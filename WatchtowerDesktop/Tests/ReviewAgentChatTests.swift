import AppKit
import ChatUI
import SwiftUI
import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerChatText
import WatchtowerCore
import WatchtowerTestSupport

/// Branch review's agent chat (#962): the session's ask drawer opens in the
/// review only when neither its terminal nor its Workchat is on screen, so
/// an ask card tapped in the panel always shows its drawer, and never twice.
@MainActor
final class ReviewAgentChatTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!

    nonisolated private static let questions = #"{"questions":[{"id":"a","question":"Flag?","options":[{"label":"Yes"},{"label":"No"}]}]}"#

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "ReviewAgentChatTests-\(UUID().uuidString)"))
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    func testReviewHostsTheAskDrawerOnlyWithoutTheSessionsPanes() async throws {
        let (projectID, sessionID, askID) = try await pool.write { d in
            let p = try TestDatabase.insertWorkbench(d, folder: "/tmp/acme")
            let s = try TerminalSessionQueries.create(d, .init(projectID: p, kind: .shell, title: "zsh", folderPath: "/tmp/acme"))
            let ask = try TestDatabase.insertOwnerAsk(d, projectID: p, sessionID: s.id, payload: Self.questions)
            return (p, s.id, ask)
        }
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults)
        await vm.asks.load(projectID: projectID)
        let ask = try XCTUnwrap(vm.asks.openAsks[projectID]?.first { $0.id == askID })
        let chat = ReviewAgentChat(vm: vm, projectID: projectID, sessionID: sessionID)

        // Branch review alone: the card's drawer opens in the review.
        var layout = WorkspaceLayout.default
        layout.primary = .changes(sessionID)
        layout.secondary = nil
        vm.setLayout(layout, projectID: projectID)
        vm.asks.openDrawer(ask)
        XCTAssertEqual(chat.drawerAsk?.id, askID)

        // Its Workchat beside the review hosts it instead: one drawer.
        layout.secondary = .sessionChat(sessionID)
        vm.setLayout(layout, projectID: projectID)
        vm.asks.openDrawer(ask)
        XCTAssertNotNil(vm.asks.drawerAsk(projectID: projectID))
        XCTAssertNil(chat.drawerAsk)

        // So does its terminal.
        layout.secondary = .session(sessionID)
        vm.setLayout(layout, projectID: projectID)
        vm.asks.openDrawer(ask)
        XCTAssertNil(chat.drawerAsk)
    }

    /// Another session's ask never opens in this review.
    func testAnotherSessionsAskIsNotHostedHere() async throws {
        let (projectID, sessionID, askID) = try await pool.write { d in
            let p = try TestDatabase.insertWorkbench(d, folder: "/tmp/acme")
            let s = try TerminalSessionQueries.create(d, .init(projectID: p, kind: .shell, title: "zsh", folderPath: "/tmp/acme"))
            let other = try TerminalSessionQueries.create(d, .init(projectID: p, kind: .shell, title: "zsh 2", folderPath: "/tmp/acme"))
            let ask = try TestDatabase.insertOwnerAsk(d, projectID: p, sessionID: other.id, payload: Self.questions)
            return (p, s.id, ask)
        }
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults)
        await vm.asks.load(projectID: projectID)
        var layout = WorkspaceLayout.default
        layout.primary = .changes(sessionID)
        layout.secondary = nil
        vm.setLayout(layout, projectID: projectID)
        vm.asks.openDrawer(try XCTUnwrap(vm.asks.openAsks[projectID]?.first { $0.id == askID }))
        XCTAssertNil(ReviewAgentChat(vm: vm, projectID: projectID, sessionID: sessionID).drawerAsk)
    }

    /// No Workchat for the session (not loaded, gone or not running): the
    /// panel shows one line and no composer, and Ask agent writes no draft.
    func testPanelWithoutAWorkchatSaysTheSessionIsNotRunning() async throws {
        let (projectID, sessionID) = try await pool.write { d in
            let p = try TestDatabase.insertWorkbench(d, folder: "/tmp/acme")
            let s = try TerminalSessionQueries.create(d, .init(projectID: p, kind: .shell, title: "zsh", folderPath: "/tmp/acme"))
            return (p, s.id)
        }
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults)
        let chat = ReviewAgentChat(vm: vm, projectID: projectID, sessionID: sessionID)
        XCTAssertNil(chat.workchat)
        XCTAssertEqual(ReviewAgentChatPanel.content(chat), .notRunning)
        XCTAssertEqual(ReviewAgentChatPanel.notRunningText, "The session is not running")
        chat.ask("Re `a.go:1`:")
        XCTAssertEqual(vm.workchat(sessionID: sessionID)?.draft ?? "", "")
    }
}

