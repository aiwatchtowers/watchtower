import GRDB

package struct ChannelSettings: Codable, FetchableRecord, PersistableRecord {
    package static let databaseTableName = "channel_settings"

    package let channelID: String
    package var isMutedForLLM: Bool
    package var isFavorite: Bool

    package init(channelID: String, isMutedForLLM: Bool, isFavorite: Bool) {
        self.channelID = channelID
        self.isMutedForLLM = isMutedForLLM
        self.isFavorite = isFavorite
    }

    package enum CodingKeys: String, CodingKey {
        case channelID = "channel_id"
        case isMutedForLLM = "is_muted_for_llm"
        case isFavorite = "is_favorite"
    }
}
