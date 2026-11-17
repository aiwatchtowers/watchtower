import Foundation

/// One entry of a folder (spec "The Inbox screen" 2, "Moving today's Inbox
/// into folders"): an automation's artifact, a legacy entry over today's
/// panes (ask #445: a Morning brief per date, Track my threads, Idea finder,
/// and Messages while it stands in for Waiting for me), an open approval or
/// a built-in upgrade notice (Needs approval), or a thread brief the
/// `:brief:` reaction made (the root, 24 hours, ask #609).
package enum InboxFolderEntry: Identifiable, Equatable, Sendable {
    case artifact(AutomationOutputCard)
    case brief(AgentAction)
    case legacyDay(InboxDayCard)
    case legacyTracks
    case legacyIdeas
    case legacyMessages
    case approval(NeedsApprovalItem)
    case builtinNotice(BuiltinUpgradeNotice)

    package var id: String {
        switch self {
        case let .artifact(card): "artifact:\(card.id)"
        case let .brief(action): "brief:\(action.id)"
        case let .legacyDay(card): "day:\(card.date)"
        case .legacyTracks: "tracks"
        case .legacyIdeas: "ideas"
        case .legacyMessages: "messages"
        case let .approval(item): "approval:\(item.key)"
        case let .builtinNotice(notice): "notice:\(notice.builtinID)"
        }
    }

    /// A legacy entry whose pane is today's list (Track my threads, Idea
    /// finder, Messages): that list.
    package var legacyList: InboxLegacyList? {
        switch self {
        case .legacyTracks: .tracks
        case .legacyIdeas: .ideas
        case .legacyMessages: .messages
        case .artifact, .brief, .legacyDay, .approval, .builtinNotice: nil
        }
    }

    /// The legacy entry whose list is `list`.
    package static func legacy(_ list: InboxLegacyList) -> Self {
        switch list {
        case .tracks: .legacyTracks
        case .ideas: .legacyIdeas
        case .messages: .legacyMessages
        }
    }

    /// The entry's own ⋯ (and context menu): only the Idea finder has one
    /// here, **Find Ideas in Past Messages…**, moved from the old Ideas
    /// filter's menu. An artifact's ⋯ is its automation's (Task 14).
    package var menuEntries: [InboxMenuEntry] {
        self == .legacyIdeas ? InboxArtifactMenuContent.ideaFinderEntries : []
    }
}
