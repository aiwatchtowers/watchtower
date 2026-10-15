import Foundation
import GRDB
import os
import WatchtowerCore
import WatchtowerSync

extension CalendarEventSlice {
    // MARK: - Prep and linked targets

    struct Prep {
        let bullets: [String]
        let generatedAt: String
    }

    private struct PrepResult: Decodable {
        struct TalkingPoint: Decodable { let text: String? }
        let talkingPoints: [TalkingPoint]?
        let suggestedPrep: [String]?

        enum CodingKeys: String, CodingKey {
            case talkingPoints = "talking_points"
            case suggestedPrep = "suggested_prep"
        }
    }

    /// event id → its `meeting_prep_cache` bullets. An empty `result_json`
    /// is no prep; an unreadable one is logged and left out.
    static func prep(_ db: Database, eventIDs: [String]) throws -> [String: Prep] {
        guard !eventIDs.isEmpty else { return [:] }
        var out: [String: Prep] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT event_id, result_json, generated_at FROM meeting_prep_cache
            WHERE result_json != '' AND event_id IN (\(placeholders(eventIDs.count)))
            """, arguments: StatementArguments(eventIDs)) {
            let eventID: String = row["event_id"]
            let json: String = row["result_json"]
            let result: PrepResult
            do {
                result = try JSONDecoder().decode(PrepResult.self, from: Data(json.utf8))
            } catch {
                warnOnce(.prep, id: eventID, event: eventID, content: json, error: error)
                continue
            }
            let bullets = (result.talkingPoints ?? []).compactMap(\.text) + (result.suggestedPrep ?? [])
            out[eventID] = Prep(
                bullets: bullets.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                generatedAt: row["generated_at"]
            )
        }
        return out
    }

    /// event id → the targets converted from its transcripts' chapter action
    /// items (`converted_target_id`), oldest transcript first. Not on a board
    /// only (`project_id IS NULL`, PROJ-01); a deleted target drops out.
    static func linkedTargets(_ db: Database, eventIDs: [String]) throws -> [String: [LinkedTarget]] {
        guard !eventIDs.isEmpty else { return [:] }
        var converted: [(event: String, target: Int64)] = []
        for row in try Row.fetchAll(db, sql: """
            SELECT id, event_id, chapters_json FROM meeting_transcripts
            WHERE chapters_json IS NOT NULL AND chapters_json != '' AND event_id IN (\(placeholders(eventIDs.count)))
            ORDER BY created_at, id
            """, arguments: StatementArguments(eventIDs)) {
            let json: String = row["chapters_json"]
            let chapters: MeetingChapters
            do {
                chapters = try JSONDecoder().decode(MeetingChapters.self, from: Data(json.utf8))
            } catch {
                warnOnce(.chapters, id: String(row["id"] as Int64), event: row["event_id"], content: json, error: error)
                continue
            }
            let event: String = row["event_id"]
            for item in chapters.chapters.flatMap(\.actionItems) {
                if let target = item.convertedTargetID { converted.append((event, target)) }
            }
        }
        let targetIDs = Array(Set(converted.map(\.target)))
        guard !targetIDs.isEmpty else { return [:] }
        var targets: [Int64: LinkedTarget] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT id, text, status FROM targets
            WHERE project_id IS NULL AND id IN (\(placeholders(targetIDs.count)))
            """, arguments: StatementArguments(targetIDs)) {
            let id: Int64 = row["id"]
            targets[id] = LinkedTarget(id: id, text: SliceClip.text(row["text"], limit: 200).text, status: row["status"])
        }
        var out: [String: [LinkedTarget]] = [:]
        for (event, id) in converted {
            if let target = targets[id] { out[event, default: []].append(target) }
        }
        return out
    }

    /// The lists in order, each target once.
    static func union(_ lists: [[LinkedTarget]]) -> [LinkedTarget] {
        var seen: Set<Int64> = []
        return lists.joined().filter { seen.insert($0.id).inserted }
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    // MARK: - Warnings

    enum Unreadable: String {
        case prep = "meeting prep"
        case attendees
        case chapters = "chapters_json"
    }

    /// Logs an unreadable source once per row and content: the 30 s tick
    /// re-reads it, and a changed value warns again. `event` is the
    /// calendar event the row belongs to.
    static func warnOnce(_ what: Unreadable, id: String, event: String, content: String, error: Error) {
        let key = warnKey(what, id: id, content: content)
        guard warned.withLock({ $0.updateValue(event, forKey: key) == nil }) else { return }
        logger.warning(
            "unreadable \(what.rawValue, privacy: .public) on \(id, privacy: .public) left out: \(String(describing: error), privacy: .public)"
        )
    }

    /// Whether `warnOnce` logged this row's content (the test seam).
    static func hasWarned(_ what: Unreadable, id: String, content: String) -> Bool {
        warned.withLock { $0[warnKey(what, id: id, content: content)] != nil }
    }

    /// Keeps the warn-once set bounded: only the warnings of events still
    /// in the window are remembered.
    static func forgetWarnings(keeping events: Set<String>) {
        warned.withLock { $0 = $0.filter { events.contains($0.value) } }
    }

    /// How many distinct warnings are remembered for `event`'s rows (the test seam).
    static func warningCount(event: String) -> Int {
        warned.withLock { $0.values.filter { $0 == event }.count }
    }

    private static func warnKey(_ what: Unreadable, id: String, content: String) -> String {
        "\(what.rawValue)\u{0}\(id)\u{0}\(content.hashValue)"
    }

    /// Warning key → the event its row belongs to.
    private static let warned = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    private static let logger = Logger(subsystem: Constants.bundleID, category: "CalendarEventSlice")
}
