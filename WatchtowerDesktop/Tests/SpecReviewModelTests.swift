import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class SpecReviewModelTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var runner: FakeCLIRunner!
    private var askID: Int64 = 0
    private var asks: OwnerAsksViewModel!
    private var projectID: Int64 = 0

    private let snapshot = "# Title\nIntro text\n## Behaviour\nMuting lasts twenty-four hours\n"

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "SpecReviewModelTests-\(UUID().uuidString)"))
        runner = FakeCLIRunner()
        let snapshot = snapshot
        (projectID, askID) = try pool.write { d in
            let p = try TestDatabase.insertWorkbench(d, folder: NSTemporaryDirectory())
            let id = try TestDatabase.insertOwnerAsk(d, projectID: p, kind: "review", docPath: "spec.md")
            try d.execute(sql: "UPDATE owner_asks SET doc_snapshot = ? WHERE id = ?", arguments: [snapshot, id])
            return (p, id)
        }
    }

    /// Chapters: ch:0 = "# Title\nIntro text\n" (19 bytes), ch:1 = the rest.
    private func resultJSON(extra: String = "") -> String {
        let end = snapshot.utf8.count
        return """
        {"summary":"s","chapters":[{"key":"ch:0","heading":"Title","start":0,"end":19},
        {"key":"ch:1","heading":"Behaviour","start":19,"end":\(end)}],
        "agreements":[{"key":"ag:1","text":"Mute lasts a day","status":"as_agreed","chapter":"ch:1"}],
        "decided_alone":[{"key":"da:1","text":"Local db","chapter":"ch:0"}],
        "blind_spots":[{"key":"bs:1","text":"Lost chapter","chapter":"ch:gone"}],
        "checks":[{"key":"ck:1","chapter":"ch:1","lens":"l","question":"q","answer":"concern"}]\(extra)}
        """
    }

    private func setRow(status: String, result: String = "") throws {
        let id = askID
        try pool.write { d in
            try d.execute(sql: """
                INSERT INTO spec_reviews (ask_id, status, result, queued_at) VALUES (?, ?, ?, '2026-10-25T10:00:00Z')
                ON CONFLICT(ask_id) DO UPDATE SET status = excluded.status, result = excluded.result
                """, arguments: [id, status, result])
        }
    }

    private func makeModel(
        sleep: @escaping (Duration) async throws -> Void = { _ in await Task.yield() }
    ) async throws -> SpecReviewModel {
        let asks = OwnerAsksViewModel(
            dbPool: pool, terminalCenter: nil, lineDelivery: SessionLineDelivery(terminalCenter: nil), defaults: defaults
        )
        self.asks = asks
        await asks.load(projectID: projectID)
        let ask = try XCTUnwrap(asks.openAsks[projectID]?.first { $0.id == askID })
        return SpecReviewModel(ask: ask, dbPool: pool, cli: WorkbenchCLI(runner: runner), asks: asks, sleep: sleep)
    }

    /// The asks view model alone, no SpecReviewModel ever built: the
    /// classic footer, a Quick answer or the phone's relay.
    private func makeAsks() async throws -> (OwnerAsksViewModel, OwnerAsk) {
        let asks = OwnerAsksViewModel(
            dbPool: pool, terminalCenter: nil, lineDelivery: SessionLineDelivery(terminalCenter: nil), defaults: defaults
        )
        self.asks = asks
        await asks.load(projectID: projectID)
        return (asks, try XCTUnwrap(asks.openAsks[projectID]?.first { $0.id == askID }))
    }

    /// A mark as the Desktop screen writes it.
    private func writeMark(_ key: String, _ state: String, body: String = "", about: String = "") throws {
        let id = askID
        try pool.write { d in
            try d.execute(sql: """
                INSERT INTO spec_review_marks (ask_id, item_key, state, body, about, updated_at)
                VALUES (?, ?, ?, ?, ?, '2026-10-25T10:00:00Z')
                """, arguments: [id, key, state, body, about])
        }
    }

    /// The screen hands the draft to the one answer path; the marks'
    /// comments are placed there, from the database, so the model never
    /// places (or renders) anything on a mark, a load or a keystroke.
    func testScreenAnswerIsTheDraftAndMarksAreAddedOnceFromTheDatabase() async throws {
        try setRow(status: "done", result: resultJSON())
        let model = try await makeModel()
        await model.load()
        await model.mark("ag:1", .comment, body: "keep")
        await model.mark("da:1", .comment, body: "why?")
        XCTAssertEqual(model.answer(verdict: .changes).comments.count, 0, "the draft has no margin comment")
        XCTAssertNil(model.answerBlocker)
        let sent = await model.send()
        guard case .delivered = sent else { return XCTFail("sent: \(sent)") }
        let answer = try OwnerAskAnswer.decode(try await storedAnswer())
        XCTAssertEqual(answer.comments.map(\.body), ["Mute lasts a day — keep", "Local db — why?"], "each mark once")
    }

    func testChaptersGroupFindingsAndOther() async throws {
        try setRow(status: "done", result: resultJSON())
        let model = try await makeModel()
        await model.load()
        let chapters = model.chapters
        XCTAssertEqual(chapters.map(\.key), ["ch:0", "ch:1", "other"])
        XCTAssertEqual(chapters[0].findings.map(\.key), ["da:1"])
        XCTAssertEqual(chapters[1].findings.map(\.key), ["ag:1"])
        XCTAssertEqual(chapters[1].checks.map(\.key), ["ck:1"])
        XCTAssertEqual(chapters[1].excerpt, "## Behaviour\nMuting lasts twenty-four hours\n")
        XCTAssertEqual(chapters[2].heading, "Other")
        XCTAssertEqual(chapters[2].findings.map(\.key), ["bs:1"])
        XCTAssertEqual(model.chapterKey, "ch:0")
    }

    func testPollingStopsWhenDone() async throws {
        try setRow(status: "running")
        var ticks = 0
        let id = askID
        let pool = try XCTUnwrap(pool)
        let model = try await makeModel { _ in
            ticks += 1
            if ticks == 3 {
                try pool.write { d in
                    try d.execute(sql: "UPDATE spec_reviews SET status = 'done' WHERE ask_id = ?", arguments: [id])
                }
            }
        }
        await model.load()
        model.startPolling()
        XCTAssertTrue(model.isPolling)
        await model.waitForPolling()
        XCTAssertFalse(model.isPolling)
        XCTAssertEqual(ticks, 3)
        XCTAssertEqual(model.row?.status, .done)
        model.startPolling()
        XCTAssertFalse(model.isPolling, "a finished review is not polled")
    }

    func testStopPollingCancelsTheTask() async throws {
        try setRow(status: "running")
        let model = try await makeModel { _ in try await Task.sleep(for: .seconds(3600)) }
        await model.load()
        model.startPolling()
        XCTAssertTrue(model.isPolling)
        model.stopPolling()
        XCTAssertFalse(model.isPolling)
    }

    func testRerunCarriesMarksAndListsOrphans() async throws {
        try setRow(status: "done", result: resultJSON())
        let model = try await makeModel()
        await model.load()
        await model.mark("ag:1", .comment, body: "keep")
        await model.mark("old:9", .comment, body: "from before")
        await model.mark("ch:1", .viewed)
        XCTAssertEqual(model.orphans.map(\.key), ["old:9"])

        await model.runReviewer()
        XCTAssertEqual(runner.invocations.last, ["workbench", "spec-review", "start", "--ask", String(askID), "--force"])
        // The reviewer ran again: same agreement key, the old finding gone.
        try setRow(status: "done", result: resultJSON().replacingOccurrences(of: "ag:1", with: "ag:2"))
        await model.load()
        XCTAssertEqual(Set(model.orphans.map(\.key)), ["ag:1", "old:9"])
        XCTAssertEqual(model.marks["ch:1"]?.state, .viewed)
        XCTAssertTrue(model.chapters.first { $0.key == "ch:1" }?.viewed == true)
    }

    func testRunReviewerExit3SaysAlreadyRunning() async throws {
        try setRow(status: "running")
        runner.shouldThrow = CLIRunnerError.nonZeroExit(code: 3, stderr: "busy")
        let model = try await makeModel { _ in try await Task.sleep(for: .seconds(3600)) }
        await model.runReviewer()
        XCTAssertEqual(model.lastError, "The reviewer is already running")
        model.stopPolling()
    }

    func testApproveWithUnmarkedNeedsConfirmFlag() async throws {
        try setRow(status: "done", result: resultJSON())
        let model = try await makeModel()
        await model.load()
        XCTAssertEqual(model.unmarkedCount, 4)
        XCTAssertTrue(model.needsApproveConfirm)
        XCTAssertEqual(model.approveConfirmMessage, "4 findings are not marked. Approve anyway?")
        for key in ["ag:1", "da:1", "bs:1", "ck:1"] { await model.mark(key, .ok) }
        XCTAssertEqual(model.unmarkedCount, 0)
        XCTAssertFalse(model.needsApproveConfirm)
        await model.unmark("ck:1")
        XCTAssertEqual(model.unmarkedCount, 1)
    }

    func testSendDisabledWithoutComments() async throws {
        try setRow(status: "done", result: resultJSON())
        let model = try await makeModel()
        await model.load()
        XCTAssertFalse(model.canSend)
        await model.mark("ag:1", .ok)
        XCTAssertFalse(model.canSend)
        let refused = await model.send()
        guard case .invalid = refused else { return XCTFail("send without comments is refused: \(refused)") }

        await model.mark("ag:1", .comment, body: "name the period")
        XCTAssertTrue(model.canSend)
        let sent = await model.send()
        guard case .delivered = sent else { return XCTFail("sent: \(sent)") }
        let askID = self.askID
        let stored = try await pool.read { d in
            try Row.fetchOne(d, sql: "SELECT status, answer FROM owner_asks WHERE id = ?", arguments: [askID])
        }
        XCTAssertEqual(stored?["status"] as String?, "answered")
        XCTAssertTrue((stored?["answer"] as String?)?.contains("Mute lasts a day") == true)
    }

    func testBlankCommentDoesNotEnableSend() async throws {
        try setRow(status: "done", result: resultJSON())
        let model = try await makeModel()
        await model.load()
        await model.mark("ag:1", .comment, body: "  \n")
        XCTAssertFalse(model.canSend)
    }

    func testRestartedPollingSurvivesTheOldTaskEnding() async throws {
        try setRow(status: "running")
        let model = try await makeModel { _ in try await Task.sleep(for: .seconds(3600)) }
        await model.load()
        model.startPolling()
        model.stopPolling()
        model.startPolling()
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(model.isPolling)
        model.stopPolling()
    }

    func testApproveWithResultSendsApprovedAndOnlyComments() async throws {
        try setRow(status: "done", result: resultJSON())
        let model = try await makeModel()
        await model.load()
        await model.mark("ag:1", .comment, body: "name the period")
        await model.mark("da:1", .ok)
        model.note = "ship it"
        let sent = await model.approve()
        guard case .delivered = sent else { return XCTFail("approved: \(sent)") }
        let answer = try await storedAnswer()
        XCTAssertTrue(answer.contains("\"approved\""), answer)
        XCTAssertTrue(answer.contains("Mute lasts a day"))
        XCTAssertFalse(answer.contains("Local db"), "an ok mark is not sent")
    }

    func testApproveWithoutResultStillAnswers() async throws {
        try setRow(status: "failed")
        let model = try await makeModel()
        await model.load()
        XCTAssertNil(model.row?.result)
        let sent = await model.approve()
        guard case .delivered = sent else { return XCTFail("approved: \(sent)") }
        let answer = try await storedAnswer()
        XCTAssertTrue(answer.contains("\"approved\""))
    }

    /// Send from the screen carries the margin comments made under Read the
    /// spec and the note, after nothing is dropped.
    func testSendCarriesTheDraftsMarginComments() async throws {
        try setRow(status: "done", result: resultJSON())
        let model = try await makeModel()
        await model.load()
        let ask = try XCTUnwrap(asks.openAsks[projectID]?.first { $0.id == askID })
        let anchor = CommentAnchor(quote: "Intro text", prefix: "Title\n", suffix: "\nBehaviour", heading: "Title")
        asks.editDraft(askID) { $0.comments = [OwnerAskCommentDraft(anchor: anchor, body: "say who")] }
        XCTAssertTrue(model.canSend, "a margin comment alone is something to send")
        await model.mark("ag:1", .comment, body: "name the period")
        let sent = await model.send()
        guard case .delivered = sent else { return XCTFail("sent: \(sent)") }
        let answer = try OwnerAskAnswer.decode(try await storedAnswer())
        XCTAssertEqual(answer.verdict, .changes)
        XCTAssertEqual(answer.comments.map(\.body), ["say who", "Mute lasts a day — name the period"])
        XCTAssertEqual(ask.kind, .review)
    }

    /// The classic footer's Request changes sends the findings' comments too.
    func testClassicVerdictCarriesTheMarksComments() async throws {
        try setRow(status: "done", result: resultJSON())
        let model = try await makeModel()
        await model.load()
        await model.mark("da:1", .comment, body: "ask me first")
        let ask = try XCTUnwrap(asks.openAsks[projectID]?.first { $0.id == askID })
        let delivery = await asks.answer(ask, verdict: .changes)
        XCTAssertNotNil(delivery)
        let answer = try OwnerAskAnswer.decode(try await storedAnswer())
        XCTAssertEqual(answer.verdict, .changes)
        XCTAssertEqual(answer.comments.map(\.body), ["Local db — ask me first"])
    }

    /// F5: the classic footer with no SpecReviewModel ever loaded (the
    /// marks written earlier, say before a relaunch) still sends them.
    func testClassicFooterWithoutALoadedModelSendsTheStoredMarks() async throws {
        try setRow(status: "done", result: resultJSON())
        try writeMark("ag:1", "comment", body: "name the period", about: "Mute lasts a day")
        try writeMark("da:1", "ok")
        let (asks, ask) = try await makeAsks()
        let delivery = await asks.answer(ask, verdict: .approved)
        XCTAssertNotNil(delivery)
        let answer = try OwnerAskAnswer.decode(try await storedAnswer())
        XCTAssertEqual(answer.verdict, .approved)
        XCTAssertEqual(answer.comments.map(\.body), ["Mute lasts a day — name the period"])
        XCTAssertEqual(answer.comments.first?.heading, "Behaviour", "anchored in its chapter")
    }

    /// F1: while the reviewer is queued, running or failed (no result) the
    /// footer sends every comment mark as the screen does: "From the
    /// previous run" with its finding text.
    func testNoResultSendsEveryCommentMarkAsFromThePreviousRun() async throws {
        for status in ["queued", "running", "failed"] {
            try setUpWithError()
            try setRow(status: status)
            try writeMark("ag:1", "comment", body: "keep", about: "Mute lasts a day")
            try writeMark("ch:1", "viewed")
            let (asks, ask) = try await makeAsks()
            let delivery = await asks.answer(ask, verdict: .changes)
            XCTAssertNotNil(delivery, status)
            let answer = try OwnerAskAnswer.decode(try await storedAnswer())
            XCTAssertEqual(answer.comments.map(\.body), ["From the previous run: Mute lasts a day — keep"], status)
        }
    }

    /// The phone's answer (the relay ends in `answer(_:with:)`) and a Quick
    /// path carry the marks too; a dismissal carries none.
    func testRelayAnswerCarriesTheMarksAndADismissalDoesNot() async throws {
        try setRow(status: "done", result: resultJSON())
        try writeMark("bs:1", "comment", body: "check it", about: "Lost chapter")
        let (asks, ask) = try await makeAsks()
        var relayed = OwnerAskAnswer()
        relayed.verdict = .changes
        let result = await asks.answerQuick(ask, with: relayed)
        guard case .delivered = result else { return XCTFail("relayed: \(result)") }
        let answer = try OwnerAskAnswer.decode(try await storedAnswer())
        XCTAssertEqual(answer.comments.map(\.body), ["Lost chapter — check it"])

        try setUpWithError()
        try setRow(status: "done", result: resultJSON())
        try writeMark("bs:1", "comment", body: "check it", about: "Lost chapter")
        let (asks2, ask2) = try await makeAsks()
        _ = await asks2.answer(ask2, with: .dismissal)
        let dismissed = try OwnerAskAnswer.decode(try await storedAnswer())
        XCTAssertTrue(dismissed.comments.isEmpty)
    }

    /// F11: the model looks for a row that is not there yet and starts the
    /// poll once it turns up while the reviewer runs.
    func testFollowReviewerWaitsForTheRowThenPolls() async throws {
        var ticks = 0
        let pool = try XCTUnwrap(pool)
        let id = askID
        let model = try await makeModel { _ in
            ticks += 1
            if ticks == 2 {
                try await pool.write { d in
                    try d.execute(sql: """
                        INSERT INTO spec_reviews (ask_id, status, queued_at) VALUES (?, 'running', '2026-10-25T10:00:00Z')
                        """, arguments: [id])
                }
            }
            if ticks > 2 { try await Task.sleep(for: .seconds(3600)) }
        }
        await model.load()
        XCTAssertNil(model.row)
        await model.followReviewer()
        XCTAssertEqual(model.row?.status, .running)
        XCTAssertTrue(model.isPolling)
        model.stopPolling()
    }

    /// A review ask with questions: Send and Approve say why they are off
    /// until the questions are answered (on Meaning), then the answer
    /// carries the picks.
    func testReviewAskWithQuestionsIsAnsweredFromTheScreen() async throws {
        let id = askID
        try await pool.write { d in
            try d.execute(sql: "UPDATE owner_asks SET payload = ? WHERE id = ?", arguments: [
                #"{"questions":[{"id":"q1","question":"Ship it this week?","options":[{"label":"Yes"},{"label":"No"}]}]}"#, id
            ])
        }
        try setRow(status: "done", result: resultJSON())
        let model = try await makeModel()
        await model.load()
        XCTAssertTrue(model.hasQuestions)
        XCTAssertEqual(model.answerBlocker, "Answer the ask's questions on Meaning first")
        asks.editDraft(askID) { $0.picks["q1"] = ChatQuestionAnswer.Entry(labels: ["Yes"]) }
        XCTAssertNil(model.answerBlocker)
        let sent = await model.approve()
        guard case .delivered = sent else { return XCTFail("approved: \(sent)") }
        let answer = try OwnerAskAnswer.decode(try await storedAnswer())
        XCTAssertEqual(answer.answers.first?.labels, ["Yes"])
        XCTAssertEqual(answer.verdict, .approved)
    }

    /// A comment keeps its finding's text, so a re-run that drops the
    /// finding still lists what it was about.
    func testCommentMarkKeepsItsFindingText() async throws {
        try setRow(status: "done", result: resultJSON())
        let model = try await makeModel()
        await model.load()
        await model.mark("ag:1", .comment, body: "keep")
        try setRow(status: "done", result: resultJSON().replacingOccurrences(of: "ag:1", with: "ag:2"))
        await model.load()
        XCTAssertEqual(model.orphans.first?.about, "Mute lasts a day")
        XCTAssertEqual(model.orphans.first?.body, "keep")
    }

    /// F3: a plan keeps no Decisions section, so Meaning shows none.
    func testAPlanShowsNoDecisionsList() async throws {
        let spec = try await makeModel()
        XCTAssertTrue(spec.showsDecisions)
        let id = askID
        try await pool.write { d in
            try d.execute(sql: "UPDATE owner_asks SET doc_type = 'plan' WHERE id = ?", arguments: [id])
        }
        let plan = try await makeModel()
        XCTAssertFalse(plan.showsDecisions)
    }

    // MARK: - Author loop (spec 2026-10-26 §6–§7)

    /// ag:1 fixed in round 2; bs:2 disputed with a reason; ck:1 not settled.
    private let loopLedger = """
    [{"key":"ag:1","kind":"agreement","text":"Mute lasts a day","note":"","round":1,
      "reply":{"key":"ag:1","reply":"fixed","note":"now a day"},"verdict":"resolved","verdict_note":"ok","settled":2},
     {"key":"bs:2","kind":"blind_spot","text":"No undo","note":"","where":{"heading":"Behaviour","quote":"Muting lasts twenty-four hours"},
      "round":1,"reply":{"key":"bs:2","reply":"disagree","note":"out of scope"},"verdict":"disputed","verdict_note":"still needed","settled":2},
     {"key":"ck:1","kind":"check","text":"q","note":"","round":2,"verdict":"unsettled","verdict_note":"Not settled in 3 rounds","settled":3}]
    """

    private func setLoopRow(end: String) throws {
        try setRow(status: "done", result: resultJSON())
        let id = askID
        let ledger = loopLedger
        try pool.write { d in
            try d.execute(sql: """
                UPDATE spec_reviews SET loop = 'owner', round = 3, ledger = ?, loop_end = ? WHERE ask_id = ?
                """, arguments: [ledger, end, id])
        }
    }

    func testAnswerReviewerRightBecomesComment() async throws {
        try setLoopRow(end: "settled")
        let model = try await makeModel()
        await model.load()
        XCTAssertTrue(model.isLoop)
        XCTAssertEqual(model.phase, .wrapup, "a finished loop opens on Decide")
        XCTAssertEqual(model.disputes.map(\.item.key), ["bs:2", "ck:1"])
        XCTAssertEqual(model.fixes.map(\.item.key), ["ag:1"])
        await model.pick("bs:2", reviewerRight: true, body: " please add it ")
        XCTAssertEqual(model.marks["bs:2"]?.state, .comment)
        XCTAssertEqual(model.marks["bs:2"]?.about, "No undo")
        let sent = await model.approve()
        guard case .delivered = sent else { return XCTFail("approved: \(sent)") }
        let answer = try OwnerAskAnswer.decode(try await storedAnswer())
        XCTAssertEqual(answer.verdict, .approved)
        XCTAssertEqual(answer.comments.map(\.body), ["Reviewer is right: No undo — still needed\n\nplease add it"])
        XCTAssertEqual(answer.comments.first?.heading, "Behaviour")
    }

    func testAnswerAuthorRightSendsNothing() async throws {
        try setLoopRow(end: "settled")
        let model = try await makeModel()
        await model.load()
        await model.pick("bs:2", reviewerRight: false)
        XCTAssertEqual(model.marks["bs:2"]?.state, .ok)
        _ = await model.approve()
        let answer = try OwnerAskAnswer.decode(try await storedAnswer())
        XCTAssertEqual(answer.verdict, .approved)
        XCTAssertTrue(answer.comments.isEmpty)
    }

    func testReopenNeedsBody() async throws {
        try setLoopRow(end: "settled")
        let model = try await makeModel()
        await model.load()
        let blank = await model.reopen("ag:1", body: "  \n")
        XCTAssertFalse(blank)
        XCTAssertNil(model.marks["ag:1"])
        XCTAssertNotNil(model.lastError)
        let saved = await model.reopen("ag:1", body: "still says a week")
        XCTAssertTrue(saved)
        XCTAssertEqual(model.marks["ag:1"]?.state, .comment)
        _ = await model.approve()
        let answer = try OwnerAskAnswer.decode(try await storedAnswer())
        XCTAssertEqual(answer.comments.map(\.body), ["Reopened: Mute lasts a day\n\nstill says a week"])
        XCTAssertEqual(answer.comments.first?.heading, "Behaviour", "no where: the finding's chapter heading")
    }

    func testApproveConfirmsOnlyAfterEarlyEnd() async throws {
        try setLoopRow(end: "settled")
        let settled = try await makeModel()
        await settled.load()
        XCTAssertEqual(settled.unpickedDisputeCount, 2)
        XCTAssertFalse(settled.needsApproveConfirm, "a normal end approves in one press")

        try setLoopRow(end: "timeout")
        let early = try await makeModel()
        await early.load()
        XCTAssertTrue(early.needsApproveConfirm)
        XCTAssertEqual(early.approveConfirmMessage, "2 disputed findings were never answered — approve anyway?")
        await early.pick("bs:2", reviewerRight: false)
        XCTAssertEqual(early.approveConfirmMessage, "1 disputed finding was never answered — approve anyway?")
        await early.pick("ck:1", reviewerRight: true)
        XCTAssertFalse(early.needsApproveConfirm)
    }

    func testUnpickedDisputeIsAuthorRight() async throws {
        try setLoopRow(end: "cap")
        let model = try await makeModel()
        await model.load()
        _ = await model.approve()
        let answer = try OwnerAskAnswer.decode(try await storedAnswer())
        XCTAssertEqual(answer.verdict, .approved)
        XCTAssertTrue(answer.comments.isEmpty, "an unpicked dispute sends nothing")
    }

    /// The classic footer (or the phone) on a finished loop: the owner's
    /// Request changes stays `changes`, with the loop's comments.
    func testLoopClassicAnswerKeepsTheOwnersVerdict() async throws {
        try setLoopRow(end: "settled")
        try writeMark("bs:2", "comment", body: "")
        let (asks, ask) = try await makeAsks()
        _ = await asks.answer(ask, verdict: .changes)
        let answer = try OwnerAskAnswer.decode(try await storedAnswer())
        XCTAssertEqual(answer.verdict, .changes)
        XCTAssertEqual(answer.comments.map(\.body), ["Reviewer is right: No undo — still needed"])
    }

    /// Round 1's reviewer failed: an empty ledger, the owner gets today's
    /// classic ask, and their Request changes is not flipped to approved.
    func testEmptyLoopLedgerKeepsRequestChanges() async throws {
        try setRow(status: "failed")
        let id = askID
        try await pool.write { d in
            try d.execute(sql: """
                UPDATE spec_reviews SET loop = 'owner', round = 1, ledger = '[]', loop_end = 'reviewer_failed' WHERE ask_id = ?
                """, arguments: [id])
        }
        let (asks, ask) = try await makeAsks()
        _ = await asks.answer(ask, verdict: .changes)
        let stored = try await storedAnswer()
        XCTAssertEqual(try OwnerAskAnswer.decode(stored).verdict, .changes)
    }

    private func storedAnswer() async throws -> String {
        let id = askID
        return try await pool.read { d in
            try String.fetchOne(d, sql: "SELECT answer FROM owner_asks WHERE id = ?", arguments: [id]) ?? ""
        }
    }
}
