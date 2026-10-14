import SwiftUI
import WatchtowerCore

extension View {
    /// The Rename sheet, the Delete confirmation and the Clean Up… sheet
    /// behind `SessionRowActions`.
    func sessionActionDialogs(
        vm: WorkbenchesViewModel,
        renaming: Binding<TerminalSession?>,
        deleting: Binding<TerminalSession?>,
        cleaning: Binding<TerminalSession?> = .constant(nil)
    ) -> some View {
        modifier(SessionActionDialogs(vm: vm, renaming: renaming, deleting: deleting, cleaning: cleaning))
    }
}

private struct SessionActionDialogs: ViewModifier {
    let vm: WorkbenchesViewModel
    @Binding var renaming: TerminalSession?
    @Binding var deleting: TerminalSession?
    @Binding var cleaning: TerminalSession?

    func body(content: Content) -> some View {
        content
            .sheet(item: $renaming) { session in
                RenameSessionSheet(session: session) { title in
                    Task { await vm.rename(session, to: title) }
                }
            }
            // A sheet rather than a confirmationDialog: its cleanup line and
            // buttons follow the plan as it arrives (board #535).
            .sheet(item: $deleting) { session in
                SessionDeleteConfirmSheet(vm: vm, session: session)
            }
            .sheet(item: $cleaning) { session in
                SessionCleanupSheet(vm: vm, session: session)
            }
    }
}

private struct RenameSessionSheet: View {
    let session: TerminalSession
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename session").font(.headline)
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .onAppear { title = session.title }
    }

    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() {
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}
