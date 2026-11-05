import CloudKit
import UserNotifications
import WatchtowerE2ETesting
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The CloudKit alert subscription across a route move (relay client Phase 4 Task 18, Open decision 18): the registrar
/// always targets the hub's CloudKit route, whatever transport the session is on. Never the real CloudKit: the saver
/// is a fake behind the real `CloudKitPushWake`, the wake reaches the sessions through the app's own factory.
@MainActor
final class AlertRouteMoveWiringTests: XCTestCase {
    /// Counts CloudKit's calls in order, and can fail them or park the next one until the test releases it.
    private final class AlertSaver: SubscriptionSaving, @unchecked Sendable {
        enum Call: Equatable { case save, delete }

        private let lock = NSLock()
        private var recorded: [Call] = []
        private var failure: (any Error)?
        private var parksNext = false
        private var parked: [CheckedContinuation<Void, Never>] = []

        var calls: [Call] { lock.withLock { recorded } }

        func fail(with error: (any Error)?) {
            lock.withLock { failure = error }
        }

        func parkNext() {
            lock.withLock { parksNext = true }
        }

        func release() {
            let waiting = lock.withLock {
                defer { parked = [] }
                return parked
            }
            waiting.forEach { $0.resume() }
        }

        func save(_ subscription: CKSubscription) async throws { try await step(.save) }
        func delete(id: CKSubscription.ID) async throws { try await step(.delete) }

        private func step(_ call: Call) async throws {
            let (error, parks): ((any Error)?, Bool) = lock.withLock {
                recorded.append(call)
                defer { parksNext = false }
                return (failure, parksNext)
            }
            if parks {
                await withCheckedContinuation { continuation in lock.withLock { parked.append(continuation) } }
            }
            if let error { throw error }
        }
    }

    /// The real CloudKit wake with the routes it was asked for and what it refused.
    private final class SpyWake: PushWake, @unchecked Sendable {
        private let inner: CloudKitPushWake
        private let lock = NSLock()
        private var asked: [HubRoute] = []
        private var refused: [UnsupportedRouteError] = []

        init(saver: AlertSaver) {
            inner = CloudKitPushWake(saver: saver)
        }

        var routes: [HubRoute] { lock.withLock { asked } }
        var refusals: [UnsupportedRouteError] { lock.withLock { refused } }

        private func noting<T>(_ route: HubRoute, _ call: () async throws -> T) async throws -> T {
            lock.withLock { asked.append(route) }
            do {
                return try await call()
            } catch let error as UnsupportedRouteError {
                lock.withLock { refused.append(error) }
                throw error
            }
        }

        func subscribeAlerts(hubID: String, route: HubRoute) async throws -> Bool {
            try await noting(route) { try await inner.subscribeAlerts(hubID: hubID, route: route) }
        }

        func unsubscribeAlerts(hubID: String, route: HubRoute) async throws {
            try await noting(route) { try await inner.unsubscribeAlerts(hubID: hubID, route: route) }
        }

        func origin(ofRemoteNotification userInfo: [AnyHashable: Any]) -> PushOrigin? {
            inner.origin(ofRemoteNotification: userInfo)
        }

        func alertSource(for userInfo: [AnyHashable: Any]) -> AlertSource? {
            inner.alertSource(for: userInfo)
        }

        func envelope(for source: AlertSource, timeout: TimeInterval) async throws -> Data? {
            try await inner.envelope(for: source, timeout: timeout)
        }
    }

    private struct Harness {
        let bed: Bed
        let saver: AlertSaver
        let wake: SpyWake
    }

    private func harness(
        on route: TransportKind,
        hubTransports: [String] = ["cloudkit", "relay"],
        failing: (any Error)? = nil
    ) async throws -> Harness {
        let saver = AlertSaver()
        saver.fail(with: failing)
        let wake = SpyWake(saver: saver)
        let bed = try await Bed.make(self, on: route, hubTransports: hubTransports, alertWake: wake)
        let env = bed.root.env
        addTeardownBlock { @MainActor in
            for session in env.sessions.values { session.deviceSettings.workAlerts = true }
        }
        for session in env.sessions.values { session.deviceSettings.workAlerts = true }
        return Harness(bed: bed, saver: saver, wake: wake)
    }

