import Foundation
import Testing
import simd
@testable import CAMCore

/// Pockets that run past the part's open edges (`Operation.runsPastOpenEdges`), and slots the cutter only just fits
/// (`narrowSlotPasses`).
@Suite struct EdgeAndSlotTests {
    let lib = ToolLibrary.starter
    var flat6: Tool { lib.closest(kind: .flat, diameter: 6)! }

    func run(_ tps: [Toolpath], _ ctx: CAMContext) -> (StockSimulator, StockSimulator.Analysis) {
        var sim = StockSimulator(stockSize: ctx.placed.stockSize, resolution: 0.25)
        sim.run(tps)
        return (sim, sim.analyze(model: ctx.placed, tolerance: 0.1))
    }

    /// A 60 × 40 block 10 mm tall with its left half standing 10 mm higher: the right half's face is open on three sides.
    static func step() -> Mesh {
        STL.merge([STL.box(V3(60, 40, 10)), STL.box(V3(30, 40, 10), at: V3(0, 0, 10))])
    }

    /// The low face is cleared right to its open edges, and outside the part nothing goes below it.
    @Test func pocketCutsFacesRightToTheirOpenEdges() throws {
        let pocket = CAMCore.Operation(kind: .pocket, tool: flat6)
        #expect(pocket.runsPastOpenEdges, "new pockets run past open edges")
        var job = Job()
        job.quality = .normal
        job.operations = [pocket]
        let ctx = CAMContext(raw: Self.step(), job: job)
        let o = ctx.placed.modelBounds.min.xy
        // Points on the low face (z 10) half a millimetre in from its three open edges.
        let edge = [V2(59.5, 20), V2(45, 0.5), V2(45, 39.5), V2(59.5, 0.5)].map { $0 + o }
        let (sim, a) = run([try ctx.generate(pocket)], ctx)
        #expect(a.gougeCells == 0)
        for p in edge { #expect(sim.stock.nearest(p) <= 10.1, "material left at the edge, \(p - o)") }
        // Outside the part nothing goes below the face it continues.
        for x in stride(from: -4.0, through: 64, by: 0.5) {
            for y in stride(from: -4.0, through: 44, by: 0.5) where x < 0 || y < 0 || x > 60 || y > 40 {
                let q = o + V2(x, y)
                guard q.x >= 0, q.y >= 0, q.x <= ctx.placed.stockSize.x, q.y <= ctx.placed.stockSize.y else { continue }
                #expect(sim.stock.nearest(q) >= 9.9, "cut below the face outside the part at \(x), \(y)")
            }
        }
    }

    /// Past the edge of a face lower than the cutout's tabs, the pocket stays above the tabs (tab height + 1 mm).
    @Test func neverCutsAwayTheTabs() throws {
        let pocket = CAMCore.Operation(kind: .pocket, tool: flat6)
        let cutout = CAMCore.Operation(kind: .cutout, tool: flat6)
        var job = Job()
        job.quality = .normal
        job.operations = [pocket, cutout]
        // A 2 mm plate with a 15 mm block on its left: the plate's face is open on three sides and below the tabs.
        let part = STL.merge([STL.box(V3(50, 30, 2)), STL.box(V3(20, 30, 15), at: V3(0, 0, 2))])
        let ctx = CAMContext(raw: part, job: job)
        let floor = ctx.edgeOverrunFloor(pocket)
        #expect(floor >= cutout.tabs.height + 1 - 1e-9)
        let (sim, a) = run([try ctx.generate(pocket)], ctx)
        #expect(a.gougeCells == 0)
        let o = ctx.placed.modelBounds.min.xy
        let s = ctx.placed.stockSize
        for x in stride(from: -4.0, through: 54, by: 0.5) {
            for y in stride(from: -4.0, through: 34, by: 0.5) where x < -0.3 || y < -0.3 || x > 50.3 || y > 30.3 {
                let q = o + V2(x, y)
                guard q.x >= 0, q.y >= 0, q.x <= s.x, q.y <= s.y else { continue }
                #expect(sim.stock.nearest(q) >= Float(floor) - 0.05, "cut into the tab zone at \(x), \(y)")
            }
        }
    }

    /// A plate 16 mm thick with a slot 6.2 mm wide and 8 mm deep along X: the 6 mm end mill cuts it at Normal quality,
    /// where the grid alone can't fit it, without touching the walls.
    @Test func sixMillCutsSixPointTwoSlot() throws {
        let w = 6.2
        let plate = STL.merge([
            STL.box(V3(80, 40, 8)),
            STL.box(V3(80, (40 - w) / 2, 8), at: V3(0, 0, 8)),
            STL.box(V3(80, (40 - w) / 2, 8), at: V3(0, (40 + w) / 2, 8)),
        ])
        // Close the slot's ends so it is a slot, not an open channel.
        let ends = STL.merge([plate, STL.box(V3(10, w, 8), at: V3(0, (40 - w) / 2, 8)), STL.box(V3(10, w, 8), at: V3(70, (40 - w) / 2, 8))])
        let pocket = CAMCore.Operation(kind: .pocket, tool: flat6)
        var job = Job()
        job.quality = .normal
        job.operations = [pocket]
        let ctx = CAMContext(raw: ends, job: job)
        let tp = try ctx.generate(pocket)
        let (sim, a) = run([tp], ctx)
        #expect(a.gougeCells == 0)
        let o = ctx.placed.modelBounds.min.xy
        for x in stride(from: 15.0, through: 65, by: 5) {
            #expect(sim.stock.nearest(o + V2(x, 20)) <= 8.1, "slot not cut at x \(x)")
        }
        // Inside the slot the cutter stays within its 0.1 mm clearance either side of the centre line.
        let inSlot = tp.moves.filter { $0.kind == .feed && $0.to.z < 15.9 && abs($0.to.x - o.x - 40) < 20 }
        #expect(!inSlot.isEmpty)
        #expect(inSlot.allSatisfy { abs($0.to.y - o.y - 20) <= (w - 6) / 2 + 1e-3 })
    }

    @Test func oldProjectsDecodeWithoutTheEdgeSetting() throws {
        var op = CAMCore.Operation(kind: .pocket, tool: flat6)
        op.runsPastOpenEdges = true
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(op)) as! [String: Any]
        #expect(json["pastOpenEdges"] as? Bool == true)
        json.removeValue(forKey: "pastOpenEdges")
        let old = try JSONDecoder().decode(CAMCore.Operation.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!old.runsPastOpenEdges)
    }
}
