import Foundation
import simd

/// The raster angle a parallel finish uses, and why.
public struct RasterChoice: Sendable, Equatable {
    /// Degrees: passes run along (cos, sin) of this angle. 0 = along X, 90 = along Y.
    public var angle: Double
    /// True when it was worked out from the surface.
    public var automatic: Bool
    /// One sentence for the user.
    public var reason: String
}

extension CAMContext {
    /// Axis-aligned passes are smoother on the machine (one axis moves along each pass), so a direction this close to X
    /// or Y (degrees) is snapped to it.
    static let rasterSnap = 10.0
    /// A surface whose principal curvatures agree this little (0…1) on one direction has no best one (a dome).
    static let rasterMinCoherence = 0.35

    /// The raster angle for a parallel finish.
    ///
    /// Each pass follows the surface exactly along its length (drop-cutter samples a fraction of a cell apart), while
    /// neighbouring passes only meet the surface where they touch it, leaving a ridge between them that grows with how
    /// much the surface bends across the passes. So the passes should run along the direction the surface bends most,
    /// and step over along the direction it is straightest. For a neck lying along X, the curve from the fretboard face
    /// down to the headstock face bends along X and is straight across Y: passes along X, stepping in Y, leave no ridges
    /// at all with a flat end mill.
    ///
    /// The bend at each cell comes from the second derivatives of the model's top surface (over about half the tool
    /// radius, so facets and grid noise don't count), as the principal direction of the larger curvature, weighted by
    /// how much larger it is than the other. Directions are axial, so they are averaged as doubled angles. Flat areas
    /// weigh nothing; walls too steep for a parallel pass, and places the operation can't reach, are left out.
    public func rasterChoice(_ op: Operation) -> RasterChoice {
        let manual = RasterChoice(angle: op.rasterAngle, automatic: false,
                                  reason: String(format: "Passes at %g°, as set.", op.rasterAngle))
        guard op.kind == .parallelFinish, op.rasterIsAuto else { return manual }
        let fallback = { (why: String) in
            RasterChoice(angle: op.rasterAngle, automatic: true, reason: why + String(format: " Using %g°.", op.rasterAngle))
        }
        let T = toolField(op)
        let h = heights
        let W = h.width, H = h.height, res = h.res
        let k = max(1, Int((max(0.5, op.tool.radius * 0.5) / res).rounded()))
        let d = Double(k) * res
        let maxSlope = op.slopeLimit > 0 ? min(op.slopeLimit + 5, 75) : 75
        let maxGrad = tan(maxSlope * .pi / 180)
        // Curvature tighter than the cutter can follow is a crease or an edge: cap it so a few don't outweigh the rest.
        let cap = 1 / max(1, op.tool.radius)
        let rest = restField(op)
        let rs = regions(for: op)
        var sx = 0.0, sy = 0.0, sw = 0.0
        var cells = 0, curved = 0
        for y in k..<max(k, H - k) {
            for x in k..<max(k, W - k) {
                let i = y * W + x
                guard T.data[i] < Grid2D.forbidThreshold else { continue }
                let c = h.data[i]
                let xm = h.data[i - k], xp = h.data[i + k], ym = h.data[i - k * W], yp = h.data[i + k * W]
                let pp = h.data[i + k * W + k], pm = h.data[i - k * W + k], mp = h.data[i + k * W - k], mm = h.data[i - k * W - k]
                @inline(__always) func ok(_ v: Float) -> Bool { v > Grid2D.none / 2 && v < Grid2D.forbidThreshold }
                guard ok(c), ok(xm), ok(xp), ok(ym), ok(yp), ok(pp), ok(pm), ok(mp), ok(mm) else { continue }
                let p = h.world(x, y)
                // Rest machining: the shape of the material actually left decides, not the finished areas around it.
                if let rest {
                    if let m = rest.material { if !(m.data[i] > Grid2D.none / 2) { continue } } else if !rest.touches(p) { continue }
                }
                if !rs.isEmpty && isForbiddenXY(p, z: Double(c), op: op, inflate: 0) { continue }
                let gx = Double(xp - xm) / (2 * d), gy = Double(yp - ym) / (2 * d)
                let g2 = gx * gx + gy * gy
                guard g2 <= maxGrad * maxGrad else { continue }
                // Next to a wall too steep for a pass (a slot's side) the central difference averages the wall into a
                // gentle curve: leave out cells where either side alone is that steep.
                let steep = Float(maxGrad * d)
                if abs(xp - c) > steep || abs(c - xm) > steep || abs(yp - c) > steep || abs(c - ym) > steep { continue }
                cells += 1
                // Hessian, then curvature (second derivative along the surface, not just in plan).
                let n = pow(1 + g2, 1.5)
                let a = Double(xp - 2 * c + xm) / (d * d) / n
                let cc = Double(yp - 2 * c + ym) / (d * d) / n
                let b = Double(pp - pm - mp + mm) / (4 * d * d) / n
                let mean = (a + cc) / 2, r = ((a - cc) * (a - cc) / 4 + b * b).squareRoot()
                let l1 = mean + r, l2 = mean - r
                // Far tighter than the cutter: a crease or an edge (a slot's lip), not a surface it follows.
                if max(abs(l1), abs(l2)) > 3 * cap { continue }
                let w = min(cap, abs(abs(l1) - abs(l2)))
                guard w > 1e-4 else { continue }
                curved += 1
                // Direction of l1 (the algebraically larger); turn 90° when l2 is the larger in size.
                var phi2 = atan2(2 * b, a - cc)
                if abs(l2) > abs(l1) { phi2 += .pi }
                sx += w * cos(phi2); sy += w * sin(phi2); sw += w
            }
        }
        guard cells > 0 else { return fallback("Nothing to finish that a parallel pass can reach.") }
        guard Double(curved) >= 0.02 * Double(cells), sw > 0 else {
            return fallback("The surface is flat, so the direction doesn't change the finish.")
        }
        let coherence = (sx * sx + sy * sy).squareRoot() / sw
        guard coherence >= Self.rasterMinCoherence else {
            return fallback("The surface curves about equally in every direction (like a dome), so no direction is better.")
        }
        var angle = atan2(sy, sx) / 2 * 180 / .pi
        if angle < 0 { angle += 180 }
        if angle >= 180 { angle -= 180 }
        if min(angle, 180 - angle) <= Self.rasterSnap { angle = 0 }
        else if abs(angle - 90) <= Self.rasterSnap { angle = 90 }
        else { angle = angle.rounded() }
        let along = angle == 0 ? "X" : angle == 90 ? "Y" : String(format: "%g°", angle)
        let across = angle == 0 ? "Y" : angle == 90 ? "X" : "the passes"
        return RasterChoice(angle: angle, automatic: true,
                            reason: "Passes along \(along): the surface curves most that way and is straightest across \(across), so the passes leave the smallest ridges between them.")
    }

