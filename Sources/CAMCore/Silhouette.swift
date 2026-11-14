import Foundation
import simd

/// Exact XY distance from a point to the model's footprint: the union of every triangle projected onto the XY plane.
///
/// Contours traced from the height-field grid follow its cell staircase, so they wobble by up to half a cell. That
/// wobble turns smooth curves into thousands of tiny segments that change direction at random, which makes the
/// machine brake and accelerate constantly. `refine` moves contour points onto the true offset curve instead.
struct Footprint: Sendable {
    private let tris: [(V2, V2, V2)]
    private let bins: [[Int32]]
    private let origin: V2
    private let cell: Double
    private let nx: Int, ny: Int

    /// With `minZ`, only the parts of triangles at or above that height count: the footprint of the material standing
    /// above that level. Triangles crossing `minZ` are clipped there; a sloped or filleted wall would otherwise count
    /// as material all the way down to its foot, and the offset taken from it would be too far from the real wall.
    init(mesh: Mesh, minZ: Double = -.infinity, cell: Double = 4) {
        var t: [(V2, V2, V2)] = []
        t.reserveCapacity(mesh.triangles.count)
        var lo = V2(repeating: .infinity), hi = V2(repeating: -.infinity)
        func add(_ a: V2, _ b: V2, _ c: V2) {
            guard a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite, c.x.isFinite, c.y.isFinite else { return }
            t.append((a, b, c))
            lo = simd_min(lo, simd_min(a, simd_min(b, c)))
            hi = simd_max(hi, simd_max(a, simd_max(b, c)))
        }
        for tri in mesh.triangles {
            let v = [tri.a, tri.b, tri.c].map { V3(Double($0.x), Double($0.y), Double($0.z)) }
            if minZ > -.infinity, v.allSatisfy({ $0.z < minZ }) { continue }
            if minZ == -.infinity || v.allSatisfy({ $0.z >= minZ }) {
                add(v[0].xy, v[1].xy, v[2].xy)
                continue
            }
            // Clip the triangle to z >= minZ (Sutherland-Hodgman against one plane): 3 or 4 vertices.
            var poly: [V2] = []
            for i in 0..<3 {
                let p = v[i], q = v[(i + 1) % 3]
                if p.z >= minZ { poly.append(p.xy) }
                if (p.z >= minZ) != (q.z >= minZ) {
                    let s = (minZ - p.z) / (q.z - p.z)
                    poly.append((p + (q - p) * s).xy)
                }
            }
            if poly.count >= 3 { add(poly[0], poly[1], poly[2]) }
            if poly.count == 4 { add(poly[0], poly[2], poly[3]) }
        }
        tris = t
        if t.isEmpty { lo = .zero; hi = .zero }
        // Keep the bin count bounded for very large stock.
        let size = hi - lo
        let c = max(cell, max(size.x, size.y) / 2000)
        self.cell = c
        origin = lo
        nx = max(1, Int(size.x / c) + 1)
        ny = max(1, Int(size.y / c) + 1)
        var b = [[Int32]](repeating: [], count: nx * ny)
        for (i, (p, q, r)) in t.enumerated() {
            let mn = simd_min(p, simd_min(q, r)), mx = simd_max(p, simd_max(q, r))
            let x0 = Int((mn.x - lo.x) / c), x1 = Int((mx.x - lo.x) / c)
            let y0 = Int((mn.y - lo.y) / c), y1 = Int((mx.y - lo.y) / c)
            for y in max(0, y0)...min(ny - 1, y1) {
                for x in max(0, x0)...min(nx - 1, x1) { b[y * nx + x].append(Int32(i)) }
            }
        }
        bins = b
    }

    /// Nearest footprint point to `p` among triangles within `radius`, or nil if none is that close.
    /// Returns distance 0 (and `p` itself) when `p` lies inside the footprint.
    func nearest(_ p: V2, within radius: Double) -> (dist: Double, point: V2)? {
        let x0 = max(0, Int((p.x - radius - origin.x) / cell)), x1 = min(nx - 1, Int((p.x + radius - origin.x) / cell))
        let y0 = max(0, Int((p.y - radius - origin.y) / cell)), y1 = min(ny - 1, Int((p.y + radius - origin.y) / cell))
        guard x0 <= x1, y0 <= y1 else { return nil }
        var best = radius * radius
        var bestPoint: V2? = nil
        for y in y0...y1 {
            for x in x0...x1 {
                for i in bins[y * nx + x] {
                    let (a, b, c) = tris[Int(i)]
                    if Footprint.inside(p, a, b, c) { return (0, p) }
                    for (u, v) in [(a, b), (b, c), (c, a)] {
                        let q = Footprint.closest(p, u, v)
                        let d2 = simd_distance_squared(p, q)
                        if d2 < best { best = d2; bestPoint = q }
                    }
                }
            }
        }
        return bestPoint.map { (best.squareRoot(), $0) }
    }

