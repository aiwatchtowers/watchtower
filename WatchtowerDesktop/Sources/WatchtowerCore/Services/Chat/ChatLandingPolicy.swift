import ChatWire
import Foundation

/// Entering the Chat tab: reopen the last conversation or show the landing
/// (owner decision 2026-09-28). Pure — the clock and every input are
/// injected; `ChatViewModel.enterTab` gathers the snapshot (from the
/// engine's list) and applies the decision.
///
/// Resume when the last-open conversation still exists and is not
/// archived, and either has a turn running or unsent composer input (both
/// resume whatever the time), or holds at least one message and saw
/// activity less than `resumeWindow` ago. Activity is the later of its last
/// stored message (`updated_at`) and the last time the owner had it on
/// screen (stamped on leaving the tab, on switching chats, on the app going
/// to the background or quitting, and every minute while the tab is shown).
/// Exactly `resumeWindow` after the last activity is already outside.
package enum ChatLandingPolicy {
    package static let resumeWindow: TimeInterval = 2 * 60 * 60
    /// The landing's recent list: every pinned chat up to `pinnedLimit`,
    /// then the most recent unpinned ones up to `recentLimit`.
    package static let pinnedLimit = 5
    package static let recentLimit = 6

    /// The project ⌘N / New Chat / `+` lands in: the panel's project while
    /// the panel is visible and shows one, else none — a hidden panel's
    /// remembered level never files a new chat into a project (controller
    /// ruling on spec 2026-10-26 §4).
    package static func newChatProject(level: ChatPanelLevel, panelVisible: Bool) -> Int64? {
        panelVisible ? level.projectID : nil
    }

    package enum Decision: Equatable, Sendable {
        case resume(Int64)
        case landing
    }

    /// The last-open conversation as read right now.
    package struct LastConversation: Equatable, Sendable {
        package let id: Int64
        package let updatedAt: Date
        package let isArchived: Bool
        package let hasMessages: Bool
        package let isStreaming: Bool

        package init(id: Int64, updatedAt: Date, isArchived: Bool, hasMessages: Bool, isStreaming: Bool) {
            self.id = id
            self.updatedAt = updatedAt
            self.isArchived = isArchived
            self.hasMessages = hasMessages
            self.isStreaming = isStreaming
        }

        /// A listed conversation: one with a message has its title (the engine
        /// sets the first message's prefix title at once).
        package init(_ conv: ChatList.Conversation, isStreaming: Bool) {
            self.init(id: conv.id, updatedAt: conv.updatedAt, isArchived: false, hasMessages: !conv.title.isEmpty,
                      isStreaming: isStreaming)
        }
    }

    /// `last` is nil when there is no last-open conversation or it was
    /// deleted; `lastViewedAt` is when the owner last had it on screen;
    /// `hasUnsentInput` is a non-empty draft or pending attachments.
    package static func decide(
        last: LastConversation?, lastViewedAt: Date?, hasUnsentInput: Bool = false, now: Date
    ) -> Decision {
        guard let last, !last.isArchived else { return .landing }
        if last.isStreaming || hasUnsentInput { return .resume(last.id) }
        guard last.hasMessages else { return .landing }
        let lastActivity = max(last.updatedAt, lastViewedAt ?? .distantPast)
        return now.timeIntervalSince(lastActivity) < resumeWindow ? .resume(last.id) : .landing
    }

    /// The landing's jump-back list: pinned first, then recent; a chat with
    /// no message yet (no title, nothing answered) is left out. The engine's
    /// list holds no archived chat.
    package static func recents(_ conversations: [ChatList.Conversation]) -> [ChatList.Conversation] {
        let candidates = conversations
            .filter { !$0.title.isEmpty || !$0.lastLine.isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
        let pinned = candidates.filter(\.pinned).prefix(pinnedLimit)
        let recent = candidates.filter { !$0.pinned }.prefix(recentLimit)
        return Array(pinned) + Array(recent)
    }
}
