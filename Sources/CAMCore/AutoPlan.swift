import Foundation

/// "Auto Plan": the Full Processing template with bits chosen for the part from the tool library instead of the ones
/// nearest 6 mm, smaller bits added only where the bigger ones leave real material (rest passes), and the result
/// ordered for the fewest bit changes. Each bit becomes its own G-code file, which KerfLine runs as a group with a
/// bit-change stop between files.
public struct AutoPlan: Sendable {
    /// The operations in run order.
    public var operations: [Operation]
    /// Why each operation's bit was chosen, by operation id.
    public var reasons: [UUID: String]
    /// What the plan couldn't do with the bits in the library.
    public var notes: [String]

    /// The bits in the order they're fitted.
    public var bits: [Tool] {
        var seen = Set<UUID>()
        return operations.filter(\.enabled).map(\.tool).filter { seen.insert($0.id).inserted }
    }
    public var toolChanges: Int { JobTemplates.toolChanges(operations) }
}

extension CAMContext {
    /// Largest bit used for clearing and finishing: bigger ones in a library are usually surfacing bits.
    static let autoPlanMaxDiameter = 12.8
    /// Smallest bit a rest pass is planned with; smaller ones are fragile and slow, so they're left to the user.
    static let autoPlanMinDiameter = 1.5

