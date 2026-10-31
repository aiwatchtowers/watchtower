import CryptoKit
import Foundation
@testable import WatchtowerHostedRelay
import WatchtowerHostedRelayTesting
import WatchtowerRelayProto
@testable import WatchtowerSync
import XCTest

/// One Mac and its phones on both legs, sharing the backend's `ManualRelayClock` (the Go
/// `sim_interop_test.go` `world`). The hub is a `SimHub` over a `SimRelayHubLeg` (a Mac
/// `HostedRelayClient`) and the shared `SimCloudKitLeg`; a paying phone is a `SimPhone` over a
/// `SimRelayPhoneLeg` (the real `HostedRelayTransport` with its own client and store) and the
/// same CloudKit leg; a free phone has CloudKit only. Devices come from fixed seeds: the Mac 1,
/// phones 2, 3, ….
final class SimWorld {
    static let origin = "https://relay.example.com"
    static let macSeed: UInt8 = 1

    let backend: RelayBackend
    let clock: ManualRelayClock
    let cloudKit: SimCloudKitLeg
    let hub: SimHub
    let mac: HostedRelayClient
    private(set) var phones: [SimPhone] = []
    private var phoneClients: [String: HostedRelayClient] = [:]
    private var payingPhones: [String] = []
    private var nextSeed = macSeed + 1

    /// The Mac registered and logged in, on `start` in epoch 1 (the relay, as in Go).
    init(backend: RelayBackend, start: SimKind = .relay) async throws {
        self.backend = backend
        switch backend {
        case .fake(let relay): clock = relay.clock
        }
        cloudKit = SimCloudKitLeg(clock: clock)
        mac = try await Self.client(backend, kind: .mac, seed: Self.macSeed)
        let dataZone = HostedRelayZones.data(mac: mac.deviceID)
        cloudKit.addDataZone(Self.cloudKitData(mac.deviceID))
        hub = SimHub(SimHubConfig(
            id: mac.deviceID, clock: clock,
            transports: [.relay: SimRelayHubLeg(client: mac, clock: clock), .cloudkit: cloudKit],
            phones: [], current: start, dataZone: dataZone))
    }

    /// The server's `/dev` controls.
    var stand: any RelayStandControl {
        switch backend {
        case .fake(let relay): return relay
        }
    }

    /// Links a new phone to the hub. A paying phone registers, pays, is paired with the Mac and
    /// starts on the hub's transport with a mailbox on both legs; a free phone has only its
    /// CloudKit mailbox and starts there.
    func addPhone(paying: Bool) async throws -> SimPhone {
        let seed = nextSeed
        nextSeed += 1
        let start = await hub.transport
        let phone: SimPhone
        if paying {
            let client = try await Self.client(backend, kind: .phone, seed: seed)
            let account = try await stand.accountID(ofPhone: client.deviceID)
            try await stand.setEntitlement(accountID: account, state: "active", for: .seconds(365 * 86_400))
            payingPhones.append(client.deviceID)
            try await stand.pair(mac: mac.deviceID, phones: payingPhones)
            let transport = try HostedRelayTransport(client: client, store: TransportStore.inMemory(), macDeviceID: mac.deviceID)
            let mailbox = mailboxes(client.deviceID, relay: true)
            phone = SimPhone(SimPhoneConfig(
                id: client.deviceID, clock: clock,
                transports: [.relay: SimRelayPhoneLeg(transport: transport, clock: clock), .cloudkit: cloudKit],
                mailbox: mailbox, current: start, dataZone: HostedRelayZones.data(mac: mac.deviceID)))
            phoneClients[client.deviceID] = client
        } else {
            let id = RelayAuthMessages.deviceID(publicKey: try Self.signer(seed: seed).publicKey)
            phone = SimPhone(SimPhoneConfig(
                id: id, clock: clock, transports: [.cloudkit: cloudKit], mailbox: mailboxes(id, relay: false),
                current: .cloudkit, dataZone: ""))
        }
        await hub.addPhone(SimPhoneLink(id: phone.id, mailbox: mailboxes(phone.id, relay: paying)))
        phones.append(phone)
        return phone
    }

