import CryptoKit
import Foundation
import os
import WatchtowerHostedRelay
import WatchtowerHostedRelayTesting
import WatchtowerRelayProto
import XCTest

/// Where scenario tests run: `.fake` builds a `FakeHostedRelay`; `.stand(URL)`
/// (Task 12) the local stand.
enum RelayBackend {
    case fake(FakeHostedRelay)
}

/// The base of the relay scenario classes: real `HostedRelayClient`s on a backend,
/// devices from fixed seeds, the Go interop helpers (`hub`, `save`, `connect`).
/// The base runs on `FakeHostedRelay` in enforce mode (test Macs exempt, R18);
/// Task 12 subclasses it for the stand, where fake-only scenarios skip (R15).
class HostedRelayScenarioCase: XCTestCase {
    static let origin = "https://relay.example.com"
    /// The Go interop tests' `quickBackoff`.
    static let quickBackoff: @Sendable (Int) -> Duration = { _ in .milliseconds(20) }
    /// Sleeps the pump may skip: reconnect waits, backoffs and retries, never the 10 s
    /// handshake / pong deadlines or the 30 s ping interval.
    static let pumpedSleeps = Duration.seconds(10)

    private var madeBackend: RelayBackend?
    /// The fake's clock (relay and clients); nil on the stand.
    private(set) var manualClock: ManualRelayClock?
    private var attests: [UInt8: FakeAppAttest] = [:]
    private var connections: [HostedRelayConnection] = []

    override func setUp() async throws {
        try await super.setUp()
        madeBackend = try makeBackend()
    }

    override func tearDown() async throws {
        for connection in connections { await connection.close() }
        connections = []
        try await super.tearDown()
    }

    /// The backend `setUp` made.
    var backend: RelayBackend {
        guard let madeBackend else { preconditionFailure("HostedRelayScenarioCase: backend used before setUp") }
        return madeBackend
    }

    /// The backend of this class: the fake. Task 12's stand subclass overrides it.
    func makeBackend() throws -> RelayBackend {
        let clock = ManualRelayClock()
        manualClock = clock
        return .fake(FakeHostedRelay(origin: Self.origin, attest: .enforce(exemptDeviceIDs: []), clock: clock))
    }

    /// The server's `/dev` controls.
    var stand: any RelayStandControl {
        switch backend {
        case .fake(let relay): return relay
        }
    }

    /// The fake, or `XCTSkip` on the stand with `why` (R15).
    func requireFake(_ why: String) throws -> FakeHostedRelay {
        switch backend {
        case .fake(let relay): return relay
        }
    }

    /// One wait step: on the fake, moves the clock to the next short sleep (a reconnect
    /// wait or a backoff), so the client goes on without wall-clock time.
    var pump: @Sendable () -> Void {
        guard let clock = manualClock else { return {} }
        return { _ = clock.advanceToNextSleeper(shorterThan: Self.pumpedSleeps) }
    }

    // MARK: - Devices

    /// The `FakeAppAttest` of the device of `seed` (made on first use).
    func fakeAttest(seed: UInt8) -> FakeAppAttest {
        let attest = attests[seed] ?? FakeAppAttest()
        attests[seed] = attest
        return attest
    }

