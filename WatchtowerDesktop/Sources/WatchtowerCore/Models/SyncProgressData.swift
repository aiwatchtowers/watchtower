import Foundation

package struct SyncProgressData: Decodable {
    package let phase: String
    package let elapsedSec: Double
    package let usersTotal: Int
    package let usersDone: Int
    package let channelsTotal: Int
    package let channelsDone: Int
    package let discoveryPages: Int
    package let discoveryTotalPages: Int
    package let discoveryChannels: Int
    package let discoveryUsers: Int
    package let userProfilesTotal: Int
    package let userProfilesDone: Int
    package let msgChannelsTotal: Int
    package let msgChannelsDone: Int
    package let messagesFetched: Int
    package let threadsTotal: Int?
    package let threadsDone: Int?
    package let threadsFetched: Int?
    package let error: String?

    package enum CodingKeys: String, CodingKey {
        case phase
        case elapsedSec = "elapsed_sec"
        case usersTotal = "users_total"
        case usersDone = "users_done"
        case channelsTotal = "channels_total"
        case channelsDone = "channels_done"
        case discoveryPages = "discovery_pages"
        case discoveryTotalPages = "discovery_total_pages"
        case discoveryChannels = "discovery_channels"
        case discoveryUsers = "discovery_users"
        case userProfilesTotal = "user_profiles_total"
        case userProfilesDone = "user_profiles_done"
        case msgChannelsTotal = "msg_channels_total"
        case msgChannelsDone = "msg_channels_done"
        case messagesFetched = "messages_fetched"
        case threadsTotal = "threads_total"
        case threadsDone = "threads_done"
        case threadsFetched = "threads_fetched"
        case error
    }
}