    /// Moves each point of a contour traced at `level` mm from the footprint onto the exact offset curve.
    /// Points that would move further than `maxShift` (the grid's own error bound), or to a place `accept` rejects,
    /// are left where they are.
    func refine(_ loop: Loop, level r: Double, maxShift: Double, accept: (V2) -> Bool = { _ in true }) -> Loop {
        var out: [V2] = []
        out.reserveCapacity(loop.points.count)
        for p0 in loop.points {
            var p = p0
            var ok = false
            for _ in 0..<6 {
                guard let (d, q) = nearest(p, within: r + 2 * maxShift), d > 1e-9 else { break }
                if abs(d - r) < 1e-5 { ok = true; break }
                p = q + (p - q) * (r / d)
            }
            if !ok, let (d, _) = nearest(p, within: r + 2 * maxShift) { ok = d >= r - 1e-4 }
            if !ok || simd_distance(p, p0) > maxShift || (p != p0 && !accept(p)) { p = p0 }
            if let last = out.last, simd_distance(last, p) < 1e-4 { continue }
            out.append(p)
        }
        // Points near a sharp inside corner can land on either side of it and fold back; drop any that reverse direction.
        var changed = true
        while changed && out.count > 4 {
            changed = false
            var kept: [V2] = []
            kept.reserveCapacity(out.count)
            let n = out.count
            for i in 0..<n {
                let prev = kept.last ?? out[(i + n - 1) % n], next = out[(i + 1) % n], p = out[i]
                if simd_dot(p - prev, next - p) < 0 { changed = true; continue }
                kept.append(p)
            }
            out = kept
        }
        return out.count >= 3 ? Loop(out) : loop
    }

    static func inside(_ p: V2, _ a: V2, _ b: V2, _ c: V2) -> Bool {
        func cross(_ u: V2, _ v: V2) -> Double { u.x * v.y - u.y * v.x }
        let area = cross(b - a, c - a)
        if abs(area) < 1e-12 { return false }  // a vertical wall projects to a line: its edges cover it
        let s = area > 0 ? 1.0 : -1.0
        return s * cross(b - a, p - a) > 0 && s * cross(c - b, p - b) > 0 && s * cross(a - c, p - c) > 0
    }

    static func closest(_ p: V2, _ a: V2, _ b: V2) -> V2 {
        let ab = b - a
        let l2 = simd_length_squared(ab)
        if l2 < 1e-18 { return a }
        return a + ab * max(0, min(1, simd_dot(p - a, ab) / l2))
    }
}

/// Exact XY clearance for a cutter of any shape at one tip height.
///
/// A flat end mill at tip height z must stay its radius away from all material standing above z. A ball, bull nose or
/// V-bit is narrower near its tip, so it may come closer to material that is only a little above z. The cutter is
/// split into height bands: for the band from δ_k to δ_k+1 above the tip, the material above z + δ_k must stay at
/// least the cutter's radius at δ_k+1 away (its widest in that band). That bound can only err away from the part, so a
/// point that satisfies every band is gouge-free; for vertical walls it is exact. A shank wider than the cutter adds
/// one more band from the top of the flutes.
struct ToolFootprint: Sendable {
    /// `full`: the band where the cutter has its full radius (or the shank). Only there is a touching band exact; a
    /// lower band touching means sloped material, where it is merely conservative.
    let slices: [(fp: Footprint, r: Double, full: Bool)]

    /// `leaveXY` widens the cutter, `leaveZ` raises the material (stock to leave).
    init(mesh: Mesh, tool: Tool, tipZ z: Double, leaveXY: Double, leaveZ: Double, bands: Int = 6) {
        var out: [(Footprint, Double, Bool)] = []
        let R = tool.radius
        // Height above the tip where the cutter reaches its full radius.
        let full = tool.profileOffset(at: R) ?? 0
        // The lowest band starts just above the tip so a floor at tip height doesn't count; higher bands start just
        // below their nominal height (taking in slightly more material is always safe), so a wall whose top is exactly
        // at a band boundary still meets the band that touches it with its full width.
        let lift = 0.01 - leaveZ, under = -0.01 - leaveZ
        if full <= 1e-6 {
            out.append((Footprint(mesh: mesh, minZ: z + lift), R + leaveXY, true))
        } else {
            let n = max(1, bands)
            for k in 0..<n {
                let lo = full * Double(k) / Double(n), hi = full * Double(k + 1) / Double(n)
                out.append((Footprint(mesh: mesh, minZ: z + lo + (k == 0 ? lift : under)), tool.cuttingRadius(depth: hi) + leaveXY, false))
            }
            out.append((Footprint(mesh: mesh, minZ: z + full + under), R + leaveXY, true))
        }
        if tool.hasWideShank {
            out.append((Footprint(mesh: mesh, minZ: z + tool.fluteLength + under), tool.shankDiameter / 2 + leaveXY, true))
        }
        slices = out
    }