    // MARK: - Driving

    /// Syncs the hub, then every phone, until a whole round makes no progress (the Go `settle`).
    func syncAll(file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            var progress = await hub.sync()
            for phone in phones {
                let moved = await phone.sync()
                progress = progress || moved
            }
            if !progress { return }
        }
        XCTFail("sim: no quiescence after 100 rounds", file: file, line: line)
        throw SimWorldError.noQuiescence
    }

    /// Moves the shared clock.
    func advance(_ duration: Duration) {
        clock.advance(by: duration)
    }

    /// The relay is down for everyone (fake only: `crash`; the stand skips, R15).
    func relayDown() throws {
        try fake("relayDown needs the fake's crash").crash()
    }

    /// The relay is back with the state it had (fake only: `restart`).
    func relayUp() throws {
        try fake("relayUp needs the fake's restart").restart()
    }

    // MARK: - Looking

    /// The names of the live records of the phone's relay mailbox, read by the Mac.
    func relayMailbox(_ phone: SimPhone) async throws -> [String] {
        var changes = Relay_V1_Changes()
        changes.zone = HostedRelayZones.mailbox(mac: mac.deviceID, phone: phone.id)
        return try await mac.changes(changes).changed.filter { !$0.deleted }.map(\.name).sorted()
    }

    /// The names of the live records of the phone's CloudKit mailbox.
    func cloudKitMailbox(_ phone: SimPhone) async -> [String] {
        await cloudKit.live(cloudKitZone(phone))
    }

    /// The phone's CloudKit mailbox zone.
    func cloudKitZone(_ phone: SimPhone) -> String {
        Self.cloudKitMailbox(mac: mac.deviceID, phone: phone.id)
    }

    /// The relay client of a paying phone.
    func relayClient(_ phone: SimPhone) -> HostedRelayClient? {
        phoneClients[phone.id]
    }

    // MARK: - Private

    private func mailboxes(_ phoneID: String, relay: Bool) -> [SimKind: String] {
        let zone = Self.cloudKitMailbox(mac: mac.deviceID, phone: phoneID)
        cloudKit.addMailbox(zone)
        var out: [SimKind: String] = [.cloudkit: zone]
        if relay { out[.relay] = HostedRelayZones.mailbox(mac: mac.deviceID, phone: phoneID) }
        return out
    }

    private func fake(_ why: String) throws -> FakeHostedRelay {
        switch backend {
        case .fake(let relay): return relay
        }
    }

    /// The Go `ckMailbox`.
    static func cloudKitMailbox(mac: String, phone: String) -> String {
        "ck/\(mac)/\(phone)"
    }

    static func cloudKitData(_ mac: String) -> String {
        "ck/\(mac)"
    }

    static func signer(seed: UInt8) throws -> Ed25519RelaySigner {
        Ed25519RelaySigner(try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32)))
    }

    /// A registered, logged-in client of the device of `seed` on `backend`
    /// (`HostedRelayScenarioCase.makeClient`'s construction; a Mac is exempt from attestation on
    /// the fake, R18).
    static func client(_ backend: RelayBackend, kind: Relay_V1_DeviceKind, seed: UInt8) async throws -> HostedRelayClient {
        let signer = try signer(seed: seed)
        let relay: FakeHostedRelay
        switch backend {
        case .fake(let fake): relay = fake
        }
        if kind == .mac, case .enforce(let exempt) = relay.attestMode {
            relay.attestMode = .enforce(exemptDeviceIDs: exempt.union([RelayAuthMessages.deviceID(publicKey: signer.publicKey)]))
        }
        let client = HostedRelayClient(
            origin: try RelayOrigin(origin), signer: signer, kind: kind,
            attestor: RelayAttestor(attest: FakeAppAttest(), keys: InMemoryAppAttestKeyStore(), clock: relay.clock),
            http: relay.http, sockets: relay.sockets, clock: relay.clock
        ) { _ in .milliseconds(20) }
        _ = try await client.register()
        try await client.login()
        return client
    }
}

enum SimWorldError: Error {
    case noQuiescence
}
