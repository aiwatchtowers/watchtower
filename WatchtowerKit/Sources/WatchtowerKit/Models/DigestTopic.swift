import GRDB
import Foundation

/// A self-contained thematic unit within a digest.
/// Each topic carries its own decisions, action items, situations, and key messages.
public struct DigestTopic: FetchableRecord, Decodable, Identifiable, Equatable {
    public let id: Int
    public let digestID: Int
    public let idx: Int
    public let title: String
    public let summary: String
    public let decisions: String
    public let actionItems: String
    public let situations: String
    public let keyMessages: String

    public enum CodingKeys: String, CodingKey {
        case id, idx, title, summary, decisions, situations
        case digestID = "digest_id"
        case actionItems = "action_items"
        case keyMessages = "key_messages"
    }

    private static let decoder = JSONDecoder()

    public var parsedDecisions: [Decision] {
        guard let data = decisions.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([Decision].self, from: data)) ?? []
    }

    public var parsedActionItems: [DigestTrack] {
        guard let data = actionItems.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([DigestTrack].self, from: data)) ?? []
    }

    public var parsedKeyMessages: [String] {
        guard let data = keyMessages.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([String].self, from: data)) ?? []
    }
}
