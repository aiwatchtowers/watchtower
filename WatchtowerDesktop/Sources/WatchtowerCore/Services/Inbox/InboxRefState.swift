import Foundation
import GRDB

/// A list row's record in an artifact (sub-project A's row `ref`): Core's
/// mirror of the Kit's `ArtifactRef`, so Core stays Kit-free; the app maps
/// between the two.
package struct InboxRef: Hashable, Sendable {
    /// The Kit's `ArtifactRefKind`, with the same raw values.
    package enum Kind: String, CaseIterable, Sendable {
        case inboxItem = "inbox_item"
        case track, idea, reminder, action
    }

    package let kind: Kind
    package let id: Int64

    package init(kind: Kind, id: Int64) {
        self.kind = kind
        self.id = id
    }

    /// Every list row's ref of a stored `blocks_json`, in document order: the
    /// Kit's `ArtifactDocument.refs` for a document it reads. A document the
    /// Kit could not read as v1 (not JSON, another version, no `blocks`
    /// array, or a row whose `ref` is malformed) has none, so it counts as a
    /// plain artifact. The Kit is stricter about the other blocks' fields;
    /// those never carry a ref.
    package static func refs(blocksJSON: String) -> [Self] {
        guard !blocksJSON.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: Data(blocksJSON.utf8))) as? [String: Any],
              integer(object["v"]) == 1,
              let blocks = object["blocks"] as? [Any] else { return [] }
        var out: [Self] = []
        for case let block as [String: Any] in blocks where block["type"] as? String == "list" {
            guard let rows = block["rows"] as? [Any] else { return [] }
            for row in rows {
                guard let row = row as? [String: Any] else { return [] }
                guard let value = row["ref"], !(value is NSNull) else { continue }
                guard let ref = value as? [String: Any],
                      let kind = (ref["kind"] as? String).flatMap(Kind.init(rawValue:)),
                      let id = integer(ref["id"]), id > 0 else { return [] }
                out.append(Self(kind: kind, id: id))
            }
        }
        return out
    }

    /// A JSON integer (never a bool or a fraction), as the Kit reads one.
    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number == NSNumber(value: number.int64Value) else { return nil }
        return number.int64Value
    }
}

/// The render-time check of row refs (spec "What 'open' means for a `ref`"):
/// a row is drawn only while its record is **shown** and counted only while
/// it **waits** on the owner, both read from the record in the same read as
/// the folder. A deleted record is neither.
package struct InboxRefState: Equatable, Sendable {
    package let shown: Set<InboxRef>
    package let waiting: Set<InboxRef>

    package init(shown: Set<InboxRef> = [], waiting: Set<InboxRef> = []) {
        self.shown = shown
        self.waiting = waiting
    }

    package func isShown(_ ref: InboxRef) -> Bool { shown.contains(ref) }
    package func waits(_ ref: InboxRef) -> Bool { waiting.contains(ref) }

    /// One query per kind present in `refs`, over its ids. `nowUTC` is an
    /// RFC 3339 UTC string; `timeZone` reads an idea's date-only snooze (the
    /// owner's local day, as Not now writes it). A kind whose table is
    /// missing (an older database) shows nothing; any other error throws.
    package static func read(
        _ db: Database, refs: [InboxRef], nowUTC: String, timeZone: TimeZone = .current
    ) throws -> Self {
        let ids = Dictionary(grouping: refs, by: \.kind).mapValues { Array(Set($0.map(\.id))).sorted() }
        var shown: Set<InboxRef> = []
        var waiting: Set<InboxRef> = []
        for (kind, kindIDs) in ids {
            let open = try openIDs(db, kind: kind, ids: kindIDs, nowUTC: nowUTC, timeZone: timeZone)
            shown.formUnion(open.shown.map { InboxRef(kind: kind, id: $0) })
            waiting.formUnion(open.waiting.map { InboxRef(kind: kind, id: $0) })
        }
        return Self(shown: shown, waiting: waiting)
    }

    private static func openIDs(
        _ db: Database, kind: InboxRef.Kind, ids: [Int64], nowUTC: String, timeZone: TimeZone
    ) throws -> (shown: Set<Int64>, waiting: Set<Int64>) {
        let marks = databaseQuestionMarks(count: ids.count)
        let idArguments = StatementArguments(ids)
        do {
            switch kind {
            case .inboxItem:
                // Shown = waits: `HomeFeedQueries.openMessageClause` (its one `?` is now).
                let open = try Int64.fetchSet(db, sql: """
                    SELECT id FROM inbox_items WHERE id IN (\(marks)) AND \(HomeFeedQueries.openMessageClause)
                    """, arguments: idArguments + [nowUTC])
                return (open, open)
            case .track:
                // Done is TRACKS-04's read; Stop watching is the dismissal.
                let open = try Int64.fetchSet(db, sql: """
                    SELECT id FROM tracks WHERE id IN (\(marks)) AND dismissed_at = '' AND read_at IS NULL
                    """, arguments: idArguments)
                return (open, open)
            case .reminder:
                // `ReminderQueries.fetchDue`'s predicate (REMIND-01).
                let open = try Int64.fetchSet(db, sql: """
                    SELECT id FROM reminders WHERE id IN (\(marks)) AND status = 'pending' AND remind_at <= ?
                    """, arguments: idArguments + [nowUTC])
                return (open, open)
            case .action:
                let open = try Int64.fetchSet(db, sql: """
                    SELECT id FROM agent_actions WHERE id IN (\(marks)) AND \(AgentActionQueries.awaitingOwnerClause)
                    """, arguments: idArguments)
                return (open, open)
            case .idea:
                let ideas = try Idea.fetchAll(db, sql: "SELECT * FROM ideas WHERE id IN (\(marks))", arguments: idArguments)
                let now = AutomationDates.parse(nowUTC) ?? Date()
                let shown = ideas.filter { ideaShown($0, now: now, timeZone: timeZone) }
                return (Set(shown.map { Int64($0.id) }), Set(shown.filter(\.awaitsVerdict).map { Int64($0.id) }))
            }
        } catch let error as DatabaseError where ActionStripViewModel.isMissingTable(error) {
            return ([], [])
        }
    }

    /// Shown while not merged or superseded and not snoozed past now.
    package static func ideaShown(_ idea: Idea, now: Date, timeZone: TimeZone) -> Bool {
        guard idea.status != .merged, idea.status != .superseded else { return false }
        return !ideaSnoozed(idea.snoozeUntil, now: now, timeZone: timeZone)
    }

    /// `snooze_until` is "" (none), an owner-local `yyyy-MM-dd` (snoozed
    /// until that day starts) or a legacy ISO datetime; anything else reads
    /// as not snoozed, so the idea is never lost.
    private static func ideaSnoozed(_ value: String, now: Date, timeZone: TimeZone) -> Bool {
        if value.isEmpty { return false }
        if value.count == 10 {
            let day = DateFormatter()
            day.calendar = Calendar(identifier: .gregorian)
            day.locale = Locale(identifier: "en_US_POSIX")
            day.timeZone = timeZone
            day.dateFormat = "yyyy-MM-dd"
            guard day.date(from: value) != nil else { return false }
            return value > day.string(from: now)
        }
        guard let until = AutomationDates.parse(value) else { return false }
        return until > now
    }
}
