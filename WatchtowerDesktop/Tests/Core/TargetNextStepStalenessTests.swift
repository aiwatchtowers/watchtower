import XCTest
import GRDB
@testable import WatchtowerCore

/// Staleness of the cached next-step suggestion: `next_step_at` versus the
/// target's last activity, where activity is `max(targets.updated_at, latest
/// assistant conversation activity)`. Units differ deliberately — the target
/// stamps are ISO-8601 TEXT, the conversation stamp is a `Date` decoded from a
/// REAL unix column.
final class TargetNextStepStalenessTests: XCTestCase {

    private func makeTarget(updatedAt: String, nextStepAt: String) -> Target {
        Target(row: Row([
            "id": 1,
            "text": "Ship the feature",
            "updated_at": updatedAt,
            "next_step": #"{"title":"Collect the checklist"}"#,
            "next_step_at": nextStepAt
        ]))
    }

    private func date(_ iso: String) -> Date {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        guard let d = fmt.date(from: iso) else {
            XCTFail("bad fixture timestamp \(iso)")
            return Date()
        }
        return d
    }

    // MARK: - Never generated

    func testNoNextStepAtIsStale() {
        let target = makeTarget(updatedAt: "2026-08-18T10:00:00Z", nextStepAt: "")
        XCTAssertTrue(target.isNextStepStale())
        XCTAssertTrue(target.isNextStepStale(latestAssistantActivity: date("2026-08-18T09:00:00Z")))
        XCTAssertNil(target.nextStepDate)
    }

    /// Even with no readable activity at all, a suggestion that was never
    /// generated is still stale — that is the Go rule's `next_step_at = ''` arm.
    func testNoNextStepAtIsStaleEvenWithoutAnyActivity() {
        let target = makeTarget(updatedAt: "", nextStepAt: "")
        XCTAssertTrue(target.isNextStepStale())
    }

    // MARK: - Target activity

    func testStaleWhenOlderThanTargetUpdatedAt() {
        let target = makeTarget(updatedAt: "2026-08-18T12:00:00Z", nextStepAt: "2026-08-18T10:00:00Z")
        XCTAssertTrue(target.isNextStepStale())
    }

    func testFreshWhenNewerThanTargetUpdatedAt() {
        let target = makeTarget(updatedAt: "2026-08-18T10:00:00Z", nextStepAt: "2026-08-18T12:00:00Z")
        XCTAssertFalse(target.isNextStepStale())
    }

    // MARK: - Assistant activity

    func testStaleWhenOlderThanLatestConversationActivity() {
        // The target row itself has not moved since the step was generated —
        // only the chat has. That is the case the old rule missed entirely.
        let target = makeTarget(updatedAt: "2026-08-18T10:00:00Z", nextStepAt: "2026-08-18T10:05:00Z")
        XCTAssertFalse(target.isNextStepStale())
        XCTAssertTrue(target.isNextStepStale(latestAssistantActivity: date("2026-08-18T11:30:00Z")))
    }

    func testFreshWhenBothActivitiesAreOlder() {
        let target = makeTarget(updatedAt: "2026-08-18T10:00:00Z", nextStepAt: "2026-08-18T13:00:00Z")
        XCTAssertFalse(target.isNextStepStale(latestAssistantActivity: date("2026-08-18T12:00:00Z")))
    }

    func testLastActivityTakesTheNewerOfTheTwo() {
        let target = makeTarget(updatedAt: "2026-08-18T10:00:00Z", nextStepAt: "2026-08-18T09:00:00Z")
        let chat = date("2026-08-18T14:00:00Z")
        XCTAssertEqual(target.lastActivityDate(latestAssistantActivity: chat), chat)
        XCTAssertEqual(
            target.lastActivityDate(latestAssistantActivity: date("2026-08-18T08:00:00Z")),
            date("2026-08-18T10:00:00Z")
        )
        XCTAssertEqual(target.lastActivityDate(), date("2026-08-18T10:00:00Z"))
    }

    // MARK: - Unparseable timestamps

    /// An unreadable `updated_at` is "no activity", never "stale right now".
    func testUnparseableUpdatedAtIsNotActivity() {
        let target = makeTarget(updatedAt: "not-a-date", nextStepAt: "2026-08-18T10:00:00Z")
        XCTAssertNil(target.lastActivityDate())
        XCTAssertFalse(target.isNextStepStale())
        // …but a readable chat stamp still ages the suggestion.
        XCTAssertTrue(target.isNextStepStale(latestAssistantActivity: date("2026-08-18T11:00:00Z")))
    }

    /// An unreadable `next_step_at` cannot be shown as fresh once activity is
    /// known; with no known activity nothing is staler than it.
    func testUnparseableNextStepAt() {
        let target = makeTarget(updatedAt: "2026-08-18T10:00:00Z", nextStepAt: "garbage")
        XCTAssertNil(target.nextStepDate)
        XCTAssertTrue(target.isNextStepStale())

        let noActivity = makeTarget(updatedAt: "also-garbage", nextStepAt: "garbage")
        XCTAssertFalse(noActivity.isNextStepStale())
    }

    func testFractionalSecondsStampsParse() {
        let target = makeTarget(updatedAt: "2026-08-18T10:00:00.123Z", nextStepAt: "2026-08-18T09:00:00.500Z")
        XCTAssertNotNil(target.nextStepDate)
        XCTAssertTrue(target.isNextStepStale())
    }

    func testParseTimestampRejectsEmpty() {
        XCTAssertNil(Target.parseTimestamp(""))
        XCTAssertNotNil(Target.parseTimestamp("2026-08-18T10:00:00Z"))
    }
}
