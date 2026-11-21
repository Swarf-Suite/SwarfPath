import CAMCore
import SwiftUI

struct InspectorView: View {
    @ObservedObject var model: ProjectModel

    var body: some View {
        Group {
            switch model.selection {
            case .model: ModelInspector(model: model)
            case .stock: StockInspector(model: model)
            case .machine: MachineInspector(model: model)
            case .region(let id):
                if model.job.regions.contains(where: { $0.id == id }) { RegionInspector(model: model, id: id) } else { placeholder }
            case .operation(let id):
                if model.job.operations.contains(where: { $0.id == id }) { OperationInspector(model: model, id: id) } else { placeholder }
            case nil: placeholder
            }
        }
        .disabled(model.placed == nil && model.selection != .machine)
    }

    var placeholder: some View {
        ContentUnavailableView("Nothing selected", systemImage: "sidebar.right", description: Text("Select an item in the sidebar."))
    }
}

// MARK: Shared controls

struct NumberField: View {
    let title: String
    @Binding var value: Double
    var unit: String = "mm"
    var step: Double = 0.1
    var range: ClosedRange<Double> = -10000...100000
    var digits = 2

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) }),
                          format: .number.precision(.fractionLength(0...digits)))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 60, maxWidth: 90)
                Stepper("", value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) }), step: step)
                    .labelsHidden()
                if !unit.isEmpty { Text(unit).foregroundStyle(.secondary).frame(width: 46, alignment: .leading).font(.caption) }
            }
        }
    }
}

struct IntField: View {
    let title: String
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...1000
    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) }),
                          format: .number).labelsHidden().multilineTextAlignment(.trailing).frame(width: 60)
                Stepper("", value: $value, in: range).labelsHidden()
            }
        }
    }
}

// MARK: Model

struct ModelInspector: View {
    @ObservedObject var model: ProjectModel
    @State private var freeAngle = 15.0

