import GRDB

package struct Channel: FetchableRecord, Decodable, Identifiable, Equatable {
    package let id: String
    package let name: String
    package let type: String
    package let topic: String
    package let purpose: String
    package let isArchived: Bool
    package let isMember: Bool
    package let dmUserID: String?
    package let numMembers: Int
    package let updatedAt: String

    package enum CodingKeys: String, CodingKey {
        case id, name, type, topic, purpose
        case isArchived = "is_archived"
        case isMember = "is_member"
        case dmUserID = "dm_user_id"
        case numMembers = "num_members"
        case updatedAt = "updated_at"
    }
}
