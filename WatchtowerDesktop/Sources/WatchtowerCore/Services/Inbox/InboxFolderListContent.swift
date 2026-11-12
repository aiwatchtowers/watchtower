import Foundation

/// One row of a folder's list (spec "The list"): an automation artifact,
/// a legacy entry over today's panes (Morning brief, Track my threads,
/// Idea finder, Messages), a native approval card in Needs approval, or a
/// result shown for a while (a thread brief, ask #609), drawn from its
/// `content`.
package struct InboxFolderListRow: Identifiable, Equatable, Sendable {
    package let id: String
    package var content: InboxRowContent
    /// The row's own ⋯ (and context menu); empty draws none.
    package var menu: [InboxMenuEntry]
    /// An artifact's row: its context menu is its automation's ⋯.
    package let isArtifact: Bool

    package init(id: String, content: InboxRowContent, menu: [InboxMenuEntry] = [], isArtifact: Bool = false) {
        self.id = id
        self.content = content
        self.menu = menu
        self.isArtifact = isArtifact
    }
}

/// One titled section of a folder's list ("Needs you", "Today", …).
package struct InboxListSection: Identifiable, Equatable, Sendable {
    package let id: String
    package let title: String
    package let rows: [InboxFolderListRow]
    /// The count the heading shows after its title ("Targets · 4"); nil
    /// shows none. A Needs approval group's approvals, which its one
    /// Approve All row may stand for.
    package let count: Int?

    package init(id: String, title: String, rows: [InboxFolderListRow], count: Int? = nil) {
        self.id = id
        self.title = title
        self.rows = rows
        self.count = count
    }
}

/// The folder's list as plain values (plan Task 1); Task 12 reads it from
/// `inbox_artifact_folders` and the legacy feeds.
package struct InboxFolderListContent: Equatable, Sendable {
    package let folderKind: InboxFolderKind
    package let folderTitle: String
    package var sections: [InboxListSection]
    /// The root's line for past briefs; nil elsewhere and with none.
    package var earlierLine: InboxEarlierLine?
    package var selection: String?
    /// A failed folder read: the previous list stays under today's strip
    /// error line.
    package var readError: String?
    /// The list's search (`InboxListFilter`) the sections are filtered by;
    /// empty = none.
    package var query: String

    package init(
        folderKind: InboxFolderKind,
        folderTitle: String,
        sections: [InboxListSection] = [],
        earlierLine: InboxEarlierLine? = nil,
        selection: String? = nil,
        readError: String? = nil,
        query: String = ""
    ) {
        self.folderKind = folderKind
        self.folderTitle = folderTitle
        self.sections = sections
        self.earlierLine = earlierLine
        self.selection = selection
        self.readError = readError
        self.query = query
    }

    /// A search is on and nothing matches it: "No matches for …" in place
    /// of the folder's empty state.
    package var hasNoMatches: Bool {
        rows.isEmpty && !InboxListFilter.trimmed(query).isEmpty
    }

    /// Every row, sections in order.
    package var rows: [InboxFolderListRow] { sections.flatMap(\.rows) }

    /// The `EmptyStateCopyTable` key of the empty folder (spec "The Inbox
    /// screen" → States): `inbox`, `inboxFolder` or `inboxApprovals`.
    package var emptyCopyKey: String {
        switch folderKind {
        case .root: "inbox"
        case .owner: "inboxFolder"
        case .approvals: "inboxApprovals"
        }
    }

    /// The empty folder's words, an owner folder's title filled in.
    package var emptyCopy: EmptyStateCopy {
        EmptyStateCopyTable.copy(for: emptyCopyKey, briefingHour: 8, folderTitle: folderTitle)
            ?? EmptyStateCopy(icon: "tray", title: "Nothing here", landsHere: "", feature: nil, primaryAction: nil)
    }
}
