import Foundation
import os
@testable import WatchtowerHostedRelay
import WatchtowerHostedRelayTesting
import WatchtowerRelayProto
import XCTest

/// The Go client's WebSocket tests (`internal/hub/transport/relay/client`,
/// relay `sim/README.md` "The Go client"), same names and numbers, plus the
/// Swift client's own reconnect rules (relay `proto/README.md` "WebSocket").
final class HostedRelayConnectionTests: XCTestCase {
    /// A reconnect delay: anything shorter than the 10 s handshake timeout.
    private static let reconnectDelay: (Duration) -> Bool = { $0 < .seconds(10) }

    // MARK: - Go twins

    func testDialSendsAuthorizationHeader() async throws {
        let harness = try RelayClientHarness()
        let connection = await harness.client.connect(zones: [])
        let events = EventProbe(connection)
        let first = await events.next()
        XCTAssertEqual(first, .connected)

        let dial = try XCTUnwrap(harness.sockets.dials.first)
        XCTAssertEqual(dial.headers["Authorization"], "Bearer token-1")
        XCTAssertEqual(dial.url.absoluteString, "wss://relay.example.com/v1/ws")
        let hello = try XCTUnwrap(dial.socket?.sent.first).hello
        XCTAssertEqual(hello.protocolVersion, HostedRelay.protocolVersion)
        XCTAssertEqual(hello.sessionToken, "token-1")
        await connection.close()
        XCTAssertEqual(dial.socket?.closedWith, 1000)
    }

    func testClientPings30s() async throws {
        let harness = try RelayClientHarness()
        let connection = await harness.client.connect(zones: [])
        let events = EventProbe(connection)
        _ = await events.next()
        let socket = try XCTUnwrap(harness.sockets.sockets.first)

        for ping in 1...2 {
            await harness.clock.waitForSleep(.seconds(30))
            XCTAssertEqual(socket.pings, ping - 1)
            harness.clock.manual.advance(by: .seconds(29))
            XCTAssertEqual(socket.pings, ping - 1)
            harness.clock.manual.advance(by: .seconds(1))
            await socket.waitForPings(ping)
        }
        await connection.close()
    }

    func testDialRelogsInOn401() async throws {
        let harness = try RelayClientHarness()
        harness.sockets.script([.http(401)])
        let connection = await harness.client.connect(zones: [])
        let events = EventProbe(connection)
        let first = await events.next()
        XCTAssertEqual(first, .connected)

        XCTAssertEqual(harness.sockets.dials.map { $0.headers["Authorization"] }, ["Bearer token-1", "Bearer token-2"])
        XCTAssertEqual(harness.http.requests("login").count, 2)
        XCTAssertEqual(harness.clock.sleeps.filter(Self.reconnectDelay), [], "a 401 redials at once")
        await connection.close()
    }

    func testHelloMismatchRelogsIn() async throws {
        let harness = try RelayClientHarness()
        harness.sockets.script([.socket(ScriptedRelaySocket(hello: .close(4001)))])
        let connection = await harness.client.connect(zones: [])
        let events = EventProbe(connection)
        let first = await events.next()
        XCTAssertEqual(first, .connected)

        XCTAssertEqual(harness.http.requests("login").count, 2)
        XCTAssertEqual(harness.sockets.dials.count, 2)
        XCTAssertEqual(harness.sockets.dials.last?.headers["Authorization"], "Bearer token-2")
        await connection.close()
    }

    func testReconnectDelayAfterGoingAway() async throws {
        let harness = try RelayClientHarness()
        let connection = await harness.client.connect(zones: [])
        let events = EventProbe(connection)
        _ = await events.next()
        let socket = try XCTUnwrap(harness.sockets.sockets.first)

        socket.pushGoingAway()
        socket.closeFromServer(1001)
        let disconnected = await events.next()
        XCTAssertEqual(disconnected, .disconnected)
        let delay = await harness.clock.waitForSleep(where: Self.reconnectDelay)
        XCTAssert(delay >= .seconds(1) && delay <= .seconds(3), "delay \(delay)")
        harness.clock.manual.advance(by: delay - .milliseconds(1))
        XCTAssertEqual(harness.sockets.dials.count, 1, "reconnected before the delay")
        harness.clock.manual.advance(by: .milliseconds(1))
        let reconnected = await events.next()
        XCTAssertEqual(reconnected, .connected)
        XCTAssertEqual(harness.sockets.dials.count, 2)
        await connection.close()
    }