    /// The app leaves the foreground and comes back; the session's registrar has then run what it was asked.
    private func foreground(_ session: HubSession) async throws {
        session.setActive(false)
        session.setActive(true)
        try await Task.sleep(for: .milliseconds(100))
        await session.alertRegistrar?.idle()
    }

    // MARK: - The route

    func testTheSubscriptionStaysOnTheRelay() async throws {
        let parts = try await harness(on: .cloudKit)
        let first = try await parts.bed.orderedSession()
        try await poll({ parts.saver.calls == [.save] }, "the CloudKit session saved it")

        try await parts.bed.writeSwitch(target: .relay, epoch: 2, on: .cloudKit)
        let onRelay = try await parts.bed.fetchAndFollow(first)
        XCTAssertEqual(onRelay.route, .hostedRelay(macDeviceID: parts.bed.mac.deviceID))
        try await poll({ parts.saver.calls == [.save, .save] }, "the relay session saved it too")

        try await parts.bed.writeSwitch(target: .cloudKit, epoch: 3, on: .relay)
        let back = try await parts.bed.fetchAndFollow(onRelay)
        XCTAssertEqual(back.route, .cloudKit(.private))
        try await poll({ parts.saver.calls == [.save, .save, .save] }, "and the session back on CloudKit")

        XCTAssertFalse(parts.saver.calls.contains(.delete), "a move removes nothing")
        XCTAssertTrue(parts.wake.routes.allSatisfy { $0 == .cloudKit(.private) }, "always the CloudKit route")
        XCTAssertTrue(parts.wake.refusals.isEmpty, "no UnsupportedRouteError")
    }

    func testTheSwitchStillWorksOnTheRelay() async throws {
        let parts = try await harness(on: .relay)
        let env = parts.bed.root.env
        await env.waitForBoot()
        try await poll({ parts.saver.calls == [.save] }, "saved at the relay session's boot")
        let tasks = FakeBackgroundTasks()
        let work = BackgroundWork.starter(runner: tasks, suspension: DatabaseSuspension { _ in }) { true }

        await env.setWorkAlerts(false, startWork: work)
        XCTAssertEqual(parts.saver.calls, [.save, .delete], "off removes it")
        await env.setWorkAlerts(true, startWork: work)
        XCTAssertEqual(parts.saver.calls, [.save, .delete, .save], "on saves it")
        XCTAssertTrue(parts.wake.routes.allSatisfy { $0 == .cloudKit(.private) })
        XCTAssertTrue(parts.wake.refusals.isEmpty)
    }

    func testARelayOnlyHubHasNoRegistrar() async throws {
        let parts = try await harness(on: .relay, hubTransports: ["relay"])
        let session = try parts.bed.session()
        await session.waitForBoot()
        XCTAssertNil(session.alertRegistrar)
        XCTAssertTrue(parts.saver.calls.isEmpty)
    }

