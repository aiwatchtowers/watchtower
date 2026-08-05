import Foundation
import UserNotifications
import XCTest
@testable import WatchtowerDesktop

/// `NotificationDelegate.route` — the notification-response dispatch table, and the
/// `forwarded` gate that downgrades a response handed over by a deferring duplicate to
/// navigation only. `route` and `routeForwarded` are static `@MainActor` functions over
/// a plain `AppState`, so they are exercised directly.
///
/// Two links in the chain stay untestable here and are covered by inspection instead:
/// `WatchtowerApp.init`'s `forwardMode` wiring (constructing the app is a single-instance
/// decision with process-wide side effects) and the `didReceive` delegate branch
/// (`UNNotificationResponse` has no public initializer, so no test can synthesize one).
@MainActor
final class NotificationRouteTests: XCTestCase {

    // MARK: - Forwarded responses are navigation-only

    /// The load-bearing one: the forwarding bus is unauthenticated, so a "Join + Record"
    /// arriving over it must not arm a recording or open the conference link. It lands
    /// the user on the Calendar tab and nothing else.
    func testForwardedMeetingReminderNavigatesWithoutOpeningTheLink() async {
        let appState = AppState()
        var opened: [URL] = []

        await NotificationDelegate.route(
            actionID: NotificationService.joinRecordActionID,
            userInfo: [
                "type": "meeting_reminder",
                "conferenceUrl": "https://meet.google.com/abc-defg-hij",
                "eventId": "evt-1"
            ],
            appState: appState,
            forwarded: true
        ) { opened.append($0); return true }

        XCTAssertEqual(appState.selectedDestination, .calendar)
        XCTAssertTrue(opened.isEmpty, "a forwarded action-button response must never open a URL")
    }

    /// The negative control for the test above: the same input on the self-received path
    /// DOES reach `handleMeetingReminderAction` (and its conferenceUrl fallback), so the
    /// forwarded assertion is proving the gate, not an inert code path.
    func testSelfReceivedMeetingReminderStillReachesTheJoinHandler() async {
        var opened: [URL] = []

        await NotificationDelegate.route(
            actionID: NotificationService.joinRecordActionID,
            userInfo: [
                "type": "meeting_reminder",
                "conferenceUrl": "https://meet.google.com/abc-defg-hij"
            ],
            appState: nil,
            forwarded: false
        ) { opened.append($0); return true }

        XCTAssertEqual(opened, [URL(string: "https://meet.google.com/abc-defg-hij")])
    }

    /// A forwarded "Stop recording" click stops nothing: it takes the navigation branch
    /// instead of `stopAndProcess`. The recorder is untouched — this fresh center never
    /// started a capture, so `isCapturing` is a floor check that the forwarded path did
    /// not somehow arm one, not proof that an in-flight capture would survive (driving a
    /// real capture needs audio hardware and stays out of `swift test`).
    func testForwardedStopRecordingOnlyNavigates() async {
        let appState = AppState()

        await NotificationDelegate.route(
            actionID: NotificationService.stopRecordingActionID,
            userInfo: ["type": "meeting_stop_recording"],
            appState: appState,
            forwarded: true
        )

        XCTAssertEqual(appState.selectedDestination, .calendar)
        XCTAssertFalse(appState.meetingRecorderCenter.isCapturing)
    }

    /// The self-received counterpart: a plain tap on a stop-recording push navigates
    /// too, because it is not the Stop action id. The `forwarded` flag is not what
    /// makes this branch navigate — a non-action tap does the same thing either way,
    /// which is why the forwarded assertion above is about the action id, not the tap.
    func testSelfReceivedStopRecordingPlainTapNavigates() async {
        let appState = AppState()

        await NotificationDelegate.route(
            actionID: UNNotificationDefaultActionIdentifier,
            userInfo: ["type": "meeting_stop_recording"],
            appState: appState,
            forwarded: false
        )

        XCTAssertEqual(appState.selectedDestination, .calendar)
    }

    /// The survivor-side entry point applies the navigation-only policy itself: callers
    /// hand it a decoded response, not a `forwarded` flag they could forget to pass.
    /// Driven end to end over the wire codec, so a "Join + Record" push arrives stripped
    /// of its `conferenceUrl` and routes to the Calendar tab, arming nothing — `route`'s
    /// live `openURL` default is left in place here precisely because a regression would
    /// have to find a URL first, and the allowlist never ships one.
    func testRouteForwardedAppliesTheNavigationOnlyPolicy() async {
        let appState = AppState()
        let json = NotificationForwarding.encode(
            actionID: NotificationService.joinRecordActionID,
            userInfo: [
                "type": "meeting_reminder",
                "eventId": "evt-1",
                "conferenceUrl": "https://meet.google.com/abc-defg-hij"
            ]
        )
        guard let json, let response = NotificationForwarding.decode(json) else {
            return XCTFail("the response did not survive the wire codec")
        }

        await NotificationDelegate.routeForwarded(response, appState: appState)

        XCTAssertEqual(appState.selectedDestination, .calendar)
        XCTAssertFalse(appState.meetingRecorderCenter.isCapturing)
        XCTAssertNil(response.userInfo["conferenceUrl"], "the allowlist drops it before the wire")
    }

    /// A nil `appState` is the launch-race case on the forwarded path too: it must
    /// no-op rather than trap.
    func testRouteForwardedWithNilAppStateNeverCrashes() async {
        await NotificationDelegate.routeForwarded(
            ForwardedNotificationResponse(
                actionID: NotificationService.stopRecordingActionID,
                payload: ["type": "meeting_stop_recording"]
            ),
            appState: nil
        )
    }

