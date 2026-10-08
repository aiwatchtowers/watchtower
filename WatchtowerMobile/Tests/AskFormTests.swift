import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// Ask answers from the phone (spec §4.6, §5.2, §6.2, §9, §13 B4): the
/// question, review and check forms, validation that mirrors the Mac's,
/// the answer through the real outbox, its echoes, and a superseded ask
/// (Review Focus 3).
@MainActor
final class AskFormTests: XCTestCase {
    private let now = Date()

    private struct Fixture {
        let store: ReplicaStore
        let outbox: ActionOutbox
        let drafts: AskDraftStore
        let answerer: AskAnswerer
    }

    private func makeFixture() async throws -> Fixture {
        let store = try ReplicaStore.inMemory()
        let outbox = ActionOutbox(transport: InMemoryCloudTransport(), store: store, deviceID: DemoSeed.device.deviceID)
        let drafts = AskDraftStore()
        let answerer = AskAnswerer.sending(through: outbox, store: store, drafts: drafts)
        await answerer.observeApplied(on: outbox)
        return Fixture(store: store, outbox: outbox, drafts: drafts, answerer: answerer)
    }

    private func makeAsk(_ id: Int64, _ overrides: [String: Any]) throws -> OwnerAsk {
        try mirror(OwnerAsk.self, DemoSeed.JSON.ask(id, workbench: DemoSeed.acmeID, overrides))
    }

    private func replica(_ asks: [OwnerAsk], store: ReplicaStore? = nil, heartbeatAge: TimeInterval = 10) throws -> WorkbenchReplicaSnapshot {
        var snapshot = WorkbenchReplicaSnapshot()
        snapshot.asks = asks
        snapshot.pending = try store?.pendingActions() ?? []
        let at = now.addingTimeInterval(-heartbeatAge)
        snapshot.heartbeat = HeartbeatPayload(
            updatedAt: at, appVersion: "1.0", hubID: "hub", macName: "Acme Mac", flavor: .default,
            lastPublishAt: at, lastRelayAt: at, relayBacklog: 0, accounts: [],
            enabledAt: at, ownerUser: "_user", sharing: .none
        )
        return snapshot
    }

    private func formOf(_ model: AskViewModel, _ snapshot: WorkbenchReplicaSnapshot) throws -> AskFormModel {
        try XCTUnwrap(model.form(snapshot: snapshot, now: now))
    }

    /// Rewrites the only overlay row as the Mac's echo.
    private func echo(
        _ fixture: Fixture,
        _ status: ActionStatus,
        reason: ActionReason? = nil,
        result: [String: JSONValue]? = nil,
        message: String? = nil
    ) async throws {
        var echo = try XCTUnwrap(fixture.store.pendingActions().first).action
        echo.status = status
        echo.reason = reason
        echo.result = result
        echo.errorMessage = message
        try await fixture.outbox.applyEcho(echo)
    }

    private static let twoQuestions: [String: Any] = [
        "kind": "question", "title": "Two questions",
        "payload": ["questions": [
            ["id": "lanes", "question": "Lanes per group?", "options": [
                ["label": "Yes", "recommended": true], ["label": "No"]
            ]],
            ["id": "fold", "question": "Which folds?", "multi": true, "options": [
                ["label": "Done"], ["label": "Dismissed"], ["label": "Blocked"]
            ]]
        ]]
    ]

    private static let review: [String: Any] = [
        "kind": "review", "title": "Review the plan", "doc_path": "docs/plan.md",
        "doc_snapshot": "# Plan\n\nShip behind a flag for acme.\n", "payload": ["focus": [["text": "The rollout"]]]
    ]

    // MARK: - Questions

    func testMultiQuestionPagingKeepsAnswersAcrossPages() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(120, Self.twoQuestions)
        let snapshot = try replica([ask])
        let model = AskViewModel(askID: 120, drafts: fixture.drafts, answerer: fixture.answerer)

