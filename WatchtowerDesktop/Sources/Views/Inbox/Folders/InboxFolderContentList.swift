import SwiftUI
import WatchtowerCore

/// The Inbox's second column: the selected folder's entries, newest change
/// first, with unread dots and the "updated …" lines, or the folder's empty
/// state (`EmptyStateCopyTable`'s `inbox`, `inboxFolder`, `inboxApprovals`)
/// with what the caller keeps under it (`emptyExtra`: the empty root's
/// OWNER-02 line and reaction cheat sheet).
struct InboxFolderContentList<EmptyExtra: View>: View {
    let content: InboxFolderListContent
    /// A row picked by click or the arrow keys; nil when Escape clears it.
    var onSelect: (String?) -> Void = { _ in }
    /// The empty root's and an empty owner folder's **New Artifact…**.
    var onNewArtifact: () -> Void = {}
    /// A row's own ⋯ press (the Idea finder's Find Ideas in Past Messages…),
    /// or a press in an artifact row's context menu.
    var onMenu: (String, InboxMenuCommand) -> Void = { _, _ in }
    /// An artifact row's context menu: its artifact ⋯ (spec "Menus").
    var contextMenu: (InboxFolderListRow) -> [InboxMenuEntry] = { _ in [] }
    /// The empty state's readiness line and actions.
    var emptyState: EmptyStateContext = .neutral
    let emptyExtra: EmptyExtra

    init(
        content: InboxFolderListContent,
        onSelect: @escaping (String?) -> Void = { _ in },
        onNewArtifact: @escaping () -> Void = {},
        onMenu: @escaping (String, InboxMenuCommand) -> Void = { _, _ in },
        contextMenu: @escaping (InboxFolderListRow) -> [InboxMenuEntry] = { _ in [] },
        emptyState: EmptyStateContext = .neutral,
        @ViewBuilder emptyExtra: () -> EmptyExtra
    ) {
        self.content = content
        self.onSelect = onSelect
        self.onNewArtifact = onNewArtifact
        self.onMenu = onMenu
        self.contextMenu = contextMenu
        self.emptyState = emptyState
        self.emptyExtra = emptyExtra()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let readError = content.readError {
                InboxReadErrorLine(message: readError)
            }
            if content.rows.isEmpty {
                ScrollView {
                    TabEmptyState(copyKey: content.emptyCopyKey, folderTitle: content.folderTitle, context: emptyState,
                                  onTabAction: onNewArtifact) {
                        emptyExtra
                    }
                    .padding(.top, Spacing.wide)
                    .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("inbox.emptyFolder")
            } else {
                // A List, as today's Inbox list (`InboxSplitView`): arrow keys
                // move the selection and VoiceOver reads the rows as a list.
                List(selection: Binding(get: { content.selection }, set: { onSelect($0) })) {
                    Text(content.folderTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                        .listRowSeparator(.hidden)
                    ForEach(content.rows) { row in
                        InboxFolderListRowView(row: row, contextEntries: contextMenu(row)) { onMenu(row.id, $0) }
                            .tag(Optional(row.id))
                            .listRowSeparator(.hidden)
                    }
                }
                .clearPlainList()
                .onExitCommand { onSelect(nil) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension InboxFolderContentList where EmptyExtra == EmptyView {
    init(
        content: InboxFolderListContent,
        onSelect: @escaping (String?) -> Void = { _ in },
        onNewArtifact: @escaping () -> Void = {},
        onMenu: @escaping (String, InboxMenuCommand) -> Void = { _, _ in },
        emptyState: EmptyStateContext = .neutral
    ) {
        self.init(content: content, onSelect: onSelect, onNewArtifact: onNewArtifact, onMenu: onMenu,
                  emptyState: emptyState) { EmptyView() }
    }
}

/// One list row: the unread dot, the title with its summary, the "updated …"
/// line under it.
struct InboxFolderListRowView: View {
    let row: InboxFolderListRow
    /// The context menu when the row has no ⋯ of its own (an artifact's ⋯).
    var contextEntries: [InboxMenuEntry] = []
    /// A press in the row's own ⋯ (`row.menu`) or its context menu.
    var onMenu: (InboxMenuCommand) -> Void = { _ in }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
            Circle()
                .fill(row.content.isUnread ? Color.accentColor : .clear)
                .frame(width: IconSize.stateDot, height: IconSize.stateDot)
                .accessibilityHidden(!row.content.isUnread)
                .accessibilityLabel("Unread")
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
                    Text(row.content.title)
                        .font(.callout.weight(row.content.isUnread ? .semibold : .regular))
                        .lineLimit(1)
                    if let pill = row.content.pill {
                        Text("· \(pill.count)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if !row.content.meta.isEmpty {
                    Text(row.content.meta)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if !row.menu.isEmpty {
                Spacer(minLength: Spacing.small)
                InboxMoreMenu(entries: row.menu, help: "More for \(row.content.title)", onCommand: onMenu)
            }
        }
        .padding(.vertical, Spacing.small)
        .accessibilityElement(children: row.menu.isEmpty ? .combine : .contain)
        .contextMenu {
            let entries = row.menu.isEmpty ? contextEntries : row.menu
            if !entries.isEmpty { InboxMenuItems(entries: entries, onCommand: onMenu) }
        }
    }
}

/// Today's strip-wide read error line (`ActionStripViewModel.lastError`),
/// kept above the previous list when a folder read fails.
struct InboxReadErrorLine: View {
    let message: String

    var body: some View {
        HStack(spacing: Spacing.regular) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Tone.warning)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.regular)
        .background(Tone.warning.opacity(ChipTint.fillOpacity))
    }
}
