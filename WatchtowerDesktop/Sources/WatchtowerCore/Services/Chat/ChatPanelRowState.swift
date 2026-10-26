import Foundation

/// A Chats panel row's state dot (spec 2026-10-26 §5.2), by precedence:
/// waiting for approval > answering > unread > read. A live turn blocked
/// on an Approve card waits for the owner, so it reads as waiting, not
/// answering (controller ruling over §5.2's table order). "Answering" is
/// the session pool's, so the caller passes it in.
package enum ChatPanelRowState: Equatable, Sendable, CaseIterable {
    case waitingForApproval, answering, unread, read

    package init(row: ChatPanelRow, isAnswering: Bool) {
        if row.pendingApprovals > 0 {
            self = .waitingForApproval
        } else if isAnswering {
            self = .answering
        } else if row.isUnread {
            self = .unread
        } else {
            self = .read
        }
    }

    /// The row's ✕ and ⌘⌫ delete at once, with Undo (spec §5.3): not while
    /// it answers or waits for approval — its context menu's Delete… then
    /// still asks first.
    package var allowsQuickDelete: Bool {
        self == .unread || self == .read
    }

    /// The dot's VoiceOver label.
    package var accessibilityLabel: String {
        switch self {
        case .waitingForApproval: "Waiting for approval"
        case .answering: "Answering"
        case .unread: "Unread"
        case .read: "Read"
        }
    }

    /// The row's second line (spec §5.1). Otherwise than answering or
    /// waiting: the last answer's first line and its age, or the chat's age
    /// before any answer; `showsProject` (All chats) prefixes a project
    /// chat's project name.
    package func secondLine(for row: ChatPanelRow, now: Date, showsProject: Bool) -> String {
        switch self {
        case .waitingForApproval:
            guard let tool = row.pendingTool else { return "Waiting for approval" }
            return "Waiting for approval: \(ReactionToolCatalog.title(for: tool))"
        case .answering:
            return "Answering…"
        case .unread, .read:
            var parts: [String] = []
            if showsProject, let name = row.projectName, !name.isEmpty { parts.append(name) }
            if !row.lastAnswerPreview.isEmpty { parts.append(row.lastAnswerPreview) }
            let at = row.lastAnswerAt ?? row.conversation.updatedDate
            parts.append(TimeFormatting.shortAge(from: at, now: now))
            return parts.joined(separator: " · ")
        }
    }
}
