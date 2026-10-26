import Foundation

/// The Undo window of the Chats panel's quick delete (spec 2026-10-26
/// §5.3), the `PendingSessionDeletes` twin. A deleted chat is hidden at
/// once; its DELETE waits until the window ends, so Undo brings it back
/// untouched. Unlike the sessions' batch, one chat waits at a time: another
/// delete replaces it in the bar, and the one it replaces commits.
package struct PendingChatDeletes: Equatable, Sendable {
    package struct Entry: Equatable, Sendable {
        package let conversationID: Int64
        package let title: String

        package init(conversationID: Int64, title: String) {
            self.conversationID = conversationID
            self.title = title
        }
    }

    /// The Undo window, the sessions panel's.
    package static let window: TimeInterval = PendingSessionDeletes.window

    /// The chat waiting for its DELETE; nil while nothing is pending.
    package private(set) var pending: Entry?
    /// When it commits; nil while nothing is pending.
    package private(set) var deadline: Date?

    package init() {}

    /// The hidden chat ids — every read the owner sees drops them.
    package var ids: Set<Int64> { pending.map { [$0.conversationID] } ?? [] }

    /// The bar's text: "Chat “…” deleted"; nil while nothing is pending.
    package var toastText: String? {
        pending.map { "Chat “\($0.title)” deleted" }
    }

    /// `entry` waits from `now` for the window; returns the chat it
    /// replaces, which the caller commits now (nil when there was none or
    /// it is the same chat).
    package mutating func enqueue(_ entry: Entry, now: Date) -> Entry? {
        let replaced = pending?.conversationID == entry.conversationID ? nil : pending
        pending = entry
        deadline = now.addingTimeInterval(Self.window)
        return replaced
    }

    /// Undo: the pending chat back, nothing pending.
    package mutating func restore() -> Entry? {
        take()
    }

    /// The chat to commit once `now` reached the deadline (and clears it);
    /// nil before the deadline or while nothing is pending.
    package mutating func expired(now: Date) -> Entry? {
        guard let deadline, now >= deadline else { return nil }
        return take()
    }

    /// Commit now, whatever the deadline (leaving the tab, quitting).
    package mutating func take() -> Entry? {
        let taken = pending
        pending = nil
        deadline = nil
        return taken
    }
}
