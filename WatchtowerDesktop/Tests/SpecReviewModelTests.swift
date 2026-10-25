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
        sleep: @escaping (Duration) async throws -> Void = { _ in await Task.yield() },
        render: @escaping (String) -> RenderedDocument = { DocumentRendering.render($0) }
    ) async throws -> SpecReviewModel {
        let dbm = DatabaseManager(pool: pool)
        let asks = OwnerAsksViewModel(
            dbPool: pool, terminalCenter: nil, lineDelivery: SessionLineDelivery(terminalCenter: nil), defaults: defaults
        )
        self.asks = asks
        await asks.load(projectID: projectID)
        let ask = try XCTUnwrap(asks.openAsks[projectID]?.first { $0.id == askID })
        return SpecReviewModel(ask: ask, db: dbm, cli: WorkbenchCLI(runner: runner), asks: asks, sleep: sleep, render: render)
    }

    /// The snapshot is rendered once for the model's life: poll loads and
    /// mark changes reuse it, and the Wrap-up's answerBlocker (read on every
    /// body evaluation, so on every keystroke of the note) never renders.
    func testSnapshotIsRenderedOnceAndAnswerBlockerNeverRenders() async throws {
        try setRow(status: "done", result: resultJSON())
        var renders = 0
        let countingRender: (String) -> RenderedDocument = { renders += 1; return DocumentRendering.render($0) }
        let model = try await makeModel(render: countingRender)
        await model.load()
        XCTAssertEqual(renders, 0, "no comment yet: nothing to place")
        for _ in 0..<5 { _ = model.answerBlocker }
        XCTAssertEqual(renders, 0, "answerBlocker must not render the snapshot")
        await model.mark("ag:1", .comment, body: "keep")
        XCTAssertEqual(renders, 1)
        await model.load()
        await model.load()
        await model.mark("da:1", .comment, body: "why?")
        for _ in 0..<5 { _ = model.answerBlocker }
        XCTAssertEqual(renders, 1, "the rendered snapshot is cached")
        XCTAssertEqual(asks.specReviewComments[askID]?.count, 2)
        XCTAssertEqual(model.answer(verdict: .changes).comments.count, 2)
        XCTAssertEqual(renders, 1)
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
        let stored = try await pool.read { d in
            try Row.fetchOne(d, sql: "SELECT status, answer FROM owner_asks WHERE id = ?", arguments: [self.askID])
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
        XCTAssertNil(asks.specReviewComments[askID], "a sent answer forgets them")
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

    private func storedAnswer() async throws -> String {
        let id = askID
        return try await pool.read { d in
            try String.fetchOne(d, sql: "SELECT answer FROM owner_asks WHERE id = ?", arguments: [id]) ?? ""
        }
    }
}
