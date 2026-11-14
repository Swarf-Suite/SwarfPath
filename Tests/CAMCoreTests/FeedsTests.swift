import Foundation
import Testing
@testable import CAMCore

@Suite struct FeedsCalculatorTests {
    /// A ball cutting shallower than its radius cuts with a smaller circle: the feed goes up by D / Deff, the real chip
    /// stays on target, and the operation's own check agrees.
    @Test func shallowBallNoseFeedsFaster() throws {
        let ball = try #require(ToolLibrary.starter.closest(kind: .ball, diameter: 6))
        let mdf = Material.named("mdf")
        var r = FeedsCalculator.Request(tool: ball, material: mdf, machine: .foxalienXEProUltra)
        r.maxFeed = 50000  // keep the machine cap out of it
        let full = FeedsCalculator.calculate(r)
        r.axialDepth = 0.5
        let shallow = FeedsCalculator.calculate(r)
        let deff = 2 * (0.5 * 5.5).squareRoot()
        #expect(abs(shallow.effectiveDiameter - deff) < 1e-9 && full.effectiveDiameter == 6)
        #expect(abs(shallow.thinning - 6 / deff) < 1e-9)
        #expect(abs(shallow.feed / full.feed - 6 / deff) < 0.02)
        #expect(abs(shallow.chipLoad - full.chipLoad) < full.chipLoad * 0.02)
        // At or below the ball's radius nothing changes; a flat ignores depth.
        r.axialDepth = 3
        #expect(FeedsCalculator.calculate(r).feed == full.feed)
        var f = FeedsCalculator.Request(tool: ToolLibrary.starter.tools[0], material: mdf, machine: .foxalienXEProUltra)
        let flat0 = FeedsCalculator.calculate(f)
        f.axialDepth = 0.5
        #expect(FeedsCalculator.calculate(f) == flat0)
        // The faster feed doesn't trip the chip-load warning on a parallel finish (about 0.5 mm deep)...
        var op = Operation(kind: .parallelFinish, tool: ball)
        op.cutting.rpm = shallow.rpm; op.cutting.feed = shallow.feed
        #expect(op.typicalAxialDepth == 0.5)
        let ok = FeedsAndSpeeds.check(tool: ball, data: op.cutting, material: mdf, axialDepth: op.typicalAxialDepth)
        #expect(!ok.warnings.contains { $0.contains("Chip load") }, "\(ok.warnings)")
        // ...but would at full depth.
        let deep = FeedsAndSpeeds.check(tool: ball, data: op.cutting, material: mdf)
        #expect(deep.warnings.contains { $0.contains("high") })
        // Thinning never goes past 3×, even scraping the very tip.
        r.axialDepth = 0.01
        #expect(FeedsCalculator.calculate(r).thinning <= 3 + 1e-9)
    }

    let flat6 = ToolLibrary.starter.closest(kind: .flat, diameter: 6)!
    let mdf = Material.named("mdf")

    func request(_ t: Tool, maxFeed: Double = 100_000) -> FeedsCalculator.Request {
        FeedsCalculator.Request(tool: t, material: mdf, maxFeed: maxFeed, minRPM: 6000, maxRPM: 24000)
    }

    @Test func feedIsRPMTimesFlutesTimesChipLoad() {
        var r = request(flat6)
        r.rpm = 18000
        let out = FeedsCalculator.calculate(r)
        #expect(out.limit == .none)
        #expect(out.rpm == 18000)
        #expect(abs(out.feed - (18000 * Double(flat6.flutes) * out.targetChipLoad / 10).rounded(.down) * 10) < 1e-6)
        #expect(out.range.contains(out.targetChipLoad))
        #expect(abs(out.chipLoad - out.targetChipLoad) < 0.001)
        #expect(out.plunge < out.feed)
        #expect(FeedsCalculator.calculate(request(flat6, maxFeed: 5000)).plunge <= 800)
        var big = flat6
        big.diameter = 12
        #expect(FeedsCalculator.calculate(request(big, maxFeed: 20000)).plunge == FeedsCalculator.maxPlunge)
    }

