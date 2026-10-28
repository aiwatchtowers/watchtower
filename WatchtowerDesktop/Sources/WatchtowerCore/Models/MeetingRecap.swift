import Foundation
import GRDB

package struct MeetingRecap: Codable, FetchableRecord, PersistableRecord {
    package static let databaseTableName = "meeting_recaps"

    // Nullable since migration 00056: a recap outlives its event (event_id →
    // NULL on deletion, the durable link is transcript_id).
    package let eventID: String?
    package let sourceText: String
    package let recapJSON: String
    package let createdAt: String
    package let updatedAt: String

    package struct Content: Decodable, Equatable {
        package let summary: String
        package let keyDecisions: [String]
        package let actionItems: [String]
        package let openQuestions: [String]

        package init(summary: String, keyDecisions: [String], actionItems: [String], openQuestions: [String]) {
            self.summary = summary
            self.keyDecisions = keyDecisions
            self.actionItems = actionItems
            self.openQuestions = openQuestions
        }

        enum CodingKeys: String, CodingKey {
            case summary
            case keyDecisions = "key_decisions"
            case actionItems = "action_items"
            case openQuestions = "open_questions"
        }
    }

    package var parsed: Content? {
        guard let data = recapJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Content.self, from: data)
    }

    package enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case sourceText = "source_text"
        case recapJSON = "recap_json"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// The `meeting_recaps` row a recording's Recap tab renders
/// (`MeetingRecapQueries.fetchForRecording`), plus whose recap it is.
package struct RecordingRecap {
    package let recap: MeetingRecap
    /// True when the row is linked to the recording by `transcript_id` — this
    /// recording's own recap (written by Go's save/retry, or copied from its
    /// `summary_json` by `linkToEvent`), which `transcript recap <id>`
    /// refreshes in place. False = the event's recap from another source (a
    /// pasted recap, another recording's), which Go's collision guard never
    /// overwrites.
    package let ownedByRecording: Bool

    package init(recap: MeetingRecap, ownedByRecording: Bool) {
        self.recap = recap
        self.ownedByRecording = ownedByRecording
    }
}

/// What the calendar event page offers on the event's recap. A recap a
/// private recording owns (MEETPRIV-01/02) still shows there — it is the
/// owner's own, local view — but nothing on it goes to AI: no Re-generate,
/// no `source_text` (the private transcript) prefilled into the recap
/// sheet, no "+ to notes" (a note becomes a Target, which feeds prompts).
package struct EventRecapGate: Equatable {
    package let ownedByPrivateRecording: Bool

    package init(ownedByPrivateRecording: Bool) {
        self.ownedByPrivateRecording = ownedByPrivateRecording
    }

    package static func load(_ db: Database, eventID: String) throws -> Self {
        Self(ownedByPrivateRecording: try MeetingRecapQueries.isOwnedByPrivateRecording(db, eventID: eventID))
    }

    /// The gate as stored now, for a check at action time (the recording may
    /// have turned private since the page loaded). A failed read (logged)
    /// closes it: no AI action on a recap whose owner could not be checked.
    package static func current(_ reader: some DatabaseReader, eventID: String) async -> Self {
        do {
            return try await reader.read { try load($0, eventID: eventID) }
        } catch {
            NSLog("EventRecapGate: checking event %@'s recap owner failed: %@", eventID, String(describing: error))
            return Self(ownedByPrivateRecording: true)
        }
    }

    /// Re-generate, "Recap from text" and "+ to notes".
    package var offersAIActions: Bool { !ownedByPrivateRecording }

    /// The text the recap sheet opens with.
    package func prefilledText(_ recap: MeetingRecap?) -> String {
        offersAIActions ? recap?.sourceText ?? "" : ""
    }
}
