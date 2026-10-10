import XCTest
@testable import WatchtowerCore

final class SessionSwitcherPresentationTests: XCTestCase {
    private let now = Date()

    private func session(
        _ id: Int64,
        _ title: String = "Session",
        target: Int64? = nil,
        secondsAgo: TimeInterval = 60,
        workbench: Int64? = 1
    ) -> TerminalSession {
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-secondsAgo))
        return TerminalSession(
            id: id, projectID: workbench, kind: .claude, title: title, titleSource: .auto, targetID: target,
            folderPath: "/tmp/acme", claudeSessionID: "uuid", createdAt: stamp, lastActiveAt: stamp
        )
    }

    private func rows(
        _ sessions: [TerminalSession],
        live: Set<Int64> = [],
        statuses: [Int64: SessionSwitcherPresentation.State] = [:]
    ) -> [SessionSwitcherPresentation.Row] {
        let mapped = statuses.mapValues { state in
            SessionAgentStatus(sessionID: 0, workbenchID: 1, workbenchName: "acme", title: "", state: state, at: "t")
        }
        return SessionSwitcherPresentation.rows(sessions, liveIDs: live, statuses: mapped, now: now)
    }

    func testOnlyTheFirstNineGetShortcutsInTheGivenOrder() {
        let sessions = [10, 3, 7, 1, 2, 4, 5, 6, 8, 9].map { session(Int64($0)) }
        let result = rows(sessions)
        XCTAssertEqual(result.map(\.id), sessions.map(\.id), "the panel order is kept")
        XCTAssertEqual(result.map(\.shortcut), [1, 2, 3, 4, 5, 6, 7, 8, 9, nil])
    }

    func testLiveSessionHasNoAgeCaption() {
        let result = rows([session(1, secondsAgo: 3 * 3600)], live: [1])
        XCTAssertEqual(result[0].state, .live(.running))
        XCTAssertEqual(result[0].caption, "Running")
        XCTAssertTrue(result[0].showsStateLabel)
    }

    /// A standalone terminal keeps its plain caption and no state label.
    func testAStandaloneTerminalKeepsItsPlainCaption() {
        let result = rows([session(1, workbench: nil), session(2, secondsAgo: 5 * 60 + 3, workbench: nil)], live: [1])
        XCTAssertEqual(result.map(\.caption), [nil, "not started · 5m"])
        XCTAssertEqual(result.map(\.showsStateLabel), [false, false])
    }

    func testLiveCaptionsNameTheAgentState() {
        let result = rows(
            [session(1, secondsAgo: 3600), session(2), session(3), session(4)],
            live: [1, 2, 3, 4],
            statuses: [1: .live(.working), 2: .live(.stopped), 3: .live(.needsApproval)]
        )
        XCTAssertEqual(result.map(\.state), [.live(.working), .live(.stopped), .live(.needsApproval), .live(.running)])
        XCTAssertEqual(result.map(\.caption), ["Working", "Stopped", "Needs approval", "Running"],
                       "a live session never carries an age caption")
        XCTAssertTrue(result.allSatisfy(\.state.live))
    }

    func testABackgroundRowCarriesItsCaption() {
        let result = rows([session(1)], live: [1], statuses: [1: .live(.background, openAsks: 1, backgroundAgents: 2)])
        XCTAssertEqual(result[0].caption, "2 agents working · 1 ask open")
        XCTAssertTrue(result[0].showsStateLabel)
    }

    func testAStatusOfASessionNoLongerLiveIsIgnored() {
        let result = rows([session(1, secondsAgo: 5 * 60 + 3)], statuses: [1: .live(.stopped)])
        XCTAssertEqual(result[0].state, .notStarted)
        XCTAssertFalse(result[0].state.live)
        XCTAssertEqual(result[0].caption, "Not running · 5m")
    }

    func testStatesKeepShortcutsAndMatching() {
        let result = rows([session(1, "Board work"), session(2, "Other")], live: [1, 2], statuses: [2: .live(.needsApproval)])
        XCTAssertEqual(result.map(\.shortcut), [1, 2])
        let matched = SessionSwitcherPresentation.matching(result, query: "other")
        XCTAssertEqual(matched.map(\.id), [2])
        XCTAssertEqual(matched.first?.state, .live(.needsApproval))
        XCTAssertEqual(matched.first?.shortcut, 2)
    }

    func testAClosedSessionKeepsItsFinishedOrAskState() {
        let result = rows(
            [session(1, secondsAgo: 60), session(2, secondsAgo: 60)],
            statuses: [
                1: SessionSwitcherPresentation.State(kind: .finished, live: false),
                2: SessionSwitcherPresentation.State(kind: .waitingOnAsk, live: false, openAsks: 2, oldestAskID: 12)
            ]
        )
        XCTAssertEqual(result.map(\.state.kind), [.finished, .waitingOnAsk])
        XCTAssertEqual(result.map(\.caption), ["Finished", "Waiting for you · ask #12 · 2 asks"],
                       "a closed session's state wins over the age")
        let restarted = rows([session(1)], live: [1], statuses: [1: SessionSwitcherPresentation.State(kind: .finished, live: false)])
        XCTAssertEqual(restarted[0].state, .live(.running), "a status read while not live is ignored once live")
    }

    func testNotStartedCaptionsCarryTheAge() {
        let result = rows([
            session(1, secondsAgo: 5 * 60 + 3),
            session(2, secondsAgo: 3 * 3600 + 3),
            session(3, secondsAgo: 86_400 + 3)
        ])
        XCTAssertEqual(result.map(\.caption), ["Not running · 5m", "Not running · 3h", "Not running · 1d"])
        XCTAssertEqual(result[0].state, .notStarted)
    }

    func testBadgeIsTheTargetID() {
        let result = rows([session(1, target: 233), session(2)])
        XCTAssertEqual(result.map(\.badge), ["#233", nil])
    }

    func testMatchingByTargetIDWithOrWithoutHash() {
        let result = rows([session(1, "Board work", target: 233), session(2, "Other", target: 2330), session(3, "None")])
        XCTAssertEqual(SessionSwitcherPresentation.matching(result, query: "#233").map(\.id), [1, 2],
                       "# and digits are a prefix: #2330 starts with them too")
        XCTAssertEqual(SessionSwitcherPresentation.matching(result, query: "233").map(\.id), [1])
        XCTAssertEqual(SessionSwitcherPresentation.matching(result, query: "#23").map(\.id), [1, 2],
                       "# and digits match the target ids starting with them")
        XCTAssertEqual(SessionSwitcherPresentation.matching(result, query: "23").map(\.id), [],
                       "a bare number matches a target id exactly")
        XCTAssertEqual(SessionSwitcherPresentation.matching(result, query: "#").map(\.id), [],
                       "a lone # matches no target id")
        XCTAssertEqual(SessionSwitcherPresentation.matching(result, query: " ").map(\.id), [1, 2, 3])
    }

    func testMatchingTitleIgnoresCaseAndDiacriticsAndKeepsShortcuts() {
        let result = rows([session(1, "Résumé parser"), session(2, "Сборка релиза"), session(3, "Other")])
        let byTitle = SessionSwitcherPresentation.matching(result, query: "RESUME")
        XCTAssertEqual(byTitle.map(\.id), [1])
        let cyrillic = SessionSwitcherPresentation.matching(result, query: "сборка")
        XCTAssertEqual(cyrillic.map(\.id), [2])
        XCTAssertEqual(cyrillic.first?.shortcut, 2, "a filtered row keeps its ⌘N")
        XCTAssertEqual(SessionSwitcherPresentation.matching(result, query: "nope"), [])
    }
}
