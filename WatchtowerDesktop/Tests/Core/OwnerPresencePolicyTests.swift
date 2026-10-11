import XCTest
import WatchtowerCore

final class OwnerPresencePolicyTests: XCTestCase {
    private func present(
        appActive: Bool = true,
        shows: OwnerPresencePolicy.KeyWindow = .workbenchSession,
        selected: Int64? = 7,
        locked: Bool = false,
        asleep: Bool = false
    ) -> Int64? {
        OwnerPresencePolicy.presentSession(
            appActive: appActive, keyWindowShows: shows, selectedSession: selected,
            screenLocked: locked, displaysAsleep: asleep
        )
    }

    func testTheSelectedSessionOfTheKeyWorkbenchWindowIsPresent() {
        XCTAssertEqual(present(), 7)
    }

    func testAppInactiveIsAbsent() {
        XCTAssertNil(present(appActive: false))
    }

    func testKeyWindowShowingSomethingElseIsAbsent() {
        XCTAssertNil(present(shows: .other))
    }

    func testNoSelectedSessionIsAbsent() {
        XCTAssertNil(present(selected: nil))
    }

    /// E32: the window stays key under a locked screen.
    func testLockedScreenIsAbsent() {
        XCTAssertNil(present(locked: true))
        XCTAssertNil(present(shows: .workbenchSessionWithAskDrawer, locked: true))
    }

    func testDisplaysAsleepIsAbsent() {
        XCTAssertNil(present(asleep: true))
    }

    func testAnotherSessionOnScreenIsThatSession() {
        XCTAssertEqual(present(selected: 9), 9)
    }

    func testDrawerOpenIsStillPresent() {
        XCTAssertEqual(present(shows: .workbenchSessionWithAskDrawer), 7)
    }
}
