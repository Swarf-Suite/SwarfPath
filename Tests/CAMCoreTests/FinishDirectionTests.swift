import Foundation
import Testing
import simd
@testable import CAMCore

@Suite struct FinishDirectionTests {
    let lib = ToolLibrary.starter

    /// A closed solid whose top is z = f(x, y) over [0, w] × [0, d], sampled every `step` mm.
    static func heightSolid(w: Double, d: Double, step: Double = 0.5, _ f: (Double, Double) -> Double) -> Mesh {
        let nx = Int((w / step).rounded()), ny = Int((d / step).rounded())
        func top(_ i: Int, _ j: Int) -> SIMD3<Float> {
            let x = Double(i) * w / Double(nx), y = Double(j) * d / Double(ny)
            return SIMD3(Float(x), Float(y), Float(f(x, y)))
        }
        func bot(_ i: Int, _ j: Int) -> SIMD3<Float> { var p = top(i, j); p.z = 0; return p }
        var t: [Triangle] = []
        for j in 0..<ny {
            for i in 0..<nx {
                let a = top(i, j), b = top(i + 1, j), c = top(i + 1, j + 1), e = top(i, j + 1)
                t.append(Triangle(a, b, c)); t.append(Triangle(a, c, e))
            }
        }
        // Sides (outward), then the bottom.
        for i in 0..<nx {
            t.append(Triangle(bot(i, 0), bot(i + 1, 0), top(i + 1, 0))); t.append(Triangle(bot(i, 0), top(i + 1, 0), top(i, 0)))
            t.append(Triangle(bot(i + 1, ny), bot(i, ny), top(i, ny))); t.append(Triangle(bot(i + 1, ny), top(i, ny), top(i + 1, ny)))
        }
        for j in 0..<ny {
            t.append(Triangle(bot(0, j + 1), bot(0, j), top(0, j))); t.append(Triangle(bot(0, j + 1), top(0, j), top(0, j + 1)))
            t.append(Triangle(bot(nx, j), bot(nx, j + 1), top(nx, j + 1))); t.append(Triangle(bot(nx, j), top(nx, j + 1), top(nx, j)))
        }
        let o = SIMD3<Float>(0, 0, 0), wx = SIMD3<Float>(Float(w), 0, 0), wy = SIMD3<Float>(0, Float(d), 0)
        t.append(Triangle(o, wx + wy, wx)); t.append(Triangle(o, wy, wx + wy))
        return Mesh(triangles: t)
    }

    /// Fretboard face (z = 20) curving down to a headstock face (z = 8) between x = 40 and 55, straight across Y: the
    /// transition of a Fender-style neck lying along X. The bottom of the curve is concave with a radius of about 3.8 mm.
    static func neckTransition(alongY: Bool = false) -> Mesh {
        func profile(_ s: Double) -> Double {
            s < 40 ? 20 : s > 55 ? 8 : 8 + 6 * (1 + cos(.pi * (s - 40) / 15))
        }
        return alongY ? heightSolid(w: 40, d: 90) { _, y in profile(y) } : heightSolid(w: 90, d: 40) { x, _ in profile(x) }
    }

    /// A 20 mm thick board with a round-bottomed cove across it (along Y), 5 mm deep with a 6 mm radius: a valley a
    /// 1/4" end mill is too flat to reach the bottom of, but a 1/8" one gets much lower.
    static func cove() -> Mesh {
        heightSolid(w: 80, d: 40) { x, _ in
            let r = 6.0, dx = abs(x - 40)
            return dx >= r ? 20 : min(20, 21 - (r * r - dx * dx).squareRoot())
        }
    }

    func job(_ ops: [CAMCore.Operation]) -> Job {
        var j = Job()
        j.quality = .draft
        j.operations = ops
        return j
    }

    func finish(_ tool: Tool) -> CAMCore.Operation {
        var p = CAMCore.Operation(kind: .parallelFinish, tool: tool)
        p.rasterAngle = 45
        return p
    }

