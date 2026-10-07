import AppKit
import GRDB
import WatchtowerCore
import XCTest
@testable import WatchtowerDesktop

/// Ruling R34: quitting the app stops every `code search` the
/// code-navigation centers run — Open Quickly's Text scope, go to
/// definition's text-search heuristic and Usages — like the index children:
/// each runs in a process group of its own, so none may outlive the app.
@MainActor
final class CodeNavQuitTests: XCTestCase {
    private var stub: CodeCLIStub!
    private var folder: URL!
    private var project: Workbench!

    override func setUpWithError() throws {
        stub = try CodeCLIStub()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("nav-quit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        project = Workbench(row: Row(["id": 3, "name": "acme", "folder_path": folder.path]))
    }

    override func tearDown() async throws {
        // A failing test leaves no stub behind either.
        await stub.assertAllGroupsReaped()
        stub.remove()
        try? FileManager.default.removeItem(at: folder)
    }

    private func stubStarter() -> CodeSearchStarter {
        let executable = stub.executable.path
        let environment = stub.environment()
        return { folder, options, onMatch, onDone in
            CodeSearchRun.start(
                folder: folder, options: options, executable: executable, environment: environment,
                onMatch: onMatch, onDone: onDone
            )
        }
    }

    private func searchesStarted(_ count: Int) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if stub.startedPIDs.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    func testQuitStopsTheSearchesOfOpenQuicklyDefinitionAndUsages() async {
        let codeIndex = CodeIndexCenter(resolveExecutable: { nil }, rulesFile: CodeIndexCenter.testRulesFile)
        let openQuickly = OpenQuicklyCenter(codeIndex: codeIndex, presenter: SilentPresenter(), startSearch: stubStarter())
        let navigation = CodeNavigationCenter(codeIndex: codeIndex, startSearch: stubStarter()) {}
        let suite = "CodeNavQuitTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        let usages = CodeUsagesCenter(defaults: defaults, startSearch: stubStarter()) {}

        usages.showUsages(of: "save", project: project)
        // A file the index has not seen: the heuristic's text search runs.
        let request = CodeDefinitionRequest(req: 1, word: "save", origin: CodeNavLocation(path: "a.pl", line: 1, col: 1))
        let definition = Task { await navigation.goToDefinition(request, project: project, anchor: nil) }
        openQuickly.pageAppeared(project, window: nil)
        openQuickly.present(scope: .text)
        openQuickly.session?.updateQuery("save")
        let started = await searchesStarted(3)
        XCTAssertTrue(started, "three searches running: \(stub.startedPIDs)")

        AppState.stopCodeNavigationChildren(index: codeIndex, openQuickly: openQuickly, navigation: navigation, usages: usages,
                                            questions: CodeQuestionCenter())

        await stub.assertAllGroupsReaped()
        await definition.value
        XCTAssertEqual(usages.usages(for: project.id)?.status, .stopped, "the list keeps what it found")
    }
}

private final class SilentPresenter: OpenQuicklyPresenting {
    func presentPanel(_ session: OpenQuicklySession, center: OpenQuicklyCenter, over window: NSWindow?) {}
    func dismissPanel(restoringFocus: Bool) {}
}
