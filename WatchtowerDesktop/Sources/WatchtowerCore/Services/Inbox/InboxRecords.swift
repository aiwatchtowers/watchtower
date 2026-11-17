import Foundation
import GRDB
import os
import WatchtowerInterface

/// The records the Inbox's panes draw, read by plain id from the cards the
/// tower's feed lists (mobile Inbox spec §5.1, Task 11 ruling 1). Nothing
/// here decides what is open, due or waiting: the feed did; this read only
/// fetches the rows it named. One read, nothing written (STRIP-02).
package enum InboxRecords {
    /// What the feed names, by kind.
    package struct IDs: Equatable, Sendable {
        package var outputs: Set<Int64> = []
        package var actions: Set<Int64> = []
        package var reminders: Set<Int64> = []
        package var notices: Set<Int64> = []
        package var dates: Set<String> = []
        package var tracks: Set<Int64> = []
        package var ideas: Set<Int64> = []
        package var messages: Set<Int64> = []
        /// The thread briefs (actions shown as results).
        package var briefs: Set<Int64> = []

        package init() {}

        /// Every record `feed` names: each card's own row, its ref rows'
        /// approvals and reminders, and its legacy list's items.
        package init(feed: Feed) {
            for card in feed.cards {
                insertOwn(card.id)
                for fact in card.refFacts { insertRef(fact) }
                if let legacy = card.legacy { insertItems(legacy) }
            }
        }

        private mutating func insertOwn(_ cardID: String) {
            if cardID.hasPrefix("brief-") { dates.insert(String(cardID.dropFirst("brief-".count))) }
            guard let number = Int64(cardID.dropFirst()) else { return }
            switch cardID.first {
            case "o": outputs.insert(number)
            case "a": actions.insert(number)
            case "r": reminders.insert(number)
            case "n": notices.insert(number)
            default: break
            }
        }

        private mutating func insertRef(_ fact: RefFacts) {
            switch fact.kind {
            case .action: actions.insert(fact.id)
            case .reminder: reminders.insert(fact.id)
            case .inboxItem: messages.insert(fact.id)
            case .track: tracks.insert(fact.id)
            case .idea: ideas.insert(fact.id)
            case .planItem, .unknown: break
            }
        }

        private mutating func insertItems(_ legacy: LegacySection) {
            let ids = legacy.items.map(\.id)
            switch legacy.kind {
            case .tracks: tracks.formUnion(ids)
            case .ideas: ideas.formUnion(ids)
            case .messages: messages.formUnion(ids)
            case .threadBriefs: briefs.formUnion(ids)
            case .morningBrief, .unknown: break
            }
        }
    }

    /// The rows `ids` names, in a snapshot the panes already read from.
    /// Each source tolerates a schema that predates it.
    private static let log = Logger(subsystem: "watchtower.desktop", category: "inbox-records")

    package static func read(
        _ db: Database, ids: IDs, disabledFeatures: Set<String> = [], now: Date
    ) throws -> InboxFeedSnapshot {
        var out = InboxFeedSnapshot()
        out.briefingOn = ReadinessFeature.briefing.featureID.map(disabledFeatures.contains) != true
        out.dayPlanOn = ReadinessFeature.dayPlan.featureID.map(disabledFeatures.contains) != true
        let actions = try orEmpty { try fetch(AgentAction.self, db, "agent_actions", ids.actions.union(ids.briefs)) }
        out.proposals = actions.filter { !ids.briefs.contains($0.id) || ids.actions.contains($0.id) }
        out.briefs = actions.filter { ids.briefs.contains($0.id) }
        out.reminders = try orEmpty { try fetch(Reminder.self, db, "reminders", ids.reminders) }
        out.outputs = try orEmpty { try AutomationQueries.fetchInboxOutputs(db, ids: ids.outputs.sorted()) }
        if !out.outputs.isEmpty {
            // Names for avatars only: a failure must not take every card with
            // it, so it is logged and the cards draw the recipe's initials.
            do {
                out.artifactPeople = try AutomationQueries.artifactPeople(db)
            } catch {
                log.error("inbox records: reading the artifacts' people failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        out.days = try orEmpty { try BriefingQueries.fetchDayCards(db, dates: ids.dates.sorted(by: >)) }
        out.ownerKnown = try OwnerQueries.resolve(db).isKnown
        let tracks = try orEmpty { try TrackQueries.fetchInboxCards(db, ids: ids.tracks.sorted()) }
        out.tracks = tracks.filter { $0.track.dismissedAt.isEmpty }
        out.stoppedTracks = tracks.filter { !$0.track.dismissedAt.isEmpty }
        out.ideas = try orEmpty { try fetch(Idea.self, db, "ideas", ids.ideas) }
        out.messages = try orEmpty { try HomeFeedQueries.messageRows(db, ids: ids.messages.sorted(), now: now) }
        out.builtinNotices = try BuiltinUpgradeNotice.load(db).filter { ids.notices.contains($0.rowID) }
        return out
    }

    private static func fetch<Record: FetchableRecord>(
        _: Record.Type, _ db: Database, _ table: String, _ ids: Set<Int64>
    ) throws -> [Record] {
        guard !ids.isEmpty else { return [] }
        let list = ids.sorted().map(String.init).joined(separator: ",")
        return try Record.fetchAll(db, sql: "SELECT * FROM \(table) WHERE id IN (\(list)) ORDER BY id")
    }

    private static func orEmpty<T>(_ read: () throws -> [T]) throws -> [T] {
        do {
            return try read()
        } catch let error as DatabaseError where error.resultCode == .SQLITE_ERROR
            && (error.message ?? "").contains("no such table") {
            return []
        }
    }
}
