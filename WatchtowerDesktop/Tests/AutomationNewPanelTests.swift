import XCTest
import SwiftUI
import ViewInspector
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

/// The New automation panel (C3 Task 15): **Watch for something** is a
/// Personal start, and Continue on it opens the editor chat on a fresh
/// draft with the composer prefilled "Watch for ".
@MainActor
final class AutomationNewPanelTests: XCTestCase {
    private static let hooks = AutomationEditorChatHooks(
        scopes: [.personal], workspaceDir: "/acme", draftContextID: { _ in "draft-1" },
        makeNewChat: { _, _ in nil }, makeEditChat: { _ in nil },
        templatePanel: { _, _ in nil }, startTemplate: { _, _ in nil }
    )

    func testWatchTileOpensChatWithPrefill() throws {
        var continued: [AutomationStart] = []
        let panel = AutomationNewPanel(flow: AutomationNewFlow(), scopes: [.personal], templates: []) { _, start in
            continued.append(start)
        }
        XCTAssertNoThrow(try panel.inspect().find(text: "Watch for something"))
        XCTAssertNoThrow(try panel.inspect().find(text: "Describe it in words"))
        try panel.inspect().find(button: "Continue").tap()
        XCTAssertEqual(continued, [.words], "Describe it in words stays the default")

        let workbench = AutomationScopeChoice.workbench(id: 4, name: "acme", folder: "/acme")
        let fixed = AutomationNewPanel(flow: AutomationNewFlow(fixedScope: workbench), scopes: [workbench],
                                       templates: []) { _, _ in }
        XCTAssertThrowsError(try fixed.inspect().find(text: "Watch for something"), "a watch is Personal only")

        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let vm = AutomationsViewModel(dbPool: pool, cli: AutomationsCLI(runner: FakeCLIRunner()))

        AutomationsView.continueNew(AutomationNewFlow(), scope: .personal, start: .watch, vm: vm, hooks: Self.hooks)

        XCTAssertEqual(vm.panel, .editor(.newDraft(contextID: "draft-1", scope: .personal, startText: nil)))
        XCTAssertEqual(vm.composerPrefill, "Watch for ")
    }

    /// Continue in a New flow from an Inbox folder: the fresh draft it
    /// starts carries the folder, for words and watch alike.
    func testContinueCarriesTheFlowsRouteToItsFreshDraft() throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let vm = AutomationsViewModel(dbPool: pool, cli: AutomationsCLI(runner: FakeCLIRunner()))
        let route = InboxNewArtifactRoute(folderID: 3, title: "Release")

        AutomationsView.continueNew(AutomationNewFlow(route: route), scope: .personal, start: .words, vm: vm,
                                    hooks: Self.hooks)

        XCTAssertEqual(vm.newDraftRoutes, ["draft-1": route])
    }

    /// Continue on a template in that flow: the template panel keeps the folder.
    func testContinueOnATemplateKeepsTheFlowsRoute() throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let cli = AutomationsCLI(runner: FakeCLIRunner())
        let vm = AutomationsViewModel(dbPool: pool, cli: cli)
        let json = #"{"name":"jira-state-report","title":"Jira state report","description":"Weekly.","#
            + #""scope":"personal","trigger_text":"Mondays 09:00","permissions":[],"outputs":[],"params":[]}"#
        let template = try JSONDecoder().decode(AutomationTemplate.self, from: Data(json.utf8))
        let model = AutomationTemplatePanelModel(template: template, scope: .personal, cli: cli) { _ in }
        let hooks = AutomationEditorChatHooks(
            scopes: [.personal], workspaceDir: "/acme", draftContextID: { _ in "draft-1" },
            makeNewChat: { _, _ in nil }, makeEditChat: { _ in nil },
            templatePanel: { _, _ in model }, startTemplate: { _, _ in model })
        let route = InboxNewArtifactRoute(folderID: 3, title: "Release")

        AutomationsView.continueNew(AutomationNewFlow(route: route), scope: .personal,
                                    start: .template("jira-state-report"), vm: vm, hooks: hooks)

        XCTAssertEqual(vm.templateRoute(name: "jira-state-report", scope: .personal), route)
    }
}
