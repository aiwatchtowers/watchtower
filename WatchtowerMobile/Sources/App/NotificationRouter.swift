import Foundation
import UserNotifications
import WatchtowerSync

/// Where a work alert's tap goes: the ask's form, or the session (its workchat).
enum AlertDestination: Equatable {
    case ask(hubID: String, askID: Int64)
    case session(hubID: String, sessionID: Int64)

    var hubID: String {
        switch self {
        case let .ask(hubID, _), let .session(hubID, _): hubID
        }
    }

    /// Reads the keys the notification extension set (`WorkAlertContent.userInfo`): an ask event opens its ask;
    /// every other event opens its session. Nil for a notification without them (the generic one).
    static func destination(userInfo: [AnyHashable: Any]) -> Self? {
        typealias Key = WorkAlertContent.Key
        guard let hubID = userInfo[Key.hub] as? String, !hubID.isEmpty,
              let event = (userInfo[Key.event] as? String).flatMap(WorkAlertPayload.Event.init(rawValue:))
        else { return nil }
        if event == .ask {
            return (userInfo[Key.ask] as? String).flatMap { Int64($0) }.map { .ask(hubID: hubID, askID: $0) }
        }
        return (userInfo[Key.session] as? String).flatMap { Int64($0) }.map { .session(hubID: hubID, sessionID: $0) }
    }

    /// A banner and sound while the app is open, nothing when the alert's own screen is the one on top.
    static func foregroundOptions(for destination: Self?, onScreen: Self?) -> UNNotificationPresentationOptions {
        if let onScreen, destination == onScreen { return [] }
        return [.banner, .sound]
    }
}

/// A delivered work alert as the sweep sees it: its notification identifier, `wt_key` and delivery time.
struct DeliveredAlert: Equatable {
    let id: String
    let key: String
    let deliveredAt: Date
}

/// Which delivered work alerts are settled and should leave Notification Center.
enum ResolvedAlerts {
    /// A push-delivered alert usually arrives before the fetch that brings its new state into the replica, so an
    /// alert younger than this is never swept: whatever the replica shows then may predate it.
    static let graceAge: TimeInterval = 120

    /// The identifiers to remove. Nothing younger than `graceAge` goes. A rule that rests on absence (the ask is not
    /// open, the request is not pending) also needs `fetchedAt`, the hub's last successful fetch, to be later than
    /// the delivery; so does a stop alert's session that works again, unless its state is newer than the stop.
    /// `fetchedAt` is when the fetch ended, so a replica read still in flight can lag it, which the grace age covers.
    /// An unknown key stays, and so does everything while the replica has not loaded.
    static func keysToRemove(
        delivered: [DeliveredAlert], snapshot: WorkbenchReplicaSnapshot, fetchedAt: Date?, now: Date
    ) -> [String] {
        guard !snapshot.workbenches.isEmpty else { return [] }
        return delivered
            .filter { now.timeIntervalSince($0.deliveredAt) >= graceAge }
            .filter { alert in
                isResolved(alert.key, snapshot: snapshot, fetchedAfterDelivery: fetchedAt.map { $0 > alert.deliveredAt } ?? false)
            }
            .map(\.id)
            .sorted()
    }

    private static func isResolved(_ key: String, snapshot: WorkbenchReplicaSnapshot, fetchedAfterDelivery: Bool) -> Bool {
        let parts = key.split(separator: "-")
        switch (parts.first, parts.count) {
        case ("ask", 2):
            guard fetchedAfterDelivery, let id = Int64(parts[1]) else { return false }
            return !snapshot.openAsks().contains { $0.id == id }
        case ("perm", 2):
            guard fetchedAfterDelivery, let id = Int64(parts[1]) else { return false }
            return !snapshot.pendingPermissions.contains { $0.id == id }
        case ("stop", 3):
            guard let id = Int64(parts[1]), let ms = Int64(parts[2]), let session = snapshot.session(id) else { return false }
            let movedOn = session.stateAt.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) > ms } ?? false
            // A working state the replica held before the stop arrived may be the one the stop ended: it counts
            // only when it is newer than the stop or a fetch came after the delivery.
            if session.stateKind == .working { return movedOn || fetchedAfterDelivery }
            return movedOn
        default:
            return false
        }
    }
}

/// Removes the delivered alerts of one hub that its replica now shows settled. The notification center is a seam.
@MainActor
struct DeliveredAlertCleaner {
    /// (identifier, delivery date, userInfo) of every delivered notification.
    var delivered: () async -> [(id: String, date: Date, userInfo: [String: String])]
    var remove: ([String]) -> Void

    static let live = Self(
        delivered: {
            await UNUserNotificationCenter.current().deliveredNotifications().map { note in
                var info: [String: String] = [:]
                for (key, value) in note.request.content.userInfo {
                    if let key = key as? String, let value = value as? String { info[key] = value }
                }
                return (id: note.request.identifier, date: note.date, userInfo: info)
            }
        },
        remove: { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: $0) }
    )

    func clear(hubID: String, snapshot: WorkbenchReplicaSnapshot, fetchedAt: Date?, now: Date) async {
        guard !snapshot.workbenches.isEmpty else { return }
        var alerts: [DeliveredAlert] = []
        for note in await delivered() where note.userInfo[WorkAlertContent.Key.hub] == hubID {
            if let key = note.userInfo[WorkAlertContent.Key.key] { alerts.append(DeliveredAlert(id: note.id, key: key, deliveredAt: note.date)) }
        }
        guard !alerts.isEmpty else { return }
        let gone = ResolvedAlerts.keysToRemove(delivered: alerts, snapshot: snapshot, fetchedAt: fetchedAt, now: now)
        if !gone.isEmpty { remove(gone) }
    }
}
