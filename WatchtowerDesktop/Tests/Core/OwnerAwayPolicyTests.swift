import XCTest
@testable import WatchtowerCore

final class OwnerAwayPolicyTests: XCTestCase {
    private func away(
        locked: Bool = false, asleep: Bool = false, idle: TimeInterval = 0, active: Bool = true
    ) -> Bool {
        OwnerAwayPolicy.isAway(screenLocked: locked, displaysAsleep: asleep, idleSeconds: idle, sessionActive: active)
    }

    func testLockedIsAway() { XCTAssertTrue(away(locked: true)) }
    func testDisplaysAsleepIsAway() { XCTAssertTrue(away(asleep: true)) }
    func testIdleUnderThresholdIsPresent() { XCTAssertFalse(away(idle: 179)) }
    func testIdleAtThresholdIsAway() { XCTAssertTrue(away(idle: 180)) }
    func testInactiveSessionIsAway() { XCTAssertTrue(away(active: false)) }
    func testPresentWhenNothingApplies() { XCTAssertFalse(away()) }
}
