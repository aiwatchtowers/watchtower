import Foundation

/// One row of a folder's list (spec "The Inbox screen" 2): an automation
/// artifact, a legacy entry over today's panes (Morning brief, Track my
/// threads, Idea finder, Messages), or a native approval card in Needs
/// approval.
package struct InboxFolderListRow: Identifiable, Equatable, Sendable {
    package enum Kind: Equatable, Sendable { case artifact, legacy, approval }

    package let id: String
    package let kind: Kind
    package let title: String
    /// "4 waiting", "today", "2 unread"; empty draws none.
    package var summary: String
    /// "updated 6 min ago · after every sync", "run #12 · 2 h ago".
    package var detail: String
    package var unread: Bool

    package init(id: String, kind: Kind, title: String, summary: String = "", detail: String = "",
                 unread: Bool = false) {
        self.id = id
        self.kind = kind
        self.title = title
        self.summary = summary
        self.detail = detail
        self.unread = unread
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

    package init(folderKind: InboxFolderKind, folderTitle: String, rows: [InboxFolderListRow] = [],
                 selection: String? = nil, readError: String? = nil) {
        self.folderKind = folderKind
        self.folderTitle = folderTitle
        self.rows = rows
        self.selection = selection
        self.readError = readError
    }

    /// The empty folder's words (spec "The Inbox screen" → States). Task 12
    /// moves them into `EmptyStateCopyTable` under `inbox`, `inboxFolder`
    /// and `inboxApprovals`.
    package var emptyCopy: EmptyStateCopy {
        switch folderKind {
        case .root:
            EmptyStateCopy(icon: "tray", title: "Your Inbox is empty",
                           landsHere: "Automations put what they make here.",
                           feature: nil, primaryAction: .tabAction(label: "New Artifact…"))
        case .owner:
            EmptyStateCopy(icon: "folder", title: "Nothing in \(folderTitle) yet",
                           landsHere: "Move an automation here from its ⋯ menu, or make a new one.",
                           feature: nil, primaryAction: .tabAction(label: "New Artifact…"))
        case .approvals:
            EmptyStateCopy(icon: "checkmark.circle", title: "Nothing waits for your approval", landsHere: "",
                           feature: nil, primaryAction: nil)
        }
    }
}
