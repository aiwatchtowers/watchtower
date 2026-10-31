import Foundation
import os
import WatchtowerHostedRelay
import WatchtowerHostedRelayTesting
import WatchtowerRelayProto
import XCTest

/// The Go client's interop scenarios (relay@3a99bd7 `client/client_interop_test.go`),
/// same names, on real `HostedRelayClient`s against the scenario backend. A record-less
/// `ZoneChanged` is `seq == 0` (the Swift event carries no record). Deploy, crash and
/// session-expiry faults run on the fake only (R15).
class HostedRelayClientScenarios: HostedRelayScenarioCase {
    static let r15 = "needs the server deployed, crashed or a session cut short (fake only, R15)"

    /// A deploy closes the socket with 1001 and no GoingAway frame; the client reconnects,
    /// subscribes again, announces the gap with a record-less event and gets live events again.
    func testReconnectAfterGoingAway() async throws {
        let relay = try requireFake(Self.r15)
        let (mac, phone) = try await hub()
        let zone = "data/\(mac.deviceID)"
        let (connection, events) = await connect(phone, [zone])
        let subscribed = await nextZoneEvent(events, zone)
        XCTAssertEqual(subscribed, 0)

        let before = try await save(mac, zone, "before")
        let live = await nextZoneEvent(events, zone)
        XCTAssertEqual(live, before)

        relay.deploy()
        let resync = await nextZoneEvent(events, zone)
        XCTAssertEqual(resync, 0, "a record-less resync event after the reconnect")
        let after = try await save(mac, zone, "after")
        let again = await nextZoneEvent(events, zone)
        XCTAssertEqual(again, after)

        // Requests flow over the new connection too.
        guard case .changes(let page) = try await connection.send(Self.changesOp(zone)).result else { return XCTFail("changes") }
        XCTAssertEqual(page.changed.map(\.name), ["before", "after"])
    }

    /// The session ends: the socket gets SESSION_EXPIRED and 4001, HTTPS gets UNAUTHENTICATED;
    /// the client logs in again by itself in both cases.
    func testReloginOnSessionExpired() async throws {
        let relay = try requireFake(Self.r15)
        let (mac, phone) = try await hub()
        let zone = "data/\(mac.deviceID)"
        let (_, events) = await connect(phone, [zone])
        let subscribed = await nextZoneEvent(events, zone)
        XCTAssertEqual(subscribed, 0)

        relay.expireSessions(of: phone.deviceID)
        relay.expireSessions(of: mac.deviceID)
        let resync = await nextZoneEvent(events, zone)
        XCTAssertEqual(resync, 0, "a record-less resync event after the relogin")
        let after = try await save(mac, zone, "after")
        let live = await nextZoneEvent(events, zone)
        XCTAssertEqual(live, after)
        XCTAssertEqual(logins(relay, of: phone.deviceID), 2)
        XCTAssertEqual(logins(relay, of: mac.deviceID), 2)
    }

    /// An error response comes back as `.server` with its code.
    func testDoReturnsProtocolErrors() async throws {
        let phone = try await makeClient(kind: .phone, seed: 30)
        await assertRelayError(.server(code: .forbidden, retryAfter: nil)) {
            _ = try await phone.perform(Self.changesOp("data/nope"))
        }
    }

    /// After a reconnect each zone is subscribed on its own; a zone that is no longer readable
    /// is dropped and reported, the others keep their live events.
    func testResubscribeDropsOnlyRefusedZone() async throws {
        let relay = try requireFake(Self.r15)
        let (mac, phone) = try await hub()
        let data = "data/\(mac.deviceID)"
        let mailbox = "relay/\(mac.deviceID)/\(phone.deviceID)"
        let (_, events) = await connect(phone, [data, mailbox])
        let first = await nextZoneEvent(events, mailbox)
        XCTAssertEqual(first, 0)

        // The hub stops sharing its data zone with the phone.
        _ = try await mac.perform(.setHubReaders(Relay_V1_SetHubReaders()))
        relay.deploy()
        var refused = false
        var resynced = false
        while !refused || !resynced, let event = await events.next() {
            switch event {
            case let .zoneRefused(zone, error):
                XCTAssertEqual(zone, data)
                XCTAssertEqual(error, .server(code: .forbidden, retryAfter: nil))
                refused = true
            case .zoneChanged(mailbox, 0) where refused:
                resynced = true
            default:
                break
            }
        }
        XCTAssertTrue(refused && resynced, "refused \(refused) resynced \(resynced)")

        let after = try await save(mac, mailbox, "after")
        let live = await nextZoneEvent(events, mailbox)
        XCTAssertEqual(live, after)
    }

