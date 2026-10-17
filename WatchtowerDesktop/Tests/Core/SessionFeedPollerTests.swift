import XCTest
@testable import WatchtowerCore

@MainActor
final class SessionFeedPollerTests: XCTestCase {
    func testRequestDuringARunYieldsExactlyOneMoreRunEvenWhenTheFirstCallerIsCancelled() async {
        var runs = 0
        var gate: CheckedContinuation<Void, Never>?
        let poller = SessionFeedPoller {
            runs += 1
            if runs == 1 { await withCheckedContinuation { gate = $0 } }
        }
        let first = Task { await poller.refresh() }
        while gate == nil { await Task.yield() }
        first.cancel()
        let second = Task { await poller.refresh() }
        let third = Task { await poller.refresh() }
        await Task.yield()
        gate?.resume()
        await first.value
        await second.value
        await third.value
        XCTAssertEqual(runs, 2, "two requests during one run fold into one more run")
        await poller.refresh()
        XCTAssertEqual(runs, 3, "an idle poller runs again")
    }
}
