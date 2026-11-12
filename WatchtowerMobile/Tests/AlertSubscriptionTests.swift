import CloudKit
import WatchtowerE2ETesting
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The work-alert subscription per hub scope, and the switch's one-time carry-over.
@MainActor
final class AlertSubscriptionTests: XCTestCase {
    private actor FakeSaver: SubscriptionSaving {
        private(set) var saved: [CKSubscription] = []
        private(set) var deleted: [String] = []
        func save(_ subscription: CKSubscription) async throws { saved.append(subscription) }
        func delete(id: CKSubscription.ID) async throws { deleted.append(id) }
    }

    private let hubID = "11111111-2222-3333-4444-555555555555"

    func testPrivateScopeSavesTheSubscriptionOnce() async {
        let saver = FakeSaver()
        let registrar = AlertSubscriptionRegistrar(hubID: hubID, route: .cloudKit(.private), wake: CloudKitPushWake(saver: saver))
        await registrar.apply(enabled: true)
        await registrar.apply(enabled: true)
        let saved = await saver.saved
        XCTAssertEqual(saved.map(\.subscriptionID), [AskAlertSubscription.subscriptionID(hubID: hubID)])
    }

    func testTurningOffDeletesIt() async {
        let saver = FakeSaver()
        let registrar = AlertSubscriptionRegistrar(hubID: hubID, route: .cloudKit(.private), wake: CloudKitPushWake(saver: saver))
        await registrar.apply(enabled: true)
        await registrar.apply(enabled: false)
        let deleted = await saver.deleted
        XCTAssertEqual(deleted, [AskAlertSubscription.subscriptionID(hubID: hubID)])
        await registrar.apply(enabled: true)
        let saved = await saver.saved
        XCTAssertEqual(saved.count, 2, "turning it back on registers again")
    }

    func testSharedScopeSavesNothing() async {
        let saver = FakeSaver()
        let registrar = AlertSubscriptionRegistrar(
            hubID: hubID, route: .cloudKit(.shared(ownerName: "_owner-acme")), wake: CloudKitPushWake(saver: saver))
        await registrar.apply(enabled: true)
        await registrar.apply(enabled: false)
        let (saved, deleted) = await (saver.saved, saver.deleted)
        XCTAssertTrue(saved.isEmpty)
        XCTAssertTrue(deleted.isEmpty)
    }

    func testAFailedSaveIsRetriedByTheNextCall() async {
        let flaky = FlakySaver()
        let registrar = AlertSubscriptionRegistrar(hubID: hubID, route: .cloudKit(.private), wake: CloudKitPushWake(saver: flaky))
        await registrar.apply(enabled: true)
        await registrar.apply(enabled: true)
        XCTAssertEqual(flaky.attempts, 2)
    }

