import GRDB

package struct User: FetchableRecord, Decodable, Identifiable, Equatable {
    package let id: String
    package let name: String
    package let displayName: String
    package let realName: String
    package let email: String
    package let isBot: Bool
    package let isDeleted: Bool
    package let profileJSON: String
    package let updatedAt: String

    package enum CodingKeys: String, CodingKey {
        case id, name, email
        case displayName = "display_name"
        case realName = "real_name"
        case isBot = "is_bot"
        case isDeleted = "is_deleted"
        case profileJSON = "profile_json"
        case updatedAt = "updated_at"
    }

    package var bestName: String {
        if !displayName.isEmpty { return displayName }
        if !realName.isEmpty { return realName }
        if !name.isEmpty { return name }
        return id
    }
}
