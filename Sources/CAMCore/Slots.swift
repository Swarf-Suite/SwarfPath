import Foundation
import simd

/// Slots a pocket's cutter only just fits, such as a 6.2 mm truss-rod channel with a 6 mm end mill.
///
/// The tool field is conservative by about a cell: triangle edges are stamped into the height field and the dilation
/// takes the worst case over each cell. In a slot only a few tenths wider than the cutter, no cell centre is far enough
/// from both walls, so the grid says the cutter doesn't fit at all and leaves the slot to a smaller bit. Here the slot is
/// found on the grid (forbidden cells with the floor below the level, more than two cells from anywhere the grid allows)
/// and each candidate is moved onto the slot's centre line, where its clearance from the true geometry
/// (`ToolFootprint`) is largest. Where that clearance is at least zero, the cutter fits and the slot is cut along it.
extension CAMContext {
    /// A slot exactly the cutter's width has zero clearance; numerically it may come out a few microns negative.
    static let slotFitTolerance = -0.005

    /// One slot pass: a centre line, cut at `z`.
    struct SlotPass { var z: Double; var points: [V2] }

    /// Centre-line passes for the slots at each level the grid can't fit `op`'s cutter into but the exact geometry can.
    func narrowSlotPasses(_ op: Operation, levels: [Double], field T0: Grid2D, rest: RestField?,
                          footprint: (Double) -> ToolFootprint, allowed: (V2, Double) -> Bool) throws -> [SlotPass] {
        guard op.kind == .pocket, op.tool.kind.cutsFlat else { return [] }
        let g = heights
        let W = T0.width, H = T0.height, res = T0.res
        var out: [SlotPass] = []
        for z in levels {
            try Task.checkCancellation()
            let zf = Float(z) + 1e-4
            // Distance from anywhere the grid already lets the cutter go at this level.
            let fromAllowed = DistanceTransform.distance(width: W, height: H, res: res) { T0.data[$0] <= zf }
            var cand: [Int] = []
            for i in 0..<(W * H) {
                let t = T0.data[i]
                guard t > zf, t < Grid2D.forbidThreshold, fromAllowed[i] > Float(2.5 * res) else { continue }
                // The floor here is at or below this level (a cell the slot runs over, not material standing above it).
                let h = g.data[i]
                guard h > Grid2D.none / 2, h <= zf else { continue }
                cand.append(i)
            }
            guard !cand.isEmpty else { continue }
            let fp = footprint(z)
            // Each candidate onto the line of greatest clearance, searching across the slot.
            var point = [Int: V2]()
            for i in cand {
                let p0 = g.world(i % W, i / W)
                guard let p = centreLine(p0, fp: fp, span: 2 * res), fp.margin(p, extra: 0) >= Self.slotFitTolerance, allowed(p, z) else { continue }
                if let rest, !(rest.materialTop.nearest(p) > zf + 0.02) { continue }
                point[i] = p
            }
            // Connected runs of cells (8-connected) that found a point: one slot each.
            var seen = Set<Int>()
            for start in point.keys.sorted() where !seen.contains(start) {
                var comp: [V2] = []
                var stack = [start]
                seen.insert(start)
                while let c = stack.popLast() {
                    comp.append(point[c]!)
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
                for run in orderedRuns(comp, fp: fp, z: z, minMargin: Self.slotFitTolerance, allowed: allowed) { out.append(SlotPass(z: z, points: run)) }
            }
        }
        return out
    }

    /// The point of greatest clearance on the line through `p0` across the slot (perpendicular to the nearest wall),
    /// within `span` either side. nil when nothing is near enough to tell the direction.
    func centreLine(_ p0: V2, fp: ToolFootprint, span: Double) -> V2? {
        // The direction away from the nearest material, from the band where the cutter is full width.
        guard let s = fp.slices.last(where: { $0.full }) ?? fp.slices.last,
              let (d, q) = s.fp.nearest(p0, within: s.r + 2 * span), d > 1e-9 else { return nil }
        let n = (p0 - q) / d
        var lo = -span, hi = span
        for _ in 0..<40 {
            let a = lo + (hi - lo) / 3, b = hi - (hi - lo) / 3
            if fp.margin(p0 + n * a, extra: 0, cap: span) < fp.margin(p0 + n * b, extra: 0, cap: span) { lo = a } else { hi = b }
        }
        let t = (lo + hi) / 2
        // A slot pinches the cutter from both sides: the clearance peaks inside the search and stays small there. Where
        // it keeps growing to the end of the search, this is the side of a wider area the pocket's own passes reach.
        guard abs(t) < span - 0.02, fp.margin(p0 + n * t, extra: 0, cap: span) < span / 2 else { return nil }
        return p0 + n * t
    }

    /// The centre-line points of one slot as polylines: ordered along the slot's main direction, thinned to 0.25 mm,
    /// and split wherever the straight segment between two points would cut the part.
    func orderedRuns(_ pts: [V2], fp: ToolFootprint, z: Double, minMargin: Double = -1e-4, allowed: (V2, Double) -> Bool) -> [[V2]] {
        guard !pts.isEmpty else { return [] }
        let c = pts.reduce(V2(0, 0), +) / Double(pts.count)
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for p in pts { let d = p - c; sxx += d.x * d.x; sxy += d.x * d.y; syy += d.y * d.y }
        let angle = 0.5 * atan2(2 * sxy, sxx - syy)
        let axis = V2(cos(angle), sin(angle))
        let sorted = pts.sorted { simd_dot($0 - c, axis) < simd_dot($1 - c, axis) }
        // Thin: one point per 0.25 mm along the axis (the mean of those in each step).
        var thin: [V2] = []
        var bucket: [V2] = []
        var bucketStart = simd_dot(sorted[0] - c, axis)
        for p in sorted {
            let t = simd_dot(p - c, axis)
            if t - bucketStart > 0.25, !bucket.isEmpty {
                thin.append(bucket.reduce(V2(0, 0), +) / Double(bucket.count)); bucket = []; bucketStart = t
            }
            bucket.append(p)
        }
        if !bucket.isEmpty { thin.append(bucket.reduce(V2(0, 0), +) / Double(bucket.count)) }
        // A mean of centre-line points can fall off it on a curve; keep only points that still fit.
        thin = thin.filter { fp.margin($0, extra: 0) >= minMargin && allowed($0, z) }
        var runs: [[V2]] = []
        var cur: [V2] = []
        for p in thin {
            if let last = cur.last {
                let len = simd_distance(last, p)
                let n = max(1, Int(ceil(len / 0.1)))
                let ok = len < 2 && (1..<n).allSatisfy { k in
                    let q = last + (p - last) * (Double(k) / Double(n))
                    return fp.margin(q, extra: 0) >= minMargin && allowed(q, z)
                }
                if !ok { if cur.count >= 2 { runs.append(cur) }; cur = [] }
            }
            cur.append(p)
        }
        if cur.count >= 2 { runs.append(cur) }
        // Runs shorter than a millimetre are specks on a slope, not slots.
        return runs.filter { r in zip(r, r.dropFirst()).reduce(0.0) { $0 + simd_distance($1.0, $1.1) } >= 1 }
    }

    /// Cuts slot passes top level first, each with a ramp along its own line (back and forth when it's shorter than the
    /// ramp), from the level above it.
    func emitSlotPasses(_ passes: [SlotPass], levels: [Double], into b: inout PathBuilder, op: Operation) {
        guard !passes.isEmpty else { return }
        let ramp = max(0.5, op.cutting.rampAngle) * .pi / 180
        let byZ = passes.sorted { $0.z > $1.z }
        for pass in byZ {
            let above = levels.filter { $0 > pass.z + 1e-6 }.min() ?? stockTop
            var pts = pass.points
            // Start from the end nearest where the tool is.
            if simd_distance_squared(b.pos.xy, pts.last!) < simd_distance_squared(b.pos.xy, pts.first!) { pts.reverse() }
            let here = b.pos
            // Continue straight on from the previous pass when it ended right here, one level up.
            if !(simd_distance(here.xy, pts[0]) < 1e-3 && here.z <= above + 1e-6 && here.z >= pass.z) {
                b.travel(to: V3(pts[0], above), approachZ: above + 1)
            }
            var zNow = b.pos.z
            let length = zip(pts, pts.dropFirst()).reduce(0.0) { $0 + simd_distance($1.0, $1.1) }
            // Ramp down along the line, turning at the ends as often as needed.
            var forward = true
            var guardCount = 0
            while zNow > pass.z + 1e-6 && length > 1e-3 && guardCount < 1000 {
                guardCount += 1
                let seq = forward ? pts : pts.reversed()
                var leg: [V3] = [b.pos]
                for (a, p) in zip(seq, seq.dropFirst()) {
                    let drop = simd_distance(a, p) * tan(ramp)
                    zNow = max(pass.z, zNow - drop)
                    leg.append(V3(p, zNow))
                }
                b.polyline(Array(Polyline.simplify(leg, tolerance: 0.005).dropFirst()))
                forward.toggle()
            }
            // One full pass at depth.
            let seq = forward ? pts : pts.reversed()
            b.cut(V3(seq[0], pass.z))
            b.polyline(Array(Polyline.simplify(seq.map { V3($0, pass.z) }, tolerance: 0.005).dropFirst()))
        }
    }
}
