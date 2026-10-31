import Foundation

/// The database a silent push came from: it reaches the sessions linked through that scope only.
public enum PushOrigin: Equatable, Sendable {
    case `private`
    case shared
}

/// Where a work alert's sealed envelope comes from.
public struct AlertRecordRef: Equatable, Sendable {
    public let hubID: String
    public let wireName: String
    public let zoneName: String
    public let ownerName: String

    public init(hubID: String, wireName: String, zoneName: String, ownerName: String) {
        self.hubID = hubID
        self.wireName = wireName
        self.zoneName = zoneName
        self.ownerName = ownerName
    }
}

public enum AlertSource: Equatable, Sendable {
    /// CloudKit: fetch the sealed ask_alert the signal names.
    case fetchRecord(AlertRecordRef)
    /// Hosted relay (Phase 4): the envelope rides in the push.
    case inline(hubID: String, envelope: Data)

    /// Spec §10.
    public static let inlineWireName = "alert-push"

    public var hubID: String {
        switch self {
        case .fetchRecord(let ref): return ref.hubID
        case .inline(let hubID, _): return hubID
        }
    }

    public var wireName: String {
        switch self {
        case .fetchRecord(let ref): return ref.wireName
        case .inline: return Self.inlineWireName
        }
    }
}

/// A transport's push side: the work-alert subscription, which sessions a silent push reaches, and the NSE's alert.
public protocol PushWake: Sendable {
    /// Registers the hub's work-alert push; false when the route has none (CloudKit shared scope, D14).
    func subscribeAlerts(hubID: String, route: HubRoute) async throws -> Bool
    func unsubscribeAlerts(hubID: String, route: HubRoute) async throws
    /// Which sessions a silent push reaches; nil = not a database push of this transport (every session fetches).
    func origin(ofRemoteNotification userInfo: [AnyHashable: Any]) -> PushOrigin?
    /// The NSE's alert, nil when the payload is not a work-alert push.
    func alertSource(for userInfo: [AnyHashable: Any]) -> AlertSource?
    /// The sealed envelope for `source`, fetched within `timeout` when it must be.
    func envelope(for source: AlertSource, timeout: TimeInterval) async throws -> Data?
}

extension HubRoute {
    /// The push origin of the route's database; nil for a hosted relay.
    public var pushOrigin: PushOrigin? {
        switch self {
        case .cloudKit(.private): return .private
        case .cloudKit(.shared): return .shared
        case .hostedRelay: return nil
        }
    }
}
