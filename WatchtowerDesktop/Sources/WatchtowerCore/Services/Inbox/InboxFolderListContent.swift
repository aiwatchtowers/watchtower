import Foundation

/// One row of a folder's list (spec "The Inbox screen" 2): an automation
/// artifact, a legacy entry over today's panes (Morning brief, Track my
/// threads, Idea finder, Messages), a native approval card in Needs
/// approval, or a result shown for a while (a thread brief, ask #609).
package struct InboxFolderListRow: Identifiable, Equatable, Sendable {
    package enum Kind: Equatable, Sendable { case artifact, legacy, approval, result }

    package let id: String
    package let kind: Kind
    package let title: String
    /// "4 waiting", "today", "2 unread"; empty draws none.
    package var summary: String
    /// "updated 6 min ago · after every sync", "run #12 · 2 h ago".
    package var detail: String
    package var unread: Bool
    /// The row's own ⋯ (and context menu); empty draws none.
    package var menu: [InboxMenuEntry]

    package init(
        id: String,
        kind: Kind,
        title: String,
        summary: String = "",
        detail: String = "",
        unread: Bool = false,
        menu: [InboxMenuEntry] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.summary = summary
        self.detail = detail
        self.unread = unread
        self.menu = menu
    }
}

/// The folder's list as plain values (plan Task 1); Task 12 reads it from
/// `inbox_artifact_folders` and the legacy feeds.
package struct InboxFolderListContent: Equatable, Sendable {
    package let folderKind: InboxFolderKind
    package let folderTitle: String
    package var rows: [InboxFolderListRow]
    package var selection: String?
    /// A failed folder read: the previous list stays under today's strip
    /// error line.
    package var readError: String?

    package init(
        folderKind: InboxFolderKind,
        folderTitle: String,
        rows: [InboxFolderListRow] = [],
        selection: String? = nil,
        readError: String? = nil
    ) {
        self.folderKind = folderKind
        self.folderTitle = folderTitle
        self.rows = rows
        self.selection = selection
        self.readError = readError
    }

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
