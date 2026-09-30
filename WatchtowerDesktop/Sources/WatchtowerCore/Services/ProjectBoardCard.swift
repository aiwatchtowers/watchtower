import Foundation

/// Sibling order of the project board. Pure.
///
/// Dual path with Go's `boardSiblingOrder` (`internal/db/project_board.go`),
/// which orders the board the agent sees through `watchtower mcp --project N`
/// and `project board`: priority high, medium, then anything else; then status
/// in_progress, blocked, todo, done, then anything else; then id. `in_review`
/// already ranks right after in_progress here; Go gains that arm together with
/// the status itself (until then the targets CHECK keeps it out of the table,
/// so both orders agree). Change both sides together.
package enum ProjectBoardOrder {
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
package struct ProjectBoardCard: Equatable {
    /// Statuses the owner can set from the board. `snoozed` is a Targets-tab
    /// concept (snooze_until) with no meaning on a project board.
    package static let editableStatuses = ["todo", "in_progress", "blocked", "done", "dismissed"]
    package static let editablePriorities = ["high", "medium", "low"]

    /// Done children of a parent card over the children that still count (a
    /// dismissed child is out of scope, not unfinished work). `total` is never 0.
    package struct ChildProgress: Equatable {
        package let done: Int
        package let total: Int
        package var fraction: Double { Double(done) / Double(total) }
    }

    package let title: String
    package let isClosed: Bool
    package let isDone: Bool
    /// Set for a card with children that still count; nil for a leaf and for a
    /// parent whose children are all dismissed (no meaningless 0/0).
    package let children: ChildProgress?
    /// A leaf's own partial progress (strictly between 0 and 1), else nil.
    package let leafProgress: Double?

    package init(_ node: ProjectBoardNode) {
        let target = node.target
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
