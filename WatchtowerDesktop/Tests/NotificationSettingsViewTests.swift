import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop

@MainActor
final class NotificationSettingsViewTests: XCTestCase {

    /// One Notifications section holds every switch; Test sits below it.
    func testSectionHeadersRendered() throws {
        let view = NotificationSettings()
        let inspected = try view.inspect()

        XCTAssertNoThrow(try inspected.find(text: "Notifications"))
        XCTAssertNoThrow(try inspected.find(text: "Test"))
        XCTAssertThrowsError(try inspected.find(text: "Notification Types"))
        XCTAssertThrowsError(try inspected.find(text: "Quiet Hours"))
    }

    /// Every notification switch by its label, unknown voices included (#290).
    func testAllTogglesRendered() throws {
        let view = NotificationSettings()
        let inspected = try view.inspect()

        for label in ["Pause notifications", "Decision notifications", "Briefing notifications",
                      "Workbench notifications", "Claude plan limits", "Notify about unknown voices",
                      "Meeting reminders"] {
            XCTAssertNoThrow(try inspected.find(text: label), label)
        }
    }

    /// Meeting reminders: the toggle and the minutes stepper.
    func testMeetingRemindersSectionRendered() throws {
        let view = NotificationSettings()
        let inspected = try view.inspect()

        XCTAssertNoThrow(try inspected.find(text: "Meeting reminders"))
        XCTAssertNoThrow(try inspected.find(text: "Remind before meeting"))
    }

    /// Кнопка "Send Test Notification" есть.
    func testSendButtonPresent() throws {
        let view = NotificationSettings()
        XCTAssertNoThrow(try view.inspect().find(button: "Send Test Notification"))
    }

    /// permissionStatus=nil (дефолт) → нет блока "Open Settings".
    func testNoPermissionWarningWhenStatusNil() throws {
        let view = NotificationSettings()
        XCTAssertThrowsError(try view.inspect().find(button: "Open Settings"))
        XCTAssertThrowsError(try view.inspect().find(text: "Notifications are disabled in System Settings."))
    }

    /// testSent=false → нет лейбла "Sent!".
    func testSentLabelHiddenInitially() throws {
        let view = NotificationSettings()
        XCTAssertThrowsError(try view.inspect().find(text: "Sent!"))
    }
}
