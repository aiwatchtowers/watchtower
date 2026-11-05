import WatchtowerHostedRelay
import XCTest
@testable import WatchtowerMobile

/// `register_push` (relay client Phase 4 Task 13): once per process per token, never creating an identity, never
/// before the first foreground, a failure owed to the next `reachable()` or `foreground()`.
@MainActor
final class RelayPushRegistrarTests: XCTestCase {
    private struct SendFailed: Error {}

    private final class Wire {
        var identity = true
        var sent: [(token: String, environment: RelayPushEnvironment)] = []
        var failing = false
        /// Holds a send until `release()`.
        var gate: CheckedContinuation<Void, Never>?
        var holding = false

        func send(_ token: String, _ environment: RelayPushEnvironment) async throws {
            sent.append((token, environment))
            if holding {
                await withCheckedContinuation { gate = $0 }
            }
            if failing { throw SendFailed() }
        }

        func release() {
            gate?.resume()
            gate = nil
        }
    }

    private let token = Data([0x00, 0xAB, 0x12, 0xFF])
    private let tokenHex = "00ab12ff"
    private let available = RelayConfig.parse("https://relay.example.com").origin.map(RelayAvailability.available) ?? .off(.notConfigured)

    private func registrar(
        _ wire: Wire, availability: RelayAvailability? = nil, environment: RelayPushEnvironment? = .sandbox
    ) -> RelayPushRegistrar {
        RelayPushRegistrar(
            availability: availability ?? available, environment: environment, hasIdentity: { wire.identity }, send: wire.send
        )
    }

    private func settled(_ registrar: RelayPushRegistrar) async {
        while let sending = registrar.sending {
            await sending.value
        }
    }

    // MARK: - The rule

    func testTheTokenIsSentOnceAsHexWithItsEnvironment() async {
        let wire = Wire()
        let registrar = registrar(wire, environment: .production)
        registrar.foreground()
        registrar.tokenArrived(token)
        await settled(registrar)

        XCTAssertEqual(wire.sent.map(\.token), [tokenHex])
        XCTAssertEqual(wire.sent.map(\.environment), [.production])
        guard case .sent = registrar.state else { return XCTFail("\(registrar.state)") }

        registrar.tokenArrived(token)
        registrar.reachable()
        registrar.foreground()
        registrar.identityMayExist()
        await settled(registrar)
        XCTAssertEqual(wire.sent.count, 1, "once per process")
    }

    func testNoIdentityNoSendAndNoIdentityCreated() async throws {
        let spies = RelaySpies()
        let relay = spies.relay()
        let attestChecks = spies.attest.calls // The availability's support check, at build.
        let registrar = RelayPushRegistrar.live(relay: relay, environment: .sandbox)
        registrar.foreground()
        registrar.tokenArrived(token)
        registrar.reachable()
        registrar.identityMayExist()
        await settled(registrar)

        XCTAssertEqual(registrar.state, .idle)
        XCTAssertFalse(relay.isBuilt, "no session, so no signer")
        XCTAssertNil(try KeychainRelayIdentity(backend: spies.keychain, group: nil).existingSigner(), "no identity created")
        XCTAssertEqual(spies.attest.calls, attestChecks)
        XCTAssertEqual(spies.network.attempts, 0)
    }

    func testTheFirstIdentityThenSends() async {
        let wire = Wire()
        wire.identity = false
        let registrar = registrar(wire)
        registrar.foreground()
        registrar.tokenArrived(token)
        await settled(registrar)
        XCTAssertTrue(wire.sent.isEmpty)

        wire.identity = true
        registrar.identityMayExist()
        await settled(registrar)
        XCTAssertEqual(wire.sent.map(\.token), [tokenHex])
    }

