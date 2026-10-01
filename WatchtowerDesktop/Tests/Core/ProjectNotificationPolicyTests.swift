import XCTest
@testable import WatchtowerCore

final class ProjectNotificationPolicyTests: XCTestCase {
    typealias Policy = ProjectNotificationPolicy

    private func snapshot(
        last: Int64 = 0,
        questions: [Policy.Question] = [],
        documents: [Int64: Policy.DocumentState] = [:],
        targets: [Int64: Policy.TargetState] = [:],
        ownerTouched: Set<ProjectSubject> = []
    ) -> Policy.Snapshot {
        Policy.Snapshot(
            projectID: 1, projectName: "acme", lastAgentCommentID: last, questions: questions,
            documents: documents, targets: targets, ownerTouched: ownerTouched
        )
    }

    private func question(_ id: Int64, target: Int64 = 10) -> Policy.Question {
        Policy.Question(id: id, targetID: target, targetTitle: "Task \(target)", body: "Which queue should retry?")
    }

    private func doc(_ title: String, _ stamp: String, open: Int = 0) -> Policy.DocumentState {
        Policy.DocumentState(title: title, updatedAt: stamp, openOwnerComments: open)
    }

    // MARK: each kind

    func testAgentQuestionNotifiesWithABoardDeepLink() {
        let notices = Policy.decide(previous: snapshot(last: 4), current: snapshot(last: 5, questions: [question(5)]))
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices[0].kind, .agentAsks)
        XCTAssertEqual(notices[0].title, "Agent asks on Task 10")
        XCTAssertEqual(notices[0].body, "acme: Which queue should retry?")
        XCTAssertEqual(notices[0].route, ProjectRoute(projectID: 1, pane: .board, subjectID: 10))
    }

    func testQuestionAtOrBelowTheWatermarkIsIgnored() {
        let notices = Policy.decide(previous: snapshot(last: 5), current: snapshot(last: 5, questions: [question(5), question(3)]))
        XCTAssertTrue(notices.isEmpty)
    }

    func testNewOrRevisedDocumentIsReadyForReviewAndAnUnchangedOneIsNot() {
        let previous = snapshot(documents: [1: doc("Spec", "t1"), 2: doc("Notes", "t1")])
        let current = snapshot(documents: [1: doc("Spec", "t2"), 2: doc("Notes", "t1"), 3: doc("Plan", "t2")])
        let notices = Policy.decide(previous: previous, current: current)
        XCTAssertEqual(notices.map(\.title), ["Spec ready for review", "Plan ready for review"])
        XCTAssertEqual(notices.map(\.route), [
            ProjectRoute(projectID: 1, pane: .documents, subjectID: 1),
            ProjectRoute(projectID: 1, pane: .documents, subjectID: 3)
        ])
        XCTAssertNotEqual(notices[0].identifier, Policy.decide(
            previous: current, current: snapshot(documents: [1: doc("Spec", "t3")])
        ).first?.identifier, "each revision is its own notification")
    }

    func testLastOpenOwnerCommentResolvedAnnouncesAllAnswered() {
        let previous = snapshot(documents: [1: doc("Plan", "t1", open: 2), 2: doc("Spec", "t1", open: 2)])
        let current = snapshot(documents: [1: doc("Plan", "t1", open: 0), 2: doc("Spec", "t1", open: 1)])
        let notices = Policy.decide(previous: previous, current: current)
        XCTAssertEqual(notices.map(\.kind), [.commentsAnswered])
        XCTAssertEqual(notices.first?.title, "All comments on Plan answered")
        XCTAssertEqual(notices.first?.route, ProjectRoute(projectID: 1, pane: .documents, subjectID: 1))
    }

    func testDocumentThatNeverHadOpenCommentsAnnouncesNothingAnswered() {
        let notices = Policy.decide(
            previous: snapshot(documents: [1: doc("Plan", "t1", open: 0)]),
            current: snapshot(documents: [1: doc("Plan", "t1", open: 0)])
        )
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
        XCTAssertEqual(notices.first?.route, ProjectRoute(projectID: 1, pane: .board, subjectID: 1))
    }

    // MARK: owner writes

    func testOwnerWritesNeverNotify() {
        let previous = snapshot(
            documents: [1: doc("Plan", "t1", open: 1)],
            targets: [7: .init(title: "Task 7", status: "todo")]
        )
        let current = snapshot(
            documents: [1: doc("Plan", "t1", open: 0)],
            targets: [7: .init(title: "Task 7", status: "done")],
            ownerTouched: [.document(1), .target(7)]
        )
        XCTAssertTrue(Policy.decide(previous: previous, current: current).isEmpty)
    }

    // MARK: coalescing

    func testThreeOrMoreOfOneKindCoalesceIntoOneSummary() {
        let current = snapshot(last: 9, questions: [question(7, target: 1), question(8, target: 2), question(9, target: 3)])
        let notices = Policy.decide(previous: snapshot(last: 6), current: current)
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices[0].title, "3 agent questions")
        XCTAssertEqual(notices[0].body, "acme")
        XCTAssertEqual(notices[0].route, ProjectRoute(projectID: 1, pane: .board))
    }

    func testTwoOfAKindStayIndividualAndKindsCoalesceSeparately() {
        let previous = snapshot(targets: [1: .init(title: "A", status: "todo"), 2: .init(title: "B", status: "todo"),
                                          3: .init(title: "C", status: "todo")])
        let current = snapshot(
            last: 2,
            questions: [question(1), question(2)],
            documents: [1: doc("D1", "t"), 2: doc("D2", "t"), 3: doc("D3", "t"), 4: doc("D4", "t")],
            targets: [1: .init(title: "A", status: "done"), 2: .init(title: "B", status: "done"),
                      3: .init(title: "C", status: "done")]
        )
        let notices = Policy.decide(previous: previous, current: current)
        XCTAssertEqual(notices.map(\.kind), [.agentAsks, .agentAsks, .documentReady, .targetDone])
        XCTAssertEqual(notices[2].title, "4 documents ready for review")
        XCTAssertEqual(notices[3].title, "3 targets done")
    }

    func testPersistedSnapshotDropsTransientParts() {
        let current = snapshot(last: 3, questions: [question(3)], ownerTouched: [.document(1)])
        XCTAssertTrue(current.persisted.questions.isEmpty)
        XCTAssertTrue(current.persisted.ownerTouched.isEmpty)
        XCTAssertEqual(current.persisted.lastAgentCommentID, 3)
    }

    // MARK: imported documents (migration 00083)

    func testImportedDocumentIsNeverReadyForReviewButItsCommentsStillAnswer() {
        let imported = Policy.DocumentState(title: "README", updatedAt: "t1", openOwnerComments: 1, imported: true)
        XCTAssertTrue(Policy.decide(previous: snapshot(), current: snapshot(documents: [1: imported])).isEmpty,
                      "an import is not a document written for review")

        let answered = Policy.DocumentState(title: "README", updatedAt: "t1", openOwnerComments: 0, imported: true)
        let notices = Policy.decide(previous: snapshot(documents: [1: imported]), current: snapshot(documents: [1: answered]))
        XCTAssertEqual(notices.map(\.kind), [.commentsAnswered])

        let reattached = doc("README", "t2", open: 1)
        XCTAssertEqual(Policy.decide(previous: snapshot(documents: [1: imported]), current: snapshot(documents: [1: reattached]))
            .map(\.kind), [.documentReady], "an agent re-attach is a revision")
    }

    func testSnapshotPersistedBeforeTheImportedKeyDecodes() throws {
        let json = #"{"title":"Spec","updatedAt":"t1","openOwnerComments":2}"#
        let state = try JSONDecoder().decode(Policy.DocumentState.self, from: Data(json.utf8))
        XCTAssertEqual(state, doc("Spec", "t1", open: 2))
        let roundTrip = try JSONDecoder().decode(
            Policy.DocumentState.self, from: JSONEncoder().encode(Policy.DocumentState(
                title: "R", updatedAt: "t", openOwnerComments: 0, imported: true)))
        XCTAssertTrue(roundTrip.imported)
    }

    // MARK: documents awaiting review (#105)

    private func reviewed(_ stamp: String, awaiting: Bool, target: Int64 = 10) -> Policy.DocumentState {
        Policy.DocumentState(title: "Spec", updatedAt: stamp, openOwnerComments: 0, awaitingReview: awaiting, targetID: target)
    }

    func testTargetEnteringReviewAnnouncesTheDocumentOnceAsAwaitingReview() {
        let attached = snapshot(documents: [1: reviewed("t1", awaiting: false)])
        let inReview = snapshot(documents: [1: reviewed("t1", awaiting: true)])
        let notices = Policy.decide(previous: attached, current: inReview)
        XCTAssertEqual(notices.map(\.title), ["Spec awaits your review"])
        XCTAssertEqual(notices.first?.route, ProjectRoute(projectID: 1, pane: .documents, subjectID: 1))
        XCTAssertEqual(notices.first?.identifier,
                       Policy.decide(previous: snapshot(), current: attached).first?.identifier,
                       "the same revision: it replaces the earlier ready-for-review notice, never stacks")
        XCTAssertTrue(Policy.decide(previous: inReview, current: inReview).isEmpty, "still in review: nothing new")
    }

    func testAttachAndReviewInOnePollIsOneNotice() {
        let notices = Policy.decide(previous: snapshot(), current: snapshot(documents: [1: reviewed("t1", awaiting: true)]))
        XCTAssertEqual(notices.map(\.title), ["Spec awaits your review"])
    }

    func testOwnerMovingTheTargetToReviewIsNotAnnouncedBack() {
        let previous = snapshot(documents: [1: reviewed("t1", awaiting: false)])
        let current = snapshot(documents: [1: reviewed("t1", awaiting: true)], ownerTouched: [.target(10)])
        XCTAssertTrue(Policy.decide(previous: previous, current: current).isEmpty)
    }

    func testImportedDocumentNeverAwaitsReview() {
        let imported = Policy.DocumentState(title: "README", updatedAt: "t1", openOwnerComments: 0, imported: true,
                                            awaitingReview: true, targetID: 10)
        XCTAssertTrue(Policy.decide(previous: snapshot(), current: snapshot(documents: [1: imported])).isEmpty)
    }

    func testSnapshotPersistedBeforeTheReviewKeysDecodes() throws {
        let json = #"{"title":"Spec","updatedAt":"t1","openOwnerComments":0,"imported":false}"#
        let state = try JSONDecoder().decode(Policy.DocumentState.self, from: Data(json.utf8))
        XCTAssertFalse(state.awaitingReview)
        XCTAssertNil(state.targetID)
        let roundTrip = try JSONDecoder().decode(Policy.DocumentState.self, from: JSONEncoder().encode(reviewed("t", awaiting: true)))
        XCTAssertEqual(roundTrip, reviewed("t", awaiting: true))
    }
}
