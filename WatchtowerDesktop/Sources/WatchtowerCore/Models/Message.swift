import GRDB

package struct Message: FetchableRecord, Decodable, Identifiable, Equatable {
    package let channelID: String
    package let ts: String
    package let userID: String
    package let text: String
    package let threadTS: String?
    package let replyCount: Int
    package let isEdited: Bool
    package let isDeleted: Bool
    package let subtype: String
    package let permalink: String
    package let tsUnix: Double
    package let rawJSON: String

    package var id: String { "\(channelID)_\(ts)" }

    package enum CodingKeys: String, CodingKey {
        case ts, text, subtype, permalink
        case channelID = "channel_id"
        case userID = "user_id"
        case threadTS = "thread_ts"
        case replyCount = "reply_count"
        case isEdited = "is_edited"
        case isDeleted = "is_deleted"
        case tsUnix = "ts_unix"
        case rawJSON = "raw_json"
    }
}
