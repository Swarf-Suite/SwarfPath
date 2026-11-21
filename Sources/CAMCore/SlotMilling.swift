import Foundation
import simd

/// Settings for a slot operation (`OperationKind.slot`).
public struct SlotSettings: Codable, Sendable, Equatable, Hashable {
    /// Cut slots from the cutter's own width up to this much wider (mm). Where a slot is wider than the cutter, a pass
    /// along each wall takes the difference.
    public var widthTolerance = 0.3
    public init() {}
}

/// Slot milling: slots the cutter fits exactly (a 6 mm slot with a 6 mm end mill, a 4 mm slot with a 4 mm one), found
/// from the true geometry and cut down their centre line, level by level, with a ramp along the slot. A slot up to
/// `SlotSettings.widthTolerance` wider also gets a pass along each wall, so it comes out its own width.
///
/// A slot is found at its floor: at each level, cells open at that level whose distance from the material standing above
/// it is about the cutter radius are moved onto the line of greatest clearance (`centreLine`). It is accepted where the
/// cutter is pinched from both sides and fits (`ToolFootprint.margin` between `slotFitTolerance` and half the
/// tolerance). Each slot is then cut from the top of the material above it (the stock top, or what the operations
/// before it left when it cuts only what's left) down to its floor.
extension CAMContext {
    /// One slot to cut: the centre line, the wall passes (empty when the slot is the cutter's width), its floor and top.
    struct SlotRun {
        var centre: [V2]
        var sideA: [V2]
        var sideB: [V2]
        var floor: Double
        var top: Double
    }

    /// The levels a slot operation works at: the stepdown from the stock top, plus the model's flat levels.
    func slotLevels(_ op: Operation) -> [Double] {
        let floor = floorZ(op) + op.stockToLeaveZ
        let sd = max(0.05, op.cutting.stepdown)
        var levels: [Double] = []
        var z = stockTop - sd
        while z > floor + 1e-6 { levels.append(z); z -= sd }
        levels.append(floor)
        for f in flatLevels {
            let fz = f + op.stockToLeaveZ
            if fz > floor + 1e-3 && fz < stockTop - 1e-3 { levels.append(fz) }
        }
        levels.sort(by: >)
        return levels.reduce(into: [Double]()) { acc, v in if acc.last.map({ $0 - v > 0.02 }) ?? true { acc.append(v) } }
    }

    func slotAllowed(_ op: Operation) -> (V2, Double) -> Bool {
        let s = placed.stockSize, R = op.tool.radius
        return { [self] p, z in
            if isForbiddenXY(p, z: z, op: op, inflate: R) { return false }
            switch op.boundary {
            case .stock: return p.x >= 0 && p.y >= 0 && p.x <= s.x && p.y <= s.y
            case .silhouette: return Double(silhouetteDistance.sample(p)) <= op.boundaryMargin + R
            case .insideSilhouette: return insideOrEnclosed(p, band: enclosedHoleBand(op))
            }
        }
    }

