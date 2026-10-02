import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class WorkbenchesViewModelTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchesViewModelTests-\(UUID().uuidString)"))
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func makeVM(_ runner: any CLIRunnerProtocol = FakeCLIRunner()) -> WorkbenchesViewModel {
        WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)
    }

    private func createdJSON(_ id: Int64) -> Data {
        Data(#"{"id":\#(id),"folder":"/tmp/acme","name":"acme"}"#.utf8)
    }

    func testReloadBuildsSummariesAndTheBadgeCountsUnreadAndUnviewedDocuments() async throws {
        let ids = try await pool.write { d -> (Int64, Int64) in
            let p = try TestDatabase.insertWorkbench(d)
            let doc = try TestDatabase.insertWorkbenchDocument(d, projectID: p)
            let t = try TestDatabase.insertWorkbenchTarget(d, projectID: p)
            _ = try TestDatabase.insertWorkbenchComment(d, projectID: p, targetID: t)
            return (p, doc)
        }
        let vm = makeVM()
        await vm.reload()
        XCTAssertEqual(vm.summaries.map(\.id), [ids.0])
        XCTAssertEqual(vm.badgeCount, 2, "one unread agent comment + one never-viewed document")
        XCTAssertEqual(vm.revisedDocumentCount(for: vm.summaries[0]), 1)
    }

    func testViewedDocumentStopsCountingUntilItIsRevisedAgain() async throws {
        let (p, doc) = try await pool.write { d -> (Int64, Int64) in
            let p = try TestDatabase.insertWorkbench(d)
            return (p, try TestDatabase.insertWorkbenchDocument(d, projectID: p, updatedAt: "2026-09-29T10:00:00Z"))
        }
        let vm = makeVM()
        await vm.reload()
        let fetched = try await pool.read { try WorkbenchQueries.document($0, id: doc) }
        let document = try XCTUnwrap(fetched)
        vm.markDocumentViewed(document)
        XCTAssertEqual(vm.badgeCount, 0)
        XCTAssertFalse(vm.isRevised(document))

        // A fresh VM reads the persisted stamp: the mark survives relaunch.
        let relaunched = makeVM()
        await relaunched.reload()
        XCTAssertEqual(relaunched.badgeCount, 0)

        try await pool.write { d in
            try d.execute(sql: "UPDATE project_documents SET updated_at = '2026-09-29T11:00:00Z' WHERE id = ?", arguments: [doc])
        }
        await relaunched.reload()
        XCTAssertEqual(relaunched.badgeCount, 1, "re-attached (revised) after the owner last looked")
        XCTAssertEqual(relaunched.summaries.first?.id, p)
    }

    func testImportedDocumentNeverLightsTheBadge() async throws {
        let doc = try await pool.write { d -> Int64 in
            let p = try TestDatabase.insertWorkbench(d)
            return try TestDatabase.insertWorkbenchDocument(d, projectID: p, origin: "import")
        }
        let vm = makeVM()
        await vm.reload()
        XCTAssertEqual(vm.badgeCount, 0, "a never-opened imported document is not revised")
        let fetched = try await pool.read { try WorkbenchQueries.document($0, id: doc) }
        XCTAssertFalse(vm.isRevised(try XCTUnwrap(fetched)))
    }

    /// #80: "Add document…" goes through `project attach-doc` (the CLI writes
    /// the row) and opens the attached document; the owner's own write is
    /// reported so it is never announced back.
    func testAttachDocumentRunsTheCLIAndOpensTheDocument() async throws {
        let (p, doc) = try await pool.write { d -> (Int64, Int64) in
            let p = try TestDatabase.insertWorkbench(d)
            // The row `project attach-doc` wrote.
            return (p, try TestDatabase.insertWorkbenchDocument(d, projectID: p, relPath: "notes/x.md", origin: "owner"))
        }
        let runner = FakeCLIRunner(stdout: Data(#"{"document_id":\#(doc),"rel_path":"notes/x.md","created":true}"#.utf8))
        let vm = makeVM(runner)
        var ownerWrites: [WorkbenchSubject] = []
        vm.onOwnerWrite = { _, subject in ownerWrites.append(subject) }
        await vm.reload()
        vm.selectedWorkbenchID = p

        let ok = await vm.attachDocument(fileURL: URL(fileURLWithPath: "/tmp/acme/notes/x.md"), kind: "spec", targetID: nil)
        XCTAssertTrue(ok)
        XCTAssertEqual(runner.invocations, [["workbench", "attach-doc", "--kind", "spec", "--json", "--", "\(p)", "/tmp/acme/notes/x.md"]])
        XCTAssertEqual(vm.documentViewModel?.document.id, doc)
        XCTAssertEqual(ownerWrites, [.document(doc)])
        XCTAssertNil(vm.attachError)
        XCTAssertFalse(vm.isAttachingDocument)
        XCTAssertEqual(vm.badgeCount, 0, "the owner's own document is never revised")
        XCTAssertNil(vm.attachNotice)
    }

    func testAttachingAnAlreadyAttachedFileOpensItAndSaysNothingChanged() async throws {
        let (p, doc) = try await pool.write { d -> (Int64, Int64) in
            let p = try TestDatabase.insertWorkbench(d)
            return (p, try TestDatabase.insertWorkbenchDocument(d, projectID: p, relPath: "docs/plan.md"))
        }
        let runner = FakeCLIRunner(stdout: Data(#"{"document_id":\#(doc),"rel_path":"docs/plan.md","created":false}"#.utf8))
        let vm = makeVM(runner)
        var ownerWrites: [WorkbenchSubject] = []
        vm.onOwnerWrite = { _, subject in ownerWrites.append(subject) }
        await vm.reload()
        vm.selectedWorkbenchID = p

        let ok = await vm.attachDocument(fileURL: URL(fileURLWithPath: "/tmp/acme/docs/plan.md"), kind: "spec", targetID: nil)
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.documentViewModel?.document.id, doc)
        XCTAssertTrue(vm.attachNotice?.contains("already attached") ?? false)
        XCTAssertEqual(ownerWrites, [], "nothing was written, so a real agent revision is not muted")

        vm.selectedWorkbenchID = nil
        XCTAssertNil(vm.attachNotice, "the notice belongs to the project it was shown on")
    }

    func testAttachDocumentRefusedByTheCLIKeepsTheReason() async throws {
        let p = try await pool.write { try TestDatabase.insertWorkbench($0) }
        let runner = FakeCLIRunner()
        runner.shouldThrow = CLIRunnerError.nonZeroExit(code: 1, stderr: "Error: /etc/x.md resolves outside the project folder")
        let vm = makeVM(runner)
        await vm.reload()
        vm.selectedWorkbenchID = p

        let ok = await vm.attachDocument(fileURL: URL(fileURLWithPath: "/etc/x.md"), kind: "doc", targetID: 4)
        XCTAssertFalse(ok)
        XCTAssertTrue(vm.attachError?.contains("resolves outside the project folder") ?? false)
        XCTAssertNil(vm.documentViewModel)
        XCTAssertFalse(vm.isAttachingDocument)
    }

    func testTargetChoicesFollowTheBoardWithDepth() async throws {
        let p = try await pool.write { d -> Int64 in
            let p = try TestDatabase.insertWorkbench(d)
            let feature = try TestDatabase.insertWorkbenchTarget(d, projectID: p, text: "Feature")
            try TestDatabase.insertWorkbenchTarget(d, projectID: p, text: "Task", parentID: feature)
            return p
        }
        let vm = makeVM()
        await vm.reload()
        vm.selectedWorkbenchID = p
        let rows = try await vm.targetChoices()
        XCTAssertEqual(rows.map(\.node.target.text), ["Feature", "Task"])
        XCTAssertEqual(rows.map(\.depth), [0, 1])
    }

    /// #81: the list groups by kind and filters by title; the search belongs
    /// to one project and is cleared on a switch.
    func testDocumentSectionsFollowTheSearchAndASwitchClearsIt() async throws {
        let p = try await pool.write { d -> Int64 in
            let p = try TestDatabase.insertWorkbench(d)
            try TestDatabase.insertWorkbenchDocument(d, projectID: p, relPath: "docs/specs/sync.md", kind: "spec", title: "Sync")
            try TestDatabase.insertWorkbenchDocument(d, projectID: p, relPath: "docs/plans/auth.md", kind: "plan", title: "Auth")
            try TestDatabase.insertWorkbenchDocument(d, projectID: p, relPath: "README.md", kind: "doc", origin: "import")
            return p
        }
        let vm = makeVM()
        await vm.reload()
        vm.selectedWorkbenchID = p
        await vm.loadDocuments()
        XCTAssertEqual(vm.documentSections.map(\.group), [.specs, .plans, .imported])

        vm.documentQuery = "auth"
        XCTAssertEqual(vm.documentSections.map(\.group), [.plans])

        // Opening a document the list hides (a deep link, an attach) reveals it.
        vm.setDocumentGroup(.specs, collapsed: true)
        let spec = try XCTUnwrap(vm.documents.first { $0.document.kind == "spec" })
        await vm.openDocument(spec.document)
        XCTAssertEqual(vm.documentQuery, "", "the search that hid it is cleared")
        XCTAssertFalse(vm.isDocumentGroupCollapsed(.specs), "its group is unfolded")

        vm.setDocumentGroup(.plans, collapsed: true)
        vm.documentQuery = "auth"
        vm.selectedWorkbenchID = nil
        XCTAssertEqual(vm.documentQuery, "")
        XCTAssertFalse(vm.isDocumentGroupCollapsed(.plans), "folding is per project")
        vm.selectedWorkbenchID = p
        XCTAssertTrue(vm.isDocumentGroupCollapsed(.plans), "and kept for the session")
    }

    func testCreateShowsAFailedDocumentImportWithTheRetryCommand() async throws {
        let id = try await pool.write { try TestDatabase.insertWorkbench($0) }
        let runner = ScriptedCLIRunner(results: [
            .success(Data(#"{"id":\#(id),"folder":"/tmp/acme","name":"acme","docs_import_ok":false,"docs_import_error":"permission denied"}"#.utf8)),
            .success(Data("installed".utf8)),
            .success(Data(#"{"skill":"unchanged","hook":true,"mcp":true}"#.utf8))
        ])
        let vm = makeVM(runner)
        await vm.createWorkbench(folder: URL(fileURLWithPath: "/tmp/acme"), name: nil)
        let note = try XCTUnwrap(vm.importNotes[id])
        XCTAssertTrue(note.contains("permission denied"))
        XCTAssertTrue(note.contains("watchtower workbench import-docs \(id)"))
        XCTAssertNil(vm.installErrors[id], "its own line, apart from the install note")
        XCTAssertNil(vm.errorMessage, "the project exists; the note belongs to it")
    }

    func testCreateRunsCreateThenInstallSelectsTheProjectAndAnnouncesIt() async throws {
        let id = try await pool.write { try TestDatabase.insertWorkbench($0) }
        let runner = ScriptedCLIRunner(results: [
            .success(createdJSON(id)),
            .success(Data("installed".utf8)),
            .success(Data(#"{"skill":"unchanged","hook":true,"mcp":true}"#.utf8))
        ])
        let vm = makeVM(runner)
        var announced: [Int64] = []
        vm.onWorkbenchCreated = { project, installed in if installed { announced.append(project.id) } }

        await vm.createWorkbench(folder: URL(fileURLWithPath: "/tmp/acme"), name: nil)

        XCTAssertEqual(runner.invocations.map { Array($0.prefix(2)) }, [
            ["workbench", "create"], ["integrate", "claude-code"], ["integrate", "status"]
        ])
        XCTAssertEqual(vm.selectedWorkbenchID, id)
        guard case .session = vm.layout.primary else { return XCTFail("the setup session goes on screen") }
        XCTAssertEqual(announced, [id])
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.installStatus[id]?.needsRepair, false)
        XCTAssertFalse(vm.isCreating)
    }

    func testInstallFailureKeepsTheProjectAndPointsAtRepair() async throws {
        let id = try await pool.write { try TestDatabase.insertWorkbench($0) }
        let runner = ScriptedCLIRunner(results: [
            .success(createdJSON(id)),
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "claude not found")),
            .success(Data(#"{"skill":"missing","hook":false,"mcp":false}"#.utf8))
        ])
        let vm = makeVM(runner)
        var announced: [(Int64, Bool)] = []
        vm.onWorkbenchCreated = { announced.append(($0.id, $1)) }
        await vm.createWorkbench(folder: URL(fileURLWithPath: "/tmp/acme"), name: nil)
        XCTAssertEqual(vm.selectedWorkbenchID, id)
        XCTAssertTrue(vm.installErrors[id]?.contains("Repair") == true)
        XCTAssertTrue(vm.installErrors[id]?.contains("claude not found") == true, "the install error is shown")
        XCTAssertNil(vm.errorMessage, "the note belongs to its project, not the list-wide line")
        XCTAssertEqual(vm.installStatus[id]?.needsRepair, true)
        XCTAssertEqual(announced.map(\.0), [id], "the baseline is still seeded")
        XCTAssertEqual(announced.map(\.1), [false], "no first-run terminal after a failed install")
    }

    func testCreateFailureShowsTheCLIErrorAndAnnouncesNothing() async {
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "folder is already bound to a project"))
        let vm = makeVM(runner)
        var announced = false
        vm.onWorkbenchCreated = { _, _ in announced = true }
        await vm.createWorkbench(folder: URL(fileURLWithPath: "/tmp/acme"), name: nil)
        XCTAssertTrue(vm.errorMessage?.contains("already bound") == true)
        XCTAssertNil(vm.selectedWorkbenchID)
        XCTAssertFalse(announced)
    }

    func testRepairRunsIntegrateAndRefreshesTheStatus() async throws {
        let id = try await pool.write { try TestDatabase.insertWorkbench($0) }
        let runner = FakeCLIRunner(stdout: Data(#"{"skill":"unchanged","hook":true,"mcp":true}"#.utf8))
        let vm = makeVM(runner)
        await vm.repairInstall(projectID: id)
        XCTAssertEqual(runner.invocations, [
            ["integrate", "claude-code", "--workbench", String(id)],
            ["integrate", "status", "--workbench", String(id), "--json"]
        ])
        XCTAssertEqual(vm.installStatus[id]?.needsRepair, false)
    }

    /// Switching projects cancels the page's `.task(id:)` status read while
    /// the CLI still runs: the cancellation is not an error, and the last
    /// known status stays.
    func testCancelledStatusReadKeepsTheStatusAndReportsNothing() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"skill":"unchanged","hook":true,"mcp":true}"#.utf8))
        let vm = makeVM(runner)
        await vm.refreshInstallStatus(projectID: 1)
        XCTAssertNotNil(vm.installStatus[1])

        runner.blockUntilCancelled = true
        let read = Task { await vm.refreshInstallStatus(projectID: 1) }
        read.cancel()
        await read.value

        XCTAssertEqual(vm.installStatus[1]?.needsRepair, false, "the previous status is kept")
        XCTAssertNil(vm.installErrors[1])
        XCTAssertNil(vm.errorMessage)
    }

    /// House rule: started → navigated away → result arrives. The process
    /// runner terminates the child on cancel, so the read can fail with a
    /// non-zero exit rather than CancellationError — still silent.
    func testStatusReadThatFailsAfterTheOwnerSwitchedAwayIsSilent() async throws {
        let held = HeldCLIRunner(error: CLIRunnerError.nonZeroExit(code: 15, stderr: ""))
        let vm = makeVM(held)
        vm.selectedWorkbenchID = 1
        let read = Task { await vm.refreshInstallStatus(projectID: 1) }
        await awaitStarted(held)

        vm.selectedWorkbenchID = 2
        read.cancel()
        held.release()
        await read.value

        XCTAssertNil(vm.installErrors[1])
        XCTAssertNil(vm.installErrors[2])
        XCTAssertNil(vm.errorMessage, "nothing lands in the shared list-wide error line")
    }

    func testStatusReadFailureIsScopedToItsProjectAndClearedByTheNextRead() async throws {
        let runner = ScriptedCLIRunner(results: [
            .success(Data(#"{"skill":"missing","hook":false,"mcp":true}"#.utf8)),
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "boom")),
            .success(Data(#"{"skill":"unchanged","hook":true,"mcp":true}"#.utf8))
        ])
        let vm = makeVM(runner)
        await vm.refreshInstallStatus(projectID: 1)
        await vm.refreshInstallStatus(projectID: 1)
        XCTAssertTrue(vm.installErrors[1]?.contains("boom") == true)
        XCTAssertEqual(vm.installStatus[1]?.needsRepair, true, "the last known status (and its Repair) stays")
        XCTAssertNil(vm.installErrors[2])
        XCTAssertNil(vm.errorMessage)

        await vm.refreshInstallStatus(projectID: 1)
        XCTAssertNil(vm.installErrors[1])
        XCTAssertEqual(vm.installStatus[1]?.needsRepair, false)
    }

    /// Selecting the new project starts the page's own status read, racing
    /// `createWorkbench`'s: a later read that still needs repair keeps the note.
    func testCreateTimeInstallNoteSurvivesTheNextStatusRead() async throws {
        let id = try await pool.write { try TestDatabase.insertWorkbench($0) }
        let missing = Data(#"{"skill":"missing","hook":false,"mcp":false}"#.utf8)
        let runner = ScriptedCLIRunner(results: [
            .success(createdJSON(id)),
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "claude not found")),
            .success(missing),
            .success(missing),
            .success(Data(#"{"skill":"unchanged","hook":true,"mcp":true}"#.utf8))
        ])
        let vm = makeVM(runner)
        await vm.createWorkbench(folder: URL(fileURLWithPath: "/tmp/acme"), name: nil)
        await vm.refreshInstallStatus(projectID: id)
        XCTAssertTrue(vm.installErrors[id]?.contains("claude not found") == true, "the note still explains Repair")

        await vm.refreshInstallStatus(projectID: id)
        XCTAssertNil(vm.installErrors[id], "a healthy install clears it")
    }

    /// A successful Repair of one project leaves the list-wide line (another
    /// operation's failure) alone.
    func testRepairSuccessLeavesTheListWideErrorAlone() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"skill":"unchanged","hook":true,"mcp":true}"#.utf8))
        let vm = makeVM(runner)
        vm.errorMessage = "Could not load workbenches"
        await vm.repairInstall(projectID: 1)
        XCTAssertEqual(vm.errorMessage, "Could not load workbenches")
    }

    func testRepairFailureStaysShownAfterTheStatusRefresh() async throws {
        let runner = ScriptedCLIRunner(results: [
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "claude not found")),
            .success(Data(#"{"skill":"missing","hook":false,"mcp":false}"#.utf8))
        ])
        let vm = makeVM(runner)
        await vm.repairInstall(projectID: 3)
        XCTAssertTrue(vm.installErrors[3]?.contains("Repair failed") == true)
        XCTAssertEqual(vm.installStatus[3]?.needsRepair, true)
    }

    func testRevealSelectsTheProjectAndPane() {
        let vm = makeVM()
        vm.reveal(WorkbenchRoute(projectID: 4, pane: .documents, subjectID: 9))
        XCTAssertEqual(vm.selectedWorkbenchID, 4)
        XCTAssertEqual(vm.layout.visiblePanes, [.documents])
    }

    /// House rule: an async operation started from a screen survives leaving
    /// it. The VM lives on AppState, so the create keeps running while the
    /// owner is on another tab and the result is there when they return.
    func testCreateSurvivesNavigatingAwayAndSelectsTheProjectOnReturn() async throws {
        let id = try await pool.write { try TestDatabase.insertWorkbench($0) }
        let held = HeldCLIRunner(stdout: createdJSON(id))
        let appState = AppState()
        appState.terminalCenter.makeProcess = { FakeTerminalSession() }
        appState.initWorkbenches(dbPool: pool, cliRunner: held, notifier: RecordingWorkbenchNotifier())
        let vm = try XCTUnwrap(appState.workbenchesViewModel)
        appState.selectedDestination = .workbench

        let run = Task { await vm.createWorkbench(folder: URL(fileURLWithPath: "/tmp/acme"), name: nil) }
        await awaitStarted(held)
        XCTAssertTrue(vm.isCreating)

        appState.selectedDestination = .inbox
        held.release()
        await run.value

        appState.selectedDestination = .workbench
        XCTAssertTrue(appState.workbenchesViewModel === vm, "the same AppState-owned VM, not a fresh one")
        XCTAssertEqual(vm.selectedWorkbenchID, id)
        XCTAssertFalse(vm.isCreating)
    }

    /// AppState wiring: after a failed install the first-run terminal must
    /// not start (setup would run without the skill/hook/MCP server).
    func testFailedInstallStartsNoFirstRunTerminal() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt-create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try await pool.write { try TestDatabase.insertWorkbench($0, name: "acme", folder: folder.path) }
        let runner = ScriptedCLIRunner(results: [
            .success(createdJSON(id)),
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "claude not found")),
            .success(Data(#"{"skill":"missing","hook":false,"mcp":false}"#.utf8))
        ])
        let appState = AppState()
        appState.terminalCenter.makeProcess = { FakeTerminalSession() }
        appState.initWorkbenches(dbPool: pool, cliRunner: runner, notifier: RecordingWorkbenchNotifier())
        let vm = try XCTUnwrap(appState.workbenchesViewModel)

        await vm.createWorkbench(folder: folder, name: nil)

        XCTAssertEqual(vm.selectedWorkbenchID, id)
        XCTAssertTrue(appState.terminalCenter.states.isEmpty, "no terminal after a failed install")
        let rows = try await pool.read { try TerminalSessionQueries.fetchForWorkbench($0, projectID: id) }
        XCTAssertTrue(rows.isEmpty, "no setup session row after a failed install")
    }

    /// A double click on Start Claude Code / Open terminal: two overlapping
    /// calls create one row and start one process.
    func testConcurrentOpenMostRecentSessionCreatesOneRow() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try await pool.write { try TestDatabase.insertWorkbench($0, name: "acme", folder: folder.path) }
        var processes: [FakeTerminalSession] = []
        let center = TerminalCenter {
            let process = FakeTerminalSession(pid: 0)
            processes.append(process)
            return process
        }
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults,
                                      terminalCenter: center)
        await vm.reload()
        let project = try XCTUnwrap(vm.summaries.first { $0.id == id }?.project)

        async let first: Void = vm.openMostRecentSession(project: project)
        async let second: Void = vm.openMostRecentSession(project: project)
        _ = await (first, second)

        let rows = try await pool.read { try TerminalSessionQueries.fetchForWorkbench($0, projectID: id) }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(processes.flatMap(\.launches).count, 1)

        await vm.openMostRecentSession(project: project)
        let after = try await pool.read { try TerminalSessionQueries.fetchForWorkbench($0, projectID: id) }
        XCTAssertEqual(after.map(\.id), rows.map(\.id), "the next open reuses the row")
        XCTAssertEqual(processes.flatMap(\.launches).count, 1, "a running session is not relaunched")
        XCTAssertEqual(center.focusOrder, [rows[0].id])
    }

    /// A failed list load says nothing about the project's sessions, so Open
    /// terminal must not start a duplicate "New session" row from it.
    func testOpenMostRecentSessionStartsNothingWhenTheLoadFails() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try await pool.write { try TestDatabase.insertWorkbench($0, name: "acme", folder: folder.path) }
        var processes: [FakeTerminalSession] = []
        let center = TerminalCenter {
            let process = FakeTerminalSession(pid: 0)
            processes.append(process)
            return process
        }
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults,
                                      terminalCenter: center)
        await vm.reload()
        let project = try XCTUnwrap(vm.summaries.first { $0.id == id }?.project)

        try await pool.write { try $0.execute(sql: "ALTER TABLE terminal_sessions RENAME TO terminal_sessions_hidden") }
        await vm.openMostRecentSession(project: project)
        try await pool.write { try $0.execute(sql: "ALTER TABLE terminal_sessions_hidden RENAME TO terminal_sessions") }

        let rows = try await pool.read { try TerminalSessionQueries.fetchForWorkbench($0, projectID: id) }
        XCTAssertTrue(rows.isEmpty)
        XCTAssertTrue(processes.flatMap(\.launches).isEmpty)
        XCTAssertNotNil(vm.sessionErrors[id])
    }

    /// A created and installed workbench gets one "Workbench setup" claude row,
    /// started fresh with its own session id and the first-run prompt.
    func testInstalledProjectStartsTheSetupSessionFresh() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt-create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try await pool.write { try TestDatabase.insertWorkbench($0, name: "acme", folder: folder.path) }
        let runner = ScriptedCLIRunner(results: [
            .success(createdJSON(id)),
            .success(Data()),
            .success(Data(#"{"skill":"installed","hook":true,"mcp":true}"#.utf8))
        ])
        let appState = AppState()
        let process = FakeTerminalSession(pid: 0)
        appState.terminalCenter.makeProcess = { process }
        appState.terminalCenter.shell = { "/bin/zsh" }
        appState.initWorkbenches(dbPool: pool, cliRunner: runner, notifier: RecordingWorkbenchNotifier())
        let vm = try XCTUnwrap(appState.workbenchesViewModel)

        await vm.createWorkbench(folder: folder, name: nil)

        let rows = try await pool.read { try TerminalSessionQueries.fetchForWorkbench($0, projectID: id) }
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(row.kind, .claude)
        XCTAssertEqual(row.title, TerminalSessionNaming.setupTitle)
        let uuid = try XCTUnwrap(row.claudeSessionID)
        XCTAssertTrue(TerminalLaunch.isValidSessionID(uuid))
        XCTAssertEqual(appState.terminalCenter.states[row.id], .running)
        XCTAssertEqual(appState.terminalCenter.focusOrder, [row.id])
        XCTAssertEqual(process.launches.last?.args.last,
                       "exec claude --session-id \(uuid) '\(TerminalLaunch.firstRunPrompt(.current))'")
        XCTAssertEqual(vm.terminalSessions[id]?.map(\.id), [row.id])
    }

    func testNavigateToProjectSetsThePendingRouteAndTheTab() {
        let appState = AppState()
        appState.navigateToWorkbench(WorkbenchRoute(projectID: 2, pane: .board))
        XCTAssertEqual(appState.selectedDestination, .workbench)
        XCTAssertEqual(appState.pendingWorkbenchRoute, WorkbenchRoute(projectID: 2, pane: .board))
    }

    func testOpenDocumentMarksItViewedAndKeepsItsViewModelAcrossPaneSwitches() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("docs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "# Plan".write(to: folder.appendingPathComponent("docs/plan.md"), atomically: true, encoding: .utf8)
        let p = try await pool.write { d -> Int64 in
            let p = try TestDatabase.insertWorkbench(d, folder: folder.path)
            _ = try TestDatabase.insertWorkbenchDocument(d, projectID: p)
            return p
        }
        let vm = makeVM()
        await vm.reload()
        vm.selectedWorkbenchID = p
        await vm.loadDocuments()
        let doc = try XCTUnwrap(vm.documents.first?.document)

        await vm.openDocument(doc)
        let opened = try XCTUnwrap(vm.documentViewModel)
        XCTAssertFalse(vm.isRevised(doc))
        vm.layout.show(.board)
        vm.layout.show(.documents)
        XCTAssertTrue(vm.documentViewModel === opened)
        XCTAssertEqual(opened.rendered?.text, "Plan\n\n")
        vm.closeDocument()
    }

    /// A deep link to a document the agent attached after the list loaded
    /// must still open: the list reloads whenever the id is not in it.
    func testOpenPendingReloadsWhenTheDocumentIsNotListedYet() async throws {
        let p = try await pool.write { d -> Int64 in
            let p = try TestDatabase.insertWorkbench(d, name: "one", folder: "/tmp/one")
            _ = try TestDatabase.insertWorkbenchDocument(d, projectID: p, relPath: "docs/a.md")
            return p
        }
        let vm = makeVM()
        await vm.reload()
        vm.selectedWorkbenchID = p
        await vm.loadDocuments()
        XCTAssertEqual(vm.documents.count, 1)
        let added = try await pool.write { try TestDatabase.insertWorkbenchDocument($0, projectID: p, relPath: "docs/b.md") }

        vm.pendingDocumentID = added
        await vm.openPendingDocument()

        XCTAssertEqual(vm.documentViewModel?.document.id, added)
        XCTAssertNil(vm.pendingDocumentID)
        vm.closeDocument()
    }

    /// The agent writes documents and comments DB-only: the poll refreshes
    /// the list and the open document's threads without re-rendering it.
    func testRefreshOnPollPicksUpAgentDBWrites() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("docs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "# Plan\n\nShip it.".write(to: folder.appendingPathComponent("docs/plan.md"), atomically: true, encoding: .utf8)
        let (p, doc) = try await pool.write { d -> (Int64, Int64) in
            let p = try TestDatabase.insertWorkbench(d, folder: folder.path)
            return (p, try TestDatabase.insertWorkbenchDocument(d, projectID: p))
        }
        let vm = makeVM()
        await vm.reload()
        vm.selectedWorkbenchID = p
        await vm.loadDocuments()
        await vm.openDocument(try XCTUnwrap(vm.documents.first?.document))
        let docVM = try XCTUnwrap(vm.documentViewModel)
        let version = docVM.renderVersion
        try await pool.write { d in
            _ = try TestDatabase.insertWorkbenchDocument(d, projectID: p, relPath: "docs/spec.md")
            _ = try TestDatabase.insertWorkbenchComment(d, projectID: p, body: "Which date?", documentID: doc, quote: "Ship it")
        }

        await vm.refreshOnPoll()

        XCTAssertEqual(vm.documents.count, 2)
        XCTAssertEqual(docVM.threads.count, 1)
        XCTAssertNotNil(docVM.anchoredRanges[try XCTUnwrap(docVM.threads.first?.id)])
        XCTAssertEqual(docVM.renderVersion, version, "an open composer's selection stays valid")
        vm.closeDocument()
    }

    /// An agent reply that lands while the document is on screen is marked
    /// read by the poll, as opening it would; the same reply stays unread when
    /// the document is open but not shown (another pane, another tab).
    func testRefreshOnPollMarksAgentRepliesReadOnlyForTheDocumentOnScreen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("docs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "# Plan\n\nShip it.".write(to: folder.appendingPathComponent("docs/plan.md"), atomically: true, encoding: .utf8)
        let (p, doc) = try await pool.write { d -> (Int64, Int64) in
            let p = try TestDatabase.insertWorkbench(d, folder: folder.path)
            return (p, try TestDatabase.insertWorkbenchDocument(d, projectID: p))
        }
        let root = try await pool.write { d in
            try TestDatabase.insertWorkbenchComment(d, projectID: p, author: "owner", documentID: doc, quote: "Ship it")
        }
        var onScreen = false
        let vm = makeVM()
        vm.isTabOnScreen = { onScreen }
        await vm.reload()
        vm.selectedWorkbenchID = p
        vm.layout.show(.documents)
        await vm.loadDocuments()
        await vm.openDocument(try XCTUnwrap(vm.documents.first?.document))
        func unread() throws -> Int {
            try pool.read { d in
                try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM project_comments WHERE author = 'agent' AND read_at = ''") ?? -1
            }
        }
        func reply(_ body: String) async throws {
            try await pool.write { d in
                _ = try TestDatabase.insertWorkbenchComment(d, projectID: p, body: body, documentID: doc, parentID: root)
            }
        }

        try await reply("Hidden tab")
        await vm.refreshOnPoll()
        XCTAssertEqual(try unread(), 1, "not on screen: the reply stays unread")

        onScreen = true
        vm.layout.show(.board)
        await vm.refreshOnPoll()
        XCTAssertEqual(try unread(), 1, "another pane: the document is not on screen")

        vm.layout.show(.documents)
        await vm.refreshOnPoll()
        XCTAssertEqual(try unread(), 0, "on screen: marked read like the open path")
        XCTAssertEqual(vm.summaries.first?.unreadAgentComments, 0, "the list reloads after marking")
        vm.closeDocument()
    }

    func testSwitchingProjectClosesTheOpenDocument() async throws {
        let (p1, p2) = try await pool.write { d -> (Int64, Int64) in
            let p1 = try TestDatabase.insertWorkbench(d, name: "one", folder: "/tmp/one")
            _ = try TestDatabase.insertWorkbenchDocument(d, projectID: p1)
            return (p1, try TestDatabase.insertWorkbench(d, name: "two", folder: "/tmp/two"))
        }
        let vm = makeVM()
        await vm.reload()
        vm.selectedWorkbenchID = p1
        await vm.loadDocuments()
        await vm.openDocument(try XCTUnwrap(vm.documents.first?.document))
        XCTAssertNotNil(vm.documentViewModel)
        vm.selectedWorkbenchID = p2
        XCTAssertNil(vm.documentViewModel)
    }
}

/// Returns one scripted result per call, in order (the last one repeats).
final class ScriptedCLIRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<Data, Error>]
    private var recorded: [[String]] = []

    init(results: [Result<Data, Error>]) {
        self.results = results
    }

    var invocations: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(args: [String]) async throws -> Data {
        lock.lock()
        recorded.append(args)
        let next = results.count > 1 ? results.removeFirst() : results[0]
        lock.unlock()
        return try next.get()
    }
}
