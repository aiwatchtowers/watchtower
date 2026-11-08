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

    /// Producer → consumer: the userInfo the notification extension builds (`WorkAlertContent`) routes every event.
    func testEveryWorkAlertEventRoutesFromTheKitsUserInfo() {
        let cases: [(WorkAlertPayload.Event, AlertDestination)] = [
            (.ask, .ask(hubID: "hub-a", askID: 109)),
            (.permission, .session(hubID: "hub-a", sessionID: 11)),
            (.sessionStopped, .session(hubID: "hub-a", sessionID: 11)),
            (.sessionFailed, .session(hubID: "hub-a", sessionID: 11))
        ]
        for (event, expected) in cases {
            let payload = WorkAlertPayload(
                event: event, key: "k", workbenchID: 1, workbenchName: "acme", sessionID: 11,
                askID: event == .ask ? 109 : nil, requestID: event == .permission ? 5 : nil,
                title: "acme", body: "body", quick: false
            )
            let content = WorkAlertContent(payload: payload, hubID: "hub-a")
            XCTAssertEqual(content.userInfo[WorkAlertContent.Key.hub], "hub-a")
            XCTAssertEqual(AlertDestination.destination(userInfo: content.userInfo), expected, event.rawValue)
        }
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

    /// A workchat or ask form opened any way (not only from an alert) keeps its own alerts quiet while it is on top.
    func testAnyOpenAlertScreenSuppressesItsBanner() {
        let navigation = AppNavigation()
        let session = AlertDestination.session(hubID: "hub-a", sessionID: 11)
        let ask = AlertDestination.ask(hubID: "hub-a", askID: 109)
        navigation.tab = .now
        navigation.screenAppeared(session)
        XCTAssertEqual(navigation.alertOnScreen, session, "opened from the Now tab, not from an alert")
        navigation.screenAppeared(ask)
        navigation.screenDisappeared(session)
        XCTAssertEqual(navigation.alertOnScreen, ask, "the covered screen's late disappear leaves the new one")
        navigation.screenDisappeared(ask)
        XCTAssertNil(navigation.alertOnScreen)
        navigation.show(session)
        XCTAssertEqual(navigation.alertOnScreen, session, "falls back to the opened alert")
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
        let beforeDelivery = old.addingTimeInterval(-60)
        let stopped = try snapshot(sessionOverrides: ["state_kind": "finished", "state_at": Int(now.timeIntervalSince1970)])
        XCTAssertEqual(sweep([stop], stopped), [], "still the same stop")
        let later = try snapshot(sessionOverrides: ["state_kind": "finished", "state_at": Int(now.timeIntervalSince1970) + 60])
        XCTAssertEqual(sweep([stop], later), ["n"], "a newer state")
        let staleWorking = try snapshot(sessionOverrides: ["state_kind": "working", "state_at": Int(now.timeIntervalSince1970)])
        XCTAssertEqual(
            sweep([stop], staleWorking, fetched: beforeDelivery), [],
            "a working state no later than the stop, with no fetch since the delivery, may predate the stop"
        )
        let laterWorking = try snapshot(sessionOverrides: ["state_kind": "working", "state_at": Int(now.timeIntervalSince1970) + 60])
        XCTAssertEqual(sweep([stop], laterWorking, fetched: beforeDelivery), ["n"], "works again after the stop")
        XCTAssertEqual(sweep([stop], staleWorking, fetched: now.addingTimeInterval(-60)), ["n"], "working, fetched after the delivery")
        let fresh = alert("stop-77-\(stopMs)", at: now.addingTimeInterval(-5))
        XCTAssertEqual(sweep([fresh], laterWorking), [], "inside the grace age")
    }

    func testAFailedSessionAlertUsesTheSameStopKey() throws {
        let key = WorkAlertKey.stop(session: 77, stateAt: now)
        let working = try snapshot(sessionOverrides: ["state_kind": "working", "state_at": Int(now.timeIntervalSince1970)])
        XCTAssertEqual(sweep([alert(key)], working, fetched: old.addingTimeInterval(-60)), [], "no fetch since the delivery")
        XCTAssertEqual(sweep([alert(key)], working), ["n"], "fetched after the delivery")
    }

    /// The key the hub builds (`WorkAlertKey.stop`) from a fractional stamp is the one the sweep compares against.
    func testAStopKeyFromAFractionalStampMatchesTheReplicasState() throws {
        let stateAt = now.addingTimeInterval(0.4567)
        let key = WorkAlertKey.stop(session: 77, stateAt: stateAt)
        let same = try snapshot(sessionOverrides: ["state_kind": "finished", "state_at": stateAt.timeIntervalSince1970])
        XCTAssertEqual(sweep([alert(key)], same), [], "the same stop, to the millisecond")
        let next = try snapshot(sessionOverrides: ["state_kind": "finished", "state_at": stateAt.timeIntervalSince1970 + 0.002])
        XCTAssertEqual(sweep([alert(key)], next), ["n"], "a state two milliseconds later is a new one")
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
                    (id: "mine", date: self.old, userInfo: [WorkAlertContent.Key.hub: "hub-a", WorkAlertContent.Key.key: "ask-99999"]),
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

    // MARK: - HubSession wiring

    /// Every successful fetch sweeps, even one whose snapshot did not change (no replica observation fires then):
    /// the fetch itself is what makes an absence or a working state trustworthy.
    func testAFetchThatChangesNothingStillSweeps() async throws {
        var sweeps = 0
        let cleaner = DeliveredAlertCleaner(delivered: { sweeps += 1; return [] }, remove: { _ in })
        let sleeper = TickSleeper()
        let clock = MutableClock()
        let env = try HubSession(
            transport: InMemoryCloudTransport(),
            replicaPath: try makeReplicaPath(),
            backend: .inMemoryDemo,
            defaults: try makeDefaults(),
            recordingsDirectory: try makeRecordingsDirectory(),
            alertCleaner: cleaner,
            now: { clock.now },
            remoteFetch: { _ in },
            sleep: { try await sleeper.sleep($0) }
        )
        addTeardownBlock { @MainActor in env.stop() }
        try await poll({ env.isLooping && sleeper.waitingCount == 1 && env.lastSyncAt != nil && sweeps > 0 }, "booted")
        for _ in 0..<20 { await Task.yield() }
        let before = sweeps
        clock.advance(30)

        let outcome = await env.handlePush(inForeground: true)

        XCTAssertEqual(outcome, .noData, "nothing new arrived")
        try await poll({ sweeps > before }, "the fetch swept the delivered alerts")
    }

    /// The sweep judges a fetch by what that fetch brought in: an ask and a stopped state that arrive in this very
    /// hydrate keep their alerts (the screens' snapshot may still predate them), and a truly settled alert goes.
    func testAFetchSweepsWithTheReplicaItHydratedNotAnOlderSnapshot() async throws {
        let delivered = Date().addingTimeInterval(-600)
        let stoppedAt = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 300).rounded())
        let stopKey = WorkAlertKey.stop(session: 10, stateAt: stoppedAt)
        var removed: Set<String> = []
        let hubID = DemoSeed.hubID
        let cleaner = DeliveredAlertCleaner(
            delivered: {
                [
                    (id: "arriving-ask", date: delivered, userInfo: [WorkAlertContent.Key.hub: hubID, WorkAlertContent.Key.key: "ask-900"]),
                    (id: "arriving-stop", date: delivered, userInfo: [WorkAlertContent.Key.hub: hubID, WorkAlertContent.Key.key: stopKey]),
                    (id: "settled", date: delivered, userInfo: [WorkAlertContent.Key.hub: hubID, WorkAlertContent.Key.key: "ask-99999"])
                ]
            },
            remove: { removed.formUnion($0) }
        )
        let transport = InMemoryCloudTransport()
        let defaults = try makeDefaults()
        let sleeper = TickSleeper()
        let env = try HubSession(
            transport: transport, replicaPath: try makeReplicaPath(), backend: .inMemoryDemo, defaults: defaults,
            recordingsDirectory: try makeRecordingsDirectory(), alertCleaner: cleaner,
            sleep: { try await sleeper.sleep($0) } // swiftlint:disable:this trailing_closure
        )
        addTeardownBlock { @MainActor in env.stop() }
        try await poll({ env.isLooping && sleeper.waitingCount == 1 && removed.contains("settled") }, "booted and swept")
        XCTAssertEqual(try XCTUnwrap(env.workbenchReplica.snapshot.session(10)).stateKind, .working, "the demo session works")

        let hub = DemoSeed.hubTransport(inner: transport, seq: DemoSeed.hubSeq(defaults: defaults, now: Date()))
        try await hub.save([
            try DemoSeed.record(kind: .ownerAsk, id: 900, json: DemoSeed.JSON.ask(900, workbench: DemoSeed.acmeID), modifiedAt: Date()),
            try DemoSeed.record(
                kind: .terminalSession, id: 10,
                json: DemoSeed.JSON.session(10, workbench: DemoSeed.acmeID, [
                    "state_kind": "stopped", "state_at": stoppedAt.timeIntervalSince1970
                ]),
                modifiedAt: Date()
            )
        ])
        removed = []

        let outcome = await env.handlePush(inForeground: true)

        XCTAssertEqual(outcome, .newData)
        try await poll({ removed.contains("settled") }, "the fetch swept")
        try await poll({ env.workbenchReplica.snapshot.openAsks().contains { $0.id == 900 } }, "the screens caught up")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(removed, ["settled"], "an ask and a stop that arrived in this fetch keep their alerts")
    }
}
