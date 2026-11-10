import Foundation
import GRDB
import WatchtowerCore

/// Analytics' tuning chat (spec 2026-11-03 §4.1): an assistant bound to one
/// workbench that reads the owner's LLM setup and files coach proposals
/// through `propose_tuning_edit`.
///
/// - An action surface (`--surface tuning`) only on a provider the catalog
///   knows as a CLI child; a local HTTP server (ollama), an unknown id or a
///   catalog not read yet leaves it draft-only (AGENT-04, owner ask #1132,
///   spec D52). Decided through the catalog's kind, never by a provider name
///   (LLMTRANSPORT-01).
/// - Every turn, with tools or without, is a `tuning.chat` call in the usage
///   ledger (spec D53).
/// - Many conversations per workbench, `context_type = 'analytics_tuning'`,
///   `context_id = '<workbench id>'`; never listed in the Chats panel (owner,
///   ask #1123), and a knowledge prefix saves nothing here.
enum TuningChatSurface {
    static let contextType = "analytics_tuning"
    static let surface = AgentSurface.tuning.rawValue
    /// How many conversations the panel's recent list shows.
    static let recentLimit = 10
    /// The Go `tuning.ChatPurpose`: the tuning chat's own Usage line.
    static let purpose = "tuning.chat"
    /// The automatic title's length (`setTitleIfEmpty`).
    static let titleLimit = 60

    /// AGENT-04 (the `AutomationEditorChatSurface.toolsAvailable` shape):
    /// tools only on a provider the catalog knows as a CLI child.
    @MainActor static func toolsAvailable(provider: String?) -> Bool {
        AIModelCatalog.shared.isKnownCLI(provider ?? Constants.aiProviderID())
    }

    /// The panel's no-tools line: the catalog's read failure when that is
    /// why, else the provider needs to change.
    @MainActor static func unavailableHelp(catalog: AIModelCatalog = .shared) -> String {
        catalog.unreadReason ?? TuningChatTexts.noTools
    }

    // MARK: - Conversations

    /// The workbench's newest tuning conversation, created on first use.
    static func latestOrNewConversation(dbPool: DatabasePool, workbenchID: Int64) async throws -> Int64 {
        try await DatabaseEmbeddedChatStore.conversationID(
            dbPool: dbPool, contextType: contextType, contextID: String(workbenchID), title: "")
    }

    /// Another conversation for the workbench (**New**): always a new row.
    static func newConversation(dbPool: DatabasePool, workbenchID: Int64) async throws -> Int64 {
        try await dbPool.write { db in
            try ChatConversationQueries.create(db, title: "", contextType: contextType,
                                               contextID: String(workbenchID)).id
        }
    }

    /// The workbench's newest conversations, `recentLimit` at most.
    static func recent(_ db: Database, workbenchID: Int64) throws -> [ChatConversation] {
        try ChatConversation.fetchAll(db, sql: """
            SELECT * FROM chat_conversations
            WHERE context_type = ? AND context_id = ?
            ORDER BY updated_at DESC, id DESC
            LIMIT ?
            """, arguments: [contextType, String(workbenchID), recentLimit])
    }

    /// The conversation's automatic title, once: the first owner message's
    /// first `titleLimit` characters, written only while the title is empty.
    static func setTitleIfEmpty(_ db: Database, conversationID: Int64) throws {
        guard let text = try String.fetchOne(db, sql: """
            SELECT text FROM chat_messages WHERE conversation_id = ? AND role = 'user' ORDER BY id LIMIT 1
            """, arguments: [conversationID]) else { return }
        let joined = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let line = joined.trimmingCharacters(in: .whitespaces)
        let title = String(line.prefix(titleLimit)).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        try db.execute(sql: "UPDATE chat_conversations SET title = ? WHERE id = ? AND title = ''",
                       arguments: [title, conversationID])
    }

    /// The conversation's tuning proposals (`origin = 'chat'`), oldest first.
    static func proposals(_ db: Database, conversationID: Int64) throws -> [CoachProposal] {
        let rows = try Row.fetchAll(db, sql: "SELECT * FROM coach_proposals WHERE conversation_id = ?",
                                    arguments: [conversationID])
        return CoachProposal.forChat(rows.map(CoachProposal.init(row:)), conversationID: conversationID)
    }

    // MARK: - Spec

