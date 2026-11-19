import Foundation

/// One row of a Mac folder list (the Desktop's `InboxFolderListRow`): the
/// texts the Mac draws today, ported exactly from `InboxFolderEntries.row`.
/// A Thread briefs card becomes one `result` row per brief, as the Mac
/// lists them.
public struct InboxMacFolderRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case artifact, legacy, approval, result }

    /// The card's id (`o12`, `tracks`, `a7`, …).
    public let cardID: String
    /// The brief's action id for a Thread briefs row; nil otherwise.
    public let briefID: Int64?
    public let kind: Kind
    public let title: String
    /// "4 waiting", "today", "2 unread", "3 to judge"; empty draws none.
    public let summary: String
    /// "updated 6 min ago", "run #12 · 2 h ago", "Your day · Fri 6 Nov".
    public let detail: String
    public let unread: Bool

    public init(
        cardID: String,
        briefID: Int64? = nil,
        kind: Kind,
        title: String,
        summary: String = "",
        detail: String = "",
        unread: Bool = false
    ) {
        self.cardID = cardID
        self.briefID = briefID
        self.kind = kind
        self.title = title
        self.summary = summary
        self.detail = detail
        self.unread = unread
    }
}

/// The Mac's folder list over the feed: the cards of one folder in the
/// feed's order (Go decides membership and order), worded as the Mac words
/// them. Nothing here decides a rule: the counts come from `ref_facts`
/// (`open && waits`), the unread flags and the per-card texts from Go.
public enum InboxMacFolderRows {
    /// `cards` are one folder's cards in feed order; `approvals` is true for
    /// Needs approval (every card there is an approval row).
    public static func rows(_ cards: [Card], approvals: Bool, now: Date = Date()) -> [InboxMacFolderRow] {
        cards.flatMap { rows(of: $0, approvals: approvals, now: now) }
    }

    static func rows(of card: Card, approvals: Bool, now: Date) -> [InboxMacFolderRow] {
        if approvals || isApproval(card) {
            return [InboxMacFolderRow(cardID: card.id, kind: .approval, title: card.title, unread: true)]
        }
        guard let legacy = card.legacy else { return [artifactRow(card, now: now)] }
        switch legacy.kind {
        case .threadBriefs:
            return legacy.items.map { item in
                let applied = InboxTime.parse(item.stamp)
                return InboxMacFolderRow(
                    cardID: card.id, briefID: item.id, kind: .result, title: item.title,
                    detail: applied.map { TowerText.threadBriefAgo($0, now: now) } ?? TowerText.threadBrief)
            }
        case .morningBrief, .messages:
            return [InboxMacFolderRow(cardID: card.id, kind: .legacy, title: card.title, summary: card.preview,
                                      detail: card.sourceLine, unread: card.unread)]
        case .tracks, .ideas, .unknown:
            // Idea finder with no idea yet has no time to show.
            let updated = legacy.items.isEmpty ? nil : InboxTime.parse(card.stamp)
            return [InboxMacFolderRow(cardID: card.id, kind: .legacy, title: card.title, summary: card.preview,
                                      detail: updated.map { TowerText.macUpdated($0, now: now) } ?? "",
                                      unread: card.unread)]
        }
    }

    private static func artifactRow(_ card: Card, now: Date) -> InboxMacFolderRow {
        let waiting = card.refFacts.filter { $0.open && $0.waits }.count
        let stamp = InboxTime.parse(card.stamp) ?? now
        let detail = card.living
            ? TowerText.macUpdated(stamp, now: now)
            : TowerText.macRunLine(run: card.automation?.runID ?? 0, at: stamp, now: now)
        return InboxMacFolderRow(
            cardID: card.id, kind: .artifact, title: card.title,
            summary: waiting > 0 ? TowerText.macWaiting(waiting) : "", detail: detail, unread: card.unread)
    }

    /// A native approval, a due reminder or a failed built-in move (on a
    /// tree without Needs approval the root lists them). An artifact whose
    /// blocks were too large is also a `notice` card, but keeps its `o` id
    /// and stays an artifact row.
    private static func isApproval(_ card: Card) -> Bool {
        switch card.cardKind {
        case .approvalNative, .reminder: true
        case .notice: card.id.hasPrefix("n")
        case .artifact, .legacy, .unknown: card.approval != nil
        }
    }
}
