import Foundation
import GRDB
import os
import WatchtowerCore

extension MeetingTranscriptSlice {
    // MARK: - Recap

    /// A recap row without its content: the light pass reads no
    /// `recap_json`.
    struct RecapRef {
        let id: Int64
        let updatedAt: String
    }

    struct Recaps {
        /// Newest first.
        var byTranscript: [Int64: [RecapRef]] = [:]
        var byEvent: [String: [RecapRef]] = [:]

        /// A transcript's recaps in precedence order: its own (by
        /// `transcript_id`) first, then its event's; the first readable one
        /// wins (decoded in the build).
        func candidates(_ id: Int64, eventID: String?) -> [RecapRef] {
            (byTranscript[id] ?? []) + (eventID.flatMap { byEvent[$0] } ?? [])
        }
    }

    /// The non-empty `meeting_recaps` rows of the window's transcripts (id
    /// and `updated_at` only), by `transcript_id` and by `event_id` (the
    /// join `r.transcript_id = t.id OR (r.event_id IS NOT NULL AND
    /// r.event_id = t.event_id)`).
    static func recaps(_ db: Database, window: [(id: Int64, eventID: String?)]) throws -> Recaps {
        guard !window.isEmpty else { return Recaps() }
        let ids = window.map(\.id)
        let eventIDs = Array(Set(window.compactMap(\.eventID)))
        let eventClause = eventIDs.isEmpty ? "" : " OR event_id IN (\(placeholders(eventIDs.count)))"
        var out = Recaps()
        for row in try Row.fetchAll(db, sql: """
            SELECT id, event_id, transcript_id, updated_at FROM meeting_recaps
            WHERE (transcript_id IN (\(placeholders(ids.count)))\(eventClause))
              AND recap_json IS NOT NULL AND recap_json != ''
            ORDER BY updated_at DESC, id DESC
            """, arguments: StatementArguments(ids) + StatementArguments(eventIDs)) {
            let ref = RecapRef(id: row["id"], updatedAt: row["updated_at"])
            if let transcriptID: Int64 = row["transcript_id"] { out.byTranscript[transcriptID, default: []].append(ref) }
            if let eventID: String = row["event_id"] { out.byEvent[eventID, default: []].append(ref) }
        }
        return out
    }

    /// `recap_json` by recap id, for the rows the build decodes.
    static func recapJSON(_ db: Database, ids: Set<Int64>) throws -> [Int64: String] {
        guard !ids.isEmpty else { return [:] }
        var out: [Int64: String] = [:]
        for row in try Row.fetchAll(
            db, sql: "SELECT id, recap_json FROM meeting_recaps WHERE id IN (\(placeholders(ids.count)))",
            arguments: StatementArguments(Array(ids))
        ) {
            if let json: String = row["recap_json"] { out[row["id"]] = json }
        }
        return out
    }

    /// nil for a NULL or empty column; an unreadable one is logged once and
    /// left out.
    static func decodeRecap(_ json: String?, what: String) -> MeetingRecap.Content? {
        guard let json, !json.isEmpty else { return nil }
        guard let content = try? JSONDecoder().decode(MeetingRecap.Content.self, from: Data(json.utf8)) else {
            if warned.withLock({ $0.insert(what).inserted }) {
                logger.warning("unreadable \(what, privacy: .public) left out")
            }
            return nil
        }
        return content
    }

    static let warned = OSAllocatedUnfairLock<Set<String>>(initialState: [])
}
