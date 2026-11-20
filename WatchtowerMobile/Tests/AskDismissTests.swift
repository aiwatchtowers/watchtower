import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// Close without answering on the phone (#2114): the Mac's Dismiss, sent as an `ask_answer` with `dismissed` and the
/// draft's note, through the same outbox, overlay and refusal handling as an answer.
///
/// Writers of the ask's answer: the phone (this), the Mac (its own answer or Dismiss in the drawer) and the agent
/// (withdraw, or a newer round). The tower applies the first one that reaches an open ask; the replica then wins on
/// the phone: a later one is refused `ask_not_open` and the form shows what the replica holds.
@MainActor
final class AskDismissTests: XCTestCase {
    private let now = Date()

    private struct Fixture {
        let store: ReplicaStore
        let outbox: ActionOutbox
        let drafts: AskDraftStore
        let answerer: AskAnswerer
        let book: OverlayBook
    }

    private func makeFixture(store: ReplicaStore? = nil) async throws -> Fixture {
        let store = try store ?? TestPhone.replica()
        let drafts = AskDraftStore()
        let outbox = ActionOutbox(transport: try TestPhone.transport(), store: store, deviceID: DemoSeed.device.deviceID)
        let book = OverlayBook(hubID: "hub")
        let answerer = AskAnswerer.sending(through: outbox, store: store, drafts: drafts, overlays: book)
        await outbox.setAppliedObserver(HubSession.appliedObserver(
            askAnswerer: answerer, sessionStarts: SessionStarter.sending(through: outbox, store: store), overlays: book))
        return Fixture(store: store, outbox: outbox, drafts: drafts, answerer: answerer, book: book)
    }

    private func makeAsk(_ id: Int64, _ overrides: [String: Any]) throws -> OwnerAsk {
        try mirror(OwnerAsk.self, DemoSeed.JSON.ask(id, workbench: DemoSeed.acmeID, overrides))
    }

    private static let question: [String: Any] = [
        "kind": "question", "title": "Lanes per group?",
        "payload": ["questions": [["id": "lanes", "question": "Lanes per group?", "options": [["label": "Yes"], ["label": "No"]]]]]
    ]

    /// The replica as the screen sees it: the asks, the outbox rows and the overlays over them.
    private func replica(
        _ asks: [OwnerAsk], _ fixture: Fixture, heartbeatAge: TimeInterval = 10
    ) throws -> WorkbenchReplicaSnapshot {
        var snapshot = WorkbenchReplicaSnapshot()
        snapshot.asks = asks
        snapshot.pending = try fixture.store.pendingActions()
        let at = now.addingTimeInterval(-heartbeatAge)
        snapshot.heartbeat = HeartbeatPayload(
            updatedAt: at, appVersion: "1.0", hubID: "hub", macName: "Acme Mac", flavor: .default,
            lastPublishAt: at, lastRelayAt: at, relayBacklog: 0, accounts: [],
            enabledAt: at, ownerUser: "_user", sharing: .none
        )
        return snapshot.applying(fixture.book.reconcile(with: snapshot, now: now))
    }

    private func form(_ model: AskViewModel, _ snapshot: WorkbenchReplicaSnapshot) throws -> AskFormModel {
        try XCTUnwrap(model.form(snapshot: snapshot, now: now))
    }

    /// Rewrites the only outbox row as the Mac's echo.
    private func echo(_ fixture: Fixture, _ status: ActionStatus, reason: ActionReason? = nil, message: String? = nil) async throws {
        var echo = try XCTUnwrap(fixture.store.pendingActions().first).action
        echo.status = status
        echo.reason = reason
        echo.errorMessage = message
        try await fixture.outbox.applyEcho(echo)
    }

    private func sentAnswer(_ store: ReplicaStore) throws -> OwnerAskAnswer {
        let row = try XCTUnwrap(try store.pendingActions().first)
        XCTAssertEqual(row.action.kind, .askAnswer)
        return try AskAnswerParams(wireParams: row.action.params).answer
    }

    // MARK: - The words

    func testTheWordsAreTheMacsAndNeverDismiss() {
        XCTAssertEqual(AskText.dismiss, "Close without answering", "Dismiss on the phone removes a refused answer")
        XCTAssertEqual(AskText.dismissConfirmTitle, "Close this ask without answering?")
        XCTAssertEqual(AskText.dismissConfirmMessage(hasNote: false), "The agent goes on without an answer.")
        XCTAssertEqual(AskText.dismissConfirmMessage(hasNote: true), "The agent goes on without an answer. Your note goes with it.")
        XCTAssertEqual(AskText.cancel, "Cancel")
        XCTAssertEqual(AskText.dismissedLabel, "Closed without answering")
    }

