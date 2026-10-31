import Foundation
import os
@testable import WatchtowerHostedRelay
import WatchtowerHostedRelayTesting
import SwiftProtobuf
import WatchtowerRelayProto
import XCTest

// The scenario classes again, on the local stand (`make relay-interop-kit RELAY=<relay
// checkout>`, which sets WATCHTOWER_RELAY_INTEROP_URL): the real `URLSessionRelayHTTP`,
// `URLSessionRelaySocketDialer` and real time for the clients, the stand's `/dev` endpoints for
// the controls. Without the variable (public CI) every test here skips in `setUp`.
// Scenarios that need the fake's log, faults or clock skip on the stand with their reason (R15).

final class HostedRelayClientInteropTests: HostedRelayClientScenarios {
    override func makeBackend() throws -> RelayBackend {
        try RelayBackend.standFromEnvironment()
    }
}

final class HostedRelayTransportInteropTests: HostedRelayTransportTests {
    override func makeBackend() throws -> RelayBackend {
        try RelayBackend.standFromEnvironment()
    }
}

final class RelaySimOrderInteropTests: RelaySimOrderTwins {
    override func makeBackend() throws -> RelayBackend {
        try RelayBackend.standFromEnvironment()
    }
}

final class RelaySimSwitchInteropTests: RelaySimSwitchTwins {
    override func makeBackend() throws -> RelayBackend {
        try RelayBackend.standFromEnvironment()
    }
}

/// The production socket seam against the stand (the Task 5 review's interop checklist):
/// it opens, a refused upgrade is `.http(status: 401)`, the relay's 4000/4001 close codes
/// survive (R13), and an idle socket outlives the 40 s an intermediary might cut it at, kept
/// by the 30 s pings.
final class RelaySocketInteropTests: HostedRelayScenarioCase {
    override func makeBackend() throws -> RelayBackend {
        try RelayBackend.standFromEnvironment()
    }

    private var socketURL: URL {
        get throws {
            var parts = try XCTUnwrap(URLComponents(url: try backend.origin.url, resolvingAgainstBaseURL: false))
            parts.scheme = parts.scheme == "https" ? "wss" : "ws"
            parts.path = "/v1/ws"
            return try XCTUnwrap(parts.url)
        }
    }

    /// `URLSessionRelaySocketDialer` opens a socket the stand accepts: the client gets
    /// `.connected` and a request answered over it.
    func testURLSessionDialerOpens() async throws {
        let phone = try await makeClient(kind: .phone, seed: 50)
        let (connection, events) = await connect(phone, [])
        let connected = await waitFor(.connected, events)
        XCTAssertTrue(connected)
        guard case .accountState = try await connection.send(.getAccountState(Relay_V1_GetAccountState())).result else {
            return XCTFail("account state")
        }
    }

    /// A bearer the stand does not know: the upgrade is refused with HTTP 401.
    func testRefusedUpgradeIsHTTP401() async throws {
        do {
            _ = try await URLSessionRelaySocketDialer().dial(try socketURL, headers: ["Authorization": "Bearer not-a-session"])
            XCTFail("the stand opened a socket for an unknown token")
        } catch let error as RelayDialError {
            XCTAssertEqual(error, .http(status: 401))
        }
    }

    /// The relay's own close codes come through `URLSessionWebSocketTask` by raw value (R13):
    /// a `Hello` whose token is not the upgrade's closes with 4001, an unknown protocol
    /// version with 4000.
    func testCustomCloseCodesSurviveURLSession() async throws {
        let phone = try await makeClient(kind: .phone, seed: 52)
        let token = try await phone.sessionToken(stale: nil)
        for (version, helloToken, code) in [(HostedRelay.protocolVersion, "not-this-session", 4001), (UInt32(999), token, 4000)] {
            let socket = try await URLSessionRelaySocketDialer().dial(try socketURL, headers: ["Authorization": "Bearer \(token)"])
            var frame = Relay_V1_Frame()
            frame.hello.protocolVersion = version
            frame.hello.sessionToken = helloToken
            try await socket.send(try frame.serializedData())
            var closed: Int?
            while closed == nil {
                if case .closed(let got) = try await socket.receive() { closed = got }
            }
            XCTAssertEqual(closed, code, "version \(version)")
            await socket.close(code: 1000)
        }
    }

    /// An idle socket stays up past 40 s (pings every 30 s) and still answers requests.
    func testIdleSocketOutlivesFortySeconds() async throws {
        let phone = try await makeClient(kind: .phone, seed: 51)
        let connection = await phone.connect(zones: [])
        addTeardownBlock { await connection.close() }
        let seen = OSAllocatedUnfairLock<[HostedRelayClientEvent]>(initialState: [])
        let reader = Task {
            for await event in connection.events {
                seen.withLock { $0.append(event) }
            }
        }
        defer { reader.cancel() }
        await spin { seen.withLock { $0.contains(.connected) } }

        try await Task.sleep(for: .seconds(45))
        XCTAssertEqual(seen.withLock { $0 }, [.connected], "the idle socket dropped")
        guard case .accountState = try await connection.send(.getAccountState(Relay_V1_GetAccountState())).result else {
            return XCTFail("account state after 45 s idle")
        }
    }
}
