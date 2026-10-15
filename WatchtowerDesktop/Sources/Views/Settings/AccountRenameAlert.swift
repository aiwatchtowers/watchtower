import SwiftUI

/// The account a Settings row's "Rename…" is renaming: its id and the name it
/// shows now (the alert's starting text).
struct AccountRenameTarget: Identifiable, Equatable {
    let id: Int
    let currentName: String
}

/// The "Rename…" alert shared by the connected-account lists in Settings
/// (Slack, Jira, Google, mail, calendars). Rename is offered only for a
/// non-empty name; `onRename` gets the account and the trimmed new name.
private struct AccountRenameAlert: ViewModifier {
    @Binding var target: AccountRenameTarget?
    let onRename: (AccountRenameTarget, String) -> Void
    @State private var draft = ""

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    func body(content: Content) -> some View {
        content
            .alert(
                "Rename \(target?.currentName ?? "account")",
                isPresented: Binding(
                    get: { target != nil },
                    set: { if !$0 { target = nil } }
                )
            ) {
                TextField("Name", text: $draft)
                Button("Rename") {
                    if let target, !trimmed.isEmpty { onRename(target, trimmed) }
                    target = nil
                }
                .disabled(trimmed.isEmpty)
                Button("Cancel", role: .cancel) { target = nil }
            } message: {
                Text("The name this account shows under in Watchtower.")
            }
            .onChange(of: target) { _, new in draft = new?.currentName ?? "" }
    }
}

extension View {
    /// Presents the account "Rename…" alert while `target` is non-nil.
    func accountRenameAlert(
        _ target: Binding<AccountRenameTarget?>,
        onRename: @escaping (AccountRenameTarget, String) -> Void
    ) -> some View {
        modifier(AccountRenameAlert(target: target, onRename: onRename))
    }
}