    // MARK: Finish reach

    /// The lowest surface a tool can leave, like `machinedSurface`, but `Grid2D.none` where no placement reaches.
    func reachedSurface(_ T: Grid2D, tool: Tool, extraRadius: Double) -> Grid2D {
        let neg = T.map { $0 >= Grid2D.forbidThreshold ? Grid2D.none : -$0 }
        let d = ToolDilation.dilate(neg, tool: tool, extraRadius: extraRadius)
        let top = Float(stockTop)
        return d.map { v in v <= Grid2D.none / 2 ? Grid2D.none : min(top, -v) }
    }

    /// Slope (degrees) of the model's top surface, 90 at its edges.
    func surfaceSlope(_ i: Int) -> Double {
        let h = heights, W = h.width
        let x = i % W, y = i / W
        guard x > 0, y > 0, x < W - 1, y < h.height - 1 else { return 90 }
        let v = [h.data[i - 1], h.data[i + 1], h.data[i - W], h.data[i + W]]
        guard v.allSatisfy({ $0 > Grid2D.none / 2 && $0 < Grid2D.forbidThreshold }) else { return 90 }
        let gx = Double(v[1] - v[0]) / (2 * h.res), gy = Double(v[3] - v[2]) / (2 * h.res)
        return atan((gx * gx + gy * gy).squareRoot()) * 180 / .pi
    }

