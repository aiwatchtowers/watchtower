import SwiftUI
import WatchtowerCore

/// The card's **History**: runs newest first; each row expands into its
/// steps. A failed run offers **Rerun**, an active one **Cancel**.
struct AutomationRunHistoryView: View {
    let runs: [AutomationRun]
    let steps: [Int64: [AutomationRunStep]]
    let expanded: Set<Int64>
    /// Run now's state: a rerun is refused whenever Run now is.
    let canRun: Bool
    let isBusy: Bool
    let now: Date
    let onToggle: (Int64) -> Void
    let onRerun: (Int64) -> Void
    let onCancel: (Int64) -> Void
    let links: AutomationStepRow.Links

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("History")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            Divider()
            if runs.isEmpty {
                Text("No runs yet.")
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                    if index > 0 { Divider() }
                    runRow(run)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(nsColor: .separatorColor)))
    }

    private func runRow(_ run: AutomationRun) -> some View {
        let isExpanded = expanded.contains(run.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button { onToggle(run.id) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Circle().fill(run.status.badge.color).frame(width: 7, height: 7)
                    Text(AutomationCardPresentation.runHeadline(run, now: now))
                    Text(AutomationCardPresentation.triggerLabel(run))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(metrics(run))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                expandedBody(run)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func metrics(_ run: AutomationRun) -> String {
        var parts = [AutomationCardPresentation.tokensText(run.totalTokens, estimated: run.tokensEstimated)]
        if let cost = AutomationCardPresentation.reportedCostText(run.reportedCostUSD) {
            parts.append(cost)
        }
        return parts.joined(separator: " · ")
    }

    private func expandedBody(_ run: AutomationRun) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            let runSteps = steps[run.id] ?? []
            if runSteps.isEmpty {
                Text("No steps recorded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(runSteps) { step in
                AutomationStepRow(step: step, links: links)
            }
            if !run.summary.isEmpty {
                Text(run.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !run.error.isEmpty {
                Text(run.error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if AutomationCardPresentation.canRerun(run) || run.status.isActive {
                HStack(spacing: 8) {
                    if AutomationCardPresentation.canRerun(run) {
                        Button("Rerun") { onRerun(run.id) }
                            .disabled(!canRun || isBusy)
                    }
                    if run.status.isActive {
                        Button("Cancel") { onCancel(run.id) }
                            .disabled(isBusy)
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
