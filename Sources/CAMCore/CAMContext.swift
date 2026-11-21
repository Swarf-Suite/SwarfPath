import Foundation
import simd

public enum CAMError: Error, LocalizedError {
    case noModel
    case nothingToCut(String)
    case invalidSettings(String)
    case internalError(String)

    public var errorDescription: String? {
        switch self {
        case .noModel: return "No model loaded."
        case .nothingToCut(let s): return s
        case .invalidSettings(let s): return s
        case .internalError(let s): return "Internal error: \(s) No toolpath was produced. Please report this."
        }
    }
}

public typealias ProgressHandler = @Sendable (Double) -> Void

/// Prepared geometry shared by every operation of a job.
public final class CAMContext: @unchecked Sendable {
    public let placed: PlacedModel
    /// The job. Its operations can be replaced (`updateOperations`) without rebuilding the geometry, so operations that
    /// depend on others (rest machining, roughing held up for its finishes) always see their current settings.
    public var job: Job {
        jobLock.lock(); defer { jobLock.unlock() }
        return _job
    }
    private var _job: Job
    private let jobLock = NSLock()
    /// Model top surface; `Grid2D.none` where there is no model.
    public let heights: Grid2D
    /// Distance (mm) from each cell to the model silhouette (0 inside).
    public let silhouetteDistance: Grid2D
    public let flatLevels: [Double]
    /// Holes in the silhouette that the part surrounds completely (a slot, a pot hole): for each such cell, the lowest
    /// model surface around the hole's edge; NaN everywhere else. "Inside model only" boundaries treat a band just inside
    /// such a hole (`enclosedHoleBand`) as filled to that height, so the cutter can sweep over the hole's edge and clear
    /// strips too narrow for it between the hole and a wall. Inside the hole is only ever waste; the rest of the hole
    /// stays out of bounds so a pocket doesn't spend time clearing it (on side B it is usually already cut through).
    public let enclosedHoleFill: [Float]
    /// For cells of an enclosed hole: distance (mm) to the nearest wall around it, i.e. surface more than 0.5 mm above
    /// the hole's fill height (searched up to `CAMContext.holeWallReach`); infinity elsewhere.
    let enclosedHoleWallDistance: [Float]
    static let holeWallReach = 30.0
    /// Which face this context machines. Side B's `placed` is side A's rolled about X.
    public let side: MachiningSide
    /// Side B only: the stock frame and tabs that must not be cut.
    let protection: FrameProtection?

    private var fieldCache: [String: Grid2D] = [:]
    var restCache: [String: RestField] = [:]
    /// Toolpaths of earlier operations, generated to simulate what they leave (`priorStock`), keyed by the whole job.
    var toolpathCache: [String: Toolpath] = [:]
    /// Stock left by earlier operations (`priorStock`), keyed by the whole job.
    var priorStockCache: [String: Grid2D?] = [:]
    var holesCache: [Hole]?
    var edgeExtensionCache: [Float]?
    var cleanupCache: [String: RoughingCleanup?] = [:]
    private var footprintCache: Footprint?
    let lock = NSLock()
    private var sideBCache: CAMContext?

    /// The side-B context for this job (built on first use), protecting the job's own side-A cutouts.
    public var sideB: CAMContext {
        if side == .b { return self }
        lock.lock()
        if let b = sideBCache { lock.unlock(); return b }
        lock.unlock()
        let b = makeSideB()
        lock.lock(); sideBCache = b; lock.unlock()
        return b
    }

    /// Replaces the job's operations (the app edits them without rebuilding the context). Side B follows.
    public func updateOperations(_ operations: [Operation]) {
        jobLock.lock()
        let changed = _job.operations != operations
        _job.operations = operations
        jobLock.unlock()
        lock.lock()
        // Kept toolpaths and simulations are for one set of operations; don't let edits pile them up.
        if changed { toolpathCache = [:]; priorStockCache = [:]; restCache = restCache.filter { !$0.key.contains("#left#") } }
        let b = sideBCache
        lock.unlock()
        if let b, b !== self { b.updateOperations(operations) }
    }

    /// Exact model footprint for sub-cell accurate outlines (built on first use).
    var footprint: Footprint {
        lock.lock(); defer { lock.unlock() }
        if let f = footprintCache { return f }
        let f = Footprint(mesh: placed.mesh)
        footprintCache = f
        return f
    }

    public var stockTop: Double { placed.stockTop }
    public var safeZ: Double { placed.stockTop + job.safeHeight }
    public var res: Double { heights.res }
    /// Work zero in stock space (XY). Toolpaths start here, matching where the G-code starts on the machine.
    public var startXY: V2 { let o = placed.originPoint(job.origin); return V2(o.x, o.y) }

