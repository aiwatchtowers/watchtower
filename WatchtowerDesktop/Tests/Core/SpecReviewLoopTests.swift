import XCTest
import GRDB
@testable import WatchtowerCore

final class SpecReviewLoopTests: XCTestCase {
    private let items = """
    [{"key":"ag:1","kind":"agreement","text":"Mute lasts a day","note":"differs","where":{"heading":"Behaviour","quote":"a day"},"round":1,
      "reply":{"key":"ag:1","reply":"fixed","note":"changed"}},
     {"key":"bs:2","kind":"blind_spot","text":"No undo","note":"","round":2}]
    """
    private let ledger = """
    [{"key":"ag:1","kind":"agreement","text":"Mute lasts a day","note":"","round":1,"verdict":"resolved","verdict_note":"ok","settled":1},
     {"key":"bs:2","kind":"blind_spot","text":"No undo","note":"","round":2,"verdict":"disputed","verdict_note":"still","settled":0},
     {"key":"ck:3","kind":"check","text":"q","note":"","round":2,"verdict":"unsettled","verdict_note":"","settled":0}]
    """

    private func row(loop: String = "author", end: String = "", items: String = "", ledger: String = "") throws -> SpecReviewRow {
        try SpecReviewRow(row: Row([
            "ask_id": 1, "status": "done", "reason": "", "provider": "", "model": "", "dropped": 0, "attempt": 1,
            "result": "", "loop": loop, "round": 2, "open_items": items, "ledger": ledger, "loop_end": end
        ]))
    }

    func testDecodesGoShapedLoop() throws {
        let r = try row(items: items, ledger: ledger)
        XCTAssertEqual(r.loop, .author)
        XCTAssertEqual(r.round, 2)
        XCTAssertEqual(r.openItems.count, 2)
        XCTAssertEqual(r.openItems[0].anchor, .init(heading: "Behaviour", quote: "a day"))
        XCTAssertEqual(r.openItems[0].reply?.reply, "fixed")
        XCTAssertNil(r.openItems[1].reply)
        XCTAssertEqual(r.ledger[1].verdictNote, "still")
        XCTAssertEqual(r.ledger[0].item.key, "ag:1")
        XCTAssertFalse(r.loopUnreadable)
    }

    func testDisputedAndFixedSplit() throws {
        let r = try row(ledger: ledger)
        XCTAssertEqual(SpecReviewLoop.disputed(r).map(\.item.key), ["bs:2", "ck:3"])
        XCTAssertEqual(SpecReviewLoop.fixed(r).map(\.item.key), ["ag:1"])
    }

    func testResolvedAfterDisagreeIsNotAFix() throws {
        let ledger = """
        [{"key":"ag:1","text":"a","reply":{"key":"ag:1","reply":"fixed","note":""},"verdict":"resolved","settled":1},
         {"key":"bs:2","text":"b","reply":{"key":"bs:2","reply":"disagree","note":"out of scope"},"verdict":"resolved","settled":2},
         {"key":"ck:3","text":"c","verdict":"resolved","settled":1}]
        """
        let r = try row(ledger: ledger)
        XCTAssertEqual(SpecReviewLoop.fixed(r).map(\.item.key), ["ag:1", "ck:3"],
                       "the reviewer accepted the author's reason: nothing was fixed")
        XCTAssertTrue(SpecReviewLoop.disputed(r).isEmpty, "and it is settled, not disputed")
    }

    func testEndedEarlyAndEndLine() throws {
        XCTAssertFalse(SpecReviewLoop.endedEarly(try row(end: "")))
        XCTAssertFalse(SpecReviewLoop.endedEarly(try row(end: "settled")))
        XCTAssertNil(SpecReviewLoop.endLine(try row(end: "settled")))
        XCTAssertNil(SpecReviewLoop.endLine(try row(end: "")))
        for end in ["cap", "reviewer_failed", "session_gone", "timeout"] {
            let r = try row(end: end)
            XCTAssertTrue(SpecReviewLoop.endedEarly(r), end)
            XCTAssertNotNil(SpecReviewLoop.endLine(r), end)
        }
        XCTAssertEqual(SpecReviewLoop.endLine(try row(end: "cap")), "The reviewer and the author did not settle everything in 3 rounds.")
    }

    func testMalformedLedgerIsEmptyAndFlagged() throws {
        let r = try row(items: items, ledger: "{not json")
        XCTAssertEqual(r.ledger, [])
        XCTAssertEqual(r.openItems.count, 2)
        XCTAssertTrue(r.loopUnreadable)
    }

    func testNoLoopRow() throws {
        let r = try row(loop: "")
        XCTAssertEqual(r.loop, .none)
        XCTAssertTrue(r.openItems.isEmpty)
        XCTAssertFalse(r.loopUnreadable)
    }
}
