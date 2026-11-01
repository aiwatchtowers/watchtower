import Foundation
import WatchtowerHostedRelay
import WatchtowerSync

/// Builds the phone's live transport for a hub's route, and answers the
/// route-independent questions the app asks of the build. A `.cloudKit`
/// route runs on CloudKit; a `.hostedRelay` route on the process's one relay
/// session (`live(relay:)`), and while the relay is off it throws
/// `UnsupportedRouteError`, never falling back to CloudKit.
struct TransportFactory: Sendable {
    /// The build can run this transport (CloudKit: `CloudKitTransport.entitlementPresent()`).
    let isAvailable: @Sendable () -> Bool
    /// A phone-role transport for `route` on `store`; a route this factory cannot serve throws `UnsupportedRouteError`.
    let make: @Sendable (_ route: HubRoute, _ store: TransportStore, _ hubID: String, _ energy: EnergyCounter?) throws -> any LiveTransport
    /// One record saved outside any engine (the kept farewell, #143): CloudKit's `saveDirectly(_:scope:hubID:)`,
    /// or on a relay route a save through the shared client into the phone's mailbox with that Mac.
    let sendDirectly: @Sendable (_ record: CloudRecord, _ route: HubRoute, _ hubID: String) async throws -> Void

    /// The transport's push side: the work-alert subscription, silent-push origins and the NSE's alert. CloudKit's
    /// on every route: relay pushes come with Phase 4.
    let wake: any PushWake

    /// CloudKit only: a `.hostedRelay` route throws (tests, and the relay's absence).
    static let cloudKit = live(relay: .off)

    /// CloudKit, and the hosted relay on `relay`'s shared session.
    static func live(relay: SharedRelaySession) -> Self {
        Self(
            isAvailable: { CloudKitTransport.entitlementPresent() },
            make: { route, store, hubID, energy in
                switch route {
                case .cloudKit(let scope):
                    return CloudKitTransport(store: store, scope: scope, hubID: hubID, role: .phone, energy: energy)
                case .hostedRelay(let macDeviceID):
                    guard let session = try relay.session() else { throw UnsupportedRouteError(route: route) }
                    return try HostedRelayTransport(session: session, store: store, macDeviceID: macDeviceID, energy: energy)
                }
            },
            sendDirectly: { record, route, hubID in
                switch route {
                case .cloudKit(let scope):
                    try await CloudKitTransport.saveDirectly(record, scope: scope, hubID: hubID)
                case .hostedRelay(let macDeviceID):
                    guard let session = try relay.session() else { throw UnsupportedRouteError(route: route) }
                    try await HostedRelayTransport.saveDirectly(record, client: session.client, macDeviceID: macDeviceID)
                }
            },
            wake: CloudKitPushWake()
        )
    }
}
