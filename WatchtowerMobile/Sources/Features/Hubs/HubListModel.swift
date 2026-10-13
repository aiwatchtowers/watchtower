import Foundation

/// One linked Mac in the switcher (multi-hub spec §5.6).
struct HubListItem: Identifiable, Equatable {
    let id: String
    /// The Mac's name, with a short hub id suffix when two share it.
    let name: String
    /// The Mac's flavor; nil for `default` or before a heartbeat.
    let flavor: String?
    let online: Bool
    /// Whole days since the last heartbeat (or the link, when none came)
    /// while offline; nil online.
    let offlineDays: Int?
    let openAsks: Int
    let isActive: Bool
    /// The Mac removed this phone: the hub is frozen until Forget.
    let removedByMac: Bool
    /// The hub has no session on this phone: its data could not be opened
    /// at launch (`AppEnvironment.live`). Never put on screen; Forget only.
    let unopened: Bool
    /// Removed by the Mac, unopened, or offline
    /// `HubListModel.forgetAfterDays` or more.
    let canForget: Bool
    /// Why the hub cannot be opened, or why its last fetch failed (§6.3);
    /// nil after a good one.
    let problem: String?

    /// The online dot: green only while online (`MacStatusRow`'s rule).
    var dotTone: PhoneTone { online ? .green : .secondary }

    /// The row's state beside (or, removed, in place of) the online dot.
    var statusText: String {
        if removedByMac { return "Removed this phone" }
        if online { return "Online" }
        switch offlineDays ?? 0 {
        case 0: return "Offline"
        case 1: return "Offline 1 day"
        case let days: return "Offline \(days) days"
        }
    }
}

/// The switcher's rows from the registry and the sessions.
@MainActor
enum HubListModel {
    /// Days offline after which a linked Mac may be forgotten (the plan's
    /// long-offline rule).
    static let forgetAfterDays = 7

    /// The problem line of a hub whose session could not be built.
    static let unopenedProblem = "Couldn't open this Mac's data on this iPhone"

    /// The items in registry order. A hub's last heartbeat is the newer of
    /// its session's (fresh after every fetch) and its row's (kept across
    /// launches); online follows the phone's rule (`MacStatus.isOnline`).
    /// A hub the Mac removed is never online. A hub in `unopened` (its
    /// data could not be opened at launch, `AppEnvironment.unopenedHubIDs`)
    /// says so and can be forgotten.
    static func items(
        rows: [HubRow],
        sessions: [String: HubSession],
        unopened unopenedHubIDs: Set<String> = [],
        activeHubID: String?,
        now: Date
    ) -> [HubListItem] {
        let names = HubDisplayName.names(for: rows)
        return rows.map { row in
            let session = sessions[row.hubID]
            let heartbeat = [session?.heartbeat?.updatedAt, row.lastHeartbeatAt].compactMap(\.self).max()
            let removed = row.state == .unlinkedByMac
            let unopened = unopenedHubIDs.contains(row.hubID)
            let online = !removed && heartbeat.map { MacStatus.isOnline(lastHeartbeat: $0, now: now) } == true
            let offlineDays = online ? nil : max(0, Int(now.timeIntervalSince(heartbeat ?? row.linkedOn) / 86_400))
            let flavor = session?.heartbeat?.flavor.rawValue ?? row.flavor
            return HubListItem(
                id: row.hubID,
                name: names[row.hubID] ?? row.link.macName,
                flavor: flavor == "default" ? nil : flavor,
                online: online,
                offlineDays: offlineDays,
                openAsks: session?.workbenchReplica.openAskCount ?? 0,
                isActive: row.hubID == activeHubID,
                removedByMac: removed,
                unopened: unopened,
                canForget: removed || unopened || (offlineDays ?? 0) >= forgetAfterDays,
                problem: unopened ? unopenedProblem : session?.lastFetchError
            )
        }
    }

    /// The open asks of every hub but the one on screen that can still
    /// answer them (not one the Mac removed): the chip's count.
    static func otherHubsOpenAsks(_ items: [HubListItem]) -> Int {
        items.filter { !$0.isActive && !$0.removedByMac }.reduce(0) { $0 + $1.openAsks }
    }

    static func chipAccessibilityLabel(name: String, otherAsks: Int) -> String {
        guard otherAsks > 0 else { return "\(name), Mac" }
        return "\(name), Mac. \(otherAsks) \(otherAsks == 1 ? "ask" : "asks") waiting on other Macs"
    }

    /// Add Mac is off at `HubRegistry.limit` linked Macs.
    static func canAddMac(rows: [HubRow]) -> Bool {
        rows.count < HubRegistry.limit
    }
}
