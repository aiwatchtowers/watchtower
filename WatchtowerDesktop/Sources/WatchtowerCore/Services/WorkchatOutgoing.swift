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
    /// When the owner's Send together tried the line beside the prompt's text:
    /// the transcript records that text and the line as one owner entry ending
    /// in the line, dated at or after this.
    package var sentTogetherAt: Date?

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
    /// A line sent together with the prompt's text matches an entry from the try that wrote it on that ends with it
    /// or holds it as whole words (pasted mid-draft, #2386) — one with only files: an entry that holds one of its
    /// paths whole, or an image marker when it sent an image.
    package static func matches(_ entry: SessionFeedEntry, line: Self) -> Bool {
        guard entry.kind == "owner", let at = entry.at, at >= line.sentAt else { return false }
        // Claude Code records a pasted image path as "[Image #N]"; the feed
        // may also show "[image]". A path comes back quoted or not.
        let (recorded, sent) = line.attachmentPaths.isEmpty
            ? (collapsed(entry.text), collapsed(line.text))
            : (withoutImageMarkers(withoutPaths(entry.text, line.attachmentPaths)),
               withoutImageMarkers(withoutPaths(line.text, line.attachmentPaths)))
        guard let together = line.sentTogetherAt else { return recorded == sent }
        guard at >= together else { return false }
        guard !sent.isEmpty else { return holdsFile(of: line, in: entry.text) }
        return recorded.hasSuffix(sent) || holdsWords(recorded, sent)
    }

    /// `words` in `text` with a word boundary at each end of some occurrence (a letter, digit or `_` on neither
    /// side across a boundary): pasted mid-draft, it may sit before punctuation ("run tests, then deploy").
    private static func holdsWords(_ text: String, _ words: String) -> Bool {
        guard let first = words.first, let last = words.last else { return false }
        let isWord: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" }
        var from = text.startIndex
        while let found = text.range(of: words, range: from..<text.endIndex) {
            from = text.index(after: found.lowerBound)
            let startsWord = found.lowerBound == text.startIndex || !isWord(first)
                || !isWord(text[text.index(before: found.lowerBound)])
            let endsWord = found.upperBound == text.endIndex || !isWord(last) || !isWord(text[found.upperBound])
            if startsWord, endsWord { return true }
        }
        return false
    }

    /// Whether `text` holds one of the line's paths as a whole token (quoted or not, bounded by whitespace, a
    /// quote or the ends), or — when the line sent an image — an image marker.
    private static func holdsFile(of line: Self, in text: String) -> Bool {
        if line.attachmentPaths.contains(where: { holdsToken(text, path: $0) }) { return true }
        guard line.attachmentPaths.contains(where: isImagePath),
              let imageMarker else { return false }
        return imageMarker.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// `path` in `text` as a whole token, in any of its spellings. Before it: the start, whitespace, a quote, or the
    /// prompt's text it was pasted straight after (a word with no `/` in it — not a longer path's head). After it: the
    /// end, whitespace or a quote, past any closing punctuation. A bare path right after a quote must close that
    /// quote: otherwise it only starts a longer quoted name (#2386).
    private static func holdsToken(_ text: String, path: String) -> Bool {
        let quotes: Set<Character> = ["\"", "'"]
        for form in Set([quoted(path), "\"\(path)\"", path]) {
            var from = text.startIndex
            while let found = text.range(of: form, range: from..<text.endIndex) {
                from = text.index(after: found.lowerBound)
                let opening = found.lowerBound == text.startIndex ? nil : text[text.index(before: found.lowerBound)]
                if let opening, quotes.contains(opening), !quotes.contains(form.first ?? " ") {
                    if found.upperBound < text.endIndex, text[found.upperBound] == opening { return true }
                    continue
                }
                guard opening.map({ $0.isWhitespace || quotes.contains($0) }) ?? true
                    || gluedToWord(text, before: found.lowerBound) else { continue }
                if endsToken(text, at: found.upperBound) { return true }
            }
        }
        return false
    }

    /// The text before `index`, back to whitespace or a quote, is a word with no `/` (the owner's text the path was
    /// pasted straight after) — not a path's own head (`pathHead`).
    /// The scan back stops at the first `/` (no copy of a long prefix per occurrence).
    private static func gluedToWord(_ text: String, before index: String.Index) -> Bool {
        var start = index
        while start > text.startIndex {
            let previous = text.index(before: start)
            let char = text[previous]
            if char == "/" { return false }
            if char.isWhitespace || char == "\"" || char == "'" { break }
            start = previous
        }
        return start < index && !pathHead(String(text[start..<index]))
    }

    /// A head that makes the path after it another path, matched whole (#2386 fix rounds 1-3). Prose such as `...`,
    /// `$19.99` or `.NET:` is not one.
    private static let pathHeads = try? NSRegularExpression(pattern: "^(?:" + [
        #"\.\.?"#,                          // . and ..
        #"\.[A-Za-z0-9_][A-Za-z0-9_.-]*"#,  // a dot-directory: .hidden
        #"~[A-Za-z0-9_.-]*"#,               // ~ and ~user
        #"~[+-]"#,                          // ~+ and ~-
        #"\$[A-Za-z_][A-Za-z0-9_]*"#,       // $NAME
        #"\$[0-9@*#?$!-]"#,                 // $1, $@ and the other one-character parameters
        #"\$\{[^}]*\}"#,                   // ${…}
        #"\$\([^)]*\)"#                    // $(…)
    ].joined(separator: "|") + ")$")

    private static func pathHead(_ head: String) -> Bool {
        pathHeads?.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)) != nil
    }

    /// `index` is the end, whitespace or a quote, once any closing punctuation is skipped.
    private static func endsToken(_ text: String, at index: String.Index) -> Bool {
        let rest = text[index...].drop { ".,;:!?)]}".contains($0) }
        guard let next = rest.first else { return true }
        return next.isWhitespace || next == "\"" || next == "'"
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp"]

    private static func isImagePath(_ path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
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