    func testCloseGoingAwayWithoutFrame() async throws {
        for frame in [false, true] {
            let calls = OSAllocatedUnfairLock(initialState: 0)
            let harness = try RelayClientHarness { calls.withLock { $0 += 1 } }
            let connection = await harness.client.connect(zones: [])
            let events = EventProbe(connection)
            _ = await events.next()
            let socket = try XCTUnwrap(harness.sockets.sockets.first)

            if frame { socket.pushGoingAway() }
            socket.closeFromServer(1001)
            let delay = await harness.clock.waitForSleep(where: Self.reconnectDelay)
            XCTAssert(delay >= .seconds(1) && delay <= .seconds(3), "frame \(frame): delay \(delay)")
            XCTAssertEqual(calls.withLock { $0 }, 1, "frame \(frame)")
            harness.clock.manual.advance(by: delay)
            await harness.sockets.waitForDials(2)
            XCTAssertEqual(calls.withLock { $0 }, 1, "frame \(frame)")
            await connection.close()
        }
    }

    // MARK: - Keepalive and close codes

    func testMissingPongClosesAndReconnects() async throws {
        let harness = try RelayClientHarness()
        harness.sockets.script([.socket(ScriptedRelaySocket(pongs: false))])
        let connection = await harness.client.connect(zones: [])
        let events = EventProbe(connection)
        _ = await events.next()
        let socket = try XCTUnwrap(harness.sockets.sockets.first)

        await harness.clock.waitForSleep(.seconds(30))
        harness.clock.manual.advance(by: .seconds(30))
        await socket.waitForPings(1)
        await harness.clock.waitForSleep(.seconds(10))
        harness.clock.manual.advance(by: .milliseconds(9_999))
        XCTAssertNil(socket.closedWith)
        harness.clock.manual.advance(by: .milliseconds(1))
        await socket.waitUntilClosedByClient()
        let disconnected = await events.next()
        XCTAssertEqual(disconnected, .disconnected)

        let delay = await harness.clock.waitForSleep(where: Self.reconnectDelay)
        XCTAssert(delay >= .milliseconds(250) && delay <= .milliseconds(500), "delay \(delay)")
        harness.clock.manual.advance(by: delay)
        let reconnected = await events.next()
        XCTAssertEqual(reconnected, .connected)
        XCTAssertEqual(harness.sockets.dials.count, 2)
        await connection.close()
    }

    func testClose4000StopsWithUnsupportedVersion() async throws {
        // Mid-connection.
        let harness = try RelayClientHarness()
        let connection = await harness.client.connect(zones: [])
        let events = EventProbe(connection)
        _ = await events.next()
        try XCTUnwrap(harness.sockets.sockets.first).closeFromServer(4000)
        let rest = await drain(events)
        XCTAssertEqual(rest, [.disconnected, .stopped(.unsupportedVersion)])
        XCTAssertEqual(harness.sockets.dials.count, 1)

        // At hello.
        let early = try RelayClientHarness()
        early.sockets.script([.socket(ScriptedRelaySocket(hello: .close(4000)))])
        let refused = await early.client.connect(zones: [])
        let refusedEvents = EventProbe(refused)
        let all = await drain(refusedEvents)
        XCTAssertEqual(all, [.stopped(.unsupportedVersion)])
        XCTAssertEqual(early.sockets.dials.count, 1)
        await connection.close()
        await refused.close()
    }

    func testAbnormalCloseKeepsExponentialBackoff() async throws {
        let harness = try RelayClientHarness()
        harness.sockets.script(Array(repeating: .socket(ScriptedRelaySocket(hello: .close(1006))), count: 3))
        let connection = await harness.client.connect(zones: [])
        let events = EventProbe(connection)

        let windows: [ClosedRange<Duration>] = [
            .milliseconds(250)...(.milliseconds(500)),
            .milliseconds(500)...(.seconds(1)),
            .seconds(1)...(.seconds(2))
        ]
        for (attempt, window) in windows.enumerated() {
            await harness.sockets.waitForDials(attempt + 1)
            let delay = await harness.clock.waitForSleep(where: Self.reconnectDelay)
            XCTAssert(window.contains(delay), "attempt \(attempt): \(delay) outside \(window)")
            harness.clock.manual.advance(by: delay)
        }
        let connected = await events.next()
        XCTAssertEqual(connected, .connected)
        XCTAssertEqual(harness.sockets.dials.count, 4)

        // A connection that reached HelloOk resets the attempt.
        try XCTUnwrap(harness.sockets.sockets.last).closeFromServer(1006)
        let disconnected = await events.next()
        XCTAssertEqual(disconnected, .disconnected)
        let delay = await harness.clock.waitForSleep(where: Self.reconnectDelay)
        XCTAssert(windows[0].contains(delay), "after HelloOk: \(delay)")
        await connection.close()
    }

    // MARK: - Subscriptions

    func testSubscribeWithoutAnswerCutsTheConnection() async throws {
        let harness = try RelayClientHarness()
        harness.sockets.script([.socket(ScriptedRelaySocket(subscribe: ["acme/a": .silent]))])
        let connection = await harness.client.connect(zones: ["acme/a"])
        let events = EventProbe(connection)
        _ = await events.next()
        let socket = try XCTUnwrap(harness.sockets.sockets.first)

        await harness.clock.waitForSleep(.seconds(10))
        harness.clock.manual.advance(by: .seconds(10))
        await socket.waitUntilClosedByClient()
        let disconnected = await events.next()
        XCTAssertEqual(disconnected, .disconnected)
        let delay = await harness.clock.waitForSleep(where: Self.reconnectDelay)
        harness.clock.manual.advance(by: delay)

        let again = await take(2, events)
        XCTAssertEqual(again, [.connected, .zoneChanged(zone: "acme/a", seq: 0)])
        XCTAssertEqual(harness.sockets.sockets.last?.subscribes, [["acme/a"]])
        await connection.close()
    }

