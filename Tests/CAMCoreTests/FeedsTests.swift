import Foundation
import Testing
@testable import CAMCore

@Suite struct FeedsCalculatorTests {
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
        #expect(FeedsCalculator.calculate(request(flat6, maxFeed: 5000)).plunge <= 900)
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
        let probe = CAMContext(raw: mesh, job: job)
        let ops = JobTemplates.fullProcessing(probe, library: library, material: .named("mdf"))
        let rough = try #require(ops.first { $0.name == "Pockets (hogging)" })
        let fin = try #require(ops.first { $0.name == "Pockets (finish)" })
        #expect(rough.tool.kind == .roughing && rough.stockToLeaveZ == Operation.hogSkin && rough.stockToLeaveXY == Operation.hogSkin)
        #expect(fin.tool.kind == .flat && fin.restFrom == Self.hog && fin.restLeftStock == Operation.hogSkin)
        #expect(ops.firstIndex { $0.id == rough.id }! + 1 == ops.firstIndex { $0.id == fin.id }!)
        #expect(ops.first { $0.kind == .cutout }?.tool.kind == .flat)

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
