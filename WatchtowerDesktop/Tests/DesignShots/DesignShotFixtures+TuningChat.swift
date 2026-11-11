import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The tuning chat beside the Analytics pane (board #1517, spec
/// `2026-11-03-tuning-chat-design.md` §3, §4.3a and §4.4), rendered from the
/// real views: `AgentAnalyticsHeaderView` and `CoachSectionsView` in the
/// pane, `TuningPanelView` over a `TuningChat` whose turns ran through the
/// embedded-chat engine on a temporary database and a scripted AI service,
/// and the Statistics blocks. Everything is synthetic.
@MainActor
enum TuningChatShotFixtures {
    enum State: String, CaseIterable {
        case empty, loading, streaming, error, proposal
        case proposalAccepting = "proposal-accepting", proposalAccepted = "proposal-accepted"
        case proposalStale = "proposal-stale"
        /// An accepted edit of the workbench folder's CLAUDE.md (§4.3a, ask #1165):
        /// the folded line says the file was written and the owner commits it.
        case proposalAcceptedRepo = "proposal-accepted-repo"
        case noTools = "no-tools", narrow
        /// The provider switched to ollama mid-conversation (§4.1): the open card keeps its buttons.
        case noToolsMidway = "no-tools-midway"

        /// Which fixture coach backs the state.
        var coachVariant: String {
            switch self {
            case .proposalStale: "stale"
            case .proposalAccepting: "accepting"
            case .proposalAccepted: "accepted"
            case .proposalAcceptedRepo: "accepted-repo"
            default: "open"
            }
        }

        /// The provider the panel decides its tools from (data for the
        /// seeded catalog, where ollama is an HTTP kind: no tools).
        var provider: String { [.noTools, .noToolsMidway].contains(self) ? "ollama" : "claude" }
    }

    private static var centers: [String: CoachCenter] = [:]
    private static var chats: [State: TuningChat] = [:]
    private static var services: [ScriptedAIService] = []
    private static var database: (pool: DatabasePool, path: String)?
    static let widthKeys = ["designShots.tuningPanelWidth.460", "designShots.tuningPanelWidth.360"]

    static func cleanUp() {
        centers.values.forEach { $0.stop() }
        centers = [:]
        chats.values.forEach { $0.close() }
        chats = [:]
        // A held turn (streaming) ends so its engine lets go of the stream.
        services.filter { !$0.calls.isEmpty }.forEach { $0.finish() }
        services = []
        if let database { TestDatabase.cleanup(path: database.path) }
        database = nil
        widthKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    static var shots: [DesignShot] {
        let panes = State.allCases.map { state in
            DesignShot(name: "tuning-chat-\(state.rawValue)",
                       size: size(state)) {
                screen(state)
            }
        }
        return panes + [
            DesignShot(name: "tuning-chat-analytics-header", size: NSSize(width: 900, height: 58)) {
                do {
                    return AnyView(header(try overview(), tuneOn: false)
                        .padding(Spacing.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .detailBackground())
                } catch {
                    return DesignShotFixtures.failure(error)
                }
            },
            DesignShot(name: "tuning-chat-statistics-codex-caption", size: NSSize(width: 900, height: 590)) {
                statistics()
            }
        ]
    }

    private static func size(_ state: State) -> NSSize {
        switch state {
        case .narrow: NSSize(width: 820, height: 1200)
        default: NSSize(width: 1040, height: 800)
        }
    }

    static func screen(_ state: State) -> AnyView {
        do {
            let coach = try loaded(state.coachVariant)
            return AnyView(TuningPaneShot(state: state, overview: try overview(), coach: coach,
                                          chat: try chat(state, coach: coach)))
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }

    /// The Statistics blocks with Codex sessions in the period: the Context
    /// and Skills blocks carry main's caption "Not measured for Codex
    /// sessions." (§4.7, ask #1132).
    static func statistics() -> AnyView {
        do {
            let overview = try overview()
            let actions = AgentAnalyticsActions(turnOn: {}, openSession: { _ in }, openTarget: { _ in },
                                                openFile: { _ in }, openAsks: {}, tune: {}, asksWaiting: false)
            return AnyView(VStack(alignment: .leading, spacing: Spacing.page) {
                header(overview, tuneOn: false)
                SectionHeader(title: "Statistics", systemImage: "chart.bar")
                AgentAnalyticsContextView(context: overview.context, codex: .some, actions: actions)
                AgentAnalyticsSkillsView(skills: overview.skills, codex: .some)
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(Spacing.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .detailBackground())
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }

    /// The pane's header over the fixture report: a 7-day period with both
    /// agents in it, so the agent filter shows.
    static func header(_ overview: AgentReportOverview, tuneOn: Bool) -> AgentAnalyticsHeaderView {
        AgentAnalyticsHeaderView(overview: overview, period: .constant(.week), agent: .constant(.all), tuneOn: tuneOn,
                                 showsAgentPicker: AgentAnalyticsFormat.showsAgentPicker(overview, filter: .all)) {}
    }

    /// `agent-report-overview` moved to the mockups' week, with Claude Code
    /// and Codex sessions in it.
    static func overview() throws -> AgentReportOverview {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("agent-report-overview")) as? [String: Any])
        json["since"] = "2026-10-27T00:00:00Z"
        json["until"] = "2026-11-03T00:00:00Z"
        json["agents"] = ["claude", "codex"]
        json["agent_filter"] = ["claude", "codex"]
        return try JSONDecoder().decode(AgentReportOverview.self, from: JSONSerialization.data(withJSONObject: json))
    }

    nonisolated private static func fixture(_ name: String) throws -> Data {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: tests.appendingPathComponent("Core/Fixtures/\(name).json"))
    }

    /// Runs the main loop until `condition` holds (a 5 s deadline): the
    /// shots are built synchronously, the engine and the coach work in tasks.
    private static func spin(_ what: String, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), what)
    }

    /// Awaits `body` by running the main loop.
    private static func wait(_ what: String, _ body: @escaping @MainActor () async -> Void) {
        var done = false
        Task { @MainActor in
            await body()
            done = true
        }
        spin(what) { done }
    }

    // MARK: - Coach fixture

    /// One center per card variant: `stale` fails its Accept with the CLI's
    /// stale code, `accepting` never returns from it (the card stays
    /// pending), `accepted` lists the chat's proposal as accepted,
    /// `accepted-repo` lists the chat's accepted CLAUDE.md edit.
    private static func loaded(_ variant: String) throws -> CoachCenter {
        if let center = centers[variant] { return center }
        let coach = CoachCenter(runner: Runner(variant: variant), interval: .seconds(3600))
        coach.show(workbench: 3, period: .week)
        spin("the coach loaded") { coach.status[3]?.value != nil && coach.proposals?.value != nil }
        let id = TuningShotTexts.proposalID
        if variant == "stale" || variant == "accepting" {
            Task { await coach.accept(id, editedText: nil) }
            spin("the accept press landed") {
                variant == "stale" ? coach.cardErrors[id] != nil : coach.pending.contains(id)
            }
        }
        centers[variant] = coach
        return coach
    }

    nonisolated static let status = """
    {"ok":true,"period":{"since":"2026-10-27T00:00:00Z","until":"2026-11-03T00:00:00Z"},\
    "metrics":{"corrections":{"value":2.4,"n":9,"known":true,"previous":2.1},\
    "task_hours":{"value":1.9,"n":7,"known":true,"previous":1.6},\
    "task_cost_usd":{"value":2.94,"n":7,"known":true,"previous":2.31},\
    "owner_loop":{"value":0.25,"n":7,"known":true,"previous":0.28},\
    "spec_findings":{"value":6.1,"n":3,"known":true,"previous":6.5},\
    "review_comments":{"value":1.5,"n":2,"known":true,"previous":2.0}},"open":1,"last_run":"2026-11-02T09:10:00Z"}
    """

    nonisolated private static let earlierAccepted = #"""
    {"id":4,"title":"Spec reviewer: skip naming nits","why":"Seen in several reviews.","destination":"prompt_addition",
    "workbench_id":0,"prompt_id":"review.spec","kind":"add","metric":"spec_findings","before":"",
    "after":"Skip naming nits.","evidence":[],"sources":3,"status":"accepted","created_at":"2026-10-24T09:00:00Z",
    "decided_at":"2026-10-24T09:00:00Z","baseline":null,"verdict":"","verdict_value":null,"verdict_at":null,
    "reverts_id":0,"budget":600}
    """#

    /// The chat's proposal (a user skill, workbench 0) and one accepted edit.
    /// `accepted-repo` lists the chat's accepted edit of workbench 3's
    /// CLAUDE.md (#22, written on `main`, not committed yet) instead.
    nonisolated static func proposals(chatStatus: String) -> String {
        if chatStatus == "accepted-repo" {
            return #"""
            {"ok":true,"proposals":[
            {"id":22,"title":"Tests run the whole suite","why":"In 7 of 9 sessions the agent ran the whole suite.",
            "destination":"repo_claude_md","workbench_id":3,"prompt_id":"","kind":"add","metric":"task_cost_usd",
            "before":"","after":"Run only the touched package's tests while iterating.","evidence":[],"sources":2,
            "status":"accepted","created_at":"2026-11-03T10:02:00Z","decided_at":"2026-11-03T10:05:00Z",
            "baseline":null,"verdict":"","verdict_value":null,"verdict_at":null,"reverts_id":0,"budget":0,
            "origin":"chat","written_branch":"main"},
            """# + earlierAccepted + "]}"
        }
        let decided = chatStatus == "accepted" ? #""2026-11-03T10:05:00Z""# : "null"
        return #"""
        {"ok":true,"proposals":[
        {"id":21,"title":"review-pr: read the diff before whole files",
        "why":"In 9 of 12 review sessions this week the agent read every changed file in full first. Asked in this chat.",
        "destination":"claude_skill_user","skill":"review-pr","workbench_id":0,"prompt_id":"","kind":"replace",
        "metric":"task_cost_usd",
        "before":"2. Read each changed file in full.\n3. Note every finding with file:line.",
        "after":"2. Read the diff first. Open a file in full only when a hunk needs its context.\n3. Note every finding with file:line.",
        "evidence":[{"kind":"chat","ref":"c12"},{"kind":"session","ref":"s41"}],"sources":2,"status":"\#(chatStatus)",
        "created_at":"2026-11-03T10:02:00Z","decided_at":\#(decided),"baseline":null,"verdict":"","verdict_value":null,
        "verdict_at":null,"reverts_id":0,"budget":6400},
        """# + earlierAccepted + "]}"
    }

    private final class Runner: CLIRunnerProtocol, @unchecked Sendable {
        let variant: String

        init(variant: String) { self.variant = variant }

        func run(args: [String]) async throws -> Data {
            switch args.dropFirst().first {
            case "status": return Data(TuningChatShotFixtures.status.utf8)
            case "accept" where variant == "accepting":
                // The press is in flight for the whole render.
                try await Task.sleep(for: .seconds(3600))
                return Data()
            case "accept":
                throw CLIRunnerError.nonZeroExit(code: 1, stderr: #"{"ok":false,"error":"stale","code":"stale"}"#)
            default:
                let status = ["accepted", "accepted-repo"].contains(variant) ? variant : "open"
                return Data(TuningChatShotFixtures.proposals(chatStatus: status).utf8)
            }
        }

        func run(args: [String], timeout: TimeInterval) async throws -> Data { try await run(args: args) }
        func run(args: [String], stdin: Data) async throws -> Data { try await run(args: args) }
    }

    // MARK: - Chat fixture

    /// The state's `TuningChat`: its own conversation of workbench 3 on the
    /// shared temporary database, its turns run through the real engine
    /// with a scripted AI service.
    private static func chat(_ state: State, coach: CoachCenter) throws -> TuningChat {
        if let chat = chats[state] { return chat }
        ProviderCatalogFixture.seedShared()
        let pool = try pool()
        let ai = ScriptedAIService()
        services.append(ai)
        let center = EmbeddedChatCenter(idleTTL: 3600, clock: Date.init) { spec, gate in
            makeSurfaceEngine(spec, dbPool: pool, ai: ai, gate: gate)
        }
        let title = Script.title(state)
        let conversation = try pool.write { db in
            try ChatConversationQueries.create(db, title: title, contextType: TuningChatSurface.contextType,
                                               contextID: "3").id
        }
        // Midway: the turn runs with tools, the provider changes after it.
        var provider = state == .noToolsMidway ? "claude" : state.provider
        let chat = TuningChat(workbenchID: 3, conversationID: conversation, dbPool: pool, center: center,
                              coach: coach, decideTools: { TuningChatSurface.toolsAvailable(provider: provider) },
                              period: { .week })
        chats[state] = chat
        try Script.run(state, chat: chat, ai: ai, pool: pool)
        if state == .noToolsMidway {
            provider = state.provider
            chat.refreshToolAccess()
        }
        wait("the cards were read") { await chat.refreshCards() }
        spin("the coach listed the chat's proposal") { coach.proposals?.value != nil }
        return chat
    }

    private static func pool() throws -> DatabasePool {
        if let database { return database.pool }
        let (pool, path) = try TestDatabase.createPool()
        database = (pool, path)
        return pool
    }

    /// The turns each state shows.
    @MainActor private enum Script {
        static func title(_ state: State) -> String {
            switch state {
            case .empty, .loading, .noTools: ""
            case .streaming, .error: TuningShotTexts.costAsk
            case .proposalAcceptedRepo: "Tests run the whole suite"
            default: "review-pr reads every file"
            }
        }

        static func run(_ state: State, chat: TuningChat, ai: ScriptedAIService, pool: DatabasePool) throws {
            switch state {
            case .empty, .loading, .noTools:
                return
            case .streaming:
                let turn = start(chat, ai, TuningShotTexts.costAsk)
                tool(ai, turn, "get_llm_usage", #"{"days":7}"#)
                tool(ai, turn, "get_prompt", #"{"prompt_id":"digest.channel"}"#, ends: false)
                ai.emit(.text(TuningShotTexts.costPartial), call: 0)
                spin("the partial reply is on the live row") {
                    chat.engine.liveTurn?.text == TuningShotTexts.costPartial
                }
            case .error:
                let turn = start(chat, ai, TuningShotTexts.costAsk)
                tool(ai, turn, "get_llm_usage", #"{"days":7}"#)
                ai.emit(.failure(ChatSessionError(turnID: turn, code: .rateLimit,
                                                  message: TuningShotTexts.turnError, retryable: true)), call: 0)
                ai.finish(call: 0)
                finish(chat)
            case .proposalAcceptedRepo:
                let turn = start(chat, ai, TuningShotTexts.repoAsk)
                tool(ai, turn, "get_agent_instructions", "{}")
                tool(ai, turn, "list_agent_sessions", #"{"days":7}"#)
                tool(ai, turn, "list_coach_proposals", "{}")
                tool(ai, turn, "propose_tuning_edit", #"{"destination":"repo_claude_md"}"#)
                try filed(22, turn: turn, chat: chat, pool: pool)
                reply(chat, ai, TuningShotTexts.repoAnswer)
            default:
                let turn = start(chat, ai, TuningShotTexts.skillAsk)
                tool(ai, turn, "get_skill", #"{"name":"review-pr"}"#)
                tool(ai, turn, "list_agent_sessions", #"{"days":7}"#)
                tool(ai, turn, "list_coach_proposals", "{}")
                tool(ai, turn, "propose_tuning_edit", #"{"skill":"review-pr"}"#)
                try filed(TuningShotTexts.proposalID, turn: turn, chat: chat, pool: pool)
                reply(chat, ai, TuningShotTexts.skillAnswer)
            }
        }

        /// Sends the owner's text and waits for the turn's stream; the turn id.
        private static func start(_ chat: TuningChat, _ ai: ScriptedAIService, _ text: String) -> String {
            XCTAssertTrue(chat.engine.send(text))
            spin("the turn started") { ai.calls.count == 1 && chat.engine.liveTurn != nil }
            return chat.engine.liveTurn?.turnID ?? ""
        }

        private static func tool(
            _ ai: ScriptedAIService,
            _ turn: String,
            _ name: String,
            _ args: String,
            ends: Bool = true
        ) {
            let id = "tool-\(name)"
            ai.emit(.toolStart(ChatToolStart(turnID: turn, id: id, name: name, argsJSON: args)), call: 0)
            if ends {
                ai.emit(.toolEnd(ChatToolEnd(turnID: turn, id: id, ok: true, summary: "", sources: [])), call: 0)
            }
        }

        /// The rows an applied `propose_tuning_edit` call writes: the card
        /// sits under its turn.
        private static func filed(_ id: Int64, turn: String, chat: TuningChat, pool: DatabasePool) throws {
            try pool.write { db in
                try db.execute(sql: """
                    INSERT INTO agent_actions (tool, args_json, conversation_id, turn_id, status, result_json)
                    VALUES ('propose_tuning_edit', '{}', ?, ?, 'applied', ?)
                    """, arguments: [chat.conversationID, turn, #"{"proposal_id":\#(id)}"#])
            }
        }

        private static func reply(_ chat: TuningChat, _ ai: ScriptedAIService, _ text: String) {
            ai.emit(.text(text), .turnComplete(text), .done, call: 0)
            ai.finish(call: 0)
            finish(chat)
        }

        private static func finish(_ chat: TuningChat) {
            spin("the turn ended") { !chat.engine.isStreaming }
            TuningChatShotFixtures.wait("the turn was written") { await chat.engine.finished() }
        }
    }
}

// MARK: - Texts

/// Fixture-only text of the shots; the panel's own strings live in `TuningChatTexts`.
enum TuningShotTexts {
    static let figures = TuningChatTexts.Figures(days: 7, sessions: 23, tasks: 7, costUSD: 41.2,
                                                 perTaskUSD: 2.94, previousPerTaskUSD: 2.31)
    static let starters = TuningChatTexts.starters(
        .init(costPerTaskGrew: true, topHintFinding: "Sessions re-read the same files: 41 times in 9 sessions")
    )
    static let proposalID: Int64 = 21
    static let turnError = "The model stopped: overloaded — the service is busy. Nothing was proposed."
    static let skillAsk = "The review-pr skill makes the agent read every changed file. Can we fix that?"
    static let skillAnswer = "In 9 of 12 review sessions the agent opened every changed file in full before "
        + "looking at the diff. Step 2 of your review-pr skill asks for exactly that. Here is a smaller step 2:"
    static let costAsk = "Which prompt costs the most?"
    static let costPartial = "Over the last 7 days, **digest.channel** is the most expensive Watchtower prompt: "
        + "$6.80 in 212 calls. Most of it is input: each call carries the whole"
    static let repoAsk = "Sessions in this repo keep running the whole test suite. Can CLAUDE.md fix that?"
    static let repoAnswer = "In 7 of 9 sessions the agent ran `go test ./...` after a one-package change. "
        + "Your CLAUDE.md never says which tests to run. I proposed one line under Build & Test: "
        + "\"Run only the touched package's tests while iterating.\""
}

// MARK: - Pane

/// The Analytics pane's header and coach sections beside the real tuning
/// panel, in the pane's `PanelSplit`.
private struct TuningPaneShot: View {
    let state: TuningChatShotFixtures.State
    let overview: AgentReportOverview
    let coach: CoachCenter
    let chat: TuningChat

    private static let noActions = CoachActions(openAsk: { _ in }, openTerminalSession: { _ in },
                                                scrollToStatistics: {})

    private var width: PanelSplitWidth {
        let narrow = state == .narrow
        return PanelSplitWidth(key: TuningChatShotFixtures.widthKeys[narrow ? 1 : 0],
                               range: 360...720, ideal: narrow ? 360 : 460)
    }

    var body: some View {
        PanelSplit(isPanelShown: true, width: width) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.page) {
                    TuningChatShotFixtures.header(overview, tuneOn: true)
                    CoachSectionsView(coach: coach, workbench: 3, actions: Self.noActions)
                }
                .frame(maxWidth: 900, alignment: .leading)
                .padding(Spacing.large)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .detailBackground()
        } panel: {
            TuningPanelView(chat: chat, coach: coach, figures: TuningShotTexts.figures,
                            starters: TuningShotTexts.starters, loading: state == .loading,
                            actions: Self.noActions, onClose: {}, onOpenSettings: {}, onShowAccepted: { _ in })
                .panelBackground()
        }
    }
}
