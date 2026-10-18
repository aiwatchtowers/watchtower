import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The branch popover's `git fetch origin` and its Remote only section
/// (board #563): a background fetch on open when the last try is over five
/// minutes old, the Fetch button, one fetch at a time per repository held by
/// the view model, a quiet note on failure, and a remote-only checkout that
/// goes through the switch's confirmations (PROJ-10).
@MainActor
final class WorkbenchesViewModelGitFetchTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var folder: URL!
    private var project: Workbench!

    /// Answers each `workbench git <command>` with its scripted envelope and
    /// records the calls. A held fetch waits until `releaseFetch()`.
    final class GitRunner: CLIRunnerProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String: Data]
        private var recorded: [[String]] = []
        private var holdFetch = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        init(_ replies: [String: Data], holdFetch: Bool = false) {
            self.replies = replies
            self.holdFetch = holdFetch
        }

        var invocations: [[String]] { lock.withLock { recorded } }

        func calls(_ command: String) -> [[String]] {
            invocations.filter { $0.count > 2 && $0[2] == command }
        }

        func reply(_ command: String, _ data: Data) { lock.withLock { replies[command] = data } }

        func releaseFetch() {
            let resumed = lock.withLock {
                holdFetch = false
                defer { waiting = [] }
                return waiting
            }
            resumed.forEach { $0.resume() }
        }

        func run(args: [String]) async throws -> Data {
            let command = args.count > 2 ? args[2] : ""
            let hold = lock.withLock {
                recorded.append(args)
                return command == "fetch" && holdFetch
            }
            if hold {
                await withCheckedContinuation { continuation in
                    let resumeNow = lock.withLock {
                        guard holdFetch else { return true }
                        waiting.append(continuation)
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
            }
            guard let data = lock.withLock({ replies[command] }) else {
                throw CLIRunnerError.nonZeroExit(code: 1, stderr: "no reply scripted for \(command)")
            }
            return data
        }
    }

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchesViewModelGitFetchTests-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt fetch \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let folderPath = folder.path
        project = try pool.write { d in
            let id = try TestDatabase.insertWorkbench(d, name: "acme", folder: folderPath)
            return try XCTUnwrap(WorkbenchQueries.fetch(d, id: id))
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    // MARK: - Fixtures

    private var status: Data {
        Data(#"""
            {"workbench_id":\#(project.id),"git":true,"branch":"main","head":"a1b2c3d","dirty":false,
             "git_dir":"/r/.git","common_dir":"/r/.git","status_ok":true}
            """#.utf8)
    }

    private func branches(behind: Int = 0, remoteOnly: [String] = []) -> Data {
        let remote = remoteOnly.map { #"{"name":"\#($0)","ref":"origin/\#($0)","head":"87cafec"}"# }
        return Data(#"""
            {"git":true,"current":"main","branches":[{"name":"main","current":true,"upstream":"origin/main","behind":\#(behind)}],
             "branches_ok":true,"remote_only":[\#(remote.joined(separator: ","))]}
            """#.utf8)
    }

    private let fetched = Data(#"{"git":true,"remote":"origin","fetched":true,"fetched_at":"2026-01-01T00:00:00Z"}"#.utf8)

    private func makeVM(_ runner: GitRunner) -> WorkbenchesViewModel {
        WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)
    }

    /// A view model whose main folder's status is read, with a clock the
    /// test moves.
    private func placedVM(_ runner: GitRunner, now: @escaping () -> Date) async -> WorkbenchesViewModel {
        let vm = makeVM(runner)
        vm.gitFetchNow = now
        await vm.refreshGitStatus(projectID: project.id)
        XCTAssertNotNil(vm.gitFetchRepository(.mainFolder(project.id)))
        return vm
    }

    private func openPopover(_ vm: WorkbenchesViewModel) async {
        await vm.loadBranches(project: project, root: project.mainCodeRoot)
        vm.fetchOriginIfDue(project: project, root: project.mainCodeRoot)
        await settle(vm)
    }

    /// Waits for the fetch in flight, if any.
    private func settle(_ vm: WorkbenchesViewModel) async {
        for task in vm.gitFetchTasks.values { await task.value }
    }

    private var key: GitRootKey { .mainFolder(project.id) }

    // MARK: - Background fetch and rarity

    func testOpeningThePopoverFetchesInTheBackgroundThenRereadsTheList() async {
        let runner = GitRunner(["status": status, "branches": branches(), "fetch": fetched])
        let start = Date()
        let vm = await placedVM(runner) { start }
        await vm.loadBranches(project: project, root: project.mainCodeRoot)
        XCTAssertEqual(vm.gitBranches[key]?.branches.first?.behind, 0, "the list shows at once, before the fetch")

        runner.reply("branches", branches(behind: 2, remoteOnly: ["topic"]))
        vm.fetchOriginIfDue(project: project, root: project.mainCodeRoot)
        XCTAssertEqual(vm.gitFetchState(key)?.running, true)
        await settle(vm)

        XCTAssertEqual(runner.calls("fetch"), [["workbench", "git", "fetch", "--workbench", String(project.id), "--json"]])
        let state = vm.gitFetchState(key)
        XCTAssertEqual(state?.running, false)
        XCTAssertEqual(state?.lastFetchedAt, start)
        XCTAssertNil(state?.failure)
        XCTAssertEqual(vm.gitBranches[key]?.branches.first?.behind, 2, "the list is read again after the fetch")
        XCTAssertEqual(vm.gitBranches[key]?.remoteOnly.map(\.name), ["topic"])
        XCTAssertEqual(WorkbenchFetchPresentation.caption(state, now: start.addingTimeInterval(150)), "Fetched 2m ago")
    }

    func testAPopoverReopenedWithinFiveMinutesDoesNotFetchAgain() async {
        let runner = GitRunner(["status": status, "branches": branches(), "fetch": fetched])
        var now = Date()
        let vm = await placedVM(runner) { now }
        await openPopover(vm)
        now = now.addingTimeInterval(4 * 60)
        await openPopover(vm)
        XCTAssertEqual(runner.calls("fetch").count, 1, "within five minutes: no second background fetch")
        now = now.addingTimeInterval(61)
        await openPopover(vm)
        XCTAssertEqual(runner.calls("fetch").count, 2, "over five minutes since the last try: fetched again")
    }

    func testTheFetchButtonFetchesEvenWhenNotDue() async {
        let runner = GitRunner(["status": status, "branches": branches(), "fetch": fetched])
        let now = Date()
        let vm = await placedVM(runner) { now }
        await openPopover(vm)
        vm.fetchOrigin(project: project, root: project.mainCodeRoot)
        await settle(vm)
        XCTAssertEqual(runner.calls("fetch").count, 2)
    }

    // MARK: - One at a time, outliving the popover

    func testOneFetchAtATimePerRepositoryAndItOutlivesThePopover() async {
        let runner = GitRunner(["status": status, "branches": branches(), "fetch": fetched], holdFetch: true)
        let now = Date()
        let vm = await placedVM(runner) { now }
        vm.fetchOrigin(project: project, root: project.mainCodeRoot)
        let popover = Task { await self.openPopover(vm) }
        popover.cancel() // the popover closed while its fetch runs
        vm.fetchOrigin(project: project, root: project.mainCodeRoot)
        vm.fetchOriginIfDue(project: project, root: project.mainCodeRoot)
        XCTAssertEqual(vm.gitFetchState(key)?.running, true)
        runner.releaseFetch()
        await settle(vm)
        await popover.value
        XCTAssertEqual(runner.calls("fetch").count, 1, "a fetch while one runs starts nothing")
        XCTAssertEqual(vm.gitFetchState(key)?.running, false)
        XCTAssertEqual(vm.gitFetchState(key)?.lastFetchedAt, now, "the fetch finished though the popover went away")
    }

    // MARK: - Failure

    func testAFailedFetchIsAQuietNoteAndTheListStays() async {
        let failed = Data(#"""
            {"git":true,"remote":"origin","fetched":false,
             "error":"fatal: could not read Username for 'https://example.com': terminal prompts disabled"}
            """#.utf8)
        let runner = GitRunner(["status": status, "branches": branches(), "fetch": failed])
        var now = Date()
        let vm = await placedVM(runner) { now }
        await openPopover(vm)
        let state = vm.gitFetchState(key)
        XCTAssertEqual(state?.failure, "Couldn't fetch origin: could not read Username for 'https://example.com': "
            + "terminal prompts disabled — Watchtower's fetch never asks for a password or key and does not use a custom core.sshCommand")
        XCTAssertNil(state?.lastFetchedAt)
        XCTAssertEqual(WorkbenchFetchPresentation.caption(state, now: now), "Not fetched yet")
        XCTAssertEqual(vm.branchListStates[key], .loaded, "the list works on the local refs")
        XCTAssertNil(vm.gitErrors[key], "a fetch failure is not a branch error")
        XCTAssertEqual(runner.calls("branches").count, 1, "no reread after a failed fetch")

        now = now.addingTimeInterval(60)
        await openPopover(vm)
        XCTAssertEqual(runner.calls("fetch").count, 1, "a failed try counts for the rarity too")

        runner.reply("fetch", fetched)
        vm.fetchOrigin(project: project, root: project.mainCodeRoot)
        await settle(vm)
        XCTAssertNil(vm.gitFetchState(key)?.failure, "a success clears the note")
    }

    func testACallThatFailsIsAQuietNoteToo() async {
        let runner = GitRunner(["status": status, "branches": branches()])
        let vm = await placedVM(runner) { Date() }
        await openPopover(vm)
        XCTAssertEqual(vm.gitFetchState(key)?.failure, "Couldn't fetch origin: "
            + WorkbenchBranchPresentation.failureText(CLIRunnerError.nonZeroExit(code: 1, stderr: "no reply scripted for fetch"),
                                                      command: "fetch"))
        XCTAssertEqual(vm.gitFetchState(key)?.running, false)
    }

    func testNoOriginIsCheckedAgainOnceDue() async {
        let runner = GitRunner(["status": status, "branches": branches(),
                                "fetch": Data(#"{"git":true,"remote":"origin","no_remote":true,"fetched":false}"#.utf8)])
        var now = Date()
        let vm = await placedVM(runner) { now }
        await openPopover(vm)
        XCTAssertEqual(vm.gitFetchState(key)?.noRemote, true)
        XCTAssertNil(vm.gitFetchState(key)?.failure)
        XCTAssertEqual(WorkbenchFetchPresentation.caption(vm.gitFetchState(key), now: now), "No origin remote")
        now = now.addingTimeInterval(60)
        await openPopover(vm)
        XCTAssertEqual(runner.calls("fetch").count, 1, "not again within five minutes")

        runner.reply("fetch", fetched) // an agent added origin meanwhile
        now = now.addingTimeInterval(5 * 60)
        await openPopover(vm)
        XCTAssertEqual(runner.calls("fetch").count, 2, "checked again once due")
        XCTAssertEqual(vm.gitFetchState(key)?.noRemote, false)
        XCTAssertEqual(vm.gitFetchState(key)?.lastFetchedAt, now)
    }

    func testNoFetchBeforeAStatusPlacedTheRepository() async {
        let runner = GitRunner(["status": status, "branches": branches(), "fetch": fetched])
        let vm = makeVM(runner)
        vm.fetchOriginIfDue(project: project, root: project.mainCodeRoot)
        vm.fetchOrigin(project: project, root: project.mainCodeRoot)
        await settle(vm)
        XCTAssertTrue(runner.calls("fetch").isEmpty)
    }

    // MARK: - Remote only: Check out (PROJ-10)

    private func checkoutArgs(_ extra: [String]) -> [String] {
        ["workbench", "git", "checkout", "--workbench", String(project.id), "--branch", "topic"] + extra + ["--json"]
    }

    private func checkoutResult(_ fields: String) -> Data {
        Data(#"{"workbench_id":\#(project.id),"branch":"topic",\#(fields),"status":{}}"#.utf8)
    }

    func testProj10_ACheckOutWaitsForTheOwnerAndResendsWhatTheyConfirmed() async throws {
        let runner = GitRunner([
            "status": status, "branches": branches(remoteOnly: ["topic"]),
            "checkout": checkoutResult(#""switched":false,"needs_confirmation":["uncommitted_changes"],"changes":2"#)
        ])
        let vm = makeVM(runner)
        await vm.checkOutRemoteBranch("topic", project: project)
        XCTAssertEqual(runner.calls("checkout"), [checkoutArgs([])], "the first try carries no confirmation flag")
        XCTAssertTrue(runner.calls("switch").isEmpty)
        let pending = try XCTUnwrap(vm.pendingBranchConfirmation[project.id])
        XCTAssertTrue(pending.checkout)
        XCTAssertEqual(pending.primaryLabel, "Stash and check out")

        runner.reply("checkout", checkoutResult(#""switched":true,"created":true"#))
        await vm.confirmPendingSwitch(project: project, confirming: pending)
        XCTAssertEqual(runner.calls("checkout").last, checkoutArgs(["--stash"]))
        XCTAssertTrue(runner.calls("switch").isEmpty, "a confirmed checkout is resent as a checkout")
        XCTAssertNil(vm.gitErrors[project.id])
        XCTAssertEqual(runner.calls("branches").count, 1, "the list is read again after the checkout")
    }

    func testProj10_ARefusedCheckOutSaysWhy() async {
        let runner = GitRunner([
            "status": status, "branches": branches(),
            "checkout": checkoutResult(#""switched":false,"refused":"exists","refused_detail":"a local branch is already named topic""#)
        ])
        let vm = makeVM(runner)
        await vm.checkOutRemoteBranch("topic", project: project)
        XCTAssertEqual(vm.gitErrors[project.id], "a local branch is already named topic")
        XCTAssertNil(vm.pendingBranchConfirmation[project.id])
    }
}
