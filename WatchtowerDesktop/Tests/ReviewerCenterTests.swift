import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// A provider stand-in that reads files the way the real ones do under
/// `--read-folder-round N`: it is handed the round, finds its folder as the
/// CLI does (`roundFolders`, the round's recorded folder), picks the `.go`
/// paths the turn's prompt names, reads each one from that folder and cites it.
private final class FolderReadingAIService: AIServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let roundFolders: [Int64: String]
    private var _rounds: [Int64?] = []
    private var _folders: [String?] = []
    private var _prompts: [String] = []
    init(roundFolders: [Int64: String]) { self.roundFolders = roundFolders }
    var rounds: [Int64?] { lock.withLock { _rounds } }
    var folders: [String?] { lock.withLock { _folders } }
    var prompts: [String] { lock.withLock { _prompts } }

    func stream(
        prompt: String,
        systemPrompt: String?,
        sessionID: String?,
        dbPath: String?,
        model: String?,
        provider: String?,
        toolMode: ChatToolMode?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        stream(prompt: prompt, systemPrompt: systemPrompt, sessionID: sessionID, dbPath: dbPath, model: model,
               provider: provider, toolMode: toolMode, readFolder: nil, ownerInstructions: false,
               purpose: nil, readFolderAskID: nil, readFolderRoundID: nil)
    }

    // swiftlint:disable:next function_parameter_count
    func stream(
        prompt: String,
        systemPrompt: String?,
        sessionID: String?,
        dbPath: String?,
        model: String?,
        provider: String?,
        toolMode: ChatToolMode?,
        readFolder: String?,
        ownerInstructions: Bool,
        purpose: String?,
        readFolderAskID: Int64?,
        readFolderRoundID: Int64?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let readFolder = readFolder ?? readFolderRoundID.flatMap { roundFolders[$0] }
        lock.withLock {
            _rounds.append(readFolderRoundID)
            _folders.append(readFolder)
            _prompts.append(prompt)
        }
        let paths = Self.goPaths(in: prompt)
        return AsyncThrowingStream { continuation in
            var lines: [String] = []
            if let readFolder {
                for path in paths {
                    let url = URL(fileURLWithPath: readFolder).appendingPathComponent(path)
                    guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                    lines.append("`\(path):1` — \(text.split(separator: "\n").first ?? "")")
                }
            }
            let reply = lines.isEmpty ? "I could not read the code." : lines.joined(separator: "\n")
            continuation.yield(.text(reply))
            continuation.yield(.turnComplete(reply))
            continuation.yield(.done)
            continuation.finish()
        }
    }

    private static func goPaths(in prompt: String) -> [String] {
        var seen: [String] = []
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",()`"))
        for token in prompt.components(separatedBy: separators) where token.hasSuffix(".go") && !seen.contains(token) {
            seen.append(token)
        }
        return seen
    }
}

@MainActor
final class ReviewerCenterTests: XCTestCase {
    private var paths: [String] = []
    private var folders: [URL] = []

    override func tearDown() {
        paths.forEach { TestDatabase.cleanup(path: $0) }
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        paths = []
        folders = []
        super.tearDown()
    }

    private func harness() throws -> ReviewModelHarness {
        let h = try ReviewModelHarness()
        paths.append(h.path)
        return h
    }

    private func roundJSON(id: Int64 = 7, folder: String, status: String = "open") -> String {
        """
        {"ok":true,"round":{"id":\(id),"status":"\(status)","mode":"quick","folder_root":"\(folder)","base_sha":"b",
         "base_label":"main","tree_sha":"t\(id)","prev_round_id":0,"prev_tree_sha":"","prev_tree_lost":false}}
        """
    }

