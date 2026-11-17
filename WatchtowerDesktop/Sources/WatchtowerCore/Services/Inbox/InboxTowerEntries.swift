import Foundation
import os
import WatchtowerInterface

/// The Inbox's lists over the tower's feed (mobile Inbox spec §5.1, Task 11
/// ruling 1): Go decides which cards a folder lists, in what order, what it
/// counts and what each row says; the Mac only matches each card to the
/// record its pane draws, read by id from the last GRDB read (`records`).
/// Nothing here decides whether something is open or waiting.
package enum InboxTowerEntries {
    /// One listed entry and its row.
    package struct Listed: Equatable, Sendable {
        package let entry: InboxFolderEntry
        package let row: InboxFolderListRow
    }

    private static let log = Logger(subsystem: "watchtower.desktop", category: "inbox-feed")

    /// `folder`'s entries in the feed's order with the Mac's row texts. A
    /// card whose record the last GRDB read does not hold yet is left out
    /// until the next read has it.
    package static func listed(
        folder: Int64, feed: Feed, records: InboxFeedSnapshot, now: Date = Date()
    ) -> [Listed] {
        let approvals = feed.folders.first { $0.id == folder }?.kind == .approvals
        let cards = feed.cards.filter { $0.folderID == folder }
        let byID = Dictionary(cards.map { ($0.id, $0) }) { first, _ in first }
        var out: [Listed] = []
        for row in InboxMacFolderRows.rows(cards, approvals: approvals, now: now) {
            guard let card = byID[row.cardID], let entry = entry(for: row, card: card, records: records) else {
                log.debug("inbox feed card \(row.cardID, privacy: .public) has no record yet")
                continue
            }
            out.append(Listed(entry: entry, row: listRow(row, entry: entry)))
        }
        return out
    }

    /// A legacy entry's list (Track my threads, Idea finder, Messages): its
    /// items in the feed's order, grouped as the Mac groups them — ideas
    /// awaiting a verdict under Needs your decision, the rest under Today and
    /// Earlier by the client's day, and the Stopped fold of stopped tracks.
    package static func sections(
        _ list: InboxLegacyList,
        feed: Feed,
        records: InboxFeedSnapshot,
        now: Date,
        calendar: Calendar,
        showsStopped: Bool
    ) -> [InboxSection] {
        let cardID = switch list {
        case .tracks: "tracks"
        case .ideas: "ideas"
        case .messages: "messages"
        }
        let items = feed.cards.first { $0.id == cardID }?.legacy?.items ?? []
        let startOfToday = calendar.startOfDay(for: now)
        var decisions: [InboxListItem] = []
        var today: [InboxListItem] = []
        var earlier: [InboxListItem] = []
        var stopped: [InboxListItem] = []
        for item in items {
            guard let listItem = record(item, list: list, records: records) else { continue }
            if item.stopped {
                stopped.append(listItem)
            } else if list == .ideas, item.unread {
                decisions.append(listItem)
            } else if (parse(item.stamp) ?? .distantPast) >= startOfToday {
                today.append(listItem)
            } else {
                earlier.append(listItem)
            }
        }
        var sections = [
            InboxSection(title: TowerText.needsYourDecision, items: decisions),
            InboxSection(title: TowerText.today, items: today),
            InboxSection(title: TowerText.earlier, items: earlier)
        ].filter { !$0.items.isEmpty }
        if list == .tracks, !stopped.isEmpty {
            sections.append(InboxSection(
                title: InboxSection.stoppedTitle(stopped.count), items: showsStopped ? stopped : [], foldable: true))
        }
        return sections
    }

    /// The folder menu's read with Go's numbers laid over it: each folder's
    /// count and artifact count, each card's ref rows and which of them are
    /// shown and waiting (`ref_facts`). The tree (the owner's arrangement)
    /// and the built-ins' states stay the read's.
    /// The menu's folders as Go lists them (`Feed.folders`, in pre-order):
    /// which folders show, their order and which are hidden come from the
    /// feed, never from the local read. A folder is drawn hidden only where
    /// its own flag hid it (Go sends the effective value, an ancestor's
    /// included). The local read keeps what the feed does not carry: the
    /// revision every CLI edit sends back and the routes.
    package static func tree(_ local: InboxFolderTree, feed: Feed) -> InboxFolderTree {
        guard !feed.folders.isEmpty else { return local }
        let hidden = Dictionary(feed.folders.map { ($0.id, $0.hidden) }) { first, _ in first }
        let folders = feed.folders.map { folder in
            InboxFolder(
                id: folder.id, kind: InboxFolder.Kind(rawValue: folder.kind.rawValue) ?? .owner,
                parentID: folder.parentID, slug: folder.slug, title: folder.title, icon: folder.icon,
                position: folder.position,
                hidden: folder.hidden && !(folder.parentID.flatMap { hidden[$0] } ?? false))
        }
        return InboxFolderTree(revision: local.revision, folders: folders, routes: local.routes)
    }

    package static func folders(_ read: InboxFolderMenuSnapshot, feed: Feed) -> InboxFolderMenuSnapshot {
        let approvalsFolder = feed.folders.first { $0.kind == .approvals }?.id
        var artifacts: [Int64: Int] = [:]
        var refs: [Int64: [InboxRef]] = [:]
        var shown: Set<InboxRef> = []
        var waiting: Set<InboxRef> = []
        for card in feed.cards {
            for fact in card.refFacts {
                guard let kind = InboxRef.Kind(rawValue: fact.kind.rawValue) else { continue }
                let ref = InboxRef(kind: kind, id: fact.id)
                if fact.open { shown.insert(ref) }
                if fact.open && fact.waits { waiting.insert(ref) }
            }
            guard card.id.first == "o", let id = Int64(card.id.dropFirst()) else { continue }
            refs[id] = card.refFacts.compactMap { fact in
                InboxRef.Kind(rawValue: fact.kind.rawValue).map { InboxRef(kind: $0, id: fact.id) }
            }
            if card.folderID != approvalsFolder { artifacts[card.folderID, default: 0] += 1 }
        }
        let counts = Dictionary(feed.folders.map { ($0.id, $0.count) }) { first, _ in first }
        return InboxFolderMenuSnapshot(
            tree: tree(read.tree, feed: feed), counts: counts, artifacts: artifacts, refs: refs,
            refState: InboxRefState(shown: shown, waiting: waiting), waitingForMe: read.waitingForMe,
            needsApproval: read.needsApproval, ideaFinderPresent: read.ideaFinderPresent)
    }

    // MARK: - Matching a card to its record

    private static func entry(for row: InboxMacFolderRow, card: Card, records: InboxFeedSnapshot) -> InboxFolderEntry? {
        if let briefID = row.briefID {
            return records.briefs.first { $0.id == briefID }.map(InboxFolderEntry.brief)
        }
        switch row.kind {
        case .approval: return approval(card, records: records)
        case .artifact: return output(card.id, records: records).map(InboxFolderEntry.artifact)
        case .legacy, .result: return legacy(card, records: records)
        }
    }

    private static func legacy(_ card: Card, records: InboxFeedSnapshot) -> InboxFolderEntry? {
        switch card.legacy?.kind {
        case .morningBrief?:
            let date = String(card.id.dropFirst("brief-".count))
            if let day = records.days.first(where: { $0.date == date }) { return .legacyDay(day) }
            // Today before its briefing and its plan exist.
            return .legacyDay(.placeholder(date: date, stamp: parse(card.stamp) ?? Date()))
        case .tracks?: return .legacyTracks
        case .ideas?: return .legacyIdeas
        case .messages?: return .legacyMessages
        case .threadBriefs?, .unknown?, nil: return nil
        }
    }

    private static func approval(_ card: Card, records: InboxFeedSnapshot) -> InboxFolderEntry? {
        guard let number = Int64(card.id.dropFirst()) else { return nil }
        switch card.id.first {
        case "a": return records.proposals.first { $0.id == number }.map { .approval(NeedsApprovalItem(.action($0))) }
        case "r": return records.reminders.first { $0.id == number }.map { .approval(NeedsApprovalItem(.reminder($0))) }
        case "n": return records.builtinNotices.first { $0.rowID == number }.map(InboxFolderEntry.builtinNotice)
        case "o":
            // The recipe's card for an approval: its one action or reminder ref.
            guard let recipe = records.outputs.first(where: { $0.id == number }),
                  let ref = card.refFacts.first(where: { $0.kind == .action || $0.kind == .reminder }) else { return nil }
            let record: NeedsApprovalItem.Record? = ref.kind == .action
                ? records.proposals.first { $0.id == ref.id }.map(NeedsApprovalItem.Record.action)
                : records.reminders.first { $0.id == ref.id }.map(NeedsApprovalItem.Record.reminder)
            return record.map { .approval(NeedsApprovalItem($0, recipe: recipe)) }
        default: return nil
        }
    }

    private static func output(_ cardID: String, records: InboxFeedSnapshot) -> AutomationOutputCard? {
        guard cardID.first == "o", let id = Int64(cardID.dropFirst()) else { return nil }
        return records.outputs.first { $0.id == id }
    }

    private static func record(_ item: LegacyItem, list: InboxLegacyList, records: InboxFeedSnapshot) -> InboxListItem? {
        switch list {
        case .tracks:
            (records.tracks + records.stoppedTracks).first { Int64($0.track.id) == item.id }.map(InboxListItem.track)
        case .ideas:
            records.ideas.first { Int64($0.id) == item.id }.map(InboxListItem.idea)
        case .messages:
            records.messages.first { Int64($0.item.id) == item.id }.map(InboxListItem.message)
        }
    }

    // MARK: - Rows

    private static func listRow(_ row: InboxMacFolderRow, entry: InboxFolderEntry) -> InboxFolderListRow {
        let kind: InboxFolderListRow.Kind = switch row.kind {
        case .artifact: .artifact
        case .legacy: .legacy
        case .approval: .approval
        case .result: .result
        }
        return InboxFolderListRow(
            id: entry.id, kind: kind, title: row.title, summary: row.summary, detail: row.detail,
            unread: row.unread, menu: entry.menuEntries)
    }

    private static func parse(_ stamp: String) -> Date? {
        stamp.isEmpty ? nil : AutomationDates.parse(stamp)
    }
}