    /// Material a finish leaves above the model because its cutter is too big or too flat for a concave curve (the
    /// bottom of a cove, the root of a fillet): plan area (mm²) and the thickest (mm), or nil when there is none worth
    /// mentioning. Measured against a tiny ball nose on the same field, so grid effects cancel.
    public func finishShortfall(_ op: Operation) -> (area: Double, maxThickness: Double)? {
        guard op.kind == .parallelFinish || op.kind == .waterlineFinish else { return nil }
        let S = reachedSurface(toolField(op), tool: op.tool, extraRadius: op.stockToLeaveXY)
        var fine = op
        fine.tool = Tool(name: "reference", kind: .ball, diameter: max(2 * res, 0.4), fluteLength: op.tool.fluteLength,
                         stickout: op.tool.stickout, defaults: op.cutting)
        let F = reachedSurface(toolField(fine), tool: fine.tool, extraRadius: op.stockToLeaveXY)
        let limit = op.slopeLimit
        let tol = Self.restTolerance
        var area = 0.0, thickest: Float = 0
        for i in S.data.indices {
            let s = S.data[i], f = F.data[i]
            guard s > Grid2D.none / 2, f > Grid2D.none / 2, heights.data[i] > Grid2D.none / 2, s - f > tol else { continue }
            if limit > 0 {
                let slope = surfaceSlope(i)
                if op.kind == .parallelFinish ? slope > limit + 5 : slope < limit - 5 { continue }
            }
            area += res * res
            thickest = max(thickest, s - f)
        }
        return area >= 1 ? (area, Double(thickest)) : nil
    }

    func shortfallWarning(_ op: Operation) -> String? {
        guard let s = finishShortfall(op) else { return nil }
        let t = op.tool
        let what = t.kind == .ball ? String(format: "Ø%g mm ball nose", t.diameter)
            : String(format: "Ø%g mm %@", t.diameter, t.kind.displayName.lowercased())
        let fix = t.kind == .ball ? "A smaller ball nose follows them." : "A ball nose or a smaller cutter follows them."
        return String(format: "Up to %.2f mm is left in concave curves tighter than the %@ can follow (about %.0f mm²). %@",
                      s.maxThickness, what, s.area, fix)
    }

    // MARK: Roughing clean-up skin

    /// The 3D finishes after a roughing operation on the same side.
    func finishesAfter(_ op: Operation) -> [Operation] {
        guard op.kind == .roughing, let me = job.operations.firstIndex(where: { $0.id == op.id }) else { return [] }
        return job.operations[(me + 1)...].filter {
            $0.enabled && ($0.kind == .parallelFinish || $0.kind == .waterlineFinish) && $0.machiningSide == op.machiningSide
        }
    }

    /// The surface a finish actually leaves, on the model grid: its own toolpath, simulated on fresh stock, so the
    /// gaps between raster passes, its slope limit and its boundary all count (a continuous estimate from the tool
    /// field says a flat cutter dips into the open end of a cove from the side, where no pass actually goes).
    /// `Grid2D.none` where it doesn't cut. Rest limits are left out: without them it cuts at least as low, and a rest
    /// finish that follows this roughing would otherwise depend on itself.
    func finishSurface(_ op: Operation) -> Grid2D {
        var f = op
        f.restFrom = nil; f.restFromOp = nil; f.restExtraStock = nil; f.restFromEarlier = nil
        var out = Grid2D(like: heights, data: [Float](repeating: Grid2D.none, count: heights.data.count))
        guard let tp = try? generate(f) else { return out }
        var sim = StockSimulator(stockSize: placed.stockSize, resolution: res)
        sim.run([tp])
        let st = sim.stock, top = Float(placed.stockSize.z) - 0.005
        let size = placed.stockSize
        for y in 0..<out.height {
            for x in 0..<out.width {
                let p = out.world(x, y)
                guard p.x >= 0, p.y >= 0, p.x <= size.x, p.y <= size.y else { continue }
                let v = st.sample(p)
                if v < top { out.data[y * out.width + x] = v }
            }
        }
        return out
    }

    /// Least stock (mm) a finish should find everywhere it cuts: under this, a roughing step is left only half taken.
    static let finishCleanup = 0.1

