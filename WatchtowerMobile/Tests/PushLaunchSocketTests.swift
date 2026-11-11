import Foundation
import WatchtowerE2ETesting
import WatchtowerHostedRelay
import WatchtowerRelayProto
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// A push launch opens no relay socket until the app is opened (board target #1559): a session booted in the background
/// on the relay route fetches over HTTPS, logging in when it must, and its first activation starts the transport as a
/// foreground launch does. Sockets are counted on `FakeHostedRelay` through `Bed`'s `SocketCounter`.
@MainActor
final class PushLaunchSocketTests: XCTestCase {
    /// Long enough for a socket a boot wanted to be dialed: a count of zero must not pass by being read early.
    private func letAnyDialLand() async throws {
        try await Task.sleep(for: .milliseconds(200))
    }

    private func has(_ bed: Bed, _ session: HubSession, _ id: String) -> Bool {
        (try? bed.briefings(session))?.contains { $0.contains(id) } ?? false
    }

    func testAPushLaunchOpensNoSocket() async throws {
        let bed = try await Bed.make(self, on: .relay, startsActive: false)
        let session = try bed.session()
        try await bed.publishBriefings(["pushed"], on: .relay)

        let outcome = await session.handlePush(inForeground: false)
        await session.waitForBoot()
        try await letAnyDialLand()

        XCTAssertNotEqual(outcome, .failed)
        XCTAssertTrue(has(bed, session, "pushed"), "the data came over HTTPS")
        XCTAssertEqual(bed.sockets.dials, 0, "no socket before the app is opened")
    }

    func testTheFirstActivationConnects() async throws {
        let bed = try await Bed.make(self, on: .relay, startsActive: false)
        let session = try bed.session()
        _ = await session.handlePush(inForeground: false)
        await session.waitForBoot()
        try await letAnyDialLand()
        XCTAssertEqual(bed.sockets.dials, 0)
        try await bed.publishBriefings(["waiting"], on: .relay)

        bed.root.env.setActive(true)

        try await poll({ bed.sockets.dials == 1 }, "the first activation connects")
        try await poll({ self.has(bed, session, "waiting") }, "and pulls")

        // From here the socket behaves as today, into the background and on a later push too.
        bed.root.env.setActive(false)
        try await bed.publishBriefings(["later"], on: .relay)
        _ = await session.handlePush(inForeground: false)
        bed.root.env.setActive(true)
        try await letAnyDialLand()
        XCTAssertTrue(has(bed, session, "later"))
        XCTAssertEqual(bed.sockets.dials, 1, "one socket: a later activation or push dials no other")
        XCTAssertEqual(bed.sockets.mostOpenAtOnce, 1)
    }

    func testAnActivationDuringAFetchLosesNoPull() async throws {
        let gate = DataReadGate()
        let bed = try await Bed.make(self, on: .relay, startsActive: false, relayHTTP: gate.wrap)
        addTeardownBlock { gate.release() }
        let session = try bed.session()
        try await bed.publishBriefings(["before"], on: .relay)
        let push = Task { await session.handlePush(inForeground: false) }
        try await poll({ gate.isHolding }, "the fetch reached the relay")
        XCTAssertEqual(bed.sockets.dials, 0)

        // The held read has its answer already: this record is only for the pull the activation owes.
        try await bed.publishBriefings(["during"], on: .relay)
        bed.root.env.setActive(true)
        try await poll({ bed.sockets.dials == 1 }, "the activation connects during the fetch")
        gate.release()
        _ = await push.value
        await session.waitForBoot()

        try await poll({ self.has(bed, session, "during") }, "no pull lost")
        XCTAssertEqual(bed.sockets.mostOpenAtOnce, 1)
    }

    func testAForegroundLaunchConnectsAsToday() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let session = try bed.session()
        await session.waitForBoot()