    /// With nobody reading events, responses still arrive; zone events that do not fit
    /// are replaced by a record-less one once there is room.
    func testFullEventBufferNeverBlocksReader() async throws {
        let (mac, phone) = try await hub(mac: 31, phone: 32)
        let zone = "data/\(mac.deviceID)"
        let (connection, events) = await connect(phone, [zone], eventBuffer: 1)
        let subscribed = await nextZoneEvent(events, zone)
        XCTAssertEqual(subscribed, 0)

        var seqs: [UInt64] = []
        for name in ["r1", "r2", "r3", "r4"] { seqs.append(try await save(mac, zone, name)) }
        // The response comes after the four events on the socket: the reader went past them.
        let since = seqs[0] - 1
        guard case .changes(let page) = try await connection.send(Self.changesOp(zone, since: since)).result else { return XCTFail("changes") }
        XCTAssertEqual(page.changed.map(\.name), ["r1", "r2", "r3", "r4"])

        var seen: [UInt64] = []
        while let seq = await nextZoneEvent(events, zone) {
            seen.append(seq)
            if seq == 0 { break }
        }
        XCTAssertEqual(seen.last, 0, "the marker for the dropped events")
        XCTAssertFalse(seen.contains(seqs[3]), "the buffer of 1 should have overflowed")
    }

    /// The callback runs for every GoingAway: a deploy (1001 without a frame) and a
    /// displacement by a newer connection of the same device (GoingAway, then 1001).
    func testOnGoingAwayCallback() async throws {
        for (index, trigger) in ["deploy", "displacement"].enumerated() {
            if trigger == "deploy", (try? requireFake(Self.r15)) == nil { continue }
            let calls = OSAllocatedUnfairLock(initialState: 0)
            let client = try await makeClient(kind: .phone, seed: 20 + UInt8(index)) { calls.withLock { $0 += 1 } }
            let (_, events) = await connect(client, [])
            let connected = await waitFor(.connected, events)
            XCTAssertTrue(connected, trigger)
            if trigger == "deploy" {
                try requireFake(Self.r15).deploy()
            } else {
                _ = await connect(client, [])
            }
            let called = await eventually { calls.withLock { $0 } >= 1 }
            XCTAssertTrue(called, "no GoingAway callback on \(trigger)")
        }
    }

    /// A writer sends 200 records over its socket and the server is redeployed halfway;
    /// every write the server acknowledged is there, and writes are acknowledged after it.
    func testNoAckedWriteLostAcrossDeploy() async throws {
        let relay = try requireFake(Self.r15)
        try await noAckedWriteLost { relay.deploy() }
    }

    /// As `testNoAckedWriteLostAcrossDeploy`, but the server crashes halfway (every
    /// connection cut) and comes back on the same state.
    func testNoAckedWriteLostAcrossCrash() async throws {
        let relay = try requireFake(Self.r15)
        try await noAckedWriteLost {
            relay.crash()
            relay.restart()
        }
    }

    /// The server applies a save and dies before answering: the client reports the write as
    /// unacknowledged (`.unreachable`), and a reader still finds the record.
    func testCrashAfterSaveLeavesTheWriteUnacknowledged() async throws {
        let relay = try requireFake(Self.r15)
        let (mac, phone) = try await hub()
        let zone = "data/\(mac.deviceID)"
        let (writer, writerEvents) = await connect(mac, [])
        let connected = await waitFor(.connected, writerEvents)
        XCTAssertTrue(connected)

        relay.crashAfterNext("save")
        await assertRelayError(.unreachable) { _ = try await writer.send(Self.saveOp(zone, "unacked")) }
        relay.restart()
        let page = try await phone.changes(Self.changesRequest(zone, since: 0))
        XCTAssertEqual(page.changed.map(\.name), ["unacked"])
    }

    /// A fresh device registers and logs in with App Attest (enforce mode on the fake:
    /// a fresh attestation at register, an assertion at login) and its writes land.
    func testRegisterLoginAndSaveOnAFreshDevice() async throws {
        let (mac, phone) = try await hub(mac: 33, phone: 34)
        let zone = "data/\(mac.deviceID)"
        let seq = try await save(mac, zone, "fresh")
        let page = try await phone.changes(Self.changesRequest(zone, since: seq - 1))
        XCTAssertEqual(page.changed.map(\.name), ["fresh"])
        XCTAssertEqual(page.changed.first?.recordSeq, seq)
        XCTAssertEqual(page.changed.first?.envelope, Data("fresh".utf8))

        guard case .fake(let relay) = backend else { return }
        XCTAssertEqual(registerKinds(relay, of: phone.deviceID), [.appAttest])
        XCTAssertEqual(loginKinds(relay, of: phone.deviceID), [.assertion])
    }