    /// When the machine's top feed decides, the spindle slows to keep the chip load: same speed, quieter.
    @Test func machineFeedCapSlowsTheSpindle() {
        let out = FeedsCalculator.calculate(request(flat6, maxFeed: 5000))
        #expect(out.feed == 5000)
        #expect(out.limit == .machineFeed)
        #expect(out.rpm < 24000)
        #expect(abs(out.chipLoad - out.targetChipLoad) / out.targetChipLoad < 0.03)

        // With the spindle fixed fast, the chip gets thin and the calculator offers the slower speed.
        var fixed = request(flat6, maxFeed: 5000)
        fixed.rpm = 24000
        let f = FeedsCalculator.calculate(fixed)
        #expect(f.rpm == 24000 && f.feed == 5000)
        #expect(f.chipLoad < f.targetChipLoad)
        #expect(abs((f.quieterRPM ?? 0) - out.rpm) <= 100)
    }

    @Test func spindleCannotGoBelowItsMinimum() {
        var r = request(ToolLibrary.starter.closest(kind: .flat, diameter: 6)!, maxFeed: 300)
        r.target = 1
        let out = FeedsCalculator.calculate(r)
        #expect(out.rpm == 6000)
        #expect(out.limit == .machineFeedAndMinRPM)
        #expect(out.chipLoad < out.targetChipLoad)
    }

    @Test func chipThinningAtLightStepovers() {
        #expect(FeedsCalculator.chipThinning(engagementPercent: 100) == 1)
        #expect(FeedsCalculator.chipThinning(engagementPercent: 50) == 1)
        #expect(abs(FeedsCalculator.chipThinning(engagementPercent: 10) - 1 / (2 * (0.09).squareRoot())) < 1e-9)
        #expect(FeedsCalculator.chipThinning(engagementPercent: 1) == 3)
        var r = request(flat6)
        r.rpm = 12000
        r.engagementPercent = 10
        let thin = FeedsCalculator.calculate(r)
        r.engagementPercent = 100
        let slot = FeedsCalculator.calculate(r)
        #expect(thin.feed > slot.feed * 1.6)
        #expect(abs(thin.chipLoad - slot.chipLoad) < 0.002)
    }

