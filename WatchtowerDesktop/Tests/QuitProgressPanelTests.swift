import XCTest
@testable import WatchtowerDesktop

/// The quit's progress panel (board #588): shown only when the step outlasts
/// its delay, closed when the step ends. No window is put on screen: the
/// delay and the panel are injected.
@MainActor
final class QuitProgressPanelTests: XCTestCase {
    func testAQuickStepShowsNothing() async {
        let (delay, endDelay) = AsyncStream<Void>.makeStream()
        var presented = 0
        let sleep: (Duration) async -> Void = { _ in
            var iterator = delay.makeAsyncIterator()
            _ = await iterator.next()
        }
        let present: @MainActor (String) -> () -> Void = { _ in
            presented += 1
            return {}
        }
        await QuitProgressPanel.showing("Finishing", sleep: sleep, present: present) {}
        endDelay.yield() // the delay ends after the step did
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(presented, 0)
    }

    func testASlowStepShowsThePanelUntilItEnds() async {
        var events: [String] = []
        let (shown, didShow) = AsyncStream<Void>.makeStream()
        let sleep: (Duration) async -> Void = { _ in }
        let present: @MainActor (String) -> () -> Void = { message in
            events.append("show \(message)")
            didShow.yield()
            return { events.append("close") }
        }
        await QuitProgressPanel.showing("Finishing session deletes…", sleep: sleep, present: present) {
            var iterator = shown.makeAsyncIterator()
            _ = await iterator.next() // the step outlasts the delay
            events.append("step done")
        }
        XCTAssertEqual(events, ["show Finishing session deletes…", "step done", "close"])
    }
}