    private final class FlakySaver: SubscriptionSaving, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private let error: CKError
        var attempts: Int { lock.withLock { count } }
        init(error: CKError = CKError(.networkUnavailable)) { self.error = error }
        func save(_ subscription: CKSubscription) async throws {
            let n = lock.withLock { count += 1; return count }
            if n == 1 { throw error }
        }
        func delete(id: CKSubscription.ID) async throws {}
    }

    /// #1749: Production refused the save with invalidArguments on every foreground (170 tries in two hours).
    private static let productionRefusal = CKError(.invalidArguments, userInfo: [
        "ServerErrorDescription": "attempting to create a subscription in a production container"
    ])

    func testAPermanentRefusalIsNotResentByTheNextCall() async {
        let refusing = FlakySaver(error: Self.productionRefusal)
        let registrar = AlertSubscriptionRegistrar(hubID: hubID, route: .cloudKit(.private), wake: CloudKitPushWake(saver: refusing))
        await registrar.apply(enabled: true)
        await registrar.apply(enabled: true)
        XCTAssertEqual(refusing.attempts, 1, "a foreground return does not resend a refused save")
    }

    func testAToggleRetriesAfterAPermanentRefusal() async {
        let refusing = FlakySaver(error: Self.productionRefusal)
        let registrar = AlertSubscriptionRegistrar(hubID: hubID, route: .cloudKit(.private), wake: CloudKitPushWake(saver: refusing))
        await registrar.apply(enabled: true)
        await registrar.apply(enabled: false)
        await registrar.apply(enabled: true)
        XCTAssertEqual(refusing.attempts, 2, "switching off and on again tries once more")
    }

    func testOldNewAsksValueCarriesOver() throws {
        let defaults = try makeDefaults()
        defaults.set(false, forKey: "notifications.newAsks")
        let settings = DeviceSettings(transport: try TestPhone.transport(), defaults: defaults, hubID: TestHub.acme)
        XCTAssertFalse(settings.workAlerts)
        XCTAssertEqual(defaults.object(forKey: "notifications.workAlerts") as? Bool, false)
        XCTAssertNil(defaults.object(forKey: "notifications.newAsks"))
        let again = DeviceSettings(transport: try TestPhone.transport(), defaults: defaults, hubID: TestHub.home)
        XCTAssertFalse(again.workAlerts)
    }

    func testWorkAlertsLiveInTheAlertSuite() throws {
        let standard = try makeDefaults()
        let group = try makeDefaults()
        standard.set(false, forKey: "notifications.newAsks")
        let settings = DeviceSettings(
            transport: try TestPhone.transport(), defaults: standard, alertDefaults: group, hubID: TestHub.acme)
        XCTAssertFalse(settings.workAlerts)
        settings.workAlerts = true
        XCTAssertEqual(group.object(forKey: "notifications.workAlerts") as? Bool, true)
        XCTAssertNil(standard.object(forKey: "notifications.workAlerts"))
    }

    func testWorkAlertsDefaultOn() throws {
        let settings = DeviceSettings(transport: try TestPhone.transport(), defaults: try makeDefaults(), hubID: TestHub.acme)
        XCTAssertTrue(settings.workAlerts)
    }

    @MainActor
    private final class IssuedCount {
        var value = 0
    }

    /// Holds every CloudKit call until the test opens it, so later requests are issued while the first is in flight.
    private actor GatedSaver: SubscriptionSaving {
        private(set) var calls: [String] = []
        private(set) var live = false
        private var open = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func save(_ subscription: CKSubscription) async throws {
            calls.append("save")
            await gate()
            live = true
        }

        func delete(id: CKSubscription.ID) async throws {
            calls.append("delete")
            await gate()
            live = false
        }

        func openGate() {
            open = true
            waiting.forEach { $0.resume() }
            waiting = []
        }

        private func gate() async {
            guard !open else { return }
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    /// on, off, on, off, issued in that order while the first save is still in flight: the run that follows it
    /// applies the newest request, the ones in between cost no CloudKit call, and the end state is the last request.
    func testRapidTogglesEndInTheLastRequestedState() async throws {
        let saver = GatedSaver()
        let registrar = AlertSubscriptionRegistrar(hubID: hubID, route: .cloudKit(.private), wake: CloudKitPushWake(saver: saver))
        let issued = IssuedCount()
        var calls: [Task<Void, Never>] = []
        for enabled in [true, false, true, false] {
            // The task's body and `apply`'s synchronous start (recording the request) run in one main-actor job,
            // so once the count moves this request is recorded, after the ones before it.
            calls.append(Task { @MainActor in
                issued.value += 1
                await registrar.apply(enabled: enabled)
            })
            try await poll({ issued.value == calls.count }, "request \(calls.count) was not issued")
        }
        while await saver.calls.isEmpty {
            await Task.yield()
        }
        let inFlight = await saver.calls
        XCTAssertEqual(inFlight, ["save"], "only the first request reached CloudKit so far")

        await saver.openGate()
        for call in calls { await call.value }

        let (live, made) = await (saver.live, saver.calls)
        XCTAssertFalse(live, "the last request (off) wins")
        XCTAssertEqual(made, ["save", "delete"], "one run for the in-flight request, one for the newest")
    }

    func testForgettingAHubDeletesItsSubscription() async {
        let saver = FakeSaver()
        let registrar = AlertSubscriptionRegistrar(hubID: hubID, route: .cloudKit(.private), wake: CloudKitPushWake(saver: saver))
        await registrar.apply(enabled: false)
        let deleted = await saver.deleted
        XCTAssertEqual(deleted, [AskAlertSubscription.subscriptionID(hubID: hubID)], "even before this launch saved it")
    }

    // MARK: - The switch on the relay (Open decision 1, option A)

    /// The phone's `device` records in the bed's cloud, opened; the in-memory store keeps a record name's last save.
    private func deviceRecords(_ bed: Bed) async throws -> [DevicePayload] {
        let changes = try await TestPhone.transport(over: bed.cloud.inner).changes(in: .relay, since: nil)
        return try changes.changed.filter { $0.kind == RelayRecordKind.device.rawValue }
            .map { try RelayCoder.makeDecoder().decode(DevicePayload.self, from: $0.payload) }
    }

    /// A bed whose phone-wide switch (the app group's) comes back on when the test ends.
    private func alertsBed(relayOff: Bool = false) async throws -> Bed {
        let bed = try await Bed.make(self, on: .cloudKit, relayOff: relayOff)
        let env = bed.root.env
        addTeardownBlock { @MainActor in
            for session in env.sessions.values { session.deviceSettings.workAlerts = true }
        }
        await env.waitForBoot()
        return bed
    }

    /// A second hub beside the bed's, on its own in-memory transport; its session goes through the environment's `add`.
    private func addSecondHub(to bed: Bed) async throws -> InMemoryCloudTransport {
        let inner = InMemoryCloudTransport()
        let session = try HubSession(
            transport: inner,
            replicaPath: try makeReplicaPath(),
            backend: .live,
            hubID: TestHub.home,
            linkedDevice: try XCTUnwrap(bed.session().linkedDevice),
            keys: try TestHub.keys(TestHub.home),
            defaults: try makeDefaults(),
            recordingsDirectory: try makeRecordingsDirectory(),
            sleep: { _ in try await Task.sleep(for: .seconds(86_400)) } // swiftlint:disable:this trailing_closure
        )
        addTeardownBlock { @MainActor in session.stop() }
        bed.root.env.add(session)
        await session.waitForBoot()
        return inner
    }

    private func secondHubRecords(_ inner: InMemoryCloudTransport) async throws -> [DevicePayload] {
        let changes = try await TestHub.hub(over: inner, TestHub.home).changes(in: .relay, since: nil)
        return try changes.changed.filter { $0.kind == RelayRecordKind.device.rawValue }
            .map { try RelayCoder.makeDecoder().decode(DevicePayload.self, from: $0.payload) }
    }

    /// While the relay is available the phone-wide switch reaches each hub's `device` record, while it is off only.
    func testTheSwitchIsInEveryHubsDeviceRecordWhileOff() async throws {
        let bed = try await alertsBed()
        let second = try await addSecondHub(to: bed)

        await bed.root.env.setWorkAlerts(false)
        var written = try await deviceRecords(bed)
        XCTAssertEqual(written.last?.workAlertsOff, true)
        var writtenSecond = try await secondHubRecords(second)
        XCTAssertEqual(writtenSecond.last?.workAlertsOff, true, "the other hub")

        await bed.root.env.setWorkAlerts(true)
        written = try await deviceRecords(bed)
        let on = try XCTUnwrap(written.last)
        XCTAssertFalse(on.workAlertsOff)
        let encoded = try RelayCoder.makeEncoder().encode(on)
        XCTAssertFalse(String(bytes: encoded, encoding: .utf8)?.contains("work_alerts_off") ?? true, "absent when on")
        writtenSecond = try await secondHubRecords(second)
        XCTAssertEqual(writtenSecond.last?.workAlertsOff, false, "the other hub")
    }

    /// On a relay route `save` only queues: the switch's record goes out before `setWorkAlerts` returns, with no pull,
    /// inside a background task, so an owner who flips it and leaves the app does not strand it.
    func testOnARelayRouteTheSwitchIsSentAtOnceInsideABackgroundTask() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let env = bed.root.env
        addTeardownBlock { @MainActor in
            for session in env.sessions.values { session.deviceSettings.workAlerts = true }
        }
        await env.waitForBoot()
        let saves = { bed.fake.log.filter { if case .save = $0 { true } else { false } }.count }
        let before = saves()
        let tasks = FakeBackgroundTasks()
        let suspension = DatabaseSuspension { _ in }

        await env.setWorkAlerts(false, startWork: BackgroundWork.starter(runner: tasks, suspension: suspension) { true })

        XCTAssertGreaterThan(saves(), before, "the record reached the relay")
        XCTAssertEqual(tasks.begun, ["work-alerts-switch"])
        XCTAssertEqual(tasks.ended.count, 1, "and the task ended")
    }

    /// A permission request on a relay route reaches the relay at once, with no pull (G1): it would wait for the
    /// session's next fetch otherwise.
    func testOnARelayRouteAToggleIsSentAtOnce() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let env = bed.root.env
        await env.waitForBoot()
        let saves = { bed.fake.log.filter { if case .save = $0 { true } else { false } }.count }
        let before = saves()

        await env.deviceSettings.setPermissionsRequested(true)

        XCTAssertGreaterThan(saves(), before, "the record reached the relay")
    }

    /// A new link or a re-link starts the hub's column at "on", so a phone whose switch is off says so at once; the
    /// extension has no switch check of its own.
    func testALinkWithTheSwitchOffWritesOneRecord() async throws {
        let bed = try await alertsBed()
        let session = try XCTUnwrap(bed.root.env.session(bed.hubID))
        let device = try XCTUnwrap(session.linkedDevice)
        let record = try XCTUnwrap(bed.root.linkedHubs().first { $0.hubID == bed.hubID }?.link)
        session.deviceSettings.workAlerts = false

        try await bed.root.linked(record, device: device)

        let written = try await deviceRecords(bed)
        XCTAssertEqual(written.last?.workAlertsOff, true)
    }

    /// The link screen waits on `linked`: a dead network holds the send, not the screen. The record is saved by then.
    func testALinkWithTheSwitchOffDoesNotWaitOnItsSend() async throws {
        let bed = try await alertsBed()
        let session = try XCTUnwrap(bed.root.env.session(bed.hubID))
        let device = try XCTUnwrap(session.linkedDevice)
        let record = try XCTUnwrap(bed.root.linkedHubs().first { $0.hubID == bed.hubID }?.link)
        session.deviceSettings.workAlerts = false
        var sendStarted = false
        var released = false
        bed.root.sendLinkedQueue = { _ in
            sendStarted = true
            while !released {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        var returned = false
        let link = Task {
            try await bed.root.linked(record, device: device)
            returned = true
        }
        for _ in 0..<600 where !returned || !sendStarted {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(sendStarted, "the send still runs")
        XCTAssertTrue(returned, "linked waited on the blocked send")
        let written = try await deviceRecords(bed)
        XCTAssertEqual(written.last?.workAlertsOff, true, "saved before it returned")

        released = true
        try await link.value
    }

    func testALinkWithTheSwitchOnWritesNoRecord() async throws {
        let bed = try await alertsBed()
        let session = try XCTUnwrap(bed.root.env.session(bed.hubID))
        let device = try XCTUnwrap(session.linkedDevice)
        let record = try XCTUnwrap(bed.root.linkedHubs().first { $0.hubID == bed.hubID }?.link)
        let before = try await deviceRecords(bed)

        try await bed.root.linked(record, device: device)

        let after = try await deviceRecords(bed)
        XCTAssertEqual(after.count, before.count)
        XCTAssertEqual(after.last?.updatedAt, before.last?.updatedAt)
    }

    /// The dark ship: with an empty origin the switch writes no record and the record is today's, byte for byte.
    func testAnEmptyOriginWritesNoWorkAlertsOff() async throws {
        let bed = try await alertsBed(relayOff: true)
        let session = try bed.session()
        let before = try await deviceRecords(bed)

        let tasks = FakeBackgroundTasks()
        let suspension = DatabaseSuspension { _ in }
        await bed.root.env.setWorkAlerts(false, startWork: BackgroundWork.starter(runner: tasks, suspension: suspension) { true })
        XCTAssertTrue(tasks.begun.isEmpty, "no background task either")
        let after = try await deviceRecords(bed)
        XCTAssertEqual(after.map(\.updatedAt), before.map(\.updatedAt), "the switch writes nothing")
        let device = try XCTUnwrap(session.linkedDevice)
        let payload = bed.root.devicePayload(hubID: bed.hubID, for: device, linkNonce: nil, unlinked: false, now: Date())
        XCTAssertFalse(payload.workAlertsOff)
    }

    /// The extension makes no relay call and links no relay target (Phase 4 global constraint).
    func testTheExtensionLinksNoRelayTarget() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("project.yml")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("project.yml is out of reach") }
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        let start = try XCTUnwrap(lines.firstIndex(of: "  NotifyService:"))
        let block = lines[(start + 1)...].prefix { $0.isEmpty || $0.hasPrefix("   ") }.joined(separator: "\n")
        XCTAssertTrue(block.contains("product: WatchtowerSync"))
        XCTAssertFalse(block.contains("WatchtowerHostedRelay"))
    }
}
