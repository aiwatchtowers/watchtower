import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class ProjectsViewModelTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "ProjectsViewModelTests-\(UUID().uuidString)"))
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func makeVM(_ runner: any CLIRunnerProtocol = FakeCLIRunner()) -> ProjectsViewModel {
        ProjectsViewModel(dbPool: pool, cli: ProjectCLI(runner: runner), defaults: defaults)
    }

    private func createdJSON(_ id: Int64) -> Data {
        Data(#"{"id":\#(id),"folder":"/tmp/acme","name":"acme"}"#.utf8)
    }

    func testReloadBuildsSummariesAndTheBadgeCountsUnreadAndUnviewedDocuments() async throws {
        let ids = try await pool.write { d -> (Int64, Int64) in
            let p = try TestDatabase.insertProject(d)
            let doc = try TestDatabase.insertProjectDocument(d, projectID: p)
            let t = try TestDatabase.insertProjectTarget(d, projectID: p)
            _ = try TestDatabase.insertProjectComment(d, projectID: p, targetID: t)
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
            let p = try TestDatabase.insertProject(d)
            return (p, try TestDatabase.insertProjectDocument(d, projectID: p, updatedAt: "2026-09-29T10:00:00Z"))
        }
        let vm = makeVM()
        await vm.reload()
        let fetched = try await pool.read { try ProjectQueries.document($0, id: doc) }
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

    func testCreateRunsCreateThenInstallSelectsTheProjectAndAnnouncesIt() async throws {
        let id = try await pool.write { try TestDatabase.insertProject($0) }
        let runner = ScriptedCLIRunner(results: [
            .success(createdJSON(id)),
            .success(Data("installed".utf8)),
            .success(Data(#"{"skill":"unchanged","hook":true,"mcp":true}"#.utf8))
        ])
        let vm = makeVM(runner)
        var announced: [Int64] = []
        vm.onProjectCreated = { project, installed in if installed { announced.append(project.id) } }

        await vm.createProject(folder: URL(fileURLWithPath: "/tmp/acme"), name: nil)

        XCTAssertEqual(runner.invocations.map { Array($0.prefix(2)) }, [
            ["project", "create"], ["integrate", "claude-code"], ["integrate", "status"]
        ])
        XCTAssertEqual(vm.selectedProjectID, id)
        XCTAssertEqual(vm.pane, .terminal)
        XCTAssertEqual(announced, [id])
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.installStatus[id]?.needsRepair, false)
        XCTAssertFalse(vm.isCreating)
    }

    func testInstallFailureKeepsTheProjectAndPointsAtRepair() async throws {
        let id = try await pool.write { try TestDatabase.insertProject($0) }
        let runner = ScriptedCLIRunner(results: [
            .success(createdJSON(id)),
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "claude not found")),
            .success(Data(#"{"skill":"missing","hook":false,"mcp":false}"#.utf8))
        ])
        let vm = makeVM(runner)
        var announced: [(Int64, Bool)] = []
        vm.onProjectCreated = { announced.append(($0.id, $1)) }
        await vm.createProject(folder: URL(fileURLWithPath: "/tmp/acme"), name: nil)
        XCTAssertEqual(vm.selectedProjectID, id)
        XCTAssertTrue(vm.errorMessage?.contains("Repair") == true)
        XCTAssertTrue(vm.errorMessage?.contains("claude not found") == true, "the install error is shown")
        XCTAssertEqual(vm.installStatus[id]?.needsRepair, true)
        XCTAssertEqual(announced.map(\.0), [id], "the baseline is still seeded")
        XCTAssertEqual(announced.map(\.1), [false], "no first-run terminal after a failed install")
    }

    func testCreateFailureShowsTheCLIErrorAndAnnouncesNothing() async {
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "folder is already bound to a project"))
        let vm = makeVM(runner)
        var announced = false
        vm.onProjectCreated = { _, _ in announced = true }
        await vm.createProject(folder: URL(fileURLWithPath: "/tmp/acme"), name: nil)
        XCTAssertTrue(vm.errorMessage?.contains("already bound") == true)
        XCTAssertNil(vm.selectedProjectID)
        XCTAssertFalse(announced)
    }

    func testRepairRunsIntegrateAndRefreshesTheStatus() async throws {
        let id = try await pool.write { try TestDatabase.insertProject($0) }
        let runner = FakeCLIRunner(stdout: Data(#"{"skill":"unchanged","hook":true,"mcp":true}"#.utf8))
        let vm = makeVM(runner)
        await vm.repairInstall(projectID: id)
        XCTAssertEqual(runner.invocations, [
            ["integrate", "claude-code", "--project", String(id)],
            ["integrate", "status", "--project", String(id), "--json"]
        ])
        XCTAssertEqual(vm.installStatus[id]?.needsRepair, false)
    }

    func testRevealSelectsTheProjectAndPane() {
        let vm = makeVM()
        vm.reveal(ProjectRoute(projectID: 4, pane: .documents, subjectID: 9))
        XCTAssertEqual(vm.selectedProjectID, 4)
        XCTAssertEqual(vm.pane, .documents)
    }

    /// House rule: an async operation started from a screen survives leaving
    /// it. The VM lives on AppState, so the create keeps running while the
    /// owner is on another tab and the result is there when they return.
    func testCreateSurvivesNavigatingAwayAndSelectsTheProjectOnReturn() async throws {
        let id = try await pool.write { try TestDatabase.insertProject($0) }
        let held = HeldCLIRunner(stdout: createdJSON(id))
        let appState = AppState()
        appState.projectTerminalCenter.makeSession = { FakeTerminalSession() }
        appState.initProjects(dbPool: pool, cliRunner: held, notifier: RecordingProjectNotifier())
        let vm = try XCTUnwrap(appState.projectsViewModel)
        appState.selectedDestination = .projects

        let run = Task { await vm.createProject(folder: URL(fileURLWithPath: "/tmp/acme"), name: nil) }
        await awaitStarted(held)
        XCTAssertTrue(vm.isCreating)

        appState.selectedDestination = .inbox
        held.release()
        await run.value

        appState.selectedDestination = .projects
        XCTAssertTrue(appState.projectsViewModel === vm, "the same AppState-owned VM, not a fresh one")
        XCTAssertEqual(vm.selectedProjectID, id)
        XCTAssertFalse(vm.isCreating)
    }

    /// AppState wiring: after a failed install the first-run terminal must
    /// not start (setup would run without the skill/hook/MCP server).
    func testFailedInstallStartsNoFirstRunTerminal() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt-create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try await pool.write { try TestDatabase.insertProject($0, name: "acme", folder: folder.path) }
        let runner = ScriptedCLIRunner(results: [
            .success(createdJSON(id)),
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "claude not found")),
            .success(Data(#"{"skill":"missing","hook":false,"mcp":false}"#.utf8))
        ])
        let appState = AppState()
        appState.projectTerminalCenter.makeSession = { FakeTerminalSession() }
        appState.initProjects(dbPool: pool, cliRunner: runner, notifier: RecordingProjectNotifier())
        let vm = try XCTUnwrap(appState.projectsViewModel)

        await vm.createProject(folder: folder, name: nil)

        XCTAssertEqual(vm.selectedProjectID, id)
        XCTAssertNil(appState.projectTerminalCenter.states[id], "no terminal after a failed install")
    }

    func testNavigateToProjectSetsThePendingRouteAndTheTab() {
        let appState = AppState()
        appState.navigateToProject(ProjectRoute(projectID: 2, pane: .board))
        XCTAssertEqual(appState.selectedDestination, .projects)
        XCTAssertEqual(appState.pendingProjectRoute, ProjectRoute(projectID: 2, pane: .board))
    }

    func testOpenDocumentMarksItViewedAndKeepsItsViewModelAcrossPaneSwitches() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("docs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "# Plan".write(to: folder.appendingPathComponent("docs/plan.md"), atomically: true, encoding: .utf8)
        let p = try await pool.write { d -> Int64 in
            let p = try TestDatabase.insertProject(d, folder: folder.path)
            _ = try TestDatabase.insertProjectDocument(d, projectID: p)
            return p
        }
        let vm = makeVM()
        await vm.reload()
        vm.selectedProjectID = p
        await vm.loadDocuments()
        let doc = try XCTUnwrap(vm.documents.first?.document)

        await vm.openDocument(doc)
        let opened = try XCTUnwrap(vm.documentViewModel)
        XCTAssertFalse(vm.isRevised(doc))
        vm.pane = .terminal
        vm.pane = .documents
        XCTAssertTrue(vm.documentViewModel === opened)
        XCTAssertEqual(opened.rendered?.text, "Plan\n\n")
        vm.closeDocument()
    }

    /// A deep link to a document the agent attached after the list loaded
    /// must still open: the list reloads whenever the id is not in it.
    func testOpenPendingReloadsWhenTheDocumentIsNotListedYet() async throws {
        let p = try await pool.write { d -> Int64 in
            let p = try TestDatabase.insertProject(d, name: "one", folder: "/tmp/one")
            _ = try TestDatabase.insertProjectDocument(d, projectID: p, relPath: "docs/a.md")
            return p
        }
        let vm = makeVM()
        await vm.reload()
        vm.selectedProjectID = p
        await vm.loadDocuments()
        XCTAssertEqual(vm.documents.count, 1)
        let added = try await pool.write { try TestDatabase.insertProjectDocument($0, projectID: p, relPath: "docs/b.md") }

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
            let p = try TestDatabase.insertProject(d, folder: folder.path)
            return (p, try TestDatabase.insertProjectDocument(d, projectID: p))
        }
        let vm = makeVM()
        await vm.reload()
        vm.selectedProjectID = p
        await vm.loadDocuments()
        await vm.openDocument(try XCTUnwrap(vm.documents.first?.document))
        let docVM = try XCTUnwrap(vm.documentViewModel)
        let version = docVM.renderVersion
        try await pool.write { d in
            _ = try TestDatabase.insertProjectDocument(d, projectID: p, relPath: "docs/spec.md")
            _ = try TestDatabase.insertProjectComment(d, projectID: p, body: "Which date?", documentID: doc, quote: "Ship it")
        }

        await vm.refreshOnPoll()

        XCTAssertEqual(vm.documents.count, 2)
        XCTAssertEqual(docVM.threads.count, 1)
        XCTAssertNotNil(docVM.anchoredRanges[try XCTUnwrap(docVM.threads.first?.id)])
        XCTAssertEqual(docVM.renderVersion, version, "an open composer's selection stays valid")
        vm.closeDocument()
    }

    func testSwitchingProjectClosesTheOpenDocument() async throws {
        let (p1, p2) = try await pool.write { d -> (Int64, Int64) in
            let p1 = try TestDatabase.insertProject(d, name: "one", folder: "/tmp/one")
            _ = try TestDatabase.insertProjectDocument(d, projectID: p1)
            return (p1, try TestDatabase.insertProject(d, name: "two", folder: "/tmp/two"))
        }
        let vm = makeVM()
        await vm.reload()
        vm.selectedProjectID = p1
        await vm.loadDocuments()
        await vm.openDocument(try XCTUnwrap(vm.documents.first?.document))
        XCTAssertNotNil(vm.documentViewModel)
        vm.selectedProjectID = p2
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
