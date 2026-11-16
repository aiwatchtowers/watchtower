import Foundation

/// One folder's list (mobile Inbox spec §4.2, §7; mockup §1 and §6): what
/// waits on the owner first (approvals, reminders, a pinned Waiting for me),
/// then the rest newest first, grouped Today and Earlier by the client's own
/// zone. A folder deeper than three levels is listed in its level-3
/// ancestor. Cards hidden on `ok` are left out.
public struct InboxFolderModel: Equatable, Sendable {
    public let folder: Folder?
    /// Needs your decision, Today, Earlier: an empty section is left out.
    public let sections: [InboxSection]
    /// Every card listed, in section order.
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
        let listed = feed.cards.filter { tree.drawnID(of: $0.folderID) == folderID && !hidden.isHidden($0.id) }
        let models = listed.map {
            InboxCardModel(
                card: $0, platform: platform, grants: grants, blocksReadable: blocksReadable($0),
                now: now, timeZone: timeZone, hidden: hidden
            )
        }
        let decisions = models.filter { Self.waitsOnTheOwner($0.card) }
        let timed = models.filter { !Self.waitsOnTheOwner($0.card) }
            .map { (at: InboxTime.parse($0.card.stamp) ?? .distantPast, card: $0) }
            .sorted { $0.at > $1.at }
        let startOfToday = InboxTime.calendar(timeZone).startOfDay(for: now)
        sections = [
            InboxSection(title: TowerText.needsYourDecision, cards: decisions),
            InboxSection(title: TowerText.today, cards: timed.filter { $0.at >= startOfToday }.map(\.card)),
            InboxSection(title: TowerText.earlier, cards: timed.filter { $0.at < startOfToday }.map(\.card))
        ].filter { !$0.cards.isEmpty }
        cards = sections.flatMap(\.cards)
        let older = (feed.more ?? []).filter { tree.drawnID(of: $0.folderID) == folderID }.reduce(0) { $0 + $1.count }
        olderLine = older > 0 ? TowerText.olderCards(older) : nil
        if cards.isEmpty, older == 0, let folder, folder.kind == .owner {
            empty = (TowerText.emptyFolderTitle(folder.title), TowerText.emptyFolderBody)
        } else {
            empty = nil
        }
    }

    /// Listed before the timed cards: an approval, a reminder, a pinned card.
    static func waitsOnTheOwner(_ card: Card) -> Bool {
        card.pinned || card.approval != nil || card.cardKind == .approvalNative || card.cardKind == .reminder
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.folder == rhs.folder && lhs.sections == rhs.sections && lhs.olderLine == rhs.olderLine
            && lhs.empty?.title == rhs.empty?.title && lhs.empty?.body == rhs.empty?.body
    }
}

/// A titled group of a folder's cards.
public struct InboxSection: Equatable, Sendable {
    public let title: String
    public let cards: [InboxCardModel]
}