    /// The slots `op`'s cutter fits, with the material still above each (see the extension's comment).
    func findSlots(_ op: Operation) throws -> [SlotRun] {
        guard op.tool.kind.cutsFlat else { return [] }
        let g = heights
        let W = g.width, H = g.height, res = g.res
        let R = op.tool.radius + op.stockToLeaveXY
        let tol = max(0, op.slotSettings.widthTolerance)
        let allowed = slotAllowed(op)
        let levels = slotLevels(op)
        let prior = op.cutsLeftoverOnly ? priorStock(op) : nil
        var covered = [Bool](repeating: false, count: W * H)
        var out: [SlotRun] = []
        // Deepest first: each slot is found at its floor; the levels above skip the cells it already covers.
        for z in levels.reversed() {
            try Task.checkCancellation()
            let zf = Float(z) + 1e-4
            let fromMaterial = DistanceTransform.distance(width: W, height: H, res: res) { g.data[$0] > zf }
            let lo = Float(R - 2.5 * res), hi = Float(R + tol / 2 + 1.5 * res)
            // A slot's centre is a ridge of the distance from the material: further than its neighbours on both sides
            // across the slot. Beside the wall of a wider area the distance only grows away from the wall, so those
            // cells never get the exact search.
            func ridge(_ x: Int, _ y: Int, _ d: Float) -> Bool {
                for (dx, dy) in [(1, 0), (0, 1), (1, 1), (1, -1)] {
                    let ax = x - dx, ay = y - dy, bx = x + dx, by = y + dy
                    guard ax >= 0, ay >= 0, ax < W, ay < H, bx >= 0, by >= 0, bx < W, by < H else { continue }
                    let a = fromMaterial[ay * W + ax], b = fromMaterial[by * W + bx]
                    if d >= a && d >= b && d > min(a, b) { return true }
                }
                return false
            }
            var cand: [Int] = []
            for i in 0..<(W * H) where !covered[i] && g.data[i] <= zf {
                let d = fromMaterial[i]
                if d >= lo && d <= hi && ridge(i % W, i / W, d) { cand.append(i) }
            }
            guard !cand.isEmpty else { continue }
            let fp = ToolFootprint(mesh: placed.mesh, tool: op.tool, tipZ: z, leaveXY: op.stockToLeaveXY, leaveZ: op.stockToLeaveZ)
            let span = 2.5 * res + tol / 2
            var point = [Int: V2]()
            for i in cand {
                guard let p = centreLine(g.world(i % W, i / W), fp: fp, span: span) else { continue }
                let m = fp.margin(p, extra: 0, cap: span)
                guard m >= Self.slotFitTolerance, m <= tol / 2 + 0.01, allowed(p, z) else { continue }
                point[i] = p
            }
            var seen = Set<Int>()
            for start in point.keys.sorted() where !seen.contains(start) {
                var comp: [V2] = []
                var cells: [Int] = []
                var stack = [start]
                seen.insert(start)
                while let c = stack.popLast() {
                    comp.append(point[c]!)
                    cells.append(c)
                    let x = c % W, y = c / W
                    for dy in -1...1 {
                        for dx in -1...1 where dx != 0 || dy != 0 {
                            let xx = x + dx, yy = y + dy
                            guard xx >= 0, yy >= 0, xx < W, yy < H else { continue }
                            let n = yy * W + xx
                            if point[n] != nil && seen.insert(n).inserted { stack.append(n) }
                        }
                    }
                }
                let runs = orderedRuns(comp, fp: fp, z: z, minMargin: Self.slotFitTolerance, allowed: allowed)
                guard !runs.isEmpty else { continue }
                // The levels above see this slot again: it is cut from the top down from here.
                for c in cells {
                    let x = c % W, y = c / W
                    for dy in -2...2 {
                        for dx in -2...2 {
                            let xx = x + dx, yy = y + dy
                            if xx >= 0, yy >= 0, xx < W, yy < H { covered[yy * W + xx] = true }
                        }
                    }
                }
                for run in runs {
                    // The material above the slot: the stock top, or the highest of what's left within the cutter.
                    var top = stockTop
                    if let prior {
                        var t = Float(Grid2D.none)
                        for p in run {
                            for o in [V2(0, 0), V2(R, 0), V2(-R, 0), V2(0, R), V2(0, -R)] { t = max(t, prior.nearest(p + o)) }
                        }
                        top = t > Grid2D.none / 2 ? min(stockTop, Double(t)) : stockTop
                    }
                    guard top > z + 0.02 else { continue }
                    let (a, b) = wallPasses(run, fp: fp, z: z, allowed: allowed)
                    out.append(SlotRun(centre: run, sideA: a, sideB: b, floor: z, top: top))
                }
            }
        }
        return out
    }

    /// Passes along each wall where the slot is wider than the cutter: each centre point moved towards the wall by its
    /// clearance (less if that would cut the part). Empty when the slot is the cutter's width everywhere.
    private func wallPasses(_ c: [V2], fp: ToolFootprint, z: Double, allowed: (V2, Double) -> Bool) -> ([V2], [V2]) {
        let margins = c.map { max(0, fp.margin($0, extra: 0)) }
        guard (margins.max() ?? 0) > 0.01, c.count >= 2 else { return ([], []) }
        func side(_ sign: Double) -> [V2] {
            c.indices.map { i in
                let t = simd_normalize(c[min(i + 1, c.count - 1)] - c[max(i - 1, 0)])
                let n = V2(-t.y, t.x) * sign
                for f in [1.0, 0.75, 0.5, 0.25] {
                    let q = c[i] + n * margins[i] * f
                    if fp.margin(q, extra: 0) >= Self.slotFitTolerance && allowed(q, z) { return q }
                }
                return c[i]
            }
        }
        return (side(1), side(-1))
    }