    public convenience init(raw: Mesh, job: Job) {
        self.init(placed: PlacedModel(raw: raw, orientation: job.orientation, stock: job.stock), job: job, side: .a, protection: nil)
    }

    init(placed: PlacedModel, job: Job, side: MachiningSide, protection: FrameProtection?) {
        self._job = job
        self.placed = placed
        self.side = side
        self.protection = protection
        let s = placed.stockSize
        let maxTool = job.operations.map { $0.tool.radius + max(0, $0.boundaryMargin) + $0.stockToLeaveXY + $0.trenchExtra }
            .filter(\.isFinite).max() ?? 5
        let reach = min(CAMContext.maxGridMargin, max(8, maxTool + 4))
        let res = CAMContext.gridResolution(stockSize: s, quality: job.quality, margin: reach)
        let margin = reach + 2 * res
        let template = Grid2D(covering: V2(-margin, -margin), V2(s.x + margin, s.y + margin), res: res, fill: Grid2D.none)
        heights = Heightmap.rasterizeTop(placed.mesh, into: template)
        let h = heights
        let d = DistanceTransform.distance(width: h.width, height: h.height, res: res) { h.data[$0] > Grid2D.none / 2 }
        silhouetteDistance = Grid2D(like: h, data: d)
        flatLevels = placed.mesh.flatUpwardFaceHeights()
        (enclosedHoleFill, enclosedHoleWallDistance) = CAMContext.enclosedHoles(h)
    }

    /// See `enclosedHoleFill`. Empty cells reachable from the grid border (4-connected) are outside the part; every other
    /// empty region is a hole, filled with the lowest surface height bordering it.
    static func enclosedHoles(_ h: Grid2D) -> (fill: [Float], wallDistance: [Float]) {
        let W = h.width, H = h.height
        let empty = { (i: Int) in h.data[i] <= Grid2D.none / 2 }
        var fill = [Float](repeating: .nan, count: W * H)
        // 0 = unvisited, 1 = outside, 2 = in a hole (already filled)
        var mark = [UInt8](repeating: 0, count: W * H)
        var stack: [Int] = []
        func push(_ i: Int) { if mark[i] == 0 && empty(i) { mark[i] = 1; stack.append(i) } }
        for x in 0..<W { push(x); push((H - 1) * W + x) }
        for y in 0..<H { push(y * W); push(y * W + W - 1) }
        while let c = stack.popLast() {
            let x = c % W, y = c / W
            if x > 0 { push(c - 1) }
            if x < W - 1 { push(c + 1) }
            if y > 0 { push(c - W) }
            if y < H - 1 { push(c + W) }
        }
        var wallDistance = [Float](repeating: .infinity, count: W * H)
        for start in 0..<(W * H) where mark[start] == 0 && empty(start) {
            var cells: [Int] = []
            var rim = Float.infinity
            var x0 = W, x1 = 0, y0 = H, y1 = 0
            mark[start] = 2; stack = [start]
            while let c = stack.popLast() {
                cells.append(c)
                x0 = min(x0, c % W); x1 = max(x1, c % W); y0 = min(y0, c / W); y1 = max(y1, c / W)
                let x = c % W, y = c / W
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < W && ny < H {
                    let n = ny * W + nx
                    if empty(n) {
                        if mark[n] == 0 { mark[n] = 2; stack.append(n) }
                    } else {
                        rim = min(rim, h.data[n])
                    }
                }
            }
            guard rim.isFinite else { continue }
            for c in cells { fill[c] = rim }
            // Distance from the hole's cells to walls around it, on a crop of the grid.
            let m = Int(ceil(holeWallReach / h.res))
            let cx0 = max(0, x0 - m), cx1 = min(W - 1, x1 + m), cy0 = max(0, y0 - m), cy1 = min(H - 1, y1 + m)
            let cw = cx1 - cx0 + 1, ch = cy1 - cy0 + 1
            let wall = rim + 0.5
            let d = DistanceTransform.distance(width: cw, height: ch, res: h.res) { k in
                h.data[(cy0 + k / cw) * W + cx0 + k % cw] > wall
            }
            for c in cells { wallDistance[c] = d[(c / W - cy0) * cw + (c % W - cx0)] }
        }
        return (fill, wallDistance)
    }