    // MARK: - Sending

    /// The dismissal carries the note alone, whatever else the draft holds; it shows as on its way at once, and
    /// neither Send nor a second Close is offered meanwhile (a double tap during the save itself is `SendGuard`'s,
    /// shared with Send).
    func testCloseWithoutAnsweringSendsTheNoteAloneAndShowsItOnItsWay() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(140, Self.question)
        let model = AskViewModel(askID: 140, drafts: fixture.drafts, answerer: fixture.answerer)
        let page = try XCTUnwrap(try form(model, try replica([ask], fixture)).question)
        model.pick("Yes", in: page)
        model.setNote("  Not a priority now  ")

        let before = try form(model, try replica([ask], fixture))
        XCTAssertTrue(before.showsDismiss)
        XCTAssertTrue(before.canDismiss)
        XCTAssertEqual(before.dismissConfirmMessage, "The agent goes on without an answer. Your note goes with it.")

        await model.sendDismissal(ask)

        let sent = try sentAnswer(fixture.store)
        XCTAssertTrue(sent.dismissed)
        XCTAssertEqual(sent.note, "Not a priority now")
        XCTAssertNil(sent.verdict)
        XCTAssertTrue(sent.answers.isEmpty && sent.checklist.isEmpty && sent.comments.isEmpty, "Go refuses a dismissal with any")
        XCTAssertEqual(fixture.book.overlays.first?.expected, .askAnswer(label: "Closed without answering"))

