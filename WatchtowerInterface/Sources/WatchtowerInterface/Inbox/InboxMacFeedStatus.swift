import Foundation

/// The Mac Inbox's line about its feed (mobile Inbox mockup §7): what shows
/// while the tower's list is not current. A failure keeps the last list
/// under its line; with no list yet the line shows alone.
public struct InboxMacFeedStatus: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The first read is on its way: a spinner and no list.
        case loading
        /// The tower is down and the client reconnects: a spinner, the list kept.
        case reconnecting
        /// A read failed: the reason and its button, the list kept when there is one.
        case failed
    }

    public let kind: Kind
    public let text: String
    /// The failure's button (`TowerText.retry`, or `restart` for another
    /// version); nil for the other kinds.
    public let actionTitle: String?

    public init(kind: Kind, text: String, actionTitle: String? = nil) {
        self.kind = kind
        self.text = text
        self.actionTitle = actionTitle
    }

    /// The line for a screen that has a list (`hasList`: a feed answered)
    /// from `shownAt`, the loader's last `failure`, the client's `state`, and
    /// whether the reconnecting line is due; nil when the list is current. A
    /// kept list names when it was read, in `timeZone`.
    public static func resolve(
        hasList: Bool,
        shownAt: Date?,
        failure: TowerFailure?,
        state: TowerScreenState,
        showsReconnectingLine: Bool,
        now: Date,
        timeZone: TimeZone = .current
    ) -> Self? {
        let failed: TowerFailure? = if case let .failed(screen) = state { failure ?? screen } else { failure }
        if let failed {
            if failed.kind == .version {
                return Self(kind: .failed, text: TowerText.differentVersion, actionTitle: failed.actionTitle)
            }
            guard hasList, let shownAt else {
                return Self(kind: .failed, text: failed.sentence, actionTitle: failed.actionTitle)
            }
            let reason = failed.sentence.hasSuffix(".") ? String(failed.sentence.dropLast()) : failed.sentence
            return Self(kind: .failed,
                        text: TowerText.refreshFailed(reason: reason, shownAt: shownAt, timeZone: timeZone, now: now),
                        actionTitle: failed.actionTitle)
        }
        if case .reconnecting = state, showsReconnectingLine {
            return Self(kind: .reconnecting, text: TowerText.reconnecting)
        }
        if !hasList { return Self(kind: .loading, text: TowerText.loadingInboxMac) }
        return nil
    }
}
