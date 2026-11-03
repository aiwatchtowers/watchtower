import Foundation

/// What the automation editor's Look step shows (Inbox builder A, spec "The
/// Look step" → States): one case per row of the spec's table. A plain
/// value, so the pane renders on fixtures; `AutomationLookPreviewModel`
/// (plan Task 11) produces it. Cards carry their stored JSON text, decoded
/// by the view (WatchtowerCore stays Kit-free).
package enum AutomationLookPaneContent: Equatable, Sendable {
    /// One Inbox card a dry run made.
    package struct Card: Equatable, Sendable {
        package let title: String
        /// `high`, `normal` or `low`.
        package let priority: String
        /// A living card's key; "" for a feed card.
        package let key: String
        /// The block document; "" when the card has none.
        package let blocksJSON: String
        /// The markdown body of a card without blocks, else Go's plain text.
        package let body: String
        /// The card's own buttons (`db.InboxAction` array).
        package let actionsJSON: String

        package init(
            title: String,
            priority: String = "normal",
            key: String = "",
            blocksJSON: String = "",
            body: String = "",
            actionsJSON: String = "[]"
        ) {
            self.title = title
            self.priority = priority
            self.key = key
            self.blocksJSON = blocksJSON
            self.body = body
            self.actionsJSON = actionsJSON
        }
    }

    /// The cards of the last preview and which one was shown (`running` draws them dimmed).
    package struct Shown: Equatable, Sendable {
        package let cards: [Card]
        package let selected: Int

        package init(cards: [Card], selected: Int = 0) {
            self.cards = cards
            self.selected = selected
        }
    }

    /// The recipe has no `outputs: [inbox]`.
    case noInboxOutput
    /// No dry run of any text yet.
    case empty
    /// The owner's Dry run is in flight, over the last preview (dimmed) or over the empty state (nil).
    case running(previous: Shown?)
    /// The newest dry run of this text failed: the error and the journal's last steps.
    case failed(message: String, steps: [String])
    /// The dry run succeeded and made no Inbox card.
    case noCard(tokens: Int)
    /// The newest dry run of this text made at least one card.
    case preview(cards: [Card], selected: Int, tokens: Int, at: Date)
    /// The newest dry run is of other bytes than the text on screen.
    case stale(cards: [Card], selected: Int)
    /// The draft stopped at an `mcp()` call; the cards made before it, if any.
    case stopped(cards: [Card])

    /// "Waiting for you · 3"; a living card adds its key.
    package static func pickerTitle(_ card: Card, index: Int, count: Int) -> String {
        let key = card.key.isEmpty ? "" : " · key: \(card.key)"
        return "Card \(index + 1) of \(count) — \(card.title)\(key)"
    }

    /// "Dry run · 3,100 tokens · just now".
    package static func runLine(tokens: Int, at: Date?, now: Date) -> String {
        var parts = ["Dry run", AutomationCardPresentation.tokensText(Int64(tokens), estimated: false)]
        if let at { parts.append(age(of: at, now: now)) }
        return parts.joined(separator: " · ")
    }

    private static func age(of date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
