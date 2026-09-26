import GRDB
import Foundation

/// A self-contained thematic unit within a digest.
/// Each topic carries its own decisions, action items, situations, and key messages.
package struct DigestTopic: FetchableRecord, Decodable, Identifiable, Equatable {
    package let id: Int
    package let digestID: Int
    package let idx: Int
    package let title: String
    package let summary: String
    package let decisions: String
    package let actionItems: String
    package let situations: String
    package let keyMessages: String

    package enum CodingKeys: String, CodingKey {
        case id, idx, title, summary, decisions, situations
        case digestID = "digest_id"
        case actionItems = "action_items"
        case keyMessages = "key_messages"
    }

    private static let decoder = JSONDecoder()

    package var parsedDecisions: [Decision] {
        guard let data = decisions.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([Decision].self, from: data)) ?? []
    }

    package var parsedActionItems: [DigestTrack] {
        guard let data = actionItems.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([DigestTrack].self, from: data)) ?? []
    }

    package var parsedKeyMessages: [String] {
        guard let data = keyMessages.data(using: .utf8) else { return [] }
        return (try? Self.decoder.decode([String].self, from: data)) ?? []
    }
}
