import Foundation

/// Where a hub's data lives, above the transport seam: a CloudKit database
/// scope, or a hosted relay addressed by the Mac's device id.
public enum HubRoute: Equatable, Sendable {
    case cloudKit(CloudDatabaseScope)
    case hostedRelay(macDeviceID: String)

    /// The CloudKit scope of a `.cloudKit` route, nil for any other.
    public var cloudKitScope: CloudDatabaseScope? {
        if case .cloudKit(let scope) = self { return scope }
        return nil
    }
}

/// A route met by code that only serves CloudKit.
public struct UnsupportedRouteError: Error, Equatable, Sendable {
    public let route: HubRoute

    public init(route: HubRoute) {
        self.route = route
    }
}
