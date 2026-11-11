import XCTest
import GRDB
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Records what the panel's callbacks asked for.
@MainActor
private final class PanelLog {
    var closes = 0
    var settings = 0
    var shown: [Int64] = []
}

/// Answers the coach's proposal list from the shot fixture, with the chat's
/// proposal (#21) in `status`.
private final class ProposalsRunner: CLIRunnerProtocol, @unchecked Sendable {
    let status: String

    init(status: String) { self.status = status }

    func run(args: [String]) async throws -> Data {
        Data(TuningChatShotFixtures.proposals(chatStatus: status).utf8)
    }

    func run(args: [String], timeout: TimeInterval) async throws -> Data { try await run(args: args) }
    func run(args: [String], stdin: Data) async throws -> Data { try await run(args: args) }
}

/// The tuning side panel (spec 2026-11-03 §3, §4.4): the title row, the
/// empty, loading and no-tools states, proposal cards inline and folded,
/// and Esc. The provider ids are data for the seeded catalog, never
/// compared in Sources (LLMTRANSPORT-01).
@MainActor
final class TuningPanelViewTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!
    private var chats: [TuningChat] = []
    private let log = PanelLog()

    private static let finding = "Sessions re-read the same files: 41 times in 9 sessions"
    private static let figures = TuningChatTexts.Figures(days: 7, sessions: 23, tasks: 7, costUSD: 41.2,
                                                         perTaskUSD: 2.94, previousPerTaskUSD: 2.31)
    private static let starters = TuningChatTexts.starters(.init(costPerTaskGrew: true, topHintFinding: finding))

    override func setUp() async throws {
        try await super.setUp()
        ProviderCatalogFixture.seedShared()
        (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
    }

    override func tearDown() async throws {
        chats.forEach { $0.close() }
        chats = []
        ProviderCatalogFixture.seedShared()
        TestDatabase.cleanup(path: dbPath)
        try await super.tearDown()
    }

    private var pool: DatabasePool { dbManager.dbPool }

    private func chat(_ ai: ScriptedAIService, tools: Bool = true) async throws -> TuningChat {
        let pool = self.pool
        let center = EmbeddedChatCenter(idleTTL: 300, clock: Date.init) { spec, gate in
            makeSurfaceEngine(spec, dbPool: pool, ai: ai, gate: gate)
        }
        let conv = try await TuningChatSurface.latestOrNewConversation(dbPool: pool, workbenchID: 3)
        let chat = TuningChat(workbenchID: 3, conversationID: conv, dbPool: pool, center: center, coach: nil,
                              decideTools: { tools }, period: { .week })
        chats.append(chat)
        return chat
    }

    private func coach(_ status: String) async -> CoachCenter {
        let coach = CoachCenter(runner: ProposalsRunner(status: status), interval: .seconds(3600))
        coach.refreshProposals()
        let loaded = await eventually { coach.proposals?.value != nil }
        XCTAssertTrue(loaded)
        return coach
    }

    private func panel(
        _ chat: TuningChat,
        coach: CoachCenter? = nil,
        loading: Bool = false,
        catalog: AIModelCatalog? = nil
    ) -> TuningPanelView {
        let log = self.log
        return TuningPanelView(
            chat: chat, coach: coach, figures: Self.figures, starters: Self.starters, loading: loading,
            actions: CoachActions(openAsk: { _ in }, openTerminalSession: { _ in }, scrollToStatistics: {}),
            onClose: { log.closes += 1 }, onOpenSettings: { log.settings += 1 },
            onShowAccepted: { log.shown.append($0) }, catalog: catalog ?? .shared
        )
    }

    /// One owner turn answered with `reply`; `during` writes the rows the
    /// turn's tool call would have.
    private func turn(
        _ chat: TuningChat,
        _ ai: ScriptedAIService,
        _ text: String,
        reply: String = "ok",
        during: (() throws -> Void)? = nil
    ) async throws {
        let calls = ai.calls.count
        XCTAssertTrue(chat.engine.send(text))
        await chat.engine.finished()
        let started = await eventually { ai.calls.count == calls + 1 }
        XCTAssertTrue(started)
        try during?()
        ai.emit(.text(reply), .turnComplete(reply), .done, call: calls)
        ai.finish(call: calls)
        let done = await eventually { !chat.engine.isStreaming }
        XCTAssertTrue(done)
        await chat.engine.finished()
        await chat.refreshCards()
    }

    /// The chat's proposal #21, filed by an applied `propose_tuning_edit`
    /// call in the turn that is streaming.
    private func fileProposal(_ chat: TuningChat) throws {
        let conv = chat.conversationID
        let turnID = try XCTUnwrap(chat.engine.messages.last { $0.message.isUser }?.message.turnID)
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO coach_proposals (id, fingerprint, kind, destination, title, why, metric, after_text,
                                             sources, created_at, origin, conversation_id)
                VALUES (21, 'fp-21', 'replace', 'session', 'Shorter', 'why', 'corrections', 'Be brief.',
                        1, '2026-11-01T00:00:00Z', 'chat', ?)
                """, arguments: [conv])
            try db.execute(sql: """
                INSERT INTO agent_actions (tool, args_json, conversation_id, turn_id, status, result_json)
                VALUES ('propose_tuning_edit', '{}', ?, ?, 'applied', '{"proposal_id":21}')
                """, arguments: [conv, turnID])
        }
    }

    // MARK: - Title row

    func testTitleRowHasPickerNewAndClose() async throws {
        let chat = try await chat(ScriptedAIService())
        try await pool.write { db in
            for index in 1...12 {
                try db.execute(sql: """
                    INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at)
                    VALUES (?, 'analytics_tuning', '3', ?, ?)
                    """, arguments: ["Chat \(index)", Double(index), Double(index)])
            }
        }
        await chat.refreshCards()
        let view = panel(chat)
        XCTAssertNoThrow(try view.inspect().find(text: TuningChatTexts.title))
        XCTAssertNoThrow(try view.inspect().find(text: TuningChatTexts.newChat), "an untitled chat is a new one")
        XCTAssertNoThrow(try view.inspect().find(button: TuningChatTexts.newButton))
        let close = try view.inspect().find(ViewType.Button.self) {
            (try? $0.labelView().image().actualImage().name()) == "xmark"
        }
        XCTAssertEqual(try close.help().string(), TuningChatTexts.closeHelp)
        let menu = try view.inspect().find(ViewType.Menu.self)
        XCTAssertEqual(menu.findAll(ViewType.Button.self).count, 10, "the last 10 tuning chats")
        XCTAssertNoThrow(try menu.find(button: "Chat 12"))
        XCTAssertThrowsError(try menu.find(button: "Chat 2"))
    }

    func testPickerSwitchesTheConversation() async throws {
        let chat = try await chat(ScriptedAIService())
        let other = try await pool.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at)
                VALUES ('Older chat', 'analytics_tuning', '3', 1, 1)
                """)
            return db.lastInsertedRowID
        }
        await chat.refreshCards()
        try panel(chat).inspect().find(ViewType.Menu.self).find(button: "Older chat").tap()
        XCTAssertEqual(chat.conversationID, other)
    }

    // MARK: - Empty, loading, no tools

    func testEmptyStateFiguresAndStarters() async throws {
        let ai = ScriptedAIService()
        let chat = try await chat(ai)
        let view = panel(chat)
        XCTAssertNoThrow(try view.inspect().find(text: TuningChatTexts.figures(Self.figures)))
        XCTAssertEqual(Self.starters.count, 4)
        for starter in Self.starters {
            XCTAssertNoThrow(try view.inspect().find(text: starter.title))
        }
        XCTAssertThrowsError(try view.inspect().find(text: TuningChatTexts.noTools))
        let starter = try view.inspect().find(text: "Which prompt costs the most?")
        try starter.find(ViewType.Button.self, relation: .parent).tap()
        await chat.engine.finished()
        let sent = await eventually { ai.calls.count == 1 }
        XCTAssertTrue(sent)
        XCTAssertEqual(ai.calls.first?.prompt.contains("Which prompt costs the most?"), true)
    }

    func testLoadingLine() async throws {
        let chat = try await chat(ScriptedAIService())
        let view = panel(chat, loading: true)
        XCTAssertNoThrow(try view.inspect().find(text: TuningChatTexts.loading))
        XCTAssertThrowsError(try view.inspect().find(text: "Tune a skill"), "no starters while the report loads")
        XCTAssertNoThrow(try view.inspect().find(EmbeddedChatComposer.self), "the composer stays")
    }

    func testNoToolsHidesStartersAndOffersSettings() async throws {
        let ai = ScriptedAIService()
        let chat = try await chat(ai, tools: false)
        let fresh = panel(chat)
        XCTAssertNoThrow(try fresh.inspect().find(text: TuningChatTexts.figures(Self.figures)))
        XCTAssertThrowsError(try fresh.inspect().find(text: "Tune a skill"))
        XCTAssertNoThrow(try fresh.inspect().find(text: TuningChatTexts.noTools))
        XCTAssertNoThrow(try fresh.inspect().find(text: TuningChatTexts.noToolsDetail))
        try fresh.inspect().find(button: TuningChatTexts.openSettings).tap()
        XCTAssertEqual(log.settings, 1)

        // Midway: the turns and the open card stay, Accept still works.
        let coach = await coach("open")
        try await turn(chat, ai, "Make review-pr cheaper") { try self.fileProposal(chat) }
        XCTAssertEqual(chat.cards.trailing + (chat.cards.byTurn.values.flatMap { $0 }), [.proposal(21)])
        let midway = panel(chat, coach: coach)
        XCTAssertEqual(try midway.inspect().findAll(TuningNoToolsCard.self).count, 1, "one card, above the composer")
        XCTAssertNoThrow(try midway.inspect().find(text: TuningChatTexts.figures(Self.figures)))
        let accept = try midway.inspect().find(CoachProposalCardView.self).find(button: "Accept")
        XCTAssertFalse(accept.isDisabled())
    }

    /// The catalog not read yet: neither the starters (a turn then would be
    /// draft-only) nor the no-tools card (the controller switches to tools
    /// when the catalog loads).
    func testCatalogNotReadYetShowsNeitherStartersNorNoTools() async throws {
        let chat = try await chat(ScriptedAIService(), tools: false)
        let catalog = AIModelCatalog()
        let view = panel(chat, catalog: catalog)
        XCTAssertNoThrow(try view.inspect().find(text: TuningChatTexts.figures(Self.figures)))
        XCTAssertThrowsError(try view.inspect().find(text: "Tune a skill"))
        XCTAssertThrowsError(try view.inspect().find(TuningNoToolsCard.self))
    }

    func testToolsState() {
        let unread = AIModelCatalog()
        XCTAssertEqual(TuningToolsState.of(toolsAvailable: false, catalog: unread), .undecided)
        XCTAssertEqual(TuningToolsState.of(toolsAvailable: true, catalog: unread), .on)
        XCTAssertEqual(TuningToolsState.of(toolsAvailable: false, catalog: .shared), .off)
        XCTAssertEqual(TuningToolsState.of(toolsAvailable: true, catalog: .shared), .on)
    }

    // MARK: - Proposal cards

    func testInlineProposalAcceptIsSecondary() async throws {
        let ai = ScriptedAIService()
        let chat = try await chat(ai)
        let coach = await coach("open")
        try await turn(chat, ai, "Make review-pr cheaper") { try self.fileProposal(chat) }
        XCTAssertFalse(chat.cards.byTurn.isEmpty, "the card sits under its turn")
        let card = try panel(chat, coach: coach).inspect().find(CoachProposalCardView.self).actualView()
        XCTAssertEqual(card.proposal.id, 21)
        XCTAssertFalse(card.isFirst, "the panel's Accept is a secondary button (D17)")
    }

    func testAcceptedFoldsToOneLine() async throws {
        let ai = ScriptedAIService()
        let chat = try await chat(ai)
        let coach = await coach("accepted")
        try await turn(chat, ai, "Make review-pr cheaper") { try self.fileProposal(chat) }
        let view = panel(chat, coach: coach)
        XCTAssertThrowsError(try view.inspect().find(CoachProposalCardView.self))
        XCTAssertNoThrow(try view.inspect().find(text: TuningChatTexts.accepted))
        try view.inspect().find(button: TuningChatTexts.showAccepted).tap()
        XCTAssertEqual(log.shown, [21])
    }

    func testDeclinedFoldsWithoutShowButton() throws {
        let json = Data(TuningChatShotFixtures.proposals(chatStatus: "declined").utf8)
        let proposal = try JSONDecoder().decode(CoachProposalList.self, from: json).proposals[0]
        let line = TuningAcceptedLine(proposal: proposal) {}
        XCTAssertNoThrow(try line.inspect().find(text: "Declined · \(proposal.title)"))
        XCTAssertThrowsError(try line.inspect().find(button: TuningChatTexts.showAccepted))
    }

    func testNoAddToKnowledgeInThePanel() async throws {
        let ai = ScriptedAIService()
        let chat = try await chat(ai)
        let reply = """
            Here is a draft.

            :::artifact key="note" kind="email" title="Note" to="colleague@example.com" subject="Hi"
            Hello.
            :::
            """
        try await turn(chat, ai, "Draft a note", reply: reply)
        XCTAssertThrowsError(try panel(chat).inspect().find(button: "Add to Knowledge"))
    }

    func testEscapeCloses() async throws {
        let chat = try await chat(ScriptedAIService())
        let composer = try panel(chat).inspect().find(EmbeddedChatComposer.self).actualView()
        composer.onEscape?()
        XCTAssertEqual(log.closes, 1)
        XCTAssertEqual(composer.placeholder, TuningChatTexts.placeholder)
    }
}
