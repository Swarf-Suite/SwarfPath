import Foundation

public enum JobTemplates {
    /// Characterise a placed model to choose sensible strategies.
    public struct ModelTraits: Sendable {
        public var hasCurvedTop: Bool
        /// Some curved or sloped surface (a cove, a transition, a fillet) on a part that is otherwise flat: too little
        /// to carve the whole part in 3D, but a flat end mill's levels would leave steps on it.
        public var hasCurvedPatches: Bool
        public var hasCavities: Bool
        public var topBelowStock: Bool
        public var touchesBottom: Bool
    }

    public static func traits(_ ctx: CAMContext) -> ModelTraits {
        let m = ctx.placed
        var curved = 0.0, total = 0.0
        for t in m.mesh.triangles where t.normal.z > 0.05 {
            let a = Double(t.area)
            total += a
            if t.normal.z < 0.999 { curved += a }
        }
        let top = m.modelBounds.max.z
        let flats = ctx.flatLevels.filter { $0 < top - 0.05 && $0 > m.modelBounds.min.z + 0.05 }
        return ModelTraits(hasCurvedTop: total > 0 && curved / total > 0.05,
                           hasCurvedPatches: total > 0 && (curved / total > 0.005 || curved > 200), hasCavities: !flats.isEmpty,
                           topBelowStock: m.stockTop - top > 0.05, touchesBottom: m.modelBounds.min.z < 0.01)
    }

    /// "Full processing": facing → roughing → finishing → cutout with tabs. On a two-sided job: dowel holes, then
    /// side A as above, then side B's pockets or 3D carving chosen from the underside.
    public static func fullProcessing(_ ctx: CAMContext, library: ToolLibrary, material: Material, bits: Bits? = nil) -> [Operation] {
        let bits = bits ?? Bits(library)
        let side = singleSide(ctx, bits: bits, library: library, material: material)
        guard ctx.job.activeFlip != nil else { return side }
        let flat6 = library.closest(kind: .flat, diameter: 6) ?? ToolLibrary.starter.tools[0]
        var dowels = Operation(kind: .dowelHoles, tool: flat6, material: material)
        dowels.name = "Dowel holes"
        let b = ctx.makeSideB()
        var back = singleSide(b, bits: bits, library: library, material: material).filter { $0.kind.allowedOnSideB }
        for i in back.indices {
            back[i].machiningSide = .b
            back[i].name += " (side B)"
        }
        return [dowels] + side + back
    }

    /// Pocketing with `flat`; with a hogging bit, the hogging bit clears first and leaves skins (`Operation.hogSkin` on
    /// walls, `Operation.hogFloorSkin` on floors), then `flat` follows that operation (`restFromOp`) and takes the skins
    /// and anything the hogging bit couldn't reach. They are separate tools, so they go in separate files for the bit swap.
    public static func pockets(flat: Tool, hog: Tool?, material: Material) -> [Operation] {
        guard let hog else {
            var p = Operation(kind: .pocket, tool: flat, material: material)
            p.name = "Pockets"
            return [p]
        }
        var rough = Operation(kind: .pocket, tool: hog, material: material)
        rough.name = "Pockets (hogging)"
        return [rough, finishing(after: rough, with: flat, material: material)]
    }

    /// Cutout with `flat`; with a hogging bit, the hogging bit cuts the slot to `Operation.hogFloorSkin` above the stock
    /// bottom with a skin on the wall, and `flat` follows it: the wall to size, and the rest of the depth with the tabs.
    public static func cutouts(flat: Tool, hog: Tool?, material: Material) -> [Operation] {
        var c = Operation(kind: .cutout, tool: flat, material: material)
        c.name = "Cutout"
        c.tabs.enabled = true
        guard let hog else { return [c] }
        var rough = Operation(kind: .cutout, tool: hog, material: material)
        rough.name = "Cutout (hogging)"
        rough.tabs = c.tabs
        return [rough, finishing(after: rough, with: flat, material: material)]
    }

    /// The finishing pass after a hogging operation: same kind and area, the finishing tool, following `hogged`.
    public static func finishing(after hogged: Operation, with tool: Tool, material: Material) -> Operation {
        var fin = Operation(kind: hogged.kind, tool: tool, material: material)
        fin.name = hogged.kind == .cutout ? "Cutout" : "\(hogged.kind.displayName) (finish)"
        if hogged.name.hasPrefix("Pockets") { fin.name = "Pockets (finish)" }
        fin.boundary = hogged.boundary
        fin.boundaryMargin = hogged.boundaryMargin
        fin.floorZ = hogged.floorZ
        fin.maxDepth = hogged.maxDepth
        fin.regionIDs = hogged.regionIDs
        fin.areaID = hogged.areaID
        fin.side = hogged.side
        fin.tabs = hogged.tabs
        fin.cutHoles = hogged.cutHoles
        fin.throughDepth = hogged.throughDepth
        fin.restFromOp = hogged.id
        fin.restFrom = hogged.tool
        return fin
    }

    /// The bits a template uses: the flat end mill for clearing, facing and the cutout, the ball nose for 3D finishing,
    /// and an optional hogging bit that does the bulk of the clearing first.
    public struct Bits: Sendable, Equatable {
        public var flat: Tool
        public var ball: Tool
        public var hog: Tool?
        public var cutout: Tool
        public init(flat: Tool, ball: Tool, hog: Tool?, cutout: Tool? = nil) {
            self.flat = flat; self.ball = ball; self.hog = hog; self.cutout = cutout ?? flat
        }
        /// The library's bits nearest 6 mm, as the Full Processing template has always used.
        public init(_ library: ToolLibrary) {
            let flat6 = library.closest(kind: .flat, diameter: 6) ?? ToolLibrary.starter.tools[0]
            self.init(flat: flat6, ball: library.closest(kind: .ball, diameter: 6) ?? flat6,
                      hog: library.closest(kind: .roughing, diameter: 6))
        }
    }

