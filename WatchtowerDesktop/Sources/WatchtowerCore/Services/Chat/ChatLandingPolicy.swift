import Foundation

/// Entering the Chat tab: reopen the last conversation or show the landing
/// (owner decision 2026-09-28). Pure — the clock and every input are
/// injected (the `ChatSessionPolicy` precedent); `ChatViewModel.enterTab`
/// gathers the snapshot and applies the decision.
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

        /// A conversation with no message has no active leaf.
        package init(_ conv: ChatConversation, isStreaming: Bool) {
            self.init(id: conv.id, updatedAt: conv.updatedDate, isArchived: conv.archivedAt != nil,
                      hasMessages: conv.activeLeafMessageID != nil, isStreaming: isStreaming)
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

    /// The landing's jump-back list: pinned first, then recent; archived
    /// chats and chats with neither a message nor an unsent file (an
    /// untouched "New Chat") are left out.
    package static func recents(_ conversations: [ChatConversation]) -> [ChatConversation] {
        let candidates = conversations
            .filter { $0.archivedAt == nil && ($0.activeLeafMessageID != nil || $0.hasAttachments) }
            .sorted { $0.updatedAt > $1.updatedAt }
        let pinned = candidates.filter(\.pinned).prefix(pinnedLimit)
        let recent = candidates.filter { !$0.pinned }.prefix(recentLimit)
        return Array(pinned) + Array(recent)
    }
}