    func slotMilling(_ op: Operation, progress: ProgressHandler?) throws -> Toolpath {
        guard op.tool.kind.cutsFlat else {
            throw CAMError.invalidSettings("\(op.name): slots need a flat end mill (the slot's floor and walls are square).")
        }
        let slots = try findSlots(op)
        progress?(0.7)
        let levels = slotLevels(op)
        var b = builder(op)
        let ramp = max(0.5, op.cutting.rampAngle) * .pi / 180
        var remaining = slots
        while !remaining.isEmpty {
            // The nearest slot end next.
            let here = b.pos.xy
            let k = remaining.indices.min { i, j in
                let a = remaining[i].centre, c = remaining[j].centre
                return min(simd_distance(here, a.first!), simd_distance(here, a.last!))
                    < min(simd_distance(here, c.first!), simd_distance(here, c.last!))
            }!
            var s = remaining.remove(at: k)
            if simd_distance(here, s.centre.last!) < simd_distance(here, s.centre.first!) {
                s.centre.reverse(); s.sideA.reverse(); s.sideB.reverse()
            }
            let zs = levels.filter { $0 < s.top - 1e-6 && $0 > s.floor + 1e-6 } + [s.floor]
            let pts = s.centre
            let length = zip(pts, pts.dropFirst()).reduce(0.0) { $0 + simd_distance($1.0, $1.1) }
            b.travel(to: V3(pts[0], s.top), approachZ: s.top + 1)
            var forward = true          // which way the next pass along the centre line runs
            for z in zs {
                // Ramp down along the centre line, turning at the ends as often as needed.
                var zNow = b.pos.z
                var guardCount = 0
                while zNow > z + 1e-6 && length > 1e-3 && guardCount < 1000 {
                    guardCount += 1
                    let seq = forward ? pts : pts.reversed()
                    var leg: [V3] = [b.pos]
                    for (a, p) in zip(seq, seq.dropFirst()) {
                        zNow = max(z, zNow - simd_distance(a, p) * tan(ramp))
                        leg.append(V3(p, zNow))
                    }
                    b.polyline(Array(Polyline.simplify(leg, tolerance: 0.005).dropFirst()))
                    forward.toggle()
                }
                if length <= 1e-3 { b.cut(V3(b.pos.xy, z)) }
                // A full pass at depth.
                let seq = forward ? pts : pts.reversed()
                b.polyline(Array(Polyline.simplify(seq.map { V3($0, z) }, tolerance: 0.005).dropFirst()))
                forward.toggle()
                // Wider than the cutter: along one wall back to the start, across, along the other, back onto the line.
                if !s.sideA.isEmpty {
                    let a = forward ? s.sideA : Array(s.sideA.reversed())
                    let c = forward ? s.sideB : Array(s.sideB.reversed())
                    b.cut(V3(a[0], z))
                    b.polyline(Array(Polyline.simplify(a.map { V3($0, z) }, tolerance: 0.005).dropFirst()))
                    b.cut(V3((forward ? pts.last! : pts.first!), z))
                    b.cut(V3(c.last!, z))
                    b.polyline(Array(Polyline.simplify(c.reversed().map { V3($0, z) }, tolerance: 0.005).dropFirst()))
                    b.cut(V3(forward ? pts.first! : pts.last!, z))
                }
            }
            b.retract()
            progress?(0.7 + 0.3 * Double(slots.count - remaining.count) / Double(max(1, slots.count)))
        }
        b.retract()
        var tp = makeToolpath(op, b)
        if slots.isEmpty {
            tp.warnings.append(String(format: "No slots %g–%g mm wide to cut.", op.tool.diameter + 2 * op.stockToLeaveXY,
                                      op.tool.diameter + 2 * op.stockToLeaveXY + op.slotSettings.widthTolerance))
        }
        return tp
    }
}
