import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class TargetBriefCenterTests: XCTestCase {
    private func makeTarget(_ manager: DatabaseManager, text: String = "ship feature") throws -> Target {
        let id = try manager.dbPool.write { db in
            try TargetQueries.create(db, text: text,
                                     periodStart: "2026-08-01", periodEnd: "2026-08-31")
        }
        return try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: id) })
    }

    private func ensureChatTables(_ manager: DatabaseManager) throws {
        try manager.dbPool.write { db in
            try ChatConversationQueries.ensureTable(db)
            try ChatMessageQueries.ensureTable(db)
        }
    }

    private func makeCenter(manager: DatabaseManager, mock: MockClaudeService) -> TargetBriefCenter {
        let center = TargetBriefCenter()
        center.makeChatVM = { target in
            TargetChatViewModel(
                target: target,
                viewModel: TargetsViewModel(dbManager: manager),
                dbManager: manager,
                aiService: mock
            )
        }
        return center
    }

    private func fetchPersistedMessages(_ manager: DatabaseManager, targetID: Int) throws -> [ChatMessageRecord] {
        try manager.dbPool.read { db in
            guard let conv = try ChatConversationQueries.fetchByContext(
                db, type: "target", id: String(targetID)
            ) else { return [] }
            return try ChatMessageQueries.fetchByConversation(db, conversationID: conv.id)
        }
    }

    /// The house "started → navigated away → came back" contract: the run
    /// lives on the center, not on any view — no view ever held the VM here,
    /// yet the run streams to completion, the message rides the VM's normal
    /// persistence path, and the center releases to idle.
    func testBriefSurvivesWithNoViewAndReleasesToIdle() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try ensureChatTables(manager)
        let target = try makeTarget(manager)
        let mock = MockClaudeService(events: [.sessionID("s1"), .text("On it — decomposing."), .done])
        let center = makeCenter(manager: manager, mock: mock)

        center.startBrief(target: target, text: "Ship feature\n\nWalk the transcripts and break it down.")

        XCTAssertEqual(center.phase, .briefing(targetID: target.id))
        // The detail view for this target adopts the center's VM …
        XCTAssertNotNil(center.adoptVM(for: target.id))
        // … while any other target gets nil (fresh VM as today).
        XCTAssertNil(center.adoptVM(for: target.id + 999))

        await center.task?.value

        XCTAssertEqual(center.phase, .idle)
        // Released after completion — a detail view opened now rebuilds from
        // the persisted conversation instead.
        XCTAssertNil(center.adoptVM(for: target.id))

        // The composer text was sent as the first owner message through the
        // VM's normal send path, and the reply persisted alongside it.
        XCTAssertEqual(mock.prompts.count, 1)
        XCTAssertEqual(mock.prompts[0], "Ship feature\n\nWalk the transcripts and break it down.")
        let persisted = try fetchPersistedMessages(manager, targetID: target.id)
        XCTAssertEqual(persisted.filter { $0.role == "user" }.count, 1)
        XCTAssertEqual(persisted.first { $0.role == "user" }?.text,
                       "Ship feature\n\nWalk the transcripts and break it down.")
        XCTAssertEqual(persisted.filter { $0.role == "assistant" }.count, 1)
    }

    /// An adopted VM stays alive with the adopting view: adoption returns the
    /// SAME instance for repeated calls while the run is held, so a view and
    /// the center never race one conversation with two VMs.
    func testAdoptionReturnsTheSameInstanceWhileHeld() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try ensureChatTables(manager)
        let target = try makeTarget(manager)
        let mock = MockClaudeService(events: [.sessionID("s1"), .text("ok"), .done])
        let center = makeCenter(manager: manager, mock: mock)

        center.startBrief(target: target, text: "brief text")
        let first = center.adoptVM(for: target.id)
        let second = center.adoptVM(for: target.id)
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second)

        await center.task?.value
        // The adopted instance survives the center's release (the view holds it).
        XCTAssertNotNil(first)
        XCTAssertEqual(center.phase, .idle)
    }

    func testStreamFailureLandsInFailed() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try ensureChatTables(manager)
        let target = try makeTarget(manager)
        struct Boom: Error, LocalizedError {
            var errorDescription: String? { "CLI unavailable" }
        }
        let mock = MockClaudeService(error: Boom())
        let center = makeCenter(manager: manager, mock: mock)

        center.startBrief(target: target, text: "brief text")
        await center.task?.value

        XCTAssertEqual(center.phase, .failed(message: "CLI unavailable"))
        XCTAssertNil(center.adoptVM(for: target.id))
        // The instruction survives as a persisted chat message (spec §7) —
        // the owner re-asks in the chat.
        let persisted = try fetchPersistedMessages(manager, targetID: target.id)
        XCTAssertEqual(persisted.filter { $0.role == "user" }.map(\.text), ["brief text"])
    }

    /// Degenerate-but-valid input: no factory wired (DB never opened) fails
    /// cleanly instead of crashing or silently idling.
    func testMissingFactoryFailsCleanly() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let target = try makeTarget(manager)
        let center = TargetBriefCenter()

        center.startBrief(target: target, text: "brief text")

        XCTAssertEqual(center.phase, .failed(message: "Database not available"))
        XCTAssertNil(center.adoptVM(for: target.id))
    }
}