    var reach: Double { slices.map(\.r).max() ?? 0 }

    /// Clearance of a cutter centred at `p`, widened by `extra`: the smallest (distance − required radius) over all
    /// bands. Negative means it would cut the part. Capped at `cap` when nothing is within reach.
    func margin(_ p: V2, extra: Double, cap: Double = 1) -> Double {
        var m = cap
        for s in slices {
            let need = s.r + extra
            if let d = s.fp.nearest(p, within: need + cap)?.dist { m = min(m, d - need) }
        }
        return m
    }

    /// True when `p` is on the exact offset (within 1 µm), i.e. a band touches and none is violated.
    func isExact(_ p: V2, extra: Double) -> Bool { abs(margin(p, extra: extra)) < 1e-3 }

    /// One point moved onto the exact offset curve (clearance 0 at `extra`), or `p0` itself if it would move further
    /// than `maxShift`, end up violating a band, land where `accept` rejects, or is held by a partial band (sloped
    /// material: the grid contour of the exact cutter dilation is closer there).
    func refinePoint(_ p0: V2, extra: Double, maxShift: Double, accept: (V2) -> Bool = { _ in true }) -> V2 {
        var p = p0
        var ok = false, held = false
        for _ in 0..<8 {
            // The band that binds here: smallest clearance.
            var best = Double.infinity, bestQ: V2? = nil, bestNeed = 0.0, bestD = 0.0, bestFull = false
            for s in slices {
                let need = s.r + extra
                guard let (d, q) = s.fp.nearest(p, within: need + 2 * maxShift) else { continue }
                // Ties go to the full band: on a vertical wall every band sees the same distance.
                if d - need < best - 1e-7 || (s.full && d - need < best + 1e-7) {
                    best = d - need; bestQ = q; bestNeed = need; bestD = d; bestFull = s.full
                }
            }
            guard let q = bestQ, bestD > 1e-9 else { break }
            guard bestFull else { held = true; break }
            if abs(best) < 1e-5 { ok = true; break }
            p = q + (p - q) * (bestNeed / bestD)
        }
        if !ok && !held { ok = margin(p, extra: extra) >= -1e-4 }
        if !ok || simd_distance(p, p0) > maxShift || (p != p0 && !accept(p)) { return p0 }
        return p
    }

    /// Drops moved points that reverse direction: near a sharp inside corner they can land on either side of it.
    /// The grid's own points stay, so callers that filter point by point see the same contour.
    static func dropFoldBacks(_ pts: [V2], moved: [Bool], closed: Bool) -> [V2] {
        var out = pts, moved = moved
        var changed = true
        while changed && out.count > 4 {
            changed = false
            var kept: [V2] = [], keptMoved: [Bool] = []
            kept.reserveCapacity(out.count)
            let n = out.count
            for i in 0..<n {
                guard closed || (i > 0 && i < n - 1) else { kept.append(out[i]); keptMoved.append(moved[i]); continue }
                let prev = kept.last ?? out[(i + n - 1) % n], next = out[(i + 1) % n], p = out[i]
                if moved[i] && simd_dot(p - prev, next - p) < 0 { changed = true; continue }
                kept.append(p); keptMoved.append(moved[i])
            }
            out = kept; moved = keptMoved
        }
        return out
    }

    /// `refinePoint` over a closed contour.
    func refine(_ loop: Loop, extra: Double, maxShift: Double, accept: (V2) -> Bool = { _ in true }) -> Loop {
        var out: [V2] = [], moved: [Bool] = []
        out.reserveCapacity(loop.points.count)
        for p0 in loop.points {
            let p = refinePoint(p0, extra: extra, maxShift: maxShift, accept: accept)
            if p != p0, let last = out.last, simd_distance(last, p) < 1e-4 { continue }
            out.append(p)
            moved.append(p != p0)
        }
        guard moved.contains(true) else { return loop }
        out = Self.dropFoldBacks(out, moved: moved, closed: true)
        return out.count >= 3 ? Loop(out) : loop
    }
}
