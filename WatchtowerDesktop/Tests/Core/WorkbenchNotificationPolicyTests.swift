import XCTest
@testable import WatchtowerCore

final class WorkbenchNotificationPolicyTests: XCTestCase {
    typealias Policy = WorkbenchNotificationPolicy

    private func snapshot(
        last: Int64 = 0,
        questions: [Policy.Question] = [],
        targets: [Int64: Policy.TargetState] = [:],
        asks: [Int64: Policy.OpenAsk] = [:],
        ownerTouched: Set<WorkbenchSubject> = []
    ) -> Policy.Snapshot {
        Policy.Snapshot(
            projectID: 1, projectName: "acme", lastAgentCommentID: last, questions: questions,
            targets: targets, ownerTouched: ownerTouched, openAsks: asks
        )
    }

    private func question(_ id: Int64, target: Int64 = 10) -> Policy.Question {
        Policy.Question(id: id, targetID: target, targetTitle: "Task \(target)", body: "Which queue should retry?")
    }

    // MARK: each kind

    func testAgentQuestionNotifiesWithABoardDeepLink() {
        let notices = Policy.decide(previous: snapshot(last: 4), current: snapshot(last: 5, questions: [question(5)]))
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices[0].kind, .agentAsks)
        XCTAssertEqual(notices[0].title, "Agent asks on Task 10")
        XCTAssertEqual(notices[0].body, "acme: Which queue should retry?")
        XCTAssertEqual(notices[0].route, WorkbenchRoute(projectID: 1, pane: .board, subjectID: 10))
    }

    func testQuestionAtOrBelowTheWatermarkIsIgnored() {
        let notices = Policy.decide(previous: snapshot(last: 5), current: snapshot(last: 5, questions: [question(5), question(3)]))
        XCTAssertTrue(notices.isEmpty)
    }

    func testTargetMovedToDoneNotifiesAndOtherMovesDoNot() {
        let previous = snapshot(targets: [
            1: .init(title: "Task 1", status: "in_progress"),
            2: .init(title: "Task 2", status: "done"),
            3: .init(title: "Task 3", status: "todo")
        ])
        let current = snapshot(targets: [
            1: .init(title: "Task 1", status: "done"),
            2: .init(title: "Task 2", status: "done"),
            3: .init(title: "Task 3", status: "in_progress"),
            4: .init(title: "Task 4", status: "done")
        ])
        let notices = Policy.decide(previous: previous, current: current)
        XCTAssertEqual(notices.map(\.title), ["Task 1 done"])
        XCTAssertEqual(notices.first?.route, WorkbenchRoute(projectID: 1, pane: .board, subjectID: 1))
    }

    // MARK: owner writes

    func testOwnerWritesNeverNotify() {
        let previous = snapshot(targets: [7: .init(title: "Task 7", status: "todo")])
        let current = snapshot(targets: [7: .init(title: "Task 7", status: "done")], ownerTouched: [.target(7)])
        XCTAssertTrue(Policy.decide(previous: previous, current: current).isEmpty)
    }

    // MARK: coalescing

    func testThreeOrMoreOfOneKindCoalesceIntoOneSummary() {
        let current = snapshot(last: 9, questions: [question(7, target: 1), question(8, target: 2), question(9, target: 3)])
        let notices = Policy.decide(previous: snapshot(last: 6), current: current)
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices[0].title, "3 agent questions")
        XCTAssertEqual(notices[0].body, "acme")
        XCTAssertEqual(notices[0].route, WorkbenchRoute(projectID: 1, pane: .board))
    }

    func testTwoOfAKindStayIndividualAndKindsCoalesceSeparately() {
        let previous = snapshot(targets: [1: .init(title: "A", status: "todo"), 2: .init(title: "B", status: "todo"),
                                          3: .init(title: "C", status: "todo")])
        let current = snapshot(
            last: 2,
            questions: [question(1), question(2)],
            targets: [1: .init(title: "A", status: "done"), 2: .init(title: "B", status: "done"),
                      3: .init(title: "C", status: "done")],
            asks: [1: ask("A1"), 2: ask("A2"), 3: ask("A3"), 4: ask("A4")]
        )
        let notices = Policy.decide(previous: previous, current: current)
        XCTAssertEqual(notices.map(\.kind), [.agentAsks, .agentAsks, .askOpened, .targetDone])
        XCTAssertEqual(notices[2].title, "Ждёт тебя 4")
        XCTAssertEqual(notices[3].title, "3 targets done")
    }

    func testPersistedSnapshotDropsTransientParts() {
        let current = snapshot(last: 3, questions: [question(3)], asks: [4: ask("Review")], ownerTouched: [.target(1)])
        XCTAssertTrue(current.persisted.questions.isEmpty)
        XCTAssertTrue(current.persisted.ownerTouched.isEmpty)
        XCTAssertEqual(current.persisted.lastAgentCommentID, 3)
        XCTAssertEqual(current.persisted.openAsks, [4: ask("Review")], "the open asks are what the next poll compares")
    }

    // MARK: proposals from the project terminal (#166)

    private func proposals(_ last: Int64, _ pending: [Int64]) -> Policy.Snapshot {
        Policy.Snapshot(
            projectID: 1, projectName: "acme", lastAgentCommentID: 0, questions: [], targets: [:],
            ownerTouched: [], lastActionID: last,
            pendingActions: pending.map { .init(id: $0, tool: "send_slack_message", summary: "To: #ops in Acme — build is green") }
        )
    }

    func testANewPendingProposalAnnouncesItsApproval() {
        let notices = Policy.decide(previous: proposals(4, []), current: proposals(6, [3, 5]))
        XCTAssertEqual(notices.map(\.kind), [.actionAwaitsApproval], "only the proposal past the watermark")
        XCTAssertEqual(notices.first?.title, "Send to Slack awaits your approval")
        XCTAssertEqual(notices.first?.body, "acme: To: #ops in Acme — build is green")
        XCTAssertEqual(notices.first?.identifier, "project-1-actionAwaitsApproval-5")
    }

    func testAnUnknownWatermarkBaselinesSilently() {
        let previous = proposals(Policy.Snapshot.unknownActionWatermark, [])
        XCTAssertTrue(Policy.decide(previous: previous, current: proposals(9, [7, 8, 9])).isEmpty)
    }

    func testSnapshotPersistedBeforeProposalsDecodesWithAnUnknownWatermark() throws {
        let old = snapshot(last: 3)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "lastActionID")
        json.removeValue(forKey: "pendingActions")
        let decoded = try JSONDecoder().decode(Policy.Snapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.lastActionID, Policy.Snapshot.unknownActionWatermark)
        XCTAssertEqual(decoded.lastAgentCommentID, 3)
        let persisted = proposals(6, [5]).persisted
        XCTAssertTrue(persisted.pendingActions.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(Policy.Snapshot.self, from: JSONEncoder().encode(persisted)), persisted)
    }

    func testThreeProposalsInOnePollCoalesceOntoTheBoard() {
        let notices = Policy.decide(previous: proposals(0, []), current: proposals(3, [1, 2, 3]))
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices.first?.title, "3 proposals await your approval")
        XCTAssertEqual(notices.first?.kind, .actionAwaitsApproval)
        XCTAssertEqual(notices.first?.route.pane, .board)
    }

    // MARK: owner asks (spec 2026-10-03 Part 8)

    private func ask(_ title: String, session: Int64? = 5) -> Policy.OpenAsk {
        Policy.OpenAsk(title: title, sessionID: session)
    }

    func testANewOpenAskAnnouncesItAndOpensItsSession() {
        let notices = Policy.decide(previous: snapshot(asks: [3: ask("Old")]),
                                    current: snapshot(asks: [3: ask("Old"), 4: ask("Review the plan")]))
        XCTAssertEqual(notices.map(\.kind), [.askOpened], "only the ask the previous poll did not see")
        XCTAssertEqual(notices.first?.title, "Агент просит: Review the plan")
        XCTAssertEqual(notices.first?.body, "acme")
        XCTAssertEqual(notices.first?.route, WorkbenchRoute(projectID: 1, pane: .terminal, subjectID: 5, askID: 4))
        XCTAssertEqual(notices.first?.identifier, "project-1-askOpened-4")
        XCTAssertTrue(Policy.decide(previous: snapshot(asks: [4: ask("Review the plan")]),
                                    current: snapshot(asks: [4: ask("Review the plan")])).isEmpty,
                      "still open: nothing new")
    }

    func testAnAskFiledOutsideTheAppOpensTheBoard() {
        let notices = Policy.decide(previous: snapshot(), current: snapshot(asks: [4: ask("Check it", session: nil)]))
        XCTAssertEqual(notices.first?.route, WorkbenchRoute(projectID: 1, pane: .board, askID: 4))
    }

    func testTwoAsksStayIndividualAndThreeCoalesce() {
        let two = Policy.decide(previous: snapshot(), current: snapshot(asks: [1: ask("A"), 2: ask("B")]))
        XCTAssertEqual(two.map(\.title), ["Агент просит: A", "Агент просит: B"])

        let three = Policy.decide(previous: snapshot(), current: snapshot(asks: [1: ask("A"), 2: ask("B"), 3: ask("C")]))
        XCTAssertEqual(three.count, 1)
        XCTAssertEqual(three.first?.kind, .askOpened)
        XCTAssertEqual(three.first?.title, "Ждёт тебя 3")
        XCTAssertEqual(three.first?.route, WorkbenchRoute(projectID: 1, pane: .board))
    }

    /// The owner's answer only closes an ask: nothing is announced back.
    func testTheOwnersAnswerIsNotAnnounced() {
        let previous = snapshot(asks: [4: ask("Review the plan"), 5: ask("Check the build")])
        XCTAssertTrue(Policy.decide(previous: previous, current: snapshot(asks: [5: ask("Check the build")])).isEmpty)
        XCTAssertTrue(Policy.decide(previous: previous, current: snapshot()).isEmpty)
    }

    /// A snapshot persisted before asks existed decodes with no open asks it
    /// knows of, so its first poll announces none of the asks already open;
    /// the poll after that announces as usual.
    func testASnapshotPersistedBeforeAsksAnnouncesNothingOnItsFirstPoll() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot(last: 3))) as? [String: Any])
        json.removeValue(forKey: "openAsks")
        json["documents"] = [1, ["title": "Spec", "updatedAt": "t1", "openOwnerComments": 0]]
        let old = try JSONDecoder().decode(Policy.Snapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(old.openAsks.isEmpty)
        XCTAssertFalse(old.asksKnown)
        XCTAssertEqual(old.lastAgentCommentID, 3, "the rest still reads; the retired documents key is ignored")

        let current = snapshot(asks: [1: ask("A"), 2: ask("B")])
        XCTAssertTrue(Policy.decide(previous: old, current: current).isEmpty)

        let saved = try JSONDecoder().decode(Policy.Snapshot.self, from: JSONEncoder().encode(current.persisted))
        XCTAssertTrue(saved.asksKnown)
        XCTAssertEqual(Policy.decide(previous: saved, current: snapshot(asks: [1: ask("A"), 2: ask("B"), 9: ask("New")]))
            .map(\.title), ["Агент просит: New"])
    }
}
