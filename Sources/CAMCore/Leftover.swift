import Foundation
import simd

/// "Only what's left": an operation that cuts only the material the operations before it left (`Operation.cutsLeftoverOnly`),
/// and pockets and finishes that run straight over holes a drilling operation will make (`Operation.ignoresDrilledHoles`).
extension CAMContext {
    /// `detectHoles()`, computed once per context.
    func cachedHoles() -> [Hole] {
        lock.lock()
        if let h = holesCache { lock.unlock(); return h }
        lock.unlock()
        let h = detectHoles()
        lock.lock(); holesCache = h; lock.unlock()
        return h
    }

    /// The holes an enabled drilling operation on this operation's side will cut, when this operation ignores them.
    func drilledHoles(for op: Operation) -> [Hole] {
        guard op.ignoresDrilledHoles, op.kind != .drill, op.kind != .dowelHoles else { return [] }
        let drills = job.operations.filter { $0.enabled && $0.kind == .drill && $0.machiningSide == side && $0.tool.kind != .vBit }
        guard !drills.isEmpty else { return [] }
        return cachedHoles().filter { h in
            drills.contains { abs(h.diameter - $0.tool.diameter) <= $0.drillSettings.diameterTolerance + 1e-9 }
        }
    }

    /// For each grid cell inside a hole `op` ignores: the hole's rim height (NaN elsewhere). nil when there are none.
    func drilledHoleFill(_ op: Operation) -> [Float]? {
        let holes = drilledHoles(for: op)
        guard !holes.isEmpty else { return nil }
        let g = heights
        var fill = [Float](repeating: .nan, count: g.data.count)
        for h in holes {
            // A cell past the wall, so the conservatively stamped wall cells are covered too.
            let r = h.diameter / 2 + g.res
            let lo = g.cellCoord(h.center - V2(r, r)), hi = g.cellCoord(h.center + V2(r, r))
            for y in max(0, Int(lo.y.rounded(.down)))...min(g.height - 1, Int(hi.y.rounded(.up))) {
                for x in max(0, Int(lo.x.rounded(.down)))...min(g.width - 1, Int(hi.x.rounded(.up))) {
                    guard g.world(x, y).dist(h.center) <= r else { continue }
                    let i = y * g.width + x
                    // Never lower anything: the wall cells may already stand above the rim (a counterbore).
                    fill[i] = max(fill[i].isNaN ? -.infinity : fill[i], Float(h.rimZ))
                }
            }
        }
        return fill
    }

    /// Part of `fieldKey`: the holes this operation runs over.
    func drilledHolesKey(_ op: Operation) -> String {
        let h = drilledHoles(for: op)
        return h.isEmpty ? "" : "|holes" + h.map { String(format: "%.3f,%.3f,%.3f,%.3f", $0.center.x, $0.center.y, $0.diameter, $0.rimZ) }.joined(separator: ";")
    }