    func testRefusedZoneIsDroppedAndReported() async throws {
        let harness = try RelayClientHarness()
        harness.sockets.script([.socket(ScriptedRelaySocket(subscribe: ["acme/b": .error(.forbidden)]))])
        let connection = await harness.client.connect(zones: ["acme/a", "acme/b", "acme/c"])
        let events = EventProbe(connection)

        let first = await take(4, events)
        XCTAssertEqual(first.first, .connected)
        let expected: [HostedRelayClientEvent] = [
            .zoneChanged(zone: "acme/a", seq: 0),
            .zoneRefused(zone: "acme/b", error: .server(code: .forbidden, retryAfter: nil)),
            .zoneChanged(zone: "acme/c", seq: 0)
        ]
        XCTAssertEqual(first.count, 4)
        for event in expected {
            XCTAssert(first.contains(event), "missing \(event) in \(first)")
        }
        let socket = try XCTUnwrap(harness.sockets.sockets.first)
        XCTAssertEqual(socket.subscribes, [["acme/a"], ["acme/b"], ["acme/c"]])

        // The refused zone is gone for good: the next connection subscribes the others only.
        socket.closeFromServer(1006)
        _ = await events.next()
        harness.clock.manual.advance(by: await harness.clock.waitForSleep(where: Self.reconnectDelay))
        let again = await take(3, events)
        XCTAssertEqual(again.first, .connected)
        XCTAssertEqual(harness.sockets.sockets.last?.subscribes, [["acme/a"], ["acme/c"]])
        await connection.close()
    }

    func testSubscribeSessionOrVersionErrorCutsAndKeepsTheZone() async throws {
        for code in [Relay_V1_ErrorCode.unauthenticated, .unsupportedVersion] {
            let harness = try RelayClientHarness()
            harness.sockets.script([.socket(ScriptedRelaySocket(subscribe: ["acme/a": .error(code)]))])
            let connection = await harness.client.connect(zones: ["acme/a"])
            let events = EventProbe(connection)

            let first = await take(2, events)
            XCTAssertEqual(first, [.connected, .disconnected], "\(code): cut, no refusal")
            let socket = try XCTUnwrap(harness.sockets.sockets.first)
            XCTAssertNotNil(socket.closedWith, "\(code)")
            harness.clock.manual.advance(by: await harness.clock.waitForSleep(where: Self.reconnectDelay))

            let again = await take(2, events)
            XCTAssertEqual(again, [.connected, .zoneChanged(zone: "acme/a", seq: 0)], "\(code): the zone is kept")
            XCTAssertEqual(harness.sockets.sockets.last?.subscribes, [["acme/a"]], "\(code)")
            await connection.close()
        }
    }

    /// A rate or traffic limit is "try again later": the zone is kept and the connection
    /// redials with backoff, so no zone goes quiet for good.
    func testSubscribeRateOrTrafficLimitCutsAndKeepsTheZone() async throws {
        for code in [Relay_V1_ErrorCode.rateLimited, .trafficLimitExceeded] {
            let harness = try RelayClientHarness()
            harness.sockets.script([
                .socket(ScriptedRelaySocket(subscribe: ["acme/a": .error(code)])),
                .socket(ScriptedRelaySocket(subscribe: ["acme/a": .error(code)]))
            ])
            let connection = await harness.client.connect(zones: ["acme/a"])
            let events = EventProbe(connection)

            // Two cuts in a row: the second redial waits longer although each reached HelloOk.
            let windows: [ClosedRange<Duration>] = [.milliseconds(250)...(.milliseconds(500)), .milliseconds(500)...(.seconds(1))]
            for window in windows {
                let first = await take(2, events)
                XCTAssertEqual(first, [.connected, .disconnected], "\(code): cut, no refusal")
                let delay = await harness.clock.waitForSleep(where: Self.reconnectDelay)
                XCTAssert(window.contains(delay), "\(code): \(delay) outside \(window)")
                harness.clock.manual.advance(by: delay)
            }

            let again = await take(2, events)
            XCTAssertEqual(again, [.connected, .zoneChanged(zone: "acme/a", seq: 0)], "\(code): the zone is kept")
            XCTAssertEqual(harness.sockets.sockets.last?.subscribes, [["acme/a"]], "\(code)")
            await connection.close()
        }
    }