    /// The target surface is rasterised conservatively (to the nearest cell), so on a steep wall a coarse grid reads as a
    /// gouge of up to half a cell times the slope: the cove's walls need a finer one.
    func simulate(_ tps: [Toolpath], _ ctx: CAMContext, resolution: Double = 0.25) -> StockSimulator.Analysis {
        var sim = StockSimulator(stockSize: ctx.placed.stockSize, resolution: resolution)
        sim.run(tps)
        return sim.analyze(model: ctx.placed, tolerance: 0.1)
    }

    /// The direction of the cutting moves that change XY, as an axial angle 0…180°, weighted by length.
    func mainDirection(_ tp: Toolpath) -> Double {
        var sx = 0.0, sy = 0.0
        var p = tp.start
        for m in tp.moves {
            defer { p = m.to }
            guard m.kind == .feed else { continue }
            let d = m.to.xy - p.xy, l = simd_length(d)
            guard l > 1e-6 else { continue }
            let a = 2 * atan2(d.y, d.x)
            sx += l * cos(a); sy += l * sin(a)
        }
        var a = atan2(sy, sx) / 2 * 180 / .pi
        if a < 0 { a += 180 }
        return a
    }

    @Test func newParallelFinishesAreAutomatic() {
        #expect(CAMCore.Operation(kind: .parallelFinish, tool: lib.tools[4]).rasterIsAuto)
        #expect(!CAMCore.Operation(kind: .waterlineFinish, tool: lib.tools[4]).rasterIsAuto)
    }

