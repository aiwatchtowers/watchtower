import Foundation

/// One folder's list (mobile Inbox spec §4.2, §7; mockup §1 and §6) in the
/// feed's own order, which Go computes as the Mac lists it (pinned, then
/// timed newest first, then the rest): never re-sorted here. The Mac draws
/// it flat, as today; the phone groups it into Needs your decision (an
/// approval, a reminder, a pinned card), Today and Earlier by the client's
/// own zone, each group keeping the feed order. A folder deeper than three
/// levels is listed in its level-3 ancestor. Cards hidden on `ok` are left
/// out.
public struct InboxFolderModel: Equatable, Sendable {
    public let folder: Folder?
    /// The phone's groups (an empty one left out); none on the Mac.
    public let sections: [InboxSection]
    /// Every card listed, in the feed's order.
    public let cards: [InboxCardModel]
    /// "N older cards are on your Mac." when the feed's limit left cards out.
    public let olderLine: String?
    /// An owner folder with nothing in it.
    public let empty: (title: String, body: String)?

    public init(
        feed: Feed,
        folderID: Int64,
        platform: Platform,
        hidden: InboxHiddenRows,
        now: Date,
        timeZone: TimeZone = .current,
        grants: Grants = .all,
        blocksReadable: (Card) -> Bool = { _ in true }
    ) {
        let tree = InboxFolderTree(feed.folders)
        folder = feed.folders.first { $0.id == folderID }
        cards = feed.cards
            .filter { tree.drawnID(of: $0.folderID) == folderID && !hidden.isHidden($0.id) }
            .map {
                InboxCardModel(
                    card: $0, platform: platform, grants: grants, blocksReadable: blocksReadable($0),
                    now: now, timeZone: timeZone, hidden: hidden
                )
            }
        sections = platform == .mac ? [] : Self.groups(cards, now: now, timeZone: timeZone)
        let older = (feed.more ?? []).filter { tree.drawnID(of: $0.folderID) == folderID }.reduce(0) { $0 + $1.count }
        olderLine = older > 0 ? TowerText.olderCards(older) : nil
        if cards.isEmpty, older == 0, let folder, folder.kind == .owner {
            empty = (TowerText.emptyFolderTitle(folder.title), TowerText.emptyFolderBody)
        } else {
            empty = nil
        }
    }

    /// The phone's groups of `cards`, each in the feed's order.
    static func groups(_ cards: [InboxCardModel], now: Date, timeZone: TimeZone) -> [InboxSection] {
        let startOfToday = InboxTime.calendar(timeZone).startOfDay(for: now)
        let timed = cards.filter { !waitsOnTheOwner($0.card) }
        let isToday = { (card: InboxCardModel) in (InboxTime.parse(card.card.stamp) ?? .distantPast) >= startOfToday }
        return [
            InboxSection(title: TowerText.needsYourDecision, cards: cards.filter { waitsOnTheOwner($0.card) }),
            InboxSection(title: TowerText.today, cards: timed.filter(isToday)),
            InboxSection(title: TowerText.earlier, cards: timed.filter { !isToday($0) })
        ].filter { !$0.cards.isEmpty }
    }

    /// The phone's Needs your decision: an approval, a reminder, a pinned card.
    static func waitsOnTheOwner(_ card: Card) -> Bool {
        card.pinned || card.approval != nil || card.cardKind == .approvalNative || card.cardKind == .reminder
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.folder == rhs.folder && lhs.cards == rhs.cards && lhs.sections == rhs.sections && lhs.olderLine == rhs.olderLine
            && lhs.empty?.title == rhs.empty?.title && lhs.empty?.body == rhs.empty?.body
    }
}

/// A titled group of a folder's cards.
public struct InboxSection: Equatable, Sendable {
    public let title: String
    public let cards: [InboxCardModel]
}
