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

    /// Calls finish in reverse order of their start; the last request still decides the end state.
    private actor SlowSaver: SubscriptionSaving {
        private(set) var live = false
        private var calls = 0
        func save(_ subscription: CKSubscription) async throws {
            calls += 1
            try? await Task.sleep(for: .milliseconds(calls.isMultiple(of: 2) ? 5 : 40))
            live = true
        }
        func delete(id: CKSubscription.ID) async throws {
            calls += 1
            try? await Task.sleep(for: .milliseconds(calls.isMultiple(of: 2) ? 5 : 40))
            live = false
        }
    }

    func testRapidTogglesEndInTheLastRequestedState() async {
        let saver = SlowSaver()
        let registrar = AlertSubscriptionRegistrar(hubID: hubID, scope: .private, saver: saver)
        async let one: Void = registrar.apply(enabled: true)
        async let two: Void = registrar.apply(enabled: false)
        async let three: Void = registrar.apply(enabled: true)
        async let four: Void = registrar.apply(enabled: false)
        _ = await (one, two, three, four)
        let live = await saver.live
        XCTAssertFalse(live)
    }

    func testForgettingAHubDeletesItsSubscription() async {
        let saver = FakeSaver()
        let registrar = AlertSubscriptionRegistrar(hubID: hubID, scope: .private, saver: saver)
        await registrar.apply(enabled: false)
        let deleted = await saver.deleted
        XCTAssertEqual(deleted, [AskAlertSubscription.subscriptionID(hubID: hubID)], "even before this launch saved it")
    }
}
