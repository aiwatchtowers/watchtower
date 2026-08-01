import Foundation
import XCTest
@testable import WatchtowerDesktop

/// `NotificationDelegate.handleMeetingReminderAction` fallback branches,
/// driven through the injectable `openURL` seam (the `JoinMeetingAction`
/// convention). Full delegate routing needs a live `UNUserNotificationCenter`
/// and stays out of `swift test`; these pin the event-vanished → conferenceUrl
/// fallback and the stringly "conferenceUrl" userInfo key contract written by
/// `NotificationService` and read here.
@MainActor
final class NotificationDelegateTests: XCTestCase {

    /// Event vanished between push and tap (no appState / no DB row): the
    /// Join tap still opens the link carried in the notification's userInfo.
    func testJoinFallsBackToConferenceUrlWhenEventUnavailable() async {
        var opened: [URL] = []
        await NotificationDelegate.handleMeetingReminderAction(
            actionID: NotificationService.joinActionID,
            userInfo: ["conferenceUrl": "https://meet.google.com/abc-defg-hij"],
            appState: nil
        ) { opened.append($0); return true }
        XCTAssertEqual(opened, [URL(string: "https://meet.google.com/abc-defg-hij")])
    }

    /// Join + Record uses the same fallback: with no event to record, the
    /// link still opens (recording needs the event row, joining does not).
    func testJoinRecordFallsBackToConferenceUrl() async {
        var opened: [URL] = []
        await NotificationDelegate.handleMeetingReminderAction(
            actionID: NotificationService.joinRecordActionID,
            userInfo: ["conferenceUrl": "https://company.zoom.us/j/123"],
            appState: nil
        ) { opened.append($0); return true }
        XCTAssertEqual(opened, [URL(string: "https://company.zoom.us/j/123")])
    }

    /// Degenerate userInfo: an empty (or absent) conferenceUrl must never
    /// reach openURL — the handler falls through to the visible Calendar-tab
    /// fallback instead of opening garbage.
    func testJoinWithEmptyOrMissingUrlNeverOpens() async {
        var opened: [URL] = []
        await NotificationDelegate.handleMeetingReminderAction(
            actionID: NotificationService.joinActionID,
            userInfo: ["conferenceUrl": ""],
            appState: nil
        ) { opened.append($0); return true }
        await NotificationDelegate.handleMeetingReminderAction(
            actionID: NotificationService.joinActionID,
            userInfo: [:],
            appState: nil
        ) { opened.append($0); return true }
        XCTAssertTrue(opened.isEmpty)
    }

    /// A plain tap (default action id) never opens a URL — it is a
    /// navigation-only path.
    func testPlainTapNeverOpensUrl() async {
        var opened: [URL] = []
        await NotificationDelegate.handleMeetingReminderAction(
            actionID: "com.apple.UNNotificationDefaultActionIdentifier",
            userInfo: ["conferenceUrl": "https://meet.google.com/abc-defg-hij"],
            appState: nil
        ) { opened.append($0); return true }
        XCTAssertTrue(opened.isEmpty)
    }
}