    /// Following the calculator never trips the chip-load warnings, for any material, bit or size.
    @Test func recommendationsPassTheFeedCheck() {
        for m in Material.library {
            for k in ToolKind.allCases {
                for d in [0.5, 0.9, 1, 2, 3.175, 4, 6, 6.35, 8, 10, 12, 16, 25] {
                    for fl in FluteStyle.allCases {
                        for z in [1, 2, 3, 4] {
                            var t = Tool(name: "t", kind: k, diameter: d, flutes: z, fluteLength: max(3, d * 3), defaults: flat6.defaults)
                            t.fluteStyle = fl
                            for target in [0.0, 0.5, 1.0] {
                                var r = FeedsCalculator.Request(tool: t, material: m, maxFeed: 100_000, minRPM: 1000, maxRPM: 24000)
                                r.target = target
                                let out = FeedsCalculator.calculate(r)
                                let data = CuttingData(rpm: out.rpm, feed: out.feed, plunge: out.plunge, stepdown: 0.1, stepoverPercent: 40)
                                let w = FeedsAndSpeeds.check(tool: t, data: data, material: m).warnings.filter { $0.contains("Chip load") }
                                #expect(w.isEmpty, "\(m.id) \(k) Ø\(d) \(fl) z\(z) t\(target): \(w)")
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func biggerBitsAndSofterMaterialsTakeBiggerChips() {
        let small = FeedsCalculator.recommendedRange(tool: ToolLibrary.starter.closest(kind: .flat, diameter: 3.175)!, material: mdf)
        let big = FeedsCalculator.recommendedRange(tool: flat6, material: mdf)
        #expect(small.upperBound < big.upperBound)
        let oak = FeedsCalculator.recommendedRange(tool: flat6, material: .named("hardwood"))
        #expect(oak.upperBound < big.upperBound)
        var down = flat6
        down.fluteStyle = .downcut
        #expect(FeedsCalculator.recommendedRange(tool: down, material: mdf).upperBound < big.upperBound)
    }

    @Test func roughingBitsGetDeeperStepdowns() {
        var hog = flat6
        hog.kind = .roughing
        hog.fluteLength = 22
        #expect(FeedsCalculator.recommendedStepdown(tool: hog, material: mdf) > FeedsCalculator.recommendedStepdown(tool: flat6, material: mdf))
        hog.fluteLength = 2
        #expect(FeedsCalculator.recommendedStepdown(tool: hog, material: mdf) == 2)
    }
}

@Suite struct HoggingTests {
    static let hog: Tool = {
        var t = Tool(number: 20, name: "6 mm corn-cob", kind: .roughing, diameter: 6, flutes: 3, fluteLength: 25, stickout: 35,
                     defaults: CuttingData(rpm: 16000, feed: 2400, plunge: 600, stepdown: 6, stepoverPercent: 45))
        t.fluteStyle = .compression
        return t
    }()

    var library: ToolLibrary {
        var l = ToolLibrary.starter
        l.tools.append(Self.hog)
        return l
    }

    @Test func roughingBitCutsLikeAFlat() {
        #expect(Self.hog.profileOffset(at: 2.9) == 0)
        #expect(Self.hog.profileOffset(at: 3.1) == nil)
        #expect(ToolKind.roughing.cutsFlat && ToolKind.flat.cutsFlat && !ToolKind.ball.cutsFlat)
    }

    @Test func oldLibrariesStillLoadAndNewFieldsRoundTrip() throws {
        let flat = ToolLibrary.starter.tools[0]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(flat)) as! [String: Any]
        #expect(json["flute"] == nil)
        json.removeValue(forKey: "flute")
        let old = try JSONDecoder().decode(Tool.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.fluteStyle == .unspecified)
        let back = try JSONDecoder().decode(Tool.self, from: JSONEncoder().encode(Self.hog))
        #expect(back == Self.hog && back.kind == .roughing && back.fluteStyle == .compression)
        var op = Operation(kind: .pocket, tool: flat)
        #expect(op.restExtraStock == nil)
        op.restLeftStock = 0
        #expect(op.restExtraStock == nil)
    }

    /// Full Processing with a hogging bit: the hogging bit clears the pockets leaving a skin, then the flat finishes
    /// only the skin and the corners. Even if Z is re-zeroed 0.2 mm low for the hogging bit, nothing is gouged.
    @Test func hogThenFinishWithAZReZeroError() throws {
        var job = Job()
        job.quality = .draft
        let mesh = RestMachiningTests.cavityPlate()
        let ops = JobTemplates.fullProcessing(CAMContext(raw: mesh, job: job), library: library, material: .named("mdf"))
        let rough = try #require(ops.first { $0.name == "Pockets (hogging)" })
        let fin = try #require(ops.first { $0.name == "Pockets (finish)" })
        #expect(rough.tool.kind == .roughing && rough.stockToLeaveZ == Operation.hogFloorSkin && rough.stockToLeaveXY == Operation.hogSkin)
        #expect(fin.tool.kind == .flat && fin.restFromOp == rough.id && fin.restLeftStock == 0)
        // All the hogging work, then the finishing bit: one swap. The flat cutout is last.
        #expect(ops.map(\.tool.kind) == [.roughing, .roughing, .flat, .flat])
        #expect(ops.last?.kind == .cutout && ops.last?.restFromOp == ops[1].id && ops[1].kind == .cutout)

        job.operations = [rough, fin]
        let ctx = CAMContext(raw: mesh, job: job)
        let tpRough = try ctx.generate(rough), tpFin = try ctx.generate(fin)
        #expect(!tpRough.warnings.contains { $0.contains("hogging bit") })
        var full = Operation(kind: .pocket, tool: fin.tool)
        full.name = "full"
        let tpFull = try ctx.generate(full)

        func sim(_ tps: [Toolpath]) -> StockSimulator.Analysis {
            var s = StockSimulator(stockSize: ctx.placed.stockSize, resolution: 0.25)
            s.run(tps)
            return s.analyze(model: ctx.placed, tolerance: 0.1)
        }
        let roughOnly = sim([tpRough])
        #expect(roughOnly.gougeCells == 0)
        #expect(roughOnly.leftoverCells > 1000)  // the skin
        let both = sim([tpRough, tpFin])
        #expect(both.gougeCells == 0)
        #expect(both.leftoverCells <= sim([tpFull]).leftoverCells + 20, "finish leaves \(both.leftoverCells)")

        // Hogging bit zeroed 0.2 mm low: it cuts 0.2 mm deeper, still inside the skin.
        var low = tpRough
        low.moves = low.moves.map { var m = $0; m.to.z -= 0.2; return m }
        let lowBoth = sim([low, tpFin])
        #expect(lowBoth.gougeCells == 0)

        // The finish only takes the skin: much less cutting than pocketing it all with the flat.
        let finLen = tpFin.stats(rapidRate: 5000, acceleration: 500).cutLength
        let fullLen = tpFull.stats(rapidRate: 5000, acceleration: 500).cutLength
        #expect(finLen < fullLen * 0.75, "finish \(finLen) vs full \(fullLen)")

        // Separate files for the bit swap.
        let post = PostProcessor(profile: .foxalienXEProUltra, origin: ctx.placed.originPoint(job.origin), safeZ: ctx.safeZ,
                                 jobName: "Hog", stockSize: ctx.placed.stockSize)
        let files = post.process([tpRough, tpFin])
        #expect(files.count == 2)
        #expect(files[0].name.contains("T20") && files[1].name.contains("T\(fin.tool.number)"))
    }

    /// The hogging bit's cutout stops 3 mm above the stock bottom with a skin on the wall; the flat cutout after it cuts
    /// only below that (plus the wall), cuts the part free, and nothing is gouged.
    @Test func hogCutoutThenFlat() throws {
        var job = Job()
        job.quality = .draft
        let mesh = STL.box(V3(60, 40, 18))
        let ops = JobTemplates.cutouts(flat: ToolLibrary.starter.tools[0], hog: Self.hog, material: .named("mdf"))
        #expect(ops.count == 2 && ops[0].tool.kind == .roughing && ops[1].restFromOp == ops[0].id)
        #expect(ops[0].stockToLeaveZ == Operation.hogFloorSkin && ops[0].stockToLeaveXY == Operation.hogSkin)
        job.operations = ops
        let ctx = CAMContext(raw: mesh, job: job)
        let hog = try ctx.generate(ops[0]), flat = try ctx.generate(ops[1])
        #expect(abs((hog.moves.map(\.to.z).min() ?? 0) - Operation.hogFloorSkin) < 1e-6)
        #expect(!hog.warnings.contains { $0.contains("hogging") })
        // The flat's roughing starts where the hog stopped: much less cutting than the whole cutout.
        var plain = ops[1]; plain.restFromOp = nil; plain.restFrom = nil
        let alone = try ctx.generate(plain)
        #expect(flat.stats(rapidRate: 5000, acceleration: 500).cutLength < alone.stats(rapidRate: 5000, acceleration: 500).cutLength * 0.8)
        var sim = StockSimulator(stockSize: ctx.placed.stockSize, resolution: 0.25)
        sim.run([hog, flat])
        let a = sim.analyze(model: ctx.placed, tolerance: 0.1)
        #expect(a.gougeCells == 0)
        var simAlone = StockSimulator(stockSize: ctx.placed.stockSize, resolution: 0.25)
        simAlone.run([alone])
        #expect(a.leftoverCells <= simAlone.analyze(model: ctx.placed, tolerance: 0.1).leftoverCells + 10)
        // Hog zeroed 0.2 mm low: still nothing gouged.
        var low = hog
        low.moves = low.moves.map { var m = $0; m.to.z -= 0.2; return m }
        var sim2 = StockSimulator(stockSize: ctx.placed.stockSize, resolution: 0.25)
        sim2.run([low, flat])
        #expect(sim2.analyze(model: ctx.placed, tolerance: 0.1).gougeCells == 0)
    }

    /// A bit whose shank is no wider than its cutter may cut below its flutes: the limit is the collet.
    @Test func deepCutLimitIsTheColletForStraightShanks() throws {
        var hog = Self.hog
        hog.fluteLength = 35; hog.stickout = 50
        var job = Job()
        job.quality = .draft
        let mesh = STL.box(V3(60, 40, 45))
        var op = Operation(kind: .cutout, tool: hog)
        op.stockToLeaveZ = Operation.hogFloorSkin
        job.operations = [op]
        let ctx = CAMContext(raw: mesh, job: job)
        let w = try ctx.generate(op).warnings  // 42 mm deep: past the flutes, inside the stick-out
        #expect(!w.contains { $0.contains("flute length") || $0.contains("collet") }, "\(w)")
        hog.stickout = 40
        op.tool = hog
        job.operations = [op]
        let w2 = try CAMContext(raw: mesh, job: job).generate(op).warnings
        #expect(w2.contains { $0.contains("collet") })
        // A wide shank still can't go below the flutes on a cutout.
        var small = ToolLibrary.starter.tools[0]
        small.diameter = 3; small.shankDiameter = 6; small.fluteLength = 12; small.stickout = 60
        var c = Operation(kind: .cutout, tool: small)
        c.cutting.stepdown = 3
        job.operations = [c]
        #expect(try CAMContext(raw: mesh, job: job).generate(c).warnings.contains { $0.contains("flute length") })
    }

    @Test func restByOperationFollowsItsSettings() throws {
        var job = Job()
        job.quality = .draft
        let mesh = RestMachiningTests.cavityPlate()
        var rough = Operation(kind: .pocket, tool: Self.hog)
        rough.name = "hog"
        let fin = JobTemplates.finishing(after: rough, with: ToolLibrary.starter.tools[0], material: .named("mdf"))
        job.operations = [rough, fin]
        let ctx = CAMContext(raw: mesh, job: job)
        let ref = try #require(ctx.restReference(fin))
        #expect(ref.id == rough.id && ref.stockToLeaveZ == Operation.hogFloorSkin)
        #expect(ctx.restField(fin) != nil)
        // Out of order, or turned off: no reference, and a warning.
        job.operations = [fin, rough]
        let swapped = CAMContext(raw: mesh, job: job)
        #expect(swapped.restReference(fin) == nil)
        #expect(try swapped.generate(fin).warnings.contains { $0.contains("cuts everything") })
        // Projects saved before it existed still open.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Operation(kind: .pocket, tool: Self.hog))) as! [String: Any]
        json.removeValue(forKey: "restFromOp")
        #expect(try JSONDecoder().decode(Operation.self, from: JSONSerialization.data(withJSONObject: json)).restFromOp == nil)
    }

    @Test func hogWithoutASkinIsWarned() throws {
        var op = Operation(kind: .pocket, tool: Self.hog)
        op.stockToLeaveXY = 0; op.stockToLeaveZ = 0
        var job = Job(); job.quality = .draft; job.operations = [op]
        let ctx = CAMContext(raw: RestMachiningTests.cavityPlate(), job: job)
        #expect(try ctx.generate(op).warnings.contains { $0.contains("hogging bit") })
    }

    @Test func roughingOperationsPreferTheHoggingBit() throws {
        var job = Job()
        job.quality = .draft
        let dome = STL.merge([STL.box(V3(60, 60, 3)), STL.dome(radius: 20, segments: 24, rings: 12, center: V2(30, 30)).translated(V3(0, 0, 3))])
        let ops = JobTemplates.fullProcessing(CAMContext(raw: dome, job: job), library: library, material: .named("mdf"))
        #expect(ops.first { $0.kind == .roughing }?.tool.kind == .roughing)
        #expect(ops.filter { $0.kind == .parallelFinish || $0.kind == .waterlineFinish }.allSatisfy { $0.tool.kind == .ball })
        // Without one, nothing changes.
        let plain = JobTemplates.fullProcessing(CAMContext(raw: dome, job: job), library: .starter, material: .named("mdf"))
        #expect(plain.first { $0.kind == .roughing }?.tool.kind == .flat)
    }
}
