import XCTest
import WatchtowerCore

/// `workbench cleanup --json --stream` lines decode into events; anything
/// else on stdout is skipped, never fatal.
final class SessionCleanupEventTests: XCTestCase {
    func testEachEventDecodes() {
        let item = #"{"key":"wt:/tmp/acme/a","kind":"worktree","action":"remove","done":true}"#
        let decoded = SessionCleanupItem(key: "wt:/tmp/acme/a", kind: .worktree, action: .remove, done: true)
        XCTAssertEqual(
            SessionCleanupEvent.decode(line: #"{"event":"listed","items":["# + item + "]}"),
            .listed([decoded]))
        XCTAssertEqual(
            SessionCleanupEvent.decode(line: #"{"event":"checked","item":"# + item + "}"),
            .checked(decoded))
        XCTAssertEqual(
            SessionCleanupEvent.decode(line: #"{"event":"sized","key":"wt:/x","bytes":11811160064,"bytes_known":true}"#),
            .sized(key: "wt:/x", bytes: 11_811_160_064, known: true))
        XCTAssertEqual(
            SessionCleanupEvent.decode(line: #"{"event":"sized","key":"wt:/x","bytes":0}"#),
            .sized(key: "wt:/x", bytes: 0, known: false))
        XCTAssertEqual(SessionCleanupEvent.decode(line: #"{"event":"removing","key":"wt:/x"}"#), .removing("wt:/x"))
        XCTAssertEqual(
            SessionCleanupEvent.decode(line: #"{"event":"removed","item":"# + item + "}"),
            .removed(decoded))
        XCTAssertEqual(
            SessionCleanupEvent.decode(line: #"{"event":"done","plan":{"mode":"plan","summary":"s","items":[]}}"#),
            .done(SessionCleanupPlan(mode: "plan", summary: "s")))
    }

    func testUnknownEventAndBadLineAreSkipped() {
        XCTAssertNil(SessionCleanupEvent.decode(line: #"{"event":"later"}"#))
        XCTAssertNil(SessionCleanupEvent.decode(line: "not json"))
        XCTAssertNil(SessionCleanupEvent.decode(line: ""))
        XCTAssertNil(SessionCleanupEvent.decode(line: #"{"event":"checked"}"#))
    }
}
