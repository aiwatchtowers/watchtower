import Foundation

/// The phone's Inbox tab as a whole (mobile Inbox spec §7, mockup §6).
public enum InboxTabState: Equatable, Sendable {
    /// The first fetch after linking, before any Inbox record arrived.
    case loading(hub: String)
    /// Fetched, and nothing is in the Inbox.
    case empty(hub: String)
    /// The hub does not announce the inbox capability.
    case tooOld(hub: String)
    /// `MobileSync = workbench_only`: the hub publishes no Inbox.
    case policyOff
    case ready
    /// The Mac sleeps: the cards stay as of its last publish.
    case macAway(hub: String, asOf: Date)

    /// The capability value the hub announces under an organization policy
    /// that keeps the Inbox on the Mac.
    public static let policyOffCapability = "policy_off"

    /// `capability` is the hub's inbox capability (nil when it announces
    /// none); `fetched` whether a fetch has finished; `macAway` when the Mac
    /// was last seen, while it is away.
    public static func resolve(
        capability: String?,
        fetched: Bool,
        feed: Feed?,
        hubName: String,
        macAway: Date?
    ) -> Self {
        guard let capability else { return .tooOld(hub: hubName) }
        if capability == policyOffCapability { return .policyOff }
        guard fetched, let feed else { return .loading(hub: hubName) }
        if let macAway { return .macAway(hub: hubName, asOf: macAway) }
        return feed.cards.isEmpty ? .empty(hub: hubName) : .ready
    }

    /// The state's title and body; nil for the states that draw the list.
    public var copy: (title: String, body: String)? {
        switch self {
        case let .loading(hub): (TowerText.loadingInbox(hub: hub), "")
        case let .empty(hub): (TowerText.emptyTitle, TowerText.emptyBody(hub: hub))
        case let .tooOld(hub): (TowerText.tooOldTitle(hub: hub), TowerText.tooOldBody(hub: hub))
        case .policyOff: (TowerText.policyTitle, TowerText.policyBody)
        case .ready, .macAway: nil
        }
    }
}