    func testEventsAfterConnectAreRecordLessPerZone() async throws {
        let harness = try RelayClientHarness()
        let connection = await harness.client.connect(zones: ["acme/a", "acme/b"])
        let events = EventProbe(connection)

        let first = await take(3, events)
        XCTAssertEqual(first, [.connected, .zoneChanged(zone: "acme/a", seq: 0), .zoneChanged(zone: "acme/b", seq: 0)])
        let socket = try XCTUnwrap(harness.sockets.sockets.first)
        socket.pushZoneChanged("acme/a", seq: 5)
        socket.pushControl(.slotRemoved, detail: "mac-device")
        socket.pushZoneChanged("acme/other", seq: 9)  // not ours: never reported
        socket.pushControl(.sessionExpired)            // handled by the 4001 that follows, never reported
        let live = await take(2, events)
        XCTAssertEqual(live, [.zoneChanged(zone: "acme/a", seq: 5), .control(kind: .slotRemoved, detail: "mac-device")])

        socket.closeFromServer(1006)
        let disconnected = await events.next()
        XCTAssertEqual(disconnected, .disconnected)
        harness.clock.manual.advance(by: await harness.clock.waitForSleep(where: Self.reconnectDelay))
        let again = await take(3, events)
        XCTAssertEqual(again, [.connected, .zoneChanged(zone: "acme/a", seq: 0), .zoneChanged(zone: "acme/b", seq: 0)])
        await connection.close()
    }

    func testFullBufferFoldsZoneEventsAndKeepsControls() async throws {
        let harness = try RelayClientHarness()
        let connection = await harness.client.connect(zones: ["acme/a", "acme/b"], eventBuffer: 2)
        let events = EventProbe(connection)
        _ = await take(3, events)
        let socket = try XCTUnwrap(harness.sockets.sockets.first)

        // Nobody reads meanwhile: the reader must not wait for room.
        socket.pushZoneChanged("acme/a", seq: 1)
        socket.pushZoneChanged("acme/a", seq: 2)
        socket.pushZoneChanged("acme/b", seq: 3)
        socket.pushControl(.slotRemoved, detail: "one")
        socket.pushZoneChanged("acme/a", seq: 4)
        socket.pushControl(.pairingOpened, detail: "two")
        socket.pushZoneChanged("acme/b", seq: 5)
        await socket.waitUntilDrained()

        let delivered = await take(6, events)
        XCTAssertEqual(delivered, [
            .zoneChanged(zone: "acme/a", seq: 1),
            .zoneChanged(zone: "acme/a", seq: 2),
            .control(kind: .slotRemoved, detail: "one"),
            .control(kind: .pairingOpened, detail: "two"),
            .zoneChanged(zone: "acme/b", seq: 0),
            .zoneChanged(zone: "acme/a", seq: 0)
        ])
        await connection.close()
    }

    /// A zone event carries the relay's `records`; an older relay's single `record` is the one record. An
    /// event folded for lack of room loses them: its reader pulls.
    func testZoneEventsCarryTheirRecordsUnlessFolded() async throws {
        let harness = try RelayClientHarness()
        let connection = await harness.client.connect(zones: ["acme/a"], eventBuffer: 2)
        let events = EventProbe(connection)
        _ = await take(2, events)
        let socket = try XCTUnwrap(harness.sockets.sockets.first)
        func record(_ name: String, _ seq: UInt64) -> Relay_V1_Record {
            var record = Relay_V1_Record()
            record.zone = "acme/a"
            record.name = name
            record.envelope = Data(name.utf8)
            record.recordSeq = seq
            return record
        }

        socket.pushZoneChanged("acme/a", seq: 2, records: [record("x", 1), record("y", 2)])
        socket.pushZoneChanged("acme/a", seq: 3, record: record("z", 3))
        socket.pushZoneChanged("acme/a", seq: 4, records: [record("w", 4)], record: record("w", 4))
        await socket.waitUntilDrained()

        let delivered = await take(3, events)
        XCTAssertEqual(delivered, [
            .zoneChanged(zone: "acme/a", seq: 2, records: [record("x", 1), record("y", 2)]),
            .zoneChanged(zone: "acme/a", seq: 3, records: [record("z", 3)]),
            .zoneChanged(zone: "acme/a", seq: 0)
        ])
        await connection.close()
    }

    func testSetZonesSubscribesOnlyTheNewZones() async throws {
        let harness = try RelayClientHarness()
        let connection = await harness.client.connect(zones: ["acme/a"])
        let events = EventProbe(connection)
        _ = await take(2, events)
        let socket = try XCTUnwrap(harness.sockets.sockets.first)

        await connection.setZones(["acme/b"])
        let added = await events.next()
        XCTAssertEqual(added, .zoneChanged(zone: "acme/b", seq: 0))
        XCTAssertEqual(socket.subscribes, [["acme/a"], ["acme/b"]])
        socket.pushZoneChanged("acme/a", seq: 3)  // removed: no longer reported
        socket.pushZoneChanged("acme/b", seq: 4)
        let live = await events.next()
        XCTAssertEqual(live, .zoneChanged(zone: "acme/b", seq: 4))
        await connection.close()
    }

