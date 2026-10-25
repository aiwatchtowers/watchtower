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

    private func makeModel(sleep: @escaping (Duration) async throws -> Void = { _ in await Task.yield() }) async throws -> SpecReviewModel {
        let dbm = DatabaseManager(pool: pool)
        let asks = OwnerAsksViewModel(
            dbPool: pool, terminalCenter: nil, lineDelivery: SessionLineDelivery(terminalCenter: nil), defaults: defaults
        )
        await asks.load(projectID: projectID)
        let ask = try XCTUnwrap(asks.openAsks[projectID]?.first { $0.id == askID })
        return SpecReviewModel(ask: ask, db: dbm, cli: WorkbenchCLI(runner: runner), asks: asks, sleep: sleep)
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
        let refused = await model.send(note: "")
        guard case .invalid = refused else { return XCTFail("send without comments is refused: \(refused)") }

        await model.mark("ag:1", .comment, body: "name the period")
        XCTAssertTrue(model.canSend)
        let sent = await model.send(note: "")
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
        let sent = await model.approve(note: "ship it")
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
        let sent = await model.approve(note: "")
        guard case .delivered = sent else { return XCTFail("approved: \(sent)") }
        let answer = try await storedAnswer()
        XCTAssertTrue(answer.contains("\"approved\""))
    }

    private func storedAnswer() async throws -> String {
        let id = askID
        return try await pool.read { d in
            try String.fetchOne(d, sql: "SELECT answer FROM owner_asks WHERE id = ?", arguments: [id]) ?? ""
        }
    }
}