    /// Where a roughing operation must stay higher than its own field allows, so the finishes after it reach below
    /// everything it cut.
    public struct RoughingCleanup {
        /// The thickest extra (mm) anywhere, over what the roughing would otherwise leave.
        public var extra: Double
        /// Plan area (mm²) where it stays higher.
        public var area: Double
        /// The finish that sets the deepest of it.
        public var finish: Operation
        /// The lowest the roughing tool tip may go, `Grid2D.none` where nothing limits it.
        var floor: Grid2D
        /// The roughing tool field with `floor` applied: what `toolField` returns for this operation.
        var field: Grid2D
    }

    /// Where a finishing cutter can't get as low as the roughing cutter did (a flat end mill in a cove a smaller
    /// roughing bit went into, or roughing that left less stock than the finish allows), the roughing surface would
    /// stay, steps and all: shelving. There, and only there, the roughing tool is held up so that it leaves at least
    /// `finishCleanup` (plus half a cell for the grid) above the lowest surface any later finish reaches. nil when the
    /// roughing already leaves enough everywhere.
    public func roughingCleanup(_ op: Operation) -> RoughingCleanup? {
        let finishes = finishesAfter(op)
        guard !finishes.isEmpty else { return nil }
        let key = fieldKey(op) + "#clean#" + finishes.map { fieldKey($0) }.joined(separator: "#")
        lock.lock()
        if let c = cleanupCache[key] { lock.unlock(); return c }
        lock.unlock()
        let T = baseToolField(op)
        // What the real cutter leaves (the field already keeps it the stock to leave away from the model).
        let R = machinedSurface(T, tool: op.tool, extraRadius: 0)
        // Per cell, the lowest any of the finishes gets (a steep-wall finish and a shallow-area one share the work).
        var S = [Float](repeating: Grid2D.none, count: R.data.count), by = [Int](repeating: 0, count: R.data.count)
        for (fi, f) in finishes.enumerated() {
            let F = finishSurface(f)
            for i in S.indices where F.data[i] > Grid2D.none / 2 && (S[i] <= Grid2D.none / 2 || F.data[i] < S[i]) {
                S[i] = F.data[i]; by[i] = fi
            }
        }
        let clear = Float(Self.finishCleanup + T.res / 2)
        let top = Float(stockTop) - 0.01
        var src = [Float](repeating: Grid2D.none, count: S.count)
        var worst: Float = 0, worstIndex = 0, cells = 0
        // Only the part's own surface: off it, a finish's reach just ends at its boundary.
        for i in S.indices where heights.data[i] > Grid2D.none / 2 && heights.data[i] < Grid2D.forbidThreshold {
            let s = S[i]
            // Where roughing never cut (the model reaches the stock top) it left no steps.
            guard s > Grid2D.none / 2, s < top, R.data[i] < top else { continue }
            let need = s + clear - R.data[i]
            guard need > 0.005 else { continue }
            src[i] = s + clear
            cells += 1
            if need > worst { worst = need; worstIndex = by[i] }
        }
        var result: RoughingCleanup? = nil
        if cells > 0 {
            // Wall passes may sit up to two cells off the grid's contour (exact-wall snapping, straightened runs), so
            // hold the cutter clear by a little more than that sideways too.
            let floor = ToolDilation.dilate(Grid2D(like: T, data: src), tool: op.tool, extraRadius: 3 * T.res)
            var field = T
            for i in field.data.indices where floor.data[i] > Grid2D.none / 2 && field.data[i] < Grid2D.forbidThreshold {
                field.data[i] = max(field.data[i], floor.data[i])
            }
            result = RoughingCleanup(extra: Double(worst), area: Double(cells) * T.res * T.res,
                                     finish: finishes[worstIndex], floor: floor, field: field)
        }
        lock.lock(); cleanupCache[key] = .some(result); lock.unlock()
        return result
    }

    func cleanupNote(_ c: RoughingCleanup) -> String {
        let f = c.finish
        let what = f.tool.kind == .ball ? String(format: "Ø%g mm ball nose", f.tool.diameter)
            : String(format: "Ø%g mm %@", f.tool.diameter, f.tool.kind.displayName.lowercased())
        return String(format: "Stays up to %.2f mm higher over about %.0f mm² so that %@ cuts below all of it: its %@ can't follow this cutter there, and steps from roughing would stay.",
                      c.extra, c.area, f.name, what)
    }
}
