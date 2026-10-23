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
}
