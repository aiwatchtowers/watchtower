import Foundation
import WatchtowerHostedRelay
import WatchtowerHostedRelayTesting
import WatchtowerRelayProto
import XCTest

/// The Go client's HTTPS tests (`internal/hub/transport/relay/client`), same
/// names and numbers.
final class HostedRelayClientTests: XCTestCase {
    func testDefaultBackoffJitteredUpTo60s() {
        for attempt in 0..<30 {
            let ceil = min(Duration.milliseconds(500) * (1 << min(attempt, 8)), .seconds(60))
            for _ in 0..<50 {
                let delay = HostedRelayClient.defaultBackoff(attempt)
                XCTAssert(delay >= ceil / 2 && delay <= ceil, "attempt \(attempt): \(delay) outside [\(ceil / 2), \(ceil)]")
            }
        }
        let seen = Set((0..<50).map { _ in HostedRelayClient.defaultBackoff(10) })
        XCTAssertGreaterThan(seen.count, 1, "no jitter")
    }

    func testRegisterAsksForRegisterNonce() async throws {
        let harness = try RelayClientHarness(storedKey: false)
        let deviceID = try await harness.client.register()

        XCTAssertEqual(deviceID, harness.client.deviceID)
        XCTAssertEqual(harness.http.ops, ["challenge", "register"])
        let challenge = try XCTUnwrap(harness.http.requests.first).request.challenge
        XCTAssertEqual(challenge.purpose, .register)
        XCTAssertEqual(challenge.deviceID, harness.client.deviceID)
        let register = try XCTUnwrap(harness.http.requests.last).request.register
        XCTAssertEqual(register.nonce, ScriptedRelayHTTP.nonce)
        let accountID = await harness.client.accountID
        XCTAssertEqual(accountID, "acme-account")
    }

    func testLoginUnsupportedVersion() async throws {
        let harness = try RelayClientHarness()
        harness.http.script("challenge", [.error(.unsupportedVersion, status: 400)])
        await assertRelayError(.unsupportedVersion) { try await harness.client.login() }
        XCTAssertEqual(harness.http.ops, ["challenge"])
        XCTAssertEqual(harness.clock.sleeps, [])
    }

    func testRetryOnUnavailable() async throws {
        let harness = try RelayClientHarness()
        harness.http.script("removeSlot", [.error(.unavailable), .error(.unavailable)])
        let call = Task { try await harness.client.perform(RelayClientHarness.removeSlot) }
        for want in [Duration.milliseconds(500), .seconds(1)] {
            await harness.clock.manual.waitForSleepers(1)
            XCTAssertEqual(harness.clock.sleeps.last, want)
            harness.clock.manual.advance(by: want)
        }
        let response = try await call.value
        XCTAssertEqual(response.ok, Relay_V1_Ok())
        XCTAssertEqual(harness.http.requests("removeSlot").count, 3)
        XCTAssertEqual(harness.clock.sleeps, [.milliseconds(500), .seconds(1)])
    }

