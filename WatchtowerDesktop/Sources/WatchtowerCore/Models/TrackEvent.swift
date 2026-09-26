import Foundation
import GRDB

/// One item on a custom track's scan-produced activity timeline. Mirrors the Go
/// `track_events` table. `proposedAction` decodes into the existing
/// `ProposedAction` so the chat executor can apply it to a linked target.
package struct TrackEvent: Codable, FetchableRecord, Identifiable, Equatable {
    package var id: Int
    package var trackId: Int
    package var summary: String
    package var detail: String
    package var sourceType: String
    package var sourceId: String
    package var sourceRefs: String      // JSON array string
    package var decision: String        // JSON object or ""
    package var proposedAction: String  // JSON object or ""
    package var actionStatus: String
    package var readAt: String?
    package var createdAt: String

    package enum CodingKeys: String, CodingKey {
        case id
        case trackId = "track_id"
        case summary, detail
        case sourceType = "source_type"
        case sourceId = "source_id"
        case sourceRefs = "source_refs"
        case decision
        case proposedAction = "proposed_action"
        case actionStatus = "action_status"
        case readAt = "read_at"
        case createdAt = "created_at"
    }

    package var isUnread: Bool { (readAt ?? "").isEmpty }

    /// Permalinks/links backing this event.
    package var decodedRefs: [String] {
        guard let data = sourceRefs.data(using: .utf8),
              let refs = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return refs
    }

    /// The confirmable proposed action, if any, decoded into the shared type.
    package var decodedAction: ProposedAction? {
        guard !proposedAction.isEmpty, let data = proposedAction.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ProposedAction.self, from: data)
    }

    /// The attached decision summary text, if any.
    package var decodedDecisionText: String? {
        guard !decision.isEmpty, let data = decision.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String, !text.isEmpty else { return nil }
        return text
    }
}
