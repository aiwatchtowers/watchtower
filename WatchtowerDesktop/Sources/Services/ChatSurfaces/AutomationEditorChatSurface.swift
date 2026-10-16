import Foundation
import GRDB
import Observation
import OSLog
import WatchtowerCore

private let editorChatLog = Logger(subsystem: Constants.bundleID, category: "automation-editor-chat")

// MARK: - Surface

/// "Change it in words" (spec §11, §12.2): an assistant chat bound to one
/// automation, and the "New automation" sheet's chat with no automation yet.
/// An action surface (AGENT-04 as amended, spec §14.5): `automation_editor`
/// carries only `draft_automation`, `save_automation` and the read tools.
/// Under ollama it is draft-only (R-P3-12): no tool mode, so it cannot draft.
enum AutomationEditorChatSurface {
    static let contextType = "automation"
    /// The new-draft chat's conversation: keyed by a draft id, and never
    /// named to the CLI (`--surface automation_editor` with no context).
    static let draftContextType = "automation_draft"
    static let surface = AgentSurface.automationEditor.rawValue
    static let dryRunAgainText = "Dry run the draft again."
    static let saveText = "Save this draft: propose save_automation with the exact text you last drafted, "
        + "and copy your dry run's summary into dry_run_summary."
    static let unavailableHelp = "Needs Claude or Codex"
    static let sendRefusedNote = "The assistant is still answering — try again when the reply finishes."

    static func toolsAvailable(provider: String?) -> Bool {
        (provider ?? Constants.aiProviderID()) != "ollama"
    }

    /// The automation's conversation, created on first use.
    static func conversationID(for automation: Automation, dbPool: DatabasePool) throws -> Int64 {
        try DatabaseEmbeddedChatStore.conversationID(
            dbPool: dbPool, contextType: contextType, contextID: String(automation.id),
            title: "Automation: \(String(automation.name.prefix(60)))")
    }

    /// The new draft's conversation, created on first use.
    static func newConversationID(draftID: String, dbPool: DatabasePool) throws -> Int64 {
        try DatabaseEmbeddedChatStore.conversationID(
            dbPool: dbPool, contextType: draftContextType, contextID: draftID, title: "New automation")
    }

    /// The chat about `automation`. Its per-turn prompt re-reads the recipe
    /// from the index, so an edit saved between turns is what the model sees.
    /// `outcomes` renders the decisions since the previous owner message.
    static func spec(
        automation: Automation,
        provider: String?,
        conversationID: Int64,
        dbPool: DatabasePool,
        outcomes: @escaping @MainActor (Date?) -> String? = { _ in nil },
        skillsDir: String? = SkillsCatalog.defaultDir()
    ) -> ChatSurfaceSpec {
        let tools = toolsAvailable(provider: provider)
        let context = contextBlock(automation: automation)
        return ChatSurfaceSpec(
            key: EmbeddedChatKey(contextType: contextType, contextID: String(automation.id),
                                 conversationID: conversationID),
            persistence: .database(conversationID: conversationID),
            toolAccess: tools ? .actions(surface: surface) : .draftOnly,
            systemPrompt: { systemPrompt(context: context, tools: tools, skillsDir: skillsDir) },
            turnPrompt: { input in
                let recipe = currentRecipeBlock(automationID: automation.id, dbPool: dbPool)
                let resumed = input.isResumed ? rulesBlock(context: context, tools: tools) + "\n\n" : ""
                return compose(outcomes(input.previousOwnerMessageAt), resumed + recipe, input.text)
            },
            emptyHint: "Say what to change — the assistant drafts it, dry-runs it and proposes the save for "
                + "your approval.",
            starterPrompts: [
                ChatStarterPrompt(title: "Explain it", text: "Explain what this automation does, step by step.",
                                  sendsImmediately: true)
            ]
        )
    }

