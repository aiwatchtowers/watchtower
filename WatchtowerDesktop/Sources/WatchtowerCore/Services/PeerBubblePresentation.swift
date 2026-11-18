import Foundation

/// How another agent's words are drawn in a Workchat feed (spec 2026-11-18
/// §6.6): the header line, the body, the colour and the action of a peer
/// card. Pure, so every string is tested; the views only map `Tone` to a colour.
/// The `peer` entries come from Go (`internal/sessionfeed`); the waiting card
/// comes from the sender's queued `session_messages` rows.
package enum PeerBubblePresentation {
    /// The card's hue: peer traffic, a sub-session that finished, a message that waits.
    package enum Tone: Equatable, Sendable { case peer, success, waiting }

    package struct Bubble: Equatable, Sendable {
        package var header: String
        package var body: String
        package var tone: Tone
        /// The button on the card's right ("Open"); nil for none.
        package var action: String?

        package init(header: String, body: String, tone: Tone, action: String? = nil) {
            self.header = header
            self.body = body
            self.tone = tone
            self.action = action
        }
    }

    /// The card of a `peer` entry; nil for an entry that is not one, or for a
    /// direction/kind this build does not know (the feed drops it).
    package static func bubble(for entry: SessionFeedEntry) -> Bubble? {
        guard entry.kind == "peer", let peer = entry.peer else { return nil }
        switch (peer.direction, peer.kind) {
        case ("in", "message"):
            return Bubble(header: "↘ From \(quoted(peer)) · \(peer.folder)", body: entry.text, tone: .peer)
        case ("in", "finished"):
            return Bubble(header: "✓ Sub-session \(quoted(peer)) finished · \(peer.folder)", body: entry.text, tone: .success)
        case ("out", "started"):
            return Bubble(header: "↗ Sub-session \(quoted(peer)) started · \(peer.folder)\(worktreeSuffix(peer))",
                          body: startedBody, tone: .peer)
        case ("out", "message"):
            return Bubble(header: "↗ To \(quoted(peer)) · \(peer.folder)", body: entry.text, tone: .peer)
        default:
            return nil
        }
    }

    /// What a started sub-session's card says under its header.
    package static let startedBody = "Brief sent."

    /// Why a queued message still waits.
    package enum Hold: Equatable, Sendable {
        case permissionPrompt, busy, ownerTyping

        /// The hold of a receiver by what the Desktop reads of it: a session at a permission prompt, a working one,
        /// else an idle one the owner is typing in (the deliverer holds a message for nothing else).
        package static func of(receiverNeedsApproval: Bool, receiverWorking: Bool) -> Self {
            if receiverNeedsApproval { return .permissionPrompt }
            return receiverWorking ? .busy : .ownerTyping
        }
    }

    package static let permissionReason = "The session is at a permission prompt; the message goes once it is answered."
    package static let busyReason = "The session is busy; the message goes when it is idle."
    package static let ownerTypingReason = "The owner is typing in this session; the message goes after that."
    package static let daemonStoppedReason = "Watchtower's background sync is stopped; the message goes when it runs."
    package static let openAction = "Open"

    /// The reason line of a waiting message: a stopped daemon comes first (nothing delivers while it is down).
    package static func waitingReason(hold: Hold, daemonRunning: Bool) -> String {
        guard daemonRunning else { return daemonStoppedReason }
        return switch hold {
        case .permissionPrompt: permissionReason
        case .busy: busyReason
        case .ownerTyping: ownerTypingReason
        }
    }

    /// The card of a queued message to the session titled `title`.
    package static func waiting(title: String, hold: Hold, daemonRunning: Bool) -> Bubble {
        Bubble(header: "⏸ Message to “\(title)” is waiting",
               body: waitingReason(hold: hold, daemonRunning: daemonRunning), tone: .waiting, action: openAction)
    }

    private static func quoted(_ peer: SessionFeedPeer) -> String {
        "“\(peer.title.isEmpty ? "#\(peer.sessionID)" : peer.title)”"
    }

    private static func worktreeSuffix(_ peer: SessionFeedPeer) -> String {
        peer.worktree.isEmpty ? "" : " · ⑂ \((peer.worktree as NSString).lastPathComponent)"
    }
}
