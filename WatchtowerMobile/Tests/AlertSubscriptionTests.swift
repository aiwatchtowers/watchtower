import CloudKit
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
        let registrar = AlertSubscriptionRegistrar(hubID: hubID, scope: .private, saver: saver)
        await registrar.apply(enabled: true)
        await registrar.apply(enabled: true)
        let saved = await saver.saved
        XCTAssertEqual(saved.map(\.subscriptionID), [AskAlertSubscription.subscriptionID(hubID: hubID)])
    }

    func testTurningOffDeletesIt() async {
        let saver = FakeSaver()
        let registrar = AlertSubscriptionRegistrar(hubID: hubID, scope: .private, saver: saver)
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
        let registrar = AlertSubscriptionRegistrar(hubID: hubID, scope: .shared(ownerName: "_owner"), saver: saver)
        await registrar.apply(enabled: true)
        await registrar.apply(enabled: false)
        let (saved, deleted) = await (saver.saved, saver.deleted)
        XCTAssertTrue(saved.isEmpty)
        XCTAssertTrue(deleted.isEmpty)
    }

    func testAFailedSaveIsRetriedByTheNextCall() async {
        let flaky = FlakySaver()
        let registrar = AlertSubscriptionRegistrar(hubID: hubID, scope: .private, saver: flaky)
        await registrar.apply(enabled: true)
        await registrar.apply(enabled: true)
        XCTAssertEqual(flaky.attempts, 2)
    }

    private final class FlakySaver: SubscriptionSaving, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var attempts: Int { lock.withLock { count } }
        func save(_ subscription: CKSubscription) async throws {
            let n = lock.withLock { count += 1; return count }
            if n == 1 { throw CKError(.networkUnavailable) }
        }
        func delete(id: CKSubscription.ID) async throws {}
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
        let registrar = AlertSubscriptionRegistrar(hubID: hubID, scope: .private, saver: saver)
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
        let registrar = AlertSubscriptionRegistrar(hubID: hubID, scope: .private, saver: saver)
        await registrar.apply(enabled: false)
        let deleted = await saver.deleted
        XCTAssertEqual(deleted, [AskAlertSubscription.subscriptionID(hubID: hubID)], "even before this launch saved it")
    }
}