    func testSendIsAnsweredByID() async throws {
        let harness = try RelayClientHarness()
        let connection = await harness.client.connect(zones: [])
        let events = EventProbe(connection)
        _ = await events.next()

        let response = try await connection.send(RelayClientHarness.removeSlot)
        XCTAssertEqual(response.ok, Relay_V1_Ok())
        let request = try XCTUnwrap(harness.sockets.sockets.first?.sent.last).request
        XCTAssertEqual(response.id, request.id)
        XCTAssertGreaterThan(request.id, 0)
        XCTAssertEqual(harness.http.requests("removeSlot").count, 0, "over the socket, not HTTPS")

        await connection.close()
        await assertRelayError(.unreachable) { _ = try await connection.send(RelayClientHarness.removeSlot) }
        let end = await events.next()
        XCTAssertNil(end)
    }

    // MARK: - Attestation inside the reconnect loop

    func testAttestationRetryLaterSpacesTheRedials() async throws {
        let harness = try RelayClientHarness()
        harness.fake.script(.generateAssertion, failures: [.serverUnavailable, .serverUnavailable, .serverUnavailable])
        let start = harness.clock.now()
        let connection = await harness.client.connect(zones: [])
        let events = EventProbe(connection)

        for want in [Duration.seconds(1), .seconds(2), .seconds(4)] {
            let delay = await harness.clock.waitForSleep(where: Self.reconnectDelay)
            XCTAssertEqual(delay, want)
            XCTAssertEqual(harness.sockets.dials.count, 0)
            harness.clock.manual.advance(by: delay)
        }
        let connected = await events.next()
        XCTAssertEqual(connected, .connected)
        XCTAssertEqual(harness.http.requests("challenge").count, 4)
        XCTAssertEqual(harness.sockets.dials.map(\.at), [start.addingTimeInterval(7)])
        await connection.close()
    }

    func testAttestationUpdateRequiredStopsTheConnection() async throws {
        let harness = try RelayClientHarness()
        let connection = await harness.client.connect(zones: [])
        let events = EventProbe(connection)
        _ = await events.next()

        harness.http.script("login", [.error(.attestationRequired)])
        try XCTUnwrap(harness.sockets.sockets.first).closeFromServer(4001)
        let disconnected = await events.next()
        XCTAssertEqual(disconnected, .disconnected)
        harness.clock.manual.advance(by: await harness.clock.waitForSleep(where: Self.reconnectDelay))
        let rest = await drain(events)
        XCTAssertEqual(rest, [.stopped(.attestation(.updateRequired))])
        XCTAssertEqual(harness.sockets.dials.count, 1)
        XCTAssertEqual(harness.http.requests("login").count, 2)
        await connection.close()
    }

    // MARK: - Wake (live link R6)

    /// A pong within the wake's 300 ms keeps the socket: no second dial, the same generation.
    func testProbeAnsweredKeepsSocket() async throws {
        XCTAssertEqual(HostedRelayConnection.wakePingDeadline, .milliseconds(300))
        let harness = try RelayClientHarness()
        let socket = ScriptedRelaySocket()
        harness.sockets.script([.socket(socket)])
        let connection = await harness.client.connect(zones: [])
        let events = EventProbe(connection)
        let first = await events.next()
        XCTAssertEqual(first, .connected)

        await connection.wake()

        XCTAssertEqual(socket.pings, 1)
        XCTAssertNil(socket.closedWith)
        XCTAssertEqual(harness.sockets.dials.count, 1)
        XCTAssertEqual(connection.liveGeneration, 1)
        await connection.close()
    }

    /// No pong within 300 ms: the old socket is dropped at once and the wake returns, its dial still running (it
    /// hangs for 5 s): a request is refused before the write (so it goes over HTTPS) without the clock moving. The
    /// dial completing later takes over with no `disconnected` and no backoff; a late pong of the old socket changes
    /// nothing.
    func testProbeSilentDialsInParallelAndFirstReadyWins() async throws {
        let harness = try RelayClientHarness()
        let old = ScriptedRelaySocket(pongs: false)
        let new = ScriptedRelaySocket()
        harness.sockets.script([.socket(old), .delayed(.seconds(5), new)])
        let connection = await harness.client.connect(zones: [])
        let events = EventProbe(connection)
        let first = await events.next()
        XCTAssertEqual(first, .connected)

        let woke = OSAllocatedUnfairLock(initialState: false)
        Task {
            await connection.wake()
            woke.withLock { $0 = true }
        }
        await harness.clock.waitForSleep(.milliseconds(300))
        harness.clock.manual.advance(by: .milliseconds(300))
        // The clock does not move again: the wake must return with its dial still out.
        var returned = false
        for _ in 0..<20_000 where !returned {
            returned = woke.withLock { $0 }
            await Task.yield()
        }
        guard returned else {
            XCTFail("the wake waited for its dial")
            harness.clock.manual.advance(by: .seconds(5))
            return await connection.close()
        }

        XCTAssertNil(connection.liveGeneration, "the silent socket is dropped at once")
        do {
            _ = try await connection.request(RelayClientHarness.removeSlot)
            XCTFail("written to a dropped socket")
        } catch {
            XCTAssertEqual(error as? HostedRelayConnection.SocketLoss, .notSent, "refused before the write: HTTPS")
        }
        await old.waitUntilClosedByClient()
        XCTAssertEqual(old.closedWith, 1000)

        await harness.clock.waitForSleep(.seconds(5))
        harness.clock.manual.advance(by: .seconds(5))
        let next = await events.next()
        XCTAssertEqual(next, .connected, "the new socket takes over, with no disconnect in between")
        XCTAssertEqual(connection.liveGeneration, 2)
        old.pong()
        XCTAssertEqual(connection.liveGeneration, 2, "a late pong of the old socket changes nothing")
        _ = try await connection.send(RelayClientHarness.removeSlot)
        XCTAssertTrue(new.sent.contains { if case .removeSlot? = $0.request.op { true } else { false } })
        XCTAssertEqual(harness.sockets.dials.count, 2, "no third dial")
        await connection.close()
        XCTAssertEqual(new.closedWith, 1000)
    }

