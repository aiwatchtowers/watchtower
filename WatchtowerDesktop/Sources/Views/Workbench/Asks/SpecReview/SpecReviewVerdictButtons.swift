import SwiftUI
import WatchtowerCore

/// The spec review screen's verdicts in the drawer's footer, beside Dismiss,
/// on every step (spec 2026-10-28 §5, ask #690): **Request changes (N)** —
/// a new review round, on when there is a comment or a note — and
/// **Approve**, always on: with comments the author applies them and goes
/// on. Why both are off (an ask question not answered, a long note) sits
/// to their left.
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

    /// The prominent one is the verdict the owner is heading for: Request
    /// changes while there is something to change, else Approve.
    @ViewBuilder
    private var requestChanges: some View {
        let count = model.requestCount
        let button = Button(count > 0 ? "Request changes (\(count))" : "Request changes") { model.pressRequestChanges() }
        if model.canSend {
            button
                .buttonStyle(.kitPrimary)
                .help("Send your comments for a new review round: the author fixes the document and files it again. Shortcut: ⌘⇧↩")
        } else {
            button
                .buttonStyle(.kitSecondary)
                .disabled(true)
                .help("Mark a finding Fix, comment on one, or write a note first")
        }
    }

    @ViewBuilder
    private var approve: some View {
        let count = model.requestCount
        let button = Button("Approve") { model.pressApprove() }
            .help(count > 0
                ? "Approve: your \(count) comment\(count == 1 ? "" : "s") go to the author as fixes to make, with no new review. Shortcut: ⌘↩"
                : "Approve the document as it is. Shortcut: ⌘↩")
        if model.canSend {
            button.buttonStyle(.kitSecondary)
        } else {
            button.buttonStyle(.kitPrimary)
        }
    }
}
