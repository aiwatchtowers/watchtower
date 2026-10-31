import CloudKit
import XCTest
@testable import WatchtowerSync

private final class RecordingSaver: SubscriptionSaving, @unchecked Sendable {
    private let lock = NSLock()
    private var _saved: [String] = []
    private var _deleted: [String] = []
    var saved: [String] { lock.withLock { _saved } }
    var deleted: [String] { lock.withLock { _deleted } }

    func save(_ subscription: CKSubscription) async throws {
        lock.withLock { _saved.append(subscription.subscriptionID) }
    }

    func delete(id: CKSubscription.ID) async throws {
        lock.withLock { _deleted.append(id) }
    }
}

final class CloudKitPushWakeTests: XCTestCase {
    private let hosted = HubRoute.hostedRelay(macDeviceID: "mac-acme")

    func testAPrivateRouteSavesTheSubscription() async throws {
        let saver = RecordingSaver()
        let wake = CloudKitPushWake(saver: saver)
        let registered = try await wake.subscribeAlerts(hubID: "hub-acme", route: .cloudKit(.private))
        XCTAssertTrue(registered)
        XCTAssertEqual(saver.saved, ["ask-alert-hub-acme"])
    }

    func testASharedRouteSavesNothing() async throws {
        let saver = RecordingSaver()
        let wake = CloudKitPushWake(saver: saver)
        let route = HubRoute.cloudKit(.shared(ownerName: "_owner-acme"))
        let registered = try await wake.subscribeAlerts(hubID: "hub-acme", route: route)
        XCTAssertFalse(registered)
        try await wake.unsubscribeAlerts(hubID: "hub-acme", route: route)
        XCTAssertTrue(saver.saved.isEmpty)
        XCTAssertTrue(saver.deleted.isEmpty)
    }

    func testAPrivateRouteUnsubscribeDeletesTheID() async throws {
        let saver = RecordingSaver()
        let wake = CloudKitPushWake(saver: saver)
        try await wake.unsubscribeAlerts(hubID: "hub-acme", route: .cloudKit(.private))
        XCTAssertEqual(saver.deleted, ["ask-alert-hub-acme"])
    }

    func testAHostedRelayRouteIsRefused() async {
        let saver = RecordingSaver()
        let wake = CloudKitPushWake(saver: saver)
        do {
            _ = try await wake.subscribeAlerts(hubID: "hub-acme", route: hosted)
            XCTFail("expected UnsupportedRouteError")
        } catch {
            XCTAssertEqual(error as? UnsupportedRouteError, UnsupportedRouteError(route: hosted))
        }
        do {
            try await wake.unsubscribeAlerts(hubID: "hub-acme", route: hosted)
            XCTFail("expected UnsupportedRouteError")
        } catch {
            XCTAssertEqual(error as? UnsupportedRouteError, UnsupportedRouteError(route: hosted))
        }
        XCTAssertTrue(saver.saved.isEmpty)
        XCTAssertTrue(saver.deleted.isEmpty)
    }

    func testOriginOfANonCloudKitPayloadIsNil() {
        let wake = CloudKitPushWake(saver: RecordingSaver())
        XCTAssertNil(wake.origin(ofRemoteNotification: ["aps": ["content-available": 1]]))
    }

    func testAlertSourceOfANonCloudKitPayloadIsNil() {
        let wake = CloudKitPushWake(saver: RecordingSaver())
        XCTAssertNil(wake.alertSource(for: ["aps": ["content-available": 1]]))
    }

    func testAnInlineSourceNeedsNoFetch() async throws {
        let wake = CloudKitPushWake(saver: RecordingSaver())
        let source = AlertSource.inline(hubID: "hub-acme", envelope: Data([1, 2]))
        let envelope = try await wake.envelope(for: source, timeout: 1)
        XCTAssertEqual(envelope, Data([1, 2]))
        XCTAssertEqual(source.wireName, "alert-push")
        XCTAssertEqual(source.hubID, "hub-acme")
    }

    func testRoutesMapToPushOrigins() {
        XCTAssertEqual(HubRoute.cloudKit(.private).pushOrigin, .private)
        XCTAssertEqual(HubRoute.cloudKit(.shared(ownerName: "_owner-acme")).pushOrigin, .shared)
        XCTAssertNil(hosted.pushOrigin)
    }
}
