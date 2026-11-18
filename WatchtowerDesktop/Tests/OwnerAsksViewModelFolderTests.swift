import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The agent's folder suggestion card (#2003, spec §6.7): Put on Bench adds
/// the folder through the CLI and answers the agent, Not Now quiets the
/// hook's root, Never writes a decline — Go does both writes (spec §7
/// writers), the Desktop only calls the verbs and answers the ask.
@MainActor
final class OwnerAsksViewModelFolderTests: XCTestCase {
    private var pool: DatabasePool!
    private var path = ""
    private var defaults: UserDefaults!
    private var bench: Int64 = 0
    private var home: Int64 = 0
    private var session: Int64 = 0

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "OwnerAsksFolderTests-\(UUID().uuidString)"))
        (bench, home, session) = try pool.write { db in
            let bench = try TestDatabase.insertWorkbench(db, name: "acme", folder: "/tmp/acme-app")
            let session = try TerminalSessionQueries.create(
                db, .init(projectID: bench, kind: .shell, title: "Export reports to PDF", folderPath: "/tmp/acme-app"))
            return (bench, try XCTUnwrap(WorkbenchFolderQueries.homeFolderID(db, workbenchID: bench)), session.id)
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeVM(_ runner: any CLIRunnerProtocol) -> WorkbenchesViewModel {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)
        vm.folderExists = { _ in true }
        vm.asks.hasHookState = { _ in true }
        vm.asks.refreshStates = { true }
        return vm
    }

    private func runner() -> BenchFoldersGitRunner {
        BenchFoldersGitRunner(folders: [.init(id: home, path: "/tmp/acme-app", branch: "main")], homeID: home)
    }

    private func folderAsk(
        _ vm: WorkbenchesViewModel, path: String = "/tmp/billing", otherBench: String = ""
    ) async throws -> OwnerAsk {
        let payload = #"{"path":"\#(path)","repo_root":"\#(path)","touches":3,"why":"the export lives there"\#(otherBench)}"#
        let id = try await pool.write { [bench, session] db in
            try TestDatabase.insertOwnerAsk(db, projectID: bench, sessionID: session, kind: "folder",
                                            title: "Put billing on the bench?", payload: payload)
        }
        await vm.asks.load(projectID: bench)
        return try XCTUnwrap(vm.asks.openAsks[bench]?.first { $0.id == id })
    }

    private func stored(_ id: Int64) async throws -> (status: String, note: String) {
        try await pool.read { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT status, answer FROM owner_asks WHERE id = ?", arguments: [id]))
            let answer: String = row["answer"]
            return (row["status"], answer.isEmpty ? "" : try OwnerAskAnswer.decode(answer).note)
        }
    }

    private static func ack(ok: Bool, code: String = "", error: String = "") -> Result<Data, Error> {
        .success(Data(#"{"ok":\#(ok),"error_code":"\#(code)","error":"\#(error)"}"#.utf8))
    }

    // MARK: - Put on Bench

    func testPutOnBenchAnswersTheAgent() async throws {
        let runner = runner()
        runner.answer("folder add", .success(Data(#"""
            {"ok":true,"folder":{"id":42,"path":"/tmp/billing","name":"billing","position":1,"home":false,"installed":true,"removed":false},
             "install":{"ok":true,"error":""}}
            """#.utf8)))
        let vm = makeVM(runner)
        let ask = try await folderAsk(vm)

        let step = await vm.asks.putOnBench(ask, home: "/Users/owner")

        XCTAssertEqual(step, .done)
        XCTAssertEqual(runner.invocations.first { $0.starts(with: ["workbench", "folder", "add"]) },
                       ["workbench", "folder", "add", "--workbench", String(bench), "--folder", "/tmp/billing",
                        "--added-by", "agent_suggestion", "--json"])
        let row = try await stored(ask.id)
        XCTAssertEqual(row.status, "answered")
        XCTAssertEqual(row.note, "billing is on the bench now. Start a sub-session there with start_session(\"billing\", …).")
        XCTAssertNil(vm.asks.folderPhases[ask.id])
        XCTAssertEqual(vm.highlightedFolderRoot[bench], 42, "FILES points at the folder it put on the bench")
    }

    /// Open Folder…'s TCC confirmation guards the card too (§6.7).
    func testPutOnBenchInASensitiveLocationAsksFirst() async throws {
        let runner = runner()
        let vm = makeVM(runner)
        let ask = try await folderAsk(vm, path: "/Users/owner/Documents/billing")

        let step = await vm.asks.putOnBench(ask, home: "/Users/owner")

        let location = try XCTUnwrap(
            WorkbenchFolderPolicy.tccSensitiveLocation(path: "/Users/owner/Documents/billing", home: "/Users/owner"))
        XCTAssertEqual(step, .confirmLocation(location), "Open Folder…'s question, unchanged")
        XCTAssertFalse(runner.invocations.contains { $0.starts(with: ["workbench", "folder", "add"]) }, "nothing added before the owner confirms")
        let row = try await stored(ask.id)
        XCTAssertEqual(row.status, "open")
    }

    func testFailedAddShowsTheReasonAndAnswers() async throws {
        let runner = runner()
        runner.answer("folder add", .success(Data(
            #"{"ok":false,"error_code":"not_found","error":"not_found: the folder was moved or deleted."}"#.utf8)))
        let vm = makeVM(runner)
        let ask = try await folderAsk(vm)

        await vm.asks.putSuggestedFolderOnBench(ask)

        let line = "Couldn’t put billing on the bench: the folder was moved or deleted."
        XCTAssertEqual(vm.asks.folderPhases[ask.id], .failed(line), "the card shows the reason")
        let row = try await stored(ask.id)
        XCTAssertEqual(row.status, "answered")
        XCTAssertEqual(row.note, line, "and the agent gets it")
        XCTAssertEqual(vm.asks.heldFolderCards(projectID: bench).map(\.id), [ask.id], "the card stays until OK")

        vm.asks.folderCardDone(ask.id)
        XCTAssertTrue(vm.asks.heldFolderCards(projectID: bench).isEmpty)
        XCTAssertNil(vm.asks.folderPhases[ask.id])
    }

    /// A suggestion filed for another bench's folder is the merge variant
    /// from the start (§6.13).
    func testAnotherBenchsFolderIsTheMergeVariant() async throws {
        let vm = makeVM(runner())
        let ask = try await folderAsk(vm, otherBench: #","other_bench":{"id":9,"name":"tools"}"#)
        let suggestion = try XCTUnwrap(ask.folderSuggestion)
        let card = FolderSuggestionPresentation.card(suggestion, sessionTitle: nil, phase: .ready)
        XCTAssertEqual(card.otherBench, "tools")
        XCTAssertEqual(card.title, "Put billing on the bench?")
        XCTAssertEqual(card.subtitle, "billing is on the “tools” bench")
    }

    /// F14, §7 "suggestion" row, Swift half: Put on Bench on a folder that
    /// became another bench's since the card was filed switches the card to
    /// the merge variant; the ask stays open (the agent hears how it ends).
    func testFolderBecameAnotherBenchsSwitchesToMerge() async throws {
        let runner = runner()
        runner.answer("folder add", .success(Data(#"""
            {"ok":false,"error_code":"other_bench","error":"other_bench: billing is on the “tools” bench.",
             "other_bench":{"id":9,"name":"tools"}}
            """#.utf8)))
        let vm = makeVM(runner)
        let ask = try await folderAsk(vm)
        let suggestion = try XCTUnwrap(ask.folderSuggestion)

        await vm.asks.putSuggestedFolderOnBench(ask)

        XCTAssertNil(vm.asks.folderPhases[ask.id], "ready again, as the merge variant")
        let card = FolderSuggestionPresentation.card(
            suggestion, sessionTitle: nil, phase: .ready, otherBench: vm.asks.folderMergeBench[ask.id])
        XCTAssertEqual(card.title, "Put billing on the bench?")
        XCTAssertEqual(card.subtitle, "billing is on the “tools” bench")
        XCTAssertEqual(card.otherBench, "tools")
        let row = try await stored(ask.id)
        XCTAssertEqual(row.status, "open")
    }

    /// Merge Benches… opens the confirmation; Merge runs `workbench merge`,
    /// and the agent hears Put on Bench's answer with the moved folder's name.
    func testMergeBenchesFromACardAnswersTheAgent() async throws {
        let tools = try await pool.write { db in
            let tools = try TestDatabase.insertWorkbench(db, name: "tools", folder: "/tmp/billing")
            try db.execute(sql: """
                INSERT INTO targets (text, period_start, period_end, status, project_id)
                VALUES ('ship it', '2026-11-01', '2026-11-30', 'todo', ?)
                """, arguments: [tools])
            return tools
        }
        let runner = runner()
        runner.answer("merge --from", .success(Data(#"""
            {"ok":true,"error_code":"","error":"","targets":1,
             "moved_folders":[{"id":77,"path":"/tmp/billing","name":"billing","position":1,"home":false,"installed":true,"removed":false}],
             "reinstall":{"ok":true,"failed":[]}}
            """#.utf8)))
        let vm = makeVM(runner)
        let ask = try await folderAsk(vm, otherBench: #","other_bench":{"id":\#(tools),"name":"tools"}"#)

        await vm.asks.mergeBenches(ask)
        let offer = try XCTUnwrap(vm.mergeOffer)
        XCTAssertEqual(offer.title, "Merge “tools” into “acme”?")
        XCTAssertEqual(offer.text, "tools's board (1 targets), asks and sessions move to acme, and tools leaves the workbench list. "
            + "Folders that move: billing.")

        await vm.confirmMerge()

        XCTAssertEqual(runner.invocations.first { $0.starts(with: ["workbench", "merge"]) },
                       ["workbench", "merge", "--from", String(tools), "--into", String(bench), "--json"])
        let row = try await stored(ask.id)
        XCTAssertEqual(row.status, "answered")
        XCTAssertEqual(row.note, "billing is on the bench now. Start a sub-session there with start_session(\"billing\", …).")
    }

    // MARK: - Not Now / Never

    func testNotNowQuietsTheRoot() async throws {
        let runner = runner()
        runner.answer("folder quiet", Self.ack(ok: true))
        let vm = makeVM(runner)
        let ask = try await folderAsk(vm)

        await vm.asks.notNow(ask)

        XCTAssertEqual(runner.invocations.first { $0.starts(with: ["workbench", "folder", "quiet"]) },
                       ["workbench", "folder", "quiet", "--session", String(session), "--root", "/tmp/billing", "--json"])
        let row = try await stored(ask.id)
        XCTAssertEqual(row.status, "answered")
        XCTAssertEqual(row.note, "The owner said not now.")
    }

    func testNeverWritesADecline() async throws {
        let runner = runner()
        runner.answer("folder decline", Self.ack(ok: true))
        let vm = makeVM(runner)
        let ask = try await folderAsk(vm)

        await vm.asks.never(ask)

        XCTAssertEqual(runner.invocations.first { $0.starts(with: ["workbench", "folder", "decline"]) },
                       ["workbench", "folder", "decline", "--workbench", String(bench), "--folder", "/tmp/billing", "--json"])
        let declines = try await pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM workbench_folder_declines") }
        XCTAssertEqual(declines, 0, "Go writes the decline; the Desktop never does (the fake CLI wrote nothing)")
        let row = try await stored(ask.id)
        XCTAssertEqual(row.status, "answered")
        XCTAssertEqual(row.note, "The owner does not want billing on this bench.")
    }

    func testNeverThatWasRefusedAnswersNothing() async throws {
        let runner = runner()
        runner.answer("folder decline", Self.ack(ok: false, code: "bad_args", error: "bad_args: --folder must be absolute"))
        let vm = makeVM(runner)
        let ask = try await folderAsk(vm)

        await vm.asks.never(ask)

        XCTAssertEqual(vm.asks.answerErrors[ask.id], "--folder must be absolute")
        let row = try await stored(ask.id)
        XCTAssertEqual(row.status, "open", "no decline, no answer: the card stays")
    }

    // MARK: - One action per card

    /// Never is still declining when Put on Bench is clicked: the card was
    /// claimed before Never's first await, so nothing is added and only
    /// the decline answers.
    func testNeverThenPutOnBenchRunsOnlyNever() async throws {
        let inner = runner()
        inner.answer("folder decline", Self.ack(ok: true))
        let gated = GatedRunner(inner: inner, gated: ["workbench", "folder", "decline"])
        let vm = makeVM(gated)
        let ask = try await folderAsk(vm)

        let never = Task { await vm.asks.never(ask) }
        await inner.until { $0.contains { $0.starts(with: ["workbench", "folder", "decline"]) } }
        XCTAssertTrue(vm.asks.isFolderCardWorking(ask.id), "the buttons wait")
        await vm.asks.putSuggestedFolderOnBench(ask)
        await vm.asks.notNow(ask)
        gated.release()
        await never.value

        XCTAssertFalse(inner.invocations.contains { $0.starts(with: ["workbench", "folder", "add"]) }, "never added and declined")
        XCTAssertFalse(inner.invocations.contains { $0.starts(with: ["workbench", "folder", "quiet"]) })
        let row = try await stored(ask.id)
        XCTAssertEqual(row.note, "The owner does not want billing on this bench.")
        XCTAssertFalse(vm.asks.isFolderCardWorking(ask.id))
    }

    /// A failed add whose answer could not be saved keeps the card open with
    /// an answer-only Retry; OK shows only once the answer is saved.
    func testUnsavedFailureAnswerOffersRetry() async throws {
        let runner = runner()
        runner.answer("folder add", .success(Data(
            #"{"ok":false,"error_code":"not_found","error":"not_found: the folder was moved or deleted."}"#.utf8)))
        let vm = makeVM(runner)
        let ask = try await folderAsk(vm)
        try await pool.write { db in
            try db.execute(sql: """
                CREATE TEMP TRIGGER refuse_answer BEFORE UPDATE ON owner_asks
                BEGIN SELECT RAISE(ABORT, 'disk full'); END
                """)
        }

        await vm.asks.putSuggestedFolderOnBench(ask)

        let line = "Couldn’t put billing on the bench: the folder was moved or deleted."
        XCTAssertEqual(vm.asks.folderPhases[ask.id], .unsent(line))
        XCTAssertEqual(FolderSuggestionPresentation.card(try XCTUnwrap(ask.folderSuggestion), sessionTitle: nil,
                                                         phase: .unsent(line)).subtitle, line)
        XCTAssertEqual(FolderSuggestionPresentation.retry, "Retry")
        XCTAssertTrue(vm.asks.heldFolderCards(projectID: bench).isEmpty, "no OK card while the agent has nothing")
        let unsaved = try await stored(ask.id)
        XCTAssertEqual(unsaved.status, "open")
        let adds = runner.invocations.filter { $0.starts(with: ["workbench", "folder", "add"]) }.count

        try await pool.write { try $0.execute(sql: "DROP TRIGGER refuse_answer") }
        await vm.asks.retryFolderAnswer(ask)

        XCTAssertEqual(runner.invocations.filter { $0.starts(with: ["workbench", "folder", "add"]) }.count, adds,
                       "Retry sends the answer only")
        XCTAssertEqual(vm.asks.folderPhases[ask.id], .failed(line))
        let saved = try await stored(ask.id)
        XCTAssertEqual(saved.status, "answered")
        XCTAssertEqual(saved.note, line)
    }

    /// A folder card is a keyboard stop like every row (A / ⌃⌘A / J/K /
    /// Return): it moves and opens; no digit answers it.
    func testAFolderCardIsAKeyboardStop() async throws {
        let vm = makeVM(runner())
        let ask = try await folderAsk(vm)
        final class Box { var opened = 0; var moves: [Bool] = [] }
        let box = Box()
        let keys = OwnerAskCardKeys(vm: vm, ask: ask) {
            true
        } open: {
            box.opened += 1
        } move: { forward in
            box.moves.append(forward)
            return true
        } textHasKeyboard: {
            false
        }

        XCTAssertFalse(keys.press(OwnerAskKeyMap.Press(characters: "1", keyCode: nil, shift: false, otherModifiers: false,
                                                       isRepeat: false)), "no Quick row: a digit answers nothing")
        XCTAssertTrue(keys.press(OwnerAskKeyMap.Press(characters: "j", keyCode: nil, shift: false, otherModifiers: false,
                                                      isRepeat: false)))
        XCTAssertTrue(keys.press(OwnerAskKeyMap.Press(key: .returnKey)))
        XCTAssertEqual(box.moves, [true])
        XCTAssertEqual(box.opened, 1)
        let row = try await stored(ask.id)
        XCTAssertEqual(row.status, "open")
    }
}

/// `BenchFoldersGitRunner` whose `gated` verb waits for `release()` after
/// it was recorded: an action held mid-call, no clock.
private final class GatedRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let inner: BenchFoldersGitRunner
    private let gated: [String]
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    private var released = false

    init(inner: BenchFoldersGitRunner, gated: [String]) {
        self.inner = inner
        self.gated = gated
    }

    func run(args: [String]) async throws -> Data {
        let data = try await inner.run(args: args)
        if args.starts(with: gated) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let go = lock.withLock { () -> Bool in
                    if released { return true }
                    waiter = continuation
                    return false
                }
                if go { continuation.resume() }
            }
        }
        return data
    }

    func release() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume()
    }
}
