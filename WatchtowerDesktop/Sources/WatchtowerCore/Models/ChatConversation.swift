import Foundation
import GRDB

package struct ChatConversation: FetchableRecord, Decodable, Identifiable, Equatable, Sendable {
    package let id: Int64
    package let title: String
    package let sessionID: String?
    package let contextType: String?
    package let contextID: String?
    package let createdAt: Double
    package let updatedAt: Double
    package let pinned: Bool
    package let archivedAt: Double?
    /// `prefix` (first 80 chars of the first message), `ai` (`chat title`) or `user` (renamed).
    package let titleSource: String
    package let provider: String?
    package let model: String?
    package let projectID: Int64?
    package let activeLeafMessageID: Int64?

    package enum CodingKeys: String, CodingKey {
        case id, title, pinned, provider, model
        case sessionID = "session_id"
        case contextType = "context_type"
        case contextID = "context_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case archivedAt = "archived_at"
        case titleSource = "title_source"
        case projectID = "project_id"
        case activeLeafMessageID = "active_leaf_message_id"
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        contextType = try c.decodeIfPresent(String.self, forKey: .contextType)
        contextID = try c.decodeIfPresent(String.self, forKey: .contextID)
        createdAt = try c.decode(Double.self, forKey: .createdAt)
        updatedAt = try c.decode(Double.self, forKey: .updatedAt)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        archivedAt = try c.decodeIfPresent(Double.self, forKey: .archivedAt)
        titleSource = try c.decodeIfPresent(String.self, forKey: .titleSource) ?? "prefix"
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        projectID = try c.decodeIfPresent(Int64.self, forKey: .projectID)
        activeLeafMessageID = try c.decodeIfPresent(Int64.self, forKey: .activeLeafMessageID)
    }

    package var createdDate: Date { Date(timeIntervalSince1970: createdAt) }
    package var updatedDate: Date { Date(timeIntervalSince1970: updatedAt) }
    package var displayTitle: String { title.isEmpty ? "New Chat" : title }
}
