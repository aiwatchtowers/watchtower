import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// A7b — adding an agent kind is uniform and fails at compile or test time:
/// `AgentKind` lists exactly Go's kinds (`internal/sessionagent/agent_capabilities.json`),
/// and a kind this build does not know (a newer Mac or CLI wrote it) is shown
/// as not supported, never fetched as an error, run as a shell or as Claude Code.
final class AgentKindRegistryTests: XCTestCase {
    static let goFixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Core
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // WatchtowerDesktop
        .deletingLastPathComponent() // repository root
        .appendingPathComponent("internal/sessionagent/agent_capabilities.json")

    static func goRows() throws -> [String: [String: Any]] {
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: goFixture)) as? [String: Any]
        return try XCTUnwrap(raw?["agents"] as? [String: [String: Any]], "agent_capabilities.json has no agents")
    }

    /// Both directions, each with what to do about it.
    func testAgentKindListsExactlyGosKinds() throws {
        let go = Set(try Self.goRows().keys)
        let swift = Set(AgentKind.allCases.map(\.rawValue))
        XCTAssertTrue(
            go.subtracting(swift).isEmpty,
            "Go's agent_capabilities.json has agent kind(s) \(go.subtracting(swift).sorted()) that Swift's AgentKind "
                + "lacks: add the case, a SessionAgent adapter (WatchtowerCore/SessionAgent) and its capability row"
        )
        XCTAssertTrue(
            swift.subtracting(go).isEmpty,
            "Swift's AgentKind has case(s) \(swift.subtracting(go).sorted()) that Go's agent_capabilities.json lacks: "
                + "add the kind to Go's internal/agentkind and sessionagent first, or remove the case"
        )
    }

    /// Every kind's adapter serves that kind, so the registry is one lookup.
    func testEveryKindHasItsOwnAdapter() {
        for kind in AgentKind.allCases {
            XCTAssertEqual(kind.session.kind, kind, "AgentKind.session for \(kind.rawValue) returns another kind's adapter")
            XCTAssertEqual(TerminalSession.Kind(kind).agent, kind, kind.rawValue)
            XCTAssertEqual(TerminalSession.Kind(rawValue: kind.rawValue), TerminalSession.Kind(kind), kind.rawValue)
        }
    }

    // MARK: - A kind this build does not know

    func testAnUnknownKindDecodesAsUnsupported() throws {
        let kind = TerminalSession.Kind(rawValue: "gemini")
        XCTAssertEqual(kind, .unsupported("gemini"))
        XCTAssertEqual(kind.rawValue, "gemini", "the stored value round-trips")
        XCTAssertNil(kind.agent, "never read as an agent this build runs")
        XCTAssertFalse(kind.isAgent)
        XCTAssertTrue(kind.isUnsupported)
        XCTAssertEqual(kind.unsupportedMessage, TerminalSession.Kind.unsupportedMessage("gemini"))
        XCTAssertTrue(try XCTUnwrap(kind.unsupportedMessage).contains("does not support"))
        XCTAssertEqual(TerminalSession.Kind(rawValue: "shell"), .shell)
        XCTAssertNil(TerminalSession.Kind.shell.unsupportedMessage)
        XCTAssertFalse(TerminalSession.Kind(rawValue: "Claude").isAgent, "the match is exact, as Go's agentkind.Parse")
    }

    /// A row a newer version wrote is fetched with its siblings, not an error
    /// that empties the whole list.
    func testARowOfAnUnknownKindIsFetched() throws {
        let queue = try TestDatabase.create()
        let rows = try queue.write { db -> [TerminalSession] in
            let project = try TestDatabase.insertWorkbench(db)
            _ = try TerminalSessionQueries.create(db, .init(projectID: project, kind: .codex, title: "Known", folderPath: "/tmp/acme"))
            // The installed CHECK lists today's kinds; a newer schema would not.
            try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
            try db.execute(
                sql: """
                INSERT INTO terminal_sessions (project_id, kind, title, title_source, folder_path, created_at, last_active_at)
                VALUES (?, 'gemini', 'Newer', 'auto', '/tmp/acme', '2026-11-08T10:00:00Z', '2026-11-08T10:00:00Z')
                """,
                arguments: [project]
            )
            try db.execute(sql: "PRAGMA ignore_check_constraints = OFF")
            return try TerminalSessionQueries.fetchForWorkbench(db, projectID: project)
        }
        XCTAssertEqual(Set(rows.map(\.title)), ["Known", "Newer"])
        XCTAssertEqual(rows.first { $0.title == "Newer" }?.kind, .unsupported("gemini"))
    }

    func testTheRowSaysNotSupportedAndOffersNoStart() {
        let session = TerminalSession(
            id: 7, projectID: 1, kind: .unsupported("gemini"), title: "Newer", titleSource: .auto, targetID: nil,
            folderPath: "/tmp/acme", claudeSessionID: nil,
            createdAt: "2026-11-08T10:00:00Z", lastActiveAt: "2026-11-08T10:00:00Z"
        )
        let row = SessionSwitcherPresentation.rows([session], liveIDs: [], statuses: [:], now: Date())[0]
        XCTAssertEqual(row.caption, SessionSwitcherPresentation.unsupportedCaption)
        XCTAssertEqual(row.agentTag, "gemini", "the tag names the stored kind, not Claude Code")
        XCTAssertNil(TerminalSessionPolicy.reopenLabel(session), "no Start or Resume for a kind this build cannot run")
        XCTAssertFalse(TerminalSessionPolicy.needsTitle(session, attempts: 0))
        XCTAssertFalse(AgentChoicePresentation.deleteSessionMessage(session.kind).contains("Claude"))
    }
}
