import Foundation

/// `PushWake` for the hosted relay's APNs bodies: the silent `{"aps":{"content-available":1}}` and the alert push
/// `{"aps":{"mutable-content":1,"alert":{"title":"Watchtower"}},"e":"<standard base64 of the sealed envelope>"}`.
/// Neither names a hub; the alert's hub comes from the envelope's clear header. Nothing here opens an envelope or
/// touches the network: `AlertOpener` still checks the signature.
public struct RelayPushWake: PushWake {
    /// `secure.AlertPushMaxEnvelope` in the Go hub: the largest envelope a push may carry.
    public static let maxEnvelopeBytes = 3021

    public init() {}

    /// The relay's token is phone-wide (registered once, Task 13), so no per-hub subscription exists.
    public func subscribeAlerts(hubID: String, route: HubRoute) async throws -> Bool {
        guard case .hostedRelay = route else { throw UnsupportedRouteError(route: route) }
        return false
    }

    public func unsubscribeAlerts(hubID: String, route: HubRoute) async throws {}

    public func origin(ofRemoteNotification userInfo: [AnyHashable: Any]) -> PushOrigin? {
        guard userInfo["ck"] == nil, userInfo["e"] == nil,
              let aps = userInfo["aps"] as? [AnyHashable: Any],
              (aps["content-available"] as? NSNumber)?.intValue == 1
        else { return nil }
        return .hostedRelay
    }

    public func alertSource(for userInfo: [AnyHashable: Any]) -> AlertSource? {
        guard userInfo["ck"] == nil, let text = userInfo["e"] as? String,
              // Four characters carry three bytes: refuse an oversize string before decoding it.
              text.utf8.count <= (Self.maxEnvelopeBytes + 2) / 3 * 4,
              // Standard alphabet with padding; unknown characters are not skipped.
              let envelope = Data(base64Encoded: text), envelope.count <= Self.maxEnvelopeBytes,
              let parsed = try? Envelope.parse(envelope),
              parsed.header.envelopeClass == .alert,
              parsed.header.senderID == parsed.header.hubID
        else { return nil }
        return .inline(hubID: parsed.header.hubID.uuidString, envelope: envelope)
    }

    public func envelope(for source: AlertSource, timeout: TimeInterval) async throws -> Data? {
        switch source {
        case .inline(_, let envelope): return envelope
        case .fetchRecord: throw UnsupportedRouteError(route: .hostedRelay(macDeviceID: ""))
        }
    }
}

/// Which transport reads a push: a payload with `ck` is CloudKit's, anything else the relay's.
public enum PushRouting {
    public static func origin(ofRemoteNotification userInfo: [AnyHashable: Any], cloudKit: any PushWake) -> PushOrigin? {
        userInfo["ck"] != nil
            ? cloudKit.origin(ofRemoteNotification: userInfo)
            : RelayPushWake().origin(ofRemoteNotification: userInfo)
    }

    public static func alertSource(for userInfo: [AnyHashable: Any], cloudKit: any PushWake) -> AlertSource? {
        userInfo["ck"] != nil
            ? cloudKit.alertSource(for: userInfo)
            : RelayPushWake().alertSource(for: userInfo)
    }

    /// The sealed envelope for `source`: an inline one is already in hand (no network); a CloudKit record is fetched.
    public static func envelope(for source: AlertSource, timeout: TimeInterval, cloudKit: any PushWake) async throws -> Data? {
        switch source {
        case .inline: return try await RelayPushWake().envelope(for: source, timeout: timeout)
        case .fetchRecord: return try await cloudKit.envelope(for: source, timeout: timeout)
        }
    }
}
