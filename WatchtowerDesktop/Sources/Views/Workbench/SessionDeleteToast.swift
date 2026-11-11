import SwiftUI
import WatchtowerCore

/// "Session deleted" / "N sessions deleted" with Undo while the Undo
/// window of a delete batch runs (board #480, PROJ-17, spec
/// 2026-10-12-sessions-panel-design §4.5): in its own bar under the
/// panel's list (above FILES), or over the page while the panel is hidden.
/// Undo restores the whole batch and hands the keyboard to the panel,
/// where ⌘Z does the same. Gone on Undo or once the batch is committed.
/// In its place, when no Undo window runs, the quiet notice of the
/// background cleanups that ended clean (board #1716), for 6 s.
struct SessionDeleteToast: View {
    @Bindable var vm: WorkbenchesViewModel

    var body: some View {
        if vm.pendingDeleteToast == nil, let notice = vm.cleanupNotice {
            SessionCleanupNoticeBar(notice: notice)
        } else if let text = vm.pendingDeleteToast {
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

/// "Cleaned up “T”: removed 3 worktrees and 12 branches (~2.1 GB)." on the
/// Undo bar's place (spec 2026-11-10-auto-cleanup-on-session-delete §3):
/// the lead in the success tone, the rest plain; several deletes in a row
/// read as one joined notice. The view model hides it after
/// `cleanupNoticeDuration`.
struct SessionCleanupNoticeBar: View {
    let notice: SessionCleanupNotice

    var body: some View {
        Text(attributed)
            .font(.callout)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.cozy)
            .padding(.vertical, Spacing.compact)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.row))
            .overlay(RoundedRectangle(cornerRadius: Radius.row).strokeBorder(.separator))
            .padding(Spacing.regular)
            .accessibilityElement(children: .combine)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onChange(of: notice.text, initial: true) { _, text in
                AccessibilityNotification.Announcement(text).post()
            }
    }

    private var attributed: AttributedString {
        var lead = AttributedString(notice.lead)
        lead.font = .callout.weight(.semibold)
        lead.foregroundColor = Tone.success
        return lead + AttributedString(notice.rest)
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
