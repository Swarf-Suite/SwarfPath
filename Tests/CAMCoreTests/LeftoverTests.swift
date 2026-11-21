import Foundation
import Testing
import simd
@testable import CAMCore

/// "Only what's left" (`Operation.cutsLeftoverOnly`) and running over holes a drill will make (`ignoresDrilledHoles`).
@Suite struct LeftoverTests {
    let lib = ToolLibrary.starter
    var flat6: Tool { lib.closest(kind: .flat, diameter: 6)! }

    func simulate(_ tps: [Toolpath], _ ctx: CAMContext) -> StockSimulator.Analysis {
        var sim = StockSimulator(stockSize: ctx.placed.stockSize, resolution: 0.25)
        sim.run(tps)
        return sim.analyze(model: ctx.placed, tolerance: 0.1)
    }

    func cuts(_ tp: Toolpath) -> [V3] { tp.moves.filter { $0.kind != .rapid }.map(\.to) }

    /// Points every 0.25 mm along the cutting moves.
    func cutSamples(_ tp: Toolpath) -> [V3] {
        var out: [V3] = []
        var at = V3.zero
        for m in tp.moves {
            defer { at = m.to }
            guard m.kind != .rapid else { continue }
            let n = max(1, Int(simd_distance(at, m.to) / 0.25))
            for k in 1...n { out.append(at + (m.to - at) * Double(k) / Double(n)) }
        }
        return out
    }

    /// The drill plate under 2 mm of extra stock.
    func plateJob(_ ops: [CAMCore.Operation]) -> Job {
        var j = Job()
        j.quality = .draft
        j.stock.extraTop = 2
        j.operations = ops
        return j
    }

    /// A pocket that ignores drilled holes runs straight over the Ø6 holes the drill makes, still clears the Ø10 one
    /// nothing drills, and the two together don't gouge.
    @Test func pocketRunsOverHolesTheDrillMakes() throws {
        var pocket = CAMCore.Operation(kind: .pocket, tool: flat6)
        pocket.ignoresDrilledHoles = true
        var drill = CAMCore.Operation(kind: .drill, tool: flat6)
        drill.drillSettings.diameterTolerance = 0.3
        let ctx = CAMContext(raw: DrillTests.plate(), job: plateJob([pocket, drill]))
        let tpPocket = try ctx.generate(pocket), tpDrill = try ctx.generate(drill)
        let o = ctx.placed.modelBounds.min.xy
        let rim = ctx.stockTop - 2
        // Over a hole it ignores the pocket passes straight across at the rim; around one it doesn't, it rings it.
        let over = { (tp: Toolpath, c: V2, r: Double) in self.cutSamples(tp).filter { simd_distance($0.xy - o, c) < r }.map(\.z) }
        for c in [V2(10, 10), V2(30, 10)] {
            let zs = over(tpPocket, c, 2)
            #expect(!zs.isEmpty, "no pass over the hole at \(c)")
            #expect(zs.allSatisfy { $0 > rim - 0.15 }, "pass dips into the hole at \(c)")
        }
        #expect(over(tpPocket, V2(50, 10), 3).isEmpty, "the Ø10 hole isn't drilled, so the pocket goes round it")
        var plain = pocket
        plain.ignoresDrilledHoles = false
        #expect(over(try ctx.generate(plain), V2(10, 10), 2).isEmpty)
        #expect(!tpDrill.moves.isEmpty)
        #expect(simulate([tpPocket, tpDrill], ctx).gougeCells == 0)
    }

