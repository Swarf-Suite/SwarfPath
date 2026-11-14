import Foundation

/// Chip-load based feeds and speeds.
///
/// Feed (mm/min) = RPM × flutes × chip load (mm/tooth). The chip load to aim for comes from a table of typical
/// router-bit values by cutter diameter (for MDF), scaled for the material, the bit type and the flute style, and kept
/// inside the window `FeedsAndSpeeds.check` warns about. With a light radial cut the real chip is thinner than the
/// feed per tooth, so the feed is raised to keep the chip at the target ("chip thinning"). The machine's maximum feed
/// caps the result; when it does, the spindle is slowed to keep the chip load, which is also quieter.
public enum FeedsCalculator {
    /// Typical chip load (mm/tooth) in MDF by cutter diameter: low and high end of the range.
    static let mdfTable: [(d: Double, lo: Double, hi: Double)] = [
        (0.5, 0.005, 0.010), (1, 0.010, 0.020), (2, 0.025, 0.045), (3.175, 0.050, 0.090),
        (6, 0.100, 0.170), (8, 0.130, 0.220), (12, 0.200, 0.300), (20, 0.250, 0.400),
    ]

    /// How a material's chip load compares with MDF.
    static func materialFactor(_ m: Material) -> Double {
        switch m.id {
        case "plywood": return 0.9
        case "softwood": return 1.05
        case "hardwood": return 0.8
        case "acrylic": return 0.7
        case "hdpe": return 0.9
        case "foam": return 1.5
        case "aluminium": return 0.3
        default: return 1
        }
    }

    static func kindFactor(_ k: ToolKind) -> Double {
        switch k {
        case .flat, .roughing, .ball, .bullNose: return 1
        case .vBit: return 0.5
        case .drill: return 0.6
        }
    }

    /// Down-cut and straight flutes pack chips into the cut; ease off a little.
    static func fluteFactor(_ f: FluteStyle) -> Double {
        switch f {
        case .downcut, .straight: return 0.85
        default: return 1
        }
    }

    /// Recommended chip-load range (mm/tooth) for this bit in this material.
    public static func recommendedRange(tool: Tool, material: Material) -> ClosedRange<Double> {
        let d = max(0.1, tool.diameter)
        let t = mdfTable
        var lo = t[0].lo * d / t[0].d, hi = t[0].hi * d / t[0].d
        if d >= t[t.count - 1].d {
            lo = t[t.count - 1].lo; hi = t[t.count - 1].hi
        } else if d > t[0].d {
            for i in 1..<t.count where d <= t[i].d {
                let u = (d - t[i - 1].d) / (t[i].d - t[i - 1].d)
                lo = t[i - 1].lo + (t[i].lo - t[i - 1].lo) * u
                hi = t[i - 1].hi + (t[i].hi - t[i - 1].hi) * u
                break
            }
        }
        let f = materialFactor(material) * kindFactor(tool.kind) * fluteFactor(tool.fluteStyle)
        lo *= f; hi *= f
        // Stay inside the window the feed check accepts (with room for rounding the feed and speed), so a
        // recommendation never raises a chip-load warning.
        let w0 = FeedsAndSpeeds.window(tool: tool, material: material)
        let w = (w0.lowerBound * 1.1)...(w0.upperBound * 0.9)
        let a = min(max(lo, w.lowerBound), w.upperBound), b = min(max(hi, w.lowerBound), w.upperBound)
        return min(a, b)...max(a, b)
    }

    /// Feed multiplier that keeps the real chip at the feed per tooth when the cutter is engaged across only
    /// `engagementPercent` of its diameter. 1 at half the diameter or more; at most 3.
    public static func chipThinning(engagementPercent: Double) -> Double {
        let ae = min(1, max(0.01, engagementPercent / 100))
        guard ae < 0.5 else { return 1 }
        return min(3, 1 / (2 * (ae * (1 - ae)).squareRoot()))
    }

    /// Typical stepdown for the bit in this material on a rigid machine, at full width (mm).
    public static func recommendedStepdown(tool: Tool, material: Material) -> Double {
        let perD: Double
        switch tool.kind {
        case .roughing: perD = 1.0
        case .flat: perD = 0.5
        case .bullNose: perD = 0.4
        case .ball: perD = 0.3
        case .vBit, .drill: perD = 0.25
        }
        let sd = tool.diameter * perD * material.stepdownFactor
        return max(0.05, min(sd, tool.fluteLength > 0 ? tool.fluteLength : sd))
    }

