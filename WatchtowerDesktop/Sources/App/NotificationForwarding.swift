import Foundation

/// A notification response handed from a deferring duplicate instance to the one that
/// survived the single-instance race, reduced to what `NotificationDelegate.route` reads.
///
/// Payload only, by design: the action identifier deliberately does not cross the bus,
/// so no action-button branch of `route` is reachable from a forwarded response. A blob
/// that still carries an `actionID` key decodes fine and simply has nowhere to put it.
struct ForwardedNotificationResponse: Codable {
    /// The routed subset of the push's `userInfo`, every value flattened to a string.
    let payload: [String: String]

    /// The routing view of the payload, with `digestId` restored to the Int the
    /// navigation call expects. A missing or unparseable one drops the key rather
    /// than smuggling a string in under it.
    var userInfo: [AnyHashable: Any] {
        var info: [AnyHashable: Any] = payload
        info[NotificationForwarding.digestIDKey] = payload[NotificationForwarding.digestIDKey].flatMap(Int.init)
        return info
    }
}

/// Carries a notification response across the single-instance boundary: the duplicate
/// posts, the survivor routes.
///
/// The transport is a distributed notification with a JSON string in `object`.
/// LaunchServices cannot address one of two processes sharing a bundle identifier, so
/// URL-scheme routing is ambiguous here; distributed `userInfo` is dropped under App
/// Sandbox (this app is unsandboxed today — `com.apple.security.app-sandbox` is false
/// in `scripts/Watchtower.entitlements` — but an object string works either way).
///
/// Threat model: `DistributedNotificationCenter` is a session-wide bus with no sender
/// authentication, so any process running as this user can post here and the survivor
/// cannot tell a real duplicate from a forgery. The payload is therefore untrusted
/// input and may only ever *navigate*: the action identifier does not travel, so a
/// forged post cannot reach a capability-bearing branch (`joinRecordActionID` starting
/// mic + system-audio capture under this app's TCC grants, `stopRecordingActionID`
/// stopping one). Navigation-only is the settled design, not a stopgap: an authenticated
/// transport (XPC with a peer code-signing check) would buy back only the ability to
/// forward action buttons, which is not worth a Mach-service registration. Do not let
/// the identifier — or any other capability-bearing field — cross this bus again.
enum NotificationForwarding {
    static let notificationName = Notification.Name("com.watchtower.desktop.forwarded-notification-response")

    /// The one routed key that is not a string in the push's `userInfo`.
    static let digestIDKey = "digestId"

    /// The `userInfo` keys `NotificationDelegate.route` actually reads — anything else
    /// in the push is dropped rather than shipped across the process boundary.
    private static let routedKeys = ["type", digestIDKey, "eventId", "conferenceUrl"]

    static func encode(userInfo: [AnyHashable: Any]) -> String? {
        var payload: [String: String] = [:]
        for key in routedKeys {
            if let value = userInfo[key] as? String {
                payload[key] = value
            } else if let value = userInfo[key] as? Int {
                payload[key] = String(value)
            }
        }
        let response = ForwardedNotificationResponse(payload: payload)
        guard let data = try? JSONEncoder().encode(response),
              let json = String(data: data, encoding: .utf8) else {
            NSLog("NotificationForwarding: could not encode forwarded response")
            return nil
        }
        return json
    }

    static func decode(_ raw: String) -> ForwardedNotificationResponse? {
        guard let data = raw.data(using: .utf8),
              let response = try? JSONDecoder().decode(ForwardedNotificationResponse.self, from: data) else {
            NSLog("NotificationForwarding: dropping unreadable forwarded response")
            return nil
        }
        return response
    }

    /// Duplicate side. Delivery is immediate: the poster exits right after.
    static func post(userInfo: [AnyHashable: Any]) {
        guard let json = encode(userInfo: userInfo) else { return }
        DistributedNotificationCenter.default().postNotificationName(
            notificationName,
            object: json,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// Survivor side. The observer lives as long as the app does, so its token is
    /// deliberately dropped.
    static func observe(_ handler: @escaping (ForwardedNotificationResponse) -> Void) {
        _ = DistributedNotificationCenter.default().addObserver(
            forName: notificationName,
            object: nil,
            queue: .main
        ) { notification in
            guard let raw = notification.object as? String, let response = decode(raw) else { return }
            handler(response)
        }
    }
}
