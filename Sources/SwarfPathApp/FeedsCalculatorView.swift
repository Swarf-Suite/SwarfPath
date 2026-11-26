import SwiftUI
import CAMCore

/// Chip-load calculator: aim for a chip load inside the recommended range for the bit and material, at the fastest
/// spindle speed the machine's maximum feed allows (or a speed you choose), then apply the result.
struct FeedsCalculatorSheet: View {
    let tool: Tool
    let material: CAMCore.Material
    /// Where the result goes, for the explanation ("this tool's MDF defaults", "this operation").
    let destination: String
    let current: CuttingData
    var apply: (CuttingData) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var machineID: String
    @State private var maxFeed: Double
    @State private var target = 0.5
    @State private var slotting: Bool
    @State private var engagement: Double
    @State private var autoRPM = true
    @State private var rpm: Double
    @State private var setStepdown = false
    @State private var shallow: Bool
    @State private var depth: Double

    /// `axialDepth`: how deep a ball or bull nose cuts below its tip in the operation, if shallower than its corner.
    init(tool: Tool, material: CAMCore.Material, destination: String, current: CuttingData, machineID: String, slotting: Bool,
         axialDepth: Double? = nil, apply: @escaping (CuttingData) -> Void) {
        self.tool = tool; self.material = material; self.destination = destination; self.current = current; self.apply = apply
        let corner = tool.kind == .ball ? tool.radius : tool.kind == .bullNose ? tool.cornerRadius : 0
        _shallow = State(initialValue: axialDepth.map { $0 < corner - 1e-6 } ?? false)
        _depth = State(initialValue: min(max(0.05, axialDepth ?? corner / 2), max(0.05, corner)))
        let m = MachineProfile.find(machineID)
        _machineID = State(initialValue: m.id)
        _maxFeed = State(initialValue: m.maxFeed)
        _slotting = State(initialValue: slotting)
        _engagement = State(initialValue: min(100, max(1, current.stepoverPercent)))
        _rpm = State(initialValue: min(m.maxRPM, max(m.minRPM, current.rpm)))
    }

    var machine: MachineProfile { MachineProfile.find(machineID) }
    /// Height of the rounded part of the cutter (mm); 0 for bits that cut with their full diameter at the tip.
    var corner: Double { tool.kind == .ball ? tool.radius : tool.kind == .bullNose ? tool.cornerRadius : 0 }
    var hasCorner: Bool { corner > 0.01 }

    var result: FeedsCalculator.Result {
        var r = FeedsCalculator.Request(tool: tool, material: material, maxFeed: maxFeed, minRPM: machine.minRPM, maxRPM: machine.maxRPM)
        r.target = target
        r.engagementPercent = slotting ? 100 : engagement
        r.axialDepth = hasCorner && shallow ? depth : nil
        r.rpm = autoRPM ? nil : rpm
        return FeedsCalculator.calculate(r)
    }

