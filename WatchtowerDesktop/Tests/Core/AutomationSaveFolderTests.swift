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
    private var defaults: UserDefaults!

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
        defaults = UserDefaults(suiteName: "AutomationSaveFolderTests.\(UUID().uuidString)") ?? .standard
        vm = AutomationsViewModel(dbPool: pool, cli: AutomationsCLI(runner: runner), defaults: defaults)
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

    /// A folder the route makes (none of that title in the tree yet).
    private var newLaunch: InboxNewArtifactRoute {
        InboxNewArtifactRoute(newFolder: "Launch", parentID: nil, parentTitle: "Inbox")
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

    /// Before the menu's first read the line shows nothing: resolved against
    /// the root-only placeholder, an existing folder would read "New folder".
    func testNoFolderLineBeforeTheMenusFirstRead() throws {
        let unread = InboxFolderMenuModel(dbPool: pool) { nil }
        XCTAssertNil(unread.readTree)
        vm.inboxFolderTree = { unread.readTree }
        XCTAssertNil(vm.editorPlacement(suggestion: AutomationFolderSuggestion(title: "release"), draftContextID: nil))
        XCTAssertNotNil(folderMenu.readTree, "a read menu has its tree")
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

    /// The tree as read, with automation `automation` routed to `folder`.
    private func treeRouting(to folder: Int64) -> InboxFolderTree {
        InboxFolderTree(revision: folderMenu.tree.revision, folders: folderMenu.tree.folders,
                        routes: [automation: folder])
    }

    /// A suggestion an earlier save already carried out is spent: moved
    /// elsewhere since by the owner, the automation is never moved back by a
    /// later save with no new `draft_automation` — not after a restart either.
    /// A new entry asking for the same folder counts again.
    func testSpentSuggestionNeverMovesTheAutomationBack() async throws {
        let suggestion = AutomationFolderSuggestion(title: "Release")
        let entry = "2026-10-14T12:00:00Z:c1"
        let shown = vm.editorPlacement(suggestion: suggestion, draftContextID: nil, automationID: automation,
                                       suggestionKey: entry)
        XCTAssertEqual(shown, InboxNewArtifactRoute(folderID: release, title: "Release"))
        await vm.routeEditorSave(key: automation, landed: automation, draftContextID: nil, editor: editorCenter(),
                                 route: shown, spending: entry)
        XCTAssertEqual(routeCalls.count, 1)

        let acme = acme
        vm.inboxFolderTree = { [weak self] in self?.treeRouting(to: acme) }
        XCTAssertNil(vm.editorPlacement(suggestion: suggestion, draftContextID: nil, automationID: automation,
                                        suggestionKey: entry), "the owner's move stands")
        let restarted = AutomationsViewModel(dbPool: pool, cli: AutomationsCLI(runner: runner), defaults: defaults)
        restarted.inboxFolderTree = vm.inboxFolderTree
        XCTAssertNil(restarted.editorPlacement(suggestion: suggestion, draftContextID: nil, automationID: automation,
                                               suggestionKey: entry), "spent across a restart")
        XCTAssertEqual(vm.editorPlacement(suggestion: suggestion, draftContextID: nil, automationID: automation,
                                          suggestionKey: "2026-10-20T09:00:00Z:c2"),
                       InboxNewArtifactRoute(folderID: release, title: "Release"), "a new ask counts")
    }

    /// A suggestion whose line was hidden because the automation already
    /// sits in that folder is spent by the save all the same: after the
    /// owner's Move to Folder, a later save with no new `draft_automation`
    /// never moves it back.
    func testSuggestionAlreadyCarriedOutIsSpentBySave() async throws {
        let suggestion = AutomationFolderSuggestion(title: "Release")
        let entry = "2026-10-14T12:00:00Z:c1"
        let release = release
        vm.inboxFolderTree = { [weak self] in self?.treeRouting(to: release) }
        let shown = vm.editorPlacement(suggestion: suggestion, draftContextID: nil, automationID: automation,
                                       suggestionKey: entry)
        XCTAssertNil(shown, "already there: no line")
        let spending = AutomationsViewModel.suggestionSpentBySave(saves: true, suggestion: suggestion,
                                                                  suggestionKey: entry)
        XCTAssertEqual(spending, entry)
        await vm.routeEditorSave(key: automation, landed: automation, draftContextID: nil, editor: editorCenter(),
                                 route: shown, spending: spending)
        XCTAssertTrue(routeCalls.isEmpty)

        let acme = acme
        vm.inboxFolderTree = { [weak self] in self?.treeRouting(to: acme) }
        XCTAssertNil(vm.editorPlacement(suggestion: suggestion, draftContextID: nil, automationID: automation,
                                        suggestionKey: entry), "the owner's move stands")
        await vm.routeEditorSave(key: automation, landed: automation, draftContextID: nil, editor: editorCenter(),
                                 route: nil, spending: nil)
        XCTAssertTrue(routeCalls.isEmpty, "the next save never moves it back")
    }

    /// The spent store is shared defaults: the same automation id in two
    /// workspaces keeps its own entry, so one never overwrites the other's.
    func testSpentSuggestionsAreKeptPerWorkspace() async throws {
        let suggestion = AutomationFolderSuggestion(title: "Release")
        let workspaceA = AutomationsViewModel(dbPool: pool, cli: AutomationsCLI(runner: runner), defaults: defaults,
                                              workspace: "/acme/a")
        let workspaceB = AutomationsViewModel(dbPool: pool, cli: AutomationsCLI(runner: runner), defaults: defaults,
                                              workspace: "/acme/b")
        for model in [workspaceA, workspaceB] {
            model.inboxFolderTree = vm.inboxFolderTree
            model.routeSavedAutomation = vm.routeSavedAutomation
            model.refresh()
        }
        await workspaceA.routeEditorSave(key: automation, landed: automation, draftContextID: nil,
                                         editor: editorCenter(), route: nil, spending: "entry-a")
        XCTAssertNotNil(workspaceB.editorPlacement(suggestion: suggestion, draftContextID: nil,
                                                   automationID: automation, suggestionKey: "entry-a"),
                        "workspace B never spent entry A")
        await workspaceB.routeEditorSave(key: automation, landed: automation, draftContextID: nil,
                                         editor: editorCenter(), route: nil, spending: "entry-b")
        XCTAssertNil(workspaceA.editorPlacement(suggestion: suggestion, draftContextID: nil,
                                                automationID: automation, suggestionKey: "entry-a"),
                     "B's save kept A's entry")
        XCTAssertNil(workspaceB.editorPlacement(suggestion: suggestion, draftContextID: nil,
                                                automationID: automation, suggestionKey: "entry-b"))
    }

    /// Writing the store drops this workspace's entries for automations
    /// that are gone; another workspace's entries stay.
    func testSpendingPrunesRemovedAutomations() async throws {
        let gone = try await pool.write { db in
            try TestDatabase.insertAutomation(db, slug: "gone", name: "Gone")
        }
        let editor = editorCenter()
        let other = AutomationsViewModel(dbPool: pool, cli: AutomationsCLI(runner: runner), defaults: defaults,
                                         workspace: "/acme/other")
        other.refresh()
        await other.routeEditorSave(key: gone, landed: gone, draftContextID: nil, editor: editor, route: nil,
                                    spending: "other")
        vm.refresh()
        await vm.routeEditorSave(key: gone, landed: gone, draftContextID: nil, editor: editor, route: nil,
                                 spending: "gone")
        try await pool.write { db in
            try db.execute(sql: "UPDATE automations SET removed_at = '2026-10-20T09:00:00Z' WHERE id = ?",
                           arguments: [gone])
        }
        vm.refresh()
        await vm.routeEditorSave(key: automation, landed: automation, draftContextID: nil, editor: editor,
                                 route: nil, spending: "kept")
        let stored = defaults.dictionary(forKey: AutomationsViewModel.spentSuggestionsKey) as? [String: String] ?? [:]
        XCTAssertEqual(Set(stored.values), ["kept", "other"], "the removed automation's entry went: \(stored)")
    }

    /// Only a press that saves spends, and only an entry that names a folder.
    func testOnlyASavingPressWithAFolderSpends() {
        let suggestion = AutomationFolderSuggestion(title: "Release")
        XCTAssertNil(AutomationsViewModel.suggestionSpentBySave(saves: false, suggestion: suggestion,
                                                                suggestionKey: "k"))
        XCTAssertNil(AutomationsViewModel.suggestionSpentBySave(saves: true, suggestion: nil, suggestionKey: "k"))
        XCTAssertNil(AutomationsViewModel.suggestionSpentBySave(saves: true, suggestion: suggestion,
                                                                suggestionKey: nil))
    }

    func testNoLineWhenAlreadyInThatFolder() {
        let release = release
        vm.inboxFolderTree = { [weak self] in self?.treeRouting(to: release) }
        XCTAssertNil(vm.editorPlacement(suggestion: AutomationFolderSuggestion(title: "release"), draftContextID: nil,
                                        automationID: automation, suggestionKey: "k"))
        XCTAssertNotNil(vm.editorPlacement(suggestion: AutomationFolderSuggestion(title: "Acme"), draftContextID: nil,
                                           automationID: automation, suggestionKey: "k"))
    }

    /// Go keeps the `needs-approval` built-in in Needs approval (its route
    /// is refused): its editor shows no folder line, like its ⋯ has no Move.
    func testNoLineForTheNeedsApprovalBuiltin() async throws {
        let slug = InboxFolderQueries.needsApprovalBuiltinID
        let id = try await pool.write { db in
            let id = try TestDatabase.insertAutomation(db, slug: slug, name: slug, triggerKind: "sync",
                                                       triggerSpec: #"{"sync":"x"}"#)
            try db.execute(sql: "UPDATE automations SET origin = 'builtin', builtin_id = ?, path = ? WHERE id = ?",
                           arguments: [slug, "builtin:\(slug)", id])
            return id
        }
        vm.refresh()
        XCTAssertNil(vm.editorPlacement(suggestion: AutomationFolderSuggestion(title: "Release"), draftContextID: nil,
                                        automationID: id, suggestionKey: "k"))
        XCTAssertNotNil(vm.editorPlacement(suggestion: AutomationFolderSuggestion(title: "Release"),
                                           draftContextID: nil, automationID: automation, suggestionKey: "k"))
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
        XCTAssertNil(vm.editorPlacement(suggestion: AutomationFolderSuggestion(title: "Release"), draftContextID: nil),
                     "before the menu is read: no line (the root alone would call Release a new folder)")
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
        XCTAssertFalse(Footer.make(isNew: false, bytesChanged: true, enabled: true, needsConfirmation: false,
                                   showsAllFields: false).pressSaves, "can't show everything: the save is off")
        XCTAssertFalse(Footer.make(isNew: true, bytesChanged: true, enabled: false, needsConfirmation: false,
                                   showsAllFields: false, hasErrors: true).pressSaves, "has errors: the save is off")
        XCTAssertFalse(Footer.make(isNew: false, bytesChanged: true, enabled: true, needsConfirmation: false,
                                   showsAllFields: false, hasErrors: true, isBuiltin: true).pressSaves)
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
        vm.setPressRoute(newLaunch, forDraft: "draft-d")
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
        let landed = await center.commit(7, plan: plan, turnOn: false, setsEnabled: false)
        XCTAssertEqual(landed, 7)
        await vm.routeEditorSave(key: 7, landed: landed, draftContextID: nil, editor: center, route: newLaunch)
        XCTAssertEqual(routeCalls, [[
            "inbox", "folders", "route", "7", "--new-title", "Launch", "--expect-revision", "7", "--json"
        ]])
        XCTAssertNil(vm.routeFailures[7])
    }

    func testRefusedSaveMakesNoFolderCall() async throws {
        runner.on("save") { _ in throw Self.failure("Error: not saved: approval hash does not match") }
        let center = editorCenter()
        let plan = try await checkedEdit(center)
        let landed = await center.commit(7, plan: plan, turnOn: false, setsEnabled: false)
        guard case .failed = center.saving[7] else { return XCTFail("the save was not refused") }
        await vm.routeEditorSave(key: 7, landed: landed, draftContextID: nil, editor: center, route: newLaunch)
        XCTAssertTrue(routeCalls.isEmpty, "a refused save never makes the folder")
    }

    /// A save that landed but did not turn on keeps `savedIDs`; the next
    /// press's refused save must still send nothing (spec: never after a
    /// refused save).
    func testRefusedSaveAfterALandedSaveMakesNoFolderCall() async throws {
        runner.on("save") { _ in
            Data(#"{"automation_id":7,"path":"/acme/automations/digest.md","approval_hash":"h2","confirmed":true}"#.utf8)
        }
        runner.on("enable") { _ in throw Self.failure("Error: config locked") }
        let center = editorCenter()
        var plan = try await checkedEdit(center)
        let first = await center.commit(7, plan: plan, turnOn: true)
        guard case .failed = center.saving[7] else { return XCTFail("the turn-on did not fail") }
        await vm.routeEditorSave(key: 7, landed: first, draftContextID: nil, editor: center, route: newLaunch)
        XCTAssertEqual(routeCalls.count, 1, "the save landed: its route goes")

        runner.on("save") { _ in throw Self.failure("Error: not saved: the recipe changed on disk") }
        plan = try await checkedEdit(center)
        let second = await center.commit(7, plan: plan, turnOn: false, setsEnabled: false)
        XCTAssertNil(second)
        await vm.routeEditorSave(key: 7, landed: second, draftContextID: nil, editor: center, route: newLaunch)
        XCTAssertEqual(routeCalls.count, 1, "a refused save never routes, whatever an earlier save left")
    }

    /// A new draft's **Save and Turn On** whose save landed but whose
    /// turn-on failed is saved: its folder route goes at once, so a panel
    /// closed while it shows the failure never loses it — and the later
    /// `draftSaved` sends no second one.
    func testNewDraftSavedButNotTurnedOnStillRoutes() async throws {
        let automation = automation
        runner.on("validate") { _ in try AutomationEditFixtures.validateJSON(approval: "hn") }
        runner.on("save") { _ in
            Data((#"{"automation_id":\#(automation),"path":"/acme/automations/digest.md","#
                + #""approval_hash":"hn","confirmed":true}"#).utf8)
        }
        runner.on("enable") { _ in throw Self.failure("Error: config locked") }
        let center = editorCenter()
        let key = AutomationEditorCenter.newDraftKey(conversationID: 77)
        center.beginNew(key: key, scope: .personal, recipeDir: "/acme/automations", startText: nil)
        center.drafts[key]?.fields.name = "Digest"
        await center.check(key)
        guard case let .review(plan) = center.saving[key] else { return XCTFail("no checked plan") }
        vm.showEditor(.newDraft(contextID: "draft-i", scope: .personal, startText: nil),
                      route: InboxNewArtifactRoute(folderID: release, title: "Release"))
        vm.setPressRoute(nil, forDraft: "draft-i")

        let landed = await center.commit(key, plan: plan, turnOn: true)
        XCTAssertEqual(landed, automation)
        guard case .failed = center.saving[key] else { return XCTFail("the turn-on did not fail") }
        await vm.routeEditorSave(key: key, landed: landed, draftContextID: "draft-i", editor: center, route: nil)
        XCTAssertEqual(routeCalls, [[
            "inbox", "folders", "route", String(automation), "--folder", String(release), "--expect-revision", "7", "--json"
        ]])

        XCTAssertNil(center.settleUnwatched(key), "the panel closed while it showed the failure")
        await vm.draftSaved(contextID: "draft-i", conversationID: 77, automationID: automation)
        XCTAssertEqual(routeCalls.count, 1, "routed once")
    }

    func testSaveWithoutPlacementMakesNoFolderCallOnAnEdit() async throws {
        runner.on("save") { _ in
            Data(#"{"automation_id":7,"path":"/acme/automations/digest.md","approval_hash":"h2","confirmed":true}"#.utf8)
        }
        let center = editorCenter()
        let plan = try await checkedEdit(center)
        let landed = await center.commit(7, plan: plan, turnOn: false, setsEnabled: false)
        await vm.routeEditorSave(key: 7, landed: landed, draftContextID: nil, editor: center, route: nil)
        XCTAssertTrue(routeCalls.isEmpty)
    }

    // MARK: - Failures

    func testRouteConflictShowsTryAgainRecipeStaysSaved() async {
        runner.on("route") { _ in throw Self.failure("the Inbox menu changed — reload it and try again (revision 8, you had 7)") }
        vm.setPressRoute(newLaunch, forDraft: "draft-e")
        await vm.draftSaved(contextID: "draft-e", conversationID: 77, automationID: automation)
        XCTAssertEqual(vm.routeFailures[automation]?.reason, InboxFolderMenuModel.routeMenuChanged)
        XCTAssertEqual(vm.routeFailures[automation]?.route, newLaunch)
        XCTAssertTrue(vm.items.contains { $0.id == automation }, "the recipe stays saved")
        XCTAssertFalse(runner.invocations.contains { $0.count > 1 && $0[1] == "save" }, "nothing is saved again")
    }

    func testTryAgainRereadsTheRevisionFirst() async throws {
        runner.on("route") { _ in throw Self.failure("the Inbox menu changed — reload it and try again (revision 8, you had 7)") }
        vm.setPressRoute(newLaunch, forDraft: "draft-f")
        await vm.draftSaved(contextID: "draft-f", conversationID: 77, automationID: automation)
        try await pool.write { db in try db.execute(sql: "UPDATE inbox_folder_state SET revision = 12 WHERE id = 1") }
        runner.on("route") { _ in Data(Self.routeJSON(revision: 13).utf8) }
        await vm.retryRoute(automation)
        XCTAssertNil(vm.routeFailures[automation])
        XCTAssertEqual(routeCalls.last, [
            "inbox", "folders", "route", String(automation), "--new-title", "Launch", "--expect-revision", "12", "--json"
        ], "the menu is read again before the second call")
    }

    /// The folder the line named was made meanwhile (say, from the Inbox
    /// menu): Try Again reuses it from the re-read tree instead of asking
    /// for a duplicate.
    func testTryAgainReusesAFolderMadeMeanwhile() async throws {
        runner.on("route") { _ in throw Self.failure("the Inbox menu changed — reload it and try again (revision 8, you had 7)") }
        vm.setPressRoute(newLaunch, forDraft: "draft-j")
        await vm.draftSaved(contextID: "draft-j", conversationID: 77, automationID: automation)
        let root = root
        let launch = try await pool.write { db in
            try db.execute(sql: "UPDATE inbox_folder_state SET revision = 12 WHERE id = 1")
            return try InboxFolderFixtures.folder(db, parent: root, slug: "launch", title: "launch", position: 3)
        }
        runner.on("route") { _ in Data(Self.routeJSON(revision: 13).utf8) }
        await vm.retryRoute(automation)
        XCTAssertNil(vm.routeFailures[automation])
        XCTAssertEqual(routeCalls.last, [
            "inbox", "folders", "route", String(automation), "--folder", String(launch), "--expect-revision", "12", "--json"
        ])
    }

    func testTryAgainFailureUpdatesLine() async {
        runner.on("route") { _ in throw Self.failure("a folder named \"Release\" already exists here") }
        vm.setPressRoute(newLaunch, forDraft: "draft-g")
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
        vm.setPressRoute(newLaunch, forDraft: "draft-h")
        await vm.draftSaved(contextID: "draft-h", conversationID: 77, automationID: automation)
        XCTAssertEqual(vm.routeFailures[automation]?.reason, "The watchtower CLI isn't available")
    }
}
