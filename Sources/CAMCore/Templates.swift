import Foundation

public enum JobTemplates {
    /// Characterise a placed model to choose sensible strategies.
    public struct ModelTraits: Sendable {
        public var hasCurvedTop: Bool
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
        return ModelTraits(hasCurvedTop: total > 0 && curved / total > 0.05, hasCavities: !flats.isEmpty,
                           topBelowStock: m.stockTop - top > 0.05, touchesBottom: m.modelBounds.min.z < 0.01)
    }

    /// "Full processing": facing → roughing → finishing → cutout with tabs. On a two-sided job: dowel holes, then
    /// side A as above, then side B's pockets or 3D carving chosen from the underside.
    public static func fullProcessing(_ ctx: CAMContext, library: ToolLibrary, material: Material) -> [Operation] {
        let side = singleSide(ctx, library: library, material: material)
        guard ctx.job.activeFlip != nil else { return side }
        let flat6 = library.closest(kind: .flat, diameter: 6) ?? ToolLibrary.starter.tools[0]
        var dowels = Operation(kind: .dowelHoles, tool: flat6, material: material)
        dowels.name = "Dowel holes"
        let b = ctx.makeSideB()
        var back = singleSide(b, library: library, material: material).filter { $0.kind.allowedOnSideB }
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
        fin.side = hogged.side
        fin.tabs = hogged.tabs
        fin.cutHoles = hogged.cutHoles
        fin.throughDepth = hogged.throughDepth
        fin.restFromOp = hogged.id
        fin.restFrom = hogged.tool
        return fin
    }

    static func singleSide(_ ctx: CAMContext, library: ToolLibrary, material: Material) -> [Operation] {
        let t = traits(ctx)
        var ops: [Operation] = []
        let flat6 = library.closest(kind: .flat, diameter: 6) ?? ToolLibrary.starter.tools[0]
        let ball = library.closest(kind: .ball, diameter: 6) ?? flat6
        // A hogging bit, when the library has one, does the bulk of the clearing.
        let hog = library.closest(kind: .roughing, diameter: 6)
        if t.topBelowStock {
            var f = Operation(kind: .facing, tool: flat6, material: material)
            f.facingDepth = min(ctx.stockTop - ctx.placed.modelBounds.max.z, 2)
            f.name = "Face stock"
            ops.append(f)
        }
        // Hogging work first (one bit swap); its cutout stops above the stock bottom, so the part stays held.
        let cutouts = cutouts(flat: flat6, hog: hog, material: material)
        var finishOps: [Operation] = []
        if t.hasCurvedTop {
            var r = Operation(kind: .roughing, tool: hog ?? flat6, material: material)
            r.name = "Rough"
            ops.append(r)
            var p = Operation(kind: .parallelFinish, tool: ball, material: material)
            p.name = "Finish (parallel)"
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
        }
        // The hogging cutout goes with the hogging work; the finishing cutout always comes last.
        if cutouts.count > 1 { ops.append(cutouts[0]) }
        // Facing uses the flat: put it with the finishing tools when a hogging bit starts the job.
        if hog != nil, let f = ops.firstIndex(where: { $0.kind == .facing }) { finishOps.insert(ops.remove(at: f), at: 0) }
        return ops + finishOps + [cutouts[cutouts.count - 1]]
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
