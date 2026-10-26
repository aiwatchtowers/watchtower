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
    /// chat's project name. Waiting names the tool by the approval card's
    /// title, never by its raw id.
    package func secondLine(for row: ChatPanelRow, now: Date, showsProject: Bool) -> ChatPanelSecondLine {
        switch self {
        case .waitingForApproval:
            guard let title = row.pendingTool.flatMap({ ReactionToolCatalog.info(for: $0)?.title }) else {
                return ChatPanelSecondLine(text: "Waiting for approval", age: nil)
            }
            return ChatPanelSecondLine(text: "Waiting for approval: \(title)", age: nil)
        case .answering:
            return ChatPanelSecondLine(text: "Answering…", age: nil)
        case .unread, .read:
            var parts: [String] = []
            if showsProject, let name = row.projectName, !name.isEmpty { parts.append(name) }
            if !row.lastAnswerPreview.isEmpty { parts.append(row.lastAnswerPreview) }
            let at = row.lastAnswerAt ?? row.conversation.updatedDate
            return ChatPanelSecondLine(
                text: parts.joined(separator: " · "),
                age: TimeFormatting.shortAge(from: at, now: now)
            )
        }
    }
}

/// A row's second line in two parts: the text, cut at its tail when the
/// row is narrow, and the age after it, never cut (spec §5.1).
package struct ChatPanelSecondLine: Equatable, Sendable {
    /// The state, or the project and the last answer's first line ('' when
    /// there is only the age).
    package let text: String
    /// "2h", "4d"; nil while the line names a state.
    package let age: String?

    package init(text: String, age: String?) {
        self.text = text
        self.age = age
    }

    /// The age as shown after the text ("· 2h"), or alone.
    package var ageLabel: String? {
        guard let age else { return nil }
        return text.isEmpty ? age : "· \(age)"
    }

    /// The whole line as one string ("Done. · 2h").
    package var joined: String {
        [text, age ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
