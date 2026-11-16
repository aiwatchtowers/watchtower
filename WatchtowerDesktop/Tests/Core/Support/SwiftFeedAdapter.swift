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
/// The mapping is the only code here. Two lists name every card or folder
/// field a Swift builder does not hand over as is:
/// - `goOnlyFields`: the Swift side does not compute it; the comparison
///   blanks it on both sides.
/// - `restatedFields`: the adapter derives it from Swift data with the rule a
///   Swift builder applies (which it does not expose); it is compared.
enum SwiftFeedAdapter {
    /// Not computed by Swift, each with why: `blankGoOnly` clears exactly these.
    static let goOnlyFields: [String: String] = [
        "folders[].waiting": "Task 6 sends 0 (pre-flight ruling F4); Task 7 ports the waiting count",
        "cards[].automation.builtin_id": "AutomationOutputCard does not carry its automation's built-in id",
        "cards[].body_clipped": "Clip is a Go-only option (the Mac never clips); no parity case sets it",
        "cards[].actions": "button states are Task 7's (InboxCardAction); both sides send none here",
        "cards[].ref_facts": "ref facts are Task 7's (InboxRefState facts); both sides send none here",
        "notice cards' source_line": "the Mac's notice row has no source line",
        "notice cards' preview": "the Mac's notice row has no summary line",
        "notice cards' priority": "a built-in move has no priority; the feed sends medium",
        "notice cards' content_hash": "a built-in move has no content hash; no write is guarded by one"
    ]

    /// Derived here with a Swift builder's own rule, each with where the rule
    /// lives; compared, not blanked.
    static let restatedFields: [String: String] = [
        "cards[].pinned": "InboxFolderEntries.build's pin: Waiting for me's card with rows that wait",
        "cards[].stamp": "InboxFolderEntries.row's detail time: written_at on a living card, else created_at",
        "cards[].source_line": "InboxCardTexts.sourceLine without its last ' · <time>' part (the models add it)",
        "notice cards' id": "Swift keys a notice by built-in id; the feed's n<rowid> is read from builtin_migrations"
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
    /// `disabledFeatures` is the Mac's feature list (ActionStripViewModel's
    /// `disabledFeatures`), passed to every reader as the app passes it.
    static func feed(_ db: Database, now: Date, folder: Int64?, disabledFeatures: Set<String>) throws -> Mapped {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let nowUTC = AutomationDates.format(now)
        let snapshot = try InboxFolderMenuSnapshot.read(db, nowUTC: nowUTC, disabledFeatures: disabledFeatures)
        let feedSnapshot = try InboxFeedQueries.read(
            db, nowUTC: nowUTC, dayLimit: ActionStripViewModel.dayPage, disabledFeatures: disabledFeatures)
        let inputs = InboxFolderEntries.Inputs(
            feed: feedSnapshot, folders: snapshot,
            approvalsOn: !disabledFeatures.contains(ActionStripViewModel.approvalsFeatureID),
            now: now, calendar: calendar)
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
            card.bodyClipped = false
            card.actions = []
            card.refFacts = []
            if card.cardKind == .notice, card.id.hasPrefix("n") {
                card.sourceLine = ""
                card.preview = ""
                card.priority = ""
                card.contentHash = ""
            }
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
