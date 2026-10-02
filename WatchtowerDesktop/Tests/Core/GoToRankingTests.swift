import XCTest
import GRDB
@testable import WatchtowerCore

final class GoToRankingTests: XCTestCase {
    private let now = Date()
    private var nextID: Int64 = 0

    private func iso(_ secondsAgo: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(-secondsAgo))
    }

    private func workbench(_ id: Int64, _ name: String, lastActivity: String = "") -> WorkbenchSwitcherSummary {
        let project = Workbench(row: ["id": id, "name": name, "folder_path": "/tmp/\(id)"])
        return WorkbenchSwitcherSummary(
            summary: WorkbenchSummary(project: project, openTargets: 0, inProgressTargets: 0,
                                      unreadAgentComments: 0, documentStamps: [:]),
            blockedTargets: 0,
            sessionCount: 0,
            lastSessionActivity: lastActivity
        )
    }

    private func session(_ project: Int64, _ title: String, target: Int64? = nil, secondsAgo: TimeInterval = 60)
        -> TerminalSession {
        nextID += 1
        return TerminalSession(
            id: nextID, projectID: project, kind: .claude, title: title, titleSource: .auto, targetID: target,
            folderPath: "/tmp/\(project)", claudeSessionID: "uuid", createdAt: iso(secondsAgo), lastActiveAt: iso(secondsAgo)
        )
    }

    private func titles(_ sections: [GoToSection]) -> [[String]] {
        sections.map { section in
            section.items.map { item in
                switch item {
                case let .session(session, workbench): "\(workbench.name) › \(session.title)"
                case let .workbench(row): "[\(row.project.name)]"
                }
            }
        }
    }

    // MARK: - Field scores

    func testFieldScoreScale() {
        let score = { (field: String, query: String) in GoToRanking.fieldScore(field, query: query) }
        XCTAssertEqual(score("Release", "release"), 100, "exact, case-insensitive")
        XCTAssertEqual(score("Résumé", "resume"), 100, "exact, diacritic-insensitive")
        XCTAssertEqual(score("Release notes", "rel"), 80)
        XCTAssertEqual(score("Fix release-notes", "notes"), 60, "a word after a dash")
        XCTAssertEqual(score("Fix the board", "board"), 60)
        XCTAssertEqual(score("Prerelease", "release"), 40)
        XCTAssertEqual(score("Board refactor", "brf"), 20, "every character in order")
        XCTAssertEqual(score("Board refactor", "zz"), 0)
        XCTAssertEqual(score("Board", ""), 0)
    }

    func testTitlesRankExactPrefixWordStartSubstringSubsequence() {
        let wb = workbench(1, "acme")
        let sessions = [
            session(1, "xdxexpxlxoxy"),
            session(1, "redeploy"),
            session(1, "fix deploy"),
            session(1, "deploy prod"),
            session(1, "Deploy")
        ]
        let result = GoToRanking.results(
            query: "deploy",
            current: .init(workbenchID: 1, orderedSessions: sessions),
            sessions: sessions,
            workbenches: [wb]
        )
        XCTAssertEqual(titles(result), [[
            "acme › Deploy", "acme › deploy prod", "acme › fix deploy", "acme › redeploy", "acme › xdxexpxlxoxy"
        ]])
    }

    func testTargetIDHitsTheTargetsSessionFirst() {
        let sessions = [session(1, "Release 2330 notes"), session(1, "Board work", target: 233)]
        let current = GoToRanking.Current(workbenchID: 1, orderedSessions: sessions)
        for query in ["#233", "233"] {
            let result = GoToRanking.results(query: query, current: current, sessions: sessions,
                                             workbenches: [workbench(1, "acme")])
            XCTAssertEqual(titles(result).first?.first, "acme › Board work", query)
        }
    }

    func testCurrentWorkbenchBonusAndSectionOrder() {
        let mine = session(1, "deploy", secondsAgo: 9000)
        let theirs = session(2, "deploy", secondsAgo: 10)
        XCTAssertEqual(GoToRanking.score(.session(mine, workbench: workbench(1, "acme").project), query: "deploy", currentID: 1), 110)
        XCTAssertEqual(GoToRanking.score(.session(theirs, workbench: workbench(2, "beta").project), query: "deploy", currentID: 1), 100)
        let result = GoToRanking.results(
            query: "deploy",
            current: .init(workbenchID: 1, orderedSessions: [mine]),
            sessions: [theirs, mine],
            workbenches: [workbench(1, "acme"), workbench(2, "beta")]
        )
        XCTAssertEqual(result.map(\.kind), [.currentSessions, .otherWorkbenches])
        XCTAssertEqual(titles(result), [["acme › deploy"], ["beta › deploy"]],
                       "the current one leads although the other is more recent")
    }

    func testEqualScoresTieByRecencyThenTitle() {
        let older = session(2, "deploy b", secondsAgo: 500)
        let newer = session(2, "deploy c", secondsAgo: 5)
        let sameStampA = session(2, "deploy a", secondsAgo: 500)
        let result = GoToRanking.results(
            query: "deploy",
            current: nil,
            sessions: [older, newer, sameStampA],
            workbenches: [workbench(2, "beta")]
        )
        XCTAssertEqual(titles(result), [["beta › deploy c", "beta › deploy a", "beta › deploy b"]])
    }

    // MARK: - Layout

    func testEmptyQueryLayout() {
        let current = [session(1, "second"), session(1, "first")]
        let others = [
            session(2, "b old", secondsAgo: 900),
            session(2, "b newest", secondsAgo: 10),
            session(2, "b mid", secondsAgo: 100),
            session(3, "c only", secondsAgo: 50)
        ]
        let result = GoToRanking.results(
            query: "  ",
            current: .init(workbenchID: 1, orderedSessions: current),
            sessions: current + others,
            workbenches: [
                workbench(1, "acme", lastActivity: iso(1)),
                workbench(2, "beta", lastActivity: iso(10)),
                workbench(3, "gamma", lastActivity: iso(50)),
                workbench(4, "delta")
            ]
        )
        XCTAssertEqual(titles(result), [
            ["acme › second", "acme › first"],
            ["[beta]", "beta › b newest", "beta › b mid", "[gamma]", "gamma › c only", "[delta]"]
        ], "panel order first, then other workbenches by recency with at most two sessions each")
    }

    func testNonEmptyQueryIsCappedAtFifty() {
        let current = (0..<30).map { session(1, "task \($0)") }
        let others = (0..<40).map { session(2, "task \($0)") }
        let result = GoToRanking.results(
            query: "task",
            current: .init(workbenchID: 1, orderedSessions: current),
            sessions: current + others,
            workbenches: [workbench(1, "acme"), workbench(2, "beta")]
        )
        XCTAssertEqual(result.map(\.items.count), [30, 20])
    }

    func testNoCurrentWorkbenchHasNoFirstSection() {
        let sessions = [session(2, "deploy")]
        let workbenches = [workbench(2, "beta", lastActivity: iso(60))]
        for query in ["", "deploy"] {
            let result = GoToRanking.results(query: query, current: nil, sessions: sessions, workbenches: workbenches)
            XCTAssertEqual(result.map(\.kind), [.otherWorkbenches], query)
        }
    }

    func testWorkbenchRowsMatchByName() {
        let result = GoToRanking.results(
            query: "bet",
            current: nil,
            sessions: [session(2, "deploy", secondsAgo: 60)],
            workbenches: [workbench(2, "beta", lastActivity: iso(60)), workbench(3, "gamma")]
        )
        XCTAssertEqual(titles(result), [["[beta]", "beta › deploy"]],
                       "the row and its session (by workbench name) both match; same score and stamp → by title")
    }
}
