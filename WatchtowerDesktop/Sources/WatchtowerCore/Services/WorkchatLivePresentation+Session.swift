import Foundation
import WatchtowerChatText

/// The Mac-only half of `WorkchatLivePresentation` (shared with the phone in
/// `WatchtowerChatText`): the parts that read the Mac's session state and
/// feed entries.
extension WorkchatLivePresentation {
    /// Busy for the live line and the 👥 list: the turn works, background
    /// agents do, or the agent waits on an approval (a permission card pauses
    /// the turn, it does not end it). Not busy = idle: a missing snapshot then
    /// means no agents, and the live read stops.
    package static func busy(_ state: SessionSwitcherPresentation.State?) -> Bool {
        guard let state, state.live else { return false }
        return [.working, .background, .needsApproval].contains(state.kind)
    }

    /// The finished subagents among the feed's markers: `started_at` newest
    /// first; undated ones after them, ties and undated in the CLI's order.
    package static func done(from subagents: [SessionFeedEntry]) -> [SessionFeedSubagent] {
        done(from: subagents.compactMap(\.subagent))
    }
}