    func testAFailureIsRetriedWhenReachableAndOnForeground() async {
        let wire = Wire()
        wire.failing = true
        let registrar = registrar(wire)
        registrar.foreground()
        registrar.tokenArrived(token)
        await settled(registrar)
        XCTAssertEqual(registrar.state, .failed)
        XCTAssertEqual(wire.sent.count, 1, "no retry by itself: no timer, no loop")

        registrar.reachable()
        await settled(registrar)
        XCTAssertEqual(wire.sent.count, 2)
        XCTAssertEqual(registrar.state, .failed)

        wire.failing = false
        registrar.foreground()
        await settled(registrar)
        XCTAssertEqual(wire.sent.count, 3)
        guard case .sent = registrar.state else { return XCTFail("\(registrar.state)") }
    }

    func testANewTokenIsSentAgain() async {
        let wire = Wire()
        let registrar = registrar(wire)
        registrar.foreground()
        registrar.tokenArrived(token)
        await settled(registrar)
        let first = registrar.state
        registrar.tokenArrived(Data([0x01, 0x02]))
        await settled(registrar)
        XCTAssertEqual(wire.sent.map(\.token), [tokenHex, "0102"])
        XCTAssertNotEqual(registrar.state, first)
    }

    func testATokenChangingDuringASendIsSentNext() async throws {
        let wire = Wire()
        wire.holding = true
        let registrar = registrar(wire)
        registrar.foreground()
        registrar.tokenArrived(token)
        try await poll({ wire.gate != nil }, "the first send never began")
        registrar.tokenArrived(Data([0x01, 0x02]))
        XCTAssertEqual(wire.sent.count, 1, "one send at a time")
        wire.holding = false
        wire.release()
        await settled(registrar)
        XCTAssertEqual(wire.sent.map(\.token), [tokenHex, "0102"])
    }

    func testANewProcessSendsAgain() async {
        let wire = Wire()
        for expected in 1...2 {
            let registrar = registrar(wire)
            registrar.foreground()
            registrar.tokenArrived(token)
            await settled(registrar)
            XCTAssertEqual(wire.sent.count, expected)
        }
    }

    func testANoEnvironmentBuildSendsNothing() async {
        let wire = Wire()
        let registrar = registrar(wire, environment: nil)
        registrar.foreground()
        registrar.tokenArrived(token)
        registrar.reachable()
        await settled(registrar)
        XCTAssertTrue(wire.sent.isEmpty)
        XCTAssertEqual(registrar.state, .idle)
    }

    // MARK: - A background launch

    /// A push launch stays frugal, as the account center's does: nothing goes out until the app is first active.
    func testABackgroundLaunchSendsNothingUntilTheFirstForeground() async {
        let wire = Wire()
        let registrar = registrar(wire)
        registrar.tokenArrived(token)
        registrar.identityMayExist()
        registrar.reachable()
        await settled(registrar)
        XCTAssertTrue(wire.sent.isEmpty)
        XCTAssertEqual(registrar.state, .idle)

        registrar.foreground()
        await settled(registrar)
        XCTAssertEqual(wire.sent.map(\.token), [tokenHex])
    }

    // MARK: - The dark ship

    func testAnEmptyOriginRegistersNoPush() async throws {
        let bed = try await Bed.make(self, on: .cloudKit, relayOff: true)
        bed.root.wireRelayPush(environment: .sandbox)
        XCTAssertNil(bed.root.relayPush, "the registrar is not built")

        AppDelegate.root = bed.root
        addTeardownBlock { @MainActor in AppDelegate.root = nil }
        AppDelegate.pushTokenArrived(token)
        await bed.root.becameActive().value
        XCTAssertFalse(bed.rootRelay.isBuilt)
        XCTAssertTrue(bed.fake.pushRegistrations.isEmpty)

        // Even one built by mistake refuses.
        let wire = Wire()
        let off = registrar(wire, availability: .off(.notConfigured))
        off.foreground()
        off.tokenArrived(token)
        await settled(off)
        XCTAssertTrue(wire.sent.isEmpty)

        // CloudKit's registration stays, and is the one that delivers the token.
        let source = try Self.appSource()
        XCTAssertTrue(source.contains("UIApplication.shared.registerForRemoteNotifications()"))
    }

    // MARK: - Secrets

