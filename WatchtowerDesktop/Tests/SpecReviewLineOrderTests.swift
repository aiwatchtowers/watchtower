import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// `SpecReviewLineOrder` (spec 2026-11-08 §3): one spec review line at a
/// time per session in filing order; a line nobody asks for again leaves
/// after `staleAfter`; an overlapping ask for the line being tried waits.
@MainActor
final class SpecReviewLineOrderTests: XCTestCase {
    /// The fake clock and session the order runs against.
    @MainActor
    private final class Stand {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        var tried: [String] = []
        var answers: [SessionLineDelivery.Delivery] = []
    }

    private var stand = Stand()
    private var clock: Date {
        get { stand.clock }
        set { stand.clock = newValue }
    }
    private var tried: [String] { stand.tried }
    private var answers: [SessionLineDelivery.Delivery] {
        get { stand.answers }
        set { stand.answers = newValue }
    }

    private func makeOrder(
        deliver: SpecReviewLineOrder.Deliver? = nil
    ) -> SpecReviewLineOrder {
        let stand = stand
        return SpecReviewLineOrder(now: { stand.clock }, deliver: deliver ?? { line, _, _ in
            stand.tried.append(line)
            return stand.answers.isEmpty ? .submitted : stand.answers.removeFirst()
        })
    }

    /// A held first line keeps a later one queued until `staleAfter` passes
    /// without the first being asked for again; then the later one goes.
    func testAStaleLineStopsBlockingTheSession() async {
        let order = makeOrder()
        answers = [.held]
        let first = await order.send("findings", key: .specReview(1), sessionID: 9)
        XCTAssertEqual(first, .held)
        let second = await order.send("question", key: .specReviewQuestion(5), sessionID: 9)
        XCTAssertEqual(second, .queued, "behind the held findings line")
        XCTAssertEqual(tried, ["findings"])

        clock = clock.addingTimeInterval(SpecReviewLineOrder.staleAfter)
        let stillQueued = await order.send("question", key: .specReviewQuestion(5), sessionID: 9)
        XCTAssertEqual(stillQueued, .queued, "exactly staleAfter is not stale yet")

        clock = clock.addingTimeInterval(1)
        let went = await order.send("question", key: .specReviewQuestion(5), sessionID: 9)
        XCTAssertEqual(went, .submitted)
        XCTAssertEqual(tried, ["findings", "question"])
    }

    /// Another session's order is its own.
    func testSessionsDoNotBlockEachOther() async {
        let order = makeOrder()
        answers = [.held]
        _ = await order.send("findings", key: .specReview(1), sessionID: 9)
        let other = await order.send("question", key: .specReviewQuestion(5), sessionID: 10)
        XCTAssertEqual(other, .submitted)
    }

    /// The same line asked again while its try is still running is queued,
    /// never typed twice.
    func testAnOverlappingSendOfTheSameLineIsQueued() async {
        var release: CheckedContinuation<Void, Never>?
        var calls = 0
        let order = makeOrder { _, _, _ in
            calls += 1
            await withCheckedContinuation { release = $0 }
            return .submitted
        }
        let firstTry = Task { await order.send("findings", key: .specReview(1), sessionID: 9) }
        while release == nil { await Task.yield() }
        let overlap = await order.send("findings", key: .specReview(1), sessionID: 9)
        XCTAssertEqual(overlap, .queued)
        release?.resume()
        let first = await firstTry.value
        XCTAssertEqual(first, .submitted)
        XCTAssertEqual(calls, 1)
    }
}
