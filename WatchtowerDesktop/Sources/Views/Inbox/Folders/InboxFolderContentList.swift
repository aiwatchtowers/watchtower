import SwiftUI
import WatchtowerCore

/// The Inbox's second column (spec "The list"): the selected folder's
/// sections by urgency, each under a small caps heading (a Needs approval
/// group with its count), the root's Earlier line as a last quiet row; or,
/// with no rows, the folder's empty state (`EmptyStateCopyTable`'s `inbox`,
/// `inboxFolder`, `inboxApprovals`) with what the caller keeps under it
/// (`emptyExtra`: the empty root's OWNER-02 line and reaction cheat sheet),
/// or "No matches for …" while a search finds nothing.
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
    /// The Earlier line's press: the Morning brief with its History open.
    var onEarlier: () -> Void = {}
    /// The empty state's readiness line and actions.
    var emptyState: EmptyStateContext = .neutral
    let emptyExtra: EmptyExtra

    init(
        content: InboxFolderListContent,
        onSelect: @escaping (String?) -> Void = { _ in },
        onNewArtifact: @escaping () -> Void = {},
        onMenu: @escaping (String, InboxMenuCommand) -> Void = { _, _ in },
        contextMenu: @escaping (InboxFolderListRow) -> [InboxMenuEntry] = { _ in [] },
        onEarlier: @escaping () -> Void = {},
        emptyState: EmptyStateContext = .neutral,
        @ViewBuilder emptyExtra: () -> EmptyExtra
    ) {
        self.content = content
        self.onSelect = onSelect
        self.onNewArtifact = onNewArtifact
        self.onMenu = onMenu
        self.contextMenu = contextMenu
        self.onEarlier = onEarlier
        self.emptyState = emptyState
        self.emptyExtra = emptyExtra()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let readError = content.readError {
                InboxReadErrorLine(message: readError)
            }
            if content.hasNoMatches {
                InboxNoMatchesLine(query: content.query)
            } else if content.rows.isEmpty {
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
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A List, as today's Inbox list (`InboxSplitView`): arrow keys move the
    /// selection and VoiceOver reads the rows as a list. Each heading is a
    /// plain row of its Section that cannot be selected, not a Section
    /// header: a plain List pins its header and draws a hairline under it.
    private var list: some View {
        List(selection: Binding(get: { content.selection }, set: { onSelect($0) })) {
            ForEach(content.sections) { section in
                Section {
                    InboxListSectionHeading(title: section.title, count: section.count)
                        .inboxListLine()
                    ForEach(section.rows) { row in
                        InboxListRow(content: row.content, isSelected: row.id == content.selection, menu: row.menu,
                                     contextEntries: contextMenu(row)) { onMenu(row.id, $0) }
                            .tag(Optional(row.id))
                            .inboxListLine(selectable: true)
                    }
                }
            }
            if let earlier = content.earlierLine {
                InboxEarlierLineRow(line: earlier, onPress: onEarlier)
                    .inboxListLine()
            }
        }
        .clearPlainList()
        .onExitCommand { onSelect(nil) }
    }
}

extension InboxFolderContentList where EmptyExtra == EmptyView {
    init(
        content: InboxFolderListContent,
        onSelect: @escaping (String?) -> Void = { _ in },
        onNewArtifact: @escaping () -> Void = {},
        onMenu: @escaping (String, InboxMenuCommand) -> Void = { _, _ in },
        onEarlier: @escaping () -> Void = {},
        emptyState: EmptyStateContext = .neutral
    ) {
        self.init(content: content, onSelect: onSelect, onNewArtifact: onNewArtifact, onMenu: onMenu,
                  onEarlier: onEarlier, emptyState: emptyState) { EmptyView() }
    }
}

/// A section's heading in the list: its title in small caps, a Needs
/// approval group's count on the right (mockup `.lsec`).
struct InboxListSectionHeading: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
            Text(title)
                .textCase(.uppercase)
                .tracking(Tracking.caps)
            Spacer(minLength: Spacing.small)
            if let count {
                Text("\(count)").monospacedDigit()
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.tertiary)
        .padding(.top, Spacing.medium)
        .padding(.horizontal, Spacing.regular)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The root's last row: where the past briefs went, a press opens the
/// Morning brief with its History.
struct InboxEarlierLineRow: View {
    let line: InboxEarlierLine
    let onPress: () -> Void

    var body: some View {
        Button(action: onPress) {
            Label(line.text, systemImage: "chevron.right")
                .font(.caption)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Quiet text, not the accent: a way into the brief, not an action.
        .buttonStyle(KitQuietButtonStyle(label: .secondary))
        .padding(.top, Spacing.medium)
        .help("Open the Morning brief's History")
        .accessibilityIdentifier("inbox.earlierLine")
    }
}

/// A search that finds nothing in the folder.
struct InboxNoMatchesLine: View {
    let query: String

    var body: some View {
        Text("No matches for “\(InboxListFilter.trimmed(query))”")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, Spacing.wide)
            .padding(.horizontal, Spacing.large)
            .accessibilityIdentifier("inbox.noMatches")
    }
}

private extension View {
    /// A line of the list: no separator, no stock background, `Spacing.tight`
    /// below a row; a heading or the Earlier line is never selected.
    @ViewBuilder
    func inboxListLine(selectable: Bool = false) -> some View {
        let line = listRowInsets(EdgeInsets(top: 0, leading: Spacing.small, bottom: Spacing.tight,
                                            trailing: Spacing.small))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        if selectable { line } else { line.selectionDisabled() }
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