    /// Projects saved before the setting existed keep their angle.
    @Test func olderProjectsKeepTheirAngle() throws {
        var op = CAMCore.Operation(kind: .parallelFinish, tool: lib.tools[4])
        op.rasterAngle = 30
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(op)) as! [String: Any]
        #expect(json["autoRaster"] as? Bool == true)
        json.removeValue(forKey: "autoRaster")
        let old = try JSONDecoder().decode(CAMCore.Operation.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.autoRaster == nil)
        #expect(!old.rasterIsAuto)
        let ctx = CAMContext(raw: Self.neckTransition(), job: job([old]))
        #expect(ctx.rasterChoice(old).angle == 30)
        #expect(!ctx.rasterChoice(old).automatic)
    }

    /// The neck transition is cut along X with an end mill or a ball nose, and along Y when the neck lies along Y.
    @Test(arguments: [false, true]) func passesFollowTheCurve(alongY: Bool) throws {
        for tool in [lib.tools[2], lib.tools[5]] {
            let op = finish(tool)
            let ctx = CAMContext(raw: Self.neckTransition(alongY: alongY), job: job([op]))
            let c = ctx.rasterChoice(op)
            #expect(c.automatic)
            #expect(c.angle == (alongY ? 90 : 0), "\(tool.name): \(c.angle)° — \(c.reason)")
            let tp = try ctx.generate(op)
            let dir = mainDirection(tp)
            let off = alongY ? abs(dir - 90) : min(dir, 180 - dir)
            #expect(off < 5, "\(tool.name): moves run at \(dir)°")
            #expect(tp.notes.contains { $0.contains(alongY ? "along Y" : "along X") })
        }
    }

    /// No best direction on a dome or a flat top: the set angle is used, and the note says why.
    @Test func domesAndFlatsUseTheSetAngle() {
        let op = finish(lib.tools[5])
        let dome = CAMContext(raw: STL.dome(radius: 30, segments: 96, rings: 48), job: job([op]))
        let d = dome.rasterChoice(op)
        #expect(d.angle == 45, "\(d.reason)")
        #expect(d.reason.contains("dome"))
        let flat = CAMContext(raw: STL.box(V3(60, 40, 15)), job: job([op]))
        let f = flat.rasterChoice(op)
        #expect(f.angle == 45, "\(f.reason)")
        #expect(f.reason.contains("flat"))
    }

    /// A diagonal ridge (a ruled surface at 30°) gets passes across the ridge.
    @Test func diagonalRidge() {
        let n = V2(cos(.pi / 6), sin(.pi / 6))
        let mesh = Self.heightSolid(w: 80, d: 80) { x, y in
            let s = simd_dot(V2(x, y) - V2(40, 40), n)
            return 10 + 8 * cos(min(1, abs(s) / 25) * .pi / 2)
        }
        let op = finish(lib.tools[5])
        let ctx = CAMContext(raw: mesh, job: job([op]))
        let c = ctx.rasterChoice(op)
        #expect(abs(c.angle - 30) <= 2, "\(c.angle)° — \(c.reason)")
    }

    /// Rough with a 1/8" end mill, finish with a 1/4" end mill: the finish can't get as low as the roughing bit in the
    /// cove, so roughing stays higher there (only there), the finish then takes everything roughing left (no shelving), and
    /// nothing gouges. The finish says where its flat cutter is too big for the curve.
    @Test func roughingLeavesEnoughForTheFinish() throws {
        var rough = CAMCore.Operation(kind: .roughing, tool: lib.tools[1])
        rough.stockToLeaveXY = 0.3; rough.stockToLeaveZ = 0.3
        var fin = finish(lib.tools[2])
        fin.stockToLeaveXY = 0; fin.stockToLeaveZ = 0
        let ctx = CAMContext(raw: Self.cove(), job: job([rough, fin]))
        let c = try #require(ctx.roughingCleanup(rough))
        #expect(c.extra > 0.3, "extra \(c.extra)")
        #expect(c.finish.id == fin.id)
        // Only in and beside the cove (12 mm wide, 40 long), not over the whole 80 x 40 board.
        #expect(c.area < 25 * 40, "area \(c.area)")

        let tpRough = try ctx.generate(rough), tpFin = try ctx.generate(fin)
        #expect(tpRough.notes.contains { $0.contains("higher") })
        #expect(tpFin.warnings.contains { $0.contains("concave") })
        let after = simulate([tpRough, tpFin], ctx, resolution: 0.1)
        #expect(after.gougeCells == 0, "max gouge \(after.maxGouge)")

        // Shelving: anywhere the finish's own surface sits above what roughing left, roughing steps survive. Compare
        // the simulated stock with the finish alone on fresh stock: they must match wherever the finish cut.
        let alone = simulate([tpFin], ctx, resolution: 0.1)
        var shelves = 0
        for i in after.deviation.indices where after.deviation[i].isFinite && alone.deviation[i].isFinite && alone.deviation[i] < 1 {
            if alone.deviation[i] - after.deviation[i] > 0.05 { shelves += 1 }
        }
        #expect(shelves == 0, "\(shelves) cells where roughing left the surface below the finish")
    }

    /// Without the extra, the same set-up would leave shelves: the check above isn't trivially true.
    @Test func withoutTheExtraRoughingShelves() throws {
        var rough = CAMCore.Operation(kind: .roughing, tool: lib.tools[1])
        rough.stockToLeaveXY = 0.3; rough.stockToLeaveZ = 0.3
        var fin = finish(lib.tools[2])
        fin.stockToLeaveXY = 0; fin.stockToLeaveZ = 0
        let ctx = CAMContext(raw: Self.cove(), job: job([rough, fin]))
        // Generate the roughing as it would be without later finishes.
        let bare = CAMContext(raw: Self.cove(), job: job([rough]))
        #expect(bare.roughingCleanup(rough) == nil)
        let tpRough = try bare.generate(rough), tpFin = try ctx.generate(fin)
        let after = simulate([tpRough, tpFin], ctx, resolution: 0.1), alone = simulate([tpFin], ctx, resolution: 0.1)
        var shelves = 0
        for i in after.deviation.indices where after.deviation[i].isFinite && alone.deviation[i].isFinite && alone.deviation[i] < 1 {
            if alone.deviation[i] - after.deviation[i] > 0.05 { shelves += 1 }
        }
        #expect(shelves > 0)
    }

    /// A ball-nose finish after an end-mill roughing with the usual stock needs no extra, and doesn't gouge.
    @Test func usualRoughingNeedsNoExtra() throws {
        let rough = CAMCore.Operation(kind: .roughing, tool: lib.tools[0])
        let fin = finish(lib.tools[4])
        let ctx = CAMContext(raw: Self.neckTransition(), job: job([rough, fin]))
        #expect(ctx.roughingCleanup(rough) == nil)
        let a = simulate([try ctx.generate(rough), try ctx.generate(fin)], ctx)
        #expect(a.gougeCells == 0, "max gouge \(a.maxGouge)")
    }
}
