import Foundation
import WatchtowerSync

/// Builds the phone's live transport for a hub's route, and answers the
/// route-independent questions the app asks of the build. CloudKit is the only
/// transport in this phase; a `.hostedRelay` route throws
/// `UnsupportedRouteError` and never falls back to CloudKit.
struct TransportFactory: Sendable {
    /// The build can run this transport (CloudKit: `CloudKitTransport.entitlementPresent()`).
    let isAvailable: @Sendable () -> Bool
    /// A phone-role transport for `route` on `store`; `.hostedRelay` throws `UnsupportedRouteError`.
    let make: @Sendable (_ route: HubRoute, _ store: TransportStore, _ hubID: String, _ energy: EnergyCounter?) throws -> any LiveTransport
    /// One record saved outside any engine (the kept farewell, #143): CloudKit's `saveDirectly(_:scope:hubID:)`.
    let sendDirectly: @Sendable (_ record: CloudRecord, _ route: HubRoute, _ hubID: String) async throws -> Void

    static let cloudKit = Self(
        isAvailable: { CloudKitTransport.entitlementPresent() },
        make: { route, store, hubID, energy in
            guard let scope = route.cloudKitScope else { throw UnsupportedRouteError(route: route) }
            return CloudKitTransport(store: store, scope: scope, hubID: hubID, role: .phone, energy: energy)
        },
        sendDirectly: { record, route, hubID in
            guard let scope = route.cloudKitScope else { throw UnsupportedRouteError(route: route) }
            try await CloudKitTransport.saveDirectly(record, scope: scope, hubID: hubID)
        }
    )
}
