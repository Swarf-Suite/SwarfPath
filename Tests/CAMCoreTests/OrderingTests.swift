import Foundation
import Testing
@testable import CAMCore

@Suite struct OrderingTests {
    let flat = ToolLibrary.starter.tools[0]
    let ball = ToolLibrary.starter.closest(kind: .ball, diameter: 6)!
    let hog = HoggingTests.hog
    let mdf = Material.named("mdf")

    func names(_ ops: [CAMCore.Operation]) -> [String] { ops.map(\.name) }
    func op(_ kind: OperationKind, _ tool: Tool, _ name: String) -> CAMCore.Operation {
        var o = CAMCore.Operation(kind: kind, tool: tool, material: mdf)
        o.name = name
        return o
    }

    /// Pockets and a cutout added one at a time (hog, flat, hog, flat): grouped into hog then flat, one bit change.
    @Test func groupsHoggingWork() {
        let ops = JobTemplates.pockets(flat: flat, hog: hog, material: mdf) + JobTemplates.cutouts(flat: flat, hog: hog, material: mdf)
        #expect(JobTemplates.toolChanges(ops) == 3)
        let o = JobTemplates.orderedForFewestToolChanges(ops)
        #expect(names(o) == ["Pockets (hogging)", "Cutout (hogging)", "Pockets (finish)", "Cutout"])
        #expect(JobTemplates.toolChanges(o) == 1)
        // Already the best order: nothing moves.
        #expect(JobTemplates.orderedForFewestToolChanges(o).map(\.id) == o.map(\.id))
    }

    /// Curved top plus pockets added later: the hogging pocket joins the roughing, and the finishes still come after
    /// everything that clears their area.
    @Test func curvedTopWithPocketsAddedLater() {
        let rough = op(.roughing, hog, "Rough")
        let par = op(.parallelFinish, ball, "Parallel"), wl = op(.waterlineFinish, ball, "Waterline")
        let pockets = JobTemplates.pockets(flat: flat, hog: hog, material: mdf)
        let cut = JobTemplates.cutouts(flat: flat, hog: hog, material: mdf)
        let ops = [rough, par, wl] + pockets + cut
        let o = JobTemplates.orderedForFewestToolChanges(ops)
        #expect(names(o) == ["Rough", "Pockets (hogging)", "Cutout (hogging)", "Parallel", "Waterline", "Pockets (finish)", "Cutout"])
        #expect(JobTemplates.toolChanges(o) == 2)
    }

    /// The rules win over fewer bit changes.
    @Test func safetyRulesHold() {
        // A ball finish listed before the roughing it needs moves after it, even though that costs nothing here.
        let par = op(.parallelFinish, ball, "Parallel")
        let rough = op(.roughing, flat, "Rough")
        let cut = op(.cutout, flat, "Cutout")
        #expect(names(JobTemplates.orderedForFewestToolChanges([par, rough, cut])) == ["Rough", "Parallel", "Cutout"])
        // Facing stays first; the through cutout stays last, even with the same tool as the facing.
        let face = op(.facing, flat, "Face")
        let drill = op(.drill, ball, "Drill")
        let o = JobTemplates.orderedForFewestToolChanges([face, drill, op(.vcarve, ball, "V"), cut])
        #expect(o.first?.name == "Face" && o.last?.name == "Cutout")
        // A rest pass never runs before what it follows.
        var big = op(.pocket, flat, "Big")
        big.tool.id = UUID()
        var small = op(.pocket, ball, "Small")
        small.restFromOp = big.id
        let other = op(.drill, ball, "Holes")
        let r = names(JobTemplates.orderedForFewestToolChanges([other, big, small]))
        #expect(r.firstIndex(of: "Big")! < r.firstIndex(of: "Small")!)
    }

    /// Two-sided jobs: dowels, side A, side B stay in that order; each side is grouped on its own.
    @Test func flipStagesKeepTheirOrder() {
        var dowels = op(.dowelHoles, flat, "Dowels")
        dowels.machiningSide = .a
        var backHog = op(.pocket, hog, "Back hog"); backHog.machiningSide = .b
        var backFin = JobTemplates.finishing(after: backHog, with: flat, material: mdf); backFin.name = "Back fin"
        let front = JobTemplates.pockets(flat: flat, hog: hog, material: mdf) + JobTemplates.cutouts(flat: flat, hog: hog, material: mdf)
        let o = JobTemplates.orderedForFewestToolChanges([backHog, backFin] + front + [dowels])
        #expect(o.map(\.flipStage) == [.dowels, .sideA, .sideA, .sideA, .sideA, .sideB, .sideB])
        #expect(names(o) == ["Dowels", "Pockets (hogging)", "Cutout (hogging)", "Pockets (finish)", "Cutout", "Back hog", "Back fin"])
    }

    /// The reordered hog-and-finish job still cuts cleanly: every pass's reference comes first and nothing is gouged.
    @Test func reorderedJobSimulatesClean() throws {
        var job = Job()
        job.quality = .draft
        let mesh = RestMachiningTests.cavityPlate()
        job.operations = JobTemplates.orderedForFewestToolChanges(
            JobTemplates.pockets(flat: flat, hog: hog, material: mdf) + JobTemplates.cutouts(flat: flat, hog: hog, material: mdf))
        let ctx = CAMContext(raw: mesh, job: job)
        for o in job.operations where o.restFromOp != nil { #expect(ctx.restReference(o) != nil, "\(o.name)") }
        let tps = try job.operations.map { try ctx.generate($0) }
        var sim = StockSimulator(stockSize: ctx.placed.stockSize, resolution: 0.25)
        sim.run(tps)
        #expect(sim.analyze(model: ctx.placed, tolerance: 0.1).gougeCells == 0)
        let post = PostProcessor(profile: .foxalienXEProUltra, origin: ctx.placed.originPoint(job.origin), safeZ: ctx.safeZ,
                                 jobName: "Order", stockSize: ctx.placed.stockSize)
        #expect(post.process(tps).count == 2)
    }
}
