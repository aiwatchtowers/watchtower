import GRDB
import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

/// Answers `automations <verb>` (`args[1]`) and `inbox folders <verb>`
/// (`args[2]`), recording every call.
private final class SaveFolderRunner: CLIRunnerProtocol, @unchecked Sendable {
    typealias Handler = @Sendable ([String]) throws -> Data

    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private var recorded: [[String]] = []

    var invocations: [[String]] { lock.withLock { recorded } }

    func on(_ verb: String, _ handler: @escaping Handler) { lock.withLock { handlers[verb] = handler } }

    func run(args: [String], stdin _: Data) async throws -> Data { try await run(args: args) }

    func run(args: [String]) async throws -> Data {
        let verb = args.first == "inbox" ? (args.count > 2 ? args[2] : "") : (args.count > 1 ? args[1] : "")
        let handler = lock.withLock {
            recorded.append(args)
            return handlers[verb]
        }
        return try handler?(args) ?? Data()
    }
}

/// The editor's folder line and the route its save sends (inbox builder B
/// Task 15): the line ends the pinned Changed row on every step, only when
/// the press saves, and is never a hashed item (AUTO-06); the route goes
/// once, after a save that landed, and a failure keeps the recipe saved
/// with **Try Again**.
@MainActor
final class AutomationSaveFolderTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var runner: SaveFolderRunner!
    private var vm: AutomationsViewModel!
    private var folderMenu: InboxFolderMenuModel!
    private var root: Int64 = 0
    private var release: Int64 = 0
    private var acme: Int64 = 0
    private var automation: Int64 = 0

    override func setUp() async throws {
        (pool, path) = try TestDatabase.createPool()
        let ids = try await pool.write { db in
            let seed = try InboxFolderFixtures.seed(db, revision: 7)
            let release = try InboxFolderFixtures.folder(db, parent: seed.root, slug: "release", title: "Release",
                                                         position: 1)
            let acme = try InboxFolderFixtures.folder(db, parent: seed.root, slug: "acme", title: "Acme", position: 2)
            let automation = try TestDatabase.insertAutomation(db, slug: "digest", name: "Digest")
            return (seed.root, release, acme, automation)
        }
        (root, release, acme, automation) = ids
        runner = SaveFolderRunner()
        runner.on("route") { _ in Data(Self.routeJSON(revision: 8).utf8) }
        vm = AutomationsViewModel(dbPool: pool, cli: AutomationsCLI(runner: runner), defaults: UserDefaults(
            suiteName: "AutomationSaveFolderTests.\(UUID().uuidString)") ?? .standard)
        let runner = self.runner
        folderMenu = InboxFolderMenuModel(dbPool: pool) { runner }
        await folderMenu.reload()
        let menu = folderMenu
        vm.inboxFolderTree = { menu?.tree }
        vm.routeSavedAutomation = { id, destination, reread in
            guard let menu else { return "no menu" }
            if reread { await menu.reload() }
            return await menu.route(id, to: destination)
        }
        vm.refresh()
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    /// `route --json`'s pinned keys.
    nonisolated private static func routeJSON(revision: Int64) -> String {
        #"{"revision":\#(revision),"automation_id":1,"created":true,"folder":{"id":9,"kind":"owner","slug":"release","#
            + #""title":"Release","icon":"","parent_id":1,"position":1,"hidden":false,"automation_ids":[1]}}"#
    }

    nonisolated private static func failure(_ text: String) -> CLIRunnerError {
        .nonZeroExit(code: 1, stderr: text + "\n")
    }

    private var routeCalls: [[String]] { runner.invocations.filter { $0.first == "inbox" && $0[2] == "route" } }

    private var newRelease: InboxNewArtifactRoute {
        InboxNewArtifactRoute(newFolder: "Release", parentID: nil, parentTitle: "Inbox")
    }

    // MARK: - Columns (the shot fixtures' shapes)

    /// An edit that moved its hour (a known diff: a Changed row off What it collects).
    private func changedColumn() -> AutomationDraftColumnModel {
        column(isNew: false, changes: #"[{"field":"trigger","old":"{\"schedule\":\"0 8 * * 1-5\"}","#
            + #""new":"{\"schedule\":\"0 9 * * 1-5\"}"}]"#)
    }

    private func newRecipeColumn() -> AutomationDraftColumnModel {
        column(isNew: true, changes: "[]")
    }

    private func column(isNew: Bool, changes: String) -> AutomationDraftColumnModel {
        let text = "---\nname: Weekly mail roundup\n---\n"
        let json = #"{"ok":true,"errors":[],"slug":"weekly-mail","name":"Weekly mail roundup","scope":"personal","#
            + #""approval_hash":"h2","content_hash":"\#(AutomationDraftColumnModel.contentHash(text))","#
            + #""permissions":["gmail:read@work"],"outputs":["inbox"],"widening":[],"#
            + #""changes":\#(changes),"changes_known":\#(!isNew),"adds_llm":false,"#
            + #""fields":{"trigger":"schedule: 0 9 * * 1-5","missed":"skip","concurrency":"1","#
            + #""artifacts":"living","budget":{"tokens":20000,"minutes":5}}}"#
        let validated = try? JSONDecoder().decode(AutomationsCLI.ValidateResult.self, from: Data(json.utf8))
        return AutomationDraftColumnModel(text: text, validated: validated, isChecking: false, newestChatEntry: nil,
                                          confirmedText: isNew ? nil : text, isNew: isNew, plan: nil) { _ in nil }
    }

    // MARK: - The line

    func testChangedRowShowsNewFolderLineOnEveryStep() throws {
        let suggestion = AutomationFolderSuggestion(title: "Release", parentSlug: "acme")
        let line = try XCTUnwrap(vm.editorPlacement(suggestion: suggestion, draftContextID: nil)).placementText
        XCTAssertEqual(line, "New folder: Release, in Acme")
        for column in [changedColumn(), newRecipeColumn()] {
            for step in AutomationEditorStep.allCases {
                let row = try XCTUnwrap(column.confirmationRow(on: step, placement: line), "\(step)")
                XCTAssertEqual(row.placement, line, "\(step)")
                XCTAssertEqual(row.items, column.confirmationRow(on: step)?.items ?? [], "\(step): items unchanged")
            }
        }
    }

    func testChangedRowShowsExistingFolderLine() throws {
        // A fresh draft from the New flow, as `AutomationsView.continueNew` opens it.
        let flowRoute = InboxNewArtifactRoute(folderID: release, title: "Release")
        vm.showNew(AutomationNewFlow(route: flowRoute))
        vm.showEditor(.newDraft(contextID: "draft-a", scope: .personal, startText: nil), route: flowRoute)
        let placement = try XCTUnwrap(vm.editorPlacement(suggestion: nil, draftContextID: "draft-a"))
        XCTAssertEqual(placement.placementText, "Folder: Release")
        XCTAssertNil(vm.editorPlacement(suggestion: nil, draftContextID: nil), "an edit with no suggestion has none")
        let row = try XCTUnwrap(newRecipeColumn().confirmationRow(on: .look, placement: placement.placementText))
        XCTAssertEqual(row.placement, "Folder: Release")
        XCTAssertEqual(row.title, AutomationSaveConfirmationRow.valuesTitle)
    }

    func testSuggestionOverridesTheNewFlowFolder() throws {
        // A fresh draft from the New flow, as `AutomationsView.continueNew` opens it.
        let flowRoute = InboxNewArtifactRoute(folderID: release, title: "Release")
        vm.showNew(AutomationNewFlow(route: flowRoute))
        vm.showEditor(.newDraft(contextID: "draft-a", scope: .personal, startText: nil), route: flowRoute)
        let placement = vm.editorPlacement(suggestion: AutomationFolderSuggestion(title: "acme"),
                                           draftContextID: "draft-a")
        XCTAssertEqual(placement, InboxNewArtifactRoute(folderID: acme, title: "Acme"),
                       "the chat's newest word wins; an existing title is reused, ignoring case")
    }

    func testSuggestionResolvesAgainstTheTree() {
        let tree = folderMenu.tree
        XCTAssertEqual(AutomationFolderSuggestion(title: "Q4", parentSlug: "release").route(in: tree),
                       InboxNewArtifactRoute(newFolder: "Q4", parentID: release, parentTitle: "Release"))
        XCTAssertEqual(AutomationFolderSuggestion(title: "Q4", parentSlug: "gone").route(in: tree),
                       InboxNewArtifactRoute(newFolder: "Q4", parentID: nil, parentTitle: "Inbox"),
                       "an unknown parent is the root")
        XCTAssertEqual(AutomationFolderSuggestion(title: "Q4", parentSlug: "needs-approval").route(in: tree),
                       InboxNewArtifactRoute(newFolder: "Q4", parentID: nil, parentTitle: "Inbox"),
                       "no folder sits under Needs approval")
        XCTAssertEqual(AutomationFolderSuggestion(title: "Release", parentSlug: "acme").route(in: tree).placementText,
                       "New folder: Release, in Acme", "a title is reused only in its own parent")
        vm.inboxFolderTree = { nil }
        XCTAssertEqual(vm.editorPlacement(suggestion: AutomationFolderSuggestion(title: "Release"),
                                          draftContextID: nil)?.placementText,
                       "New folder: Release, in Inbox", "before the menu is read: the root alone")
    }

    func testPlacementIsNotAHashedItem() {
        for column in [changedColumn(), newRecipeColumn()] {
            for step in AutomationEditorStep.allCases {
                let with = column.confirmationRow(on: step, placement: "New folder: Release, in Inbox")
                let without = column.confirmationRow(on: step)
                XCTAssertEqual(with?.items ?? [], without?.items ?? [], "\(step)")
                XCTAssertEqual(with?.note, without?.note, "\(step)")
                XCTAssertFalse(column.changeMarks(on: step).contains { $0.contains("Release") }, "\(step)")
                XCTAssertFalse((with?.items ?? []).contains { $0.text.contains("Release") }, "\(step)")
            }
            XCTAssertFalse(column.hashedItems.contains { $0.text.contains("Release") })
        }
        // The press decision takes no placement at all: the same inputs give the same footer.
        XCTAssertEqual(AutomationDraftFooter.make(isNew: false, bytesChanged: true, enabled: true, needsConfirmation: false),
                       AutomationDraftFooter.make(isNew: false, bytesChanged: true, enabled: true, needsConfirmation: false))
    }

    func testRowShownForPlacementAlone() throws {
        let column = changedColumn()
        XCTAssertNil(column.confirmationRow(on: .collects), "a known diff's row is off What it collects")
        let row = try XCTUnwrap(column.confirmationRow(on: .collects, placement: "Folder: Release"))
        XCTAssertEqual(row.title, AutomationSaveConfirmationRow.changedTitle)
        XCTAssertTrue(row.items.isEmpty)
        XCTAssertNil(row.note)
        XCTAssertEqual(row.placement, "Folder: Release")
        XCTAssertNil(column.confirmationRow(on: .collects, placement: nil))
    }

    func testNoPlacementLineWhenNothingToSave() {
        typealias Footer = AutomationDraftFooter
        XCTAssertFalse(Footer.make(isNew: false, bytesChanged: false, enabled: true, needsConfirmation: false).pressSaves,
                       "No changes to save")
        XCTAssertFalse(Footer.make(isNew: false, bytesChanged: false, enabled: true, needsConfirmation: true).pressSaves,
                       "a confirm of unchanged bytes")
        XCTAssertFalse(Footer.make(isNew: false, bytesChanged: false, enabled: false, needsConfirmation: true).pressSaves)
        XCTAssertFalse(Footer.make(isNew: false, bytesChanged: false, enabled: true, needsConfirmation: false,
                                   isBuiltin: true).pressSaves)
        XCTAssertTrue(Footer.make(isNew: true, bytesChanged: true, enabled: false, needsConfirmation: false).pressSaves)
        XCTAssertTrue(Footer.make(isNew: false, bytesChanged: true, enabled: true, needsConfirmation: false).pressSaves)
        XCTAssertTrue(Footer.make(isNew: false, bytesChanged: true, enabled: true, needsConfirmation: false,
                                  isBuiltin: true).pressSaves)
        XCTAssertTrue(Footer.make(isNew: false, bytesChanged: true, enabled: true, needsConfirmation: false,
                                  showsAllFields: false).pressSaves, "still a save while it is checked")
    }

    // MARK: - The cache entry

    func testEntryCarriesTheSuggestionAndDropsAnUndecodableOne() throws {
        let base = #"{"recipe_text":"r","result":null,"error":"e","at":"2026-10-14T12:00:00Z""#
        let good = try JSONDecoder().decode(AutomationDraftEntry.self,
                                            from: Data((base + #","folder":{"title":" Release ","parent_slug":"acme"}}"#).utf8))
        XCTAssertEqual(good.folder, AutomationFolderSuggestion(title: "Release", parentSlug: "acme"))
        for folder in [#""Release""#, #"{"title":5}"#, #"{"title":"  "}"#, "[1]", "null"] {
            let entry = try JSONDecoder().decode(AutomationDraftEntry.self, from: Data((base + #","folder":"# + folder + "}").utf8))
            XCTAssertNil(entry.folder, folder)
            XCTAssertEqual(entry.recipeText, "r", "\(folder): the draft is kept")
            XCTAssertEqual(entry.error, "e")
        }
        let none = try JSONDecoder().decode(AutomationDraftEntry.self, from: Data((base + "}").utf8))
        XCTAssertNil(none.folder)
    }

    // MARK: - The route after a new draft's save

    func testSaveWithoutSuggestionMakesNoFolderCall() async {
        vm.showEditor(.newDraft(contextID: "draft-b", scope: .personal, startText: nil))
        vm.setPressRoute(vm.editorPlacement(suggestion: nil, draftContextID: "draft-b"), forDraft: "draft-b")
        await vm.draftSaved(contextID: "draft-b", conversationID: 77, automationID: automation)
        XCTAssertTrue(routeCalls.isEmpty)
    }

    func testNewDraftSaveCreatesTheSuggestedFolderOnce() async {
        vm.showEditor(.newDraft(contextID: "draft-c", scope: .personal, startText: nil))
        vm.setPressRoute(vm.editorPlacement(suggestion: AutomationFolderSuggestion(title: "Q4", parentSlug: "release"),
                                            draftContextID: "draft-c"), forDraft: "draft-c")
        await vm.draftSaved(contextID: "draft-c", conversationID: 77, automationID: automation)
        XCTAssertEqual(routeCalls, [[
            "inbox", "folders", "route", String(automation), "--new-title", "Q4", "--parent", String(release),
            "--expect-revision", "7", "--json"
        ]])
        XCTAssertNil(vm.routeFailures[automation])
    }

    func testDiscardedDraftForgetsItsPressRoute() async {
        vm.showEditor(.newDraft(contextID: "draft-d", scope: .personal, startText: nil))
        vm.setPressRoute(newRelease, forDraft: "draft-d")
        await vm.discardDraft(contextID: "draft-d")
        await vm.draftSaved(contextID: "draft-d", conversationID: 77, automationID: automation)
        XCTAssertTrue(routeCalls.isEmpty)
    }

    // MARK: - The route after a saved automation's save

    private func editorCenter() -> AutomationEditorCenter {
        AutomationEditorCenter(cli: AutomationsCLI(runner: runner), grants: { _ in [] }, refresh: { _ in },
                               sleep: { _ in })
    }

    /// Opens automation 7 in the editor, edits it and checks it: the plan a press saves.
    private func checkedEdit(_ center: AutomationEditorCenter) async throws -> AutomationSavePlan {
        runner.on("show") { _ in try AutomationEditFixtures.showJSON() }
        runner.on("validate") { _ in try AutomationEditFixtures.validateJSON(approval: "h2") }
        await center.beginEdit(7, chatNewestText: nil)
        center.drafts[7]?.fields.name = "Weekly digest"
        await center.check(7)
        guard case let .review(plan) = center.saving[7] else {
            XCTFail("no checked plan: \(String(describing: center.saving[7]))")
            throw CancellationError()
        }
        return plan
    }

    func testEditSaveRoutesOnceAfterItLanded() async throws {
        runner.on("save") { _ in
            Data(#"{"automation_id":7,"path":"/acme/automations/digest.md","approval_hash":"h2","confirmed":true}"#.utf8)
        }
        let center = editorCenter()
        let plan = try await checkedEdit(center)
        await center.commit(7, plan: plan, turnOn: false, setsEnabled: false)
        XCTAssertEqual(center.savedIDs[7], 7)
        await vm.routeEditorSave(center, key: 7, route: newRelease)
        XCTAssertEqual(routeCalls, [[
            "inbox", "folders", "route", "7", "--new-title", "Release", "--expect-revision", "7", "--json"
        ]])
        XCTAssertNil(vm.routeFailures[7])
    }

    func testRefusedSaveMakesNoFolderCall() async throws {
        runner.on("save") { _ in throw Self.failure("Error: not saved: approval hash does not match") }
        let center = editorCenter()
        let plan = try await checkedEdit(center)
        await center.commit(7, plan: plan, turnOn: false, setsEnabled: false)
        guard case .failed = center.saving[7] else { return XCTFail("the save was not refused") }
        await vm.routeEditorSave(center, key: 7, route: newRelease)
        XCTAssertTrue(routeCalls.isEmpty, "a refused save never makes the folder")
    }

    func testSaveWithoutPlacementMakesNoFolderCallOnAnEdit() async throws {
        runner.on("save") { _ in
            Data(#"{"automation_id":7,"path":"/acme/automations/digest.md","approval_hash":"h2","confirmed":true}"#.utf8)
        }
        let center = editorCenter()
        let plan = try await checkedEdit(center)
        await center.commit(7, plan: plan, turnOn: false, setsEnabled: false)
        await vm.routeEditorSave(center, key: 7, route: nil)
        XCTAssertTrue(routeCalls.isEmpty)
    }

    // MARK: - Failures

    func testRouteConflictShowsTryAgainRecipeStaysSaved() async {
        runner.on("route") { _ in throw Self.failure("the Inbox menu changed — reload it and try again (revision 8, you had 7)") }
        vm.setPressRoute(newRelease, forDraft: "draft-e")
        await vm.draftSaved(contextID: "draft-e", conversationID: 77, automationID: automation)
        XCTAssertEqual(vm.routeFailures[automation]?.reason, InboxFolderMenuModel.routeMenuChanged)
        XCTAssertEqual(vm.routeFailures[automation]?.route, newRelease)
        XCTAssertTrue(vm.items.contains { $0.id == automation }, "the recipe stays saved")
        XCTAssertFalse(runner.invocations.contains { $0.count > 1 && $0[1] == "save" }, "nothing is saved again")
    }

    func testTryAgainRereadsTheRevisionFirst() async throws {
        runner.on("route") { _ in throw Self.failure("the Inbox menu changed — reload it and try again (revision 8, you had 7)") }
        vm.setPressRoute(newRelease, forDraft: "draft-f")
        await vm.draftSaved(contextID: "draft-f", conversationID: 77, automationID: automation)
        try await pool.write { db in try db.execute(sql: "UPDATE inbox_folder_state SET revision = 12 WHERE id = 1") }
        runner.on("route") { _ in Data(Self.routeJSON(revision: 13).utf8) }
        await vm.retryRoute(automation)
        XCTAssertNil(vm.routeFailures[automation])
        XCTAssertEqual(routeCalls.last, [
            "inbox", "folders", "route", String(automation), "--new-title", "Release", "--expect-revision", "12", "--json"
        ], "the menu is read again before the second call")
    }

    func testTryAgainFailureUpdatesLine() async {
        runner.on("route") { _ in throw Self.failure("a folder named \"Release\" already exists here") }
        vm.setPressRoute(newRelease, forDraft: "draft-g")
        await vm.draftSaved(contextID: "draft-g", conversationID: 77, automationID: automation)
        XCTAssertEqual(vm.routeFailures[automation]?.reason, "a folder named \"Release\" already exists here")
        runner.on("route") { _ in throw Self.failure("folders nest at most 3 deep") }
        await vm.retryRoute(automation)
        XCTAssertEqual(vm.routeFailures[automation]?.reason, "folders nest at most 3 deep", "the newest reason")
        XCTAssertEqual(routeCalls.count, 2, "one call per press")
        XCTAssertFalse(runner.invocations.contains { $0.count > 1 && $0[1] == "save" }, "no second save")
        XCTAssertTrue(vm.items.contains { $0.id == automation }, "the recipe still saved")
    }

    func testMissingCLIAtTheRouteShowsTheLine() async {
        let menu = InboxFolderMenuModel(dbPool: pool) { nil }
        await menu.reload()
        vm.routeSavedAutomation = { id, destination, _ in await menu.route(id, to: destination) }
        vm.setPressRoute(newRelease, forDraft: "draft-h")
        await vm.draftSaved(contextID: "draft-h", conversationID: 77, automationID: automation)
        XCTAssertEqual(vm.routeFailures[automation]?.reason, "The watchtower CLI isn't available")
    }
}
