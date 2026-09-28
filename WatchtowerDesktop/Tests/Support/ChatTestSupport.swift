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

/// Polls `condition` on the main actor until it holds or `timeout` passes (a
/// deadline, not a spin count). Returns the final verdict so the caller
/// asserts it: `XCTAssertTrue(await waitForCondition { … })`.
@MainActor
package func waitForCondition(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let start = ContinuousClock.now
    while ContinuousClock.now - start < timeout {
        if condition() { return true }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}
