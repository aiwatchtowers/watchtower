import GRDB

package struct SyncState: FetchableRecord, Decodable, Identifiable, Equatable {
    package let channelID: String
    package let lastSyncedTS: String
    package let oldestSyncedTS: String
    package let isInitialSyncComplete: Bool
    package let cursor: String
    package let messagesSynced: Int
    package let lastSyncAt: String?
    package let error: String

    package var id: String { channelID }

    package enum CodingKeys: String, CodingKey {
        case cursor, error
        case channelID = "channel_id"
        case lastSyncedTS = "last_synced_ts"
        case oldestSyncedTS = "oldest_synced_ts"
        case isInitialSyncComplete = "is_initial_sync_complete"
        case messagesSynced = "messages_synced"
        case lastSyncAt = "last_sync_at"
    }
}