    /// Fastest plunge the calculator suggests (mm/min).
    public static let maxPlunge = 800.0

    public struct Request: Sendable {
        public var tool: Tool
        public var material: Material
        /// Where to aim inside the recommended range: 0 = low end (gentle), 1 = high end.
        public var target: Double = 0.5
        /// How much of the cutter's diameter is cutting sideways (%). 100 = a full-width slot.
        public var engagementPercent: Double = 100
        /// Spindle speed to use; nil = the fastest the machine allows for this chip load.
        public var rpm: Double? = nil
        public var maxFeed: Double
        public var minRPM: Double
        public var maxRPM: Double
        public init(tool: Tool, material: Material, maxFeed: Double, minRPM: Double, maxRPM: Double) {
            self.tool = tool; self.material = material; self.maxFeed = maxFeed; self.minRPM = minRPM; self.maxRPM = maxRPM
        }
        public init(tool: Tool, material: Material, machine: MachineProfile) {
            self.init(tool: tool, material: material, maxFeed: machine.maxFeed, minRPM: machine.minRPM, maxRPM: machine.maxRPM)
        }
    }

    public enum Limit: Sendable, Equatable {
        /// Nothing held it back: the target chip load at the chosen speed.
        case none
        /// The machine's maximum feed: the spindle was slowed to keep the chip load.
        case machineFeed
        /// The machine's maximum feed with the spindle already at its slowest: the chip is thinner than the target.
        case machineFeedAndMinRPM
    }

    public struct Result: Sendable, Equatable {
        public var rpm: Double
        public var feed: Double
        public var plunge: Double
        public var range: ClosedRange<Double>
        /// The chip load aimed for (mm/tooth).
        public var targetChipLoad: Double
        /// The real chip at the result's feed and speed, after chip thinning (mm/tooth).
        public var chipLoad: Double
        /// Feed per tooth (mm), which is larger than the real chip at light engagement.
        public var feedPerTooth: Double
        public var thinning: Double
        public var limit: Limit
        /// With a fixed spindle speed that the feed cap makes too fast: the slower speed that keeps the chip load.
        public var quieterRPM: Double?
    }

    public static func calculate(_ r: Request) -> Result {
        let range = recommendedRange(tool: r.tool, material: r.material)
        let target = range.lowerBound + (range.upperBound - range.lowerBound) * min(1, max(0, r.target))
        let thin = chipThinning(engagementPercent: r.engagementPercent)
        let fpt = target * thin
        let z = Double(max(1, r.tool.flutes))
        let lo = max(1, r.minRPM), hi = max(lo, r.maxRPM)
        func roundRPM(_ v: Double) -> Double { min(hi, max(lo, (v / 100).rounded() * 100)) }
        var rpm = roundRPM(r.rpm ?? hi)
        var limit = Limit.none
        var quieter: Double? = nil
        let maxFeed = max(1, r.maxFeed)
        if rpm * z * fpt > maxFeed {
            let needed = maxFeed / (z * fpt)
            if r.rpm == nil {
                limit = needed < lo ? .machineFeedAndMinRPM : .machineFeed
                rpm = roundRPM(needed)
            } else {
                limit = .machineFeed
                if needed < rpm - 50 { quieter = roundRPM(needed) }
            }
        }
        let feed = min(maxFeed, max(10, (rpm * z * fpt / 10).rounded() * 10))
        let plungeShare: Double = r.tool.kind == .drill || r.tool.kind == .vBit ? 0.5 : 0.3
        // Straight down the bit can't clear chips sideways: a share of the feed, no more than about 150 mm/min per mm
        // of diameter, and never over `maxPlunge`.
        let plunge = max(10, (min(feed * plungeShare, 150 * max(1, r.tool.diameter), maxPlunge) / 10).rounded() * 10)
        let realFPT = feed / (rpm * z)
        return Result(rpm: rpm, feed: feed, plunge: plunge, range: range, targetChipLoad: target,
                      chipLoad: realFPT / thin, feedPerTooth: realFPT, thinning: thin, limit: limit, quieterRPM: quieter)
    }
}
