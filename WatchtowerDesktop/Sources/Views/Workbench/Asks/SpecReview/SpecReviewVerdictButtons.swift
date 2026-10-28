import SwiftUI
import WatchtowerCore

/// The spec review screen's verdicts in the drawer's footer, beside Dismiss,
/// on every step (spec 2026-10-28 §5): **Request changes (N)** — the
/// comment marks and margin comments go to the author — and **Approve**,
/// which is off while anything would go back (D7). Why both are off (an
/// ask question not answered, a long note) sits to their left.
struct SpecReviewVerdictButtons: View {
    let model: SpecReviewModel

    var body: some View {
        let blocker = model.answerBlocker
        HStack(spacing: Spacing.regular) {
            if let blocker {
                Text(blocker).font(.caption).foregroundStyle(Tone.warning).lineLimit(2)
                if SpecReviewPresentation.showsGoToMeaning(row: model.row, hasQuestions: model.hasQuestions) {
                    Button("Go to Meaning") { model.phase = .meaning }.buttonStyle(.kitQuiet)
                }
            }
            if model.isAnswering { ProgressView().controlSize(.small) }
            HStack(spacing: Spacing.regular) {
                requestChanges
                approve
            }
            .disabled(blocker != nil || model.isAnswering)
        }
        .controlSize(.small)
        .confirmationDialog(
            model.approveConfirmMessage,
            isPresented: Binding(get: { model.confirmingApprove }, set: { model.confirmingApprove = $0 })
        ) {
            Button("Approve") { Task { _ = await model.approve() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// The prominent one is the verdict that can go: Request changes while
    /// a comment would go back, else Approve.
    @ViewBuilder
    private var requestChanges: some View {
        let count = model.requestCount
        let button = Button(count > 0 ? "Request changes (\(count))" : "Request changes") { model.pressRequestChanges() }
        if model.canSend {
            button
                .buttonStyle(.kitPrimary)
                .help("Send your comments to the author; it fixes the document and files it again. Shortcut: ⌘⇧↩")
        } else {
            button
                .buttonStyle(.kitSecondary)
                .disabled(true)
                .help("Mark a finding Fix or comment on one first")
        }
    }

    @ViewBuilder
    private var approve: some View {
        let button = Button("Approve") { model.pressApprove() }
        if model.canApprove {
            button.buttonStyle(.kitPrimary).help("Approve the document as it is. Shortcut: ⌘↩")
        } else {
            let count = model.requestCount
            button
                .buttonStyle(.kitSecondary)
                .disabled(true)
                .help("You have \(count) comment\(count == 1 ? "" : "s") for the author — Request changes, or remove them to approve")
        }
    }
}
