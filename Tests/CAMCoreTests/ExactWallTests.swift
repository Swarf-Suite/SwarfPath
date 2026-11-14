import Foundation
import Testing
@testable import CAMCore

/// Walls cut by pockets, 3D roughing and waterline sit on the exact model wall for every cutter shape, not on the grid.
@Suite struct ExactWallTests {
    let lib = ToolLibrary.starter

    /// 40 × 30 plate with a 24 × 14 pocket 12 mm deep (floor z = 3, top z = 15); the odd margin puts the walls between
    /// grid nodes.
    static let mesh = STL.merge([
        STL.box(V3(40, 30, 3)),
        STL.box(V3(40, 8, 12), at: V3(0, 0, 3)), STL.box(V3(40, 8, 12), at: V3(0, 22, 3)),
        STL.box(V3(8, 14, 12), at: V3(0, 8, 3)), STL.box(V3(8, 14, 12), at: V3(32, 8, 3)),
    ])

    func context(_ op: CAMCore.Operation) -> CAMContext {
        var job = Job()
        job.quality = .draft
        job.stock.marginXY = 5.137
        job.operations = [op]
        return CAMContext(raw: Self.mesh, job: job)
    }

    /// Per flat level inside the pocket: the extreme X and Y the tool centre reaches.
    func extents(_ tp: Toolpath, _ ctx: CAMContext) -> [Double: (Double, Double, Double, Double)] {
        let o = ctx.placed.modelBounds.min
        var levels: [Double: (Double, Double, Double, Double)] = [:]
        var prev = tp.start
        for m in tp.moves {
            defer { prev = m.to }
            guard m.kind != .rapid, m.to.z < ctx.stockTop - 0.5, abs(m.to.z - prev.z) < 1e-6 else { continue }
            let p = m.to.xy - o.xy
            guard p.x > 8, p.x < 32, p.y > 8, p.y < 22 else { continue }
            let z = (m.to.z * 1000).rounded() / 1000
            let e = levels[z] ?? (.infinity, -.infinity, .infinity, -.infinity)
            levels[z] = (min(e.0, m.to.x), max(e.1, m.to.x), min(e.2, m.to.y), max(e.3, m.to.y))
        }
        return levels
    }

    /// Walls at `offset` from the pocket's walls on every level at least a cutter radius below the top (higher up a
    /// ball or bull nose touches the wall with less than its full radius), and nothing gouged.
    func expectExact(_ op: CAMCore.Operation, offset: Double, _ comment: String) throws {
        let ctx = context(op)
        let tp = try ctx.generate(op)
        let o = ctx.placed.modelBounds.min
        let want = (x0: o.x + 8 + offset, x1: o.x + 32 - offset, y0: o.y + 8 + offset, y1: o.y + 22 - offset)
        let top = o.z + 15
        let levels = extents(tp, ctx).filter { $0.key <= top - op.tool.radius - op.stockToLeaveZ + 1e-6 }
        #expect(levels.count >= 3, "\(comment): \(levels.count) levels")
        for (z, e) in levels {
            let err = max(abs(e.0 - want.x0), abs(e.1 - want.x1), abs(e.2 - want.y0), abs(e.3 - want.y1))
            #expect(err < 0.02, "\(comment) at z \(z): walls off by \(err) mm")
        }
        var sim = StockSimulator(stockSize: ctx.placed.stockSize, resolution: 0.1)
        sim.run([tp])
        #expect(sim.analyze(model: ctx.placed, tolerance: 0.05).gougeCells == 0, "\(comment) gouges")
    }

    @Test func ballAndBullNosePocketWallsAreExact() throws {
        for kind in [ToolKind.ball, .bullNose] {
            let tool = try #require(lib.closest(kind: kind, diameter: 6))
            var op = CAMCore.Operation(kind: .pocket, tool: tool)
            op.boundary = .insideSilhouette
            try expectExact(op, offset: tool.radius, "\(kind) pocket")
        }
    }

    @Test func roughingWallsAreExact() throws {
        for kind in [ToolKind.flat, .ball] {
            let tool = try #require(lib.closest(kind: kind, diameter: 6))
            let op = CAMCore.Operation(kind: .roughing, tool: tool)
            try expectExact(op, offset: tool.radius + op.stockToLeaveXY, "\(kind) roughing")
        }
    }

