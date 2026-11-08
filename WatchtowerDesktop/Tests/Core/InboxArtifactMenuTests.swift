import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// Answers `automations …` and `inbox folders …` by verb, optionally holding
/// one verb at a gate until the test opens it.
private final class MenuRunner: CLIRunnerProtocol, @unchecked Sendable {
    typealias Handler = @Sendable ([String]) throws -> Data

    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private var recorded: [[String]] = []
    private var held: String?
    private var gate: CheckedContinuation<Void, Never>?
    private var opened = false

    var invocations: [[String]] { lock.withLock { recorded } }
    var isHolding: Bool { lock.withLock { gate != nil } }

    /// `verb` is `args[1]` for `automations`, `args[2]` for `inbox folders`.
    func on(_ verb: String, _ handler: @escaping Handler) { lock.withLock { handlers[verb] = handler } }
    func hold(_ verb: String) { lock.withLock { held = verb } }

    func release() {
        let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
            opened = true
            defer { gate = nil }
            return gate
        }
        waiting?.resume()
    }

    func run(args: [String], stdin _: Data) async throws -> Data { try await run(args: args) }

    func run(args: [String]) async throws -> Data {
        let verb = args.first == "inbox" ? (args.count > 2 ? args[2] : "") : (args.count > 1 ? args[1] : "")
        let (handler, isHeld) = lock.withLock {
            recorded.append(args)
            return (handlers[verb], held == verb)
        }
        if isHeld {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let now = lock.withLock {
                    if opened { return true }
                    gate = continuation
                    return false
                }
                if now { continuation.resume() }
            }
        }
        return try handler?(args) ?? Data()
    }
}