    private func counts(_ db: DatabasePool) async throws -> [Int] {
        try await db.read { db in
            try ["review_comments", "review_rounds", "review_checks", "review_viewed", "agent_actions"].map {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)") ?? -1
            }
        }
    }

    private static func center(_ h: ReviewModelHarness, ai: any AIServiceProtocol) -> ReviewerCenter {
        let chats = EmbeddedChatCenter { spec, gate in makeSurfaceEngine(spec, dbPool: h.db, ai: ai, gate: gate) }
        return ReviewerCenter(embeddedChats: chats, dbPool: h.db) { .claudeTools }
    }

    private func engine(
        _ h: ReviewModelHarness, context: ReviewerSurface.Context, ai: any AIServiceProtocol
    ) async throws -> (ReviewerCenter, EmbeddedChatEngine) {
        let center = Self.center(h, ai: ai)
        let id = ReviewerCenter.ThreadID(projectID: context.projectID, branch: context.branch)
        await center.open(id)
        guard case let .ready(conversationID) = center.threads[id] else {
            XCTFail("the thread did not open: \(String(describing: center.threads[id]))")
            throw CancellationError()
        }
        let model = h.model
        return (center, center.engine(context: context, conversationID: conversationID) { model.reviewerMapInput })
    }

    // MARK: - End to end

    /// A session in its own registered worktree; a question that needs a
    /// file of each of two chapters: the turn runs with `--read-folder-round` =
    /// the round taken in that worktree, the answer cites both files, and
    /// nothing is written to the round.
    func testReviewerReadsTwoChaptersFromTheSessionsWorktree() async throws {
        let h = try harness()
        let worktree = FileManager.default.temporaryDirectory.appendingPathComponent("reviewer-e2e-\(UUID().uuidString)")
        folders.append(worktree)
        let files = ["internal/providers/capabilities.go": "package providers // capability table",
                     "internal/auth/tokens.go": "package auth // token store per provider"]
        for (path, text) in files {
            let url = worktree.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let sessionID = h.sessionID
        try await h.db.write { db in
            try db.execute(sql: """
                INSERT INTO terminal_session_worktrees (session_id, root, branch, first_at)
                VALUES (?, ?, 'feature/registry', '2026-11-08T10:00:00Z')
                """, arguments: [sessionID, worktree.path])
        }
        h.cli.script(["start": roundJSON(folder: worktree.path), "context": #"{"ok":true,"items":[]}"#,
                      "diff": diffJSON(Array(files.keys).sorted())])
        await h.model.open()
        await h.model.mapTask?.value
        XCTAssertEqual(Set(h.model.chapters.map(\.key)).count, 2, "two chapters, one file each")

        let place = SessionPlace.worktree(name: "registry", root: worktree,
                                          status: WorkbenchGitStatus(branch: "feature/registry"))
        let context = try XCTUnwrap(ReviewerSurface.context(projectID: h.projectID, sessionID: sessionID,
                                                            round: h.model.round, place: place, mainStatus: nil))
        XCTAssertEqual(context.branch, "feature/registry")
        XCTAssertEqual(context.roundID, 7)
        XCTAssertTrue(context.inWorktree)

        let before = try await counts(h.db)
        let ai = FolderReadingAIService(roundFolders: [7: worktree.path])
        let (_, engine) = try await engine(h, context: context, ai: ai)
        engine.send("What would adding another provider take?")
        let done = await eventually { !engine.isBusy && engine.messages.count == 2 }
        XCTAssertTrue(done)

        XCTAssertEqual(ai.rounds, [7], "the turn names the round, not a folder")
        XCTAssertEqual(ai.folders, [worktree.path], "the turn reads the session's worktree")
        let answer = try XCTUnwrap(engine.messages.last?.message)
        XCTAssertEqual(answer.status, "complete")
        XCTAssertTrue(answer.text.contains("`internal/providers/capabilities.go:1` — package providers // capability table"))
        XCTAssertTrue(answer.text.contains("`internal/auth/tokens.go:1` — package auth // token store per provider"))
        let after = try await counts(h.db)
        XCTAssertEqual(after, before, "a reviewer turn writes nothing to the round")
    }

    // MARK: - Send to author

    func testSendWritesExactlyOneDesignCommentAndNothingElse() async throws {
        let h = try harness()
        h.cli.script(["start": roundJSON(folder: "/tmp/acme"), "context": #"{"ok":true,"items":[]}"#,
                      "diff": diffJSON(["a.go"])])
        await h.model.open()
        let context = try XCTUnwrap(ReviewerSurface.context(
            projectID: h.projectID, sessionID: h.sessionID, round: h.model.round, place: .main,
            mainStatus: WorkbenchGitStatus(branch: "feature/a")))
        let ai = ScriptedAIService()
        let (center, engine) = try await engine(h, context: context, ai: ai)
        engine.send("What breaks?")
        let started = await eventually { ai.calls.count == 1 }
        XCTAssertTrue(started)
        ai.emit(.text("The fallback chain."), .turnComplete("The fallback chain."), .done)
        ai.finish()
        let finished = await eventually { !engine.isBusy }
        XCTAssertTrue(finished)
        let answer = try XCTUnwrap(engine.messages.last)
        XCTAssertTrue(ReviewerAnswerActions.offers(answer, isLive: false))

        let before = try await counts(h.db)
        let conversationRows = try await h.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chat_messages") }
        await center.send(messageID: answer.id, text: answer.message.text, to: h.model)
        await center.send(messageID: answer.id, text: answer.message.text, to: h.model)

        let comments = try await h.comments()
        XCTAssertEqual(comments.count, 1, "one design comment, even when pressed twice")
        XCTAssertNil(comments.first?.path, "a design comment has no file")
        XCTAssertEqual(comments.first?.body, "The fallback chain.")
        XCTAssertEqual(comments.first?.status, .draft)
        var expected = before
        expected[0] += 1
        let after = try await counts(h.db)
        XCTAssertEqual(after, expected, "nothing but the comment is written")
        let rowsAfter = try await h.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chat_messages") }
        XCTAssertEqual(rowsAfter, conversationRows)
        XCTAssertTrue(center.wasSent(messageID: answer.id, roundID: 7))
        XCTAssertEqual(ReviewerCenter.sentLine(roundID: 7), "Sent to the author as a design comment in round 7")
        XCTAssertTrue(h.sink.lines.isEmpty, "nothing reaches the author's session")
    }

    func testSendIsRefusedWithoutAnOpenRound() async throws {
        let h = try harness()
        h.cli.script(["start": roundJSON(folder: "/tmp/acme", status: "sent"), "context": #"{"ok":true,"items":[]}"#,
                      "diff": diffJSON(["a.go"])])
        await h.model.open()
        XCTAssertFalse(h.model.canSendToAuthor)
        let center = Self.center(h, ai: ScriptedAIService())
        await center.send(messageID: 1, text: "An answer", to: h.model)
        XCTAssertEqual(center.sendErrors[1], "Start a round to send")
        XCTAssertTrue(center.sent.isEmpty)
        let comments = try await h.comments()
        XCTAssertTrue(comments.isEmpty)
    }

    /// A round sent by another writer after the pane loaded it takes no
    /// comment: the send fails, says so, and nothing is marked as sent.
    func testSendIntoARoundSentMeanwhileWritesNothing() async throws {
        let h = try harness()
        h.cli.script(["start": roundJSON(folder: "/tmp/acme"), "context": #"{"ok":true,"items":[]}"#,
                      "diff": diffJSON(["a.go"])])
        await h.model.open()
        XCTAssertTrue(h.model.canSendToAuthor)
        try await h.db.write { try $0.execute(sql: "UPDATE review_rounds SET status = 'sent' WHERE id = 7") }
        let center = Self.center(h, ai: ScriptedAIService())
        await center.send(messageID: 1, text: "An answer", to: h.model)
        XCTAssertEqual(center.sendErrors[1], "This round was already sent, so it cannot change.")
        XCTAssertTrue(center.sent.isEmpty)
        XCTAssertFalse(h.model.canSendToAuthor, "the pane learns the round is closed")
        let comments = try await h.comments()
        XCTAssertTrue(comments.isEmpty)
    }

    /// A sent answer is marked for the round it went to only: another
    /// session's round of the branch can still take it.
    func testSentIsKeptPerRound() async throws {
        let h = try harness()
        h.cli.script(["start": roundJSON(folder: "/tmp/acme"), "context": #"{"ok":true,"items":[]}"#,
                      "diff": diffJSON(["a.go"])])
        await h.model.open()
        let center = Self.center(h, ai: ScriptedAIService())
        await center.send(messageID: 1, text: "An answer", to: h.model)
        XCTAssertTrue(center.wasSent(messageID: 1, roundID: 7))
        XCTAssertFalse(center.wasSent(messageID: 1, roundID: 8))
        XCTAssertFalse(center.wasSent(messageID: 1, roundID: nil))
    }

    // MARK: - Failed turn

    /// A failed turn keeps its error on the reply with Retry, as every
    /// embedded chat does, and offers no Send to author.
    func testAFailedTurnOffersRetryNotSend() async throws {
        let h = try harness()
        h.cli.script(["start": roundJSON(folder: "/tmp/acme"), "context": #"{"ok":true,"items":[]}"#,
                      "diff": diffJSON(["a.go"])])
        await h.model.open()
        let context = try XCTUnwrap(ReviewerSurface.context(
            projectID: h.projectID, sessionID: h.sessionID, round: h.model.round, place: .main,
            mainStatus: WorkbenchGitStatus(branch: "feature/a")))
        let ai = ScriptedAIService()
        let (_, engine) = try await engine(h, context: context, ai: ai)
        engine.send("What breaks if the table has no row?")
        let started = await eventually { ai.calls.count == 1 }
        XCTAssertTrue(started)
        ai.emit(.error("The reviewer did not answer in time"), .done)
        ai.finish()
        let finished = await eventually { !engine.isBusy }
        XCTAssertTrue(finished)
        let reply = try XCTUnwrap(engine.messages.last)
        XCTAssertEqual(reply.message.status, "error")
        XCTAssertTrue(engine.canRetry)
        XCTAssertFalse(ReviewerAnswerActions.offers(reply, isLive: false))
        XCTAssertNil(ai.calls.first?.readFolder, "never --read-folder (owner, ask #611)")
        XCTAssertEqual(ai.calls.first?.readFolderRoundID, 7, "--read-folder-round = the open round")
        XCTAssertNil(ai.calls.first?.toolMode, "draft-only (AGENT-04)")
    }

    // MARK: - Context

    func testContextNeedsARoundAndAKnownBranch() async throws {
        let h = try harness()
        XCTAssertNil(ReviewerSurface.context(projectID: 1, sessionID: 2, round: nil, place: .main,
                                             mainStatus: WorkbenchGitStatus(branch: "main")))
        h.cli.script(["start": roundJSON(folder: "/tmp/acme"), "context": #"{"ok":true,"items":[]}"#,
                      "diff": diffJSON(["a.go"])])
        await h.model.open()
        XCTAssertNil(ReviewerSurface.context(projectID: 1, sessionID: 2, round: h.model.round, place: .main, mainStatus: nil))
        let detached = try XCTUnwrap(ReviewerSurface.context(
            projectID: 1, sessionID: 2, round: h.model.round, place: .main,
            mainStatus: WorkbenchGitStatus(detached: true, head: "abc1234")))
        XCTAssertEqual(detached.branch, "session:2")
        XCTAssertEqual(detached.branchLabel, "")
        XCTAssertFalse(detached.inWorktree)
    }

    /// Two sessions on one branch open the same thread.
    /// A deleted workbench's reviewer engines stop and its threads are
    /// forgotten; another workbench's stay.
    func testWorkbenchRemovedDropsItsEnginesAndThreads() async throws {
        let h = try harness()
        let context = ReviewerSurface.Context(projectID: h.projectID, branch: "feature/a", branchLabel: "feature/a",
                                              roundID: 7, inWorktree: false, tipTree: nil)
        let (center, _) = try await engine(h, context: context, ai: ScriptedAIService())
        let other = ReviewerCenter.ThreadID(projectID: h.projectID + 1, branch: "feature/a")
        await center.open(other)
        let mine = ReviewerCenter.ThreadID(projectID: h.projectID, branch: "feature/a")
        guard case let .ready(conversationID) = center.threads[mine] else { return XCTFail("no thread") }
        let key = EmbeddedChatKey(contextType: ReviewerSurface.contextType,
                                  contextID: ReviewerSurface.contextID(projectID: h.projectID, branch: "feature/a"),
                                  conversationID: conversationID)
        XCTAssertNotNil(center.embeddedChats.loaded(key))
        center.workbenchRemoved(h.projectID)
        XCTAssertNil(center.embeddedChats.loaded(key), "the engine stopped")
        XCTAssertNil(center.threads[mine])
        XCTAssertNotNil(center.threads[other], "another workbench's thread stays")
    }

    func testTwoSessionsOnOneBranchShareTheThread() async throws {
        let h = try harness()
        let center = Self.center(h, ai: ScriptedAIService())
        let id = ReviewerCenter.ThreadID(projectID: h.projectID, branch: "feature/a")
        await center.open(id)
        let other = ReviewerCenter(embeddedChats: center.embeddedChats, dbPool: h.db) { .claudeTools }
        await other.open(id)
        XCTAssertEqual(center.threads[id], other.threads[id])
        let rows = try await h.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM review_reviewer_threads") }
        XCTAssertEqual(rows, 1)
    }
}
