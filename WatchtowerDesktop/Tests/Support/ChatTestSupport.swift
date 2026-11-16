import Foundation

/// A settable clock for policy/driver tests (`clock: { testClock.now }`).
package final class ChatTestClock: @unchecked Sendable {
    package var now: Date

    package init(now: Date = Date(timeIntervalSinceReferenceDate: 0)) {
        self.now = now
    }

    package func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

/// Waits on the main actor until `condition` holds — re-checked once per main-actor turn, no clock and no
/// deadline (`untilTurn`; a hang is the lane watchdog's to report). Always returns true, so the existing
/// `XCTAssertTrue(await waitForCondition { … })` call sites read the same.
@MainActor
@discardableResult
package func waitForCondition(_ condition: () -> Bool) async -> Bool {
    await untilTurn(condition)
    return true
}