    /// The plan for this model and stock from the bits in `library`.
    public func autoPlan(library: ToolLibrary, material: Material) -> AutoPlan {
        let tools = library.tools.isEmpty ? ToolLibrary.starter.tools : library.tools
        var notes: [String] = []
        var reasons: [UUID: String] = [:]

        // How deep the bits must reach: clearing to the lowest point of the part's top, the cutout through the stock.
        var lowest = Float.greatestFiniteMagnitude
        for h in heights.data where h > Grid2D.none / 2 && h < Grid2D.forbidThreshold { lowest = min(lowest, h) }
        let clearDepth = lowest == .greatestFiniteMagnitude ? 0 : max(0, stockTop - Double(lowest))
        let cutDepth = stockTop + Operation(kind: .cutout, tool: tools[0]).throughDepth

        func reaches(_ t: Tool, _ kind: OperationKind, _ depth: Double) -> Bool {
            depthWarning(Operation(kind: kind, tool: t), depth: depth) == nil
        }
        func label(_ t: Tool) -> String { String(format: "T%d %@ (Ø%g mm)", t.number, t.name, t.diameter) }
        let usable = tools.filter { $0.diameter <= Self.autoPlanMaxDiameter }

        // Clearing and facing: the biggest flat end mill that reaches the bottom of the part's top.
        let flats = usable.filter { $0.kind == .flat }.sorted { $0.diameter > $1.diameter }
        let fallback = JobTemplates.Bits(library.tools.isEmpty ? .starter : library)
        let flat = flats.first { reaches($0, .pocket, clearDepth) } ?? flats.first ?? fallback.flat
        if !reaches(flat, .pocket, clearDepth) {
            notes.append(String(format: "No flat end mill in the library reaches %.1f mm deep: %@ is used, and its operations warn about the depth.", clearDepth, label(flat)))
        }
        // Finishing: the biggest ball nose that reaches (bigger balls leave smaller scallops at the same stepover).
        let balls = usable.filter { $0.kind == .ball }.sorted { $0.diameter > $1.diameter }
        let ball = balls.first { reaches($0, .parallelFinish, clearDepth) } ?? balls.first ?? flat
        // Cutout: a flat that reaches through the stock, nearest 6 mm (a wider slot wastes stock, a thinner bit flexes).
        let cutters = flats.filter { reaches($0, .cutout, cutDepth) }
        let cutout = cutters.min { abs($0.diameter - 6) < abs($1.diameter - 6) } ?? flat
        if cutters.isEmpty {
            notes.append(String(format: "No flat end mill in the library reaches through the stock (%.1f mm): the cutout uses %@ and warns about the depth.", cutDepth, label(cutout)))
        }
        let hog = usable.filter { $0.kind == .roughing && reaches($0, .pocket, clearDepth) }.max { $0.diameter < $1.diameter }

        let bits = JobTemplates.Bits(flat: flat, ball: ball, hog: hog, cutout: cutout)
        var ops = JobTemplates.fullProcessing(self, library: library, material: material, bits: bits)
        for op in ops {
            reasons[op.id] = switch op.kind {
            case .facing: "The biggest flat end mill, for the fewest passes."
            case .dowelHoles: "Dowel holes use the flat nearest 6 mm."
            case .drill: String(format: "Makes the holes their own size (Ø%g mm)%@.", op.tool.diameter, op.tool.kind == .drill ? "" : "; the library has no drill that size")
            case .cutout where op.tool.id == hog?.id: "The hogging bit takes the bulk of the slot."
            case .cutout: String(format: "Reaches through the stock (%.1f mm) and is nearest 6 mm.", cutDepth)
            case .parallelFinish, .waterlineFinish: String(format: "The biggest ball nose that reaches %.1f mm deep: the smoothest finish for the time.", clearDepth)
            case _ where op.tool.id == hog?.id: "The hogging bit does the bulk of the clearing."
            case _ where op.restFromOp != nil: "Takes the skin the hogging bit leaves, and what it couldn't reach."
            default: String(format: "The biggest flat end mill that reaches %.1f mm deep, for the fastest clearing.", clearDepth)
            }
        }

        // Smaller flats where the clearing leaves material in corners and slots: up to two rest passes per clearing.
        for root in ops where (root.kind == .pocket || root.kind == .roughing) && root.restFrom == nil {
            let series = ops.filter { $0.id == root.id || $0.restFromOp == root.id }
            var ref = series.map(\.tool).min { $0.diameter < $1.diameter }!
            var after = series.last!.id
            // A flat can never reach the bottom of a round curve: on a 3D carve, one rest pass for the bulk, and the
            // finish's smaller ball takes the curves.
            for _ in 0..<(root.kind == .pocket ? 2 : 1) {
                var cleared = root
                cleared.tool = ref
                let smaller = flats.filter { $0.diameter < ref.diameter - 0.5 && $0.diameter >= Self.autoPlanMinDiameter && reaches($0, root.kind, clearDepth) }
                var found: (Tool, Double)?
                for t in smaller {
                    if let p = restPotential(after: cleared, with: t), p.area >= 5, p.maxThickness >= 0.5 { found = (t, p.area); break }
                }
                guard let (t, area) = found else { break }
                var rest = root
                rest.id = UUID()
                rest.name = root.kind == .roughing ? "Rough (rest, Ø\(String(format: "%g", t.diameter)))" : "Pockets (rest, Ø\(String(format: "%g", t.diameter)))"
                rest.tool = t
                rest.cutting = material.apply(t.defaults)
                rest.restFrom = ref
                rest.restFromOp = root.id
                rest.restExtraStock = nil
                if let i = ops.firstIndex(where: { $0.id == after }) { ops.insert(rest, at: i + 1) }
                reasons[rest.id] = String(format: "The Ø%g mm bit leaves about %.0f mm² in corners and slots it can't reach; this one can.", ref.diameter, area)
                ref = t
                after = rest.id
            }
            // Still a lot left for bits the plan won't use (pockets: flat floors, so a leftover is a real slot).
            guard root.kind == .pocket else { continue }
            var cleared = root
            cleared.tool = ref
            let tiny = Tool(name: "reference", kind: .flat, diameter: 1, fluteLength: ref.fluteLength, stickout: ref.stickout, defaults: ref.defaults)
            if let p = restPotential(after: cleared, with: tiny), p.area >= 20, p.maxThickness >= 1 {
                notes.append(String(format: "%@: about %.0f mm² is narrower than the smallest bit used (Ø%g mm). Add a smaller bit by hand if it matters.", root.name, p.area, ref.diameter))
            }
        }

        // A smaller ball nose where the finish can't follow tight concave curves.
        if let i = ops.firstIndex(where: { $0.kind == .parallelFinish && $0.restFrom == nil }), let short = finishShortfall(ops[i]),
           short.maxThickness >= 0.15, short.area >= 10 {
            let fin = ops[i]
            let smaller = balls.filter { $0.diameter < fin.tool.diameter - 0.5 && reaches($0, .parallelFinish, clearDepth) }
            var pick: Tool?
            for t in smaller {
                pick = t
                var trial = fin
                trial.tool = t
                if let s = finishShortfall(trial), s.maxThickness >= 0.15, s.area >= 10 { continue }
                break
            }
            if let t = pick {
                var rest = fin
                rest.id = UUID()
                rest.name = "Finish (tight curves, Ø\(String(format: "%g", t.diameter)))"
                rest.tool = t
                rest.cutting = material.apply(t.defaults)
                rest.restFrom = fin.tool
                rest.restFromOp = fin.id
                rest.restExtraStock = nil
                ops.insert(rest, at: i + 1)
                reasons[rest.id] = String(format: "The Ø%g mm ball leaves up to %.2f mm in concave curves (about %.0f mm²); this one follows them.", fin.tool.diameter, short.maxThickness, short.area)
            } else {
                notes.append(String(format: "The finish leaves up to %.2f mm in concave curves, and the library has no smaller ball nose to follow it.", short.maxThickness))
            }
        }

        return AutoPlan(operations: JobTemplates.orderedForFewestToolChanges(ops), reasons: reasons, notes: notes)
    }
}
