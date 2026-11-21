import Foundation
import Testing
import simd
@testable import CAMCore

/// Auto Plan picks the bits for the part from the library, adds smaller ones only where needed, and orders the
/// result for the fewest bit changes.
@Suite struct AutoPlanTests {
    let lib = ToolLibrary.starter
    let hardwood = Material.named("hardwood")

    func context(_ mesh: Mesh) -> CAMContext {
        var job = Job()
        job.quality = .draft
        job.stock.extraTop = 2
        return CAMContext(raw: mesh, job: job)
    }

    func run(_ plan: AutoPlan, _ mesh: Mesh) throws -> (CAMContext, [Toolpath]) {
        var job = context(mesh).job
        job.operations = plan.operations
        let ctx = CAMContext(raw: mesh, job: job)
        return (ctx, try plan.operations.filter(\.enabled).map { try ctx.generate($0) })
    }

    func simulate(_ tps: [Toolpath], _ ctx: CAMContext) -> StockSimulator.Analysis {
        var sim = StockSimulator(stockSize: ctx.placed.stockSize, resolution: 0.25)
        sim.run(tps)
        return sim.analyze(model: ctx.placed, tolerance: 0.1)
    }

    /// The neck blank with a 5 mm truss-rod slot: the biggest flat clears it, a 1/8" bit follows only for the slot,
    /// and between them they leave the slot clean without gouging anything.
    @Test func theSlotGetsASmallerBit() throws {
        let mesh = AreaOperationTests.slottedBoard()
        let plan = context(mesh).autoPlan(library: lib, material: hardwood)
        let clearing = try #require(plan.operations.first { $0.kind == .pocket && $0.restFrom == nil })
        let biggest = lib.tools.filter { $0.kind == .flat }.map(\.diameter).max()!
        #expect(clearing.tool.diameter == biggest)
        let rest = try #require(plan.operations.first { $0.kind == .pocket && $0.restFromOp == clearing.id })
        #expect(rest.tool.diameter < 5, "rest bit Ø\(rest.tool.diameter)")
        #expect(plan.reasons[rest.id]?.contains("can't reach") == true)
        // The cutout comes last, and each bit's work is together.
        #expect(plan.operations.last?.kind == .cutout)
        #expect(plan.toolChanges == plan.bits.count - 1, "\(plan.operations.map { "\($0.name) T\($0.tool.number)" })")

        let (ctx, tps) = try run(plan, mesh)
        let a = simulate(tps, ctx)
        #expect(a.gougeCells == 0, "max gouge \(a.maxGouge)")
        let s = AreaOperationTests()
        #expect(s.leftInSlot(a, ctx) < 0.5, "slot left \(s.leftInSlot(a, ctx)) mm")
    }

    /// A plain board with nothing narrow: no rest pass.
    @Test func noSmallBitWhenNothingNeedsIt() {
        let mesh = FinishDirectionTests.heightSolid(w: 100, d: 60, step: 1) { x, y in
            x > 20 && x < 80 && y > 15 && y < 45 ? 12 : 20
        }
        let plan = context(mesh).autoPlan(library: lib, material: hardwood)
        #expect(!plan.operations.contains { $0.restFromOp != nil && $0.kind == .pocket })
    }

    /// Without a bit small enough, the plan says so rather than leaving the slot without a word.
    @Test func saysWhatItCantReach() {
        var big = ToolLibrary(tools: lib.tools.filter { $0.kind != .flat || $0.diameter >= 6 })
        big.tools.removeAll { $0.kind == .roughing }
        let plan = context(AreaOperationTests.slottedBoard()).autoPlan(library: big, material: hardwood)
        #expect(!plan.operations.contains { $0.restFromOp != nil && $0.kind == .pocket })
        #expect(plan.notes.contains { $0.contains("narrower than the smallest bit") }, "\(plan.notes)")
    }

    /// A carved top with a cove tighter than the big ball nose: a smaller ball follows it.
    @Test func tightCurvesGetASmallerBall() throws {
        let mesh = FinishDirectionTests.heightSolid(w: 80, d: 40) { x, y in
            let r = 2.5, dx = abs(x - 40)
            let dome = 20 - 0.002 * ((x - 40) * (x - 40) + (y - 20) * (y - 20))
            return dx >= r ? dome : min(dome, dome + 1 - (r * r - dx * dx).squareRoot())
        }
        let plan = context(mesh).autoPlan(library: lib, material: hardwood)
        let fin = try #require(plan.operations.first { $0.kind == .parallelFinish && $0.restFrom == nil })
        let rest = try #require(plan.operations.first { $0.kind == .parallelFinish && $0.restFromOp == fin.id })
        #expect(rest.tool.diameter < fin.tool.diameter)
        #expect(rest.tool.kind == .ball)
        // One rest roughing at most, and no complaint about curves a flat can't reach.
        #expect(plan.operations.filter { $0.kind == .roughing && $0.restFrom != nil }.count <= 1)
        #expect(plan.notes.isEmpty, "\(plan.notes)")
    }
}
