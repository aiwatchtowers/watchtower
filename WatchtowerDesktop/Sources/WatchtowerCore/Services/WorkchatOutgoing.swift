import Foundation

/// A line the owner sent from the Workchat composer (#711), shown at the end
/// of the feed until the transcript shows it as an owner entry.
package struct WorkchatOutgoing: Identifiable, Equatable, Sendable {
    /// Where the line is, per `SessionLineDelivery.Delivery` (spec §4).
    package enum State: Equatable, Sendable {
        /// The first try is under way.
        case sending
        /// Held or queued: it goes when the agent stops (Cancel drops it).
        case queued
        /// Pasted without Return: the owner presses it in the terminal.
        case typed
        /// On the clipboard: the terminal took no pasted text.
        case copied
        /// Submitted: waits for its echo in the feed.
        case sent
        /// The session ended before it went: the text is back in the field.
        case notSent
    }

    /// Why a queued line waits: the reason its check held it
    /// (`SessionControl.LineHold`) — the spec's hold captions (§6.3).
    package enum HoldReason: Equatable, Sendable {
        /// A permission prompt is up: the owner answers it in the terminal.
        case needsApproval
        /// The agent works, or turns to the line just submitted.
        case agentBusy
        /// The terminal prompt holds text not submitted.
        case promptHasText
    }

    package let id: UUID
    /// What goes to the terminal: the typed text with its paste tokens expanded, then the attachment paths.
    package let text: String
    /// The owner's own words as typed, paste tokens unexpanded (#2065 §6), without the attachment paths.
    package let typedText: String
    /// The files sent with the line, as written into `text` (`quoted`): the chips' and the image tokens'.
    package let attachmentPaths: [String]
    /// When the owner sent it: an echo is dated at or after this.
    package let sentAt: Date
    package var state: State
    /// When it was submitted, typed or copied; `echoWindow` counts from here,
    /// so a line queued for long still gets its full window.
    package var deliveredAt: Date?
    /// Submitted while the agent worked: the agent reads it at its next
    /// step, so its echo can come long after delivery (no `echoWindow`).
    package var sentWhileBusy: Bool
    /// Why it waits while `queued`; nil: not known (another line goes first,
    /// or no check said yet).
    package var holdReason: HoldReason?

    package init(
        id: UUID,
        text: String,
        sentAt: Date,
        state: State,
        deliveredAt: Date? = nil,
        sentWhileBusy: Bool = false,
        typedText: String? = nil,
        attachmentPaths: [String] = []
    ) {
        self.id = id
        self.text = text
        self.typedText = typedText ?? text
        self.attachmentPaths = attachmentPaths
        self.sentAt = sentAt
        self.state = state
        self.deliveredAt = deliveredAt
        self.sentWhileBusy = sentWhileBusy
    }

    /// The caption under a line (spec §4's table, #2065 §5); nil where the
    /// bubble shows the send time. `working`: the session's agent works now;
    /// `holdsUntilIdle`: a queued line waits for the agent to stop
    /// (`WorkchatModel.holdsUntilIdle`), otherwise only for a prompt, the
    /// owner's typing or the settle after the previous line. A queued line's
    /// `holdReason` says why it waits (its actions go on a row of their own).
    package static func caption(
        state: State,
        working: Bool,
        holdsUntilIdle: Bool,
        sentWhileBusy: Bool = false,
        holdReason: HoldReason? = nil
    ) -> String? {
        switch state {
        case .queued where holdReason != nil: holdCaption(holdReason, working: working, holdsUntilIdle: holdsUntilIdle)
        case .sending: "Sending…"
        case .queued: holdsUntilIdle ? "Queued · sends when the agent stops ·" : "Queued · sends in a moment ·"
        case .typed: "Typed into the terminal, not sent: press Return there ·"
        case .copied: "Copied to the clipboard: the terminal does not accept pasted text ·"
        case .notSent: "Not sent: the session ended"
        case .sent: sentWhileBusy && working ? "Queued · the agent reads it at its next step" : nil
        }
    }

    /// A held line's actions (spec §6.3): Send together for one held for the
    /// prompt's text, Cancel for any queued line.
    package static let sendTogether = "Send together"
    package static let cancel = "Cancel"

    private static func holdCaption(_ reason: HoldReason?, working: Bool, holdsUntilIdle: Bool) -> String? {
        switch reason {
        case .needsApproval?: "Waiting: answer the permission prompt in the terminal"
        case .agentBusy?: working && holdsUntilIdle ? "Queued · sends when the agent stops" : "Queued · sends in a moment"
        case .promptHasText?: "Waiting: the terminal prompt holds text"
        case nil: nil
        }
    }

    /// A submitted line with no echo this long stays a plain local bubble
    /// (a `/clear` writes no owner entry): the phone's rule.
    package static let echoWindow: TimeInterval = 90

    /// The feed's owner entry for this line: same text with whitespace collapsed
    /// (a "/name args" line equals the parser's slash entry), dated at or after sentAt.
    /// Matched on `text`, the expanded line the transcript records (#2065 §6), not on the tokenized `typedText`.
    package static func matches(_ entry: SessionFeedEntry, line: Self) -> Bool {
        guard entry.kind == "owner", let at = entry.at, at >= line.sentAt else { return false }
        if line.attachmentPaths.isEmpty { return collapsed(entry.text) == collapsed(line.text) }
        // Claude Code records a pasted image path as "[Image #N]"; the feed
        // may also show "[image]". A path comes back quoted or not.
        return withoutImageMarkers(withoutPaths(entry.text, line.attachmentPaths))
            == withoutImageMarkers(withoutPaths(line.text, line.attachmentPaths))
    }

    /// A path as it goes into a line: one with a space, a double quote or a backslash in double quotes, with `\`
    /// and `"` escaped inside, as a shell reads it. A line break never gets here (`WorkchatModel` refuses it).
    package static func quoted(_ path: String) -> String {
        guard path.contains(where: { $0 == " " || $0 == "\"" || $0 == "\\" }) else { return path }
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func withoutPaths(_ text: String, _ paths: [String]) -> String {
        paths.reduce(text) { text, path in
            text.replacingOccurrences(of: quoted(path), with: " ")
                .replacingOccurrences(of: "\"\(path)\"", with: " ")
                .replacingOccurrences(of: path, with: " ")
        }
    }

    private static let imageMarker = try? NSRegularExpression(pattern: #"\[(?:Image #\d+|image)\]"#)

    private static func withoutImageMarkers(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let bare = imageMarker?.stringByReplacingMatches(in: text, range: range, withTemplate: " ") ?? text
        return collapsed(bare)
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
