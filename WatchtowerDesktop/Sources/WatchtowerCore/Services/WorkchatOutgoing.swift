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

    package let id: UUID
    /// What goes to the terminal: the typed text, then the attachment paths.
    package let text: String
    /// The owner's own words, without the attachment paths.
    package let typedText: String
    /// The files sent with the line, as written into `text` (quoted or not there).
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

    /// A submitted line with no echo this long stays a plain local bubble
    /// (a `/clear` writes no owner entry): the phone's rule.
    package static let echoWindow: TimeInterval = 90

    /// The feed's owner entry for this line: same text with whitespace collapsed
    /// (a "/name args" line equals the parser's slash entry), dated at or after sentAt.
    package static func matches(_ entry: SessionFeedEntry, line: Self) -> Bool {
        guard entry.kind == "owner", let at = entry.at, at >= line.sentAt else { return false }
        var echoed = entry.text
        // Claude Code records a pasted image path as "[Image #N]"; the feed
        // may also show "[image]". A path comes back quoted or not.
        for path in line.attachmentPaths {
            echoed = echoed.replacingOccurrences(of: "\"\(path)\"", with: " ")
                .replacingOccurrences(of: path, with: " ")
        }
        if line.attachmentPaths.isEmpty { return collapsed(echoed) == collapsed(line.text) }
        return withoutImageMarkers(echoed) == withoutImageMarkers(line.typedText)
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
