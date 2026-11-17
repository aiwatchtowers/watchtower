import Foundation
import GRDB
import WatchtowerCore
import WatchtowerInterface

/// Canned tower feeds for the Inbox's view-model tests (Task 11d). The Mac
/// lists what the tower's `inbox.feed` lists; a test whose subject is the
/// view model (its writes, selection, errors) hands it a feed naming the
/// records it seeded, and the panes read those records by id. What a feed
/// lists — the Inbox's rules — is Go's and is tested there
/// (`internal/inboxfeed`: the parity cases, `TestStrip0N_*`, `TestApproval01_*`).
package enum TestInboxFeeds {
    /// One card of a canned feed.
    package enum Entry {
        case output(Int64, unread: Bool = true, refs: [RefFacts] = [])
        case action(Int64)
        case reminder(Int64)
        case notice(Int64)
        case day(String, unread: Bool = false)
        case tracks([Int64], stopped: [Int64] = [])
        case ideas([Int64], awaiting: [Int64] = [])
        case messages([Int64])
        case brief(Int64)
    }

    /// A feed over `pool`'s folder tree: `root` in the root folder, and
    /// `approvals` in Needs approval (the root on a tree without it). Each
    /// folder's count is its own cards'.
    package static func feed(_ pool: DatabasePool, root: [Entry] = [], approvals: [Entry] = []) throws -> Feed {
        let tree = try pool.read { db in try InboxFolderQueries.tree(db) }
        let rootID = tree.root.id
        let approvalsID = tree.approvals?.id ?? rootID
        let cards = root.map { card($0, folder: rootID) } + approvals.map { card($0, folder: approvalsID) }
        let folders = tree.folders.map { folder in
            Folder(
                id: folder.id, kind: FolderKind(rawValue: folder.kind.rawValue), slug: folder.slug, title: folder.title,
                icon: folder.icon, parentID: folder.parentID, position: folder.position, hidden: folder.hidden,
                count: cards.filter { $0.folderID == folder.id && ($0.unread || $0.folderID == approvalsID) }.count,
                waiting: 0)
        }
        return Feed(v: 1, builtAt: "2026-11-16T12:00:00Z", folders: folders, cards: cards)
    }

    /// A feed listing the Inbox records `pool` holds that are still open
    /// by their own row (an output neither done nor dismissed, a pending
    /// reminder, an unresolved message, an undecided proposal, a failed
    /// built-in move): a press or pane test's stand-in for the tower's read.
    /// Not the Inbox's rules (Go's, tested there): coarse row states only,
    /// so a written row leaves on the next listing. Outputs go to their
    /// folder (`inbox_artifact_folders`), tracks (dismissed ones in the
    /// Stopped fold), ideas, messages, day cards and thread briefs to the
    /// root; proposals, reminders and notices to Needs approval.
    package static func everything(_ pool: DatabasePool) throws -> Feed {
        func ids(_ db: Database, _ sql: String) -> [Int64] {
            (try? Int64.fetchAll(db, sql: sql)) ?? []
        }
        let read = try pool.read { db in
            (outputs: ids(db, "SELECT id FROM automation_outputs WHERE kind = 'inbox' AND done_at IS NULL AND dismissed_at IS NULL ORDER BY id"),
             folders: Dictionary((try? Row.fetchAll(db, sql: "SELECT output_id, folder_id FROM inbox_artifact_folders"))?
                .map { (($0["output_id"] as Int64?) ?? 0, ($0["folder_id"] as Int64?) ?? 0) } ?? []) { first, _ in first },
             actions: ids(db, """
                SELECT id FROM agent_actions
                WHERE tool != 'brief_context' AND status IN ('pending','approved','failed','executing') ORDER BY id
                """),
             briefs: ids(db, "SELECT id FROM agent_actions WHERE tool = 'brief_context' AND status = 'applied' ORDER BY id"),
             reminders: ids(db, "SELECT id FROM reminders WHERE status = 'pending' ORDER BY id"),
             notices: ids(db, "SELECT rowid FROM builtin_migrations WHERE status = 'failed' ORDER BY rowid"),
             tracks: ids(db, "SELECT id FROM tracks WHERE dismissed_at = '' ORDER BY id"),
             stopped: ids(db, "SELECT id FROM tracks WHERE dismissed_at != '' ORDER BY id"),
             ideas: ids(db, "SELECT id FROM ideas WHERE status != 'merged' ORDER BY id"),
             messages: ids(db, "SELECT id FROM inbox_items WHERE status NOT IN ('resolved','dismissed') ORDER BY id"),
             dates: (try? String.fetchAll(db, sql: "SELECT DISTINCT date FROM briefings ORDER BY date DESC")) ?? [])
        }
        var root: [Entry] = read.dates.map { .day($0) } + read.briefs.map { .brief($0) }
        if !read.tracks.isEmpty || !read.stopped.isEmpty { root.append(.tracks(read.tracks, stopped: read.stopped)) }
        if !read.ideas.isEmpty { root.append(.ideas(read.ideas)) }
        if !read.messages.isEmpty { root.append(.messages(read.messages)) }
        let approvals: [Entry] = read.notices.map { .notice($0) } + read.actions.map { .action($0) }
            + read.reminders.map { .reminder($0) }
        var result = try feed(pool, root: root, approvals: approvals)
        let rootID = result.folders.first { $0.kind == .root }?.id ?? 0
        let outputs = read.outputs.reversed().map { id in card(.output(id), folder: read.folders[id] ?? rootID) }
        result.cards = outputs + result.cards
        for index in result.folders.indices {
            let folderID = result.folders[index].id
            result.folders[index].count += outputs.filter { $0.folderID == folderID }.count
        }
        return result
    }

    /// A ref row's facts: shown, and waiting when `waits`.
    package static func ref(_ kind: RefKind, _ id: Int64, waits: Bool = true, reply: Bool = false) -> RefFacts {
        RefFacts(kind: kind, id: id, open: true, waits: waits, reply: reply, replyWaiting: false, link: "",
                 triggerType: "", custom: false, linkedTargetID: 0, ideaKind: "", ideaStatus: "")
    }

    private static func card(_ entry: Entry, folder: Int64) -> Card {
        switch entry {
        case let .output(id, unread, refs):
            return plain("o\(id)", folder, .artifact, unread: unread, refs: refs)
        case let .action(id):
            return plain("a\(id)", folder, .approvalNative, unread: true, refs: [ref(.action, id)])
        case let .reminder(id):
            return plain("r\(id)", folder, .reminder, unread: true, refs: [ref(.reminder, id)])
        case let .notice(id):
            return plain("n\(id)", folder, .notice, unread: true)
        case let .day(date, unread):
            return legacy("brief-\(date)", folder, .morningBrief, [], unread: unread, title: "Morning brief")
        case let .tracks(ids, stopped):
            return legacy("tracks", folder, .tracks, ids.map { item(.track, $0) } + stopped.map { item(.track, $0, stopped: true) },
                          title: "Track my threads")
        case let .ideas(ids, awaiting):
            return legacy("ideas", folder, .ideas, awaiting.map { item(.idea, $0, unread: true) } + ids.map { item(.idea, $0) },
                          title: "Idea finder")
        case let .messages(ids):
            return legacy("messages", folder, .messages, ids.map { item(.inboxItem, $0) }, title: "Messages")
        case let .brief(id):
            return legacy("thread-brief-\(id)", folder, .threadBriefs, [item(.action, id)], title: "Thread brief")
        }
    }

    private static func plain(_ id: String, _ folder: Int64, _ kind: CardKind, unread: Bool, refs: [RefFacts] = []) -> Card {
        Card(id: id, folderID: folder, cardKind: kind, title: id, sourceLine: "", preview: "",
             stamp: "2026-11-16T10:00:00Z", living: false, unread: unread, priority: "medium", pinned: false,
             blocks: "", body: "", bodyClipped: false, link: "", contentHash: "", actions: [], refFacts: refs)
    }

    private static func legacy(
        _ id: String, _ folder: Int64, _ kind: LegacyKind, _ items: [LegacyItem], unread: Bool = false, title: String
    ) -> Card {
        // Each listed record's row is shown (its ref facts), as Go sends them.
        let refs = items.filter { $0.refKind != .action }
            .map { ref($0.refKind, $0.id, waits: $0.refKind == .inboxItem || $0.unread) }
        var card = plain(id, folder, .legacy, unread: unread, refs: refs)
        card.title = title
        card.legacy = LegacySection(kind: kind, items: items, attention: [])
        return card
    }

    private static func item(_ kind: RefKind, _ id: Int64, unread: Bool = false, stopped: Bool = false) -> LegacyItem {
        LegacyItem(refKind: kind, id: id, title: "", subtitle: "", preview: "", stamp: "2026-11-16T10:00:00Z", end: "",
                   unread: unread, high: false, stopped: stopped, done: false, date: "")
    }
}

package extension ActionStripViewModel {
    /// Lists every Inbox record the pool holds (`TestInboxFeeds.everything`)
    /// and reads them: a press or pane test's stand-in for the tower's read.
    @MainActor
    func refreshListingEverything() async {
        if let feed = try? TestInboxFeeds.everything(databasePool) { receiveTowerFeed(feed) }
        await refresh()
    }

    /// Lists `feed` (as the tower would) and reads its records.
    @MainActor
    func showFeed(_ feed: Feed) async {
        receiveTowerFeed(feed)
        await refresh()
    }
}