    func testTheTokenIsNeverLogged() {
        struct Leaky: Error, CustomStringConvertible {
            let description: String
        }
        let error = Leaky(description: "refused token 00ab12ff")
        for text in [RelayPushRegistrar.failureLog(error), RelayPushRegistrar.registrationFailureLog(error)] {
            XCTAssertFalse(text.contains(tokenHex), text)
            XCTAssertFalse(text.contains("refused"), text)
        }
        XCTAssertEqual(RelayPushRegistrar.failureLog(error), "register_push failed: Leaky")
        XCTAssertEqual(
            RelayPushRegistrar.registrationFailureLog(NSError(domain: "x", code: 3010)),
            "APNs registration failed: code 3010")
        let state = RelayPushRegistrar.State.sent(tokenHash: RelayPushRegistrar.hash(tokenHex))
        XCTAssertFalse(String(describing: state).contains(tokenHex))
    }

    // MARK: - The wiring

    func testATokenBeforeTheRootWaitsInTheDelegate() async throws {
        let bed = try await Bed.make(self, on: .cloudKit)
        AppDelegate.root = nil
        AppDelegate.pushTokenArrived(token)

        bed.root.wireRelayPush(environment: .sandbox)
        let registrar = try XCTUnwrap(bed.root.relayPush)
        AppDelegate.root = bed.root
        addTeardownBlock { @MainActor in AppDelegate.root = nil }
        await bed.root.becameActive().value
        await settled(registrar)

        XCTAssertEqual(bed.fake.pushRegistrations.map(\.token), [tokenHex])
        XCTAssertEqual(bed.fake.pushRegistrations.map(\.environment), [.sandbox])
    }

    func testTheLiveSendGoesThroughTheAccountOnTheRelay() async throws {
        let bed = AccountBed()
        try await bed.register()
        let registrar = RelayPushRegistrar.live(relay: bed.relay, environment: .production)
        registrar.foreground()
        registrar.tokenArrived(token)
        await settled(registrar)
        XCTAssertEqual(bed.fake.pushRegistrations.map(\.token), [tokenHex])
        XCTAssertEqual(bed.fake.pushRegistrations.map(\.environment), [.production])
    }

    func testARefusedSendIsOwedLikeAnUnreachableRelay() async throws {
        let bed = AccountBed()
        try await bed.register()
        bed.fake.failNext("registerPush", with: .invalidTransaction)
        let registrar = RelayPushRegistrar.live(relay: bed.relay, environment: .sandbox)
        registrar.foreground()
        registrar.tokenArrived(token)
        await settled(registrar)
        XCTAssertEqual(registrar.state, .failed)

        registrar.reachable()
        await settled(registrar)
        XCTAssertEqual(bed.fake.pushRegistrations.map(\.token), [tokenHex])
    }

    /// The center is the one reader of the session's events, and its identity points are the registrar's.
    func testTheCenterForwardsReachableAndTheIdentityPoints() async throws {
        let bed = AccountBed()
        try await bed.register()
        let wire = Wire()
        let registrar = registrar(wire)
        let center = bed.makeCenter()
        center.pushRegistrar = registrar
        registrar.foreground()
        wire.failing = true
        registrar.tokenArrived(token)
        await settled(registrar)
        XCTAssertEqual(wire.sent.count, 1)

        center.start()
        bed.emit(.reachable(true))
        try await poll({ wire.sent.count == 2 }, "reachable was not forwarded")
        await settled(registrar)

        center.identityAppeared()
        await settled(registrar)
        XCTAssertEqual(wire.sent.count, 3, "an identity point reaches the registrar, the center already running")
    }

    /// The relay's silent body is `.hostedRelay` at the delegate; a CloudKit one is not.
    func testTheDelegateClassifiesASilentPushByItsTransport() {
        XCTAssertEqual(AppDelegate.pushScope(["aps": ["content-available": 1]]), .hostedRelay)
        XCTAssertNotEqual(AppDelegate.pushScope(["aps": ["content-available": 1], "ck": ["cid": "x"]]), .hostedRelay)
    }

    private static func appSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Sources/App/WatchtowerMobileApp.swift")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("the sources are out of reach") }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