    /// A session with no link (a pairing's, a link being made) keeps the route's own rule: a relay route has none.
    func testASessionWithNoLinkOnTheRelayHasNoRegistrar() throws {
        let session = try HubSession(
            transport: InMemoryCloudTransport(), replicaPath: try makeReplicaPath(), backend: .live, hubID: TestE2E.hubID.uuidString,
            keys: try TestPhone.keys(), defaults: try makeDefaults(), recordingsDirectory: try makeRecordingsDirectory(),
            route: .hostedRelay(macDeviceID: "mac-1"), pushWake: CloudKitPushWake(saver: AlertSaver()),
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) } // swiftlint:disable:this trailing_closure
        )
        closeAtTeardown(session)
        XCTAssertNil(session.alertRegistrar)
    }

    // MARK: - Retries

    func testAFailedSaveIsRetriedOnForeground() async throws {
        let parts = try await harness(on: .relay, failing: CKError(.networkUnavailable))
        let session = try parts.bed.session()
        await session.waitForBoot()
        try await poll({ parts.saver.calls == [.save] }, "the boot's save failed")

        parts.saver.fail(with: nil)
        try await foreground(session)
        XCTAssertEqual(parts.saver.calls, [.save, .save], "retried")

        try await foreground(session)
        XCTAssertEqual(parts.saver.calls, [.save, .save], "applied: a foreground costs no CloudKit call")
    }

    /// A link that never switched behaves as before Task 18: a saved subscription costs a foreground nothing, and a
    /// failed one is retried by the foreground, as `HubSession.setActive` always did.
    func testANeverSwitchedLinkKeepsTodaysRetry() async throws {
        let parts = try await harness(on: .cloudKit)
        let session = try parts.bed.session()
        await session.waitForBoot()
        try await poll({ parts.saver.calls == [.save] }, "saved at the boot")
        XCTAssertNil(try parts.bed.row()?.link.switchedAt)

        try await foreground(session)
        XCTAssertEqual(parts.saver.calls, [.save], "no save on a foreground")

        let failing = try await harness(on: .cloudKit, failing: CKError(.networkUnavailable))
        let other = try failing.bed.session()
        await other.waitForBoot()
        try await poll({ failing.saver.calls == [.save] }, "the boot's save failed")
        failing.saver.fail(with: nil)
        try await foreground(other)
        XCTAssertEqual(failing.saver.calls, [.save, .save], "the foreground retry a never-switched link always had")
    }

    func testNoICloudAccountDoesNotStopTheRelayLink() async throws {
        let parts = try await harness(on: .relay, failing: CKError(.notAuthenticated))
        let session = try await parts.bed.orderedSession()
        try await poll({ parts.saver.calls == [.save] }, "the save was tried and failed")

        try await parts.bed.publishBriefings(["41"], on: .relay)
        await parts.bed.fetch(session)
        XCTAssertEqual(try parts.bed.briefings(session), [SliceKind.briefing.recordName(id: "41")], "the link keeps working")
        XCTAssertEqual(try parts.bed.row()?.link.transport, .relay)
        XCTAssertTrue(parts.bed.root.env.session(parts.bed.hubID) === session, "the session stands")
    }

    // MARK: - The race

    func testAMoveWaitsForTheOldRegistrar() async throws {
        let parts = try await harness(on: .cloudKit)
        let first = try await parts.bed.orderedSession()
        try await poll({ parts.saver.calls == [.save] }, "saved at the boot")
        let registrar = try XCTUnwrap(first.alertRegistrar)

        parts.saver.parkNext()
        let parked = Task { await registrar.apply(enabled: false) }
        try await poll({ parts.saver.calls == [.save, .delete] }, "the old session's delete is at CloudKit")

        try await parts.bed.writeSwitch(target: .relay, epoch: 2, on: .cloudKit)
        await parts.bed.fetch(first)
        // Long enough for a move that does not wait to have built the new session.
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(parts.bed.root.env.session(parts.bed.hubID) === first, "no new session while the old call runs")
        XCTAssertEqual(parts.saver.calls, [.save, .delete])

        parts.saver.release()
        await parked.value
        await parts.bed.root.routeMoves[parts.bed.hubID]?.value
        let next = try parts.bed.session()
        XCTAssertFalse(next === first, "the move went on")
        await next.waitForBoot()
        try await poll({ parts.saver.calls == [.save, .delete, .save] }, "the new session's save comes after the delete")
    }

    // MARK: - A shared-scope phone

    @MainActor
    private final class Posted {
        var requests: [UNNotificationRequest] = []
        var posting: LocalAlertPosting { LocalAlertPosting { self.requests.append($0) } }
    }

    private let hubID = TestE2E.hubID.uuidString
    private let shared = HubRoute.cloudKit(.shared(ownerName: "_owner"))
    private let relay = HubRoute.hostedRelay(macDeviceID: "mac-1")

    private func publishAlert(_ key: String, ask: Int64, into transport: InMemoryCloudTransport) async throws {
        let payload = WorkAlertPayload(
            event: .ask, key: key, workbenchID: 3, workbenchName: "Acme", sessionID: 7, askID: ask, requestID: nil,
            title: "Acme · Lane totals", body: "Which wording?", quick: false)
        try await TestPhone.hub(over: transport).save([
            CloudRecord(
                recordName: SliceKind.askAlert.recordName(id: String(ask)), zone: .data, kind: SliceKind.askAlert.rawValue,
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_000), payload: try JSONEncoder().encode(payload))
        ])
    }

    /// A linked session of a shared-scope hub on `route`, on the shared replica and settings.
    private func session(
        _ route: HubRoute,
        transport: InMemoryCloudTransport,
        posted: Posted,
        replicaPath: String,
        defaults: UserDefaults
    ) throws -> HubSession {
        let link = LinkRecord(
            hubID: hubID, macName: "Work Mac", scope: .shared, ownerName: "_owner", userRecordName: "_owner-acme", nonce: "nonce",
            dataShareURL: nil, relayShareURL: nil, deviceID: TestE2E.deviceID.uuidString, linkedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let session = try HubSession(
            transport: transport, replicaPath: replicaPath, backend: .live, hubID: hubID, keys: try TestPhone.keys(),
            defaults: defaults, recordingsDirectory: try makeRecordingsDirectory(), route: route, link: link, alertPosting: posted.posting,
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) } // swiftlint:disable:this trailing_closure
        )
        closeAtTeardown(session)
        let settings = session.deviceSettings
        let before = settings.workAlerts
        addTeardownBlock { @MainActor in settings.workAlerts = before }
        settings.workAlerts = true
        return session
    }

    /// CloudKit (ask 41 seen, ask 42 posted), then the relay (ask 43 pushed over it), then CloudKit again.
    private func returnFromRelay(posted: Posted) async throws -> (HubSession, InMemoryCloudTransport) {
        let transport = InMemoryCloudTransport()
        let (path, defaults) = (try makeReplicaPath(), try makeDefaults())
        try await publishAlert("ask-41", ask: 41, into: transport)
        let before = try session(shared, transport: transport, posted: posted, replicaPath: path, defaults: defaults)
        _ = await before.refresh(.pull)
        try await publishAlert("ask-42", ask: 42, into: transport)
        _ = await before.refresh(.pull)
        XCTAssertEqual(posted.requests.map(\.identifier), [SharedAlertPoster.identifier(hubID: hubID, key: "ask-42")])
        await before.shutDown()
        before.closeDatabases()

        try await publishAlert("ask-43", ask: 43, into: transport)
        let onRelay = try session(relay, transport: transport, posted: posted, replicaPath: path, defaults: defaults)
        _ = await onRelay.refresh(.pull)
        XCTAssertEqual(try onRelay.store.alertEnvelopes().count, 3, "the alerts are in the replica")
        XCTAssertEqual(posted.requests.count, 1, "no poster on the relay")
        XCTAssertNil(defaults.object(forKey: SharedAlertPoster.postedDefaultsKey(hubID: hubID)), "the seen list is gone")
        SharedAlertPoster.forgetSeen(hubID: hubID, defaults: defaults) // Idempotent: a restart calls it again.
        await onRelay.shutDown()
        onRelay.closeDatabases()

        let back = try session(shared, transport: transport, posted: posted, replicaPath: path, defaults: defaults)
        return (back, transport)
    }

    func testAReturnFromRelayPostsNoBurst() async throws {
        let posted = Posted()
        let (back, _) = try await returnFromRelay(posted: posted)
        _ = await back.refresh(.pull)
        XCTAssertEqual(posted.requests.count, 1, "the return's first fetch posts nothing")
        XCTAssertEqual(try back.store.alertEnvelopes().count, 3)
    }

    func testAnAlertAfterTheReturnIsPosted() async throws {
        let posted = Posted()
        let (back, transport) = try await returnFromRelay(posted: posted)
        _ = await back.refresh(.pull)
        try await publishAlert("ask-44", ask: 44, into: transport)
        _ = await back.refresh(.pull)
        XCTAssertEqual(posted.requests.map(\.identifier).last, SharedAlertPoster.identifier(hubID: hubID, key: "ask-44"))
        XCTAssertEqual(posted.requests.count, 2)
    }
}
