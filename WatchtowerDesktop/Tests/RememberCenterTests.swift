import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// Remember in place: the center calls the CLI only for a remember message,
/// and shows what the CLI said.
@MainActor
final class RememberCenterTests: XCTestCase {
    private final class FakeCLI: RememberCLI, @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        var remember: Result<InstructionRememberResult, Error> = .success(.init(outcome: "added", lineID: 7))
        var forget: Result<Bool, Error> = .success(true)

        var recorded: [String] { lock.lock(); defer { lock.unlock() }; return calls }
        private func record(_ s: String) { lock.lock(); calls.append(s); lock.unlock() }

        func remember(text: String, conversationID: Int64, messageID: Int64) async throws -> InstructionRememberResult {
            record("remember \(conversationID) \(messageID) \(text)")
            return try remember.get()
        }

        func forget(lineID: Int64) async throws -> Bool {
            record("forget \(lineID)")
            return try forget.get()
        }
    }

    private func send(_ center: RememberCenter, _ text: String = "remember: answer short") async {
        center.ownerMessageSent(text: text, conversationID: 3, messageID: 11)
        await center.waitForIdle()
    }

    func testRememberMessageIsRemembered() async {
        let cli = FakeCLI()
        let center = RememberCenter(cli: cli)
        await send(center)
        XCTAssertEqual(center.mark(for: 11), .remembered(lineID: 7))
        XCTAssertEqual(center.revision, 1)
        XCTAssertEqual(cli.recorded, ["remember 3 11 remember: answer short"])
    }

    func testOrdinaryMessageNeverCallsTheCLI() async {
        let cli = FakeCLI()
        let center = RememberCenter(cli: cli)
        await send(center, "please remember to answer short")
        XCTAssertTrue(cli.recorded.isEmpty)
        XCTAssertNil(center.mark(for: 11))
        XCTAssertEqual(center.revision, 0)
    }

    func testAlreadyPresent() async {
        let cli = FakeCLI()
        cli.remember = .success(.init(outcome: "already_present", lineID: nil))
        let center = RememberCenter(cli: cli)
        await send(center)
        XCTAssertEqual(center.mark(for: 11), .alreadyPresent)
        XCTAssertEqual(center.revision, 0)
    }

    func testTooLongIsFull() async {
        let cli = FakeCLI()
        cli.remember = .failure(OwnerInstructionsError(message: "full", code: "too_long"))
        let center = RememberCenter(cli: cli)
        await send(center)
        XCTAssertEqual(center.mark(for: 11), .full)
    }

    func testNothingAfterThePrefixIsEmptyWithoutACall() async {
        let cli = FakeCLI()
        let center = RememberCenter(cli: cli)
        await send(center, "Remember:   ")
        XCTAssertEqual(center.mark(for: 11), .empty)
        XCTAssertTrue(cli.recorded.isEmpty)
    }

    func testOtherFailureShowsItsMessage() async {
        let cli = FakeCLI()
        cli.remember = .failure(OwnerInstructionsError(message: "db locked"))
        let center = RememberCenter(cli: cli)
        await send(center)
        XCTAssertEqual(center.mark(for: 11), .failed("db locked"))
    }

    func testUndoRemovesTheLineAndBumpsRevision() async {
        let cli = FakeCLI()
        let center = RememberCenter(cli: cli)
        await send(center)
        await center.undo(messageID: 11)
        XCTAssertEqual(center.mark(for: 11), .undone)
        XCTAssertEqual(center.revision, 2)
        XCTAssertEqual(cli.recorded.last, "forget 7")
    }

    func testUndoOfAGoneLineIsNotFound() async {
        let cli = FakeCLI()
        let center = RememberCenter(cli: cli)
        await send(center)
        cli.forget = .success(false)
        await center.undo(messageID: 11)
        XCTAssertEqual(center.mark(for: 11), .notFound)
    }

    func testUndoWithoutARememberedMarkDoesNothing() async {
        let cli = FakeCLI()
        let center = RememberCenter(cli: cli)
        await center.undo(messageID: 11)
        XCTAssertTrue(cli.recorded.isEmpty)
    }

    func testLoadMarksRebuildsFromTheLedger() throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO instruction_chat_lines (line, conversation_id, message_id, added_at)
                VALUES ('Answer short', 3, 11, '2026-10-24T08:00:00Z')
                """)
        }
        let center = RememberCenter(cli: FakeCLI(), dbPool: pool)
        center.loadMarks(messageIDs: [11, 12])
        guard case .remembered? = center.mark(for: 11) else { return XCTFail("no mark") }
        XCTAssertNil(center.mark(for: 12))
    }

    func testRefusalTextsCarryTheirCode() async {
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(
            code: 1, stderr: "chat instructions: adding this line would go over the 1000-character limit — shorten the text first"))
        do {
            _ = try await WorkbenchCLI(runner: runner).instructionsRemember(text: "remember: x", conversationID: 1, messageID: 2)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual((error as? OwnerInstructionsError)?.code, "too_long")
        }
        XCTAssertFalse(runner.invocations[0].contains { $0.contains("remember: x") })
    }

    func testRememberSendsTheMessageOnStdinOnly() async throws {
        let body = #"{"ok":true,"outcome":"added","line_id":5,"limit":1000,"global":{"session":"","procedure":""}}"#
        let runner = FakeCLIRunner(stdout: Data(body.utf8))
        let r = try await WorkbenchCLI(runner: runner).instructionsRemember(text: "remember: секрет", conversationID: 1, messageID: 2)
        XCTAssertEqual(r, InstructionRememberResult(outcome: "added", lineID: 5))
        let args = try XCTUnwrap(runner.invocations.first)
        XCTAssertEqual(args, ["instructions", "remember", "--conversation", "1", "--message", "2", "--stdin", "--json"])
        XCTAssertEqual(runner.stdinInputs, [Data("remember: секрет".utf8)])
    }
}
