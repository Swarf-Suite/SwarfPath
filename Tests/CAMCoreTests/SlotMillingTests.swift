import Foundation
import Testing
import simd
@testable import CAMCore

/// The slot operation (`OperationKind.slot`): slots the cutter fits exactly, cut down their centre line.
@Suite struct SlotMillingTests {
    let lib = ToolLibrary.starter
    var flat6: Tool { lib.closest(kind: .flat, diameter: 6)! }
    func flat(_ d: Double) -> Tool {
        var t = flat6
        t.id = UUID()
        t.name = String(format: "%g mm Flat", d)
        t.diameter = d
        t.shankDiameter = d
        return t
    }

    func run(_ tps: [Toolpath], _ ctx: CAMContext) -> (StockSimulator, StockSimulator.Analysis) {
        var sim = StockSimulator(stockSize: ctx.placed.stockSize, resolution: 0.25)
        sim.run(tps)
        return (sim, sim.analyze(model: ctx.placed, tolerance: 0.1))
    }

    /// An 80 × 40 plate 16 mm thick with a slot `w` wide and 8 mm deep along X, its ends closed (x 10…70).
    static func slotted(_ w: Double) -> Mesh {
        STL.merge([
            STL.box(V3(80, 40, 8)),
            STL.box(V3(80, (40 - w) / 2, 8), at: V3(0, 0, 8)),
            STL.box(V3(80, (40 - w) / 2, 8), at: V3(0, (40 + w) / 2, 8)),
            STL.box(V3(10, w, 8), at: V3(0, (40 - w) / 2, 8)),
            STL.box(V3(10, w, 8), at: V3(70, (40 - w) / 2, 8)),
        ])
    }

    func context(_ mesh: Mesh, _ ops: [CAMCore.Operation]) -> CAMContext {
        var job = Job()
        job.quality = .normal
        job.operations = ops
        return CAMContext(raw: mesh, job: job)
    }

    /// Exact-width slots: 4 mm with a 4 mm bit and 6 mm with a 6 mm bit, cut to the floor end to end on the centre line.
    @Test(arguments: [4.0, 6.0]) func cutsASlotItsOwnWidth(_ d: Double) throws {
        let op = CAMCore.Operation(kind: .slot, tool: flat(d))
        let ctx = context(Self.slotted(d), [op])
        let tp = try ctx.generate(op)
        let (sim, a) = run([tp], ctx)
        #expect(a.gougeCells == 0)
        let o = ctx.placed.modelBounds.min.xy
        for x in stride(from: 10 + d / 2, through: 70 - d / 2, by: 2) {
            #expect(sim.stock.nearest(o + V2(x, 20)) <= 8.1, "slot not cut at x \(x)")
        }
        let cuts = tp.moves.filter { $0.kind != .rapid && $0.to.z < 15.99 }
        #expect(!cuts.isEmpty)
        #expect(cuts.allSatisfy { abs($0.to.y - o.y - 20) <= 0.02 }, "off the centre line")
        #expect(cuts.allSatisfy { $0.to.z >= 8 - 1e-6 })
    }