    var body: some View {
        let res = result
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                BitView(kind: tool.kind, flute: tool.fluteStyle, shankRatio: tool.shankDiameter / max(0.1, tool.diameter))
                    .frame(width: 54, height: 74)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Feeds & Speeds").font(.title2.bold())
                    Text(String(format: "T%d · %@ · Ø%g mm · %d flute%@%@ · %@", tool.number, tool.name, tool.diameter, tool.flutes,
                                tool.flutes == 1 ? "" : "s", tool.fluteStyle == .unspecified ? "" : " " + tool.fluteStyle.displayName.lowercased(),
                                material.name))
                        .foregroundStyle(.secondary)
                }
            }
            .padding([.horizontal, .top], 20)
            Form {
                Section("Machine") {
                    Picker("Machine", selection: $machineID) {
                        ForEach(MachineProfile.builtIn) { Text($0.name).tag($0.id) }
                    }
                    .onChange(of: machineID) { _, _ in maxFeed = machine.maxFeed; rpm = min(machine.maxRPM, max(machine.minRPM, rpm)) }
                    NumberField(title: "Fastest feed it handles", value: $maxFeed, unit: "mm/min", step: 100, range: 100...20000, digits: 0)
                    LabeledContent("Spindle range", value: String(format: "%.0f – %.0f RPM", machine.minRPM, machine.maxRPM))
                }
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: $target, in: 0...1) {
                            Text("Chip load")
                        } minimumValueLabel: { Text("Gentle").font(.caption) } maximumValueLabel: { Text("Aggressive").font(.caption) }
                        Text(String(format: "Aiming for %.3f mm per tooth (recommended %.3f – %.3f for this bit in %@).",
                                    res.targetChipLoad, res.range.lowerBound, res.range.upperBound, material.name))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Cut", selection: $slotting) {
                        Text("Full-width slot").tag(true)
                        Text("Side cut").tag(false)
                    }
                    .pickerStyle(.segmented)
                    if !slotting {
                        NumberField(title: "Width of cut", value: $engagement, unit: "% of Ø", step: 5, range: 1...100, digits: 0)
                    }
                    if hasCorner {
                        Toggle(String(format: "Shallower than the %@ (%g mm)", tool.kind == .ball ? "ball" : "corner radius", corner), isOn: $shallow)
                        if shallow {
                            NumberField(title: "Depth of cut", value: $depth, unit: "mm", step: 0.1, range: 0.05...corner)
                            Text(String(format: "At %g mm deep it cuts with a Ø%.2g mm circle, not Ø%g, so the chip is thinner and the feed goes up to keep it.", depth, res.effectiveDiameter, tool.diameter))
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Toggle("Fastest spindle speed for this chip load", isOn: $autoRPM)
                    if !autoRPM {
                        Slider(value: $rpm, in: machine.minRPM...max(machine.minRPM + 100, machine.maxRPM), step: 100) {
                            Text(String(format: "Spindle %.0f RPM", rpm)).monospacedDigit()
                        }
                    }
                } header: {
                    Text("Target")
                } footer: {
                    Text("Cutouts and the first pass of a pocket cut a full-width slot. With a narrow side cut (finishing, light stepovers) the chip comes out thinner than the feed per tooth, so the feed goes up to keep it the same. Too small a chip rubs and burns; too big a chip strains the bit.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Result") {
                    row("Spindle", String(format: "%.0f RPM", res.rpm), was: String(format: "%.0f", current.rpm))
                    row("Feed", String(format: "%.0f mm/min", res.feed), was: String(format: "%.0f", current.feed))
                    row("Plunge", String(format: "%.0f mm/min", res.plunge), was: String(format: "%.0f", current.plunge))
                    LabeledContent("Chip load", value: String(format: "%.3f mm/tooth", res.chipLoad))
                    if res.thinning > 1.001 {
                        LabeledContent("Feed per tooth", value: String(format: "%.3f mm (×%.2f for chip thinning)", res.feedPerTooth, res.thinning))
                    }
                    if let note = limitNote(res) {
                        Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    let speedup = current.feed > 0 ? res.feed / current.feed : 1
                    if abs(speedup - 1) > 0.05 {
                        Text(String(format: "Feed %@ %.0f%% on the current value.", speedup > 1 ? "up" : "down", abs(speedup - 1) * 100))
                            .font(.caption).foregroundStyle(speedup > 1 ? .green : .orange)
                    }
                    let sd = FeedsCalculator.recommendedStepdown(tool: tool, material: material)
                    Toggle(String(format: "Also set stepdown to %.2g mm (now %.2g)", sd, current.stepdown), isOn: $setStepdown)
                }
            }
            .formStyle(.grouped)
            HStack {
                Text("Values are starting points from typical chip-load charts: listen to the cut and check the chips, then adjust.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply to \(destination)") {
                    var c = current
                    c.rpm = res.rpm; c.feed = res.feed; c.plunge = res.plunge
                    if setStepdown { c.stepdown = (FeedsCalculator.recommendedStepdown(tool: tool, material: material) * 100).rounded() / 100 }
                    apply(c)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 540, height: 600)
    }

    func row(_ title: String, _ value: String, was: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text("was \(was)").font(.caption).foregroundStyle(.secondary)
                Text(value).monospacedDigit().bold()
            }
        }
    }

    func limitNote(_ r: FeedsCalculator.Result) -> String? {
        switch r.limit {
        case .none:
            return autoRPM ? "Full spindle speed: the machine's maximum feed isn't reached." : nil
        case .machineFeed:
            if let q = r.quieterRPM {
                return String(format: "The machine's %.0f mm/min limit decides. At %.0f RPM the chip is thinner than the target; %.0f RPM gives the target chip at the same feed, and is quieter.", maxFeed, r.rpm, q)
            }
            return String(format: "The machine's %.0f mm/min limit decides, so the spindle is slowed to %.0f RPM to keep the chip load: same speed, quieter, less heat.", maxFeed, r.rpm)
        case .machineFeedAndMinRPM:
            return String(format: "Even at the spindle's slowest (%.0f RPM) the machine's %.0f mm/min can't reach the target chip load. Expect some rubbing; a bit with fewer flutes would help.", machine.minRPM, maxFeed)
        }
    }
}
