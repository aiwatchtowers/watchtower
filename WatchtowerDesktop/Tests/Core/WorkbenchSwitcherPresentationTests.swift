import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class WorkbenchSwitcherPresentationTests: XCTestCase {
    private let now = Date()

    private func iso(_ secondsAgo: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(-secondsAgo))
    }

    private func summary(
        id: Int64,
        name: String,
        folder: String = "/tmp/x",
        blocked: Int = 0,
        sessions: Int = 0,
        lastActivity: String = ""
    ) -> WorkbenchSwitcherSummary {
        let project = Workbench(row: ["id": id, "name": name, "folder_path": folder])
        return WorkbenchSwitcherSummary(
            summary: WorkbenchSummary(project: project, openTargets: 0, inProgressTargets: 0,
                                      unreadAgentComments: 0),
            blockedTargets: blocked,
            sessionCount: sessions,
            lastSessionActivity: lastActivity
        )
    }

    // MARK: - Order

    func testOrderedByLastActivityThenNoSessionWorkbenchesByName() {
        let rows = [
            summary(id: 1, name: "zeta"),
            summary(id: 2, name: "old", sessions: 1, lastActivity: "2026-09-01T10:00:00Z"),
            summary(id: 3, name: "Alpha"),
            summary(id: 4, name: "new", sessions: 2, lastActivity: "2026-09-30T10:00:00Z"),
            summary(id: 5, name: "beta")
        ]
        XCTAssertEqual(WorkbenchSwitcherPresentation.ordered(rows).map(\.id), [4, 2, 3, 5, 1])
    }

    // MARK: - Filter

    func testMatchingFiltersByNameAndFolderIgnoringCaseAndDiacritics() {
        let rows = [
            summary(id: 1, name: "Café", folder: "/work/one"),
            summary(id: 2, name: "acme-app", folder: "/work/projects/acme-app"),
            summary(id: 3, name: "billing", folder: "/work/Résumé")
        ]
        let match = { (query: String) in WorkbenchSwitcherPresentation.matching(rows, query: query).map(\.id) }
        XCTAssertEqual(match("cafe"), [1])
        XCTAssertEqual(match("CAF"), [1])
        XCTAssertEqual(match("projects"), [2], "the folder matches")
        XCTAssertEqual(match("resume"), [3], "the folder ignores diacritics too")
        XCTAssertEqual(match("  "), [1, 2, 3], "a blank query keeps every row in its order")
        XCTAssertEqual(match("nothing"), [])
    }

    // MARK: - Segments

    private func segments(
        _ row: WorkbenchSwitcherSummary,
        comments: Int = 0,
        live: Int = 0
    ) -> [WorkbenchSwitcherPresentation.Segment] {
        WorkbenchSwitcherPresentation.stateSegments(summary: row, newComments: comments, liveCount: live, now: now)
    }

    func testSegmentsEachCombination() {
        typealias Seg = WorkbenchSwitcherPresentation.Segment
        let all = summary(id: 1, name: "a", blocked: 2, sessions: 5, lastActivity: iso(60))
        XCTAssertEqual(segments(all, comments: 3, live: 1), [
            Seg(text: "3 new comments", tone: .comments),
            Seg(text: "2 blocked", tone: .blocked),
            Seg(text: "5 sessions · 1 running", tone: .sessions)
        ])
        XCTAssertEqual(segments(all, comments: 1), [
            Seg(text: "1 new comment", tone: .comments),
            Seg(text: "2 blocked", tone: .blocked),
            Seg(text: "1m", tone: .age)
        ], "nothing running → the age instead of the sessions")
        let sessionsOnly = summary(id: 2, name: "b", sessions: 1, lastActivity: iso(60))
        XCTAssertEqual(segments(sessionsOnly, live: 1), [Seg(text: "1 session · 1 running", tone: .sessions)])
        let blockedOnly = summary(id: 3, name: "c", blocked: 1)
        XCTAssertEqual(segments(blockedOnly), [Seg(text: "1 blocked", tone: .blocked)])
        let commentsOnly = summary(id: 4, name: "d")
        XCTAssertEqual(segments(commentsOnly, comments: 5), [Seg(text: "5 new comments", tone: .comments)])
    }

    /// Unreachable from the DB (a live session has a row) but the counts
    /// come from two sources: a live count alone still says it is running.
    func testSegmentsLiveWithoutCountedSessions() {
        let row = summary(id: 1, name: "a")
        XCTAssertEqual(segments(row, live: 2), [.init(text: "2 running", tone: .sessions)])
    }

    func testSegmentsFallBackToTheAgeThenToNothing() {
        let quiet = summary(id: 1, name: "a", sessions: 2, lastActivity: iso(3 * 86_400 + 100))
        XCTAssertEqual(segments(quiet), [.init(text: "3d", tone: .age)], "sessions on file, none running")
        XCTAssertEqual(segments(summary(id: 2, name: "b")), [])
        XCTAssertEqual(segments(summary(id: 3, name: "c", lastActivity: "garbage")), [],
                       "an unreadable stamp shows nothing rather than the raw text")
    }

    // MARK: - Ages

    func testShortAge() {
        let age = { (seconds: TimeInterval) in TimeFormatting.shortAge(from: self.iso(seconds), now: self.now) }
        XCTAssertEqual(age(10), "just now")
        XCTAssertEqual(age(5 * 60 + 5), "5m")
        XCTAssertEqual(age(3 * 3600 + 5), "3h")
        XCTAssertEqual(age(86_400 + 5), "1d")
        XCTAssertEqual(age(-120), "just now", "a clock skew into the future is not a negative age")
        XCTAssertNil(TimeFormatting.shortAge(from: "", now: now))
    }
}
