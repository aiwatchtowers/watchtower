import XCTest
import SwiftUI
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// ⌃⌘R opens the one root-level "Run Automation…" palette from every tab
/// and window, and ⌘K keeps its per-tab meanings (owner ruling 2026-10-15).
@MainActor
final class RunAutomationShortcutTests: XCTestCase {
    /// An app past onboarding (the automations view model and the quick-run
    /// center built); `body` runs synchronously, as in
    /// `SidebarAutomationsVisibilityTests`, so no background read outlives the database.
    private func withAppState(_ body: (AppState) throws -> Void) throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let suite = "RunAutomationShortcutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let features = FeatureManagerService(runner: FakeCLIRunner(stdout: Data(#"{"features":[]}"#.utf8)))
        let appState = AppState(onboardingDefaults: defaults, featureManager: features)
        appState.wireAppDatabaseOverride = { _ in }
        appState.databaseManager = manager
        appState.completeOnboarding()
        defer { appState.automationsViewModel?.stop() }
        try body(appState)
    }

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")

    /// Every Swift file under `Sources/`, by path relative to it.
    private static func swiftSources() throws -> [(path: String, text: String)] {
        let root = sources.standardizedFileURL.path
        let walker = try XCTUnwrap(FileManager.default.enumerator(atPath: root))
        var out: [(String, String)] = []
        while let rel = walker.nextObject() as? String {
            guard rel.hasSuffix(".swift") else { continue }
            out.append((rel, try String(contentsOfFile: root + "/" + rel, encoding: .utf8)))
        }
        XCTAssertGreaterThan(out.count, 100, "the scan reads the app's sources")
        return out
    }

    func testShortcutOpensSamePaletteFromWorkbenchChatAndAnotherTab() throws {
        try withAppState { appState in
            XCTAssertNotNil(appState.quickRunCenter, "built with the automations view model")
            for tab: SidebarDestination in [.workbench, .chat, .catchUp] {
                appState.selectedDestination = tab
                appState.isRunAutomationPaletteShown = false
                appState.showRunAutomationPalette(windows: []) {}
                XCTAssertTrue(appState.isRunAutomationPaletteShown, "\(tab)")
                XCTAssertEqual(appState.selectedDestination, tab, "the palette opens over the tab, not instead of it")
            }
        }
        // One palette, hosted at the root above every destination: no tab builds its own.
        let files = try Self.swiftSources()
        let builders = files.filter { $0.text.contains("RunAutomationPalette(center:") }.map(\.path)
        XCTAssertEqual(builders, ["Views/Automations/RunAutomationPalette.swift"])
        let hosts = files.filter { $0.text.contains("RunAutomationPaletteHost(appState:") }.map(\.path)
        XCTAssertEqual(hosts, ["App/WatchtowerApp.swift"])
        let navigation = try XCTUnwrap(files.first { $0.path == "App/Navigation.swift" }).text
        XCTAssertFalse(navigation.contains("RunAutomation"), "no per-destination branch")
    }

    func testPaletteRefusedWhenFeatureOff() throws {
        try withAppState { appState in
            appState.featureVisibility.disabledFeatureIDs = ["automations"]
            appState.showRunAutomationPalette(windows: []) {}
            XCTAssertFalse(appState.isRunAutomationPaletteShown)
        }
    }

    func testCommandKUnchangedOnWorkbenchAndChat() throws {
        let files = try Self.swiftSources()
        let commandK = files.filter { $0.text.contains(#".keyboardShortcut("k", modifiers: .command)"#) }
        XCTAssertEqual(commandK.map(\.path).sorted(), ["Views/Chat/ChatView.swift", "Views/Workbench/WorkbenchesView.swift"])
        let workbench = try XCTUnwrap(commandK.first { $0.path.hasSuffix("WorkbenchesView.swift") }).text
        XCTAssertTrue(workbench.contains(#".help("Go to… (⌘K)")"#))
        let chat = try XCTUnwrap(commandK.first { $0.path.hasSuffix("ChatView.swift") }).text
        XCTAssertTrue(chat.contains(#".help("Search Chats (⌘K)")"#))
        // The Go to… palette lists sessions and workbenches only: no automation rows.
        for name in ["WatchtowerCore/Services/GoToRanking.swift", "Views/Workbench/GoToPalette.swift"] {
            let text = try XCTUnwrap(files.first { $0.path == name }, name).text
            XCTAssertFalse(text.localizedCaseInsensitiveContains("automation"), name)
        }
        XCTAssertEqual(GoToRanking.results(query: "", current: nil, sessions: [], workbenches: []), [])
    }

    func testShortcutUnusedElsewhere() throws {
        let files = try Self.swiftSources()
        // A literal ⌃⌘R shortcut anywhere: the menu item reads RunAutomationCommand instead.
        let literal = try NSRegularExpression(
            pattern: #"keyboardShortcut\(\s*"r"\s*,\s*modifiers:\s*\[\s*\.(control|command)\s*,\s*\.(control|command)\s*\]"#)
        for file in files {
            let range = NSRange(file.text.startIndex..., in: file.text)
            XCTAssertNil(literal.firstMatch(in: file.text, range: range), file.path)
        }
        let definitions = files.filter {
            $0.text.contains(#"static let key: Character = "r""#)
                && $0.text.contains("static let modifiers: EventModifiers = [.control, .command]")
        }
        XCTAssertEqual(definitions.map(\.path), ["App/RunAutomationCommand.swift"])
        let uses = files.filter { $0.text.contains("KeyEquivalent(RunAutomationCommand.key)") }
        XCTAssertEqual(uses.map(\.path), ["App/WatchtowerApp.swift"], "the one menu item")
        let app = try XCTUnwrap(uses.first).text
        XCTAssertEqual(app.components(separatedBy: "KeyEquivalent(RunAutomationCommand.key)").count, 2)
    }

    func testOpensMainWindowWhenNoneVisible() throws {
        try withAppState { appState in
            var opened = 0
            var activated = 0
            appState.openMainWindow = { opened += 1 }
            appState.showRunAutomationPalette(windows: []) { activated += 1 }
            XCTAssertEqual(opened, 1, "the Settings window or tray mode: a main window opens first")
            XCTAssertEqual(activated, 1)
            XCTAssertTrue(appState.isRunAutomationPaletteShown)
        }
    }
}