    /// Tripwire over every push `type` the app emits, plus `task_overdue` (routed but
    /// no longer emitted by `NotificationService`). Each type is driven forwarded with
    /// every action id that arms something, and the `openURL` seam must stay untouched
    /// throughout. A future action-bearing push type that forgets the `forwarded` gate
    /// fails here rather than shipping a bus-triggerable action.
    ///
    /// Keep the list in sync with `NotificationService`'s `content.userInfo` sites.
    func testNoPushTypeArmsAnActionWhenForwarded() async {
        let pushTypes = [
            "decision", "track", "track_update", "task_overdue", "target_extract",
            "daily_summary", "meeting_reminder", "meeting_stop_recording",
            "test", "briefing", "board_config_changed", "meeting_transcript"
        ]
        let actionIDs = [
            UNNotificationDefaultActionIdentifier,
            NotificationService.joinActionID,
            NotificationService.joinRecordActionID,
            NotificationService.stopRecordingActionID
        ]

        for type in pushTypes {
            for actionID in actionIDs {
                let appState = AppState()
                var opened: [URL] = []

                await NotificationDelegate.route(
                    actionID: actionID,
                    userInfo: [
                        "type": type,
                        "eventId": "evt-1",
                        "conferenceUrl": "https://meet.google.com/abc-defg-hij"
                    ],
                    appState: appState,
                    forwarded: true
                ) { opened.append($0); return true }

                XCTAssertTrue(opened.isEmpty, "\(type) / \(actionID) opened a URL on the forwarded path")
                XCTAssertFalse(
                    appState.meetingRecorderCenter.isCapturing,
                    "\(type) / \(actionID) armed a capture on the forwarded path"
                )
                if type == "meeting_stop_recording" || type == "meeting_reminder" {
                    XCTAssertEqual(appState.selectedDestination, .calendar, "\(type) / \(actionID)")
                }
            }
        }
    }

    // MARK: - Dispatch table

    /// A decision push carrying a digest id opens that digest; without one it can only
    /// land on the tab.
    func testDecisionRoutesToDigest() async {
        let withID = AppState()
        await NotificationDelegate.route(
            actionID: UNNotificationDefaultActionIdentifier,
            userInfo: ["type": "decision", "digestId": 4242],
            appState: withID,
            forwarded: true
        )
        XCTAssertEqual(withID.selectedDestination, .digests)
        XCTAssertEqual(withID.pendingDigestID, 4242)

        let withoutID = AppState()
        await NotificationDelegate.route(
            actionID: UNNotificationDefaultActionIdentifier,
            userInfo: ["type": "decision"],
            appState: withoutID,
            forwarded: true
        )
        XCTAssertEqual(withoutID.selectedDestination, .digests)
        XCTAssertNil(withoutID.pendingDigestID)
    }

    /// The navigation-only types, forwarded and self-received alike: same table, same
    /// destination — the gate touches only the action-bearing branches.
    func testNavigationTypesRouteToTheirTab() async {
        let cases: [(type: String, destination: SidebarDestination)] = [
            ("track", .tracks),
            ("track_update", .tracks),
            ("task_overdue", .targets),
            ("target_extract", .targets),
            ("daily_summary", .digests)
        ]

        for forwarded in [true, false] {
            for (type, destination) in cases {
                let appState = AppState()
                await NotificationDelegate.route(
                    actionID: UNNotificationDefaultActionIdentifier,
                    userInfo: ["type": type],
                    appState: appState,
                    forwarded: forwarded
                )
                XCTAssertEqual(
                    appState.selectedDestination,
                    destination,
                    "type \(type) (forwarded: \(forwarded))"
                )
            }
        }
    }

    /// An unknown or absent type is not an error — routing falls through and leaves the
    /// UI where the user left it.
    func testUnknownTypeLeavesNavigationAlone() async {
        let appState = AppState()
        let initial = appState.selectedDestination

        await NotificationDelegate.route(
            actionID: UNNotificationDefaultActionIdentifier,
            userInfo: ["type": "no_such_push_type"],
            appState: appState,
            forwarded: true
        )
        await NotificationDelegate.route(
            actionID: UNNotificationDefaultActionIdentifier,
            userInfo: [:],
            appState: appState,
            forwarded: true
        )

        XCTAssertEqual(appState.selectedDestination, initial)
    }

    // MARK: - Degenerate input

    /// A tap can race app launch, leaving `sharedAppState` nil: every branch must
    /// no-op instead of trapping on the optional.
    func testNilAppStateNeverCrashes() async {
        let payloads: [[AnyHashable: Any]] = [
            ["type": "decision", "digestId": 1],
            ["type": "decision"],
            ["type": "track_update"],
            ["type": "daily_summary"],
            ["type": "meeting_reminder"],
            ["type": "meeting_stop_recording"],
            [:]
        ]

        for payload in payloads {
            for forwarded in [true, false] {
                await NotificationDelegate.route(
                    actionID: NotificationService.stopRecordingActionID,
                    userInfo: payload,
                    appState: nil,
                    forwarded: forwarded
                ) { _ in true }
            }
        }
    }

    // MARK: - Coupling

    /// The wire allowlist and what forwarded routing reads are one decision in two
    /// files. Forwarded routing reads exactly `type` (the dispatch key) and `digestId`
    /// (the one navigation argument); widening either side without the other is the
    /// failure this pins — the payload must never regrow keys only an armed action
    /// would use.
    func testForwardedAllowlistMatchesWhatForwardedRoutingReads() {
        XCTAssertEqual(NotificationForwarding.routedKeys, ["type", NotificationForwarding.digestIDKey])
        XCTAssertEqual(NotificationForwarding.digestIDKey, "digestId")
    }
}
