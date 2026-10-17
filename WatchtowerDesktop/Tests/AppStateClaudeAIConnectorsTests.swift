import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// AppState wiring of Settings → claude.ai tools (#737): the list is read
/// beside the open database, as Go writes it, and a saved switch is wired
/// to the chat pool.
@MainActor
final class AppStateClaudeAIConnectorsTests: XCTestCase {
    func testListIsReadBesideTheDatabaseAndASwitchIsWiredToThePool() async throws {
        let (seedPool, path) = try TestDatabase.createPool()
        try seedPool.close()
        defer { TestDatabase.cleanup(path: path) }
        let sidecar = ((path as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(ClaudeAIConnectorsFile.fileName)
        try Data(#"{"updated_at":"2026-10-17T09:30:00Z","available":true,"servers":[{"name":"Connector A","status":"connected"}]}"#.utf8)
            .write(to: URL(fileURLWithPath: sidecar))
        defer { try? FileManager.default.removeItem(atPath: sidecar) }

        let appState = AppState()
        appState.databaseManager = try DatabaseManager(path: path)
        appState.claudeAIConnectors.reload()
        XCTAssertEqual(appState.claudeAIConnectors.servers.map(\.name), ["Connector A"])

        // The pool's own retirement is pinned in ChatSessionPoolTests; here
        // the switch must reach it (the real pool spawns real processes).
        let pool = try XCTUnwrap(appState.databaseManager.map { appState.ensureChatSessionPool($0) })
        XCTAssertNotNil(appState.claudeAIConnectors.onSwitched)
        appState.claudeAIConnectors.onSwitched?()
        XCTAssertTrue(pool.clients.isEmpty)
        await pool.closeAll()
    }
}