    /// A slot 0.25 mm wider than the bit gets a pass along each wall, so it is cut to its own width.
    @Test func cutsASlightlyWiderSlotToWidth() throws {
        let w = 4.25
        let op = CAMCore.Operation(kind: .slot, tool: flat(4))
        let ctx = context(Self.slotted(w), [op])
        let tp = try ctx.generate(op)
        let (sim, a) = run([tp], ctx)
        #expect(a.gougeCells == 0)
        let o = ctx.placed.modelBounds.min.xy
        let ys = tp.moves.filter { $0.kind == .feed && abs($0.to.z - 8) < 1e-6 }.map { $0.to.y - o.y - 20 }
        #expect((ys.max() ?? 0) > 0.1 && (ys.min() ?? 0) < -0.1, "no wall passes")
        // The walls' foot is clear within a few hundredths.
        for x in stride(from: 15.0, through: 65, by: 5) {
            for dy in [-1.9, 0, 1.9] { #expect(sim.stock.nearest(o + V2(x, 20 + dy)) <= 8.1, "left at \(x), \(dy)") }
        }
    }

    /// Slots of other widths are left alone: a 4 mm bit never touches a 6 mm slot, and can't fit a 3.8 mm one.
    @Test(arguments: [6.0, 3.8]) func leavesOtherWidthsAlone(_ w: Double) throws {
        let op = CAMCore.Operation(kind: .slot, tool: flat(4))
        let ctx = context(Self.slotted(w), [op])
        let tp = try ctx.generate(op)
        #expect(!tp.moves.contains { $0.kind != .rapid && $0.to.z < ctx.stockTop - 0.01 })
        #expect(tp.warnings.contains { $0.hasPrefix("No slots") })
    }

    /// The pocket's own bit cuts a slot exactly its width (a 6.0 mm slot with a 6 mm end mill).
    @Test func pocketCutsAnExactWidthSlot() throws {
        let pocket = CAMCore.Operation(kind: .pocket, tool: flat6)
        let ctx = context(Self.slotted(6), [pocket])
        let (sim, a) = run([try ctx.generate(pocket)], ctx)
        #expect(a.gougeCells == 0)
        let o = ctx.placed.modelBounds.min.xy
        for x in stride(from: 15.0, through: 65, by: 5) {
            #expect(sim.stock.nearest(o + V2(x, 20)) <= 8.1, "slot not cut at x \(x)")
        }
    }

    /// Full Processing adds a slot operation for a slot only a smaller library bit fits, after the pockets, cutting only
    /// what they left; together they leave the slot cut with no gouges.
    @Test func fullProcessingAddsSlotsForSmallerBits() throws {
        var library = ToolLibrary(tools: [flat6, flat(4)])
        library.tools[1].number = 2
        let ctx = context(Self.slotted(4), [])
        let ops = JobTemplates.fullProcessing(ctx, library: library, material: .named("mdf"))
        let slots = ops.filter { $0.kind == .slot }
        #expect(slots.count == 1)
        guard let s = slots.first else { return }
        #expect(s.tool.diameter == 4)
        #expect(s.cutsLeftoverOnly)
        let si = ops.firstIndex { $0.id == s.id }!
        #expect(ops.firstIndex { $0.kind == .pocket }! < si)
        #expect(ops.firstIndex { $0.kind == .cutout }! > si)
        // Run everything but the cutout.
        var job = ctx.job
        job.operations = ops.filter { $0.kind != .cutout }
        let full = CAMContext(raw: Self.slotted(4), job: job)
        let tps = try job.operations.map { try full.generate($0) }
        let (sim, a) = run(tps, full)
        #expect(a.gougeCells == 0)
        let o = full.placed.modelBounds.min.xy
        for x in stride(from: 15.0, through: 65, by: 5) {
            #expect(sim.stock.nearest(o + V2(x, 20)) <= 8.1, "slot not cut at x \(x)")
        }
        // And no slot operation when the library has no bit that fits.
        let none = JobTemplates.fullProcessing(context(Self.slotted(5), []), library: library, material: .named("mdf"))
        #expect(!none.contains { $0.kind == .slot })
    }

    /// Full Processing finishes the curved patches of a pocketed part with the pocket's flat end mill.
    @Test func curveFinishUsesTheFlat() throws {
        // A plate with a small dome on it: pockets, plus a curved patch.
        let part = STL.merge([STL.box(V3(80, 60, 6)), STL.dome(radius: 4, center: V2(40, 30)).translated(V3(0, 0, 6))])
        let ctx = context(part, [])
        let ops = JobTemplates.fullProcessing(ctx, library: lib, material: .named("mdf"))
        let fin = ops.filter { $0.name == "Finish (curves)" }
        #expect(fin.count == 1)
        let pocketTool = ops.first { $0.kind == .pocket }?.tool.id
        #expect(fin.allSatisfy { $0.tool.kind == .flat && $0.tool.id == pocketTool })
    }

    @Test func oldProjectsDecodeWithoutSlotSettings() throws {
        var op = CAMCore.Operation(kind: .slot, tool: flat(4))
        op.slotting = nil
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(op)) as! [String: Any]
        #expect(json["slotting"] == nil)
        let old = try JSONDecoder().decode(CAMCore.Operation.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.slotSettings == SlotSettings())
    }
}