        var page = try XCTUnwrap(try formOf(model, snapshot).question)
        XCTAssertEqual(try formOf(model, snapshot).header, "ASK #120 · QUESTION · 1 OF 2")
        XCTAssertEqual(page.options.map(\.recommended), [true, false])
        model.pick("Yes", in: page)
        model.next(of: page.count)

        page = try XCTUnwrap(try formOf(model, snapshot).question)
        XCTAssertEqual(page.questionID, "fold")
        XCTAssertTrue(page.isLast)
        XCTAssertFalse(try formOf(model, snapshot).canSend, "the second question has no answer yet")
        model.pick("Done", in: page)
        model.pick("Blocked", in: page)
        model.previous()

        page = try XCTUnwrap(try formOf(model, snapshot).question)
        XCTAssertEqual(page.options.filter(\.isPicked).map(\.label), ["Yes"], "the first page kept its pick")
        model.next(of: page.count)
        XCTAssertEqual(try XCTUnwrap(try formOf(model, snapshot).question).options.filter(\.isPicked).map(\.label), ["Done", "Blocked"])
        XCTAssertTrue(try formOf(model, snapshot).canSend)

        // A fresh screen on the same ask (navigation away and back) keeps it.
        let reopened = AskViewModel(askID: 120, drafts: fixture.drafts, answerer: fixture.answerer)
        XCTAssertEqual(try XCTUnwrap(try formOf(reopened, snapshot).question).options.filter(\.isPicked).map(\.label), ["Yes"])
        XCTAssertTrue(try formOf(reopened, snapshot).canSend)
    }

    func testAPickOnASingleSelectQuestionReplacesTheOtherAndTogglesOff() async throws {
        let fixture = try await makeFixture()
        let snapshot = try replica([try makeAsk(120, Self.twoQuestions)])
        let model = AskViewModel(askID: 120, drafts: fixture.drafts, answerer: fixture.answerer)
        let page = try XCTUnwrap(try formOf(model, snapshot).question)
        model.pick("Yes", in: page)
        model.pick("No", in: page)
        XCTAssertEqual(model.draft.picks["lanes"]?.labels, ["No"])
        model.pick("No", in: page)
        XCTAssertEqual(model.draft.picks["lanes"]?.labels, [])
    }

    func testOtherWithOnlyWhitespaceIsNoAnswer() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(121, [
            "kind": "question", "payload": ["questions": [["id": "q", "question": "Which?", "options": [["label": "A"], ["label": "B"]]]]]
        ])
        let snapshot = try replica([ask])
        let model = AskViewModel(askID: 121, drafts: fixture.drafts, answerer: fixture.answerer)

        model.setOther("  \n\t ", for: "q")
        XCTAssertFalse(try formOf(model, snapshot).canSend)
        try await fixture.answerer.send(ask)
        XCTAssertTrue(try fixture.store.pendingActions().isEmpty, "a draft the Mac would refuse is never sent")

        model.setOther("  Neither, use C  ", for: "q")
        XCTAssertTrue(try formOf(model, snapshot).canSend)
        await model.send(ask)
        let row = try XCTUnwrap(try fixture.store.pendingActions().first)
        XCTAssertEqual(row.action.kind, .askAnswer)
        XCTAssertEqual(row.entityRecordName, "owner_ask-121")
        XCTAssertEqual(row.action.entityID, "121")
        let params = try AskAnswerParams(wireParams: row.action.params)
        XCTAssertEqual(params, AskAnswerParams(
            workbenchID: DemoSeed.acmeID,
            answer: OwnerAskAnswer(answers: [.init(id: "q", other: "Neither, use C")])
        ))
    }

    func testALabelNotAmongTheOptionsIsNoAnswer() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(121, [
            "kind": "question", "payload": ["questions": [["id": "q", "question": "Which?", "options": [["label": "A"], ["label": "B"]]]]]
        ])
        fixture.drafts.update(121) { $0.picks["q"] = AskQuestionPick(labels: ["Z"]) }
        XCTAssertFalse(fixture.drafts.draft(for: 121).isAnswerable(for: ask))
        fixture.drafts.update(121) { $0.picks["q"] = AskQuestionPick(labels: ["A", "B"]) }
        XCTAssertFalse(fixture.drafts.draft(for: 121).isAnswerable(for: ask), "single select takes one label")
    }

    // MARK: - Review

    func testAClippedSnapshotShowsHowMuchIsShown() async throws {
        let fixture = try await makeFixture()
        var json = Self.review
        json["doc_clipped"] = true
        json["doc_bytes"] = 2_097_152
        let snapshot = try replica([try makeAsk(130, json)])
        let model = AskViewModel(askID: 130, drafts: fixture.drafts, answerer: fixture.answerer)

        let review = try XCTUnwrap(try formOf(model, snapshot).review)
        // N in the phone's locale ("2.1 MB", "2,1 MB").
        let full = ByteCountFormatter.string(fromByteCount: 2_097_152, countStyle: .file)
        XCTAssertEqual(review.clippedNotice, "Showing the first 256 KB of \(full)")
        XCTAssertEqual(review.document?.text, "Plan\n\nShip behind a flag for acme.\n\n")

        let whole = try XCTUnwrap(try formOf(model, try replica([try makeAsk(130, Self.review)])).review)
        XCTAssertNil(whole.clippedNotice)
    }

    func testAReviewCommentAnchorsOnTheShownTextAndApproveSends() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(130, Self.review)
        let snapshot = try replica([ask])
        let model = AskViewModel(askID: 130, drafts: fixture.drafts, answerer: fixture.answerer)
        let document = try XCTUnwrap(try formOf(model, snapshot).review?.document)
        XCTAssertFalse(try formOf(model, snapshot).canSend, "a review needs a verdict")
        XCTAssertTrue(try formOf(model, snapshot).canSendVerdict, "which Approve and Request changes give")

        XCTAssertNil(model.addComment(on: NSRange(location: 3, length: 0), in: document, body: "x"), "an empty selection")
        let id = try XCTUnwrap(model.addComment(on: NSRange(location: 6, length: 4), in: document, body: ""))
        model.setCommentBody("Which flag?", for: id)
        model.addComment(on: NSRange(location: 11, length: 6), in: document, body: "   ")
        XCTAssertEqual(try formOf(model, snapshot).review?.commentsLine, "Select text to comment · 2 comments")

        await model.review(.approved, ask)
        let row = try XCTUnwrap(try fixture.store.pendingActions().first)
        let answer = try AskAnswerParams(wireParams: row.action.params).answer
        XCTAssertEqual(answer.verdict, .approved)
        XCTAssertEqual(answer.comments, [
            OwnerAskAnswer.Comment(quote: "Ship", prefix: "Plan\n\n", suffix: " behind a flag for acme.\n\n", heading: "Plan", body: "Which flag?")
        ], "the blank comment is dropped, the other anchored as Core anchors it")
    }

    // MARK: - Check

    func testABrokenStepNeedsANoteAndUnmarkedStepsGoAsSkipped() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(140, [
            "kind": "check", "payload": ["checklist": [["id": "1", "text": "Open the menu"], ["id": "2", "text": "Archive", "hint": "Header menu"]]]
        ])
        let snapshot = try replica([ask])
        let model = AskViewModel(askID: 140, drafts: fixture.drafts, answerer: fixture.answerer)
        XCTAssertEqual(try formOf(model, snapshot).checks.map(\.text), ["Open the menu", "Archive"])
        XCTAssertTrue(try formOf(model, snapshot).canSend, "unmarked steps go as skipped")

        model.setCheck(.broken, for: "1")
        XCTAssertTrue(try XCTUnwrap(try formOf(model, snapshot).checks.first).needsNote)
        XCTAssertFalse(try formOf(model, snapshot).canSend)
        model.setCheckNote("The menu is empty", for: "1")
        model.setCheck(.ok, for: "2")
        XCTAssertTrue(try formOf(model, snapshot).canSend)

        await model.send(ask)
        let answer = try AskAnswerParams(wireParams: try XCTUnwrap(try fixture.store.pendingActions().first).action.params).answer
        XCTAssertEqual(answer.checklist, [.init(id: "1", state: .broken, note: "The menu is empty"), .init(id: "2", state: .ok)])
        XCTAssertNil(answer.verdict)
    }

    // MARK: - Payload clipped, closed asks

    func testAClippedPayloadOffersOnlyOpenOnTheMac() async throws {
        let fixture = try await makeFixture()
        let snapshot = try replica([try makeAsk(150, ["kind": "question", "payload_clipped": true])])
        let model = AskViewModel(askID: 150, drafts: fixture.drafts, answerer: fixture.answerer)
        let form = try formOf(model, snapshot)

        XCTAssertEqual(form.openOnMac, "Open the ask on the Mac")
        XCTAssertNil(form.question)
        XCTAssertNil(form.review)
        XCTAssertTrue(form.checks.isEmpty)
        XCTAssertFalse(form.isEditable)
        XCTAssertFalse(form.canSend)
    }

    func testAClosedAskShowsItsStoredAnswerReadOnly() async throws {
        let fixture = try await makeFixture()
        let snapshot = try replica([try makeAsk(160, [
            "kind": "question", "status": "delivered",
            "payload": ["questions": [["id": "q", "question": "Keep the counter?", "options": [["label": "Yes"], ["label": "No"]]]]],
            "answer": ["verdict": "", "answers": [["id": "q", "labels": ["No"], "other": ""]], "checklist": [], "comments": [], "note": "Not needed"]
        ])])
        let model = AskViewModel(askID: 160, drafts: fixture.drafts, answerer: fixture.answerer)
        let form = try formOf(model, snapshot)

        XCTAssertEqual(form.closedStatus, "Answered and delivered")
        XCTAssertEqual(form.closedLines, ["Keep the counter?: No", "Note: Not needed"])
        XCTAssertNil(form.question)
        XCTAssertFalse(form.isEditable)
        XCTAssertNil(form.openOnMac, "a closed ask is shown, not sent to the Mac")
    }

    // MARK: - On its way and back

    func testAPendingAnswerSaysWaitingForYourMacWhileTheHeartbeatIsStale() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(140, ["kind": "check", "payload": ["checklist": [["id": "1", "text": "Open"]]]])
        let model = AskViewModel(askID: 140, drafts: fixture.drafts, answerer: fixture.answerer)
        await model.send(ask)

        let online = try formOf(model, try replica([ask], store: fixture.store))
        XCTAssertEqual(online.status, .sending("Sending…"))
        XCTAssertFalse(online.isEditable)
        XCTAssertFalse(online.canSend)
        let stale = try formOf(model, try replica([ask], store: fixture.store, heartbeatAge: 3_600))
        XCTAssertEqual(stale.status, .sending("Waiting for your Mac"))
    }

    func testAnAppliedEchoShowsTheDeliveryAndClearsTheDraft() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(140, ["kind": "check", "payload": ["checklist": [["id": "1", "text": "Open"]]]])
        let model = AskViewModel(askID: 140, drafts: fixture.drafts, answerer: fixture.answerer)
        model.setNote("All good")
        await model.send(ask)

        try await echo(fixture, .applied, result: ["delivery": .string("held")])
        try await poll { fixture.answerer.applied[140] != nil }

        let form = try formOf(model, try replica([ask], store: fixture.store))
        XCTAssertEqual(form.status, .applied("Held until the session is free"))
        XCTAssertFalse(form.isEditable, "an applied answer is not sent again")
        XCTAssertNil(fixture.drafts.byAsk[140], "a successful answer clears the draft")
        XCTAssertEqual(AskDelivery.noSession.text, "No session is running — the answer is saved on the Mac")
        XCTAssertEqual(AppliedAnswer(delivery: nil).text, "Answer saved on the Mac")
    }

    func testAnInvalidAnswerEchoShowsTheMacsMessageAndKeepsTheDraft() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(140, ["kind": "check", "payload": ["checklist": [["id": "1", "text": "Open"]]]])
        let model = AskViewModel(askID: 140, drafts: fixture.drafts, answerer: fixture.answerer)
        model.setNote("All good")
        await model.send(ask)
        try await echo(fixture, .failed, reason: .invalidAnswer, message: "checklist: item \"1\" has no state")

        let rowID = try XCTUnwrap(try fixture.store.pendingActions().first).id
        let form = try formOf(model, try replica([ask], store: fixture.store))
        XCTAssertEqual(form.status, .failed("checklist: item \"1\" has no state", rowID: rowID))
        XCTAssertTrue(form.isEditable)
        XCTAssertEqual(model.draft.note, "All good")

        model.dismiss(rowID: rowID, snapshot: try replica([ask], store: fixture.store))
        XCTAssertTrue(try fixture.store.pendingActions().isEmpty)
    }

    /// Review Focus 3: the owner drafts on a review the agent replaced with
    /// a newer round meanwhile. The answer fails `ask_not_open`; the phone
    /// opens the newer round (`previous_ask_id` chain, followed to its open
    /// end) and keeps the old draft's text.
    func testASupersededAskFailsAskNotOpenAndMovesToTheNewRoundWithTheDraftText() async throws {
        let fixture = try await makeFixture()
        let old = try makeAsk(170, Self.review)
        let model = AskViewModel(askID: 170, drafts: fixture.drafts, answerer: fixture.answerer)
        let document = try XCTUnwrap(try formOf(model, try replica([old])).review?.document)
        model.addComment(on: NSRange(location: 6, length: 4), in: document, body: "Which flag?")
        model.setNote("Looks fine otherwise")
        await model.review(.changes, old)
        try await echo(fixture, .failed, reason: .askNotOpen, message: "The ask is no longer open")

        // The replica caught up: the old round withdrawn, a middle round
        // withdrawn too, the newest one open.
        let withdrawn = try makeAsk(170, Self.review.merging(["status": "withdrawn", "withdrawn_reason": "superseded"]) { _, new in new })
        let middle = try makeAsk(171, Self.review.merging([
            "status": "withdrawn", "withdrawn_reason": "superseded", "previous_ask_id": 170
        ]) { _, new in new })
        let newest = try makeAsk(172, Self.review.merging(["previous_ask_id": 171, "title": "Review the plan, round 3"]) { _, new in new })
        let caughtUp = try replica([withdrawn, middle, newest], store: fixture.store)

        let rowID = try XCTUnwrap(try fixture.store.pendingActions().first).id
        XCTAssertEqual(
            try formOf(model, caughtUp).status,
            .notOpen("This ask is no longer open: Replaced by a newer round", rowID: rowID, successor: 172)
        )

        XCTAssertTrue(model.followSuccessor(snapshot: caughtUp, now: now))
        XCTAssertEqual(model.askID, 172)
        XCTAssertEqual(model.carriedNotice, "This ask was replaced by a newer round. Your earlier draft is in the note.")
        XCTAssertEqual(model.draft.note, "“Ship” — Which flag?\n\nLooks fine otherwise")
        XCTAssertNil(model.draft.verdict, "the verdict is not carried over")
        XCTAssertTrue(model.draft.comments.isEmpty, "anchors do not carry over to another snapshot")
        XCTAssertNil(fixture.drafts.byAsk[170], "the old draft went")
        XCTAssertTrue(try fixture.store.pendingActions().isEmpty, "the failed answer row went")

        let moved = try formOf(model, try replica([withdrawn, middle, newest], store: fixture.store))
        XCTAssertEqual(moved.title, "Review the plan, round 3")
        XCTAssertTrue(moved.isEditable)
        XCTAssertEqual(moved.status, AskFormModel.Status.none)
    }

    func testAskNotOpenWithoutANewerRoundStaysAndShowsTheStatus() async throws {
        let fixture = try await makeFixture()
        let open = try makeAsk(180, ["kind": "check", "payload": ["checklist": [["id": "1", "text": "Open"]]]])
        let model = AskViewModel(askID: 180, drafts: fixture.drafts, answerer: fixture.answerer)
        await model.send(open)
        try await echo(fixture, .failed, reason: .askNotOpen)
        let answered = try makeAsk(180, ["kind": "check", "status": "answered", "payload": ["checklist": [["id": "1", "text": "Open"]]]])
        let caughtUp = try replica([answered], store: fixture.store)

        let rowID = try XCTUnwrap(try fixture.store.pendingActions().first).id
        XCTAssertEqual(try formOf(model, caughtUp).status, .notOpen("This ask is no longer open: Answered", rowID: rowID, successor: nil))
        XCTAssertFalse(model.followSuccessor(snapshot: caughtUp, now: now))
        XCTAssertEqual(model.askID, 180)
    }

    // MARK: - The demo

    func testTheDemoReachesOneAskOfEachKind() async throws {
        let fixture = try await makeFixture()
        let demo = try demoSnapshot(now: now)
        func form(_ id: Int64) throws -> AskFormModel {
            try XCTUnwrap(AskViewModel(askID: id, drafts: fixture.drafts, answerer: fixture.answerer).form(snapshot: demo, now: now))
        }
        XCTAssertEqual(try form(109).question?.options.map(\.label), ["Archive Closed Targets Now", "Archive Now"])
        let review = try XCTUnwrap(try form(110).review)
        XCTAssertNotNil(review.document)
        XCTAssertNotNil(review.clippedNotice)
        XCTAssertNil(AskFormModel.successor(of: 110, in: demo), "110 is the open round of the superseded #107")
        XCTAssertEqual(AskFormModel.successor(of: 107, in: demo)?.id, 110)
        XCTAssertEqual(try form(111).checks.count, 2)
        XCTAssertEqual(try form(105).closedLines, ["Keep the archived counter?: Drop it", "Note: Not needed on the board."])
    }

    // MARK: - One answer per ask in flight

    /// A second Send while the first is still being saved sends nothing.
    /// Bounded: the second call runs in its own Task and must finish within
    /// seconds; a missing guard fails here, it never hangs.
    func testASecondSendWhileTheFirstIsSavingSendsNothing() async throws {
        let gate = Gate()
        let drafts = AskDraftStore()
        let sent = Counter()
        let answerer = AskAnswerer(
            drafts: drafts,
            enqueue: { _, _ in
                sent.count += 1
                await gate.wait()
            },
            remove: { _ in }
        )
        let ask = try makeAsk(140, ["kind": "check", "payload": ["checklist": [["id": "1", "text": "Open"]]]])

        let first = Task { try await answerer.send(ask) }
        try await poll(timeout: 2) { sent.count == 1 }
        XCTAssertTrue(answerer.isSending(140))

        let secondDone = expectation(description: "the second send returns")
        let secondSent = Counter(-1)
        Task {
            secondSent.count = try await answerer.send(ask) ? 1 : 0
            secondDone.fulfill()
        }
        await fulfillment(of: [secondDone], timeout: 2)
        XCTAssertEqual(secondSent.count, 0, "the second send sent nothing")
        XCTAssertEqual(sent.count, 1)

        await gate.release()
        let firstSent = try await first.value
        XCTAssertTrue(firstSent)
        XCTAssertFalse(answerer.isSending(140))
    }
}

/// A gate the first enqueue waits on; releasing is sticky, so any later
/// waiter passes at once.
private actor Gate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@MainActor
private final class Counter {
    var count: Int

    init(_ count: Int = 0) {
        self.count = count
    }
}
