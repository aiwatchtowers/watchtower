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
    /// until the next read has it. `selectedDay` (an open Morning brief
    /// day) stays listed while it is open, as the Mac keeps it today.
    package static func listed(
        folder: Int64, feed: Feed, records: InboxFeedSnapshot, selectedDay: String? = nil, now: Date = Date()
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
        if let selectedDay, folder == feed.folders.first(where: { $0.kind == .root })?.id,
           !out.contains(where: { $0.entry.id == "day:\(selectedDay)" }),
           let day = records.days.first(where: { $0.date == selectedDay }) {
            let dayRow = InboxFolderListRow(
                id: "day:\(day.date)", kind: .legacy, title: "Morning brief", detail: daySource(day.date))
            let index = out.firstIndex { listedStamp($0.entry, records: records).map { $0 < day.stamp } ?? false }
            out.insert(Listed(entry: .legacyDay(day), row: dayRow), at: index ?? out.endIndex)
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
            InboxSection(title: "Needs your decision", items: decisions),
            InboxSection(title: "Today", items: today),
            InboxSection(title: "Earlier", items: earlier)
        ].filter { !$0.items.isEmpty }
        if list == .tracks, !stopped.isEmpty {
            sections.append(InboxSection(
                title: InboxSection.stoppedTitle(stopped.count), items: showsStopped ? stopped : [], foldable: true))
        }
        return sections
    }

    /// The folder menu's read with Go's numbers in place of the Swift
    /// ones: each folder's count, each folder's artifacts in the feed's
    /// order, each card's ref rows and which of them are shown and waiting
    /// (`ref_facts`). The tree (the owner's arrangement) and the records
    /// stay the read's.
    package static func folders(_ read: InboxFolderMenuSnapshot, feed: Feed) -> InboxFolderMenuSnapshot {
        let records = Dictionary(
            (read.cards.values.flatMap { $0 } + read.approvalArtifacts.values).map { ($0.id, $0) }
        ) { first, _ in first }
        let approvalsFolder = feed.folders.first { $0.kind == .approvals }?.id
        var cards: [Int64: [AutomationOutputCard]] = [:]
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
            guard card.folderID != approvalsFolder, let record = records[id] else { continue }
            cards[card.folderID, default: []].append(record)
            artifacts[card.folderID, default: 0] += 1
        }
        let counts = Dictionary(feed.folders.map { ($0.id, $0.count) }) { first, _ in first }
        return InboxFolderMenuSnapshot(
            tree: read.tree, counts: counts, artifacts: artifacts, cards: cards, refs: refs,
            refState: InboxRefState(shown: shown, waiting: waiting), waitingForMe: read.waitingForMe,
            needsApproval: read.needsApproval, approvalArtifacts: read.approvalArtifacts,
            openActions: read.openActions, ideaFinderPresent: read.ideaFinderPresent)
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

    /// The time the root orders an entry by, for the open day kept listed.
    private static func listedStamp(_ entry: InboxFolderEntry, records: InboxFeedSnapshot) -> Date? {
        switch entry {
        case let .artifact(card): card.changedAt
        case let .legacyDay(day): day.stamp
        case let .brief(action): AutomationDates.parse(action.appliedAt)
        case .legacyTracks: (records.tracks + records.stoppedTracks).map(\.lastEventAt).max()
        case .legacyIdeas: records.ideas.compactMap { AutomationDates.parse($0.updatedAt) }.max()
        case .legacyMessages: records.messages.map(\.stamp).max()
        case .approval, .builtinNotice: nil
        }
    }

    /// "Your day · Fri 6 Nov".
    private static func daySource(_ date: String) -> String {
        guard let day = dayParser.date(from: date) else { return "Your day · \(date)" }
        return "Your day · \(dayFormatter.string(from: day))"
    }

    private static func parse(_ stamp: String) -> Date? {
        stamp.isEmpty ? nil : AutomationDates.parse(stamp)
    }

    nonisolated(unsafe) private static let dayParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    nonisolated(unsafe) private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE d MMM"
        return formatter
    }()
}
