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
        guard let hubID = userInfo["wt_hub"] as? String, !hubID.isEmpty,
              let event = (userInfo["wt_event"] as? String).flatMap(WorkAlertPayload.Event.init(rawValue:))
        else { return nil }
        if event == .ask {
            return (userInfo["wt_ask"] as? String).flatMap { Int64($0) }.map { .ask(hubID: hubID, askID: $0) }
        }
        return (userInfo["wt_session"] as? String).flatMap { Int64($0) }.map { .session(hubID: hubID, sessionID: $0) }
    }

    /// A banner and sound while the app is open, nothing when the alert's own screen is the one on top.
    static func foregroundOptions(for destination: Self?, onScreen: Self?) -> UNNotificationPresentationOptions {
        if let onScreen, destination == onScreen { return [] }
        return [.banner, .sound]
    }
}

/// Which delivered work alerts are settled and should leave Notification Center.
enum ResolvedAlerts {
    /// `delivered` is notification identifier -> `wt_key` of the hub's alerts. An unknown key stays, and so does
    /// everything while the replica has not loaded (no workbench yet): absence there proves nothing.
    static func keysToRemove(delivered: [String: String], snapshot: WorkbenchReplicaSnapshot) -> [String] {
        guard !snapshot.workbenches.isEmpty else { return [] }
        return delivered.filter { isResolved(key: $0.value, snapshot: snapshot) }.map(\.key).sorted()
    }

    private static func isResolved(key: String, snapshot: WorkbenchReplicaSnapshot) -> Bool {
        let parts = key.split(separator: "-")
        switch (parts.first, parts.count) {
        case ("ask", 2):
            guard let id = Int64(parts[1]) else { return false }
            return !snapshot.openAsks().contains { $0.id == id }
        case ("perm", 2):
            guard let id = Int64(parts[1]) else { return false }
            return !snapshot.pendingPermissions.contains { $0.id == id }
        case ("stop", 3):
            guard let id = Int64(parts[1]), let ms = Int64(parts[2]), let session = snapshot.session(id) else { return false }
            if session.stateKind == .working { return true }
            guard let stateAt = session.stateAt else { return false }
            return Int64((stateAt.timeIntervalSince1970 * 1000).rounded()) > ms
        default:
            return false
        }
    }
}

/// Removes the delivered alerts of one hub that its replica now shows settled. The notification center is a seam.
@MainActor
struct DeliveredAlertCleaner {
    /// (identifier, userInfo) of every delivered notification.
    var delivered: () async -> [(id: String, userInfo: [String: String])]
    var remove: ([String]) -> Void

    static let live = Self(
        delivered: {
            await UNUserNotificationCenter.current().deliveredNotifications().map { note in
                var info: [String: String] = [:]
                for (key, value) in note.request.content.userInfo {
                    if let key = key as? String, let value = value as? String { info[key] = value }
                }
                return (id: note.request.identifier, userInfo: info)
            }
        },
        remove: { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: $0) }
    )

    func clear(hubID: String, snapshot: WorkbenchReplicaSnapshot) async {
        guard !snapshot.workbenches.isEmpty else { return }
        var keys: [String: String] = [:]
        for note in await delivered() where note.userInfo["wt_hub"] == hubID {
            if let key = note.userInfo["wt_key"] { keys[note.id] = key }
        }
        guard !keys.isEmpty else { return }
        let gone = ResolvedAlerts.keysToRemove(delivered: keys, snapshot: snapshot)
        if !gone.isEmpty { remove(gone) }
    }
}
