import XCTest
@testable import WatchtowerCore

@MainActor
final class LiveTurnReplaceTextTests: XCTestCase {
    func testReplaceTextSetsTheAuthoritativeText() {
        let turn = LiveTurn(messageID: 1, turnID: "t", startedAt: Date(), publishInterval: 1)
        let now = Date()
        turn.replaceText("draft", now: now)
        XCTAssertEqual(turn.text, "draft", "the first change publishes at once")
        turn.replaceText("final", now: now.addingTimeInterval(0.1))
        XCTAssertEqual(turn.fullText, "final")
        XCTAssertEqual(turn.text, "draft", "inside the interval the published copy waits")
        turn.replaceText("", now: now.addingTimeInterval(2))
        XCTAssertEqual(turn.text, "")
    }

    func testManyChangesPublishAtMostOncePerInterval() {
        let turn = LiveTurn(messageID: 1, turnID: "t", startedAt: Date(), publishInterval: 1.0 / 30)
        let start = Date()
        var published = 0
        var lastSeen = ""
        var accumulated = ""
        for index in 0..<100 {
            accumulated += "x"
            // 100 deltas inside one second.
            turn.replaceText(accumulated, now: start.addingTimeInterval(Double(index) * 0.01))
            if turn.text != lastSeen {
                published += 1
                lastSeen = turn.text
            }
        }
        XCTAssertLessThanOrEqual(published, 35, "≈30 fps over one second")
        XCTAssertEqual(turn.fullText.count, 100)
        turn.finish(.complete, at: start.addingTimeInterval(1))
        XCTAssertEqual(turn.text, accumulated, "finish flushes the authoritative text")
    }
}
