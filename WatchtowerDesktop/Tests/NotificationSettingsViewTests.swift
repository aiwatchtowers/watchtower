import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop

@MainActor
final class NotificationSettingsViewTests: XCTestCase {

    /// Все три заголовка секций видны в дефолтном состоянии.
    func testSectionHeadersRendered() throws {
        let view = NotificationSettings()
        let inspected = try view.inspect()

        XCTAssertNoThrow(try inspected.find(text: "Notification Types"))
        XCTAssertNoThrow(try inspected.find(text: "Quiet Hours"))
        XCTAssertNoThrow(try inspected.find(text: "Test"))
    }

    /// Все три тогла присутствуют по своим лейблам.
    func testAllTogglesRendered() throws {
        let view = NotificationSettings()
        let inspected = try view.inspect()

        XCTAssertNoThrow(try inspected.find(text: "Decision notifications"))
        XCTAssertNoThrow(try inspected.find(text: "Daily summary notifications"))
        XCTAssertNoThrow(try inspected.find(text: "Enable quiet hours"))
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