    /// The "New automation" chat: no automation yet, so the CLI gets
    /// `--surface automation_editor` with no context (Task 3).
    static func newSpec(
        provider: String?,
        draftID: String,
        conversationID: Int64,
        outcomes: @escaping @MainActor (Date?) -> String? = { _ in nil },
        skillsDir: String? = SkillsCatalog.defaultDir()
    ) -> ChatSurfaceSpec {
        let tools = toolsAvailable(provider: provider)
        let context = newContextBlock
        return ChatSurfaceSpec(
            key: EmbeddedChatKey(contextType: draftContextType, contextID: draftID, conversationID: conversationID),
            persistence: .database(conversationID: conversationID),
            toolAccess: tools ? .actionsWithoutContext(surface: surface) : .draftOnly,
            systemPrompt: { systemPrompt(context: context, tools: tools, skillsDir: skillsDir) },
            turnPrompt: { input in
                let resumed = input.isResumed ? rulesBlock(context: context, tools: tools) : ""
                return compose(outcomes(input.previousOwnerMessageAt), resumed, input.text)
            },
            emptyHint: "Describe the recurring work in your own words — when it runs, what it reads and where "
                + "the result goes. The assistant drafts it and dry-runs it without writing anything."
        )
    }

    // MARK: - Prompt

    static func contextBlock(automation: Automation) -> String {
        let scope = automation.scope == .personal ? "personal" : "workbench \(automation.projectID ?? 0)"
        var lines = [
            "You are Watchtower's assistant, helping the owner change one of their automations in words.",
            "",
            "=== AUTOMATION ===",
            "Name: \(automation.name)",
            "Slug: \(automation.slug)",
            "Scope: \(scope)",
            "",
            "Always pass `slug: \"\(automation.slug)\"` to `draft_automation` and `save_automation`."
        ]
        if automation.scope == .workbench, let workbench = automation.projectID {
            lines.append("Always pass `workbench_id: \(workbench)` too.")
        }
        return lines.joined(separator: "\n")
    }

    static let newContextBlock = """
        You are Watchtower's assistant, helping the owner create a new automation in words.

        === NEW AUTOMATION ===
        Scope: personal
        Pick a short slug for it (lowercase letters, digits and hyphens) and keep using the same one.
        """

    /// Who the assistant is and the rules; repeated on a resumed turn, whose
    /// CLI call drops the system prompt.
    static func rulesBlock(context: String, tools: Bool) -> String {
        guard tools else {
            return context + "\n\nThis provider has no tools: you can talk the automation through, but you cannot "
                + "draft, dry-run or save it here. Tell the owner it needs Claude or Codex."
        }
        return context + "\n\n"
            + "Load the `create-automation` skill with `load_skill` before drafting.\n"
            + "Draft with `draft_automation` and go through its dry run with the owner before proposing "
            + "`save_automation`.\n\n"
            + AgentToolsContract.promptBlock(surface: .automationEditor)
    }

    static func systemPrompt(context: String, tools: Bool, skillsDir: String?) -> String {
        // The skills are listed whatever the chat's context type: the editor
        // needs `create-automation`, which is a shipped skill.
        let skills = SkillsCatalog.promptBlock(dir: skillsDir).map { "\n\n" + $0 } ?? ""
        return rulesBlock(context: context, tools: tools) + skills + "\n\n" + ChatQuestionsContract.promptBlock
    }

    static let goneRecipeBlock = "=== CURRENT RECIPE ===\nThis automation is no longer in the index (its file may be gone)."

    /// The per-turn recipe block, re-read from the index. A row that is gone
    /// and a read that failed are told apart: a failed read is logged and the
    /// model is told the recipe could not be read now, never that it is gone.
    static func currentRecipeBlock(automationID: Int64, dbPool: DatabasePool) -> String {
        do {
            guard let current = try dbPool.read({ db in try AutomationQueries.fetchAutomation(db, id: automationID) })
            else { return goneRecipeBlock }
            return recipeBlock(current)
        } catch {
            editorChatLog.error("reading automation \(automationID) for the editor chat: \(error.localizedDescription, privacy: .public)")
            return "=== CURRENT RECIPE ===\nThe recipe could not be read from the index just now "
                + "(\(error.localizedDescription)). Do not assume it is gone; tell the owner and ask them to retry."
        }
    }

