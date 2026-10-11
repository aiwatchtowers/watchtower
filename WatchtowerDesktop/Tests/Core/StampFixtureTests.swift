import XCTest
import WatchtowerCore

/// The Desktop's `agent_state_at` parser and writer over the shared stamp
/// fixture (`internal/db/testdata/stamps`, spec 2026-10-10-owner-asks-v2
/// Part 2.5, E35): what Go writes parses to its instant, what Go refuses is
/// refused, and a stamp read and written back is byte-identical.
final class StampFixtureTests: XCTestCase {
    func testTheFixturePinsGosLayoutAndTheColumns() throws {
        let fixture = try StampFixture.load()
        XCTAssertEqual(fixture.layout, "2006-01-02T15:04:05.000Z")
        for column in ["terminal_sessions.agent_state_at", "terminal_sessions.agent_background_at",
                       "terminal_sessions.chat_question_at", "owner_presence.seen_at",
                       "owner_asks.chat_asked_at"] {
            XCTAssertTrue(fixture.columns.contains(column), column)
        }
        XCTAssertFalse(fixture.valid.isEmpty)
        XCTAssertFalse(fixture.invalid.isEmpty)
    }

    func testEveryValidStampParsesToItsInstant() throws {
        for valid in try StampFixture.load().valid {
            let parsed = try XCTUnwrap(SessionAgentStatus.parseStamp(valid.stamp), valid.stamp)
            XCTAssertEqual(Int64((parsed.timeIntervalSince1970 * 1000).rounded()), valid.unixMS, valid.stamp)
        }
    }

    func testEveryInvalidStampIsRefused() throws {
        for invalid in try StampFixture.load().invalid {
            XCTAssertNil(SessionAgentStatus.parseStamp(invalid), "\"\(invalid)\" must not read as a time")
        }
    }

    /// E35: the escalation passes `chat_question_at` back as `--at`; the raw
    /// string is what it sends, and a parse and a write of it give the
    /// same bytes as well.
    func testAStampReadAndWrittenBackIsByteIdentical() throws {
        for valid in try StampFixture.load().valid {
            let parsed = try XCTUnwrap(SessionAgentStatus.parseStamp(valid.stamp))
            XCTAssertEqual(SessionAgentStatus.formatStamp(parsed), valid.stamp)
            let instant = Date(timeIntervalSince1970: TimeInterval(valid.unixMS) / 1000)
            XCTAssertEqual(SessionAgentStatus.formatStamp(instant), valid.stamp)
        }
    }

    /// Go's formatter floors a pre-epoch instant: -1.5 s is half a second
    /// into the second before.
    func testAPreEpochInstantFloorsLikeGo() {
        XCTAssertEqual(SessionAgentStatus.formatStamp(Date(timeIntervalSince1970: -1.5)), "1969-12-31T23:59:58.500Z")
        XCTAssertEqual(SessionAgentStatus.formatStamp(Date(timeIntervalSince1970: -0.001)), "1969-12-31T23:59:59.999Z")
    }
}