    /// A client for the device of `seed` (one `FakeAppAttest` per seed, so a second client
    /// of the same device keeps the assertion counter). `register`: register and log in,
    /// like the Go `device`. A Mac is exempt from attestation on the fake (R18). `wrapHTTP`
    /// puts a test's `RelayHTTP` in front of the backend's.
    func makeClient(
        kind: Relay_V1_DeviceKind,
        seed: UInt8,
        keys: (any AppAttestKeyStore)? = nil,
        register: Bool = true,
        wrapHTTP: ((any RelayHTTP) -> any RelayHTTP)? = nil,
        onGoingAway: (@Sendable () -> Void)? = nil
    ) async throws -> HostedRelayClient {
        let attest = fakeAttest(seed: seed)
        let signer = Ed25519RelaySigner(try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32)))
        let http: any RelayHTTP
        let sockets: any RelaySocketDialer
        let clock: any RelayClock
        switch backend {
        case .fake(let relay):
            http = relay.http
            sockets = relay.sockets
            clock = relay.clock
            if kind == .mac, case .enforce(let exempt) = relay.attestMode {
                relay.attestMode = .enforce(exemptDeviceIDs: exempt.union([RelayAuthMessages.deviceID(publicKey: signer.publicKey)]))
            }
        }
        let client = HostedRelayClient(
            origin: try RelayOrigin(Self.origin),
            signer: signer,
            kind: kind,
            attestor: RelayAttestor(attest: attest, keys: keys ?? InMemoryAppAttestKeyStore(), clock: clock),
            http: wrapHTTP?(http) ?? http,
            sockets: sockets,
            clock: clock,
            backoff: Self.quickBackoff,
            onGoingAway: onGoingAway
        )
        if register {
            _ = try await client.register()
            try await client.login()
        }
        return client
    }

    /// The Go `hub`: a Mac paired with a paying phone. A scenario that also runs on the
    /// stand, which keeps its state between tests, picks seeds no other test uses.
    func hub(
        mac macSeed: UInt8 = 1, phone phoneSeed: UInt8 = 2, phoneHTTP: ((any RelayHTTP) -> any RelayHTTP)? = nil
    ) async throws -> (mac: HostedRelayClient, phone: HostedRelayClient) {
        let phone = try await makeClient(kind: .phone, seed: phoneSeed, wrapHTTP: phoneHTTP)
        let mac = try await makeClient(kind: .mac, seed: macSeed)
        try await pay(phone)
        try await stand.pair(mac: mac.deviceID, phones: [phone.deviceID])
        return (mac, phone)
    }

    func pay(_ phone: HostedRelayClient) async throws {
        let account = try await stand.accountID(ofPhone: phone.deviceID)
        try await stand.setEntitlement(accountID: account, state: "active", for: .seconds(365 * 86_400))
    }

    // MARK: - Ops

    static func saveOp(_ zone: String, _ name: String) -> Relay_V1_Request.OneOf_Op {
        var item = Relay_V1_SaveItem()
        item.record.zone = zone
        item.record.name = name
        item.record.envelope = Data(name.utf8)
        var save = Relay_V1_Save()
        save.items = [item]
        return .save(save)
    }

    static func changesOp(_ zone: String, since: UInt64 = 0) -> Relay_V1_Request.OneOf_Op {
        var changes = Relay_V1_Changes()
        changes.zone = zone
        changes.sinceSeq = since
        return .changes(changes)
    }

    /// Saves one record over HTTPS (envelope = its name) and returns its seq.
    @discardableResult
    func save(_ client: HostedRelayClient, _ zone: String, _ name: String) async throws -> UInt64 {
        guard case .save(let result) = try await client.perform(Self.saveOp(zone, name)).result,
              let saved = result.saved.first
        else { throw ScenarioFailure.unexpected("save \(name)") }
        return saved.recordSeq
    }

    // MARK: - Connections

    /// Connects and returns a probe on its events (pumping the fake's clock); the
    /// connection is closed at tear-down.
    func connect(
        _ client: HostedRelayClient, _ zones: [String], eventBuffer: Int = 256
    ) async -> (HostedRelayConnection, EventProbe) {
        let connection = await client.connect(zones: zones, eventBuffer: eventBuffer)
        connections.append(connection)
        return (connection, EventProbe(connection, pump: pump))
    }

    /// The Go `nextZoneEvent`: the seq of the next `zoneChanged` of `zone` (0 = record-less),
    /// skipping other events; nil when none came within the probe's cap.
    func nextZoneEvent(_ events: EventProbe, _ zone: String, file: StaticString = #filePath, line: UInt = #line) async -> UInt64? {
        while let event = await events.next(file: file, line: line) {
            if case .zoneChanged(zone, let seq) = event { return seq }
        }
        return nil
    }

    /// Reads events until `wanted`; false when the stream ended or the cap passed first.
    @discardableResult
    func waitFor(
        _ wanted: HostedRelayClientEvent, _ events: EventProbe, file: StaticString = #filePath, line: UInt = #line
    ) async -> Bool {
        while let event = await events.next(file: file, line: line) {
            if event == wanted { return true }
        }
        return false
    }

    /// Spins (pumping the fake's clock) until `condition` holds, 5 s cap.
    @discardableResult
    func eventually(file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping () -> Bool) async -> Bool {
        let pump = pump
        return await spin(file: file, line: line) {
            if condition() { return true }
            pump()
            return false
        }
    }

    enum ScenarioFailure: Error {
        case unexpected(String)
    }
}