    static func recipeBlock(_ automation: Automation) -> String {
        "=== CURRENT RECIPE (as saved now — re-read every turn) ===\n```markdown\n\(automation.recipeText)\n```"
    }

    private static func compose(_ parts: String?...) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

// MARK: - Controller

/// One open editor chat: the engine (from the app-wide `EmbeddedChatCenter`,
/// so a turn keeps streaming after the sheet closes), the conversation's
/// proposal feed and the Draft panel read from the editor's draft cache.
/// Made when a sheet opens and `close()`d when it goes; the engine and the
/// cache outlive it, so reopening shows the same turn and the same draft.
@MainActor
@Observable
final class AutomationEditorChat {
    let engine: EmbeddedChatEngine
    let actionFeed: AgentActionFeed
    let conversationID: Int64
    let toolsAvailable: Bool
    private(set) var draft: AutomationDraftPanelModel
    /// What to say once a `save_automation` of this chat landed while it
    /// was open (`SaveAutomationCardModel.appliedNote`); nil before.
    private(set) var savedNote: String?
    /// Why the last **Dry run again** / **Save…** was not sent (the engine
    /// refused it: a turn is still running); nil once one is sent.
    private(set) var sendNote: String?

    @ObservationIgnored private let databasePath: String
    @ObservationIgnored private let center: EmbeddedChatCenter
    @ObservationIgnored private let onSaved: () -> Void
    @ObservationIgnored private var closed = false

    /// `makeSpec` builds the surface's spec around this chat's feed.
    init(
        conversationID: Int64,
        dbPool: DatabasePool,
        toolsAvailable: Bool,
        center: EmbeddedChatCenter,
        cliRunner: CLIRunnerProtocol? = nil,
        onSaved: @escaping () -> Void,
        makeSpec: (_ outcomes: @escaping @MainActor (Date?) -> String?) -> ChatSurfaceSpec
    ) {
        let feed = AgentActionFeed(dbPool: dbPool, cliRunner: cliRunner)
        self.actionFeed = feed
        self.conversationID = conversationID
        self.toolsAvailable = toolsAvailable
        self.databasePath = dbPool.path
        self.center = center
        self.onSaved = onSaved
        let spec = makeSpec { [weak feed] floor in feed?.outcomesBlock(after: floor) }
        engine = center.engine(for: spec)
        draft = AutomationDraftPanelModel.load(databasePath: dbPool.path, conversationID: conversationID)
        center.markShown(spec.key)
        engine.onTurnFinished = { [weak self] _ in self?.turnFinished() }
        feed.onDecision = { [weak self] _, row in self?.decided(row) }
        feed.start(conversationID: conversationID)
    }

    /// The sheet closed: the engine stays in the center (a running turn
    /// finishes), only this view of it stops.
    func close() {
        guard !closed else { return }
        closed = true
        actionFeed.stop()
        center.markHidden(engine.spec.key)
    }

    /// Re-reads the newest draft (after a turn, and when the sheet appears).
    func reloadDraft() {
        draft = AutomationDraftPanelModel.load(databasePath: databasePath, conversationID: conversationID)
    }

    func dryRunAgain() {
        send(AutomationEditorChatSurface.dryRunAgainText)
    }

    /// **Save…**: the assistant proposes `save_automation`; its card's
    /// Approve is the save (spec §11).
    func askToSave() {
        send(AutomationEditorChatSurface.saveText)
    }

    /// A refused send is said, never dropped silently.
    private func send(_ text: String) {
        sendNote = engine.send(text) ? nil : AutomationEditorChatSurface.sendRefusedNote
    }

    private func turnFinished() {
        actionFeed.refresh()
        reloadDraft()
    }

    private func decided(_ row: AgentAction?) {
        guard let row, row.tool == SaveAutomationCardModel.tool, row.status == "applied" else { return }
        savedNote = SaveAutomationCardModel(action: row).appliedNote
        onSaved()
    }
}