        let onItsWay = try form(model, try replica([ask], fixture))
        XCTAssertEqual(onItsWay.status, .sending("Sending… · Closed without answering"))
        XCTAssertFalse(onItsWay.canDismiss)
        XCTAssertFalse(onItsWay.canSend)
        XCTAssertFalse(onItsWay.isEditable)
    }

    /// The tower asleep: the overlay waits as for any answer.
    func testWithTheTowerOfflineTheDismissalWaitsForIt() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(140, Self.question)
        let model = AskViewModel(askID: 140, drafts: fixture.drafts, answerer: fixture.answerer)
        await model.sendDismissal(ask)

        let stale = try form(model, try replica([ask], fixture, heartbeatAge: 3_600))
        XCTAssertEqual(stale.status, .sending("Waiting for your tower · Closed without answering"))
        XCTAssertFalse(stale.canDismiss)
    }

    /// Applied: the draft goes, and once the slice closes the ask the overlay goes and the form says Dismissed.
    func testAnAppliedDismissalClearsTheDraftAndTheClosedAskSaysDismissed() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(140, Self.question)
        let model = AskViewModel(askID: 140, drafts: fixture.drafts, answerer: fixture.answerer)
        model.setNote("Not now")
        await model.sendDismissal(ask)
        try await echo(fixture, .applied)
        try await poll { fixture.answerer.applied[140] != nil }
        XCTAssertNil(fixture.drafts.byAsk[140])

        let closed = try makeAsk(140, Self.question.merging([
            "status": "answered",
            "answer": ["verdict": "", "answers": [[String: Any]](), "checklist": [[String: Any]](), "comments": [[String: Any]](),
                       "dismissed": true, "note": "Not now"]
        ]) { _, new in new })
        let shown = try form(model, try replica([closed], fixture))
        XCTAssertTrue(fixture.book.overlays.isEmpty, "the replica shows the ask closed")
        XCTAssertEqual(shown.closedStatus, "Dismissed")
        XCTAssertEqual(shown.closedLines, [
            AskFormModel.ClosedLine(label: "Dismissed", value: "Closed without answering"),
            AskFormModel.ClosedLine(label: "Note", value: "Not now")
        ])
        XCTAssertFalse(shown.showsDismiss)
    }

    // MARK: - Failures

    /// A refusal shows today's refusal line; the draft stays whole, Close is offered again, and the refusal's own
    /// Dismiss still removes the row.
    func testARefusedDismissalShowsTheRefusalAndItsDismissStillWorks() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(140, Self.question)
        let model = AskViewModel(askID: 140, drafts: fixture.drafts, answerer: fixture.answerer)
        let page = try XCTUnwrap(try form(model, try replica([ask], fixture)).question)
        model.pick("No", in: page)
        await model.sendDismissal(ask)
        try await echo(fixture, .failed, reason: .invalidAnswer, message: "dismissed: a dismissal carries no answer")

        let rowID = try XCTUnwrap(try fixture.store.pendingActions().first).id
        let refused = try form(model, try replica([ask], fixture))
        XCTAssertEqual(refused.status, .failed("dismissed: a dismissal carries no answer", rowID: rowID))
        XCTAssertTrue(refused.canDismiss)
        XCTAssertTrue(refused.canSend, "the draft's answer can still go instead")
        XCTAssertEqual(model.draft.picks["lanes"]?.labels, ["No"])
        XCTAssertTrue(fixture.book.overlays.isEmpty, "a refusal drops the overlay at once")

        model.dismiss(rowID: rowID, snapshot: try replica([ask], fixture))
        XCTAssertTrue(try fixture.store.pendingActions().isEmpty)
        XCTAssertEqual(try form(model, try replica([ask], fixture)).status, .none)
    }

    /// The Mac answered (or the agent withdrew the ask) before the dismissal arrived: the tower refuses it
    /// `ask_not_open` and the replica's answer is what the form shows; nothing is offered to send again.
    func testAnAskClosedOnTheMacMeanwhileKeepsTheMacsAnswer() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(140, Self.question)
        let model = AskViewModel(askID: 140, drafts: fixture.drafts, answerer: fixture.answerer)
        await model.sendDismissal(ask)
        try await echo(fixture, .failed, reason: .askNotOpen)

        let answered = try makeAsk(140, Self.question.merging([
            "status": "answered",
            "answer": ["verdict": "", "answers": [["id": "lanes", "labels": ["Yes"], "other": ""]], "checklist": [[String: Any]](),
                       "comments": [[String: Any]](), "note": ""]
        ]) { _, new in new })
        let rowID = try XCTUnwrap(try fixture.store.pendingActions().first).id
        let shown = try form(model, try replica([answered], fixture))
        XCTAssertEqual(shown.status, .notOpen("This ask is no longer open: Answered", rowID: rowID, successor: nil))
        XCTAssertEqual(shown.closedLines, [AskFormModel.ClosedLine(label: "Lanes per group?", value: "Yes")])
        XCTAssertFalse(shown.showsDismiss)
        XCTAssertFalse(shown.canDismiss)

        let withdrawn = try makeAsk(140, Self.question.merging(["status": "withdrawn", "withdrawn_reason": "agent"]) { _, new in new })
        let gone = try form(model, try replica([withdrawn], fixture))
        XCTAssertEqual(gone.status, .notOpen("This ask is no longer open: Withdrawn by the agent", rowID: rowID, successor: nil))
        XCTAssertEqual(gone.closedStatus, "Withdrawn by the agent")
        XCTAssertFalse(gone.canDismiss)
    }

    /// The app quits after the tap: the outbox row is on disk, so the relaunched app shows the dismissal on its way
    /// (today's pending row, no overlay) and takes the tower's echo for it.
    func testARelaunchMidSendKeepsTheDismissalQueued() async throws {
        let path = try makeReplicaPath()
        let ask = try makeAsk(140, Self.question)
        do {
            let fixture = try await makeFixture(store: try TestPhone.replica(path: path))
            fixture.drafts.update(140) { $0.note = "Later" }
            let sent = try await fixture.answerer.sendDismissal(ask)
            XCTAssertTrue(sent)
        }

        let relaunched = try await makeFixture(store: try TestPhone.replica(path: path))
        let sent = try sentAnswer(relaunched.store)
        XCTAssertTrue(sent.dismissed)
        XCTAssertEqual(sent.note, "Later")
        let model = AskViewModel(askID: 140, drafts: relaunched.drafts, answerer: relaunched.answerer)
        let shown = try form(model, try replica([ask], relaunched))
        XCTAssertEqual(shown.status, .sending("Sending…"))
        XCTAssertFalse(shown.canDismiss)

        try await echo(relaunched, .applied)
        try await poll { relaunched.answerer.applied[140] != nil }
        XCTAssertTrue(try relaunched.store.pendingActions().isEmpty)
    }

    // MARK: - When it is offered

    func testCloseIsOfferedOnOpenAsksOfKnownKindsWithANoteInBound() async throws {
        let fixture = try await makeFixture()
        func shown(_ id: Int64, _ overrides: [String: Any]) throws -> AskFormModel {
            try form(AskViewModel(askID: id, drafts: fixture.drafts, answerer: fixture.answerer), try replica([try makeAsk(id, overrides)], fixture))
        }

        let folder = try makeAsk(151, ["kind": "folder", "payload": ["path": "/code/app"]])
        XCTAssertFalse(try shown(151, ["kind": "folder", "payload": ["path": "/code/app"]]).showsDismiss, "answered on the Mac")
        let folderSent = try await fixture.answerer.sendDismissal(folder)
        XCTAssertFalse(folderSent)
        XCTAssertTrue(try fixture.store.pendingActions().isEmpty)

        XCTAssertFalse(try shown(152, Self.question.merging(["status": "delivered"]) { _, new in new }).showsDismiss)

        fixture.drafts.update(153) { $0.note = String(repeating: "a", count: AskDraft.noteLimit + 1) }
        let long = try shown(153, Self.question)
        XCTAssertTrue(long.showsDismiss)
        XCTAssertFalse(long.canDismiss, "the Mac refuses a note over 4000 characters")
        let longSent = try await fixture.answerer.sendDismissal(try makeAsk(153, Self.question))
        XCTAssertFalse(longSent)
        XCTAssertEqual(long.dismissConfirmMessage, "The agent goes on without an answer. Your note goes with it.")
        XCTAssertEqual(try shown(154, Self.question).dismissConfirmMessage, "The agent goes on without an answer.")
    }

    /// A too-large ask has no note field: its dismissal goes with no note whatever the draft carries (a note over the
    /// bound left from earlier included), and the confirmation names none.
    func testATooLargeAskClosesWithoutTheDraftsNote() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(150, ["kind": "question", "payload_clipped": true])
        fixture.drafts.update(150) { $0.note = String(repeating: "a", count: AskDraft.noteLimit + 1) }
        let model = AskViewModel(askID: 150, drafts: fixture.drafts, answerer: fixture.answerer)

        let shown = try form(model, try replica([ask], fixture))
        XCTAssertNotNil(shown.openOnMac)
        XCTAssertTrue(shown.showsDismiss)
        XCTAssertTrue(shown.canDismiss, "a dismissal needs no payload, and this one no note")
        XCTAssertEqual(shown.dismissConfirmMessage, "The agent goes on without an answer.")

        await model.sendDismissal(ask)
        let sent = try sentAnswer(fixture.store)
        XCTAssertTrue(sent.dismissed)
        XCTAssertEqual(sent.note, "")
    }

    /// The save into the outbox throws: the overlay goes at once, the error shows, and Close is offered again.
    func testASaveThatThrowsTakesTheDismissalBack() async throws {
        struct Full: LocalizedError {
            var errorDescription: String? { "The phone's storage is full" }
        }
        let drafts = AskDraftStore()
        let book = OverlayBook(hubID: "hub")
        let answerer = AskAnswerer(drafts: drafts, enqueue: { _, _, _ in throw Full() }, remove: { _ in }, overlays: book)
        let ask = try makeAsk(140, Self.question)
        let model = AskViewModel(askID: 140, drafts: drafts, answerer: answerer)

        await model.sendDismissal(ask)

        XCTAssertEqual(model.sendError, "The phone's storage is full")
        XCTAssertTrue(book.overlays.isEmpty, "the save threw: nothing shows as sent")
        XCTAssertFalse(answerer.isSending(140))
        var snapshot = WorkbenchReplicaSnapshot()
        snapshot.asks = [ask]
        let again = try XCTUnwrap(model.form(snapshot: snapshot, now: now))
        XCTAssertEqual(again.status, .none)
        XCTAssertTrue(again.canDismiss)
    }

    /// While an answer to the ask waits in the outbox, neither a dismissal nor another answer is queued behind it;
    /// once the tower refused it, a new one goes and the refusal row with it.
    func testNothingIsQueuedBehindAnAnswerStillInTheOutbox() async throws {
        let fixture = try await makeFixture()
        let ask = try makeAsk(140, Self.question)
        let model = AskViewModel(askID: 140, drafts: fixture.drafts, answerer: fixture.answerer)
        let page = try XCTUnwrap(try form(model, try replica([ask], fixture)).question)
        model.pick("Yes", in: page)
        let answered = try await fixture.answerer.send(ask)
        XCTAssertTrue(answered)

        let dismissed = try await fixture.answerer.sendDismissal(ask)
        let again = try await fixture.answerer.send(ask)
        XCTAssertFalse(dismissed)
        XCTAssertFalse(again)
        XCTAssertEqual(try fixture.store.pendingActions().count, 1)

        try await echo(fixture, .failed, reason: .invalidAnswer, message: "Not now")
        let afterRefusal = try await fixture.answerer.sendDismissal(ask)
        XCTAssertTrue(afterRefusal)
        let rows = try fixture.store.pendingActions()
        XCTAssertEqual(rows.map(\.state), [.pending], "the refused row went once the dismissal was queued")
        XCTAssertTrue(try sentAnswer(fixture.store).dismissed)
    }

    /// A note over the bound written on the last question page turns Close off on every page, and the reason shows
    /// under the button there too; a too-large ask's dismissal has no note, so nothing there.
    func testANoteOverTheBoundSaysWhyCloseIsOffOnEveryPage() async throws {
        let fixture = try await makeFixture()
        let twoQuestions: [String: Any] = ["kind": "question", "payload": ["questions": [
            ["id": "a", "question": "A?", "options": [["label": "Yes"]]], ["id": "b", "question": "B?", "options": [["label": "No"]]]
        ]]]
        let ask = try makeAsk(170, twoQuestions)
        let model = AskViewModel(askID: 170, drafts: fixture.drafts, answerer: fixture.answerer)
        let snapshot = try replica([ask], fixture)
        XCTAssertNil(try form(model, snapshot).dismissHint)

        model.next(of: 2)
        model.setNote(String(repeating: "a", count: AskDraft.noteLimit + 1))
        let last = try form(model, snapshot)
        XCTAssertFalse(last.canDismiss)
        XCTAssertEqual(last.dismissHint, "The note is over 4000 characters — shorten it to send")
        model.previous()
        let first = try form(model, snapshot)
        XCTAssertEqual(first.question?.isLast, false, "back on the first page, where the note field is not")
        XCTAssertFalse(first.canDismiss)
        XCTAssertEqual(first.dismissHint, AskText.noteTooLong)

        model.setNote("Short")
        XCTAssertNil(try form(model, snapshot).dismissHint)
        XCTAssertTrue(try form(model, snapshot).canDismiss)

        fixture.drafts.update(171) { $0.note = String(repeating: "a", count: AskDraft.noteLimit + 1) }
        let tooLarge = try form(AskViewModel(askID: 171, drafts: fixture.drafts, answerer: fixture.answerer),
                                try replica([try makeAsk(171, ["kind": "question", "payload_clipped": true])], fixture))
        XCTAssertNil(tooLarge.dismissHint)
    }

    // MARK: - The bar

    func testTheBarFollowsTheAsk() async throws {
        let fixture = try await makeFixture()
        func bar(_ id: Int64, _ overrides: [String: Any], page: Bool = false) throws -> AskFormModel.Bar? {
            let model = AskViewModel(askID: id, drafts: fixture.drafts, answerer: fixture.answerer)
            let snapshot = try replica([try makeAsk(id, overrides)], fixture)
            if page { model.next(of: 2) }
            return try form(model, snapshot).bar
        }
        typealias Bar = AskFormModel.Bar
        let twoQuestions: [String: Any] = ["kind": "question", "payload": ["questions": [
            ["id": "a", "question": "A?", "options": [["label": "Yes"]]], ["id": "b", "question": "B?", "options": [["label": "No"]]]
        ]]]

        XCTAssertEqual(try bar(160, twoQuestions), Bar(main: .next, showsPrevious: false, showsClose: true, showsFooter: true))
        XCTAssertEqual(try bar(160, twoQuestions, page: true), Bar(main: .send, showsPrevious: true, showsClose: true, showsFooter: true))
        XCTAssertEqual(try bar(161, ["kind": "check", "payload": ["checklist": [["id": "1", "text": "Open"]]]]),
                       Bar(main: .send, showsPrevious: false, showsClose: true, showsFooter: true))
        XCTAssertEqual(try bar(162, ["kind": "review", "doc_snapshot": "# Plan\n", "payload": [String: Any]()]),
                       Bar(main: .verdicts, showsPrevious: false, showsClose: true, showsFooter: true))
        XCTAssertEqual(try bar(163, ["kind": "question", "payload_clipped": true]),
                       Bar(main: .none, showsPrevious: false, showsClose: true, showsFooter: false), "Close without answering alone")
        XCTAssertNil(try bar(164, ["kind": "folder", "payload_clipped": true]), "nothing to send from the phone")
        XCTAssertEqual(try bar(165, ["kind": "folder", "payload": ["path": "/code/app"]]),
                       Bar(main: .send, showsPrevious: false, showsClose: false, showsFooter: true))
        XCTAssertNil(try bar(166, Self.question.merging(["status": "answered"]) { _, new in new }), "a closed ask has no bar")
    }
}