    /// Everything a generated toolpath can depend on besides the geometry: the job's operations and this one.
    func generationKey(_ op: Operation) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let ops = job.operations.map { o -> Operation in var c = o; c.name = ""; return c }
        var me = op
        me.name = ""
        return String(decoding: (try? enc.encode(ops)) ?? Data(), as: UTF8.self) + "#"
            + String(decoding: (try? enc.encode(me)) ?? Data(), as: UTF8.self)
    }

    /// The enabled operations before `op` on its side that remove material, in order.
    func earlierOperations(_ op: Operation) -> [Operation] {
        let ops = job.operations
        guard let me = ops.firstIndex(where: { $0.id == op.id }) else { return [] }
        return ops[..<me].filter { $0.enabled && $0.kind != .dowelHoles && $0.machiningSide == op.machiningSide }
    }

    /// The stock the operations before `op` leave (on this context's grid; `Grid2D.none` outside the stock), from
    /// simulating their toolpaths. nil when nothing runs before it. Cached.
    public func priorStock(_ op: Operation) -> Grid2D? {
        let earlier = earlierOperations(op)
        guard !earlier.isEmpty else { return nil }
        let key = generationKey(op)
        lock.lock()
        if let c = priorStockCache[key] { lock.unlock(); return c }
        lock.unlock()
        var paths: [Toolpath] = []
        for e in earlier {
            // An earlier operation that fails (nothing to cut, bad settings) removes nothing.
            guard var tp = try? generate(e) else { continue }
            // Simulate in this side's own coordinates, cutting from the top.
            tp.side = .a
            paths.append(tp)
        }
        var out: Grid2D? = nil
        if !paths.isEmpty {
            var sim = StockSimulator(stockSize: placed.stockSize, resolution: res)
            sim.run(paths)
            let st = sim.stock, size = placed.stockSize
            var g = Grid2D(like: heights, data: [Float](repeating: Grid2D.none, count: heights.data.count))
            // The simulated grid isn't aligned with this one, and sampling across a cut wall blends the top of the wall
            // with the floor: take the lowest of the neighbours, so a wall never looks like material left on the floor.
            let d = res
            let offsets = [V2(0, 0), V2(d, 0), V2(-d, 0), V2(0, d), V2(0, -d), V2(d, d), V2(-d, d), V2(d, -d), V2(-d, -d)]
            for y in 0..<g.height {
                for x in 0..<g.width {
                    let p = g.world(x, y)
                    guard p.x >= 0, p.y >= 0, p.x <= size.x, p.y <= size.y else { continue }
                    var v = Float.infinity
                    for o in offsets {
                        let q = simd_clamp(p + o, V2(0, 0), V2(size.x, size.y))
                        v = min(v, st.nearest(q))
                    }
                    g.data[y * g.width + x] = v
                }
            }
            out = g
        }
        lock.lock(); priorStockCache[key] = .some(out); lock.unlock()
        return out
    }

    /// The leftover-material field for an operation that cuts only what the operations before it left: the same as
    /// `restField`, with the simulated stock in place of a reference tool's surface.
    func leftoverField(_ op: Operation) -> RestField? {
        guard let prior = priorStock(op) else { return nil }
        let key = fieldKey(op) + "#left#" + generationKey(op)
        lock.lock()
        if let r = restCache[key] { lock.unlock(); return r }
        lock.unlock()
        let leave = op.stockToLeaveXY
        let Ts = toolField(op)
        let S = machinedSurface(Ts, tool: op.tool, extraRadius: leave)
        let tol = Self.restTolerance
        let cell = Ts.res * Ts.res
        var src = [Float](repeating: Grid2D.none, count: Ts.data.count)
        var area = 0.0, thickest: Float = 0
        for i in src.indices {
            let r = prior.data[i], s = S.data[i]
            guard r > Grid2D.none / 2 else { continue }
            if r - s > tol && !isPastOpenEdge(i, op: op) { src[i] = r; area += cell; thickest = max(thickest, r - s) }
        }
        let reach = op.tool.radius + leave + Ts.res
        let top = ToolDilation.dilate(Grid2D(like: Ts, data: src), kernel: ToolDilation.disc(radius: reach, res: Ts.res))
        let field = RestField(materialTop: top, leftoverArea: area, maxThickness: Double(thickest), unreachableArea: 0, unreachableDepth: 0,
                              material: Grid2D(like: Ts, data: src))
        lock.lock(); restCache[key] = field; lock.unlock()
        return field
    }

    /// Where a drill should start pecking at `center`: the top of the stock left there (stock top when nothing ran before).
    func drillStart(_ op: Operation, at center: V2) -> Double {
        guard op.cutsLeftoverOnly, let prior = priorStock(op) else { return stockTop }
        let r = op.tool.radius + res
        var top = Float(Grid2D.none)
        var y = -r
        while y <= r + 1e-9 {
            var x = -r
            while x <= r + 1e-9 {
                if x * x + y * y <= r * r { top = max(top, prior.nearest(center + V2(x, y))) }
                x += res / 2
            }
            y += res / 2
        }
        return top > Grid2D.none / 2 ? min(stockTop, Double(top)) : stockTop
    }
}
