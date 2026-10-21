import SwiftUI
import WatchtowerCore

/// A pending `save_automation` proposal in the Inbox reading pane: what the
/// recipe is, where it goes, when it runs and what it may do. The recipe is
/// read and saved in the editor panel (**Open Draft**), where only the
/// owner's press saves; **Reject** decides the proposal through the
/// registry (`ActionStripViewModel.reject`, STRIP-03).
struct SaveAutomationProposalPane: View {
    let action: AgentAction
    let workbenchName: (Int64) -> String?
    /// The proposal's "⚙ automation · run #n" label, when it has one.
    var contextLabel: String?
    /// A Reject of this proposal is under way.
    var inFlight = false
    /// Why the last Reject failed.
    var gestureError: String?
    let onOpenDraft: (SaveAutomationCardModel) -> Void
    let onReject: () -> Void

    var body: some View {
        let model = SaveAutomationCardModel(action: action)
        let summary = SaveAutomationProposalSummary(model: model, workbenchName: workbenchName)
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Text(contextLabel ?? "Assistant proposal")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(summary.name)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Grid(alignment: .leading, horizontalSpacing: Spacing.medium, verticalSpacing: Spacing.compact) {
                line("For", summary.scope)
                line("When", summary.when)
                line("It may", summary.mayLine)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.medium)
            .card()
            if !action.reason.isEmpty {
                Text(action.reason)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: Spacing.regular) {
                Button("Open Draft") { onOpenDraft(model) }
                    .buttonStyle(.kitPrimary)
                    .help("Read the whole recipe in the editor and save it there")
                Button("Reject", action: onReject)
                    .buttonStyle(.kitSecondary)
                    .disabled(inFlight)
            }
            .controlSize(.small)
            .padding(.top, Spacing.small)
            if let gestureError {
                Text(gestureError)
                    .font(.caption)
                    .foregroundStyle(Tone.status("red"))
                    .textSelection(.enabled)
            }
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