    var body: some View {
        Form {
            Section("Model") {
                LabeledContent("Name", value: model.document.modelName)
                if let p = model.placed {
                    let s = p.modelBounds.size
                    LabeledContent("Size", value: String(format: "%.2f × %.2f × %.2f mm", s.x, s.y, s.z))
                }
                if let d = model.diagnostics {
                    LabeledContent("Triangles", value: d.triangleCount.formatted())
                    LabeledContent("Mesh") {
                        Label(d.isWatertight ? "Watertight" : "\(d.openEdges) open edges", systemImage: d.isWatertight ? "checkmark.circle" : "exclamationmark.triangle")
                            .foregroundStyle(d.isWatertight ? .green : .orange)
                    }
                }
                Button("Replace Model…") { model.presentImport() }
            }
            Section {
                HStack {
                    Text("Scale")
                    Spacer()
                    TextField("Scale", value: Binding(get: { model.job.orientation.scale },
                                                      set: { v in model.updateJob("Scale") { $0.orientation.scale = v.isFinite ? min(max(v, 0.001), 10000) : 1 } }), format: .number.precision(.fractionLength(0...4)))
                        .labelsHidden().frame(width: 80).multilineTextAlignment(.trailing)
                }
                HStack {
                    Button("mm → ×1") { model.jobBinding(\.orientation.scale).wrappedValue = 1 }
                    Button("inch → ×25.4") { model.jobBinding(\.orientation.scale).wrappedValue = 25.4 }
                }
                .controlSize(.small)
            } header: { Text("Units") } footer: {
                Text("STL files carry no units. Models smaller than 12 units are assumed to be inches.").font(.caption)
            }
            Section {
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        Text("X").bold().foregroundStyle(.red)
                        Button { model.rotate(axis: V3(1, 0, 0), degrees: -90) } label: { Image(systemName: "rotate.left") }
                        Button { model.rotate(axis: V3(1, 0, 0), degrees: 90) } label: { Image(systemName: "rotate.right") }
                        Button("180°") { model.rotate(axis: V3(1, 0, 0), degrees: 180) }
                    }
                    GridRow {
                        Text("Y").bold().foregroundStyle(.green)
                        Button { model.rotate(axis: V3(0, 1, 0), degrees: -90) } label: { Image(systemName: "rotate.left") }
                        Button { model.rotate(axis: V3(0, 1, 0), degrees: 90) } label: { Image(systemName: "rotate.right") }
                        Button("180°") { model.rotate(axis: V3(0, 1, 0), degrees: 180) }
                    }
                    GridRow {
                        Text("Z").bold().foregroundStyle(.blue)
                        Button { model.rotate(axis: V3(0, 0, 1), degrees: -90) } label: { Image(systemName: "rotate.left") }
                        Button { model.rotate(axis: V3(0, 0, 1), degrees: 90) } label: { Image(systemName: "rotate.right") }
                        Button("180°") { model.rotate(axis: V3(0, 0, 1), degrees: 180) }
                    }
                }
                HStack {
                    Text("Free Z rotation")
                    Spacer()
                    TextField("", value: $freeAngle, format: .number).frame(width: 50).multilineTextAlignment(.trailing)
                    Text("°")
                    Button("Rotate") { model.rotate(axis: V3(0, 0, 1), degrees: freeAngle) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Button { model.mode = .faceUp } label: { Label("Pick the face that should point UP", systemImage: "arrow.up.square") }
                    Button { model.mode = .faceDown } label: { Label("Pick the face to lay on the BED", systemImage: "arrow.down.square") }
                    Button { model.layFlat() } label: { Label("Auto lay-flat (largest face down)", systemImage: "wand.and.rays") }
                    Button(role: .destructive) { model.resetOrientation() } label: { Label("Reset orientation", systemImage: "arrow.uturn.backward") }
                }
                .buttonStyle(.borderless)
            } header: { Text("Orientation (3-axis: X / Y / Z only)") }
            Section("Reachability") {
                Toggle("Highlight undercuts", isOn: $model.showUndercuts)
                if let p = model.placed {
                    let u = Placement.undercutArea(p.mesh)
                    let pct = u.total > 0 ? u.undercut / u.total * 100 : 0
                    LabeledContent("Unreachable from above", value: String(format: "%.1f %% of surface", pct))
                    if pct > 1 {
                        Text("Orange faces face downward and cannot be reached by a 3-axis machine from this side. Try another face up, or plan a second (flipped) setup.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Stock

struct StockInspector: View {
    @ObservedObject var model: ProjectModel

    var body: some View {
        Form {
            Section("Material") {
                Picker("Material", selection: Binding(get: { model.job.stock.materialID }, set: { model.setMaterial($0) })) {
                    ForEach(Material.library) { m in Text(m.name).tag(m.id) }
                }
                Text("New operations take their feeds from the tool's defaults, scaled for this material.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Size", selection: Binding(get: { model.job.stock.autoSize }, set: { model.setStockAutoSize($0) })) {
                    Text("Model + margins").tag(true)
                    Text("Exact size").tag(false)
                }
                .pickerStyle(.segmented)
                if model.job.stock.autoSize {
                    NumberField(title: "XY margin", value: model.jobBinding(\.stock.marginXY), step: 1, range: 0...500)
                    NumberField(title: "Extra on top", value: model.jobBinding(\.stock.extraTop), step: 0.5, range: 0...500)
                    NumberField(title: "Extra below", value: model.jobBinding(\.stock.extraBottom), step: 0.5, range: 0...500)
                    if let p = model.placed {
                        LabeledContent("Stock", value: String(format: "%.1f × %.1f × %.1f mm", p.stockSize.x, p.stockSize.y, p.stockSize.z))
                    }
                } else {
                    NumberField(title: "Length (X)", value: model.jobBinding(\.stock.size.x, name: "Stock Size"), step: 1, range: 1...5000)
                    NumberField(title: "Width (Y)", value: model.jobBinding(\.stock.size.y, name: "Stock Size"), step: 1, range: 1...5000)
                    NumberField(title: "Depth (Z)", value: model.jobBinding(\.stock.size.z, name: "Stock Size"), step: 0.5, range: 0.5...500)
                    if let p = model.placed {
                        let m = p.modelBounds.size
                        LabeledContent("Model", value: String(format: "%.1f × %.1f × %.1f mm", m.x, m.y, m.z))
                        if p.modelOutsideStock {
                            Label("The model doesn't fit inside this stock (or sticks out at its offset). Anything outside is not machined correctly.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } header: {
                Text("Stock size")
            } footer: {
                Text(model.job.stock.autoSize
                     ? "The stock is the model's size plus these margins."
                     : "Enter the blank's real size: length (X) left to right, width (Y) front to back, depth (Z) its thickness. The model sits in it as set under Model position in stock.")
                    .font(.caption)
            }
            Section {
                Toggle("Test cut mode", isOn: model.jobBinding(\.testCutSettings.enabled, name: "Test Cut Mode"))
                if model.job.testCutSettings.enabled {
                    NumberField(title: "Cutouts", value: model.jobBinding(\.testCutSettings.cutoutDepth, name: "Test Cut Depth"),
                                step: 0.5, range: 0.5...100, digits: 1)
                    NumberField(title: "Pockets & carving", value: model.jobBinding(\.testCutSettings.pocketDepth, name: "Test Cut Depth"),
                                step: 0.5, range: 0.5...100, digits: 1)
                    NumberField(title: "Drilled holes", value: model.jobBinding(\.testCutSettings.drillDepth, name: "Test Cut Depth"),
                                step: 0.5, range: 0.5...100, digits: 1)
                }
            } header: { Text("Test cut") } footer: {
                Text("Try the job on scrap such as 9 mm MDF. Every cut stops at these depths below the stock top, so the cutout leaves a thin skin holding the part. Facing is not limited. Zero Z on the top of the test board.")
                    .font(.caption)
            }
            Section {
                Toggle("Machine both sides (flip)", isOn: Binding(get: { model.job.activeFlip != nil }, set: { model.setFlip($0) }))
                if model.job.activeFlip != nil {
                    if !model.job.operations.contains(where: { $0.kind == .dowelHoles }) {
                        Button("Add Dowel Holes") { model.addOperation(.dowelHoles) }
                    }
                }
            } header: { Text("Two-sided machining") } footer: {
                Text("Dowel holes go through the stock in the waste around the part, in pairs mirrored across the centre line; select the Dowel holes operation to place them. Side A (the top) is machined and cut out with tabs; then the stock is rolled over front-to-back onto dowels in those holes and side B (the back) is machined. Keep the X/Y zero; re-probe Z. The stock needs room for the holes at both ends.")
                    .font(.caption)
            }
            Section("Model position in stock") {
                Picker("Vertical", selection: model.jobBinding(\.stock.modelZ)) {
                    Text("Flush with top").tag(ModelZPlacement.top)
                    Text("Centred").tag(ModelZPlacement.center)
                    Text("On bottom").tag(ModelZPlacement.bottom)
                }
                NumberField(title: "Offset X", value: model.jobBinding(\.stock.modelOffset.x), step: 1)
                NumberField(title: "Offset Y", value: model.jobBinding(\.stock.modelOffset.y), step: 1)
            }
            Section {
                OriginPicker(origin: model.jobBinding(\.origin, name: "Work Zero"))
                Picker("Z zero", selection: model.jobBinding(\.origin.z)) {
                    Text("Top of stock").tag(WorkOrigin.ZAnchor.stockTop)
                    Text("Bed / stock bottom").tag(WorkOrigin.ZAnchor.stockBottom)
                }
                NumberField(title: "Safe height", value: model.jobBinding(\.safeHeight), step: 1, range: 1...100)
            } header: { Text("Work zero (G54)") } footer: {
                Text("Toolpaths start from the work zero. Zero XY on the point shown and probe Z on the top of the stock.").font(.caption)
            }
            Section {
                Picker("Calculation resolution", selection: model.jobBinding(\.quality)) {
                    Text("Draft").tag(ResolutionQuality.draft)
                    Text("Normal").tag(ResolutionQuality.normal)
                    Text("Fine").tag(ResolutionQuality.fine)
                }
            } footer: {
                if let p = model.placed {
                    let r = CAMContext.gridResolution(stockSize: p.stockSize, quality: model.job.quality)
                    Text(String(format: "Grid cell: %.3f mm", r)).font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct OriginPicker: View {
    @Binding var origin: WorkOrigin

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text("XY zero")
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Color(red: 0.85, green: 0.7, blue: 0.45).opacity(0.35))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary))
                    .frame(width: 120, height: 84)
                VStack(spacing: 22) {
                    ForEach([WorkOrigin.YAnchor.back, .center, .front], id: \.self) { y in
                        HStack(spacing: 40) {
                            ForEach([WorkOrigin.XAnchor.left, .center, .right], id: \.self) { x in
                                let on = origin.x == x && origin.y == y
                                Button {
                                    origin.x = x; origin.y = y
                                } label: {
                                    Circle().fill(on ? Color.accentColor : Color.secondary.opacity(0.4))
                                        .frame(width: on ? 14 : 9, height: on ? 14 : 9)
                                        .frame(width: 16, height: 16)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: Machine

struct MachineInspector: View {
    @ObservedObject var model: ProjectModel

    var body: some View {
        let m = model.machine
        Form {
            Section("Post-processor") {
                Picker("Machine", selection: model.jobBinding(\.machineID, name: "Machine")) {
                    ForEach(MachineProfile.builtIn) { p in Text(p.name).tag(p.id) }
                }
                LabeledContent("Controller", value: m.controller)
                LabeledContent("File type", value: "." + m.fileExtension)
                LabeledContent("Work area", value: String(format: "%.0f × %.0f × %.0f mm", m.envelope.x, m.envelope.y, m.envelope.z))
                LabeledContent("Arcs (G2/G3)", value: m.supportsArcs ? "Yes" : "No")
                LabeledContent("Tool changes", value: {
                    switch m.toolChange {
                    case .none: return "Separate file per tool"
                    case .m6: return "M6 in one file"
                    case .pause: return "M0 pause"
                    case .rrfPrompt: return "RRF M291 prompt"
                    }
                }())
                LabeledContent("Comments", value: m.commentStyle == .semicolon ? "; semicolon" : "( parentheses )")
                if !m.notes.isEmpty { Text(m.notes).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Defaults for new projects") {
                Button("Use this machine for new projects") { UserDefaults.standard.set(m.id, forKey: "defaultMachineID") }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Region

struct RegionInspector: View {
    @ObservedObject var model: ProjectModel
    let id: UUID

    var body: some View {
        let protect = model.regionBinding(id, \.protectBelowZ)
        let isArea = model.job.regions.first { $0.id == id }?.isArea ?? false
        Form {
            Section(isArea ? "Area for its own operations" : "Region") {
                TextField("Name", text: model.regionBinding(id, \.name))
                if !isArea {
                    Picker("Type", selection: model.regionBinding(id, \.kind)) {
                        ForEach(Region.Kind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                }
                Toggle("Enabled", isOn: model.regionBinding(id, \.enabled))
            }
            if isArea { areaOperations }
            if model.job.activeFlip != nil {
                Section {
                    Picker("Side", selection: model.regionBinding(id, \.appliesTo)) {
                        ForEach(RegionSides.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                } footer: {
                    Text("Clamps usually move when the stock is flipped: give each side its own keep-outs. Draw side-B regions in this same top view, over the side-B toolpaths as they are shown here; Swarf mirrors them onto the back.")
                        .font(.caption)
                }
            }
            Section("Rectangle (stock coordinates)") {
                NumberField(title: "Min X", value: model.regionBinding(id, \.min.x), step: 1)
                NumberField(title: "Min Y", value: model.regionBinding(id, \.min.y), step: 1)
                NumberField(title: "Max X", value: model.regionBinding(id, \.max.x), step: 1)
                NumberField(title: "Max Y", value: model.regionBinding(id, \.max.y), step: 1)
            }
            if !isArea && model.regionBinding(id, \.kind).wrappedValue == .keepOut {
                Section {
                    Toggle("Allow cutting down to a height", isOn: Binding(get: { protect.wrappedValue != nil }, set: { on in
                        protect.wrappedValue = on ? (model.placed?.stockTop ?? 10) - 1 : nil
                    }))
                    if let z = protect.wrappedValue {
                        NumberField(title: "Protect below Z", value: Binding(get: { z }, set: { protect.wrappedValue = $0 }), step: 0.5)
                    }
                } footer: {
                    Text("By default the tool never enters a keep-out region, keeping a full cutter radius away. Toggle this to allow skimming above a feature, for example to face over it.").font(.caption)
                }
            }
            if !isArea { appliesTo }
            Section {
                Button(isArea ? "Delete Area" : "Delete Region", role: .destructive) { model.deleteRegion(id) }
                Text("In the view: click a box to select it, drag the selected box to move it, arrow keys nudge it (⇧ 10 mm, ⌥ 0.1 mm), ⌫ deletes it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// The operations limited to this area, and the button that adds one.
    var areaOperations: some View {
        Section {
            ForEach(model.operations(inArea: id)) { op in
                Button { model.selection = .operation(op.id) } label: {
                    HStack {
                        Image(systemName: op.kind.symbol)
                        Text(op.name)
                        Spacer()
                        Text("T\(op.tool.number) · Ø\(String(format: "%.3g", op.tool.diameter)) mm").foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            Button { model.areaOperationRequest = AreaRequest(id: id) } label: {
                Label("New Operation in This Area…", systemImage: "plus")
            }
        } header: {
            Text("Operations in this area")
        } footer: {
            Text("Each one machines only inside this box, with its own bit and feeds: a truss-rod slot cut with a smaller bit than the neck, say. The other operations aren't limited by it; draw a keep-out too if they must not cut here.")
                .font(.caption)
        }
    }

    var appliesTo: some View {
            Section("Applies to") {
                ForEach(model.job.operations.filter { $0.areaID == nil }) { op in
                    let ids = model.opBinding(op.id, \.regionIDs)
                    Toggle(op.name, isOn: Binding(get: { ids?.wrappedValue == nil || ids!.wrappedValue!.contains(id) }, set: { on in
                        guard let ids else { return }
                        var cur = ids.wrappedValue ?? model.job.regions.map(\.id)
                        if on { if !cur.contains(id) { cur.append(id) } } else { cur.removeAll { $0 == id } }
                        ids.wrappedValue = Set(cur) == Set(model.job.regions.map(\.id)) ? nil : cur
                    }))
                }
            }
    }
}

/// "New Operation in This Area": the kind of operation and the bit. Feeds and speeds come from the bit, and are
/// changed in the operation's inspector, which is selected once it's added.
struct AreaOperationSheet: View {
    @ObservedObject var model: ProjectModel
    @ObservedObject var tools = ToolLibraryStore.shared
    let areaID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var kind: OperationKind = .pocket
    @State private var toolID: UUID?

    static let kinds: [OperationKind] = OperationKind.allCases.filter { $0 != .dowelHoles && $0 != .facing }

    var body: some View {
        let area = model.job.regions.first { $0.id == areaID }
        VStack(alignment: .leading, spacing: 14) {
            Text("New Operation in \(area?.name ?? "This Area")").font(.headline)
            Text("It machines only inside the box, with its own bit and feeds.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                Picker("Operation", selection: $kind) {
                    ForEach(Self.kinds) { k in Label(k.displayName, systemImage: k.symbol).tag(k) }
                }
                Picker("Bit", selection: $toolID) {
                    ForEach(tools.tools) { t in Text("T\(t.number) · \(t.name)").tag(Optional(t.id)) }
                }
                if let t = tools.tools.first(where: { $0.id == toolID }) {
                    let c = CAMCore.Operation(kind: kind, tool: t, material: .named(model.job.stock.materialID)).cutting
                    LabeledContent("Feeds & speeds", value: String(format: "%.0f rpm · feed %.0f · plunge %.0f mm/min · %.2g mm per pass", c.rpm, c.feed, c.plunge, c.stepdown))
                    Text("For this bit in the stock's material. Change them in the operation once it's added.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Operation") {
                    let t = tools.tools.first { $0.id == toolID }
                    dismiss()
                    model.addOperation(kind, tool: t, area: areaID)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(area == nil || toolID == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            // The smallest flat bit: an area is usually there because the main bit is too big for it.
            toolID = tools.tools.filter { $0.kind == .flat }.min { $0.diameter < $1.diameter }?.id ?? tools.tools.first?.id
        }
        .onChange(of: kind) { _, k in
            let want: ToolKind? = k == .vcarve ? .vBit : k == .parallelFinish || k == .waterlineFinish ? .ball : k == .drill ? nil : .flat
            if let want, tools.tools.first(where: { $0.id == toolID })?.kind != want {
                toolID = tools.tools.filter { $0.kind == want }.min { $0.diameter < $1.diameter }?.id ?? toolID
            }
        }
    }
}

// MARK: Operation

struct OperationInspector: View {
    @ObservedObject var model: ProjectModel
    @ObservedObject var tools = ToolLibraryStore.shared
    @Environment(\.openSettings) private var openSettings
    let id: UUID

    @State private var showCalculator = false

    func b<T>(_ kp: WritableKeyPath<CAMCore.Operation, T>) -> Binding<T> {
        model.opBinding(id, kp) ?? .constant(CAMCore.Operation.placeholder[keyPath: kp])
    }

    var body: some View {
        let op = model.job.operations.first { $0.id == id } ?? .placeholder
        Form {
            Section {
                TextField("Name", text: b(\.name))
                LabeledContent("Strategy") { Label(op.kind.displayName, systemImage: op.kind.symbol) }
                Toggle("Enabled", isOn: b(\.enabled))
                if model.job.activeFlip != nil && op.kind != .dowelHoles {
                    if op.kind.allowedOnSideB || op.machiningSide == .b {
                        Picker("Side", selection: Binding(get: { op.machiningSide }, set: { model.setSide($0, for: id) })) {
                            ForEach(MachiningSide.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    } else {
                        LabeledContent("Side", value: MachiningSide.a.displayName)
                    }
                }
                statusRow(op)
            }
            Section("Tool") {
                Picker("Tool", selection: Binding(get: { op.tool.id }, set: { newID in
                    if let t = tools.tools.first(where: { $0.id == newID }) { model.setTool(t, for: id, resetCutting: true) }
                })) {
                    if !tools.tools.contains(where: { $0.id == op.tool.id }) { Text(op.tool.name + " (project)").tag(op.tool.id) }
                    ForEach(tools.tools) { t in Text("T\(t.number) · \(t.name)").tag(t.id) }
                }
                LabeledContent("Geometry", value: String(format: "Ø%.3g mm %@, %d flute%@, %g mm flutes%@", op.tool.diameter,
                                                          op.tool.kind.displayName, op.tool.flutes, op.tool.flutes == 1 ? "" : "s", op.tool.fluteLength,
                                                          op.tool.hasWideShank ? String(format: ", Ø%g mm shank", op.tool.shankDiameter) : ""))
                IntField(title: "Tool number (T)", value: b(\.tool.number), range: 1...99)
                Button {
                    UserDefaults.standard.set(1, forKey: "settingsTab")
                    openSettings()
                } label: {
                    Label("Edit Tool Library…", systemImage: "wrench.and.screwdriver")
                }
                .help("Add, edit or import tools (⇧⌘T)")
                if model.needsFinishingPass(op), let flat = model.finishingTool(after: op) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(op.kind == .cutout
                              ? String(format: "A hogging bit stops %.0f mm above the stock bottom and leaves a rough wall. Add a cutout with a flat bit to finish it and cut the part free.", CAMCore.Operation.hogFloorSkin)
                              : String(format: "A hogging bit leaves %.1f mm on walls and %.0f mm on floors. Add a pass with a flat bit to take them to size.", CAMCore.Operation.hogSkin, CAMCore.Operation.hogFloorSkin),
                              systemImage: "info.circle")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        Button("Add Finishing Pass with T\(flat.number) · \(flat.name)") { model.addFinishingPass(after: id) }
                    }
                }
            }
            Section("Feeds & speeds") {
                NumberField(title: "Spindle", value: b(\.cutting.rpm), unit: "RPM", step: 500, range: 0...60000, digits: 0)
                NumberField(title: "Feed", value: b(\.cutting.feed), unit: "mm/min", step: 50, range: 1...20000, digits: 0)
                NumberField(title: "Plunge", value: b(\.cutting.plunge), unit: "mm/min", step: 25, range: 1...10000, digits: 0)
                NumberField(title: op.kind == .waterlineFinish ? "Z step" : op.kind == .drill || op.kind == .dowelHoles ? "Peck depth" : "Stepdown", value: b(\.cutting.stepdown), step: 0.1, range: 0.05...50)
                if op.kind != .cutout && op.kind != .waterlineFinish && op.kind != .drill && op.kind != .dowelHoles {
                    NumberField(title: "Stepover", value: b(\.cutting.stepoverPercent), unit: String(format: "%% (%.2f)", op.stepover), step: 1, range: 1...100, digits: 0)
                }
                if op.kind != .parallelFinish && op.kind != .waterlineFinish && op.kind != .facing && op.kind != .vcarve && op.kind != .drill && op.kind != .dowelHoles {
                    NumberField(title: "Ramp angle", value: b(\.cutting.rampAngle), unit: "°", step: 0.5, range: 0.5...45, digits: 1)
                }
                let advice = FeedsAndSpeeds.check(tool: op.tool, data: op.cutting, material: .named(model.job.stock.materialID))
                LabeledContent("Chip load") {
                    HStack {
                        Text(String(format: "%.3f mm/tooth", advice.chipLoad))
                        Button("Calculate…") { showCalculator = true }
                            .controlSize(.small)
                            .help("Chip-load calculator for this operation, the project's material and machine")
                    }
                }
                .sheet(isPresented: $showCalculator) {
                    // Finishing passes and light stepovers cut from the side; everything else includes full-width cuts.
                    let side = op.kind == .parallelFinish || op.kind == .waterlineFinish
                    FeedsCalculatorSheet(tool: op.tool, material: .named(model.job.stock.materialID), destination: "Operation",
                                         current: op.cutting, machineID: model.job.machineID, slotting: !side,
                                         axialDepth: op.typicalAxialDepth) { c in
                        b(\.cutting).wrappedValue = c
                    }
                }
                ForEach(advice.warnings, id: \.self) { w in Label(w, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                let material = Material.named(model.job.stock.materialID)
                Button(material.adjustmentSummary == nil ? "Reset to tool defaults" : "Reset to tool defaults for \(material.name)") {
                    model.setTool(op.tool, for: id, resetCutting: true)
                }
                .controlSize(.small)
                if let adj = material.adjustmentSummary {
                    Label {
                        Text("Adjusted for \(material.name). The tool library's values are for MDF; resetting applies \(adj). Change the material under Stock to use other factors.")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: { Image(systemName: "info.circle.fill").foregroundStyle(.blue) }
                    .font(.callout)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            Section("Depth") {
                let thickness = model.placed?.stockTop ?? 0
                Toggle("Limit maximum depth", isOn: Binding(get: { op.maxDepth != nil }, set: { on in
                    // Start from how deep the operation cuts now, so turning it on changes nothing until edited.
                    let deepest = model.toolpaths.first { $0.id == id }.map { thickness - ($0.moves.map(\.to.z).min() ?? thickness) }
                    b(\.maxDepth).wrappedValue = on ? max(0.5, ((deepest ?? thickness) * 10).rounded() / 10) : nil
                }))
                if let d = op.maxDepth {
                    NumberField(title: "Maximum depth", value: Binding(get: { d }, set: { b(\.maxDepth).wrappedValue = $0 }),
                                unit: "mm", step: 0.5, range: 0.1...500)
                    Text(String(format: "Measured down from the top of the stock (%.1f mm thick). Nothing in this operation cuts deeper; material below is left.", thickness))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            let areas = model.job.regions.filter(\.isArea)
            if op.areaID != nil || (!areas.isEmpty && op.kind != .dowelHoles) {
                Section {
                    Picker("Machine only in", selection: b(\.areaID)) {
                        Text("The whole part").tag(UUID?.none)
                        ForEach(areas) { r in Text(r.name).tag(Optional(r.id)) }
                        if let a = op.areaID, !areas.contains(where: { $0.id == a }) { Text("A deleted area").tag(Optional(a)) }
                    }
                } footer: {
                    Text("An area is a box drawn for operations of their own (⌥⌘A): this operation cuts only inside it.").font(.caption)
                }
            }
            kindSpecific(op)
            if op.kind.supportsRest || op.kind == .cutout { restSection(op) }
            if op.kind != .facing && op.kind != .cutout && op.kind != .vcarve && op.kind != .drill && op.kind != .dowelHoles {
                Section("Area") {
                    Picker("Boundary", selection: b(\.boundary)) {
                        ForEach(BoundaryMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    if op.boundary == .silhouette { NumberField(title: "Margin", value: b(\.boundaryMargin), step: 0.5, range: 0...200) }
                    Toggle("Custom bottom height", isOn: Binding(get: { op.floorZ != nil }, set: { on in b(\.floorZ).wrappedValue = on ? (model.placed?.modelBounds.min.z ?? 0) : nil }))
                    if let f = op.floorZ { NumberField(title: "Lowest Z", value: Binding(get: { f }, set: { b(\.floorZ).wrappedValue = $0 }), step: 0.5) }
                    else if model.placed?.modelBounds.min.z ?? 1 < 0.01 && op.kind != .pocket {
                        NumberField(title: "Bottom skin", value: b(\.bottomSkin), step: 0.25, range: 0...20)
                    }
                }
            }
            if op.kind != .facing && op.kind != .vcarve && op.kind != .drill && op.kind != .dowelHoles {
                Section("Stock to leave") {
                    NumberField(title: "Radial (XY)", value: b(\.stockToLeaveXY), step: 0.05, range: 0...10)
                    if op.kind != .cutout {
                        NumberField(title: "Axial (Z)", value: b(\.stockToLeaveZ), step: 0.05, range: 0...10)
                    } else {
                        NumberField(title: "Stop above bottom (Z)", value: b(\.stockToLeaveZ), step: 0.5, range: 0...50)
                        if op.stockToLeaveZ > 0 {
                            Text(String(format: "Stops %g mm above the stock bottom instead of cutting through, so the part stays attached. A later cutout that follows this one cuts the rest.", op.stockToLeaveZ))
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            Section {
                Button("Duplicate") { model.duplicateOperation(id) }
                Button("Delete Operation", role: .destructive) { model.deleteOperation(id) }
            }
        }
        .formStyle(.grouped)
        // Developer hook for automated screenshots: -SwarfInspectorBottom YES opens the inspector scrolled to the end.
        .defaultScrollAnchor(UserDefaults.standard.bool(forKey: "SwarfInspectorBottom") ? .bottom : .top)
    }

    @ViewBuilder func restSection(_ op: CAMCore.Operation) -> some View {
        let choices = model.restReferenceChoices(for: op)
        let opChoices = model.restOperationChoices(for: op)
        let isCutout = op.kind == .cutout
        Section(isCutout ? "Follows" : "Rest machining") {
            // "none", "op:<id>" (an earlier operation, exactly as set there) or "tool" (a larger tool, older projects).
            Picker(isCutout ? "Finishes after" : "Only cut what was left by", selection: Binding(get: {
                op.restFromOp.map { "op:\($0.uuidString)" } ?? (op.restFrom != nil ? "tool" : !isCutout && op.cutsLeftoverOnly ? "earlier" : "none")
            }, set: { tag in
                b(\.cutsLeftoverOnly).wrappedValue = tag == "earlier"
                if tag.hasPrefix("op:"), let o = opChoices.first(where: { "op:\($0.id.uuidString)" == tag }) {
                    b(\.restFromOp).wrappedValue = o.id
                    b(\.restFrom).wrappedValue = o.tool
                    b(\.restLeftStock).wrappedValue = 0
                } else if tag == "tool", let t = choices.first {
                    b(\.restFromOp).wrappedValue = nil
                    b(\.restFrom).wrappedValue = t
                    b(\.restLeftStock).wrappedValue = t.kind == .roughing ? CAMCore.Operation.hogSkin : 0
                } else {
                    b(\.restFromOp).wrappedValue = nil
                    b(\.restFrom).wrappedValue = nil
                    b(\.restLeftStock).wrappedValue = 0
                }
            })) {
                Text(isCutout ? "Nothing: cut the full depth" : "Nothing: cut everything").tag("none")
                if !isCutout { Text("Everything before it").tag("earlier") }
                if let r = op.restFromOp, !opChoices.contains(where: { $0.id == r }) { Text("A missing operation").tag("op:\(r.uuidString)") }
                ForEach(opChoices) { o in Text("\(o.name) · T\(o.tool.number) Ø\(String(format: "%g", o.tool.diameter))").tag("op:\(o.id.uuidString)") }
                if !isCutout && (op.restFromOp == nil && op.restFrom != nil || !choices.isEmpty) { Text("A larger tool…").tag("tool") }
            }
            if let rid = op.restFromOp {
                if let o = opChoices.first(where: { $0.id == rid }) {
                    Text(isCutout
                         ? String(format: "Starts where %@ stopped (%g mm above the stock bottom) and cuts the rest of the depth, then the wall passes to size.", o.name, max(0, o.stockToLeaveZ))
                         : String(format: "Cuts only what %@ left: its stock to leave (%g mm on walls, %g mm on floors) and wherever its Ø%g mm bit couldn't reach. Uses that operation's own area and depth, so changes there carry over.", o.name, o.stockToLeaveXY, o.stockToLeaveZ, o.tool.diameter))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("The operation this followed is gone, off, later in the list or on the other side. Choose another.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            } else if !isCutout && op.cutsLeftoverOnly {
                Text("Cuts only the material the enabled operations above it on this side leave, worked out by simulating them. Reorder or change them and this follows.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let r = op.restFrom, !isCutout {
                Picker("Larger tool", selection: Binding(get: { r.id }, set: { newID in
                    if let t = choices.first(where: { $0.id == newID }) {
                        b(\.restFrom).wrappedValue = t
                        if t.kind == .roughing && op.restLeftStock == 0 { b(\.restLeftStock).wrappedValue = CAMCore.Operation.hogSkin }
                    }
                })) {
                    if !choices.contains(where: { $0.id == r.id }) { Text(r.name).tag(r.id) }
                    ForEach(choices) { t in Text("T\(t.number) · \(t.name)").tag(t.id) }
                }
                NumberField(title: "It left extra stock", value: b(\.restLeftStock), step: 0.05, range: 0...3)
                Text(String(format: "Cuts only where the Ø%g mm tool couldn't reach (plus %g mm it left on purpose), using this operation's area, depth and stock to leave, so match them to the operation it follows. Following the operation itself avoids that.", r.diameter, op.restLeftStock))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if opChoices.isEmpty && choices.isEmpty {
                Text(isCutout ? "No earlier cutout to follow." : "No earlier operation or larger tool to follow.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !isCutout {
                Toggle("Run over holes a drilling operation makes", isOn: b(\.ignoresDrilledHoles))
                if op.ignoresDrilledHoles {
                    Text("Holes an enabled drilling operation on this side will make are treated as solid, so passes go straight across them instead of around.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if op.tool.hasWideShank {
                Text(String(format: "This bit's Ø%g mm shank is wider than its cutter, so beside a wall it only reaches %g mm (its flute length) below the top of the wall. Anything deeper is left, with a warning.", op.tool.shankDiameter, op.tool.fluteLength))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder func statusRow(_ op: CAMCore.Operation) -> some View {
        if case .failed(let e) = model.status[id] {
            Label(e, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        } else if let tp = model.toolpaths.first(where: { $0.id == id }) {
            let s = tp.stats(rapidRate: model.machine.rapidRate, acceleration: model.machine.acceleration)
            LabeledContent("Estimated time", value: formatDuration(s.seconds))
            LabeledContent("Cutting length", value: String(format: "%.2f m", s.cutLength / 1000))
            LabeledContent("Depth range", value: String(format: "%.2f … %.2f mm", s.bounds.min.z - (model.placed?.stockTop ?? 0), s.bounds.max.z - (model.placed?.stockTop ?? 0)))
            ForEach(tp.notes, id: \.self) { n in Label(n, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
            ForEach(tp.warnings, id: \.self) { w in Label(w, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
        }
    }

    @ViewBuilder func kindSpecific(_ op: CAMCore.Operation) -> some View {
        switch op.kind {
        case .facing:
            Section("Facing") {
                NumberField(title: "Depth", value: b(\.facingDepth), step: 0.1, range: 0.05...50)
                Toggle("Zig-zag", isOn: b(\.zigzag))
            }
        case .roughing, .pocket:
            Section("Clearing") {
                Picker("Direction", selection: b(\.direction)) {
                    Text("Climb").tag(CutDirection.climb)
                    Text("Conventional").tag(CutDirection.conventional)
                }
                .pickerStyle(.segmented)
                Text(op.kind == .pocket ? "Clears cavities inside the model outline with offset passes, with exact passes at every flat floor."
                     : "Waterline offset clearing layer by layer, with extra layers on flat faces. Entry ramps along the path.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .parallelFinish:
            Section("Raster") {
                Toggle("Automatic direction", isOn: b(\.rasterIsAuto))
                NumberField(title: op.rasterIsAuto ? "Otherwise" : "Angle", value: b(\.rasterAngle), unit: "°", step: 15, range: -180...180, digits: 0)
                Text(op.rasterIsAuto
                     ? "Passes run along the direction the surface curves most and step over where it is straightest (on a neck lying along X, the fretboard-to-headstock curve is cut along X), so the passes leave the smallest ridges. The angle is used only where no direction is better, such as a dome."
                     : "Passes run at this angle: 0° along X, 90° along Y.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Zig-zag", isOn: b(\.zigzag))
                NumberField(title: "Only slopes below", value: b(\.slopeLimit), unit: "° (0=all)", step: 5, range: 0...90, digits: 0)
            }
        case .waterlineFinish:
            Section("Waterline") {
                Picker("Direction", selection: b(\.direction)) {
                    Text("Climb").tag(CutDirection.climb)
                    Text("Conventional").tag(CutDirection.conventional)
                }
                .pickerStyle(.segmented)
                NumberField(title: "Only slopes above", value: b(\.slopeLimit), unit: "° (0=all)", step: 5, range: 0...90, digits: 0)
            }
        case .vcarve:
            Section("V-Carve") {
                Picker("Engrave", selection: b(\.vcarveSettings.source)) {
                    ForEach(VCarveSource.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Limit depth (flat bottom)", isOn: Binding(get: { op.vcarveSettings.maxDepth > 0 },
                                                                 set: { b(\.vcarveSettings.maxDepth).wrappedValue = $0 ? 2 : 0 }))
                if op.vcarveSettings.maxDepth > 0 {
                    NumberField(title: "Max depth", value: b(\.vcarveSettings.maxDepth), step: 0.1, range: 0.05...50)
                }
                if op.tool.kind != .vBit {
                    Label("Choose a V-bit for this operation.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Text(op.vcarveSettings.source == .recesses
                     ? "Engraves areas that sit below the model's top face (e.g. text sunk into a plaque). The V-bit follows the centre line of each shape and goes deeper where it is wider, so edges and corners stay sharp. Stepdown sets the depth per pass."
                     : "Carves the model's outline (e.g. an STL of lettering or a logo) into the stock top. The V-bit follows the centre line of each shape and goes deeper where it is wider, so edges and corners stay sharp. Stepdown sets the depth per pass.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Use keep-out or machine-only regions to limit what is engraved.").font(.caption).foregroundStyle(.secondary)
            }
        case .drill:
            Section("Drilling") {
                Picker("Retract", selection: b(\.drillSettings.retract)) {
                    ForEach(PeckRetract.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                if op.drillSettings.retract == .chipBreak {
                    NumberField(title: "Chip-break lift", value: b(\.drillSettings.chipBreakLift), step: 0.1, range: 0.1...5)
                }
                NumberField(title: "Hole size match ±", value: b(\.drillSettings.diameterTolerance), step: 0.1, range: 0...20)
                NumberField(title: "Through holes: below stock", value: b(\.throughDepth), step: 0.1, range: 0...5)
                if op.tool.kind == .vBit {
                    Label("Choose a drill or end mill for this operation.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                Text(String(format: "Finds round holes in the model within ±%.2g mm of the Ø%.3g mm tool and pecks each one: down by the peck depth at the plunge rate, then %@. Blind holes stop at their floor; through holes go below the stock. Drill before the cutout so parts are still held.",
                            op.drillSettings.diameterTolerance, op.tool.diameter,
                            op.drillSettings.retract == .full ? "back out above the stock to clear chips" : "a small lift to break the chip"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .dowelHoles:
            Section("Dowel holes") {
                Picker("Retract", selection: b(\.drillSettings.retract)) {
                    ForEach(PeckRetract.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                NumberField(title: "Into spoilboard", value: b(\.dowelSettings.spoilboardDepth), unit: "mm", step: 0.5, range: 0...30)
                NumberField(title: "Clearance from part", value: b(\.dowelSettings.clearance), unit: "mm", step: 0.5, range: 0...100)
                let thick = model.placed?.stockTop ?? 0
                let depth = thick + op.dowelSettings.spoilboardDepth
                LabeledContent("Hole depth", value: String(format: "%.1f mm (%.1f stock + %.1f)", depth, thick, op.dowelSettings.spoilboardDepth))
                if depth > op.tool.fluteLength {
                    Label(String(format: "Deeper than the %.0f mm the cutter can reach. Use thinner stock, a longer cutter or less spoilboard depth.", op.tool.fluteLength),
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                Text(String(format: "Ø%.3g mm holes pecked through the stock and into the spoilboard. After side A, put Ø%.3g mm dowels in the spoilboard holes, roll the stock over front-to-back onto them and re-probe Z.",
                            op.tool.diameter, op.tool.diameter))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Hole positions") {
                let picks = op.dowelSettings.picks
                LabeledContent("Placement", value: picks.isEmpty ? "Automatic" : "\(picks.count) placed by hand")
                HStack {
                    Button {
                        model.mode = model.mode == .placeDowel ? .orbit : .placeDowel
                    } label: {
                        Label(model.mode == .placeDowel ? "Done Placing" : "Place by Clicking", systemImage: "circle.circle")
                    }
                    if !picks.isEmpty { Button("Use Automatic") { model.clearDowelPicks() } }
                }
                ForEach(Array(model.dowelMarkers().enumerated()), id: \.offset) { i, m in
                    Label(String(format: "Hole %d: X%.1f Y%.1f", i + 1, m.0.x, m.0.y), systemImage: m.1 ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(m.1 ? .green : .red)
                }
                Text("Each hole you click gets a partner mirrored across the stock's centre line (front to back), so the pair lines up again after the stock is rolled over. Green spots are clear of the part and the cutout; red ones aren't and can't be used. Click a hole again to remove it. With none placed, Swarf puts one beyond each end of the part, or the best mirrored pair if the ends have no room.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .cutout:
            Section("Cutout") {
                NumberField(title: "Cut below stock", value: b(\.throughDepth), step: 0.1, range: 0...5)
                Toggle("Also cut internal holes", isOn: b(\.cutHoles))
                Picker("Direction", selection: b(\.direction)) {
                    Text("Climb").tag(CutDirection.climb)
                    Text("Conventional").tag(CutDirection.conventional)
                }
                .pickerStyle(.segmented)
            }
            Section("Finishing pass") {
                Toggle("Rough, then finish", isOn: b(\.cutoutFinishSettings.enabled))
                if op.cutoutFinishSettings.enabled {
                    NumberField(title: "Roughing leaves", value: b(\.cutoutFinishSettings.allowance), step: 0.1, range: 0.05...5)
                    HStack {
                        NumberField(title: "Finish depth of cut", value: b(\.finishStepdown), step: 0.5, range: 0.1...100)
                        if op.cutoutFinish?.stepdown != nil {
                            Button("4×") { b(\.cutoutFinishSettings.stepdown).wrappedValue = nil }
                                .controlSize(.small).help("Reset to 4× the roughing stepdown")
                        }
                    }
                    Text(String(format: "Roughing passes cut %.2g mm deep and stay %.2g mm off the part. A finishing pass then takes the last %.2g mm in %d pass%@ of up to %.2g mm, for a clean edge. Tabs are left in both.",
                                op.cutting.stepdown, op.cutoutFinishSettings.allowance, op.cutoutFinishSettings.allowance,
                                op.tool.passLevels(top: 0, bottom: -((model.placed?.stockTop ?? 0) + op.throughDepth), stepdown: op.finishStepdown).count,
                                op.tool.passLevels(top: 0, bottom: -((model.placed?.stockTop ?? 0) + op.throughDepth), stepdown: op.finishStepdown).count == 1 ? "" : "es",
                                op.finishStepdown))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Chip clearance") {
                Toggle("Wide trench", isOn: b(\.cutoutTrenchSettings.enabled))
                if op.cutoutTrenchSettings.enabled {
                    NumberField(title: "Trench width", value: b(\.cutoutTrenchSettings.widthFactor), unit: "× tool", step: 0.1,
                                range: CutoutTrench.widthRange, digits: 2)
                    NumberField(title: "Second pass feed", value: b(\.cutoutTrenchSettings.innerFeedFactor), unit: "× feed", step: 0.05,
                                range: CutoutTrench.innerFeedRange, digits: 2)
                    Text(String(format: "Each roughing level is cut twice: first %.1f mm further out, then next to the part, so the slot is %.1f mm wide instead of %.1f mm and chips can clear. The second pass only cuts part of the bit's width, so it runs at %.0f mm/min. Roughing still takes much longer, and the stock needs this much room around the part.",
                                op.trenchExtra, op.tool.diameter + op.trenchExtra, op.tool.diameter,
                                op.cutting.feed * op.cutoutTrenchSettings.innerFeedFactor))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Section("Holding tabs") {
                Toggle("Tabs", isOn: b(\.tabs.enabled))
                if op.tabs.enabled {
                    if op.tabs.manualPositions.isEmpty {
                        IntField(title: "Tabs per loop", value: b(\.tabs.countPerLoop), range: 1...24)
                    }
                    NumberField(title: "Width", value: b(\.tabs.width), step: 0.5, range: 1...100)
                    NumberField(title: "Height", value: b(\.tabs.height), step: 0.25, range: 0.2...50)
                    Picker("Shape", selection: b(\.tabs.shape)) {
                        Text("Triangular (ramped)").tag(TabShape.triangular)
                        Text("Rectangular").tag(TabShape.rectangular)
                    }
                    NumberField(title: "Skip loops shorter than", value: b(\.tabs.minLoopLength), step: 5, range: 0...1000, digits: 0)
                    HStack {
                        Button { model.mode = .placeTab } label: { Label("Place tabs by clicking", systemImage: "pin") }
                        if !op.tabs.manualPositions.isEmpty {
                            Text("\(op.tabs.manualPositions.count) placed").foregroundStyle(.secondary)
                            Button("Clear") { b(\.tabs.manualPositions).wrappedValue = [] }
                        }
                    }
                }
            }
        }
    }
}
