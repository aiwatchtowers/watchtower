import Foundation
import GRDB

/// One item on a target's observer-produced activity timeline. Mirrors the Go
/// `observer_events` table. `proposedAction` decodes into the existing
/// `ProposedAction` so the chat executor can apply it.
struct ObserverEvent: Codable, FetchableRecord, Identifiable, Equatable {
    var id: Int
    var observerId: Int
    var entityType: String
    var entityId: Int
    var summary: String
    var detail: String
    var sourceType: String
    var sourceId: String
    var sourceRefs: String      // JSON array string
    var decision: String        // JSON object or ""
    var proposedAction: String  // JSON object or ""
    var actionStatus: String
    var readAt: String?
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case observerId = "observer_id"
        case entityType = "entity_type"
        case entityId = "entity_id"
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

    var isUnread: Bool { (readAt ?? "").isEmpty }

    /// Permalinks/links backing this event.
    var decodedRefs: [String] {
        guard let data = sourceRefs.data(using: .utf8),
              let refs = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return refs
    }

    /// The confirmable proposed action, if any, decoded into the shared type.
    var decodedAction: ProposedAction? {
        guard !proposedAction.isEmpty, let data = proposedAction.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ProposedAction.self, from: data)
    }

    /// The attached decision summary text, if any.
    var decodedDecisionText: String? {
        guard !decision.isEmpty, let data = decision.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String, !text.isEmpty else { return nil }
        return text
    }
}