/// The Author chat hosted in Branch review's panel (final review, #2201 T2 round 4): a path clicked in the rendered
/// Workchat opens through the review's `.changes` pane — Files beside the review — never through a Workchat pane
/// that is not on screen.
@MainActor
final class ReviewAgentChatHostedTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var folder: URL!

    /// Answers every `session-feed` read with one agent line naming `src/a.go`; any other call gets `{}`.
    private final class FeedRunner: CLIRunnerProtocol, @unchecked Sendable {
        func run(args: [String]) async throws -> Data {
            guard args.contains("session-feed") else { return Data("{}".utf8) }
            let entry = #"{"id":"e1","kind":"agent","at":"2026-10-16T10:00:00Z","text":"Edited src/a.go.","conversation":"main"}"#
            return Data(#"{"session_id":1,"cursor":"c1","entries":[\#(entry)],"subagents":[]}"#.utf8)
        }
    }

    /// What the rendered feed handed its rows.
    private final class Probe {
        var handlers: AgentTextHighlighting?
        var highlights: WorkchatHighlights?
    }

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "ReviewAgentChatHostedTests-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("review-chat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "package a\n".write(to: folder.appendingPathComponent("src/a.go"), atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    func testAPathClickedInTheHostedAuthorChatOpensBesideTheReview() async throws {
        let folderPath = folder.path
        let (projectID, sessionID) = try await pool.write { d in
            let p = try TestDatabase.insertWorkbench(d, folder: folderPath)
            let s = try TerminalSessionQueries.create(d, .init(
                projectID: p, kind: .claude, title: "claude", folderPath: folderPath,
                claudeSessionID: UUID().uuidString.lowercased()
            ))
            return (p, s.id)
        }
        let runner = FeedRunner()
        let center = TerminalCenter(makeProcess: { FakeTerminalSession() },
                                    signaller: ProcessGroupSignaller(signal: { _, _ in }, isAlive: { _ in false }, sleep: { _ in }))
        let delivery = SessionLineDelivery(terminalCenter: center)
        let control = SessionControl(dbPool: pool, terminalCenter: center, lineDelivery: delivery) { _ in nil }
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults,
                                      sessionControl: control)
        await vm.reload()
        _ = await vm.loadSessions(projectID: projectID)
        await vm.feedStore(sessionID: sessionID).refresh()
        var split = WorkspaceLayout.default
        split.primary = .changes(sessionID)
        split.secondary = .sessionChat(sessionID + 100)
        vm.setLayout(split, projectID: projectID)
        let chat = ReviewAgentChat(vm: vm, projectID: projectID, sessionID: sessionID)
        XCTAssertNotNil(chat.workchat, "the Author side shows the Workchat")
        let model = ReviewChangesModel(projectID: projectID, sessionID: sessionID, cli: WorkbenchCLI(runner: runner),
                                       db: pool, lineDelivery: delivery) { false }
        let identity = ReviewSessionIdentity(row: nil, place: .unknown, stale: false, mainStatus: nil,
                                             agentName: AgentKind.claude.displayName, openSession: {}, openTerminal: {})
        let appState = AppState.isolated()
        let probe = Probe()
        let panel = ReviewAgentChatPanel(chat: chat, model: model, identity: identity, side: .constant(.author),
                                         composerFocus: nil, focusOnOpen: false) {}
            .environment(appState)
            .environment(\.workchatHighlightProbe) { handlers, highlights in
                probe.handlers = handlers
                probe.highlights = highlights
            }

        // Hosted in a window that is never ordered in (review rules, Tests).
        let host = NSHostingView(rootView: panel.frame(width: 600, height: 500))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let handlers = try XCTUnwrap(probe.handlers, "the rendered Author chat's feed context highlights the agent's text")
        let highlights = try XCTUnwrap(probe.highlights)
        // The context's resolver and click are the screen's handlers: they act through its highlights.
        let resolvesPath = try XCTUnwrap(handlers.resolvesPath, "the feed context carries the screen's path resolver")
        let openHighlight = try XCTUnwrap(handlers.openHighlight, "the feed context carries the screen's click")
        _ = resolvesPath("src/a.go", 1)
        await highlights.lookupsFinished()
        XCTAssertTrue(resolvesPath("src/a.go", 1))
        let text = "src/a.go"
        openHighlight(AgentTextHighlights.Span(range: text.startIndex..<text.endIndex, kind: .path, text: text), 1)
        await highlights.clickFinished()

        XCTAssertEqual(Set(vm.layout(projectID: projectID).visiblePanes), [.files, .changes(sessionID)],
                       "Files opens beside the review the chat is hosted in")
        let project = try XCTUnwrap(vm.summaries.first { $0.id == projectID }?.project)
        XCTAssertEqual(vm.codeFiles.tabs(for: vm.codeRoot(sessionID: sessionID, project: project)).paths, ["src/a.go"])
    }
}
