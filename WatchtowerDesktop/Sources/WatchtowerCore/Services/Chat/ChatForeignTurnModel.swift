import Foundation

/// A turn of the open chat that the hub runs for the phone (spec 2026-11-15
/// §5 "A turn run elsewhere", mockup 4a): while a live `owner = 'hub'` lease
/// holds the conversation the composer shows `answeringFromPhone` with
/// Stop, Send is off (the draft stays), and the thread is re-read from the
/// database every `pollInterval` and once more when the lease is released.
///
/// Pure: the view model reads the lease every `pollInterval` while a chat is
/// open and hands it to `observe`, which says what to re-read.
package struct ChatForeignTurnModel: Equatable, Sendable {
    package static let answeringFromPhone = "Answering from your iPhone — you can watch here"
    /// How often the open chat's lease is read, and its thread re-read while
    /// the hub holds it.
    package static let pollInterval: Duration = .seconds(1)

    /// What one lease read asks the view model to re-read.
    package struct Tick: Equatable, Sendable {
        /// The thread: every read while the hub holds the lease, and the one
        /// after its release.
        package let reloadThread: Bool
        /// The Chats panel: the row's "answering" starts or ends.
        package let reloadPanel: Bool

        package init(reloadThread: Bool, reloadPanel: Bool) {
            self.reloadThread = reloadThread
            self.reloadPanel = reloadPanel
        }
    }

    /// The hub's turn on the open chat; nil when none holds a live lease.
    package private(set) var turnID: String?

    package init() {}

    /// The composer's line; nil when no turn runs elsewhere.
    package var line: String? { turnID == nil ? nil : Self.answeringFromPhone }
    /// Send waits for the release.
    package var blocksSend: Bool { turnID != nil }

    /// One read of the open chat's lease at `nowMS`.
    package mutating func observe(_ lease: ChatLease?, nowMS: Int64) -> Tick {
        let held = lease.flatMap { $0.owner == .hub && $0.isLive(nowMS: nowMS) ? $0.turnID : nil }
        let previous = turnID
        turnID = held
        return Tick(reloadThread: held != nil || previous != nil, reloadPanel: held != previous)
    }

    /// Another chat was opened: nothing is known about its lease yet.
    package mutating func reset() {
        turnID = nil
    }
}
