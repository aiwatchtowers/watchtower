import Foundation
import GRDB
import WatchtowerCore
import WatchtowerInterface

/// Test-only: today's Swift Inbox builders (`InboxFolderMenuSnapshot.read`,
/// `InboxFeedQueries.read`, `InboxFolderEntries.build`/`row`,
/// `InboxCardTexts`, `InboxCardSubject`) mapped to the generated `Feed`, so
/// `InboxFeedParityTests` can compare them with the Go feed over the shared
/// fixture `internal/inboxfeed/testdata/inbox_feed_cases.json`.
///
/// The mapping is the only code here: every value comes from a Swift
/// builder, except the fields listed in `goOnlyFields`, which the Swift side
/// does not compute and the comparison blanks on both sides.
enum SwiftFeedAdapter {
    /// What the adapter leaves to Go, each with why. Never silently skipped:
    /// `blankGoOnly` clears exactly these.
    static let goOnlyFields: [String: String] = [
        "folders[].waiting": "Task 6 sends 0 (pre-flight ruling F4); Task 7 ports the waiting count",
        "cards[].automation.builtin_id": "AutomationOutputCard does not carry its automation's built-in id"
    ]

    /// The entry kinds the Swift builder lists that Task 7 ports (approvals,
    /// thread briefs, legacy entries; ruling F4): left out of the mapped feed
    /// and reported in `Mapped.unmapped` so a test can see them.
    static let laterKinds: Set<String> = ["approval", "brief", "day", "tracks", "ideas", "messages"]

    struct Mapped {
        var feed: Feed
        /// The Swift entry ids left out (each of a `laterKinds` kind).
        var unmapped: [String]
    }

    /// The Swift builders' Inbox at `now` (zone UTC), narrowed to `folder`
    /// as `FeedRequest.folder` narrows it (every folder is still listed).
    static func feed(_ db: Database, now: Date, folder: Int64?) throws -> Mapped {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let nowUTC = AutomationDates.format(now)
        let snapshot = try InboxFolderMenuSnapshot.read(db, nowUTC: nowUTC)
        let feedSnapshot = try InboxFeedQueries.read(db, nowUTC: nowUTC, dayLimit: ActionStripViewModel.dayPage)
        let inputs = InboxFolderEntries.Inputs(feed: feedSnapshot, folders: snapshot, now: now, calendar: calendar)
        let tree = snapshot.tree
        let folders = tree.folders.map { item in
            Folder(
                id: item.id, kind: FolderKind(rawValue: item.kind.rawValue), slug: item.slug, title: item.title,
                icon: item.icon, parentID: item.parentID, position: item.position,
                hidden: !tree.isVisible(item.id), count: snapshot.counts[item.id] ?? 0, waiting: 0)
        }
        var cards: [Card] = []
        var unmapped: [String] = []
        for item in tree.folders where folder == nil || folder == item.id {
            for entry in InboxFolderEntries.build(folder: item, inputs) {
                let row = InboxFolderEntries.row(entry, inputs)
                switch entry {
                case let .artifact(card):
                    cards.append(artifact(card, folder: item.id, row: row, snapshot: snapshot, now: now, calendar: calendar))
                case let .builtinNotice(notice):
                    cards.append(try builtinNotice(db, notice, folder: item.id, row: row))
                case .approval, .brief, .legacyDay, .legacyTracks, .legacyIdeas, .legacyMessages:
                    unmapped.append(entry.id)
                }
            }
        }
        return Mapped(feed: Feed(v: 1, builtAt: "", folders: folders, cards: cards), unmapped: unmapped)
    }

    /// `feed` with the `goOnlyFields` cleared.
    static func blankGoOnly(_ feed: Feed) -> Feed {
        var out = feed
        out.builtAt = ""
        out.folders = out.folders.map { folder in
            var folder = folder
            folder.waiting = 0
            return folder
        }
        out.cards = out.cards.map { card in
            var card = card
            card.automation?.builtinID = ""
            return card
        }
        return out
    }

    /// An artifact's card from its list row and the card texts. Swift's
    /// source line ends in " · <time>" ("· 10:00", "· Updated 10 min ago"),
    /// which the screen models add now; the adapter drops that last part.
    private static func artifact(
        _ card: AutomationOutputCard,
        folder: Int64,
        row: InboxFolderListRow,
        snapshot: InboxFolderMenuSnapshot,
        now: Date,
        calendar: Calendar
    ) -> Card {
        let waiting = (snapshot.refs[card.id] ?? []).filter(snapshot.refState.waits).count
        return Card(
            id: "o\(card.id)", folderID: folder, cardKind: .artifact, title: row.title,
            sourceLine: withoutTime(InboxCardTexts.sourceLine(card, now: now, calendar: calendar)),
            preview: InboxCardTexts.preview(card.body),
            stamp: AutomationDates.format(card.isLiving ? card.writtenAt : card.createdAt),
            living: card.isLiving, unread: row.unread, priority: InboxCardSubject(card).priority,
            // InboxFolderEntries.build's pin: Waiting for me with rows that wait.
            pinned: snapshot.waitingForMe.automationID == card.automationID && waiting > 0,
            automation: CardAutomation(id: card.automationID, name: card.automationName, builtinID: "", runID: card.runID),
            blocks: card.blocksJSON, body: card.body, bodyClipped: false, contentHash: card.contentHash,
            actions: [], refFacts: [])
    }

    /// A failed move's card. Swift keys it by built-in id; the feed's id is
    /// the row's rowid (`n<rowid>`), read here for the mapping only.
    private static func builtinNotice(
        _ db: Database,
        _ notice: BuiltinUpgradeNotice,
        folder: Int64,
        row: InboxFolderListRow
    ) throws -> Card {
        let rowid = try Int64.fetchOne(
            db, sql: "SELECT rowid FROM builtin_migrations WHERE builtin_id = ?", arguments: [notice.builtinID]) ?? 0
        return Card(
            id: "n\(rowid)", folderID: folder, cardKind: .notice, title: row.title, sourceLine: "", preview: "",
            stamp: AutomationDates.format(notice.updatedAt), living: false, unread: row.unread, priority: "medium",
            pinned: false, blocks: "", body: notice.error, bodyClipped: false, contentHash: "", actions: [],
            refFacts: [])
    }

    private static func withoutTime(_ line: String) -> String {
        guard let range = line.range(of: " · ", options: .backwards) else { return line }
        return String(line[..<range.lowerBound])
    }
}
