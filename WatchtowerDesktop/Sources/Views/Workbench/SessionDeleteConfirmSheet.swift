import SwiftUI
import WatchtowerCore

/// The Delete confirmation for a live session. Every delete cleans up in
/// the background once its Undo window ends (board #1716, spec
/// 2026-11-10-auto-cleanup-on-session-delete §1), so the dialog is a plain
/// confirmation: no cleanup choice, no plan. Its copy is
/// `SessionAutoCleanupPresentation`'s.
struct SessionDeleteConfirmSheet: View {
    let vm: WorkbenchesViewModel
    let session: TerminalSession
    @Environment(\.dismiss) private var dismiss

    private typealias Copy = SessionAutoCleanupPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Text(Copy.deleteTitle(session.title)).font(.headline)
            Text(Copy.deleteMessage(isWorkbenchSession: session.projectID != nil, kind: session.kind))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.regular) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.kitSecondary)
                    .keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    let (vm, session) = (vm, session)
                    dismiss()
                    Task { await vm.delete(session) }
                }
                .buttonStyle(.kitDestructive)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.page)
        .frame(width: 440)
    }
}
