import Foundation
import UserNotifications
import XCTest
@testable import WatchtowerDesktop

/// `NotificationDelegate.route` — the notification-response dispatch table, and the
/// `forwarded` gate that downgrades a response handed over by a deferring duplicate to
/// navigation only. `route` is a static `@MainActor` function over a plain `AppState`,
/// so it is exercised directly; only the `UNUserNotificationCenter` delegate callback
/// wrapping it needs live UN plumbing and stays out of `swift test`.
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

    /// A forwarded "Stop recording" click stops nothing: it navigates, leaving the
    /// recorder untouched (an in-flight capture keeps running).
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

    /// A forwarded plain tap on a stop-recording push takes the same navigation branch
    /// as the self-received one — the gate does not change what a non-action tap does.
    func testForwardedStopRecordingPlainTapNavigates() async {
        let appState = AppState()

        await NotificationDelegate.route(
            actionID: UNNotificationDefaultActionIdentifier,
            userInfo: ["type": "meeting_stop_recording"],
            appState: appState,
            forwarded: true
        )

        XCTAssertEqual(appState.selectedDestination, .calendar)
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
