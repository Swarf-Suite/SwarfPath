import CAMCore
import SwiftUI

/// The plan Auto Plan worked out, bit by bit in the order they're fitted, with why each bit was chosen. Nothing
/// changes until "Use This Plan".
struct AutoPlanSheet: View {
    @ObservedObject var model: ProjectModel
    let proposal: ProjectModel.AutoPlanProposal
    @Environment(\.dismiss) private var dismiss

    /// Consecutive operations on the same bit: one G-code file each.
    var runs: [(tool: Tool, ops: [CAMCore.Operation])] {
        var out: [(tool: Tool, ops: [CAMCore.Operation])] = []
        for op in proposal.operations where op.enabled {
            if let last = out.last, last.tool.id == op.tool.id { out[out.count - 1].ops.append(op) } else { out.append((op.tool, [op])) }
        }
        return out
    }

    var body: some View {
        let changes = JobTemplates.toolChanges(proposal.operations)
        VStack(alignment: .leading, spacing: 12) {
            Text("Auto Plan").font(.headline)
            Text("\(runs.count) bit\(runs.count == 1 ? "" : "s") · \(changes) bit change\(changes == 1 ? "" : "s") · about \(duration(proposal.seconds))")
                .font(.title3.weight(.semibold))
            Text("Each bit is its own G-code file. SwarfGRBL runs them in order and stops between them to change the bit and re-probe Z.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(runs.enumerated()), id: \.offset) { i, run in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Bit \(i + 1): T\(run.tool.number) \(run.tool.name)").font(.body.weight(.semibold))
                            ForEach(run.ops) { op in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: op.kind.symbol).frame(width: 16)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(op.name + (op.areaID != nil ? " (its area)" : ""))
                                        if let why = proposal.plan.reasons[op.id] {
                                            Text(why).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                    }
                    ForEach(proposal.plan.notes, id: \.self) { n in
                        Label(n, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    }
                }
            }
            .frame(maxHeight: 420)
            if proposal.replacing > 0 || proposal.areaOps > 0 {
                Text([proposal.replacing > 0 ? "Replaces the \(proposal.replacing) operation\(proposal.replacing == 1 ? "" : "s") in the job (undo with ⌘Z)." : nil,
                      proposal.areaOps > 0 ? "Keeps the \(proposal.areaOps) operation\(proposal.areaOps == 1 ? "" : "s") in areas." : nil]
                    .compactMap { $0 }.joined(separator: " "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use This Plan") {
                    let p = proposal
                    dismiss()
                    model.applyAutoPlan(p)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    func duration(_ s: Double) -> String {
        let m = Int((s / 60).rounded())
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(max(1, m)) min"
    }
}
