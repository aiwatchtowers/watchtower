import SwiftUI
import WatchtowerCore

/// "Chat “…” deleted · Undo ⌘Z" while a quick delete's Undo window runs
/// (spec 2026-10-26 §5.3), the sessions panel's `SessionDeleteToast` shape,
/// in its own bar under the Chats panel's list. Undo brings the chat back
/// and hands the keyboard to the panel, where ⌘Z does the same.
struct ChatDeleteToast: View {
    @Bindable var historyVM: ChatHistoryViewModel

    var body: some View {
        if let text = historyVM.pendingDeleteToast {
            HStack(spacing: Spacing.regular) {
                Text(text)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Spacing.small)
                Button("Undo ⌘Z") {
                    historyVM.requestPanelKeyboard()
                    historyVM.undoPendingDelete()
                }
                .buttonStyle(.kitQuiet)
                .accessibilityLabel("Undo delete")
                .help("Restore the chat (⌘Z in the chat list)")
            }
            .padding(.horizontal, Spacing.cozy)
            .padding(.vertical, Spacing.compact)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.row))
            .overlay(RoundedRectangle(cornerRadius: Radius.row).strokeBorder(.separator))
            .padding(Spacing.regular)
            .accessibilityElement(children: .contain)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onChange(of: text, initial: true) { _, text in
                AccessibilityNotification.Announcement("\(text). Undo is available.").post()
            }
        }
    }
}

/// The ✕ of a chat row that neither answers nor waits for approval
/// (`ChatPanelRowState.allowsQuickDelete`): deletes it at once, with Undo.
/// Shown while the row is hovered or under the panel cursor.
struct ChatRowDeleteButton: View {
    let onDelete: () -> Void

    var body: some View {
        Button(action: onDelete) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Delete chat")
        .accessibilityLabel("Delete chat")
    }
}
