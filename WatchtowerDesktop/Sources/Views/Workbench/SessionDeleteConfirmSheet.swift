import SwiftUI
import WatchtowerCore

/// The Delete confirmation for a live session. Every delete cleans up in
/// the background once its Undo window ends (board #1716), so the dialog
/// offers no cleanup choice and plans nothing.
struct SessionDeleteConfirmSheet: View {
    let vm: WorkbenchesViewModel
    let session: TerminalSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete “\(session.title)”?").font(.headline)
            Text(AgentChoicePresentation.deleteSessionMessage(session.kind))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Delete Session", role: .destructive) {
                    let (vm, session) = (vm, session)
                    dismiss()
                    Task { await vm.delete(session) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