    /// The chat of one conversation. `period` is read at each turn (the
    /// pane's picker); `onWillSend` runs before each owner turn is accepted
    /// (the controller decides the tool access again there).
    @MainActor static func spec(
        workbenchID: Int64,
        conversationID: Int64,
        provider: String?,
        period: @escaping @MainActor () -> AgentAnalyticsCenter.Period,
        onWillSend: @escaping @MainActor () -> Void
    ) -> ChatSurfaceSpec {
        spec(workbenchID: workbenchID, conversationID: conversationID, tools: toolsAvailable(provider: provider),
             period: period, onWillSend: onWillSend)
    }

    /// The same chat with the tool access already decided (`TuningChat`'s
    /// `decideTools`).
    @MainActor static func spec(
        workbenchID: Int64,
        conversationID: Int64,
        tools: Bool,
        period: @escaping @MainActor () -> AgentAnalyticsCenter.Period,
        onWillSend: @escaping @MainActor () -> Void
    ) -> ChatSurfaceSpec {
        // Every turn, draft-only too, is a `tuning.chat` call (D53).
        let runOptions = { @MainActor () -> ChatRunOptions in ChatRunOptions(purpose: purpose) }
        return ChatSurfaceSpec(
            key: EmbeddedChatKey(contextType: contextType, contextID: String(workbenchID),
                                 conversationID: conversationID),
            persistence: .database(conversationID: conversationID),
            toolAccess: tools ? .actions(surface: surface) : .draftOnly,
            ownerInstructions: true,
            systemPrompt: { systemPrompt(tools: tools) },
            turnPrompt: { input in
                turnContext(workbenchID: workbenchID, period: period(), tools: tools) + "\n\n" + input.text
            },
            willSend: { _ in
                onWillSend()
                return true
            },
            emptyHint: TuningChatTexts.placeholder,
            starterPrompts: [],
            runOptions: runOptions
        )
    }

    // MARK: - Prompt

    /// The surface's own rules with tools. What the tool contract
    /// (`AgentToolsContract.promptBlock(.tuning)`) already says — proposals
    /// only, `list_coach_proposals` first, the stale-CLI answer — is said
    /// there once, never here.
    private static let toolsRules = """
        You are Watchtower's tuning assistant for one workbench. You help the owner tune Watchtower's prompts \
        (through additions only), their global Claude Code and Codex skills, the Watchtower skill pack overlay, \
        ~/.claude/CLAUDE.md, ~/.codex/AGENTS.md, the Claude and Codex allow rules, and this workbench folder's \
        CLAUDE.md, AGENTS.md, skills and .watchtower/workflow.md.
        Read before you answer: the agent report, sessions, LLM usage, prompts, skills and instructions. Quote \
        numbers from the tools, never guesses.
        A workbench folder file is written by Accept on its card, and the owner commits it.
        """

    /// Without tools, neutral about why (an HTTP provider, or a model list
    /// not read yet): the panel's line is the one place that names the cause.
    private static let noToolsRules = """
        You are Watchtower's tuning assistant for one workbench. Tuning tools are not available for this turn \
        — say so in one line and answer from what the owner pastes. You cannot read the report, prompts or \
        skills, or propose an edit.
        """

    static func rulesBlock(tools: Bool) -> String {
        tools ? toolsRules : noToolsRules
    }

    static func systemPrompt(tools: Bool) -> String {
        var parts = [rulesBlock(tools: tools)]
        if tools { parts.append(AgentToolsContract.promptBlock(surface: .tuning)) }
        parts.append(ChatQuestionsContract.promptBlock)
        return parts.joined(separator: "\n\n")
    }

    /// The per-turn block: the workbench and the pane's period, with the
    /// tools' arguments when the turn has tools.
    static func turnContext(workbenchID: Int64, period: AgentAnalyticsCenter.Period, tools: Bool) -> String {
        let days = period.rawValue
        let span = days == 1 ? "the last day" : "the last \(days) days"
        guard tools else {
            return "=== ANALYTICS PANE ===\nWorkbench: \(workbenchID)\nPeriod: \(span)"
        }
        return "=== ANALYTICS PANE ===\nWorkbench: \(workbenchID) (pass workbench_id: \(workbenchID))\n"
            + "Period: \(span) (pass days: \(days))"
    }
}