    /// How far into an enclosed hole (from its edge) "inside model only" lets this operation's cutter go: a cutter
    /// diameter plus 1 mm, so it can reach across the edge from either side. Only near a wall, though: where the floor
    /// between the hole and the nearest wall is wider than the cutter, it can already reach the edge from the floor.
    /// How far past an open edge an operation that runs past edges may treat the face as carrying on: far enough for the
    /// cutter's centre to go 1 mm past the edge.
    func edgeOverrunBand(_ op: Operation) -> Double { 2 * op.tool.radius + 2 * max(0, op.stockToLeaveXY) + 1 + heights.res }

    /// Lowest Z a cut past an open edge may reach: above the cutout's tabs (on this side), and never within 1 mm of the
    /// stock bottom, so cutting past the edge of a face that runs down to the bottom never frees the part.
    func edgeOverrunFloor(_ op: Operation) -> Double {
        let tabs = job.operations.filter { $0.enabled && $0.kind == .cutout && $0.machiningSide == side && $0.tabs.enabled }
            .map { $0.tabs.height }.max() ?? 0
        return max(1, tabs + 1)
    }

    /// Widest `edgeOverrunBand` computed: covers bits up to 25 mm.
    static let maxEdgeBand = 28.0

    /// For cells outside the part (not in a hole it surrounds) within `maxEdgeBand` of it: the height of the nearest
    /// part cell, i.e. each face carried on outwards past its edge. NaN elsewhere. Material there is waste the cutout
    /// takes anyway, and nothing of the part is lower than the face it continues, so cutting down to it is safe and lets
    /// a cutter clear the face right to its edge. Computed once per context.
    var edgeExtension: [Float] {
        lock.lock()
        if let e = edgeExtensionCache { lock.unlock(); return e }
        lock.unlock()
        let g = heights, sil = silhouetteDistance
        let W = g.width, H = g.height
        var out = [Float](repeating: .nan, count: g.data.count)
        var dist = [Float](repeating: .infinity, count: g.data.count)
        // Multi-source search outwards from the part's boundary cells, nearest first (Dijkstra on the 8-neighbour grid).
        var heap: [(Float, Int)] = []
        func push(_ e: (Float, Int)) {
            heap.append(e)
            var c = heap.count - 1
            while c > 0 { let p = (c - 1) / 2; if heap[p].0 <= heap[c].0 { break }; heap.swapAt(p, c); c = p }
        }
        func pop() -> (Float, Int) {
            let top = heap[0]
            let last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last
                var c = 0
                while true {
                    let l = 2 * c + 1, r = l + 1
                    var m = c
                    if l < heap.count && heap[l].0 < heap[m].0 { m = l }
                    if r < heap.count && heap[r].0 < heap[m].0 { m = r }
                    if m == c { break }
                    heap.swapAt(m, c); c = m
                }
            }
            return top
        }
        let inside = { (i: Int) in g.data[i] > Grid2D.none / 2 }
        let outer = { (i: Int) in !inside(i) && self.enclosedHoleFill[i].isNaN }
        let res = Float(g.res), diag = Float(g.res * 2.0.squareRoot())
        for y in 0..<H {
            for x in 0..<W {
                let i = y * W + x
                guard inside(i) else { continue }
                var edge = false
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let xx = x + dx, yy = y + dy
                    if xx >= 0, yy >= 0, xx < W, yy < H, outer(yy * W + xx) { edge = true; break }
                }
                if edge { dist[i] = 0; out[i] = g.data[i]; push((0, i)) }
            }
        }
        let band = Float(Self.maxEdgeBand)
        while !heap.isEmpty {
            let (d, i) = pop()
            if d > dist[i] { continue }
            let x = i % W, y = i / W
            for dy in -1...1 {
                for dx in -1...1 where dx != 0 || dy != 0 {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, yy >= 0, xx < W, yy < H else { continue }
                    let j = yy * W + xx
                    guard outer(j), sil.data[j] <= band else { continue }
                    let nd = d + (dx != 0 && dy != 0 ? diag : res)
                    if nd < dist[j] { dist[j] = nd; out[j] = out[i]; push((nd, j)) }
                }
            }
        }
        for i in out.indices where inside(i) { out[i] = .nan }
        lock.lock(); edgeExtensionCache = out; lock.unlock()
        return out
    }

    func enclosedHoleBand(_ op: Operation) -> Double { op.tool.diameter + 2 * max(0, op.stockToLeaveXY) + 1 }

    /// Whether cell `i` (a cell outside the silhouette, `d` mm from it) is in the band of an enclosed hole that this
    /// operation may use.
    @inline(__always) func inHoleBand(_ i: Int, _ d: Float, band: Float) -> Bool {
        !enclosedHoleFill[i].isNaN && d <= band && enclosedHoleWallDistance[i] <= 2 * band
    }

    /// For rest and leftover passes: grid cell `i` is outside the part (not in a hole it surrounds) and `op` runs past
    /// open edges. Stock there is waste the cutout takes, so it never counts as left over, though the cutter may still
    /// pass over it to reach the part's edge.
    func isPastOpenEdge(_ i: Int, op: Operation) -> Bool {
        op.runsPastOpenEdges && op.boundary == .insideSilhouette && silhouetteDistance.data[i] > 0 && enclosedHoleFill[i].isNaN
    }

    /// True outside the part's open outline, within the band `op` may run past it (see `edgeExtension`).
    func pastOpenEdge(_ p: V2, op: Operation) -> Bool {
        let d = silhouetteDistance.sample(p)
        guard d > 0, Double(d) <= edgeOverrunBand(op) - op.tool.radius else { return false }
        let c = heights.cellCoord(p)
        let x = Int(c.x.rounded()), y = Int(c.y.rounded())
        guard x >= 0, y >= 0, x < heights.width, y < heights.height else { return false }
        return !edgeExtension[y * heights.width + x].isNaN
    }

    /// True inside the silhouette, or in the band of a hole the part surrounds (see `enclosedHoleFill`).
    func insideOrEnclosed(_ p: V2, band: Double) -> Bool {
        let d = silhouetteDistance.sample(p)
        if d <= 0 { return true }
        let c = heights.cellCoord(p)
        let x = Int(c.x.rounded()), y = Int(c.y.rounded())
        guard x >= 0, y >= 0, x < heights.width, y < heights.height else { return false }
        return inHoleBand(y * heights.width + x, d, band: Float(band))
    }

    /// Widest border kept around the stock for cutter overhang and boundary margins (mm).
    static let maxGridMargin = 250.0
    /// Upper bound on height-field cells, so huge stock (or a model in the wrong units) can't exhaust memory.
    static let maxGridCells = 36_000_000.0

    /// Height-field cell size for a stock size: finer for small stock, never more cells than `maxGridCells`.
    public static func gridResolution(stockSize s: V3, quality: ResolutionQuality, margin: Double = 8) -> Double {
        let ideal = max(0.05, min(0.5, max(s.x, s.y) / quality.divisions))
        let area = (s.x + 2 * margin) * (s.y + 2 * margin)
        return max(ideal, (area / maxGridCells).squareRoot())
    }

    // MARK: Regions

    func regions(for op: Operation) -> [Region] {
        job.regions.compactMap { r in
            guard r.enabled, r.applies(to: side) else { return nil }
            if r.isArea {
                // Only the operations limited to an area use it, and inside it they may only machine there.
                guard r.id == op.areaID else { return nil }
                var m = r
                m.kind = .machineOnly
                return m
            }
            return op.regionIDs == nil || op.regionIDs!.contains(r.id) ? r : nil
        }
    }

    func isForbiddenXY(_ p: V2, z: Double, op: Operation, inflate: Double) -> Bool {
        let rs = regions(for: op)
        for r in rs where r.kind == .keepOut && r.contains(p, inflate: inflate) {
            if let pz = r.protectBelowZ { if z < pz - 1e-6 { return true } } else { return true }
        }
        let only = rs.filter { $0.kind == .machineOnly }
        if !only.isEmpty && !only.contains(where: { $0.contains(p) }) { return true }
        return false
    }

    // MARK: Fields

    public func floorZ(_ op: Operation) -> Double {
        let base: Double
        if let f = op.floorZ {
            base = f
        } else {
            let mb = placed.modelBounds.min.z
            base = op.kind == .pocket ? max(0, mb) : (mb <= 0.01 ? min(op.bottomSkin, stockTop) : mb)
        }
        if op.kind != .cutout, op.kind != .drill, op.kind != .dowelHoles, let t = depthFloor(op) { return max(base, t) }
        return base
    }

    /// The lowest Z an operation may reach: the shallower of its own maximum depth and the test-cut limit,
    /// or nil when neither applies.
    public func depthFloor(_ op: Operation) -> Double? {
        var depths: [Double] = []
        if let t = job.activeTestCut, let d = t.depth(for: op.kind), d.isFinite { depths.append(max(0, d)) }
        if let d = op.maxDepth, d.isFinite, d > 0 { depths.append(d) }
        return depths.min().map { stockTop - $0 }
    }

    /// Effective obstacle heights for an operation (model + floor + boundary + regions + stock-to-leave).
    func obstacleHeights(_ op: Operation) -> Grid2D {
        let floor = Float(floorZ(op))
        let leaveZ = Float(op.stockToLeaveZ)
        let R = op.tool.radius + op.stockToLeaveXY
        let s = placed.stockSize
        var g = heights
        let sil = silhouetteDistance
        let rs = regions(for: op)
        let onlyRegions = rs.filter { $0.kind == .machineOnly }
        let keepOuts = rs.filter { $0.kind == .keepOut }
        let margin = Float(op.boundaryMargin + R)
        let res = g.res
        let frame = protection
        let holes = enclosedHoleFill
        let band = Float(enclosedHoleBand(op))
        let top = Float(stockTop)
        // Holes a drilling operation will make: solid at their rim, so passes run straight over them.
        let drilled = drilledHoleFill(op)
        let edge = op.boundary == .insideSilhouette && op.runsPastOpenEdges ? edgeExtension : nil
        let edgeBand = Float(edgeOverrunBand(op))
        let edgeFloor = Float(edgeOverrunFloor(op))
        for y in 0..<g.height {
            for x in 0..<g.width {
                let i = y * g.width + x
                let p = g.world(x, y)
                var v = max(g.data[i], floor) + leaveZ
                // Outside the stock (expanded by the cutter radius) there is nothing to reach.
                let outsideStock = p.x < -R - res || p.y < -R - res || p.x > s.x + R + res || p.y > s.y + R + res
                if let drilled, !drilled[i].isNaN {
                    v = max(max(g.data[i], drilled[i]), floor) + leaveZ
                    if outsideStock { v = Grid2D.forbid }
                } else {
                switch op.boundary {
                case .stock:
                    if outsideStock { v = Grid2D.forbid }
                case .silhouette:
                    if outsideStock || sil.data[i] > margin { v = Grid2D.forbid }
                case .insideSilhouette:
                    if sil.data[i] > 0 {
                        let f = holes[i]
                        if inHoleBand(i, sil.data[i], band: band) {
                            v = max(f, floor) + leaveZ
                        } else if let edge, sil.data[i] <= edgeBand, !edge[i].isNaN, !outsideStock {
                            // Past an open edge: the face carried on outwards, so the cutter can hang over the edge.
                            v = max(edge[i], floor, edgeFloor) + leaveZ
                        } else {
                            v = Grid2D.forbid
                        }
                    }
                }
                }
                if !onlyRegions.isEmpty && !onlyRegions.contains(where: { $0.contains(p, inflate: R) }) { v = Grid2D.forbid }
                for r in keepOuts where r.contains(p, inflate: res) {
                    v = max(v, r.protectBelowZ.map { Float($0) } ?? Grid2D.forbid)
                }
                // Side B: the frame and the tabs holding the part stay whole.
                if let frame, frame.protects(p, silhouetteDistance: sil.data[i]) { v = max(v, top) }
                g.data[i] = v
            }
        }
        // 3D strategies: make the field conservative (half-cell max) so contact points that fall
        // between grid nodes on steep slopes can never cause a gouge.
        if op.kind == .roughing || op.kind == .parallelFinish || op.kind == .waterlineFinish {
            let src = g.data
            let W = g.width, H = g.height
            g.data.withUnsafeMutableBufferPointer { dst in
                let d = dst.baseAddress!
                src.withUnsafeBufferPointer { sb in
                    let s = sb.baseAddress!
                    Parallel.forEach(H) { rows in
                        for y in rows {
                            for x in 0..<W {
                                let c = s[y * W + x]
                                if c >= Grid2D.forbidThreshold { continue }
                                var m = c
                                for yy in max(0, y - 1)...min(H - 1, y + 1) {
                                    for xx in max(0, x - 1)...min(W - 1, x + 1) {
                                        let v = s[yy * W + xx]
                                        if v < Grid2D.forbidThreshold { m = max(m, (v + c) * 0.5) }
                                    }
                                }
                                d[y * W + x] = m
                            }
                        }
                    }
                }
            }
        }
        return g
    }

    /// Everything `obstacleHeights()` and the dilation depend on, as a cache key. 3D strategies use a more conservative
    /// field than 2.5D ones, so the two must never share a cache entry.
    func fieldKey(_ op: Operation) -> String {
        let conservative = op.kind == .roughing || op.kind == .parallelFinish || op.kind == .waterlineFinish
        let t = op.tool
        let shank = t.hasWideShank ? "|shank\(t.shankDiameter)/\(t.fluteLength)" : ""
        return "\(conservative)|\(t.kind.cutsFlat ? ToolKind.flat : t.kind)|\(t.diameter)|\(t.cornerRadius)|\(t.vAngle)|\(t.tipDiameter)\(shank)|\(op.stockToLeaveXY)|\(op.stockToLeaveZ)|\(op.boundary)\(op.boundary == .insideSilhouette && op.runsPastOpenEdges ? "+edges\(edgeOverrunFloor(op))" : "")|\(op.boundaryMargin)|\(floorZ(op))|\(regions(for: op).map { "\($0.min)\($0.max)\($0.kind)\(String(describing: $0.protectBelowZ))" })" + drilledHolesKey(op)
    }

    /// Tool-tip height field for an operation (cached).
    ///
    /// A shank wider than the cutter (`Tool.hasWideShank`) is kept clear of the model too: wherever the shank's
    /// footprint covers model higher than the flute length above the tip, the tip is raised. Out-of-bounds cells
    /// (forbidden by the boundary or a keep-out) count as uncut stock at the stock top for that test, so the shank
    /// never runs deep along an edge it can't see; outside the stock there is nothing to hit.
    ///
    /// A roughing operation with finishes after it is also held up where they can't follow it (`roughingCleanup`).
    public func toolField(_ op: Operation) -> Grid2D {
        if op.kind == .roughing, let c = roughingCleanup(op) { return c.field }
        return baseToolField(op)
    }

    func baseToolField(_ op: Operation) -> Grid2D {
        let key = fieldKey(op)
        lock.lock()
        if let f = fieldCache[key] { lock.unlock(); return f }
        lock.unlock()
        let h = obstacleHeights(op)
        var t = ToolDilation.dilate(h, tool: op.tool, extraRadius: op.stockToLeaveXY)
        if op.tool.hasWideShank {
            let s = placed.stockSize, top = Float(stockTop)
            var src = h
            for y in 0..<h.height {
                for x in 0..<h.width {
                    let p = h.world(x, y), i = y * h.width + x
                    if p.x < 0 || p.y < 0 || p.x > s.x || p.y > s.y { src.data[i] = Grid2D.none }
                    else if src.data[i] >= Grid2D.forbidThreshold { src.data[i] = top }
                }
            }
            let shank = ToolDilation.dilate(src, kernel: ToolDilation.disc(radius: op.tool.shankDiameter / 2 + op.stockToLeaveXY, res: h.res))
            let reach = Float(op.tool.fluteLength)
            for i in t.data.indices where shank.data[i] > Grid2D.none / 2 {
                t.data[i] = max(t.data[i], shank.data[i] - reach)
            }
        }
        lock.lock(); fieldCache[key] = t; lock.unlock()
        return t
    }

    // MARK: Generation

    /// Rejects settings that would produce unusable G-code (F0 moves, zero-size cutters) or run away.
    func validate(_ op: Operation) throws {
        func bad(_ what: String) -> CAMError { .invalidSettings("\(op.name): \(what)") }
        let t = op.tool, c = op.cutting
        if let a = op.areaID {
            // Without its area the operation would machine the whole part with a bit chosen for one small feature.
            guard let r = job.regions.first(where: { $0.id == a }), r.isArea else {
                throw bad("the area it is limited to has been deleted. Choose another area for it, or delete the operation.")
            }
            guard r.enabled else { throw bad("its area \"\(r.name)\" is turned off. Turn the area on, or turn the operation off.") }
            guard r.applies(to: side) else { throw bad("its area \"\(r.name)\" is set to \(r.appliesTo.displayName.lowercased()). Set the area to this side too.") }
        }
        guard t.diameter.isFinite, t.diameter >= 0.05 else { throw bad("the tool diameter must be at least 0.05 mm.") }
        guard t.diameter <= 2 * (CAMContext.maxGridMargin - 4) else { throw bad("the tool diameter is too large.") }
        guard c.feed.isFinite, c.feed >= 1 else { throw bad("the feed rate must be at least 1 mm/min.") }
        guard c.plunge.isFinite, c.plunge >= 1 else { throw bad("the plunge rate must be at least 1 mm/min.") }
        guard c.rpm.isFinite, c.rpm >= 0 else { throw bad("the spindle speed is not valid.") }
        guard c.stepdown.isFinite, c.stepdown > 0 else { throw bad("the stepdown must be greater than zero.") }
        guard c.rampAngle.isFinite else { throw bad("the ramp angle is not valid.") }
        let usesStepover = op.kind != .cutout && op.kind != .waterlineFinish && op.kind != .drill && op.kind != .dowelHoles
        if usesStepover {
            guard c.stepoverPercent.isFinite, c.stepoverPercent > 0, op.stepover >= 0.02 else {
                throw bad("the stepover is too small (it must be at least 0.02 mm).")
            }
        }
        let numbers: [Double] = [op.stockToLeaveXY, op.stockToLeaveZ, op.boundaryMargin, op.bottomSkin, op.facingDepth, op.throughDepth,
                  op.rasterAngle, op.slopeLimit, op.floorZ ?? 0, op.maxDepth ?? 0, t.cornerRadius, t.vAngle, t.tipDiameter, t.fluteLength,
                  op.tabs.width, op.tabs.height, op.tabs.minLoopLength]
        for v in numbers where !v.isFinite {
            throw bad("one of the settings is not a valid number.")
        }
        if let r = op.restFrom, op.kind.supportsRest {
            let sizes: [Double] = [r.diameter, r.cornerRadius, r.vAngle, r.tipDiameter, r.shankDiameter, r.fluteLength]
            let maxDiameter: Double = 2 * (CAMContext.maxGridMargin - 4)
            guard sizes.allSatisfy({ $0.isFinite }), r.diameter >= 0.05, r.diameter <= maxDiameter else {
                throw bad("the larger tool for rest machining is not valid.")
            }
        }
        guard safeZ.isFinite, job.safeHeight > 0 else {
            throw CAMError.invalidSettings("The safe height must be greater than zero.")
        }
    }

    public func generate(_ op: Operation, progress: ProgressHandler? = nil) throws -> Toolpath {
        if op.kind != .dowelHoles && op.machiningSide != side {
            guard op.machiningSide == .b, job.activeFlip != nil else {
                throw CAMError.invalidSettings("\(op.name) is set to machine side B, but two-sided machining is off. Turn it on under Stock & Work Zero, or move the operation to side A.")
            }
            return try sideB.generate(op, progress: progress)
        }
        if op.kind == .dowelHoles && job.activeFlip == nil {
            throw CAMError.invalidSettings("\(op.name): dowel holes are for two-sided machining. Turn it on under Stock & Work Zero.")
        }
        if side == .b && !op.kind.allowedOnSideB {
            throw CAMError.invalidSettings("\(op.name): \(op.kind.displayName) can't be used on side B. The part is cut out from side A.")
        }
        try validate(op)
        // Operations that cut only what earlier ones left generate those earlier ones too: do each only once.
        let cacheKey = generationKey(op)
        lock.lock()
        if let tp = toolpathCache[cacheKey] { lock.unlock(); progress?(1); return tp }
        lock.unlock()
        let start = V3(startXY.x, startXY.y, safeZ)
        var tp: Toolpath
        switch op.kind {
        case .facing: tp = try facing(op, progress: progress)
        case .roughing, .pocket: tp = try clearing(op, progress: progress)
        case .parallelFinish: tp = try parallel(op, progress: progress)
        case .waterlineFinish: tp = try waterline(op, progress: progress)
        case .vcarve: tp = try vcarve(op, progress: progress)
        case .drill: tp = try drill(op, progress: progress)
        case .cutout: tp = try cutout(op, progress: progress)
        case .dowelHoles:
            if side == .b { return try CAMContext(placed: placed.rolledAboutX(), job: job, side: .a, protection: nil).generate(op, progress: progress) }
            tp = try dowelHoles(op, progress: progress)
        }
        tp.start = start
        tp.side = side
        // Last line of defence: a NaN or infinite coordinate must never reach a G-code file.
        for m in tp.moves {
            let ok = m.to.x.isFinite && m.to.y.isFinite && m.to.z.isFinite && m.feed.isFinite
                && (m.center.map { $0.x.isFinite && $0.y.isFinite } ?? true) && (m.kind == .rapid || m.feed > 0)
            guard ok else { throw CAMError.internalError("\(op.name) produced an invalid move.") }
        }
        if tp.moves.isEmpty { tp.warnings.append("Operation produced no toolpath.") }
        if placed.modelOutsideStock {
            tp.warnings.append("Part of the model lies outside the stock. Check the stock size and the model position.")
        }
        let advice = FeedsAndSpeeds.check(tool: op.tool, data: op.cutting, material: .named(job.stock.materialID),
                                          axialDepth: op.typicalAxialDepth)
        tp.warnings.append(contentsOf: advice.warnings)
        if let t = job.activeTestCut, let d = t.depth(for: op.kind) {
            tp.warnings.append(String(format: "Test cut: no deeper than %g mm below the stock top.", d))
            if job.origin.z == .stockBottom {
                tp.warnings.append("Test cut with Z zero on the bed: the depths assume the full stock thickness. Zero Z on the top of the test board instead.")
            }
        }
        let deepest = tp.moves.map(\.to.z).min() ?? stockTop
        if op.kind != .cutout && op.kind != .drill && op.kind != .dowelHoles && deepest < -0.01 {
            tp.warnings.append(String(format: "Cuts %.2f mm below the stock bottom%@.", -deepest,
                                      op.kind == .vcarve ? " — set a depth limit or use a wider-angle V-bit" : ""))
        }
        if op.kind == .parallelFinish { tp.notes.append(rasterChoice(op).reason) }
        if let c = roughingCleanup(op) {
            tp.notes.append(cleanupNote(c))
            if c.extra > 1 {
                tp.warnings.append(String(format: "%@ will take up to %.1f mm in one pass where this roughing stays higher. A rest-machining pass with a smaller cutter before it would let it go lower.", c.finish.name, c.extra + op.stockToLeaveZ))
            }
        }
        if let w = shortfallWarning(op) { tp.warnings.append(w) }
        if let w = restWarning(op) { tp.warnings.append(w) }
        if let w = hogSkinWarning(op) { tp.warnings.append(w) }
        if let w = depthWarning(op, depth: stockTop - deepest) { tp.warnings.append(w) }
        lock.lock(); toolpathCache[cacheKey] = tp; lock.unlock()
        progress?(1)
        return tp
    }

    /// A hogging bit should leave skins for the finishing bit (see `Operation.applyHogSkins`).
    func hogSkinWarning(_ op: Operation) -> String? {
        guard op.tool.kind == .roughing else { return nil }
        switch op.kind {
        case .pocket, .roughing:
            let floor = op.kind == .pocket ? Operation.hogFloorSkin : Operation.hogSkin
            guard op.stockToLeaveXY < Operation.hogSkin - 0.1 - 1e-9 || op.stockToLeaveZ < floor * 0.5 - 1e-9 else { return nil }
            return String(format: "A hogging bit's pass should leave about %.1f mm on walls and %.1f mm on floors for the finishing bit: its corn-cob flutes leave a rough wall, and Z is rarely re-zeroed exactly the same after the bit swap.", Operation.hogSkin, floor)
        case .cutout:
            guard op.stockToLeaveZ < Operation.hogFloorSkin * 0.5 - 1e-9 || op.stockToLeaveXY < Operation.hogSkin - 0.1 - 1e-9 else { return nil }
            return String(format: "A hogging bit's cutout should stop about %.0f mm above the stock bottom (Z stock to leave) and leave %.1f mm on the wall, and a flat bit should finish it: a corn-cob bit leaves a rough wall and tears the bottom edge.", Operation.hogFloorSkin, Operation.hogSkin)
        default:
            return nil
        }
    }

    /// Too deep for the bit. A shank wider than the cutter can't go below the flutes (except where `toolField` already
    /// keeps it off the model); a shank no wider than the cutter follows it down its own slot, so then the limit is the
    /// collet: the bit's stick-out, less a little clearance over the surface.
    func depthWarning(_ op: Operation, depth: Double) -> String? {
        guard op.kind != .dowelHoles else { return nil }
        let t = op.tool
        let colletClearance = 2.0
        if t.stickout.isFinite && t.stickout > 0 && depth > t.stickout - colletClearance + 0.01 {
            return String(format: "Cut depth %.1f mm leaves the collet less than %.0f mm above the stock: the bit sticks out only %.1f mm. Set it further out of the collet, or limit the depth.", depth, colletClearance, t.stickout)
        }
        guard depth > t.fluteLength + 0.01 else { return nil }
        let endMill = t.kind.cutsFlat || t.kind == .ball || t.kind == .bullNose
        if endMill && !t.hasWideShank { return nil }
        // A wide shank is already kept off the model above the flutes (see `toolField`), so cutting deeper is fine.
        if t.hasWideShank && op.kind != .vcarve && op.kind != .drill && op.kind != .cutout && op.kind != .facing { return nil }
        return String(format: t.hasWideShank
                      ? "Cut depth %.1f mm exceeds the tool's flute length (%.1f mm), and its shank is wider than the cutter."
                      : "Cut depth %.1f mm exceeds the tool's flute length (%.1f mm).", depth, t.fluteLength)
    }

    func makeToolpath(_ op: Operation, _ b: PathBuilder) -> Toolpath {
        Toolpath(id: op.id, name: op.name, kind: op.kind, tool: op.tool, rpm: op.cutting.rpm,
                 start: V3(startXY.x, startXY.y, safeZ), moves: b.moves)
    }

    func builder(_ op: Operation) -> PathBuilder {
        PathBuilder(start: V3(startXY.x, startXY.y, safeZ), safeZ: safeZ, feed: op.cutting.feed, plunge: op.cutting.plunge)
    }
}
