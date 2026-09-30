import Foundation
import GRDB

/// The three panes of a project page (spec §6.1). Lives in Core because the
/// notification policy deep-links into one.
package enum ProjectPane: String, CaseIterable, Codable, Sendable {
    case terminal
    case board
    case documents

    package var title: String {
        switch self {
        case .terminal: "Terminal"
        case .board: "Board"
        case .documents: "Documents"
        }
    }
}

/// What an owner write touched, so the notification policy can tell the
/// owner's own changes from an agent's (Task 18: owner writes never notify).
package enum ProjectSubject: Hashable, Codable, Sendable {
    case document(Int64)
    case target(Int64)
}

/// Where a notification click or an in-app link lands: a project, a pane and
/// optionally the document (documents pane) or target (board pane) to open.
package struct ProjectRoute: Equatable, Sendable {
    package let projectID: Int64
    package let pane: ProjectPane
    package let subjectID: Int64?

    package init(projectID: Int64, pane: ProjectPane, subjectID: Int64? = nil) {
        self.projectID = projectID
        self.pane = pane
        self.subjectID = subjectID
    }
}

/// A `projects` row. Written only by the Go CLI (`watchtower project create`);
/// the Desktop reads it.
package struct Project: FetchableRecord, Identifiable, Equatable, Hashable, Sendable {
    package let id: Int64
    package let name: String
    package let folderPath: String
    package let description: String
    package let createdAt: String
    package let updatedAt: String

    package init(row: Row) {
        id = row["id"]
        name = row["name"] ?? ""
        folderPath = row["folder_path"] ?? ""
        description = row["description"] ?? ""
        createdAt = row["created_at"] ?? ""
        updatedAt = row["updated_at"] ?? ""
    }

    package var folderURL: URL { URL(fileURLWithPath: folderPath, isDirectory: true) }
}

/// A `project_documents` row: a spec/plan/doc file inside the project folder
/// that an agent attached. The Desktop reads the file, never writes it (PROJ-03).
package struct ProjectDocument: FetchableRecord, Identifiable, Equatable, Hashable, Sendable {
    package let id: Int64
    package let projectID: Int64
    package let targetID: Int64?
    package let relPath: String
    package let kind: String        // spec | plan | doc
    package let title: String
    package let createdAt: String
    package let updatedAt: String   // bumped by every re-attach ("revised")

    package init(row: Row) {
        id = row["id"]
        projectID = row["project_id"]
        targetID = row["target_id"]
        relPath = row["rel_path"] ?? ""
        kind = row["kind"] ?? "doc"
        title = row["title"] ?? ""
        createdAt = row["created_at"] ?? ""
        updatedAt = row["updated_at"] ?? ""
    }

    package var displayTitle: String {
        title.isEmpty ? (relPath as NSString).lastPathComponent : title
    }

    package func fileURL(in project: Project) -> URL {
        project.folderURL.appendingPathComponent(relPath)
    }
}

/// A `project_comments` row — a thread root (on a target or a document) or a
/// reply. Status is meaningful on roots only.
package struct ProjectComment: FetchableRecord, Identifiable, Equatable, Hashable, Sendable {
    package let id: Int64
    package let projectID: Int64
    package let targetID: Int64?
    package let documentID: Int64?
    package let parentID: Int64?
    package let author: String      // owner | agent
    package let agentLabel: String
    package let body: String
    package let anchorQuote: String
    package let anchorPrefix: String
    package let anchorSuffix: String
    package let anchorHeading: String
    package let status: String      // open | resolved | outdated
    package let createdAt: String
    package let readAt: String

    package init(row: Row) {
        id = row["id"]
        projectID = row["project_id"]
        targetID = row["target_id"]
        documentID = row["document_id"]
        parentID = row["parent_id"]
        author = row["author"] ?? "owner"
        agentLabel = row["agent_label"] ?? ""
        body = row["body"] ?? ""
        anchorQuote = row["anchor_quote"] ?? ""
        anchorPrefix = row["anchor_prefix"] ?? ""
        anchorSuffix = row["anchor_suffix"] ?? ""
        anchorHeading = row["anchor_heading"] ?? ""
        status = row["status"] ?? "open"
        createdAt = row["created_at"] ?? ""
        readAt = row["read_at"] ?? ""
    }

    package var isRoot: Bool { parentID == nil }
    package var isAgent: Bool { author == "agent" }
    package var isOpen: Bool { status == "open" }
    package var isUnreadForOwner: Bool { isAgent && readAt.isEmpty }

    /// The stored anchor, or nil for an unanchored comment (target threads).
    package var anchor: CommentAnchor? {
        guard !anchorQuote.isEmpty else { return nil }
        return CommentAnchor(quote: anchorQuote, prefix: anchorPrefix, suffix: anchorSuffix, heading: anchorHeading)
    }
}

/// A root comment with its replies, in creation order.
package struct ProjectCommentThread: Identifiable, Equatable, Sendable {
    package let root: ProjectComment
    package let replies: [ProjectComment]

    package var id: Int64 { root.id }

    /// Groups a flat, creation-ordered comment list (as `ProjectQueries.comments`
    /// returns it) into threads. A reply whose root is not in the list is dropped.
    package static func group(_ comments: [ProjectComment]) -> [Self] {
        let replies = Dictionary(grouping: comments.filter { !$0.isRoot }) { $0.parentID ?? 0 }
        return comments.filter(\.isRoot).map { root in
            Self(root: root, replies: replies[root.id] ?? [])
        }
    }
}

extension ProjectCommentThread {
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
            quote: root.anchorQuote,
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
package struct ProjectBoardNode: Identifiable, Equatable {
    package let target: Target
    package let children: [Self]
    /// Open owner threads (roots) on this target — the same count the
    /// Documents list shows, and what the agent sees as waiting on it.
    package let openComments: Int
    /// Agent comments on this target the owner has not seen.
    package let unreadForOwner: Int
    package let documents: [ProjectDocument]

    package var id: Int { target.id }
}

/// A row of the Documents pane's list.
package struct ProjectDocumentListItem: Identifiable, Equatable, Sendable {
    package let document: ProjectDocument
    package let targetTitle: String?
    /// Open owner threads (roots) on the document.
    package let openComments: Int

    package var id: Int64 { document.id }
}

/// A project list row.
package struct ProjectSummary: Identifiable, Equatable, Sendable {
    package let project: Project
    package let openTargets: Int
    package let inProgressTargets: Int
    package let unreadAgentComments: Int
    /// Document id → `updated_at`, for "revised since last viewed".
    package let documentStamps: [Int64: String]

    package var id: Int64 { project.id }
}