    /// A 2 mm pocket after a 6 mm one, with no rest source named, cuts only what the 6 mm one left.
    @Test func cutsOnlyWhatEarlierOperationsLeft() throws {
        let big = CAMCore.Operation(kind: .pocket, tool: lib.tools[0])
        var small = ToolLibrary.smallFlats[0]
        small.shankDiameter = small.diameter
        small.fluteLength = 20
        var rest = CAMCore.Operation(kind: .pocket, tool: small)
        rest.cutsLeftoverOnly = true
        let full = CAMCore.Operation(kind: .pocket, tool: small)
        var job = Job()
        job.quality = .draft
        job.operations = [big, rest]
        let ctx = CAMContext(raw: RestMachiningTests.cavityPlate(), job: job)
        let tpBig = try ctx.generate(big), tpRest = try ctx.generate(rest), tpFull = try ctx.generate(full)
        let before = simulate([tpBig], ctx), after = simulate([tpBig, tpRest], ctx)
        #expect(after.gougeCells == 0)
        #expect(Double(after.leftoverCells) < Double(before.leftoverCells) * 0.2, "leftover \(before.leftoverCells) → \(after.leftoverCells)")
        let restLen = tpRest.stats(rapidRate: 5000, acceleration: 500).cutLength
        let fullLen = tpFull.stats(rapidRate: 5000, acceleration: 500).cutLength
        #expect(restLen < fullLen * 0.25, "rest \(restLen) mm vs full \(fullLen) mm")
        // First in the job: nothing before it, so it cuts everything.
        var first = rest
        first.id = UUID()
        job.operations = [first]
        let alone = CAMContext(raw: RestMachiningTests.cavityPlate(), job: job)
        #expect(alone.priorStock(first) == nil)
    }

    /// A drill after a facing pass starts pecking at the faced surface, not the old stock top.
    @Test func drillStartsOnTheSurfaceLeft() throws {
        var face = CAMCore.Operation(kind: .facing, tool: flat6)
        face.facingDepth = 2
        var drill = CAMCore.Operation(kind: .drill, tool: flat6)
        drill.cutsLeftoverOnly = true
        drill.drillSettings.diameterTolerance = 0.3
        let ctx = CAMContext(raw: DrillTests.plate(), job: plateJob([face, drill]))
        let hole = ctx.detectHoles().min { $0.center.x < $1.center.x }!
        let start = ctx.drillStart(drill, at: hole.center)
        #expect(abs(start - (ctx.stockTop - 2)) < 0.15, "starts at \(start), stock top \(ctx.stockTop)")
        var plain = drill
        plain.cutsLeftoverOnly = false
        #expect(ctx.drillStart(plain, at: hole.center) == ctx.stockTop)
        #expect(simulate([try ctx.generate(face), try ctx.generate(drill)], ctx).gougeCells == 0)
    }

    /// Full Processing drills the holes it has a bit for, runs everything else over them, and each later step only
    /// takes what's left.
    @Test func fullProcessingDrillsAndLinksUp() throws {
        let ctx = CAMContext(raw: DrillTests.plate(), job: plateJob([]))
        let ops = JobTemplates.fullProcessing(ctx, library: lib, material: .named("mdf"))
        let drills = ops.filter { $0.kind == .drill }
        #expect(!drills.isEmpty)
        for (i, op) in ops.enumerated() where op.kind.supportsRest || op.kind == .drill {
            if op.kind.supportsRest { #expect(op.ignoresDrilledHoles, "\(op.name)") }
            if i > 0 && op.restFromOp == nil && op.restFrom == nil { #expect(op.cutsLeftoverOnly, "\(op.name)") }
        }
        let run = CAMContext(raw: DrillTests.plate(), job: plateJob(ops))
        let tps = try ops.filter(\.enabled).map { try run.generate($0) }
        #expect(simulate(tps, run).gougeCells == 0)
    }

    @Test func offByDefaultAndOldProjectsStillOpen() throws {
        var op = CAMCore.Operation(kind: .pocket, tool: flat6)
        #expect(!op.cutsLeftoverOnly && !op.ignoresDrilledHoles)
        op.cutsLeftoverOnly = true
        op.ignoresDrilledHoles = true
        let back = try JSONDecoder().decode(CAMCore.Operation.self, from: JSONEncoder().encode(op))
        #expect(back.cutsLeftoverOnly && back.ignoresDrilledHoles)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(op)) as! [String: Any]
        json.removeValue(forKey: "restFromEarlier")
        json.removeValue(forKey: "leaveHolesToDrill")
        let old = try JSONDecoder().decode(CAMCore.Operation.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!old.cutsLeftoverOnly && !old.ignoresDrilledHoles)
    }
}