    /// The App Attest key id is lost (a reinstall): the login attests a fresh key, and the
    /// relay takes it (enforce mode on the fake; on the stand the login only has to succeed).
    func testLostAppAttestKeyLogsInWithAFreshAttestation() async throws {
        let phone = try await makeClient(kind: .phone, seed: 35)
        let reinstalled = try await makeClient(kind: .phone, seed: 35, keys: InMemoryAppAttestKeyStore(), register: false)
        XCTAssertEqual(reinstalled.deviceID, phone.deviceID)
        try await reinstalled.login()
        _ = try await reinstalled.accountState()
        try await reinstalled.login()

        guard case .fake(let relay) = backend else { return }
        XCTAssertEqual(loginKinds(relay, of: phone.deviceID), [.assertion, .appAttest, .assertion])
    }

    // MARK: - Helpers

    private func noAckedWriteLost(disrupt: () -> Void) async throws {
        let total = 200
        let (mac, phone) = try await hub()
        let zone = "data/\(mac.deviceID)"
        let (reader, readerEvents) = await connect(phone, [zone])
        let subscribed = await nextZoneEvent(readerEvents, zone)
        XCTAssertEqual(subscribed, 0)
        let (writer, writerEvents) = await connect(mac, [])
        let connected = await waitFor(.connected, writerEvents)
        XCTAssertTrue(connected)

        var acked: Set<String> = []
        var ackedAfter = 0
        var disrupted = false
        for index in 0..<total {
            if !disrupted, acked.count == total / 2 {
                disrupt()
                disrupted = true
            }
            let name = String(format: "w%03d", index)
            do {
                guard case .save(let result) = try await writer.send(Self.saveOp(zone, name)).result, result.saved.count == 1 else { continue }
                acked.insert(name)
                if disrupted { ackedAfter += 1 }
            } catch {
                // Not acknowledged: lost or refused. On to the next one once the writer is back.
                await waitFor(.connected, writerEvents)
            }
        }
        XCTAssertTrue(disrupted, "the writer never reached half of its writes")
        XCTAssertGreaterThan(ackedAfter, 0, "no write acknowledged after the disruption")

        // The reader is back: its record-less resync event says so; then it pulls the whole zone.
        while let seq = await nextZoneEvent(readerEvents, zone), seq != 0 {}
        var got: [String: Data] = [:]
        var since: UInt64 = 0
        while true {
            guard case .changes(let page) = try await reader.send(Self.changesOp(zone, since: since)).result else {
                return XCTFail("changes")
            }
            for record in page.changed { got[record.name] = record.envelope }
            since = page.newSeq
            if !page.more { break }
        }
        for name in acked.sorted() where got[name] != Data(name.utf8) {
            XCTFail("acknowledged write \(name) lost")
        }
    }

    private static func changesRequest(_ zone: String, since: UInt64) -> Relay_V1_Changes {
        var changes = Relay_V1_Changes()
        changes.zone = zone
        changes.sinceSeq = since
        return changes
    }

    private enum AttestationKind: Equatable {
        case none, appAttest, assertion
    }

    private static func kind(_ attestation: Relay_V1_Attestation) -> AttestationKind {
        switch attestation.kind {
        case .appAttest: return .appAttest
        case .appAttestAssertion: return .assertion
        case nil: return .none
        }
    }

    private func logins(_ relay: FakeHostedRelay, of deviceID: String) -> Int {
        loginKinds(relay, of: deviceID).count
    }

    private func loginKinds(_ relay: FakeHostedRelay, of deviceID: String) -> [AttestationKind] {
        relay.log.compactMap { op in
            guard case .login(let login) = op, login.deviceID == deviceID else { return nil }
            return Self.kind(login.attestation)
        }
    }

    private func registerKinds(_ relay: FakeHostedRelay, of deviceID: String) -> [AttestationKind] {
        relay.log.compactMap { op in
            guard case .register(let register) = op, RelayAuthMessages.deviceID(publicKey: register.authPub) == deviceID else { return nil }
            return Self.kind(register.attestation)
        }
    }
}
