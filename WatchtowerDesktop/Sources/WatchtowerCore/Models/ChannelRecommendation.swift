import Foundation

package struct ChannelRecommendation: Identifiable {
    package enum Action: String {
        case mute
        case leave
        case favorite
    }

    package var id: String { "\(action.rawValue)-\(channelID)" }
    package let channelID: String
    package let channelName: String
    package let action: Action
    package let reason: String

    package init(channelID: String, channelName: String, action: Action, reason: String) {
        self.channelID = channelID
        self.channelName = channelName
        self.action = action
        self.reason = reason
    }
}
