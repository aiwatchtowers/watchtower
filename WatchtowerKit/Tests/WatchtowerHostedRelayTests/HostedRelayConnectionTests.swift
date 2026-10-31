import Foundation
import os
import WatchtowerHostedRelay
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

    // MARK: - Helpers

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