/// The Inbox's artifact ⋯ and Needs approval's ⋯ (plan B Task 14): each
/// entry goes through the Automations tab's own verb (one busy guard, one
/// Delete cleanup), a failure shows on the artifact header as that press's
/// own, and **+ New Artifact…** routes the saved automation to its folder.
@MainActor
final class InboxArtifactMenuTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var runner: MenuRunner!
    private var vm: AutomationsViewModel!
    private var folderMenu: InboxFolderMenuModel!
    private var ids: Ids!

    private var editorOpened: [(Int64, AutomationEditorStep)] = []
    private var historyOpened: [Int64] = []
    private var builtinWrites: [([String], Bool)] = []
    private var builtinAnswer: String?
    private var refreshes = 0
    private var discarded: [Int64] = []

    private struct Ids {
        let root, approvals, release, owner, builtin, noRunNow, needsApproval, ownerOutput: Int64
    }

    override func setUp() async throws {
        (pool, path) = try TestDatabase.createPool()
        ids = try await pool.write { db in
            let seed = try InboxFolderFixtures.seed(db, revision: 7)
            let release = try InboxFolderFixtures.folder(db, parent: seed.root, slug: "release", title: "Release",
                                                         position: 1)
            let owner = try TestDatabase.insertAutomation(db, slug: "roundup", name: "Weekly mail roundup")
            let builtin = try Self.builtin(db, slug: "track-my-threads")
            let noRunNow = try Self.builtin(db, slug: "reactions")
            let needsApproval = try Self.builtin(db, slug: InboxFolderQueries.needsApprovalBuiltinID)
            let run = try TestDatabase.insertAutomationRun(db, automationID: owner)
            let output = try TestDatabase.insertAutomationOutput(db, automationID: owner, runID: run)
            return Ids(root: seed.root, approvals: seed.approvals, release: release, owner: owner, builtin: builtin,
                       noRunNow: noRunNow, needsApproval: needsApproval, ownerOutput: output)
        }
        runner = MenuRunner()
        let ids = try XCTUnwrap(ids)
        runner.on("show") { args in
            let id = Int64(args[2]) ?? 0
            let slug = id == ids.builtin ? "track-my-threads" : id == ids.noRunNow ? "reactions" : "needs-approval"
            let features = id == ids.needsApproval ? #"["approval-cards"]"# : #"["tracks"]"#
            return Data(("{\"id\":\(id),\"slug\":\"\(slug)\",\"scope\":\"personal\",\"path\":\"builtin:\(slug)\","
                + "\"name\":\"\(slug)\",\"enabled\":true,\"runnable\":true,\"needs_confirmation\":false,"
                + "\"recipe_text\":\"\",\"builtin\":{\"id\":\"\(slug)\",\"feature_ids\":\(features),"
                + "\"run_now\":\(id == ids.builtin)}}").utf8)
        }
        runner.on("run") { _ in Data(#"{"run_id":9,"coalesced":false,"daemon_running":true}"#.utf8) }
        runner.on("route") { _ in
            Data(Self.routeJSON(revision: 8).utf8)
        }
        vm = AutomationsViewModel(dbPool: pool, cli: AutomationsCLI(runner: runner), defaults: UserDefaults(
            suiteName: "InboxArtifactMenuTests.\(UUID().uuidString)") ?? .standard)
        vm.discardEditorDraft = { [weak self] in self?.discarded.append($0) }
        vm.refresh()
        let runner = self.runner
        folderMenu = InboxFolderMenuModel(dbPool: pool) { runner }
        await folderMenu.reload()
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    /// `route --json`'s pinned keys.
    nonisolated private static func routeJSON(revision: Int64) -> String {
        #"{"revision":\#(revision),"automation_id":1,"created":false,"folder":{"id":3,"kind":"owner","slug":"release","#
            + #""title":"Release","icon":"","parent_id":1,"position":1,"hidden":false,"automation_ids":[1]}}"#
    }

    nonisolated private static func builtin(_ db: Database, slug: String) throws -> Int64 {
        let id = try TestDatabase.insertAutomation(db, slug: slug, name: slug, triggerKind: "sync",
                                                   triggerSpec: #"{"sync":"x"}"#)
        try db.execute(sql: "UPDATE automations SET origin = 'builtin', builtin_id = ?, path = ? WHERE id = ?",
                       arguments: [slug, "builtin:\(slug)", id])
        return id
    }

    private func model(automations: Bool = true) -> InboxArtifactMenuModel {
        let vm = automations ? self.vm : nil
        return InboxArtifactMenuModel(folderMenu: folderMenu, hooks: .init(
            automations: { vm },
            setBuiltinEnabled: { [weak self] ids, on in
                self?.builtinWrites.append((ids, on))
                return self?.builtinAnswer
            },
            openEditor: { [weak self] id, step in self?.editorOpened.append((id, step)) },
            openRunHistory: { [weak self] id in self?.historyOpened.append(id) },
            refresh: { [weak self] in self?.refreshes += 1 }
        ))
    }

    private func card(_ automationID: Int64, id: Int64? = nil) -> AutomationOutputCard {
        AutomationOutputCard(id: id ?? (automationID == ids.owner ? ids.ownerOutput : 900 + automationID),
                             automationID: automationID, automationName: "Weekly mail roundup", runID: 1,
                             title: "Weekly mail roundup", body: "", priority: "normal", createdAt: Date())
    }

    private func commands(_ entries: [InboxMenuEntry]) -> [String] {
        entries.map(\.title)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "timed out")
    }

    nonisolated private static func failure(_ text: String) -> CLIRunnerError {
        .nonZeroExit(code: 1, stderr: text + "\n")
    }

    // MARK: - Entries

    func testEntriesPerAutomationKind() async {
        let menu = model()
        XCTAssertEqual(commands(menu.content(for: card(ids.owner)).entries), [
            "Run Now", "Edit What It Collects…", "Edit the Look…", "Schedule…", "Move to Folder", "Turn Off",
            "Run History", "Delete…"
        ])
        await menu.prepare(card(ids.builtin))
        XCTAssertEqual(commands(menu.content(for: card(ids.builtin)).entries), [
            "Run Now", "Edit What It Collects…", "Edit the Look…", "Schedule…", "Move to Folder", "Turn Off",
            "Run History"
        ], "a built-in has no Delete…")
        await menu.prepare(card(ids.noRunNow))
        XCTAssertFalse(commands(menu.content(for: card(ids.noRunNow)).entries).contains("Run Now"),
                       "a built-in without Run Now has none")
        await menu.prepare(card(ids.needsApproval))
        XCTAssertFalse(commands(menu.content(for: card(ids.needsApproval)).entries).contains("Move to Folder"),
                       "Needs approval's automation is never moved")
    }

    /// A folder list's rows prepared together (the row context menu's way
    /// in): a built-in never opened offers Run Now, one `show` per automation.
    func testListPrepareOffersRunNowForABuiltinNeverOpened() async {
        let menu = model()
        XCTAssertFalse(commands(menu.content(for: card(ids.builtin)).entries).contains("Run Now"))
        await menu.prepare([card(ids.builtin), card(ids.builtin, id: 950), card(ids.owner)])
        XCTAssertTrue(commands(menu.content(for: card(ids.builtin)).entries).contains("Run Now"))
        XCTAssertEqual(runner.invocations.filter { $0.count > 1 && $0[1] == "show" }.count, 1)
    }

    func testMoveToFolderListsTheTreeWithTheRouteChecked() async throws {
        let (owner, release) = (ids.owner, ids.release)
        try await pool.write { db in try InboxFolderFixtures.route(db, automation: owner, folder: release) }
        await folderMenu.reload()
        let move = try XCTUnwrap(model().content(for: card(ids.owner)).entries.first { $0.title == "Move to Folder" })
        XCTAssertEqual(move.children.map(\.title), ["Inbox", "Release"], "Needs approval is never a target")
        XCTAssertEqual(move.children.filter(\.checked).map(\.title), ["Release"])
    }

    func testEntriesOffWithoutTheAutomationsViewModel() {
        XCTAssertTrue(model(automations: false).isDisabled(card(ids.owner)))
        XCTAssertFalse(model().isDisabled(card(ids.owner)))
    }

    // MARK: - Verbs

    func testToggleAndEditGoThroughTheTabPath() async {
        let menu = model()
        await menu.perform(.runNow, on: card(ids.owner))
        await menu.perform(.turnOff, on: card(ids.owner))
        await menu.perform(.turnOn, on: card(ids.owner))
        await menu.perform(.editCollects, on: card(ids.owner))
        await menu.perform(.editLook, on: card(ids.owner))
        await menu.perform(.schedule, on: card(ids.owner))
        await menu.perform(.runHistory, on: card(ids.owner))
        let id = String(ids.owner)
        XCTAssertEqual(runner.invocations, [
            ["automations", "run", id, "--json"], ["automations", "disable", id], ["automations", "enable", id]
        ])
        XCTAssertEqual(editorOpened.map(\.0), [ids.owner, ids.owner, ids.owner])
        XCTAssertEqual(editorOpened.map(\.1), [.collects, .look, .schedule])
        XCTAssertEqual(historyOpened, [ids.owner])
        XCTAssertEqual(refreshes, 3, "every landed write re-reads the Inbox")
        XCTAssertNil(menu.headerErrors[ids.ownerOutput])
    }

    func testBuiltinRunNowAndTurnOffGoThroughItsCard() async {
        let menu = model()
        await menu.perform(.runNow, on: card(ids.builtin))
        await menu.perform(.turnOff, on: card(ids.builtin))
        XCTAssertTrue(runner.invocations.contains(["automations", "run", String(ids.builtin), "--json"]))
        XCTAssertEqual(builtinWrites.map(\.0), [["tracks"]], "Turn Off names the built-in's feature ids")
        XCTAssertEqual(builtinWrites.map(\.1), [false])
        XCTAssertFalse(runner.invocations.contains { $0.count > 1 && $0[1] == "disable" },
                       "a built-in is turned off through its features, not `automations disable`")
    }

    func testMoveToFolderSendsRouteWithTheCurrentRevision() async {
        await model().perform(.moveTo(folderID: ids.release), on: card(ids.owner))
        XCTAssertEqual(runner.invocations, [[
            "inbox", "folders", "route", String(ids.owner), "--folder", String(ids.release),
            "--expect-revision", "7", "--json"
        ]])
    }

    func testMoveConflictReloadsLikeTheMenuAndShowsOnTheHeader() async {
        runner.on("route") { _ in throw Self.failure("the Inbox menu changed (revision 8, expected 7)") }
        let menu = model()
        await menu.perform(.moveTo(folderID: ids.release), on: card(ids.owner))
        XCTAssertEqual(menu.headerErrors[ids.ownerOutput], "Couldn't move it: \(InboxFolderMenuModel.routeMenuChanged)")
        XCTAssertEqual(folderMenu.note, .menuChanged)
        XCTAssertEqual(runner.invocations.filter { $0.contains("route") }.count, 1, "never retried")
    }

    // MARK: - Failures

    func testFailureShowsOnHeader() async {
        let menu = model()
        runner.on("run") { _ in throw Self.failure("automation is not runnable: disabled") }
        await menu.perform(.runNow, on: card(ids.owner))
        XCTAssertEqual(menu.headerErrors[ids.ownerOutput], "automation is not runnable: disabled")

        runner.on("disable") { _ in throw Self.failure("recipe is locked") }
        await menu.perform(.turnOff, on: card(ids.owner))
        XCTAssertEqual(menu.headerErrors[ids.ownerOutput], "recipe is locked", "the next press replaces the text")

        vm.lastError = nil
        builtinAnswer = "config locked"
        let builtin = card(ids.builtin)
        await menu.perform(.turnOff, on: builtin)
        XCTAssertEqual(menu.headerErrors[builtin.id], "config locked")
        XCTAssertNil(vm.lastError, "the header's text is the press's own, never the tab-wide line")

        runner.on("route") { _ in throw Self.failure("unknown folder 99") }
        await menu.perform(.moveTo(folderID: 99), on: card(ids.owner))
        XCTAssertEqual(menu.headerErrors[ids.ownerOutput], "Couldn't move it: unknown folder 99")
        XCTAssertEqual(refreshes, 0)
    }

    func testDeleteFailureKeepsArtifact() async throws {
        runner.on("delete") { _ in throw Self.failure("recipe file is busy") }
        let menu = model()
        await menu.perform(.delete, on: card(ids.owner))
        let pending = try XCTUnwrap(menu.pendingDelete)
        XCTAssertEqual(pending.automationID, ids.owner, "Delete… asks first")
        XCTAssertTrue(runner.invocations.isEmpty)
        await menu.confirmDelete(pending)
        XCTAssertEqual(menu.headerErrors[ids.ownerOutput], "recipe file is busy")
        let owner = ids.owner
        let outputs = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM automation_outputs WHERE automation_id = ?",
                             arguments: [owner])
        }
        XCTAssertEqual(outputs, 1)
        XCTAssertNil(menu.pendingDelete)
    }

    func testCancelledDeleteSendsNothing() async {
        let menu = model()
        await menu.perform(.delete, on: card(ids.owner))
        menu.cancelDelete()
        XCTAssertNil(menu.pendingDelete)
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    // MARK: - Busy

    func testSecondPressWhileRunningIsIgnored() async {
        runner.hold("run")
        let menu = model()
        let first = Task { await menu.perform(.runNow, on: card(ids.owner)) }
        await waitUntil { self.runner.isHolding }
        XCTAssertTrue(menu.isWorking(card(ids.owner)))
        XCTAssertTrue(menu.isDisabled(card(ids.owner)), "the entries are off while it runs")
        await menu.perform(.runNow, on: card(ids.owner))
        runner.release()
        await first.value
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertNil(menu.headerErrors[ids.ownerOutput], "ignored, not refused")
    }

    func testConcurrentRunNowFromTabAndInboxRunsOnce() async {
        runner.hold("run")
        let menu = model()
        let tab = Task { await self.vm.runNow(self.ids.owner) }
        await waitUntil { self.runner.isHolding }
        XCTAssertTrue(menu.isDisabled(card(ids.owner)), "the Inbox entry is off while the tab's call runs")
        await menu.perform(.runNow, on: card(ids.owner))
        XCTAssertEqual(menu.headerErrors[ids.ownerOutput], AutomationCallResult.busyText)
        runner.release()
        _ = await tab.value
        XCTAssertEqual(runner.invocations.filter { $0.count > 1 && $0[1] == "run" }.count, 1)
    }

    func testSecondDeleteWhileInFlightIsIgnored() async throws {
        runner.hold("delete")
        let menu = model()
        await menu.perform(.delete, on: card(ids.owner))
        let pending = try XCTUnwrap(menu.pendingDelete)
        let first = Task { await menu.confirmDelete(pending) }
        await waitUntil { self.runner.isHolding }
        await menu.perform(.delete, on: card(ids.owner))
        XCTAssertNil(menu.pendingDelete, "no second confirmation while the first delete runs")
        await menu.confirmDelete(pending)
        runner.release()
        await first.value
        XCTAssertEqual(runner.invocations.filter { $0.count > 1 && $0[1] == "delete" }.count, 1)
    }

    // MARK: - Delete's cleanup is the tab's

    func testDeleteFromInboxClearsTabSelectionAndCaches() async throws {
        let ownerID = ids.owner
        runner.on("dry-run") { _ in throw Self.failure("no budget") }
        vm.select(ownerID)
        await vm.dryRun(ownerID)
        XCTAssertNotNil(vm.dryRuns[ownerID])
        XCTAssertNotNil(vm.runs[ownerID])
        let pool = try XCTUnwrap(self.pool)
        runner.on("delete") { _ in
            try pool.write { db in try db.execute(sql: "DELETE FROM automations WHERE id = ?", arguments: [ownerID]) }
            return Data()
        }
        let menu = model()
        await menu.perform(.delete, on: card(ownerID))
        await menu.confirmDelete(try XCTUnwrap(menu.pendingDelete))
        XCTAssertNil(vm.selectedID)
        XCTAssertEqual(vm.panel, .empty)
        XCTAssertNil(vm.runs[ownerID])
        XCTAssertNil(vm.dryRuns[ownerID])
        XCTAssertEqual(refreshes, 1)
    }

    func testDeleteFromInboxClosesTheOpenEditor() async throws {
        vm.showEditor(.existing(ids.owner))
        let menu = model()
        await menu.perform(.delete, on: card(ids.owner))
        await menu.confirmDelete(try XCTUnwrap(menu.pendingDelete))
        XCTAssertEqual(vm.panel, .empty)
        XCTAssertEqual(discarded, [ids.owner], "the editor's draft of it goes too")
    }

    // MARK: - Needs approval's ⋯

    func testApprovalsMenuEntries() async {
        let menu = model()
        await menu.performApprovals(.editLook)
        await menu.performApprovals(.runHistory)
        await menu.performApprovals(.turnOff)
        XCTAssertEqual(editorOpened.map(\.0), [ids.needsApproval])
        XCTAssertEqual(editorOpened.map(\.1), [.look])
        XCTAssertEqual(historyOpened, [ids.needsApproval])
        XCTAssertEqual(builtinWrites.map(\.0), [["approval-cards"]])
        XCTAssertEqual(builtinWrites.map(\.1), [false])
        XCTAssertEqual(refreshes, 1)

        builtinAnswer = "Feature changes are being applied in Settings — try again"
        await menu.performApprovals(.turnOn)
        XCTAssertEqual(menu.approvalsError, "Feature changes are being applied in Settings — try again")
    }

    func testApprovalsMenuWithoutTheBuiltinIndexed() async throws {
        let needsApproval = ids.needsApproval
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM automations WHERE id = ?", arguments: [needsApproval])
        }
        vm.refresh()
        let menu = model()
        await menu.performApprovals(.turnOn)
        XCTAssertEqual(builtinWrites.map(\.0), [[ActionStripViewModel.approvalsFeatureID]], "its feature directly")
        await menu.performApprovals(.editLook)
        XCTAssertEqual(menu.approvalsError, InboxArtifactMenuModel.notIndexed)
        XCTAssertTrue(editorOpened.isEmpty)
    }

    // MARK: - + New Artifact…

    /// The view model wired as the app wires it: the route through the
    /// folder menu at its read revision.
    private func wireRoute() {
        guard let menu = folderMenu else { return XCTFail("no folder menu") }
        vm.routeSavedAutomation = { id, folder, reread in
            if reread { await menu.reload() }
            return await menu.route(id, to: folder)
        }
    }

    /// A fresh draft started from the New panel on screen (its route, as
    /// `AutomationsView.continueNew` passes it), then saved.
    private func saveNewDraft(contextID: String, as automationID: Int64) async {
        let route: InboxNewArtifactRoute? = if case let .new(flow) = vm.panel { flow.route } else { nil }
        vm.showEditor(.newDraft(contextID: contextID, scope: .personal, startText: nil), route: route)
        await vm.draftSaved(contextID: contextID, conversationID: 77, automationID: automationID)
    }

    func testNewArtifactRoutesSavedAutomationToCurrentFolder() async {
        wireRoute()
        let route = InboxArtifactMenuModel.newArtifactRoute(folderMenu.tree, selected: ids.release)
        XCTAssertEqual(route, InboxNewArtifactRoute(folderID: ids.release, title: "Release"))
        vm.showNew(AutomationNewFlow(route: route))
        await saveNewDraft(contextID: "draft-a", as: ids.owner)
        XCTAssertEqual(runner.invocations, [[
            "inbox", "folders", "route", String(ids.owner), "--folder", String(ids.release),
            "--expect-revision", "7", "--json"
        ]])
        XCTAssertNil(vm.routeFailures[ids.owner])
    }

    func testNewArtifactFromRootSendsNoRoute() async {
        wireRoute()
        XCTAssertNil(InboxArtifactMenuModel.newArtifactRoute(folderMenu.tree, selected: ids.root))
        XCTAssertNil(InboxArtifactMenuModel.newArtifactRoute(folderMenu.tree, selected: ids.approvals))
        vm.showNew(AutomationNewFlow(route: nil))
        await saveNewDraft(contextID: "draft-b", as: ids.owner)
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testNewArtifactCancelledSendsNoRoute() async {
        wireRoute()
        vm.showNew(AutomationNewFlow(route: InboxNewArtifactRoute(folderID: ids.release, title: "Release")))
        vm.select(nil) // the New flow left before a draft started
        await saveNewDraft(contextID: "draft-c", as: ids.owner)
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    /// + New Artifact… from Release, then an older draft row opened
    /// instead of a fresh start: its save sends no route.
    func testResumedDraftFromTheNewPanelSendsNoRoute() async {
        wireRoute()
        vm.showNew(AutomationNewFlow(route: InboxNewArtifactRoute(folderID: ids.release, title: "Release")))
        vm.showEditor(.newDraft(contextID: "older-draft", scope: .personal, startText: nil))
        await vm.draftSaved(contextID: "older-draft", conversationID: 78, automationID: ids.owner)
        XCTAssertTrue(runner.invocations.isEmpty)
        XCTAssertTrue(vm.newDraftRoutes.isEmpty)
    }

    /// A template picked in a New flow from Release: every copy its install
    /// makes is routed there, one call each.
    func testTemplateFromAFolderRoutesEveryInstalledCopy() async {
        wireRoute()
        vm.showTemplate(name: "jira-state-report", scope: .personal,
                        route: InboxNewArtifactRoute(folderID: ids.release, title: "Release"))
        await vm.templateInstalled(name: "jira-state-report", scope: .personal, ids: [ids.owner, ids.builtin])
        XCTAssertEqual(runner.invocations.map { $0.prefix(6) }, [
            ["inbox", "folders", "route", String(ids.owner), "--folder", String(ids.release)],
            ["inbox", "folders", "route", String(ids.builtin), "--folder", String(ids.release)]
        ])
        XCTAssertTrue(vm.routeFailures.isEmpty)
        XCTAssertNil(vm.templateRoute(name: "jira-state-report", scope: .personal), "routed once")
    }

    func testTemplateFromTheRootSendsNoRoute() async {
        wireRoute()
        vm.showTemplate(name: "jira-state-report", scope: .personal)
        await vm.templateInstalled(name: "jira-state-report", scope: .personal, ids: [ids.owner])
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    /// A template's failed route shows the save's line and Try Again on the copy.
    func testTemplateRouteFailureShowsTryAgain() async {
        wireRoute()
        runner.on("route") { _ in throw Self.failure("the Inbox menu changed (revision 8, expected 7)") }
        vm.showTemplate(name: "jira-state-report", scope: .personal,
                        route: InboxNewArtifactRoute(folderID: ids.release, title: "Release"))
        await vm.templateInstalled(name: "jira-state-report", scope: .personal, ids: [ids.owner])
        XCTAssertEqual(vm.routeFailures[ids.owner]?.reason, InboxFolderMenuModel.routeMenuChanged)
    }

    func testNewArtifactRouteConflictShowsTryAgain() async {
        wireRoute()
        runner.on("route") { _ in throw Self.failure("the Inbox menu changed (revision 8, expected 7)") }
        vm.showNew(AutomationNewFlow(route: InboxNewArtifactRoute(folderID: ids.release, title: "Release")))
        await saveNewDraft(contextID: "draft-d", as: ids.owner)
        XCTAssertEqual(vm.routeFailures[ids.owner]?.reason, InboxFolderMenuModel.routeMenuChanged)
        XCTAssertEqual(vm.routeFailures[ids.owner]?.route.title, "Release")
        XCTAssertEqual(vm.items.map(\.id).contains(ids.owner), true, "the recipe stays saved")

        runner.on("route") { _ in
            Data(Self.routeJSON(revision: 9).utf8)
        }
        await vm.retryRoute(ids.owner)
        XCTAssertNil(vm.routeFailures[ids.owner])
        XCTAssertEqual(runner.invocations.filter { $0.contains("route") }.count, 2, "one call per press")
    }
}