    /// The write chain is per socket: the new socket's subscribe goes out although the old socket's subscribe write
    /// is stuck for good (not ended by the close or the cancel).
    func testANewSocketsWritesAreNotHeldByAStuckOldWrite() async throws {
        let harness = try RelayClientHarness()
        let old = ScriptedRelaySocket(pongs: false, stuckWrites: true)
        let new = ScriptedRelaySocket()
        harness.sockets.script([.socket(old), .delayed(.milliseconds(100), new)])
        let connection = await harness.client.connect(zones: ["acme/a"])
        let events = EventProbe(connection)
        _ = await events.next()
        await spin { old.stuckCount == 1 }

        let wake = Task { await connection.wake() }
        await harness.clock.waitForSleep(.milliseconds(300))
        harness.clock.manual.advance(by: .milliseconds(300))
        await wake.value
        await harness.clock.waitForSleep(.milliseconds(100))
        harness.clock.manual.advance(by: .milliseconds(100))
        let up = await events.next()
        XCTAssertEqual(up, .connected)

        var subscribed = false
        for _ in 0..<50_000 where !subscribed {
            subscribed = new.sent.contains { if case .subscribe? = $0.request.op { true } else { false } }
            await Task.yield()
        }
        XCTAssertTrue(subscribed, "the new socket's subscribe waited on the old socket's stuck write")
        old.releaseStuck()
        await connection.close()
    }

    /// Writes stay in order past a cancelled one: A is stuck in its send, B (queued behind it) is cancelled, C is
    /// queued behind B. C's frame is written only once A's send has returned.
    func testACancelledQueuedWriteDoesNotLetTheNextOvertake() async throws {
        let harness = try RelayClientHarness()
        let socket = ScriptedRelaySocket(stuckWrites: true)
        harness.sockets.script([.socket(socket)])
        let connection = await harness.client.connect(zones: [])
        let events = EventProbe(connection)
        _ = await events.next()
        func requests() -> Int {
            socket.sent.filter { if case .request = $0.kind { true } else { false } }.count
        }

        let first = Task { try await connection.request(RelayClientHarness.removeSlot) }
        let second = Task<Relay_V1_Response, any Error> {
            _ = await self.settles { socket.stuckCount == 1 }
            return try await connection.request(RelayClientHarness.removeSlot)
        }
        // B is queued (registered behind A) before it is cancelled; C is queued behind B before the check.
        let queuedB = await settles { socket.stuckCount == 1 && connection.pendingRequests == 2 }
        second.cancel()
        _ = await second.result
        let third = Task { try await connection.request(RelayClientHarness.removeSlot) }
        let queuedC = await settles { connection.pendingRequests == 2 }
        guard queuedB, queuedC else {
            XCTFail("the requests were not queued (B \(queuedB), C \(queuedC))")
            socket.releaseStuck()
            return await connection.close()
        }
        // Nothing observable marks "C is still held": give a write that would overtake every chance to land.
        _ = await settles { requests() > 0 }
        XCTAssertEqual(requests(), 0, "C was written while A was still in its send")

        socket.releaseStuck()
        _ = await first.result
        let written = await settles { requests() == 1 }
        XCTAssertTrue(written, "C goes out once A's send returned; B was never written")
        _ = await third.result
        await connection.close()
    }

    /// A's send stays blocked while the socket is retired: the cancelled writes queued behind it stop waiting for it
    /// (their chain settles) before A is released.
    func testARetiredSocketEndsTheSkippedWritesWaits() async throws {
        try await assertSkippedWritesEnd { connection in
            guard let generation = connection.liveGeneration else { return XCTFail("no live socket") }
            connection.detach(generation)
        }
    }

