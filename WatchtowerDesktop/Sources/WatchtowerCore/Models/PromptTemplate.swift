import GRDB
import Foundation

package struct PromptTemplate: FetchableRecord, Decodable, Identifiable, Equatable {
    package let id: String    // "digest.channel", "tracks.extract", etc.
    package let template: String
    package let version: Int
    package let language: String
    package let updatedAt: String

    package enum CodingKeys: String, CodingKey {
        case id, template, version, language
        case updatedAt = "updated_at"
    }
}

package struct PromptHistoryEntry: FetchableRecord, Decodable, Identifiable, Equatable {
    package let id: Int
    package let promptID: String
    package let version: Int
    package let template: String
    package let reason: String
    package let createdAt: String

    package enum CodingKeys: String, CodingKey {
        case id, version, template, reason
        case promptID = "prompt_id"
        case createdAt = "created_at"
    }
}
