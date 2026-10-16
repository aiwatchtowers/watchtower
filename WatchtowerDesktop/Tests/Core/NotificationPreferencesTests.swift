import XCTest
@testable import WatchtowerCore

final class NotificationPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "NotificationPreferencesTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testPauseIsOffUntilSwitchedOn() {
        XCTAssertFalse(NotificationPreferences.isPaused(defaults))
        defaults.set(true, forKey: NotificationPreferences.pausedKey)
        XCTAssertTrue(NotificationPreferences.isPaused(defaults))
        defaults.set(false, forKey: NotificationPreferences.pausedKey)
        XCTAssertFalse(NotificationPreferences.isPaused(defaults))
    }

    func testBriefingNotificationsAreOnUntilSwitchedOff() {
        XCTAssertTrue(NotificationPreferences.briefingEnabled(defaults), "absent = on, the toggle's default")
        defaults.set(false, forKey: NotificationPreferences.briefingKey)
        XCTAssertFalse(NotificationPreferences.briefingEnabled(defaults))
        defaults.set(true, forKey: NotificationPreferences.briefingKey)
        XCTAssertTrue(NotificationPreferences.briefingEnabled(defaults))
    }

    /// The renamed switches keep their stored keys, so a value saved under
    /// the old labels carries over.
    func testRenamedSwitchesKeepTheirStoredKeys() {
        XCTAssertEqual(NotificationPreferences.pausedKey, "quietHoursEnabled")
        XCTAssertEqual(NotificationPreferences.briefingKey, "notifyDailySummary")
    }
}
