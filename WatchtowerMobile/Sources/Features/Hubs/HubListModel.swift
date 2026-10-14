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
    /// The name and problem line of a registry row that cannot be read (a
    /// newer build's link, a damaged value): its Mac's name is in it.
    static let unreadableName = "Unknown Mac"
    static let unreadableProblem = "Couldn't read this Mac's link on this iPhone"

    /// The items in registry order. A hub's last heartbeat is the newer of
    /// its session's (fresh after every fetch) and its row's (kept across
    /// launches); online follows the phone's rule (`MacStatus.isOnline`).
    /// A hub the Mac removed is never online. A hub in `unopened` (its
    /// data could not be opened at launch, `AppEnvironment.unopenedHubIDs`)
    /// says so and can be forgotten. The hub ids of rows that cannot be
    /// read (`unreadable`, `HubRegistry.unreadableHubIDs`, in order) are
    /// each unopened and forgettable (#222), and take their own places in
    /// the registry's order: the places the readable rows' `sortOrder`
    /// leaves free (the registry numbers its rows 0…n−1). So a list index
    /// is the registry index a move writes (`MacsModel.registryMove`).
    static func items(
        rows: [HubRow],
        unreadable: [String] = [],
        sessions: [String: HubSession],
        unopened unopenedHubIDs: Set<String> = [],
        activeHubID: String?,
        now: Date
    ) -> [HubListItem] {
        let names = HubDisplayName.names(for: rows)
        let readable = rows.map { row in
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
        let taken = Set(rows.map(\.sortOrder))
        let free = (0..<(rows.count + unreadable.count)).filter { !taken.contains($0) }
        let unknown = unreadable.enumerated().map { index, hubID in
            (
                order: index < free.count ? free[index] : Int.max,
                item: HubListItem(
                    id: hubID, name: unreadableName, flavor: nil, online: false, offlineDays: nil, openAsks: 0,
                    isActive: false, removedByMac: false, unopened: true, canForget: true, problem: unreadableProblem
                )
            )
        }
        let known = zip(rows, readable).map { (order: $0.sortOrder, item: $1) }
        // Stable: equal places keep the readable row first.
        return (known + unknown).enumerated()
            .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
            .map(\.element.item)
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

    /// Add Mac is off at `HubRegistry.limit` linked Macs, those whose row
    /// cannot be read (`unreadable`) included.
    static func canAddMac(rows: [HubRow], unreadable: [String] = []) -> Bool {
        rows.count + unreadable.count < HubRegistry.limit
    }
}
