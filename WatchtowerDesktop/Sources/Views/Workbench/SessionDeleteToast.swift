import SwiftUI
import WatchtowerCore

/// "Session deleted" / "N sessions deleted" with Undo while the Undo
/// window of a delete batch runs (board #480, PROJ-17, spec
/// 2026-10-12-sessions-panel-design §4.5): at the bottom of the left
/// column, or over the page while the panel is hidden. Undo restores the
/// whole batch and hands the keyboard to the panel, where ⌘Z does the
/// same. Gone on Undo or once the batch is committed.
struct SessionDeleteToast: View {
    @Bindable var vm: WorkbenchesViewModel

    var body: some View {
        if let text = vm.pendingDeleteToast {
            HStack(spacing: 8) {
                Text(text)
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("Undo") {
                    vm.requestPanelKeyboard()
                    Task { await vm.undoPendingDeletes() }
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Undo delete")
                .help("Restore what was deleted (⌘Z in the sessions panel)")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .padding(8)
            .accessibilityElement(children: .contain)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onChange(of: text, initial: true) { _, text in
                AccessibilityNotification.Announcement("\(text). Undo is available.").post()
            }
        }
    }
}

/// The ✕ of a session row whose agent is not working
/// (`SessionDeletePolicy.isQuick`): deletes it at once, with Undo. Shown
/// while the row is hovered or under the panel cursor; it sits outside the
/// row's open click, which would start the session.
struct SessionRowDeleteButton: View {
    let onDelete: () -> Void

    var body: some View {
        Button(action: onDelete) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Delete session")
        .accessibilityLabel("Delete session")
    }
}
