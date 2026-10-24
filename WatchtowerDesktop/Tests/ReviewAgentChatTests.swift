import XCTest
import GRDB
@testable import WatchtowerDesktop
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
}
