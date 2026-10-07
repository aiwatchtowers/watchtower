import Foundation
import GRDB

/// The panes a notification deep-links into (spec §6.1). Lives in Core
/// because the notification policy names one. A push naming a pane that is
/// gone (`documents`, spec 2026-10-03 Part 8) opens the board.
package enum WorkbenchPane: String, CaseIterable, Codable, Sendable {
    case terminal
    case board

    package var title: String {
        switch self {
        case .terminal: "Terminal"
        case .board: "Board"
        }
    }
}

/// What an owner write touched, so the notification policy can tell the
/// owner's own changes from an agent's (Task 18: owner writes never notify).
package enum WorkbenchSubject: Hashable, Codable, Sendable {
    case target(Int64)
}

/// Where a notification click or an in-app link lands: a project, a pane and
/// optionally the target (board pane) or session (terminal pane) to open.
/// `askID` names the owner ask a click opens (spec 2026-10-03 Part 8).
package struct WorkbenchRoute: Equatable, Sendable {
    package let projectID: Int64
    package let pane: WorkbenchPane
    package let subjectID: Int64?
    package let askID: Int64?

    package init(projectID: Int64, pane: WorkbenchPane, subjectID: Int64? = nil, askID: Int64? = nil) {
        self.projectID = projectID
        self.pane = pane
        self.subjectID = subjectID
        self.askID = askID
    }
}

/// A `projects` row. Written only by the Go CLI (`watchtower workbench create`);
/// the Desktop reads it.
package struct Workbench: FetchableRecord, Identifiable, Equatable, Hashable, Sendable {
    package let id: Int64
    package let name: String
    package let folderPath: String
    package let description: String
    package let createdAt: String
    package let updatedAt: String
    /// Days a closed target waits before the board archives it; 0 = never
    /// (board #301, migration 00103). The owner's setting, written only by
    /// `WorkbenchQueries.setArchiveAfterDays`.
    package let archiveAfterDays: Int
    /// The moment of the last "Archive Closed Targets Now" (board #415,
    /// migration 00105), a UTC `YYYY-MM-DDTHH:MM:SSZ`; nil = never pressed or
    /// undone. Written only by `WorkbenchQueries.archiveClosedTargetsNow` and
    /// cleared by `WorkbenchQueries.clearArchivedThrough`.
    package let archivedThrough: String?

    package init(row: Row) {
        id = row["id"]
        name = row["name"] ?? ""
        folderPath = row["folder_path"] ?? ""
        description = row["description"] ?? ""
        createdAt = row["created_at"] ?? ""
        updatedAt = row["updated_at"] ?? ""
        archiveAfterDays = row["archive_after_days"] ?? Self.defaultArchiveAfterDays
        archivedThrough = row["archived_through"]
    }

    package var folderURL: URL { URL(fileURLWithPath: folderPath, isDirectory: true) }

    /// The column's default.
    package static let defaultArchiveAfterDays = 14
    /// The header menu's "Archive Closed Targets After" choices (owner
    /// decision B); 0 = Never.
    package static let archiveAfterDaysChoices = [0, 3, 7, 14, 30, 90]

    package static func archiveAfterDaysLabel(_ days: Int) -> String {
        days == 0 ? "Never" : "\(days) days"
    }
}

/// A `project_target_images` row (migration 00088): an image the agent
/// attached to a board target. `path` is Watchtower's own 0600 copy under
/// `<workspace>/project_files/<project_id>/`, written only by the Go project
/// tools; the Desktop only reads it.
package struct WorkbenchTargetImage: FetchableRecord, Identifiable, Equatable, Hashable, Sendable {
    package let id: Int64
    package let targetID: Int64
    package let fileName: String
    package let mime: String
    package let size: Int64
    package let path: String
    package let createdAt: String

    package init(row: Row) {
        id = row["id"]
        targetID = row["target_id"]
        fileName = row["file_name"] ?? ""
        mime = row["mime"] ?? ""
        size = row["size"] ?? 0
        path = row["path"] ?? ""
        createdAt = row["created_at"] ?? ""
    }

    package var fileURL: URL { URL(fileURLWithPath: path) }
}