    /// Drilling for the model's round holes, one operation per bit: a drill or flat end mill from the library that
    /// makes the hole its own size (never larger, at most 0.5 mm smaller), a drill preferred. Holes no bit fits are left
    /// to the pockets and the cutout.
    static func drilling(_ ctx: CAMContext, library: ToolLibrary, material: Material) -> [Operation] {
        let tools = (library.tools.isEmpty ? ToolLibrary.starter : library).tools.filter { $0.kind == .drill || $0.kind == .flat }
        var byTool: [(Tool, [Hole])] = []
        for h in ctx.cachedHoles() {
            let fits = tools.filter { $0.diameter <= h.diameter + 0.05 && $0.diameter >= h.diameter - 0.5 }
            guard let t = fits.min(by: { a, b in
                (a.kind == .drill ? 0 : 1, abs(a.diameter - h.diameter)) < (b.kind == .drill ? 0 : 1, abs(b.diameter - h.diameter))
            }) else { continue }
            if let i = byTool.firstIndex(where: { $0.0.id == t.id }) { byTool[i].1.append(h) } else { byTool.append((t, [h])) }
        }
        return byTool.map { t, holes in
            var d = Operation(kind: .drill, tool: t, material: material)
            d.name = String(format: "Drill Ø%g holes", t.diameter)
            // Just wide enough for the holes it was picked for.
            let off = holes.map { abs($0.diameter - t.diameter) }.max() ?? 0
            var s = d.drillSettings
            s.diameterTolerance = min(0.5, max(0.1, off + 0.05))
            d.drilling = s
            return d
        }
    }

    /// Full Processing's defaults for working together: every operation after the first cuts only what the ones before
    /// it left, and pockets and finishes run straight over the holes that are drilled.
    static func linkUp(_ ops: [Operation]) -> [Operation] {
        let drills = ops.contains { $0.kind == .drill }
        return ops.enumerated().map { i, op in
            var o = op
            if drills && o.kind.supportsRest { o.ignoresDrilledHoles = true }
            if i > 0 && (o.kind.supportsRest || o.kind == .drill) && o.restFromOp == nil && o.restFrom == nil { o.cutsLeftoverOnly = true }
            return o
        }
    }

    static func singleSide(_ ctx: CAMContext, bits: Bits, library: ToolLibrary, material: Material) -> [Operation] {
        let t = traits(ctx)
        var ops: [Operation] = []
        let flat6 = bits.flat, ball = bits.ball, hog = bits.hog
        if t.topBelowStock {
            var f = Operation(kind: .facing, tool: flat6, material: material)
            f.facingDepth = min(ctx.stockTop - ctx.placed.modelBounds.max.z, 2)
            f.name = "Face stock"
            ops.append(f)
        }
        // Hogging work first (one bit swap); its cutout stops above the stock bottom, so the part stays held.
        let cutouts = cutouts(flat: bits.cutout, hog: hog, material: material)
        var finishOps: [Operation] = []
        if t.hasCurvedTop {
            var r = Operation(kind: .roughing, tool: hog ?? flat6, material: material)
            r.name = "Rough"
            ops.append(r)
            var p = Operation(kind: .parallelFinish, tool: ball, material: material)
            p.name = "Finish (parallel)"
            // Direction is automatic; 45° is only for surfaces with no best direction (a dome).
            p.rasterAngle = 45
            p.slopeLimit = 50
            finishOps.append(p)
            var w = Operation(kind: .waterlineFinish, tool: ball, material: material)
            w.name = "Finish (steep walls)"
            w.slopeLimit = 50
            w.cutting.stepdown = 0.3
            finishOps.append(w)
        } else if t.hasCavities || t.topBelowStock {
            let p = pockets(flat: flat6, hog: hog, material: material)
            ops.append(p[0])
            finishOps += p.dropFirst()
            if t.hasCurvedPatches {
                // The pocket's levels leave steps on the curved parts; the ball takes only those, along the curve.
                var f = Operation(kind: .parallelFinish, tool: ball, material: material)
                f.name = "Finish (curves)"
                // On the part, and past its open edges so the curve is finished right to them; the cutout takes the rest.
                f.boundary = .insideSilhouette
                f.runsPastOpenEdges = true
                f.rasterAngle = 45
                finishOps.append(f)
            }
        }
        finishOps += drilling(ctx, library: library, material: material)
        // The hogging cutout goes with the hogging work; the finishing cutout always comes last.
        if cutouts.count > 1 { ops.append(cutouts[0]) }
        // Facing uses the flat: put it with the finishing tools when a hogging bit starts the job.
        if hog != nil, let f = ops.firstIndex(where: { $0.kind == .facing }) { finishOps.insert(ops.remove(at: f), at: 0) }
        return linkUp(ops + finishOps + [cutouts[cutouts.count - 1]])
    }
}

public struct GenerationOutput: Sendable {
    public var toolpaths: [Toolpath]
    public var errors: [UUID: String]
}

extension CAMContext {
    public func generateAll(progress: (@Sendable (Int, Double) -> Void)? = nil) async -> GenerationOutput {
        var tps: [Toolpath] = []
        var errs: [UUID: String] = [:]
        for (i, op) in job.operations.enumerated() where op.enabled {
            if Task.isCancelled { break }
            do {
                let tp = try generate(op) { p in progress?(i, p) }
                tps.append(tp)
            } catch is CancellationError {
                break
            } catch {
                errs[op.id] = error.localizedDescription
            }
        }
        return GenerationOutput(toolpaths: tps, errors: errs)
    }
}
