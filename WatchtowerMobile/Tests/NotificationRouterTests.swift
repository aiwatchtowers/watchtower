import Foundation
import UserNotifications
import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// A tapped work alert opens its screen, a foreground one stays quiet over its own screen, and settled alerts leave
/// Notification Center.
@MainActor
final class NotificationRouterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func info(_ event: String, hub: String = "hub-a", session: String? = nil, ask: String? = nil) -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = ["wt_hub": hub, "wt_event": event, "wt_key": "k"]
        if let session { info["wt_session"] = session }
        if let ask { info["wt_ask"] = ask }
        return info
    }

    // MARK: - destination(userInfo:)

    func testAnAskEventOpensItsAsk() {
        XCTAssertEqual(AlertDestination.destination(userInfo: info("ask", ask: "109")), .ask(hubID: "hub-a", askID: 109))
    }

    func testPermissionStoppedAndFailedOpenTheSession() {
        for event in ["permission", "session_stopped", "session_failed"] {
            XCTAssertEqual(
                AlertDestination.destination(userInfo: info(event, session: "11")), .session(hubID: "hub-a", sessionID: 11), event
            )
        }
    }

    func testAnAlertWithoutItsIdsOrHubOpensNothing() {
        XCTAssertNil(AlertDestination.destination(userInfo: info("ask")))
        XCTAssertNil(AlertDestination.destination(userInfo: info("session_stopped")))
        XCTAssertNil(AlertDestination.destination(userInfo: info("session_stopped", session: "x")))
        XCTAssertNil(AlertDestination.destination(userInfo: info("bogus", session: "11")))
        XCTAssertNil(AlertDestination.destination(userInfo: ["aps": ["alert": "hi"]]))
        XCTAssertNil(AlertDestination.destination(userInfo: info("ask", hub: "", ask: "1")))
    }

    // MARK: - Navigation and foreground presentation

    func testShowingADestinationSelectsTheWorkbenchTabAndPushesItsRoute() {
        let navigation = AppNavigation()
        navigation.show(.ask(hubID: "hub-a", askID: 109))
        XCTAssertEqual(navigation.tab, .workbench)
        XCTAssertEqual(navigation.workbenchPath.count, 1)
        XCTAssertEqual(navigation.alertOnScreen, .ask(hubID: "hub-a", askID: 109))
        navigation.show(.session(hubID: "hub-a", sessionID: 11))
        XCTAssertEqual(navigation.workbenchPath.count, 1, "one screen over the root, never a stack of alerts")
        XCTAssertEqual(navigation.alertOnScreen, .session(hubID: "hub-a", sessionID: 11))
    }

    func testTheScreenIsNoLongerOnTopOncePoppedCoveredOrLeft() {
        let navigation = AppNavigation()
        navigation.show(.session(hubID: "hub-a", sessionID: 11))
        navigation.workbenchPath.append(AskRoute(id: 1))
        XCTAssertNil(navigation.alertOnScreen, "covered")
        navigation.workbenchPath.removeLast(2)
        XCTAssertNil(navigation.alertOnScreen, "popped")
        navigation.workbenchPath.append(SessionRoute(id: 11))
        XCTAssertNil(navigation.alertOnScreen, "a different screen at the same depth is not the alert's")
        navigation.show(.session(hubID: "hub-a", sessionID: 11))
        navigation.tab = .now
        XCTAssertNil(navigation.alertOnScreen, "another tab")
    }

    func testAHubSwitchResetsTheWorkbenchStack() {
        let navigation = AppNavigation()
        navigation.show(.session(hubID: "hub-a", sessionID: 11))
        navigation.resetStacks()
        XCTAssertEqual(navigation.workbenchPath.count, 0)
        XCTAssertNil(navigation.alertOnScreen)
    }

    func testForegroundAlertsShowUnlessTheirScreenIsOpen() {
        let session = AlertDestination.session(hubID: "hub-a", sessionID: 11)
        XCTAssertEqual(AlertDestination.foregroundOptions(for: session, onScreen: nil), [.banner, .sound])
        XCTAssertEqual(AlertDestination.foregroundOptions(for: session, onScreen: .session(hubID: "hub-a", sessionID: 12)), [.banner, .sound])
        XCTAssertEqual(AlertDestination.foregroundOptions(for: session, onScreen: .session(hubID: "hub-b", sessionID: 11)), [.banner, .sound])
        XCTAssertEqual(AlertDestination.foregroundOptions(for: nil, onScreen: session), [.banner, .sound])
        XCTAssertEqual(AlertDestination.foregroundOptions(for: session, onScreen: session), [])
    }

    // MARK: - ResolvedAlerts

    private func snapshot(
        asks: [OwnerAsk]? = nil, permissions: [Int64] = [], sessionOverrides: [String: Any] = [:]
    ) throws -> WorkbenchReplicaSnapshot {
        var snapshot = try demoSnapshot(now: now)
        if let asks { snapshot.asks = asks }
        snapshot.permissionRequests = try permissions.map { try mirror(PermissionRequest.self, permissionRequestJSON($0, session: 11)) }
        let session = DemoSeed.JSON.session(77, workbench: DemoSeed.acmeID, sessionOverrides)
        snapshot.sessions.append(try mirror(TerminalSessionState.self, session))
        return snapshot
    }

    private let old = Date(timeIntervalSince1970: 1_800_000_000 - 600)
    private func alert(_ key: String, id: String = "n", at: Date? = nil) -> DeliveredAlert {
        DeliveredAlert(id: id, key: key, deliveredAt: at ?? old)
    }

    private func sweep(_ alerts: [DeliveredAlert], _ snapshot: WorkbenchReplicaSnapshot, fetched: Date? = nil) -> [String] {
        ResolvedAlerts.keysToRemove(delivered: alerts, snapshot: snapshot, fetchedAt: fetched ?? now.addingTimeInterval(-60), now: now)
    }

    func testAnAskAlertStaysWhileTheAskIsOpenAndGoesWhenItIsNot() throws {
        let snapshot = try snapshot()
        let open = try XCTUnwrap(snapshot.openAsks().first).id
        XCTAssertEqual(sweep([alert("ask-\(open)")], snapshot), [])
        XCTAssertEqual(sweep([alert("ask-99999")], snapshot), ["n"])
    }

    func testAFreshAlertWhoseEntityIsMissingFromTheReplicaIsKept() throws {
        let snapshot = try snapshot()
        let fresh = alert("ask-99999", at: now.addingTimeInterval(-10))
        XCTAssertEqual(sweep([fresh], snapshot, fetched: now), [], "inside the grace age")
        let justOver = alert("ask-99999", at: now.addingTimeInterval(-ResolvedAlerts.graceAge))
        XCTAssertEqual(sweep([justOver], snapshot, fetched: now), ["n"], "past the grace age, fetched after delivery")
    }

    func testAnAbsenceRuleNeedsAFetchAfterTheDelivery() throws {
        let snapshot = try snapshot(permissions: [5])
        let delivered = alert("perm-6", at: now.addingTimeInterval(-300))
        XCTAssertEqual(sweep([delivered], snapshot, fetched: now.addingTimeInterval(-400)), [], "replica older than the alert")
        XCTAssertEqual(ResolvedAlerts.keysToRemove(delivered: [delivered], snapshot: snapshot, fetchedAt: nil, now: now), [])
        XCTAssertEqual(sweep([delivered], snapshot, fetched: now.addingTimeInterval(-100)), ["n"])
    }

    func testAPermissionAlertGoesWhenTheRequestIsNoLongerPending() throws {
        let snapshot = try snapshot(permissions: [5])
        XCTAssertEqual(sweep([alert("perm-5", id: "a"), alert("perm-6", id: "b")], snapshot), ["b"])
    }

    func testAStopAlertGoesWhenTheSessionWorksAgainOrMovedOn() throws {
        let stopMs = Int64(now.timeIntervalSince1970 * 1000)
        let stop = alert("stop-77-\(stopMs)")
        let stopped = try snapshot(sessionOverrides: ["state_kind": "finished", "state_at": Int(now.timeIntervalSince1970)])
        XCTAssertEqual(sweep([stop], stopped), [], "still the same stop")
        let later = try snapshot(sessionOverrides: ["state_kind": "finished", "state_at": Int(now.timeIntervalSince1970) + 60])
        XCTAssertEqual(sweep([stop], later), ["n"], "a newer state")
        let working = try snapshot(sessionOverrides: ["state_kind": "working", "state_at": Int(now.timeIntervalSince1970)])
        XCTAssertEqual(sweep([stop], working), ["n"], "works again")
        let fresh = alert("stop-77-\(stopMs)", at: now.addingTimeInterval(-5))
        XCTAssertEqual(sweep([fresh], working), [], "a stale working state inside the grace age")
    }

    func testAFailedSessionAlertUsesTheSameStopKey() throws {
        let key = WorkAlertKey.stop(session: 77, stateAt: now)
        let working = try snapshot(sessionOverrides: ["state_kind": "working"])
        XCTAssertEqual(sweep([alert(key)], working), ["n"])
    }

    func testUnknownKeysMissingSessionsAndAnUnloadedReplicaKeepTheirAlerts() throws {
        let snapshot = try snapshot()
        XCTAssertEqual(sweep([alert("other-1", id: "a"), alert("stop-4040-1", id: "b"), alert("ask-x", id: "c")], snapshot), [])
        XCTAssertEqual(sweep([alert("ask-99999")], WorkbenchReplicaSnapshot()), [])
    }

    func testTheCleanerRemovesOnlyThisHubsSettledAlerts() async throws {
        var removed: [[String]] = []
        let cleaner = DeliveredAlertCleaner(
            delivered: {
                [
                    (id: "mine", date: self.old, userInfo: ["wt_hub": "hub-a", "wt_key": "ask-99999"]),
                    (id: "other-hub", date: self.old, userInfo: ["wt_hub": "hub-b", "wt_key": "ask-99999"]),
                    (id: "fresh", date: self.now, userInfo: ["wt_hub": "hub-a", "wt_key": "ask-99998"]),
                    (id: "generic", date: self.old, userInfo: [:])
                ]
            },
            remove: { removed.append($0) }
        )
        await cleaner.clear(hubID: "hub-a", snapshot: try snapshot(), fetchedAt: now, now: now)
        XCTAssertEqual(removed, [["mine"]])
    }
}