/// A `project_comments` row — a thread root on a target or a reply. Status
/// is meaningful on roots only.
package struct WorkbenchComment: FetchableRecord, Identifiable, Equatable, Hashable, Sendable {
    package let id: Int64
    package let projectID: Int64
    package let targetID: Int64?
    package let parentID: Int64?
    package let author: String      // owner | agent
    package let agentLabel: String
    package let body: String
    package let status: String      // open | resolved | outdated
    package let createdAt: String
    package let readAt: String

    package init(row: Row) {
        id = row["id"]
        projectID = row["project_id"]
        targetID = row["target_id"]
        parentID = row["parent_id"]
        author = row["author"] ?? "owner"
        agentLabel = row["agent_label"] ?? ""
        body = row["body"] ?? ""
        status = row["status"] ?? "open"
        createdAt = row["created_at"] ?? ""
        readAt = row["read_at"] ?? ""
    }

    package var isRoot: Bool { parentID == nil }
    package var isAgent: Bool { author == "agent" }
    package var isOpen: Bool { status == "open" }
    package var isUnreadForOwner: Bool { isAgent && readAt.isEmpty }
}

/// A root comment with its replies, in creation order.
package struct WorkbenchCommentThread: Identifiable, Equatable, Sendable {
    package let root: WorkbenchComment
    package let replies: [WorkbenchComment]

    package var id: Int64 { root.id }

    /// An owner reply newer than the thread's latest agent comment (the agent
    /// root counts) — the reply half of Go's `newForAgentPredicate`
    /// (`internal/db/workbench_comments.go`). Ids, not timestamps, order them.
    package var hasUnansweredOwnerReply: Bool {
        let lastAgent = ([root] + replies).filter(\.isAgent).map(\.id).max() ?? 0
        return replies.contains { !$0.isAgent && $0.id > lastAgent }
    }

    /// Groups a flat, creation-ordered comment list (as `WorkbenchQueries.comments`
    /// returns it) into threads. A reply whose root is not in the list is dropped.
    package static func group(_ comments: [WorkbenchComment]) -> [Self] {
        let replies = Dictionary(grouping: comments.filter { !$0.isRoot }) { $0.parentID ?? 0 }
        return comments.filter(\.isRoot).map { root in
            Self(root: root, replies: replies[root.id] ?? [])
        }
    }
}

extension WorkbenchCommentThread {
    /// The thread as `CommentThreadView` shows it — the same labels the
    /// Phase 4 view derived itself ("You"/the agent's label/"Agent";
    /// "Resolved"/"Outdated — the quoted text changed").
    package var content: CommentThreadContent {
        let note: String? = switch root.status {
        case "open": nil
        case "resolved": "Resolved"
        default: "Outdated — the quoted text changed"
        }
        return CommentThreadContent(
            id: id,
            quote: "",
            statusNote: note,
            entries: ([root] + replies).map { comment in
                let author = comment.isAgent ? (comment.agentLabel.isEmpty ? "Agent" : comment.agentLabel) : "You"
                return CommentThreadContent.Entry(id: comment.id, author: author, body: comment.body)
            }
        )
    }
}

/// One node of a project board: a project target with its sub-targets and
/// the counters the board badges show.
package struct WorkbenchBoardNode: Identifiable, Equatable {
    package let target: Target
    package let children: [Self]
    /// Open owner threads (roots) on this target — what the agent sees as
    /// waiting on it.
    package let openComments: Int
    /// Agent comments on this target the owner has not seen.
    package let unreadForOwner: Int
    /// In the board archive (board #301): the `workbench_target_archive`
    /// view's verdict. An archived node's whole subtree is archived too.
    package var archived = false

    package var id: Int { target.id }
}

/// A project list row.
package struct WorkbenchSummary: Identifiable, Equatable, Sendable {
    package let project: Workbench
    package let openTargets: Int
    package let inProgressTargets: Int
    package let unreadAgentComments: Int
    /// `owner_asks` rows still `open` (spec 2026-10-03 Part 8).
    package let openAsks: Int

    package init(project: Workbench, openTargets: Int, inProgressTargets: Int, unreadAgentComments: Int, openAsks: Int = 0) {
        self.project = project
        self.openTargets = openTargets
        self.inProgressTargets = inProgressTargets
        self.unreadAgentComments = unreadAgentComments
        self.openAsks = openAsks
    }

    package var id: Int64 { project.id }
}

/// A row of the workbench switcher (board #250): the list row's summary plus
/// what the switcher shows beside it. Live sessions are not here — they come
/// from `TerminalCenter`, not the DB.
package struct WorkbenchSwitcherSummary: Identifiable, Equatable, Sendable {
    package let summary: WorkbenchSummary
    /// `blocked` targets on the workbench's own board.
    package let blockedTargets: Int
    package let sessionCount: Int
    /// `MAX(last_active_at)` of its sessions; empty when it has none.
    package let lastSessionActivity: String

    package var id: Int64 { summary.id }
    package var project: Workbench { summary.project }
}
