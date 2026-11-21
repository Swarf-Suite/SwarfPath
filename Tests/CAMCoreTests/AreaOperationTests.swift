import Foundation
import Testing
import simd
@testable import CAMCore

/// Operations limited to an area of their own: a neck blank roughed with a 6 mm bit, and a truss-rod slot too narrow
/// for it cut by a 1/8" bit limited to a box drawn over the slot.
@Suite struct AreaOperationTests {
    let lib = ToolLibrary.starter

    /// A 120 × 50 board 20 mm thick (in stock 2 mm thicker) with a slot 5 mm wide and 10 mm deep along X, from x = 20 to 100.
    static func slottedBoard() -> Mesh {
        FinishDirectionTests.heightSolid(w: 120, d: 50, step: 0.5) { x, y in
            x >= 20 && x <= 100 && y >= 22.5 && y <= 27.5 ? 10 : 20
        }
    }

    struct Setup {
        var job: Job
        var rough: CAMCore.Operation
        var slot: CAMCore.Operation
        var area: Region
        var ctx: CAMContext { CAMContext(raw: AreaOperationTests.slottedBoard(), job: job) }
    }

    func setup() -> Setup {
        var job = Job()
        job.quality = .draft
        job.stock.extraTop = 2  // something for the roughing to take off the whole board
        let base = CAMContext(raw: Self.slottedBoard(), job: job).placed.modelBounds.min
        let o = V2(base.x, base.y)
        var area = Region(name: "Truss rod", kind: .machineOnly, min: o + V2(18, 20), max: o + V2(102, 30))
        area.area = true
        var rough = CAMCore.Operation(kind: .roughing, tool: lib.tools[0])
        rough.stockToLeaveXY = 0; rough.stockToLeaveZ = 0
        var slot = CAMCore.Operation(kind: .pocket, tool: lib.tools[1])
        slot.stockToLeaveXY = 0; slot.stockToLeaveZ = 0
        slot.areaID = area.id
        job.regions = [area]
        job.operations = [rough, slot]
        return Setup(job: job, rough: rough, slot: slot, area: area)
    }

    func feedPoints(_ tp: Toolpath) -> [V3] { tp.moves.filter { $0.kind == .feed }.map(\.to) }

    func simulate(_ tps: [Toolpath], _ ctx: CAMContext) -> StockSimulator.Analysis {
        var sim = StockSimulator(stockSize: ctx.placed.stockSize, resolution: 0.25)
        sim.run(tps)
        return sim.analyze(model: ctx.placed, tolerance: 0.1)
    }

    /// Material left in the middle of the slot: cells along its centre line, away from the ends.
    func leftInSlot(_ a: StockSimulator.Analysis, _ ctx: CAMContext) -> Float {
        let g = StockSimulator(stockSize: ctx.placed.stockSize, resolution: 0.25).stock
        let m = ctx.placed.modelBounds.min
        var worst: Float = 0
        for y in 0..<g.height {
            for x in 0..<g.width {
                let p = g.world(x, y) - V2(m.x, m.y)
                guard p.x > 30, p.x < 90, abs(p.y - 25) < 1 else { continue }
                let d = a.deviation[y * g.width + x]
                if d.isFinite { worst = max(worst, d) }
            }
        }
        return worst
    }

    @Test func theSlotIsCutOnlyInsideItsArea() throws {
        let s = setup()
        let ctx = s.ctx
        let tpRough = try ctx.generate(s.rough), tpSlot = try ctx.generate(s.slot)

        // The 1/8" bit stays inside the box; the roughing isn't limited by it.
        let pts = feedPoints(tpSlot)
        #expect(!pts.isEmpty)
        #expect(pts.allSatisfy { s.area.contains($0.xy, inflate: 0.3) }, "a slot move left its area")
        #expect(feedPoints(tpRough).contains { !s.area.contains($0.xy, inflate: 5) })

        // The 6 mm bit can't get into the 5 mm slot; the 1/8" one clears it, and nothing gouges.
        let rough = simulate([tpRough], ctx)
        #expect(leftInSlot(rough, ctx) > 5, "roughing reached into the slot")
        let both = simulate([tpRough, tpSlot], ctx)
        #expect(both.gougeCells == 0, "max gouge \(both.maxGouge)")
        #expect(leftInSlot(both, ctx) < 0.5, "slot left \(leftInSlot(both, ctx)) mm")
    }

    /// An area only limits the operations given it, even an operation whose own region list names it.
    @Test func otherOperationsIgnoreAreas() {
        var s = setup()
        s.rough.regionIDs = [s.area.id]
        s.job.operations[0] = s.rough
        let ctx = s.ctx
        #expect(ctx.regions(for: s.rough).isEmpty)
        #expect(ctx.regions(for: s.slot).map(\.id) == [s.area.id])
        #expect(ctx.regions(for: s.slot)[0].kind == .machineOnly)
    }

    /// Without its area the operation would cut the whole part with the small bit: refuse instead.
    @Test func aMissingOrDisabledAreaIsRefused() {
        var s = setup()
        s.job.regions[0].enabled = false
        #expect(throws: CAMError.self) { try s.ctx.generate(s.slot) }
        s.job.regions = []
        #expect(throws: CAMError.self) { try s.ctx.generate(s.slot) }
        // An ordinary region with that id isn't an area either.
        var r = s.area
        r.area = nil
        r.kind = .keepOut
        s.job.regions = [r]
        #expect(throws: CAMError.self) { try s.ctx.generate(s.slot) }
    }

    @Test func theFinishAfterAHogKeepsTheArea() {
        let s = setup()
        let fin = JobTemplates.finishing(after: s.slot, with: lib.tools[3], material: .named("hardwood"))
        #expect(fin.areaID == s.area.id)
    }

    /// Projects saved before areas existed: no area on any operation, and no region is one.
    @Test func olderProjectsHaveNoAreas() throws {
        let s = setup()
        var op = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s.slot)) as! [String: Any]
        #expect(op["areaID"] != nil)
        op.removeValue(forKey: "areaID")
        #expect(try JSONDecoder().decode(CAMCore.Operation.self, from: JSONSerialization.data(withJSONObject: op)).areaID == nil)
        var r = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s.area)) as! [String: Any]
        #expect(r["area"] as? Bool == true)
        r.removeValue(forKey: "area")
        #expect(!(try JSONDecoder().decode(Region.self, from: JSONSerialization.data(withJSONObject: r)).isArea))
    }

    /// The header says in words where Z zero is, as Fretboard Modeller's files do, so KerfLine can show it.
    @Test func theHeaderSaysWhereZZeroIs() throws {
        let s = setup()
        let ctx = s.ctx
        let tp = try ctx.generate(s.slot)
        func header(_ z: WorkOrigin.ZAnchor, testCut: TestCut? = nil) -> String {
            var o = s.job.origin
            o.z = z
            let post = PostProcessor(profile: .grbl, origin: ctx.placed.originPoint(o), safeZ: ctx.safeZ, jobName: "neck",
                                     stockSize: ctx.placed.stockSize, testCut: testCut)
            return post.process([tp])[0].content
        }
        #expect(header(.stockTop).contains("Z0 = TOP of stock"))
        #expect(header(.stockBottom).contains("Z0 = SPOILBOARD surface"))
        let test = { var t = TestCut(); t.enabled = true; return t }()
        #expect(header(.stockTop, testCut: test).contains("Z0 = TOP of the test board"))
        // A test cut zeroed on the bed says so: the coordinates really are from the bed.
        #expect(header(.stockBottom, testCut: test).contains("Z0 = SPOILBOARD surface"))
    }
}
