import XCTest
import GRDB
import ViewInspector
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
        // Whether a thread reads the reviewer's folder is the provider's
        // capability row.
        ProviderCatalogFixture.seedShared()
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

    /// Approve from the reviewer's status page asks once: nothing is reviewed yet.
    func testApproveWhileTheReviewerRunsAsksOnce() async throws {
        try setRow(status: "running")
        let model = try await makeModel()
        await model.load()
        XCTAssertTrue(model.canApprove)
        XCTAssertTrue(model.needsApproveConfirm)
        XCTAssertEqual(model.approveConfirmMessage, "The reviewer has not finished — approve anyway?")
        model.pressApprove()
        XCTAssertTrue(model.confirmingApprove)
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

    /// **Fix** (a comment with no body) alone is something to send: the
    /// finding goes to the author as it is.
    func testFixAloneEnablesSend() async throws {
        try setRow(status: "done", result: resultJSON())
        let model = try await makeModel()
        await model.load()
        await model.mark("ag:1", .comment)
        XCTAssertTrue(model.canSend)
        let sent = await model.send()
        guard case .delivered = sent else { return XCTFail("sent: \(sent)") }
        let answer = try await storedAnswer()
        XCTAssertTrue(answer.contains("Mute lasts a day"))
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

    /// Approve is never off (ask #690): with a comment it goes as
    /// `approved` with the comment, a fix to make; Request changes carries
    /// only the comment marks.
    func testApproveStaysOnWithCommentsAndRequestChangesSendsThem() async throws {
        try setRow(status: "done", result: resultJSON())
        let model = try await makeModel()
        await model.load()
        XCTAssertTrue(model.canApprove)
        XCTAssertEqual(model.requestCount, 0)
        await model.mark("ag:1", .comment, body: "name the period")
        await model.mark("da:1", .ok)
        XCTAssertTrue(model.canApprove)
        XCTAssertEqual(model.requestCount, 1, "an ok mark is nothing to send")
        model.note = "ship it"
        let sent = await model.send()
        guard case .delivered = sent else { return XCTFail("sent: \(sent)") }
        let answer = try await storedAnswer()
        XCTAssertTrue(answer.contains("\"changes\""), answer)
        XCTAssertTrue(answer.contains("Mute lasts a day"))
        XCTAssertFalse(answer.contains("Local db"), "an ok mark is not sent")
    }

    /// N counts every comment mark — Fix, Comment, Reviewer is right,
    /// Reopen — and the margin comments.
    func testRequestCountCountsCommentMarksAndMarginComments() async throws {
        try setRow(status: "done", result: resultJSON())
        let model = try await makeModel()
        await model.load()
        await model.mark("ag:1", .comment)
        await model.mark("bs:1", .comment, body: "say why")
        await model.mark("da:1", .notUseful)
        XCTAssertEqual(model.requestCount, 2)
        XCTAssertTrue(model.canSend)
        let anchor = CommentAnchor(quote: "Intro text", prefix: "Title\n", suffix: "\nBehaviour", heading: "Title")
        asks.editDraft(askID) { $0.comments = [OwnerAskCommentDraft(anchor: anchor, body: "say who")] }
        XCTAssertEqual(model.requestCount, 3, "a margin comment counts too")
        asks.editDraft(askID) { $0.comments = [] }
        await model.unmark("ag:1")
        await model.unmark("bs:1")
        XCTAssertEqual(model.requestCount, 0)
        XCTAssertFalse(model.canSend)
        model.note = "tighten the goal"
        XCTAssertTrue(model.canSend, "a note alone is something to change (ask #690)")
        XCTAssertTrue(model.canApprove)
    }

    /// Approve with a comment sends it as a fix to make (ask #690).
    func testApproveWithACommentSendsItAsAFix() async throws {
        try setRow(status: "done", result: resultJSON())
        let model = try await makeModel()
        await model.load()
        await model.mark("ag:1", .comment, body: "name the period")
        let sent = await model.approve()
        guard case .delivered = sent else { return XCTFail("approved: \(sent)") }
        let answer = try await storedAnswer()
        XCTAssertTrue(answer.contains("\"approved\""), answer)
        XCTAssertTrue(answer.contains("Mute lasts a day"))
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
        XCTAssertEqual(model.disputes.map(\.item.key), ["bs:2"])
        XCTAssertEqual(model.unanswered.map(\.item.key), ["ck:1"])
        XCTAssertEqual(model.fixes.map(\.item.key), ["ag:1"])
        await model.pick("bs:2", reviewerRight: true, body: " please add it ")
        XCTAssertEqual(model.marks["bs:2"]?.state, .comment)
        XCTAssertEqual(model.marks["bs:2"]?.about, "No undo")
        let sent = await model.send()
        guard case .delivered = sent else { return XCTFail("sent: \(sent)") }
        let answer = try OwnerAskAnswer.decode(try await storedAnswer())
        XCTAssertEqual(answer.verdict, .changes)
        XCTAssertEqual(answer.comments.map(\.body), ["Reviewer is right: No undo — still needed\n\nplease add it"])
        XCTAssertEqual(answer.comments.first?.heading, "Behaviour")
    }

    /// A Comment on a chapter finding the loop never carried (spec
    /// 2026-10-28 §4) goes with Request changes, as on a review without a loop.
    func testLoopCommentOnAFindingOutsideTheLedgerIsSent() async throws {
        try setLoopRow(end: "settled")
        let model = try await makeModel()
        await model.load()
        XCTAssertFalse(model.disputes.contains { $0.item.key == "da:1" } || model.fixes.contains { $0.item.key == "da:1" })
        await model.mark("da:1", .comment, body: "say why a local db")
        XCTAssertEqual(model.requestCount, 1)
        let sent = await model.send()
        guard case .delivered = sent else { return XCTFail("sent: \(sent)") }
        let answer = try OwnerAskAnswer.decode(try await storedAnswer())
        XCTAssertEqual(answer.verdict, .changes)
        XCTAssertEqual(answer.comments.map(\.body), ["Local db — say why a local db"])
    }

    /// Fix on a finding the author never answered sends the reviewer's own
    /// note, never the loop-end line.
    func testFixOnUnansweredSendsTheReviewersNote() async throws {
        try setRow(status: "done", result: resultJSON())
        let id = askID
        let ledger = """
        [{"key":"bs:9","kind":"blind_spot","text":"Spool follows the active workspace","note":"a switch moves pending calls",
          "round":3,"verdict":"unsettled","verdict_note":"Not settled in 3 rounds","settled":3}]
        """
        try await pool.write { d in
            try d.execute(sql: "UPDATE spec_reviews SET loop = 'owner', round = 3, ledger = ?, loop_end = 'cap' WHERE ask_id = ?",
                          arguments: [ledger, id])
        }
        let model = try await makeModel()
        await model.load()
        XCTAssertTrue(model.disputes.isEmpty)
        XCTAssertEqual(model.unpickedDisputeCount, 1)
        await model.pick("bs:9", reviewerRight: true)
        let sent = await model.send()
        guard case .delivered = sent else { return XCTFail("sent: \(sent)") }
        let answer = try OwnerAskAnswer.decode(try await storedAnswer())
        XCTAssertEqual(answer.comments.map(\.body), ["Reviewer is right: Spool follows the active workspace — a switch moves pending calls"])
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
        _ = await model.send()
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

    // MARK: - Discuss: card kinds, thread findings, owner items (spec 2026-11-08)

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met in \(timeout)s")
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Every kind of card one review can hold.
    private func kindsResultJSON() -> String {
        let end = snapshot.utf8.count
        return """
        {"summary":"s","chapters":[{"key":"ch:0","heading":"Title","start":0,"end":19},
        {"key":"ch:1","heading":"Behaviour","start":19,"end":\(end)}],
        "agreements":[{"key":"ag:1","text":"Mute lasts a day","status":"as_agreed","chapter":"ch:1"},
                      {"key":"ag:2","text":"Mute is per channel","status":"differs","chapter":"ch:1"}],
        "decided_alone":[{"key":"da:1","text":"Local db","chapter":"ch:0"}],
        "checks":[{"key":"ck:1","chapter":"ch:1","lens":"l","question":"q1","answer":"concern"},
                  {"key":"ck:2","chapter":"ch:1","lens":"l","question":"q2","answer":"ok"},
                  {"key":"ck:3","chapter":"ch:1","lens":"l","question":"q3","answer":"n/a"}],
        "theses":[{"key":"th:1","kind":"goal","text":"Mute for a day","chapter":"ch:1"}]}
        """
    }

    private func addThreadFinding(_ key: String, json: String) throws {
        let id = askID
        try pool.write { d in
            try d.execute(sql: """
                INSERT INTO spec_review_thread_findings (ask_id, item_key, thread, finding, created_at)
                VALUES (?, ?, ?, ?, '2026-11-08T10:00:00Z')
                """, arguments: [id, key, "1:\(id):ag:2", json])
        }
    }

    // MARK: - Discuss threads (spec 2026-11-08 §3)

    /// A model with the app's embedded chats over `ai`; the same chats on
    /// every call, as the app's center (a new screen keeps them).
    private func makeThreadModel(
        _ ai: ScriptedAIService,
        threads: SpecReviewThreadCenter? = nil,
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> SpecReviewModel {
        let base = try await makeModel()
        let pool = try XCTUnwrap(pool)
        let center = threadCenter ?? EmbeddedChatCenter { spec, gate in
            guard case .database(let conversationID) = spec.persistence else { preconditionFailure("database chat") }
            return EmbeddedChatEngine(spec: spec, store: DatabaseEmbeddedChatStore(dbPool: pool, conversationID: conversationID),
                                      aiService: ai, gate: gate)
        }
        threadCenter = center
        let model = SpecReviewModel(ask: base.ask, dbPool: pool, cli: WorkbenchCLI(runner: runner), asks: asks, chats: center,
                                    threadCenter: threads, sleep: sleep)
        model.configuredProvider = { .claude }
        return model
    }

    /// A thread on `ag:2` with one exchange in it (the owner's question and
    /// `reply`), its turn ended.
    private func discussedModel(
        _ ai: ScriptedAIService,
        reply: String = "It holds.",
        threads: SpecReviewThreadCenter? = nil,
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> SpecReviewModel {
        runner = FakeCLIRunner(stdout: Data("data".utf8))
        try setRow(status: "done", result: kindsResultJSON())
        let model = try await makeThreadModel(ai, threads: threads, sleep: sleep)
        await model.load()
        let threads = try XCTUnwrap(model.threads)
        threads.open("ag:2")
        await waitUntil { model.threadEngine("ag:2") != nil }
        XCTAssertTrue(threads.send("ag:2", "Why per channel?"))
        await waitUntil { ai.calls.count == 1 }
        ai.emit(.text(reply), .turnComplete(reply), .done)
        ai.finish()
        await waitUntil { model.threadContent("ag:2").entries.count >= 2 && !model.threadContent("ag:2").isReplying }
        await model.threadEngine("ag:2")?.finished()
        return model
    }

    /// **Fix** on a card with a thread writes the mark at once and opens the
    /// field empty; the conclusion arrives after the owner typed, and does
    /// not replace the owner's words.
    func testFixPrefillDoesNotOverwriteTyping() async throws {
        let ai = ScriptedAIService()
        let model = try await discussedModel(ai)
        let fixing = Task { await model.fix(key: "ag:2") }
        await waitUntil { model.fixDrafts["ag:2"] != nil && ai.calls.count == 2 }
        XCTAssertEqual(model.marks["ag:2"]?.state, .comment, "the Fix mark is written at once")
        XCTAssertEqual(model.fixDrafts["ag:2"]?.text, "")
        XCTAssertEqual(model.fixDrafts["ag:2"]?.isDrafting, true)
        XCTAssertEqual(ai.calls[1].prompt.contains("one-paragraph conclusion"), true)
        model.editFixDraft("ag:2", text: "My own words")
        ai.emit(.text("Make it per user."), .turnComplete("Make it per user."), .done)
        ai.finish()
        await fixing.value
        XCTAssertEqual(model.fixDrafts["ag:2"]?.text, "My own words")
        XCTAssertEqual(model.fixDrafts["ag:2"]?.isDrafting, false)
        XCTAssertEqual(model.fixDrafts["ag:2"]?.couldNotDraft, false)
        await model.saveFixDraft("ag:2")
        XCTAssertEqual(model.marks["ag:2"]?.body, "My own words")
        XCTAssertNil(model.fixDrafts["ag:2"])

        // Untouched, the conclusion fills the field.
        await model.unmark("ag:2")
        let again = Task { await model.fix(key: "ag:2") }
        await waitUntil { ai.calls.count == 3 }
        ai.emit(.text("Make it per user."), .turnComplete("Make it per user."), .done)
        ai.finish()
        await again.value
        XCTAssertEqual(model.fixDrafts["ag:2"]?.text, "Make it per user.")
    }

    /// The drafted conclusion fills the field; Request changes without Save
    /// sends it as that finding's comment, with its key.
    func testDraftedConclusionIsSentWithoutSave() async throws {
        let ai = ScriptedAIService()
        let model = try await discussedModel(ai)
        try await fillConclusion(model, ai)
        _ = await model.send()
        try await assertSentConclusion(verdict: .changes)
        XCTAssertTrue(model.fixDrafts.isEmpty)
    }

    /// The same on Approve; an empty field stays a plain Fix.
    func testDraftedConclusionIsSentOnApprove() async throws {
        let ai = ScriptedAIService()
        let model = try await discussedModel(ai)
        try await fillConclusion(model, ai)
        await model.mark("da:1", .comment)
        _ = await model.approve()
        try await assertSentConclusion(verdict: .approved)
        XCTAssertEqual(model.marks["da:1"]?.body, "", "no field: the plain Fix")
    }

    private func fillConclusion(_ model: SpecReviewModel, _ ai: ScriptedAIService) async throws {
        let fixing = Task { await model.fix(key: "ag:2") }
        await waitUntil { ai.calls.count == 2 }
        ai.emit(.text("Make it per user."), .turnComplete("Make it per user."), .done)
        ai.finish()
        await fixing.value
        XCTAssertEqual(model.fixDrafts["ag:2"]?.text, "Make it per user.")
    }

    /// A Fix comment whose write fails stays in its field, and Send and
    /// Approve stop instead of sending the answer without it.
    func testFixDraftKeptAndAnswerStoppedWhenTheSaveFails() async throws {
        let ai = ScriptedAIService()
        let model = try await discussedModel(ai)
        try await fillConclusion(model, ai)
        try await pool.write { d in try d.execute(sql: "DROP TABLE spec_review_marks") }

        let saved = await model.saveFixDraft("ag:2")
        XCTAssertFalse(saved)
        XCTAssertEqual(model.fixDrafts["ag:2"]?.text, "Make it per user.", "the owner's words are kept")
        XCTAssertNotNil(model.lastError)

        for result in [await model.send(), await model.approve()] {
            guard case let .invalid(message) = result else { return XCTFail("expected a refusal, got \(result)") }
            XCTAssertEqual(message, SpecReviewModel.fixNotSavedMessage)
        }
        let stored = try await storedAnswer()
        XCTAssertEqual(stored, "", "nothing was sent")
        XCTAssertEqual(model.fixDrafts["ag:2"]?.text, "Make it per user.")
    }

    /// The Fix field lives in the app's thread center: a conclusion still
    /// drafting when the drawer closes lands there, and the reopened screen
    /// shows it; typed words survive the same way.
    func testFixDraftSurvivesClosingTheDrawer() async throws {
        let ai = ScriptedAIService()
        let pool = try XCTUnwrap(pool)
        let threads = SpecReviewThreadCenter(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner(stdout: Data("1".utf8))),
                                             delivery: SessionLineDelivery(terminalCenter: nil), pollInterval: .seconds(3600))
        defer { threads.stop() }
        var first: SpecReviewModel? = try await discussedModel(ai, threads: threads)
        let fixing = Task { [first] in await first?.fix(key: "ag:2") }
        await waitUntil { ai.calls.count == 2 && first?.fixDrafts["ag:2"]?.isDrafting == true }
        first = nil // the drawer closed: only the running Fix holds the old screen

        let reopened = try await makeThreadModel(ai, threads: threads)
        await reopened.load()
        XCTAssertEqual(reopened.fixDrafts["ag:2"]?.isDrafting, true, "still drafting on the reopened screen")
        ai.emit(.text("Make it per user."), .turnComplete("Make it per user."), .done)
        ai.finish()
        await fixing.value
        XCTAssertEqual(reopened.fixDrafts["ag:2"]?.text, "Make it per user.")

        reopened.editFixDraft("ag:2", text: "My own words")
        let third = try await makeThreadModel(ai, threads: threads)
        await third.load()
        XCTAssertEqual(third.fixDrafts["ag:2"]?.text, "My own words")
        let saved = await third.saveFixDraft("ag:2")
        XCTAssertTrue(saved)
        XCTAssertNil(reopened.fixDrafts["ag:2"])
        XCTAssertEqual(third.marks["ag:2"]?.body, "My own words")
    }

    /// A thread on an item the re-run dropped is reachable whether or not
    /// the owner marked it: under "From the previous run", read-only.
    func testUnmarkedOrphanThreadIsListed() async throws {
        try setRow(status: "done", result: kindsResultJSON())
        for (key, title) in [("bs:gone", "Threads stay muted"), ("ag:2", "Mute is per channel")] {
            let conversation = try await SpecReviewThreadSurface.conversationID(
                workbenchID: projectID, rootAskID: askID, itemKey: key, title: title, dbPool: pool)
            try await pool.write { d in
                try d.execute(sql: """
                    INSERT INTO chat_messages (conversation_id, role, text, created_at, status) VALUES (?, 'user', 'Why?', 0, 'complete')
                    """, arguments: [conversation])
            }
        }
        let model = try await makeThreadModel(ScriptedAIService())
        await model.load()
        XCTAssertTrue(model.orphans.isEmpty, "nothing is marked")
        XCTAssertEqual(model.orphanThreads, [SpecReviewOrphanThread(key: "bs:gone", title: "Threads stay muted")],
                       "the current item's thread is not from the previous run")
        XCTAssertEqual(model.threadContent("bs:gone").persistedMessageCount, 1, "its folded line counts it")
        XCTAssertTrue(model.threadContent("bs:gone").isOrphaned)
    }

    private func assertSentConclusion(verdict: OwnerAskAnswer.Verdict) async throws {
        let answer = try OwnerAskAnswer.decode(try await storedAnswer())
        XCTAssertEqual(answer.verdict, verdict)
        let comment = try XCTUnwrap(answer.comments.first { $0.itemKey == "ag:2" })
        XCTAssertEqual(comment.body, "Mute is per channel — Make it per user.")
    }

    /// The conclusion turn runs none of the thread's block handling: a
    /// block in it files no question and shows no proposal, and the stored
    /// reply has none.
    func testConclusionTurnFilesNoQuestionAndShowsNoProposal() async throws {
        let ai = ScriptedAIService()
        let pool = try XCTUnwrap(pool)
        let threads = SpecReviewThreadCenter(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner(stdout: Data("1".utf8))),
                                             delivery: SessionLineDelivery(terminalCenter: nil), pollInterval: .seconds(3600))
        defer { threads.stop() }
        let model = try await discussedModel(ai, threads: threads)
        let fixing = Task { await model.fix(key: "ag:2") }
        await waitUntil { ai.calls.count == 2 }
        let reply = """
            Make it per user.

            ```watchtower-ask-author
            {"question": "Per user?"}
            ```

            ```watchtower-finding
            {"kind": "missing", "severity": "minor", "title": "Ends at midnight", "text": "t", \
            "quote": {"source": "document", "text": "Muting lasts"}, "where": null}
            ```
            """
        ai.emit(.text(reply), .turnComplete(reply), .done)
        ai.finish()
        await fixing.value
        XCTAssertEqual(model.fixDrafts["ag:2"]?.text, "Make it per user.")
        await model.threadEngine("ag:2")?.finished()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(threads.questions.isEmpty, "no question filed")
        let entries = model.threadContent("ag:2").entries
        XCTAssertFalse(entries.contains { if case .finding = $0 { true } else { false } }, "\(entries.map(\.id))")
        let stored = model.threadEngine("ag:2")?.messages.map(\.message).last { $0.role == "assistant" }?.text
        XCTAssertEqual(stored, "Make it per user.")
    }

    /// A chat let go while **Fix**'s turn waits for a slot ends the wait at
    /// once (`.notStarted`), never leaving it hanging; so does a withdrawn
    /// queued turn.
    func testOutcomeWaitEndsWhenTheEngineIsReleased() async throws {
        let pool = try XCTUnwrap(pool)
        let conversation = try await SpecReviewThreadSurface.conversationID(
            workbenchID: projectID, rootAskID: askID, itemKey: "ag:2", title: "t", dbPool: pool)
        let context = SpecReviewThreadContext(workbenchID: projectID, rootAskID: askID, askID: askID, itemKey: "ag:2",
                                              data: "", provider: .claude)
        // No free slot: the hidden turn waits in the queue.
        let gate = EmbeddedStreamGate(limit: 1)
        XCTAssertTrue(gate.tryAcquire(UUID()))
        let engine = EmbeddedChatEngine(
            spec: SpecReviewThreadSurface.spec(context: context, conversationID: conversation, dbPool: pool),
            store: DatabaseEmbeddedChatStore(dbPool: pool, conversationID: conversation),
            aiService: ScriptedAIService(), gate: gate)
        engine.sendHidden("conclude")
        XCTAssertTrue(engine.isQueued)
        var outcome: EmbeddedChatEngine.TurnOutcome?
        Task { outcome = await SpecReviewModel.nextOutcome(of: engine) }
        await waitUntil { engine.onTurnDropped != nil }
        engine.shutdown(quietly: true)
        await waitUntil { outcome != nil }
        XCTAssertEqual(outcome, .notStarted(message: SpecReviewOutcomeWaiter.goneMessage))
        XCTAssertNil(engine.onTurnDropped, "the waiter's hooks are gone")

        engine.sendHidden("conclude")
        outcome = nil
        Task { outcome = await SpecReviewModel.nextOutcome(of: engine) }
        await waitUntil { engine.onTurnDropped != nil }
        engine.stop()
        await waitUntil { outcome != nil }
        XCTAssertEqual(outcome, .notStarted(message: SpecReviewOutcomeWaiter.goneMessage), "Stop withdrew it")
        let none = await SpecReviewModel.nextOutcome(of: nil)
        XCTAssertEqual(none, .notStarted(message: SpecReviewOutcomeWaiter.goneMessage))
    }

    /// The conclusion takes longer than 30 s: the field stays as it is with
    /// "Couldn't draft a conclusion"; the Fix mark is in.
    func testFixPrefillTimeoutShowsLine() async throws {
        let ai = ScriptedAIService()
        var waited: [Duration] = []
        let model = try await discussedModel(ai) { duration in
            waited.append(duration)
            if duration != .seconds(30) { try await Task.sleep(for: duration) }
        }
        await model.fix(key: "ag:2")
        XCTAssertEqual(waited, [.seconds(30)])
        XCTAssertEqual(model.marks["ag:2"]?.state, .comment)
        let failed = SpecReviewFixDraft(text: "", ownerTyped: false, isDrafting: false, couldNotDraft: true)
        XCTAssertEqual(model.fixDrafts["ag:2"], failed)
        let controls = try SpecReviewMarkControls(model: model, key: "ag:2", kind: .actionable) {}.inspect()
        let editor = try controls.find(SpecReviewFixDraftEditor.self)
        XCTAssertEqual(try editor.actualView().draft.couldNotDraft, true)
        // The line under the field (searching the field itself is slow).
        XCTAssertNoThrow(try editor.vStack().hStack(1).find(text: "Couldn't draft a conclusion"))

        // A card without a thread: the plain Fix, no field.
        await model.fix(key: "da:1")
        XCTAssertEqual(model.marks["da:1"]?.state, .comment)
        XCTAssertNil(model.fixDrafts["da:1"])
    }

    /// **Add to review** refused by Go: its words stay on the proposal's card.
    func testAddToReviewRefusalShownOnCard() async throws {
        let ai = ScriptedAIService()
        let reply = """
            It is missing.

            ```watchtower-finding
            {"kind": "missing", "severity": "minor", "title": "Ends at midnight", "text": "t", \
            "quote": {"source": "document", "text": "Mute ends at midnight"}, "where": null}
            ```
            """
        let model = try await discussedModel(ai, reply: reply)
        guard case let .finding(_, proposed)? = model.threadContent("ag:2").entries.last else {
            return XCTFail("no proposal: \(model.threadContent("ag:2").entries.map(\.id))")
        }
        XCTAssertEqual(proposed.status, .proposed)
        runner.shouldThrow = CLIRunnerError.nonZeroExit(code: 3, stderr: "not added: quote not found\n")
        await model.addToReview(proposed, thread: "ag:2")
        let args = try XCTUnwrap(runner.invocations.last)
        let thread = SpecReviewThreadKey.contextID(workbenchID: projectID, rootAskID: askID, itemKey: "ag:2")
        XCTAssertEqual(args, ["workbench", "spec-review", "add-finding", "--ask=\(askID)", "--thread=\(thread)"])
        let block = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(runner.stdinInputs.last)) as? [String: Any])
        XCTAssertEqual(block["title"] as? String, "Ends at midnight")
        XCTAssertTrue(block["where"] is NSNull)
        guard case let .finding(_, shown)? = model.threadContent("ag:2").entries.last else { return XCTFail("no card") }
        XCTAssertEqual(shown.status, .refused("not added: quote not found"))
        let card = try SpecReviewProposedFindingCard(finding: shown) {}.inspect()
        XCTAssertNoThrow(try card.find(text: "not added: quote not found"))
        XCTAssertThrowsError(try card.find(button: "Add to review"))
    }

    /// A thread left open is open again when the drawer is closed and the
    /// ask reopened: the app's thread center holds it, not the screen.
    func testOpenThreadSurvivesReopeningTheScreen() async throws {
        runner = FakeCLIRunner(stdout: Data("data".utf8))
        try setRow(status: "done", result: kindsResultJSON())
        let pool = try XCTUnwrap(pool)
        let threads = SpecReviewThreadCenter(dbPool: pool, cli: WorkbenchCLI(runner: runner),
                                             delivery: SessionLineDelivery(terminalCenter: nil), pollInterval: .seconds(3600))
        defer { threads.stop() }
        let ai = ScriptedAIService()
        let first = try await makeThreadModel(ai, threads: threads)
        await first.load()
        try XCTUnwrap(first.threads).open("ag:2")
        await waitUntil { first.threadEngine("ag:2") != nil }
        XCTAssertTrue(first.threadContent("ag:2").isOpen)

        let reopened = try await makeThreadModel(ai, threads: threads)
        await reopened.load()
        XCTAssertTrue(reopened.threadContent("ag:2").isOpen)
        await waitUntil { reopened.threadEngine("ag:2") != nil }
        try XCTUnwrap(reopened.threads).hide("ag:2")
        let third = try await makeThreadModel(ai, threads: threads)
        await third.load()
        XCTAssertFalse(third.threadContent("ag:2").isOpen, "Hide folds it for next time too")
    }

    private var threadCenter: EmbeddedChatCenter?

    func testDiscussRunsOnTheReviewersDataAndShowsTheBlocks() async throws {
        runner = FakeCLIRunner(stdout: Data("```document\nMuting lasts twenty-four hours\n```".utf8))
        try setRow(status: "done", result: kindsResultJSON())
        let ai = ScriptedAIService()
        let model = try await makeThreadModel(ai)
        await model.load()
        let threads = try XCTUnwrap(model.threads)
        XCTAssertFalse(model.threadContent("ag:2").isOpen)

        threads.open("ag:2")
        await waitUntil { model.threadStates["ag:2"]?.context != nil }
        XCTAssertEqual(runner.invocations.last,
                       ["workbench", "spec-review", "thread-context", "--ask=\(askID)", "--item=ag:2"])
        XCTAssertTrue(model.threadContent("ag:2").isOpen)
        threads.open("ag:2")
        XCTAssertEqual(runner.invocations.count, 1, "the data is fetched once")

        XCTAssertTrue(threads.send("ag:2", "Why per channel?"))
        await waitUntil { ai.calls.count == 1 }
        let call = try XCTUnwrap(ai.calls.first)
        XCTAssertNil(call.toolMode, "draft-only (AGENT-04)")
        XCTAssertEqual(call.purpose, "spec_review.discuss")
        XCTAssertNil(call.readFolder)
        XCTAssertEqual(call.readFolderAskID, askID, "the CLI reads the folder this ask's reviewer read")
        XCTAssertTrue(try XCTUnwrap(call.systemPrompt).contains("Muting lasts twenty-four hours"))

        let id = askID
        let thread = SpecReviewThreadKey.contextID(workbenchID: projectID, rootAskID: id, itemKey: "ag:2")
        try await pool.write { d in
            try d.execute(sql: """
                INSERT INTO spec_review_questions (ask_id, thread, item_key, question, answer, state, created_at)
                VALUES (?, ?, 'ag:2', 'Per user?', '', 'open', '2026-11-08T10:00:00Z')
                """, arguments: [id, thread])
        }
        let reply = """
            It holds.

            ```watchtower-finding
            {"kind": "missing", "severity": "minor", "title": "Ends at midnight", "text": "t", \
            "quote": {"source": "thread", "text": "Why per channel"}, "where": null}
            ```

            ```watchtower-ask-author
            {"question": "Per user?"}
            ```
            """
        ai.emit(.text(reply), .turnComplete(reply), .done)
        ai.finish()
        await waitUntil { model.threadContent("ag:2").entries.count == 4 }
        let entries = model.threadContent("ag:2").entries
        guard entries.count == 4, case let .owner(_, owner) = entries[0], case let .assistant(_, text) = entries[1],
              case let .finding(_, finding) = entries[2], case let .question(question) = entries[3] else {
            return XCTFail("rows: \(entries.map(\.id))")
        }
        XCTAssertEqual(owner, "Why per channel?")
        XCTAssertEqual(text, "It holds.", "the blocks leave the reply's text")
        XCTAssertEqual(finding.title, "Ends at midnight")
        XCTAssertEqual(question.question, "Per user?")
        XCTAssertEqual(model.threadMessageCounts["ag:2"], 2)
    }

    /// An open thread on screen keeps its chat through the center's idle
    /// sweep; once no view draws it, the sweep lets it go, and drawing it
    /// again brings it back.
    func testShownThreadSurvivesTheSweepAndAHiddenOneIsReleased() async throws {
        runner = FakeCLIRunner(stdout: Data("data".utf8))
        try setRow(status: "done", result: kindsResultJSON())
        let model = try await makeThreadModel(ScriptedAIService())
        await model.load()
        let threads = try XCTUnwrap(model.threads)
        let center = try XCTUnwrap(threadCenter)
        threads.shown("ag:2")
        threads.open("ag:2")
        await waitUntil { model.threadEngine("ag:2") != nil }
        let later = Date().addingTimeInterval(301)

        center.sweep(now: later)
        XCTAssertNotNil(model.threadEngine("ag:2"), "a thread on screen is never swept")

        threads.hidden("ag:2")
        center.sweep(now: later.addingTimeInterval(301))
        XCTAssertNil(model.threadEngine("ag:2"), "a hidden idle thread is let go")

        threads.shown("ag:2")
        XCTAssertNotNil(model.threadEngine("ag:2"), "drawn again: back in the center")
        center.sweep(now: later.addingTimeInterval(1000))
        XCTAssertNotNil(model.threadEngine("ag:2"))
    }

    /// An orphaned item without a conversation gets none.
    func testOrphanedThreadCreatesNoConversation() async throws {
        try setRow(status: "done", result: kindsResultJSON())
        let model = try await makeThreadModel(ScriptedAIService())
        await model.load()
        try XCTUnwrap(model.threads).open("bs:gone")
        await waitUntil { model.threadStates["bs:gone"]?.isOpening == false }
        let count = try await pool.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM chat_conversations WHERE context_type = 'spec_review_thread'")
        }
        XCTAssertEqual(count, 0)
        XCTAssertNil(model.threadEngine("bs:gone"))
        XCTAssertTrue(model.threadContent("bs:gone").isOrphaned)
    }

    func testFailedThreadOpeningShowsRetry() async throws {
        runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "boom"))
        try setRow(status: "done", result: kindsResultJSON())
        let model = try await makeThreadModel(ScriptedAIService())
        await model.load()
        let threads = try XCTUnwrap(model.threads)
        threads.open("ag:2")
        await waitUntil { model.threadContent("ag:2").loadError != nil }
        XCTAssertFalse(model.threadContent("ag:2").isOpening)
        XCTAssertFalse(threads.send("ag:2", "Why?"), "nothing to send to before it opened")

        runner.shouldThrow = nil
        threads.open("ag:2")
        await waitUntil { model.threadStates["ag:2"]?.context != nil }
        XCTAssertNil(model.threadContent("ag:2").loadError)
    }

    /// A thread whose item a re-run dropped is readable only: no data to
    /// fetch, no new turn.
    func testOrphanedThreadTakesNoTurns() async throws {
        try setRow(status: "done", result: kindsResultJSON())
        let ai = ScriptedAIService()
        let model = try await makeThreadModel(ai)
        await model.load()
        XCTAssertTrue(model.isOrphanedItem("bs:gone"))
        XCTAssertFalse(model.isOrphanedItem("th:1"), "a thesis has a thread too")
        // Its thread from the previous run.
        let conversation = try await SpecReviewThreadSurface.conversationID(
            workbenchID: projectID, rootAskID: askID, itemKey: "bs:gone", title: "Gone", dbPool: pool)
        let threads = try XCTUnwrap(model.threads)
        threads.open("bs:gone")
        await waitUntil { model.threadStates["bs:gone"]?.context != nil }
        XCTAssertEqual(model.threadStates["bs:gone"]?.conversationID, conversation)
        XCTAssertNotNil(model.threadEngine("bs:gone"), "readable")
        XCTAssertTrue(runner.invocations.isEmpty)
        XCTAssertTrue(model.threadContent("bs:gone").isOrphaned)
        XCTAssertFalse(threads.send("bs:gone", "Still there?"))
        XCTAssertTrue(ai.calls.isEmpty)
    }

    func testCardKinds() async throws {
        try setRow(status: "done", result: kindsResultJSON())
        try addThreadFinding("tf:1", json: #"{"kind":"blind_spot","title":"Followed threads","text":"t","chapter":"ch:1"}"#)
        let model = try await makeModel()
        await model.load()
        XCTAssertEqual(model.cardKind(for: "ag:1"), .asAgreed)
        XCTAssertEqual(model.cardKind(for: "ag:2"), .actionable, "differs")
        XCTAssertEqual(model.cardKind(for: "da:1"), .actionable)
        XCTAssertEqual(model.cardKind(for: "ck:1"), .actionable, "a check with a concern")
        XCTAssertEqual(model.cardKind(for: "ck:2"), .checkToVerify, "a check without one")
        XCTAssertNil(model.cardKind(for: "ck:3"), "a check the reviewer found not applicable has no buttons")
        XCTAssertEqual(model.cardKind(for: "tf:1"), .fromDiscussion)
        XCTAssertEqual(model.cardKind(for: "th:1"), .thesis)
        XCTAssertEqual(SpecReviewPresentation.okLabel(model.cardKind(for: "ck:2")), "Checked")
        XCTAssertEqual(SpecReviewPresentation.okLabel(model.cardKind(for: "ag:2")), "Skip")
    }

    /// A thread finding sits in its chapter by `chapter`, one with no known
    /// chapter in Other, with the From discussion card; it counts as
    /// unmarked, and a Fix on it is no orphan of a re-run.
    func testThreadFindingsJoinTheirChapter() async throws {
        try setRow(status: "done", result: kindsResultJSON())
        try addThreadFinding("tf:1", json: #"{"kind":"blind_spot","title":"Followed threads","text":"t","chapter":"ch:1"}"#)
        try addThreadFinding("tf:2", json: #"{"kind":"missing","text":"No undo","chapter":"ch:gone"}"#)
        let model = try await makeModel()
        await model.load()
        XCTAssertEqual(model.threadFindings.map(\.key), ["tf:1", "tf:2"])
        let chapters = model.chapters
        XCTAssertEqual(chapters.map(\.key), ["ch:0", "ch:1", "other"])
        XCTAssertTrue(chapters[1].findings.contains { $0.key == "tf:1" })
        XCTAssertEqual(chapters[2].findings.map(\.key), ["tf:2"])
        let card = try XCTUnwrap(chapters[1].findings.first { $0.key == "tf:1" })
        XCTAssertEqual(SpecReviewPresentation.cardKind(for: card), .fromDiscussion)
        XCTAssertEqual(SpecReviewPresentation.badge(for: card).title, "Blind spot")
        let unmarked = model.unmarkedCount
        await model.mark("tf:1", .comment)
        XCTAssertEqual(model.unmarkedCount, unmarked - 1)
        XCTAssertEqual(model.marks["tf:1"]?.about, "Followed threads", "the comment keeps its finding's words")
        XCTAssertTrue(model.orphans.isEmpty, "an added finding is not from the previous run")
        let groups = SpecReviewPresentation.wrapUpGroups(try XCTUnwrap(model.row?.result), threadFindings: model.threadFindings)
        XCTAssertEqual(groups.last?.title, "From discussion")
        XCTAssertEqual(groups.last?.items.map(\.key), ["tf:1", "tf:2"])
    }

    /// A thread finding's quote is shown whatever its source: the owner's
    /// words, or the document's (unless it is the anchor's own quote).
    func testThreadFindingShowsItsDocumentQuote() async throws {
        try setRow(status: "done", result: kindsResultJSON())
        try addThreadFinding("tf:1", json: #"{"kind":"differs","title":"Per user","text":"t","chapter":"ch:1","quote":"#
            + #"{"source":"document","text":"Muting lasts twenty-four hours"}}"#)
        let model = try await makeModel()
        await model.load()
        let finding = try XCTUnwrap(model.threadFindings.first)
        let card = try SpecReviewFindingCard(model: model, finding: .fromDiscussion(finding)).inspect()
        XCTAssertNoThrow(try card.find(text: "The document says"))
        XCTAssertNoThrow(try card.find(SpecReviewQuote.self) { try $0.actualView().quote == "Muting lasts twenty-four hours" })
    }

    /// The composer takes the focus on an explicit **Discuss** only, not
    /// when a thread left open is drawn again.
    func testThreadComposerFocusesOnDiscussOnly() throws {
        let threads = SpecReviewThreads { _ in SpecReviewThreadContent(isOpen: true) }
        func autoFocus(_ visibility: SpecReviewThreadVisibility) throws -> Bool {
            let section = SpecReviewCardThreadSection(key: "ag:1", visibility: .constant(visibility))
                .environment(\.specReviewThreads, threads)
            return try section.inspect().find(SpecReviewThreadView.self).actualView().autoFocus
        }
        XCTAssertFalse(try autoFocus(.auto))
        XCTAssertFalse(try autoFocus(.shown))
        XCTAssertTrue(try autoFocus(.discussed))
    }

    /// The thread key's root is the first ask of the review chain.
    func testRootAskIDIsTheChainsFirstAsk() async throws {
        let (id, project) = (askID, projectID)
        let first = try await pool.write { d in
            let first = try TestDatabase.insertOwnerAsk(d, projectID: project, kind: "review", docPath: "spec.md")
            try d.execute(sql: "UPDATE owner_asks SET previous_ask_id = ? WHERE id = ?", arguments: [first, id])
            return first
        }
        try setRow(status: "done", result: kindsResultJSON())
        let model = try await makeModel()
        XCTAssertEqual(model.rootAskID, askID, "the ask itself until loaded")
        await model.load()
        XCTAssertEqual(model.rootAskID, first)
    }

    /// **Skip** is today's Fine as is: the one `ok` mark, written to the
    /// database; **Checked** on a check to verify is the same mark.
    func testSkipWritesOkMark() async throws {
        try setRow(status: "done", result: kindsResultJSON())
        let model = try await makeModel()
        await model.load()
        try SpecReviewMarkControls(model: model, key: "ag:2", kind: XCTUnwrap(model.cardKind(for: "ag:2")))
            .inspect().find(button: "Skip").tap()
        await waitUntil { model.marks["ag:2"] != nil }
        try SpecReviewMarkControls(model: model, key: "ck:2", kind: XCTUnwrap(model.cardKind(for: "ck:2")))
            .inspect().find(button: "Checked").tap()
        await waitUntil { model.marks["ck:2"] != nil }
        let id = askID
        let stored = try await pool.read { d in
            let rows = try Row.fetchAll(d, sql: "SELECT item_key, state FROM spec_review_marks WHERE ask_id = ? ORDER BY item_key",
                                        arguments: [id])
            return rows.map { "\($0["item_key"] as String)=\($0["state"] as String)" }
        }
        XCTAssertEqual(stored, ["ag:2=ok", "ck:2=ok"])
        let checked = try SpecReviewMarkControls(model: model, key: "ck:2", kind: .checkToVerify).inspect()
        let labels = try checked.findAll(ViewType.Text.self).map { try $0.string() }
        XCTAssertTrue(labels.contains("Checked"), "\(labels)")
    }

    /// After **Fix** the card still offers **Add Comment** for a one-line
    /// note without a thread (spec 2026-11-08 §2).
    func testPickedFixKeepsAddComment() async throws {
        try setRow(status: "done", result: kindsResultJSON())
        let model = try await makeModel()
        await model.load()
        let controls = SpecReviewMarkControls(model: model, key: "ag:2", kind: .actionable) {}
        XCTAssertThrowsError(try controls.inspect().find(button: "Add Comment"), "no Add Comment before Fix")
        XCTAssertThrowsError(try controls.inspect().find(button: "Comment"), "Discuss stands in Comment's place")
        try controls.inspect().find(button: "Fix").tap()
        await waitUntil { model.marks["ag:2"]?.state == .comment }
        XCTAssertEqual(model.marks["ag:2"]?.body, "", "Fix sends the finding as it is")
        XCTAssertNoThrow(try controls.inspect().find(button: "Add Comment"))
        XCTAssertNoThrow(try controls.inspect().find(button: "Undo"))
    }

    /// In a loop seeded from the owner's Request changes, each of the
    /// owner's own items says whether the author fixed it; a stalled
    /// loop's end line is said once, never on a card.
    func testOwnerItemsShowFixedOrOpen() async throws {
        try setRow(status: "done", result: resultJSON())
        let id = askID
        let stalled = SpecReviewLoop.stalledNote
        let ledger = """
        [{"key":"ow:1","kind":"owner_comment","text":"Say what mute does to threads","note":"","round":1,
          "reply":{"key":"ow:1","reply":"fixed","note":"added a line"},"verdict":"resolved","verdict_note":"ok","settled":1},
         {"key":"ow:2","kind":"owner_comment","text":"Drop the local db","note":"","round":1,
          "reply":{"key":"ow:2","reply":"disagree","note":"needed offline"},"verdict":"disputed","verdict_note":"still needed","settled":2},
         {"key":"ow:3","kind":"owner_comment","text":"Name the setting","note":"","round":2,
          "verdict":"unsettled","verdict_note":"\(stalled)","settled":2},
         {"key":"bs:2","kind":"blind_spot","text":"No undo","note":"","round":1,
          "reply":{"key":"bs:2","reply":"fixed","note":""},"verdict":"resolved","verdict_note":"ok","settled":1},
         {"key":"da:9","kind":"decided_alone","text":"Muted for a day","note":"midnight","round":1,"owner":true,
          "reply":{"key":"da:9","reply":"fixed","note":""},"verdict":"resolved","verdict_note":"ok","settled":1}]
        """
        try await pool.write { d in
            try d.execute(sql: "UPDATE spec_reviews SET loop = 'owner', round = 2, ledger = ?, loop_end = 'stalled' WHERE ask_id = ?",
                          arguments: [ledger, id])
        }
        let model = try await makeModel()
        await model.load()
        func line(_ key: String) -> String? {
            (model.fixes + model.disputes + model.unanswered).first { $0.item.key == key }.flatMap(SpecReviewLoop.ownerItemLine)
        }
        XCTAssertEqual(model.fixes.map(\.item.key), ["ow:1", "bs:2", "da:9"])
        XCTAssertEqual(line("ow:1"), "Your item — fixed by the author")
        XCTAssertEqual(line("da:9"), "Your item — fixed by the author", "a Fix on a reviewer finding is the owner's item too")
        XCTAssertEqual(line("ow:2"), "Your item — still open")
        XCTAssertEqual(line("ow:3"), "Your item — still open")
        XCTAssertNil(line("bs:2"), "the reviewer's own finding has no such line")
        XCTAssertEqual(model.cardKind(for: "ow:1"), .fixedByAuthor)
        XCTAssertEqual(model.cardKind(for: "ow:2"), .dispute)
        XCTAssertEqual(model.cardKind(for: "ow:3"), .unanswered)
        XCTAssertEqual(SpecReviewPresentation.loopBadge(try XCTUnwrap(model.unanswered.first)).title, "Your item · New in round 2")
        XCTAssertEqual(model.row.flatMap(SpecReviewLoop.endLine),
                       "The reviewer and the author stopped making progress: these are still open.")
        XCTAssertNil(SpecReviewPresentation.loopStatus(try XCTUnwrap(model.unanswered.first)),
                     "the end line is shown once, not on the card")
    }

    private func storedAnswer() async throws -> String {
        let id = askID
        return try await pool.read { d in
            try String.fetchOne(d, sql: "SELECT answer FROM owner_asks WHERE id = ?", arguments: [id]) ?? ""
        }
    }
}