    @Test func waterlineWallsAreExact() throws {
        let ball = try #require(lib.closest(kind: .ball, diameter: 6))
        var op = CAMCore.Operation(kind: .waterlineFinish, tool: ball)
        op.cutting.stepdown = 1
        try expectExact(op, offset: ball.radius, "waterline")
    }

    /// A V-bit carving a 10 mm wide recess: down the middle, the cone's edge reaches both sides of the recess exactly.
    @Test func vcarveRecessDepthIsExact() throws {
        // 60 × 40 × 20 plate with a recess 10.137 mm wide, 30 long and 12 deep.
        let w = 10.137
        let mesh = STL.merge([
            STL.box(V3(60, 40, 8)),
            STL.box(V3(60, 15, 12), at: V3(0, 0, 8)), STL.box(V3(60, 40 - 15 - w, 12), at: V3(0, 15 + w, 8)),
            STL.box(V3(15, w, 12), at: V3(0, 15, 8)), STL.box(V3(15, w, 12), at: V3(45, 15, 8)),
        ])
        var job = Job()
        job.quality = .draft
        let vbit = try #require(lib.tools.first { $0.kind == .vBit && abs($0.vAngle - 60) < 1 })
        var op = CAMCore.Operation(kind: .vcarve, tool: vbit)
        op.vcarveSettings.source = .recesses
        job.operations = [op]
        let ctx = CAMContext(raw: mesh, job: job)
        let tp = try ctx.generate(op)
        let tanHalf = tan(vbit.vAngle / 2 * .pi / 180), tipR = vbit.tipDiameter / 2
        let o = ctx.placed.modelBounds.min
        // Along the straight middle of the recess, every cutting point's depth matches the true distance to the nearer
        // wall (the path may sit a fraction of a cell off the centre line; the depth must follow where it really is).
        var checked = 0
        var prev = tp.start
        for m in tp.moves {
            defer { prev = m.to }
            guard m.kind != .rapid else { continue }
            for k in 0...20 {
                let q = prev + (m.to - prev) * (Double(k) / 20)
                let p = q.xy - o.xy
                guard p.x > 22, p.x < 38, p.y > 15.5, p.y < 15 + w - 0.5, q.z < ctx.stockTop - 0.5 else { continue }
                let want = (min(p.y - 15, 15 + w - p.y) - tipR) / tanHalf
                let depth = ctx.stockTop - q.z
                #expect(depth < want + 0.02, "at \(p): depth \(depth), wall allows \(want)")
                if depth > want - 0.02 { checked += 1 }  // the final pass is on the wall
            }
        }
        #expect(checked >= 10)
        let ideal = (w / 2 - tipR) / tanHalf
        let deepest = ctx.stockTop - (tp.moves.map(\.to.z).min() ?? ctx.stockTop)
        #expect(deepest <= ideal + 1e-6 && deepest > ideal - 0.25, "deepest \(deepest) mm, ideal \(ideal)")
        var sim = StockSimulator(stockSize: ctx.placed.stockSize, resolution: 0.1)
        sim.run([tp])
        #expect(sim.analyze(model: ctx.placed, tolerance: 0.05).gougeCells == 0)
    }

    /// The bands never let a narrow-tipped cutter closer than its real shape allows.
    @Test func bandsAreConservative() {
        let ball = lib.closest(kind: .ball, diameter: 6)!
        // A single wall standing 1 mm above the tip: a ball touches it with radius sqrt(1 × 5).
        let wall = STL.box(V3(10, 10, 1), at: V3(0, 0, 0))
        let tf = ToolFootprint(mesh: wall, tool: ball, tipZ: 0, leaveXY: 0, leaveZ: 0)
        let exact = (1.0 * (2 * ball.radius - 1)).squareRoot()
        let p = V2(10 + exact, 5)
        #expect(tf.margin(p, extra: 0) <= 1e-9)  // never optimistic
        #expect(tf.margin(V2(10 + ball.radius, 5), extra: 0) >= -1e-9)  // a full radius is always clear
    }
}
