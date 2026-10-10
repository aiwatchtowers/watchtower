import SwiftUI
import WatchtowerCore

/// The panel's Asks section: every ask about the open target, newest first
/// (spec 2026-10-03 Part 8). A row opens it in the ask drawer the way a
/// "Waiting for you" row does — a review ask shows its document there.
struct WorkbenchPanelAsks: View {
    let vm: WorkbenchBoardViewModel
    /// `WorkbenchesViewModel.showAsk`.
    let onShowAsk: (Int64, Int64) async -> Bool
    /// Why an ask did not open, a full sentence shown as is; nil = it is gone.
    let failure: () -> String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            WorkbenchDetailSectionHeader(title: "Asks", systemImage: "person.crop.circle.badge.questionmark",
                                         count: vm.selectedAsks.count)
                .padding(.bottom, 4)
            ForEach(vm.selectedAsks) { ask in
                Button {
                    Task { await vm.openAsk(ask.id, show: onShowAsk, failure: failure) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ask.title)
                            .font(.callout)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(ask.statusLabel)
                            .font(.caption)
                            .foregroundStyle(ask.status == OwnerAskStatus.open.rawValue ? Color.accentColor : .secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open the ask")
            }
        }
    }
}

/// The panel's Comments | History tabs; both are read with the selection
/// and on reload (`WorkbenchBoardViewModel.load`), not per tab switch.
struct WorkbenchPanelActivity: View {
    let vm: WorkbenchBoardViewModel

    private enum Tab: Hashable {
        case comments
        case history
    }

    @State private var tab = Tab.comments

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Activity", selection: $tab) {
                Text(vm.threads.isEmpty ? "Comments" : "Comments \(vm.threads.count)").tag(Tab.comments)
                Text("History").tag(Tab.history)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            switch tab {
            case .comments: comments
            case .history: history
            }
        }
    }

    @ViewBuilder
    private var comments: some View {
        if vm.threads.isEmpty {
            Text("No comments yet. Agents ask their questions here; write below to ask or answer.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(vm.threads) { thread in
            CommentThreadView(
                thread: thread.content,
                onReply: { vm.reply(to: thread.id, body: $0) },
                onResolve: thread.root.isOpen ? { vm.setThreadStatus(rootID: thread.id, status: "resolved") } : nil,
                onReopen: thread.root.isOpen ? nil : { vm.setThreadStatus(rootID: thread.id, status: "open") }
            )
        }
    }

    /// Status changes, newest first: "from → to", who, when.
    @ViewBuilder
    private var history: some View {
        if vm.selectedHistory.isEmpty {
            Text("No status changes yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        ForEach(vm.selectedHistory) { change in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.transition(change))
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(change.actor.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let date = Target.parseTimestamp(change.changedAt) {
                    Text(date, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(change.changedAt)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private static func transition(_ change: TargetStatusChange) -> String {
        let to = WorkbenchBoardCard.statusLabel(change.toStatus)
        guard let from = change.fromStatus else { return "Created as \(to)" }
        return "\(WorkbenchBoardCard.statusLabel(from)) → \(to)"
    }
}

/// The panel's foot: the error row (the board's banner sits under the
/// panel, so a failed rename, status, priority, description or comment
/// write shows here too) over the pinned comment field.
struct WorkbenchPanelComposer: View {
    let vm: WorkbenchBoardViewModel

    /// The open target's own draft (`WorkbenchBoardViewModel.commentDraft`):
    /// switching the panel to another target switches the draft with it.
    private var draft: Binding<String> {
        Binding(get: { vm.commentDraft }, set: { vm.commentDraft = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = vm.errorMessage {
                errorRow(error)
            }
            field
        }
    }

    private func errorRow(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(error)
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { vm.dismissError() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Dismiss")
                .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
    }

    private var canSend: Bool {
        !vm.commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        // Cleared only once the comment is saved: a failed write keeps the text.
        vm.sendCommentDraft()
    }

    /// The chat composer's idiom: a rounded field and a round send button.
    private var field: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Return is a new line; ⌘↩ or ⌃↩ sends, and only while this
            // field has focus: a window-wide shortcut would also fire from a
            // terminal in the other split pane and post a stale draft.
            CommentTextEditor(text: draft, placeholder: "Comment or answer the agent…",
                              minHeight: 34, maxHeight: 140, cornerRadius: 16, onSubmit: send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(canSend ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
            }
            .buttonStyle(.borderless)
            .disabled(!canSend)
            .help("Comment (⌘↩ or ⌃↩)")
            .accessibilityLabel("Comment")
            .padding(.bottom, 3)
        }
        .padding(12)
    }
}
