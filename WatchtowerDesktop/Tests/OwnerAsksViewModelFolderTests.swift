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

    private func makeVM(_ runner: BenchFoldersGitRunner) -> WorkbenchesViewModel {
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

    /// §7 "suggestion" row, Swift half (the merge variant is §6.13's, Task
    /// 19): the card flags another bench's folder, and an add refused with
    /// `other_bench` shows and answers the plain reason.
    func testAnotherBenchsFolderIsFlaggedAndSaysWhy() async throws {
        let runner = runner()
        runner.answer("folder add", .success(Data(#"""
            {"ok":false,"error_code":"other_bench","error":"other_bench: billing is on the “tools” bench.",
             "other_bench":{"id":9,"name":"tools"}}
            """#.utf8)))
        let vm = makeVM(runner)
        let ask = try await folderAsk(vm, otherBench: #","other_bench":{"id":9,"name":"tools"}"#)
        let suggestion = try XCTUnwrap(ask.folderSuggestion)
        XCTAssertEqual(FolderSuggestionPresentation.card(suggestion, sessionTitle: nil, phase: .ready).otherBench, "tools")

        await vm.asks.putSuggestedFolderOnBench(ask)

        let line = "Couldn’t put billing on the bench: billing is on the “tools” bench."
        XCTAssertEqual(vm.asks.folderPhases[ask.id], .failed(line))
        let row = try await stored(ask.id)
        XCTAssertEqual(row.note, line)
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
}