    func testRetryGivesUpAfter30s() async throws {
        let harness = try RelayClientHarness()
        harness.http.script("removeSlot", Array(repeating: .error(.unavailable), count: 20))
        let start = harness.clock.now()
        let call = Task { try await harness.client.perform(RelayClientHarness.removeSlot) }
        let want: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(8), .milliseconds(6500)]
        for (index, delay) in want.enumerated() {
            await harness.clock.manual.waitForSleepers(1)
            XCTAssertEqual(harness.clock.sleeps.count, index + 1)
            XCTAssertEqual(harness.clock.sleeps.last, delay)
            harness.clock.manual.advance(by: delay)
        }
        await assertRelayError(.server(code: .unavailable, retryAfter: nil)) { _ = try await call.value }
        XCTAssertEqual(harness.clock.now().timeIntervalSince(start), 30)
        XCTAssertEqual(harness.http.requests("removeSlot").count, want.count + 1)
    }

    func testDoReturnsProtocolErrors() async throws {
        let harness = try RelayClientHarness()
        harness.http.script("removeSlot", [
            .error(.forbidden, retryAfter: 7),
            .raw(status: 500, body: Data()),
            .raw(status: 200, body: Data([0xFF, 0xFF, 0xFF]))
        ])
        await assertRelayError(.server(code: .forbidden, retryAfter: 7)) {
            _ = try await harness.client.perform(RelayClientHarness.removeSlot)
        }
        await assertRelayError(.undecodable(status: 500)) {
            _ = try await harness.client.perform(RelayClientHarness.removeSlot)
        }
        await assertRelayError(.undecodable(status: 200)) {
            _ = try await harness.client.perform(RelayClientHarness.removeSlot)
        }
        XCTAssertEqual(harness.http.requests("removeSlot").count, 3)
        XCTAssertEqual(harness.http.requests("login").count, 1)
    }

    func testUnauthenticatedRelogsInOnceAndRetries() async throws {
        let harness = try RelayClientHarness()
        harness.http.script("removeSlot", [.error(.unauthenticated, status: 401)])
        _ = try await harness.client.perform(RelayClientHarness.removeSlot)
        XCTAssertEqual(harness.http.ops, ["challenge", "login", "removeSlot", "challenge", "login", "removeSlot"])
        XCTAssertEqual(harness.http.requests("removeSlot").map { $0.headers["Authorization"] }, ["Bearer token-1", "Bearer token-2"])

        // A refusal after the relogin is returned: one relogin and one retry per op.
        harness.http.script("removeSlot", [.error(.unauthenticated, status: 401), .error(.unauthenticated, status: 401)])
        await assertRelayError(.server(code: .unauthenticated, retryAfter: nil)) {
            _ = try await harness.client.perform(RelayClientHarness.removeSlot)
        }
        XCTAssertEqual(harness.http.requests("removeSlot").count, 4)
        XCTAssertEqual(harness.http.requests("login").count, 3)
    }

    func testConcurrentCallersShareOneLogin() async throws {
        let harness = try RelayClientHarness()
        harness.http.gate("challenge")
        let calls = (0..<5).map { _ in
            Task { try await harness.client.perform(RelayClientHarness.removeSlot) }
        }
        await harness.http.waitForGated(1)
        for _ in 0..<200 { await Task.yield() }
        XCTAssertEqual(harness.http.requests("challenge").count, 1)
        harness.http.release()
        for call in calls { _ = try await call.value }

        XCTAssertEqual(harness.http.requests("challenge").count, 1)
        XCTAssertEqual(harness.http.requests("login").count, 1)
        XCTAssertEqual(harness.http.requests("removeSlot").map { $0.headers["Authorization"] }, Array(repeating: "Bearer token-1", count: 5))
    }

    func testRequestsCarryTheProtocolHeaderAndBearer() async throws {
        let harness = try RelayClientHarness(storedKey: false)
        _ = try await harness.client.register()
        _ = try await harness.client.perform(RelayClientHarness.removeSlot)
        XCTAssertEqual(harness.http.ops, ["challenge", "register", "challenge", "login", "removeSlot"])
        for recorded in harness.http.requests {
            XCTAssertEqual(recorded.url.absoluteString, "https://relay.example.com/v1/op")
            XCTAssertEqual(recorded.headers["Content-Type"], "application/x-protobuf")
            XCTAssertEqual(recorded.headers["Relay-Protocol-Version"], "1")
            let bearer = recorded.op == "removeSlot" ? "Bearer token-1" : nil
            XCTAssertEqual(recorded.headers["Authorization"], bearer, recorded.op)
        }
    }

    func testTokensAreNeverInErrorDescriptions() async throws {
        let harness = try RelayClientHarness()
        let token = "secret-session-token-0001"
        var response = Relay_V1_Response()
        response.session.token = token
        harness.http.script("login", [.ok(response)])
        harness.http.script("removeSlot", [
            .error(.forbidden),
            .error(.unauthenticated, status: 401),
            .raw(status: 502, body: Data([0xFF, 0xFF])),
            .failure(URLError(.timedOut))
        ])
        var errors: [any Error] = []
        for _ in 0..<4 {
            do {
                _ = try await harness.client.perform(RelayClientHarness.removeSlot)
            } catch {
                errors.append(error)
            }
        }
        XCTAssertEqual(errors.compactMap { $0 as? HostedRelayError }, [
            .server(code: .forbidden, retryAfter: nil),
            .undecodable(status: 502),
            .unreachable
        ])
        XCTAssertEqual(harness.http.requests("removeSlot").first?.headers["Authorization"], "Bearer \(token)")
        for error in errors {
            for text in [String(describing: error), String(reflecting: error), error.localizedDescription] {
                XCTAssertFalse(text.contains(token), text)
                XCTAssertFalse(text.contains("token-1"), text)
            }
        }
    }

    func testReloginWhenTheSharedLoginIssuesTheRefusedToken() async throws {
        let harness = try RelayClientHarness()
        var reissued = Relay_V1_Response()
        reissued.session.token = "reissued-token"
        harness.http.script("login", [.ok(reissued), .ok(reissued)])
        harness.http.script("removeSlot", [.error(.unauthenticated, status: 401)])
        _ = try await harness.client.perform(RelayClientHarness.removeSlot)

        // Refused with "reissued-token", the relogin got the very same token back: a real login follows.
        XCTAssertEqual(harness.http.requests("login").count, 3)
        XCTAssertEqual(
            harness.http.requests("removeSlot").map { $0.headers["Authorization"] },
            ["Bearer reissued-token", "Bearer token-1"]
        )
    }

    func testCancellationIsNotUnreachable() async throws {
        let harness = try RelayClientHarness()
        harness.http.script("removeSlot", [.failure(URLError(.cancelled))])
        do {
            _ = try await harness.client.perform(RelayClientHarness.removeSlot)
            XCTFail("expected CancellationError")
        } catch {
            XCTAssert(error is CancellationError, "got \(error)")
        }

        // A cancelled caller whose request then fails in transport sees the cancellation.
        harness.http.script("removeSlot", [.failure(URLError(.networkConnectionLost))])
        harness.http.gate("removeSlot")
        let call = Task { try await harness.client.perform(RelayClientHarness.removeSlot) }
        await harness.http.waitForGated(1)
        call.cancel()
        harness.http.release()
        do {
            _ = try await call.value
            XCTFail("expected CancellationError")
        } catch {
            XCTAssert(error is CancellationError, "got \(error)")
        }
    }
}
