import Foundation

/// A notification response handed from a deferring duplicate instance to the one that
/// survived the single-instance race, reduced to what `NotificationDelegate.route` reads
/// on its FORWARDED (navigation-only) branches — a strict subset of what a self-received
/// response carries.
struct ForwardedNotificationResponse: Codable {
    let actionID: String
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
/// The bus is an unauthenticated per-session one — any process running as this user can
/// post on it — so forwarding is deliberately reduced to navigation. Action-button
/// responses (Join / Join + Record / Stop recording) are NOT forwarded as actions: a
/// forwarded action-button click degrades to navigating the survivor to its Calendar
/// tab. Full-fidelity forwarding would need an authenticated transport (XPC with a peer
/// audit token plus a code-signing check), deliberately out of scope here.
///
/// Forwarding is best-effort in the other direction too: an old-build survivor without
/// the observer receives nothing, and forwarding silently degrades to activate-only.
enum NotificationForwarding {
    static let notificationName = Notification.Name("com.watchtower.desktop.forwarded-notification-response")

    /// The one routed key that is not a string in the push's `userInfo`.
    static let digestIDKey = "digestId"

    /// The `userInfo` keys forwarded routing in `NotificationDelegate.route` actually
    /// reads — anything else in the push is dropped rather than shipped across the
    /// process boundary.
    static let routedKeys = ["type", digestIDKey]

    static func encode(actionID: String, userInfo: [AnyHashable: Any]) -> String? {
        var payload: [String: String] = [:]
        for key in routedKeys {
            if let value = userInfo[key] as? String {
                payload[key] = value
            } else if let value = userInfo[key] as? Int {
                payload[key] = String(value)
            }
        }
        let response = ForwardedNotificationResponse(actionID: actionID, payload: payload)
        guard let data = try? JSONEncoder().encode(response),
              let json = String(data: data, encoding: .utf8) else {
            NSLog("NotificationForwarding: could not encode response for action %@", actionID)
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

    /// Duplicate side. Returns whether the response reached the bus at all — false
    /// means it could not be encoded and nothing was posted. True is not delivery:
    /// `deliverImmediately` bypasses receiver-side suspension and coalescing, but it
    /// is not an acknowledgement — once `post` returns, distnoted owns the message and
    /// nothing here can observe whether it landed.
    @discardableResult
    static func post(actionID: String, userInfo: [AnyHashable: Any]) -> Bool {
        guard let json = encode(actionID: actionID, userInfo: userInfo) else { return false }
        DistributedNotificationCenter.default().postNotificationName(
            notificationName,
            object: json,
            userInfo: nil,
            deliverImmediately: true
        )
        return true
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
