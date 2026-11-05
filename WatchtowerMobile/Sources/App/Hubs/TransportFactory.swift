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
    /// `make` can build a transport for the route: checked before its store is opened, so a route this factory
    /// refuses leaves no empty store file.
    let serves: @Sendable (_ route: HubRoute) -> Bool
    /// A phone-role transport for `route` on `store`; a route this factory cannot serve throws `UnsupportedRouteError`.
    let make: @Sendable (_ route: HubRoute, _ store: TransportStore, _ hubID: String, _ energy: EnergyCounter?) throws -> any LiveTransport
    /// A Relay link's pairing transport (relay client Phase 3 Task 10): both lanes on `pair/<slot>`, on `store`
    /// bound to the Mac `macDeviceID` (after `promote_pairing`, `make` goes on with the same store).
    var makePairing: @Sendable (_ macDeviceID: String, _ slot: String, _ store: TransportStore, _ energy: EnergyCounter?) throws
        -> any LiveTransport = { macDeviceID, _, _, _ in throw UnsupportedRouteError(route: .hostedRelay(macDeviceID: macDeviceID)) }
    /// One record saved outside any engine (the kept farewell, #143): CloudKit's `saveDirectly(_:scope:hubID:)`,
    /// or on a relay route a save through the shared client into the phone's mailbox with that Mac.
    let sendDirectly: @Sendable (_ record: CloudRecord, _ route: HubRoute, _ hubID: String) async throws -> Void

    /// The push side the session's alert subscription goes through: CloudKit's on every route (the subscription stays
    /// on the hub's CloudKit route while the phone is on the relay).
    let wake: any PushWake

    /// CloudKit only: a `.hostedRelay` route throws (tests, and the relay's absence).
    static let cloudKit = live(relay: .off)

    /// CloudKit, and the hosted relay on `relay`'s shared session.
    static func live(relay: SharedRelaySession) -> Self {
        var factory = Self(
            isAvailable: { CloudKitTransport.entitlementPresent() },
            serves: { route in
                guard case .hostedRelay = route else { return true }
                if case .available = relay.availability { return true }
                return false
            },
            make: { route, store, hubID, energy in
                switch route {
                case .cloudKit(let scope):
                    return CloudKitTransport(store: store, scope: scope, hubID: hubID, role: .phone, energy: energy)
                case .hostedRelay(let macDeviceID):
                    guard let session = try relay.session() else { throw UnsupportedRouteError(route: route) }
                    return try HostedRelayTransport(session: session, store: store, macDeviceID: macDeviceID, mode: .hub, energy: energy)
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
        factory.makePairing = { macDeviceID, slot, store, energy in
            guard let session = try relay.session() else { throw UnsupportedRouteError(route: .hostedRelay(macDeviceID: macDeviceID)) }
            return try HostedRelayTransport(
                session: session, store: store, macDeviceID: macDeviceID, mode: .pairing(slot: slot), energy: energy
            )
        }
        return factory
    }
}

/// A transport for a hub's other route and the store it runs on (nil for a stand-in without one), for the side
/// mailbox reader (relay client Phase 3 Task 12), which stops the one and closes the other when done with them.
struct SideTransport {
    let transport: any CloudSyncTransport & Sendable
    let store: TransportStore?
    /// Makes the next pull read the whole mailbox again: the store is the route's own, which the session that left it
    /// read and compacted, and a drain must see everything there. On the relay a resync of the mailbox zone. On
    /// CloudKit the store is wiped before its engine starts (its leftover send queue with it: nothing more goes out on
    /// a transport the hub left): the engine's state is one blob for the whole database, so the relay zone cannot be
    /// re-read alone. Nothing for a stand-in without a store.
    let readFromStart: @Sendable () async throws -> Void
    /// Brings the mailbox up to date: on the relay the mailbox zone alone, with nothing flushed (a refusal of the data
    /// zone never stops a drain); on CloudKit the engine's fetch (the whole database); nothing for a stand-in.
    let pullMailbox: @Sendable () async throws -> Void

    init(transport: any CloudSyncTransport & Sendable, store: TransportStore?) {
        self.transport = transport
        self.store = store
        if let relay = transport as? HostedRelayTransport {
            readFromStart = { try await relay.readFromStart(.relay) }
            pullMailbox = { try await relay.pull(only: [.relay]) }
            return
        }
        if let store {
            readFromStart = { try store.wipe() }
        } else {
            readFromStart = {}
        }
        if let live = transport as? any LiveTransport {
            pullMailbox = { try await live.pull() }
        } else {
            pullMailbox = {}
        }
    }

    /// Sim rule 16: the relay refused the account (`FORBIDDEN`: the hub left its slots or the mailbox is out of
    /// reach; `ENTITLEMENT_INACTIVE`: a lapsed account), on a read or a delete. Retrying cannot clear it this launch.
    static func refusesTheAccount(_ error: any Error) -> Bool {
        guard case let HostedRelayError.server(code, _) = error else { return false }
        return code == .forbidden || code == .entitlementInactive
    }

    /// `refusesTheAccount` for a delete's refusal.
    static func refusesTheAccount(_ refusal: TransportRefusal) -> Bool {
        refusal == .entitlementInactive || refusal == .permanent(code: "forbidden")
    }
}