        try await poll({ bed.sockets.dials == 1 }, "a foreground launch connects in its boot, with no activation")
        bed.root.env.setActive(true)
        try await letAnyDialLand()
        XCTAssertEqual(bed.sockets.dials, 1)
    }

    /// Refused, unavailable (Apple's server), or App Attest gone; the push before or after the launch fetch began: a
    /// `.failed` fetch, no socket, the data waiting for the next open.
    func testARefusedAssertionOnAPushLaunchIsFailed() async throws {
        for refusal in [LockedPhoneAttest.Refusal.fails(.other("test")), .fails(.serverUnavailable), .notSupported] {
            for pushBeforeTheLaunchFetch in [true, false] {
                let (session, sockets) = try makeRelaySessionWithoutLogin(LockedPhoneAttest(refusal))
                if !pushBeforeTheLaunchFetch { await session.waitForBoot() }

                let outcome = await session.handlePush(inForeground: false)
                await session.waitForBoot()
                try await letAnyDialLand()

                let what = "\(refusal), push first \(pushBeforeTheLaunchFetch)"
                XCTAssertEqual(outcome, .failed, what)
                XCTAssertEqual(outcome.backgroundFetchResult, .failed, what)
                XCTAssertEqual(sockets.dials, 0, what)
            }
        }
    }

    func testACloudKitSessionStartsItsEngineInTheBackgroundAsToday() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("no-\(UUID().uuidString)")
        let cloud = CloudSide(inner: RecordingCloud(), marker: marker)
        let session = try makeSession(transport: cloud, store: nil, route: .cloudKit(.private))
        await session.waitForBoot()
        let starts = await cloud.starts
        XCTAssertEqual(starts, 1, "the boot starts the engine, in the background too")

        session.setActive(true)
        await session.waitForBoot()
        let after = await cloud.starts
        XCTAssertEqual(after, 1, "the activation starts nothing more")
    }

    func testAnEmptyOriginChangesNothing() async throws {
        let bed = try await Bed.make(self, on: .cloudKit, relayOff: true, startsActive: false)
        let session = try bed.session()
        try await bed.publishBriefings(["cloud"], on: .cloudKit)
        _ = await session.handlePush(inForeground: false)
        await session.waitForBoot()
        bed.root.env.setActive(true)
        try await letAnyDialLand()

        XCTAssertEqual(session.route, .cloudKit(.private))
        XCTAssertTrue(has(bed, session, "cloud"))
        XCTAssertEqual(bed.sockets.dials, 0)
    }

    // MARK: - Helpers

    /// A session booted in the background on the relay route, its client with no session token.
    private func makeRelaySessionWithoutLogin(_ attest: any AppAttesting) throws -> (HubSession, SocketCounter) {
        let clock = ManualRelayClock(now: Date())
        let fake = FakeHostedRelay(attest: .enforce(exemptDeviceIDs: []), clock: clock)
        let sockets = SocketCounter(inner: fake.sockets)
        let parts = RelayParts(
            attest: attest, keychain: InMemoryKeychainBackend(), keychainGroup: nil, http: fake.http,
            sockets: sockets, clock: clock
        )
        let relay = SharedRelaySession(config: RelayConfig.parse(fake.origin)) { parts }
        let route = HubRoute.hostedRelay(macDeviceID: "mac-acme")
        let store = try TransportStore(path: ":memory:")
        let transport = try TransportFactory.live(relay: relay).make(route, store, TestE2E.hubID.uuidString, nil)
        return (try makeSession(transport: transport, store: store, route: route), sockets)
    }

    /// A live session on `route` with this phone's keys, launched into the background.
    private func makeSession(transport: any CloudSyncTransport & Sendable, store: TransportStore?, route: HubRoute) throws -> HubSession {
        let session = try HubSession(
            transport: transport,
            replicaPath: try makeReplicaPath(),
            backend: .live,
            transportStore: store,
            hubID: TestE2E.hubID.uuidString,
            keys: PhoneKeys(store: try TestE2E.phoneStore(), hubID: TestE2E.hubID.uuidString),
            defaults: try makeDefaults(),
            recordingsDirectory: try makeRecordingsDirectory(),
            route: route,
            startsActive: false,
            uploadRetriesAllowed: false,
            sleep: { _ in try await Task.sleep(for: .seconds(86_400)) } // swiftlint:disable:this trailing_closure
        )
        addTeardownBlock { @MainActor in await session.shutDown() }
        return session
    }
}

/// App Attest on a locked phone: the device says it is supported when the relay is set up (the availability check),
/// and every later call refuses.
private final class LockedPhoneAttest: AppAttesting, @unchecked Sendable {
    enum Refusal {
        case fails(AppAttestFailure)
        case notSupported
    }

    private let refusal: Refusal
    private let lock = NSLock()
    private var reads = 0

    init(_ refusal: Refusal) {
        self.refusal = refusal
    }

    var isSupported: Bool {
        lock.withLock {
            reads += 1
            if case .notSupported = refusal { return reads == 1 }
            return true
        }
    }

    func generateKey() async throws -> String { try refuse() }
    func attestKey(_: String, clientDataHash _: Data) async throws -> Data { try refuse() }
    func generateAssertion(_: String, clientDataHash _: Data) async throws -> Data { try refuse() }

    private func refuse<T>() throws -> T {
        if case .fails(let failure) = refusal { throw failure }
        throw AppAttestFailure.other("not supported")
    }
}

/// The relay's HTTP with the first read of a data zone held after the relay answered it, until `release()`: a record
/// written meanwhile is not in that answer.
private final class DataReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = true
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false

    var isHolding: Bool { lock.withLock { waiter != nil } }

    func wrap(_ inner: any RelayHTTP) -> any RelayHTTP {
        Wrapped(inner: inner, gate: self)
    }

    func release() {
        let parked = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { waiter = nil }
            return waiter
        }
        parked?.resume()
    }

    fileprivate func passed(_ body: Data) async {
        guard let request = try? Relay_V1_Request(serializedBytes: body), case .changes(let changes)? = request.op,
              changes.zone.hasPrefix("data/") else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let parked = lock.withLock {
                guard armed, !released else { return false }
                armed = false
                waiter = continuation
                return true
            }
            if !parked { continuation.resume() }
        }
    }

    private struct Wrapped: RelayHTTP {
        let inner: any RelayHTTP
        let gate: DataReadGate

        func post(_ url: URL, body: Data, headers: [String: String]) async throws -> (status: Int, body: Data) {
            let answer = try await inner.post(url, body: body, headers: headers)
            await gate.passed(body)
            return answer
        }

        func put(_ url: URL, file: URL, headers: [String: String]) async throws -> Int {
            try await inner.put(url, file: file, headers: headers)
        }

        func get(_ url: URL, to file: URL, maxBytes: Int64, headers: [String: String]) async throws -> Int {
            try await inner.get(url, to: file, maxBytes: maxBytes, headers: headers)
        }
    }
}