    /// The same when the connection is closed with A's send still blocked.
    func testACloseEndsTheSkippedWritesWaits() async throws {
        try await assertSkippedWritesEnd { await $0.close() }
    }

    private func assertSkippedWritesEnd(
        after end: (HostedRelayConnection) async -> Void, line: UInt = #line
    ) async throws {
        let harness = try RelayClientHarness()
        let socket = ScriptedRelaySocket(stuckWrites: true)
        harness.sockets.script([.socket(socket)])
        let connection = await harness.client.connect(zones: [])
        let events = EventProbe(connection)
        _ = await events.next()
        defer { socket.releaseStuck() }

        let first = Task { try await connection.request(RelayClientHarness.removeSlot) }
        let second = Task<Relay_V1_Response, any Error> {
            _ = await self.settles { socket.stuckCount == 1 }
            return try await connection.request(RelayClientHarness.removeSlot)
        }
        let queued = await settles { socket.stuckCount == 1 && connection.pendingRequests == 2 }
        XCTAssertTrue(queued, "B was not queued behind A", line: line)
        second.cancel()
        _ = await second.result
        XCTAssertFalse(connection.lastWriteSettled, "B's skipped write still waits for A", line: line)

        await end(connection)

        let settled = await settles { connection.lastWriteSettled }
        XCTAssertTrue(settled, "the skipped write still waits for A's blocked send", line: line)
        XCTAssertEqual(socket.stuckCount, 1, "A's send is still blocked", line: line)
        socket.releaseStuck()
        _ = await first.result
        // A detached socket is no longer the connection's to close: end its reader so `close()` returns.
        socket.closeFromServer(1006)
        await connection.close()
    }

