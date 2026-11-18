import Foundation

/// Sibling order of the project board. Pure.
///
/// Dual path with Go's `boardSiblingOrder` (`internal/db/workbench_board.go`),
/// which orders the board the agent sees through `watchtower mcp --workbench N`
/// and `workbench board`: priority high, medium, then anything else; then status
/// in_progress, in_review, blocked, todo, done, then anything else; then id.
/// A third twin is the phone's `BoardModel.boardOrder`
/// (`WatchtowerMobile/Sources/Features/Workbench/BoardModel.swift`), which
/// orders the mirrored board. Change all three together.
package enum WorkbenchBoardOrder {
    package static func priorityRank(_ priority: String) -> Int {
        switch priority {
        case "high": 0
        case "medium": 1
        default: 2
        }
    }

    package static func statusRank(_ status: String) -> Int {
        switch status {
        case "in_progress": 0
        case "in_review": 1
        case "blocked": 2
        case "todo": 3
        case "done": 4
        default: 5
        }
    }

    package static func sorted(_ targets: [Target]) -> [Target] {
        targets.sorted { lhs, rhs in
            let l = (priorityRank(lhs.priority), statusRank(lhs.status), lhs.id)
            let r = (priorityRank(rhs.priority), statusRank(rhs.status), rhs.id)
            return l < r
        }
    }
}

/// What one board card shows, derived from its node. Pure; the view only maps
/// these values to colours and layout.
package struct WorkbenchBoardCard: Equatable {
    /// Statuses the owner can set from the board. `snoozed` is a Targets-tab
    /// concept (snooze_until) with no meaning on a project board.
    package static let editableStatuses = ["todo", "in_progress", "in_review", "blocked", "done", "dismissed"]
    package static let editablePriorities = ["high", "medium", "low"]

    /// Done children of a parent card over the children that still count (a
    /// dismissed child is out of scope, not unfinished work). `total` is never 0.
    package struct ChildProgress: Equatable {
        package let done: Int
        package let total: Int
        package var fraction: Double { Double(done) / Double(total) }
    }

    /// The folder a card names (spec 2026-11-18 §6.10), after the status chip.
    package enum FolderChip: Equatable {
        /// The target's folder, on a bench of more than one live folder.
        case folder(String)
        /// The target's folder left the bench: `· folder removed`, in the
        /// warning Tone, instead of the chip.
        case removed

        package var text: String {
            switch self {
            case let .folder(name): name
            case .removed: WorkbenchBoardCard.folderRemovedText
            }
        }
    }

    package static let folderRemovedText = "· folder removed"

    package let title: String
    package let isClosed: Bool
    package let isDone: Bool
    /// Set for a card with children that still count; nil for a leaf and for a
    /// parent whose children are all dismissed (no meaningless 0/0).
    package let children: ChildProgress?
    /// A leaf's own partial progress (strictly between 0 and 1), else nil.
    package let leafProgress: Double?
    /// nil on a one-folder bench (the card looks as before), for a target
    /// with no folder row to name, and while the bench's folders are unread.
    package let folderChip: FolderChip?

    /// `folders`: the bench's folders as one read gives them. A target
    /// stores no folder (nil) for the home folder.
    package init(_ node: WorkbenchBoardNode, folders: BenchFolders? = nil) {
        let target = node.target
        folderChip = Self.folderChip(folderID: target.workbenchFolderID, folders: folders)
        title = Self.title(target.text)
        isDone = target.status == "done"
        isClosed = isDone || target.status == "dismissed"
        if node.children.isEmpty {
            children = nil
            leafProgress = target.progress > 0 && target.progress < 1 ? target.progress : nil
        } else {
            let counted = node.children.filter { $0.target.status != "dismissed" }
            children = counted.isEmpty ? nil : ChildProgress(
                done: counted.filter { $0.target.status == "done" }.count,
                total: counted.count
            )
            leafProgress = nil
        }
    }

    /// A removed folder always says so (the work in it cannot be checked
    /// any more); a live one is named only on a bench of several.
    package static func folderChip(folderID: Int64?, folders: BenchFolders?) -> FolderChip? {
        guard let folders, let folder = folders.folder(folderID) else { return nil }
        if folder.isRemoved { return .removed }
        return folders.live.count > 1 ? .folder(folder.name) : nil
    }

    /// The panel's Folder menu title: the folder's name, `Folder removed` for
    /// one that left the bench, `Folder` for one this bench does not know.
    package static func folderMenuTitle(_ folder: WorkbenchFolder?) -> String {
        guard let folder else { return "Folder" }
        return folder.isRemoved ? "Folder removed" : folder.name
    }

    /// The first non-blank line of a target's text.
    package static func title(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// The chip text for a status. An unknown status (a newer CLI wrote a
    /// value this build does not know) shows as its raw text.
    package static func statusLabel(_ status: String) -> String {
        switch status {
        case "todo": "To Do"
        case "in_progress": "In Progress"
        case "in_review": "In Review"
        case "blocked": "Blocked"
        case "done": "Done"
        case "dismissed": "Dismissed"
        default: status
        }
    }
}
