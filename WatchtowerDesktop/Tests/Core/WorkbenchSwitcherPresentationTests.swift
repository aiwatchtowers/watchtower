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
                                      unreadAgentComments: 0, documentStamps: [:]),
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
            summary(id: 2, name: "watchtower", folder: "/Users/x/PhpstormProjects/watchtower"),
            summary(id: 3, name: "billing", folder: "/work/Résumé")
        ]
        let match = { (query: String) in WorkbenchSwitcherPresentation.matching(rows, query: query).map(\.id) }
        XCTAssertEqual(match("cafe"), [1])
        XCTAssertEqual(match("CAF"), [1])
        XCTAssertEqual(match("phpstorm"), [2], "the folder matches")
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
            Seg(text: "3 новых коммента", tone: .comments),
            Seg(text: "2 blocked", tone: .blocked),
            Seg(text: "5 сессий · 1 в работе", tone: .sessions)
        ])
        XCTAssertEqual(segments(all, comments: 1), [
            Seg(text: "1 новый коммент", tone: .comments),
            Seg(text: "2 blocked", tone: .blocked),
            Seg(text: "5 сессий", tone: .sessions)
        ], "no live session → no second part")
        let sessionsOnly = summary(id: 2, name: "b", sessions: 1, lastActivity: iso(60))
        XCTAssertEqual(segments(sessionsOnly, live: 1), [Seg(text: "1 сессия · 1 в работе", tone: .sessions)])
        let blockedOnly = summary(id: 3, name: "c", blocked: 1)
        XCTAssertEqual(segments(blockedOnly), [Seg(text: "1 blocked", tone: .blocked)])
        let commentsOnly = summary(id: 4, name: "d")
        XCTAssertEqual(segments(commentsOnly, comments: 5), [Seg(text: "5 новых комментов", tone: .comments)])
    }

    /// Unreachable from the DB (a live session has a row) but the counts
    /// come from two sources: a live count alone still says it is running.
    func testSegmentsLiveWithoutCountedSessions() {
        let row = summary(id: 1, name: "a")
        XCTAssertEqual(segments(row, live: 2), [.init(text: "2 в работе", tone: .sessions)])
    }

    func testSegmentsFallBackToTheAgeThenToNothing() {
        let quiet = summary(id: 1, name: "a", lastActivity: iso(3 * 86_400 + 100))
        XCTAssertEqual(segments(quiet), [.init(text: "3 д", tone: .age)])
        XCTAssertEqual(segments(summary(id: 2, name: "b")), [])
        XCTAssertEqual(segments(summary(id: 3, name: "c", lastActivity: "garbage")), [],
                       "an unreadable stamp shows nothing rather than the raw text")
    }

    // MARK: - Plurals and ages

    func testRussianPluralForms() {
        let form = { (n: Int) in RussianPlural.form(n, one: "сессия", few: "сессии", many: "сессий") }
        XCTAssertEqual([1, 2, 5, 11, 21].map(form), ["сессия", "сессии", "сессий", "сессий", "сессия"])
        XCTAssertEqual([0, 4, 12, 14, 22, 25, 101, 111, 112].map(form),
                       ["сессий", "сессии", "сессий", "сессий", "сессии", "сессий", "сессия", "сессий", "сессий"])
    }

    func testShortAge() {
        let age = { (seconds: TimeInterval) in TimeFormatting.shortAge(from: self.iso(seconds), now: self.now) }
        XCTAssertEqual(age(10), "только что")
        XCTAssertEqual(age(5 * 60 + 5), "5 мин")
        XCTAssertEqual(age(3 * 3600 + 5), "3 ч")
        XCTAssertEqual(age(86_400 + 5), "1 д")
        XCTAssertEqual(age(-120), "только что", "a clock skew into the future is not a negative age")
        XCTAssertNil(TimeFormatting.shortAge(from: "", now: now))
    }
}