    /// A body that ignores the cancel and finishes before the race sees it: the cancelled caller still gets no
    /// value, which goes to `discard` (whichever of the two the race meets first).
    func testACancelledDeadlineDiscardsAValueItsBodyReturnsAnyway() async throws {
        let harness = try RelayClientHarness()
        let connection = await harness.client.connect(zones: [])
        let held = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)
        let caller = OSAllocatedUnfairLock<Task<Int?, any Error>?>(initialState: nil)
        let discarded = OSAllocatedUnfairLock<[Int]>(initialState: [])
        let race = Task {
            try await connection.deadline(.seconds(7), discard: { (value: Int) in discarded.withLock { $0.append(value) } }, {
                await withCheckedContinuation { continuation in held.withLock { $0 = continuation } }
                // Cancels its own caller and returns at once.
                caller.withLock { $0 }?.cancel()
                return 7
            })
        }
        caller.withLock { $0 = race }
        let out = await settles { held.withLock { $0 != nil } }
        XCTAssertTrue(out, "the body never started")
        held.withLock { $0 }?.resume()
        let result = await race.result
        XCTAssertThrowsError(try result.get(), "a cancelled caller gets no value")
        XCTAssertEqual(discarded.withLock { $0 }, [7])
        await connection.close()
    }

    /// A `deadline` whose caller is cancelled while its body (a dial) is still out hands the value the body returns
    /// later to `discard`: a late socket is closed, not dropped open.
    func testACancelledDeadlineDiscardsWhatItsBodyReturnsLate() async throws {
        let harness = try RelayClientHarness()
        let connection = await harness.client.connect(zones: [])
        let held = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)
        let discarded = OSAllocatedUnfairLock<[Int]>(initialState: [])
        let race = Task {
            try await connection.deadline(.seconds(7), discard: { (value: Int) in discarded.withLock { $0.append(value) } }, {
                // Not ended by the cancel, like a dial that ignores it.
                await withCheckedContinuation { continuation in held.withLock { $0 = continuation } }
                return 7
            })
        }
        let out = await settles { held.withLock { $0 != nil } }
        XCTAssertTrue(out, "the body never started")
        await harness.clock.waitForSleep(.seconds(7))
        race.cancel()
        // The race has seen the cancel (its clock sleep ended) before the body returns.
        await harness.clock.waitForSleeps(.seconds(7), count: 0)
        held.withLock { $0 }?.resume()
        let result = await race.result
        XCTAssertThrowsError(try result.get(), "a cancelled race throws")
        XCTAssertEqual(discarded.withLock { $0 }, [7], "the late value was dropped, not discarded")
        await connection.close()
    }

    /// The second dial hangs past the handshake timeout: the loop stops waiting for it and dials again at once; the
    /// socket the hung dial produces later is closed, never live.
    func testAHungSecondDialIsGivenUpAfterTheHandshakeTimeout() async throws {
        let harness = try RelayClientHarness()
        let old = ScriptedRelaySocket(pongs: false)
        let late = ScriptedRelaySocket()
        let third = ScriptedRelaySocket()
        harness.sockets.script([.socket(old), .held(late), .socket(third)])
        defer { harness.sockets.releaseHeld() }
        let connection = await harness.client.connect(zones: [])
        let events = EventProbe(connection)
        _ = await events.next()

        let wake = Task { await connection.wake() }
        await harness.clock.waitForSleep(.milliseconds(300))
        harness.clock.manual.advance(by: .milliseconds(300))
        await wake.value
        // The redial is in its upgrade (the dial is out), under the wake's timer and the upgrade's own deadline.
        let dialling = await settles { harness.sockets.heldCount == 1 }
        XCTAssertTrue(dialling, "the redial never dialled")
        await harness.clock.waitForSleeps(HostedRelayConnection.handshakeTimeout, count: 2)
        harness.clock.manual.advance(by: HostedRelayConnection.handshakeTimeout)

        let down = await events.next()
        XCTAssertEqual(down, .disconnected)
        let up = await events.next()
        XCTAssertEqual(up, .connected, "dialled again with no backoff")
        XCTAssertEqual(harness.sockets.dials.count, 3)
        // The hung dial returns its socket at last: closed, never greeted, the loop's socket untouched.
        harness.sockets.releaseHeld()
        let closed = await settles { late.closedWith != nil }
        XCTAssertTrue(closed, "the given-up redial's late socket was left open")
        XCTAssertEqual(late.closedWith, 1000)
        XCTAssertTrue(late.sent.isEmpty, "the given-up redial never said Hello")
        XCTAssertEqual(connection.liveGeneration, 2)
        XCTAssertNil(third.closedWith)
        await connection.close()
    }

    /// The second dial fails while the old socket is silent: the wake returns at once (no 10 s wait), the old socket
    /// is retired so requests go over HTTPS, and the loop dials again with no backoff.
    func testAFailedSecondDialRetiresTheSilentSocketAtOnce() async throws {
        let harness = try RelayClientHarness()
        let old = ScriptedRelaySocket(pongs: false)
        let third = ScriptedRelaySocket()
        harness.sockets.script([.socket(old), .unreachable, .socket(third)])
        let connection = await harness.client.connect(zones: [])
        let events = EventProbe(connection)
        _ = await events.next()

        let wake = Task { await connection.wake() }
        await harness.clock.waitForSleep(.milliseconds(300))
        harness.clock.manual.advance(by: .milliseconds(300))
        await wake.value

        XCTAssertEqual(old.closedWith, 1000)
        let down = await events.next()
        XCTAssertEqual(down, .disconnected)
        let up = await events.next()
        XCTAssertEqual(up, .connected, "redialled with no backoff (the clock did not move)")
        XCTAssertEqual(harness.sockets.dials.count, 3)
        XCTAssertNil(third.closedWith)
        await connection.close()
    }

    /// A wake while the loop waits out a reconnect backoff dials at once.
    func testAWakeDuringBackoffDialsNow() async throws {
        let harness = try RelayClientHarness()
        let first = ScriptedRelaySocket()
        harness.sockets.script([.socket(first)])
        let connection = await harness.client.connect(zones: [])
        let events = EventProbe(connection)
        _ = await events.next()

        first.closeFromServer(1006)
        let down = await events.next()
        XCTAssertEqual(down, .disconnected)
        await harness.clock.waitForSleep(where: Self.reconnectDelay)
        await connection.wake()

        let up = await events.next()
        XCTAssertEqual(up, .connected, "dialled without waiting out the backoff")
        XCTAssertEqual(harness.sockets.dials.count, 2)
        await connection.close()
    }

    /// The old socket's serve ends before the replacement says `HelloOk` and the connection closes meanwhile: the
    /// replacement is closed, never made live.
    func testARedialAfterCloseClosesTheReplacement() async throws {
        let harness = try RelayClientHarness()
        let old = ScriptedRelaySocket(pongs: false)
        let new = ScriptedRelaySocket(hello: .silent)
        harness.sockets.script([.socket(old), .socket(new)])
        let connection = await harness.client.connect(zones: [])
        let events = EventProbe(connection)
        _ = await events.next()

        let wake = Task { await connection.wake() }
        await harness.clock.waitForSleep(.milliseconds(300))
        harness.clock.manual.advance(by: .milliseconds(300))
        await spin { new.sent.contains { if case .hello = $0.kind { true } else { false } } }
        await connection.close()
        await wake.value

        XCTAssertEqual(new.closedWith, 1000)
        XCTAssertNil(connection.liveGeneration)
    }

    // MARK: - Helpers

    /// Whether `condition` comes to hold within a bounded number of yields: false, never a hang, when it does not.
    private func settles(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<50_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    private func take(_ count: Int, _ events: EventProbe, line: UInt = #line) async -> [HostedRelayClientEvent] {
        var taken: [HostedRelayClientEvent] = []
        while taken.count < count, let event = await events.next(line: line) {
            taken.append(event)
        }
        return taken
    }

    /// Every event up to the end of the stream.
    private func drain(_ events: EventProbe, line: UInt = #line) async -> [HostedRelayClientEvent] {
        var taken: [HostedRelayClientEvent] = []
        while let event = await events.next(line: line) {
            taken.append(event)
        }
        return taken
    }
}
