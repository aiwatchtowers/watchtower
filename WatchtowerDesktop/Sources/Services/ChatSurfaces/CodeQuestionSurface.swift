import Foundation
import GRDB
import WatchtowerCore

// MARK: - CodeQuestionSurface

/// A question about the code of a workbench (spec 2026-10-02 §9.1, §9.4),
/// on the shared embedded chat component.
///
/// - Draft-only (review-rules "The assistant & chat contracts", AGENT-04):
///   no tool mode; the answer only reads.
/// - Reading more of the folder (owner decision 1, confirmed 2026-10-03 —
///   ruling R55): the provider's own read-only file tools, run in the
///   workbench folder by `ai query --read-folder` — Claude and Codex; Ollama
///   has none and is told so, and its conversation shows
///   `cannotReadFilesNotice` once.
/// - Stored as `chat_conversations` rows with `context_type =
///   'code_question'` and `context_id = '<workbench>:<path>:<line>'` (owner
///   decision 2), which the main chat's list and searches never read
///   (`context_type IS NULL`).
/// - The model (owner decision 3) is the conversation's
///   `provider`/`model`, read when each turn starts, so a follow-up keeps it
///   and a new pick applies from the next turn.
@MainActor
enum CodeQuestionSurface {
    static let contextType = CodeQuestionList.contextType
    static let cannotReadFilesNotice =
        "This model cannot read other files: the answer uses only the code sent with the question."

    /// The provider/model pick of the composer's picker; `model` "" = Auto,
    /// the provider's default (strong) tier.
    struct ModelChoice: Equatable {
        var provider: AIProvider
        var model: String

        /// A new provider goes back to Auto, as the main chat's picker does.
        func switching(to provider: AIProvider) -> Self {
            provider == self.provider ? self : Self(provider: provider, model: "")
        }

        /// Whether the provider reads the workbench folder itself (Claude,
        /// Codex: the run carries `--read-folder`).
        var readsFiles: Bool { provider != .ollama }
    }

    /// The preselected pick: the configured provider at its default tier.
    static func defaultModelChoice() -> ModelChoice {
        defaultModelChoice(configProvider: ConfigService().aiProvider)
    }

    static func defaultModelChoice(configProvider: String?) -> ModelChoice {
        ModelChoice(provider: AIProvider.fromConfig(configProvider), model: "")
    }

    /// A new conversation for one question, holding the owner's pick.
    static func createConversation(
        workbenchID: Int64, origin: CodeQuestionOrigin, choice: ModelChoice, dbPool: DatabasePool
    ) throws -> Int64 {
        try dbPool.write { db in
            let conversation = try ChatConversationQueries.create(
                db, title: "\(origin.path):\(origin.line)", contextType: contextType,
                contextID: origin.contextID(workbenchID: workbenchID))
            try ChatConversationQueries.setProviderModel(db, id: conversation.id, provider: choice.provider.rawValue,
                                                         model: choice.model.isEmpty ? nil : choice.model)
            return conversation.id
        }
    }

    /// The conversation's pick; the default for a row that has none.
    static func modelChoice(conversationID: Int64, dbPool: DatabasePool) throws -> ModelChoice {
        guard let row = try dbPool.read({ try ChatConversationQueries.fetchByID($0, id: conversationID) }) else {
            throw ChatContextGoneError()
        }
        guard let provider = row.provider.flatMap(AIProvider.init(rawValue:)) else { return defaultModelChoice() }
        return ModelChoice(provider: provider, model: row.model ?? "")
    }

    static func setModelChoice(_ choice: ModelChoice, conversationID: Int64, dbPool: DatabasePool) throws {
        try dbPool.write { db in
            try ChatConversationQueries.setProviderModel(db, id: conversationID, provider: choice.provider.rawValue,
                                                         model: choice.model.isEmpty ? nil : choice.model)
            guard db.changesCount > 0 else { throw ChatContextGoneError() }
        }
    }

    static func spec(
        workbench: Workbench,
        origin: CodeQuestionOrigin,
        conversationID: Int64,
        dbPool: DatabasePool,
        context: CodeQuestionContext?,
        turnAttachment: @escaping @MainActor () -> String? = { nil }
    ) -> ChatSurfaceSpec {
        spec(workbench: workbench, origin: origin, conversationID: conversationID, dbPool: dbPool,
             context: { context }, turnAttachment: turnAttachment)
    }

    /// `context` is read when each turn starts (ruling R41: every turn's
    /// system prompt carries it): the first-turn context built where the
    /// question was asked, or rebuilt from the file when it was reopened;
    /// nil while there is none, and the prompt then names the file and line
    /// only. `turnAttachment` is read once per turn: text added to a turn
    /// that resumes a provider session (which drops the system prompt) — the
    /// usages "Where is it used?" attached after the first turn (ruling R45).
    static func spec(
        workbench: Workbench,
        origin: CodeQuestionOrigin,
        conversationID: Int64,
        dbPool: DatabasePool,
        context: @escaping @MainActor () -> CodeQuestionContext?,
        turnAttachment: @escaping @MainActor () -> String? = { nil }
    ) -> ChatSurfaceSpec {
        let currentChoice = { @MainActor () -> ModelChoice in
            do {
                return try modelChoice(conversationID: conversationID, dbPool: dbPool)
            } catch {
                // The turn's own writes to this conversation report the
                // failure to the owner; the run falls back to the default.
                NSLog("CodeQuestionSurface: reading the model of conversation %lld: %@",
                      conversationID, error.localizedDescription)
                return defaultModelChoice()
            }
        }
        let runOptions = { @MainActor () -> ChatRunOptions in
            let choice = currentChoice()
            return ChatRunOptions(provider: choice.provider.rawValue,
                                  model: choice.model.isEmpty ? nil : choice.model,
                                  readFolder: choice.readsFiles ? workbench.folderPath : nil)
        }
        return ChatSurfaceSpec(
            key: EmbeddedChatKey(contextType: contextType, contextID: origin.contextID(workbenchID: workbench.id),
                                 conversationID: conversationID),
            persistence: .database(conversationID: conversationID),
            toolAccess: .draftOnly,
            systemPrompt: {
                buildSystemPrompt(workbench: workbench, origin: origin, context: context(),
                                  provider: currentChoice().provider)
            },
            turnPrompt: { input in
                let attachment = turnAttachment()
                guard input.isResumed, let attachment else { return input.text }
                return input.text + "\n\n" + attachment
            },
            postTurn: { input in
                var result = ChatPostTurnResult.identity(input)
                if !currentChoice().readsFiles, !hasCannotReadNotice(conversationID: conversationID, dbPool: dbPool) {
                    result.notices = [cannotReadFilesNotice]
                }
                return result
            },
            emptyHint: "Ask about this code. The assistant reads the workbench folder and never changes it.",
            runOptions: runOptions
        )
    }

    /// Whether the conversation already told the owner its model reads no
    /// files. A failed read shows it again rather than never.
    private static func hasCannotReadNotice(conversationID: Int64, dbPool: DatabasePool) -> Bool {
        do {
            return try dbPool.read { db in
                try Bool.fetchOne(db, sql: """
                    SELECT EXISTS (SELECT 1 FROM chat_messages
                                   WHERE conversation_id = ? AND role = 'system' AND text = ?)
                    """, arguments: [conversationID, cannotReadFilesNotice]) ?? false
            }
        } catch {
            NSLog("CodeQuestionSurface: reading the notices of conversation %lld: %@",
                  conversationID, error.localizedDescription)
            return false
        }
    }

    // MARK: - System prompt

    /// What the provider can do with the folder (ruling R55), worded for its
    /// own tools: Claude reads through Read/Grep/Glob/LS, Codex only through
    /// its shell under the read-only sandbox, Ollama not at all.
    static func readingInstructions(_ provider: AIProvider) -> String {
        switch provider {
        case .claude:
            """
            You run inside the workbench folder with the read-only file tools Read, Grep, Glob and LS. Read other \
            files of the folder when the answer needs them; paths are relative to the folder. You cannot change, \
            create or delete any file, run commands or reach the web.
            """
        case .codex:
            """
            You run inside the workbench folder under a read-only sandbox. Read-only shell commands that inspect \
            files of the folder (cat, ls, rg, grep, sed -n, head) are fine when the answer needs them; paths are \
            relative to the folder. Never modify, create or delete anything, and do not reach the web.
            """
        case .ollama:
            """
            You cannot read any other file, run commands or reach the web: answer from the code above only, and \
            say so when the answer needs code you have not been shown.
            """
        }
    }

    static func buildSystemPrompt(
        workbench: Workbench, origin: CodeQuestionOrigin, context: CodeQuestionContext?, provider: AIProvider
    ) -> String {
        // Open Quickly with no file open: `<wb>::0`, the folder only.
        let contextBlock = context?.promptBlock ?? (origin.path.isEmpty ? """
        === CODE QUESTION CONTEXT ===
        Workbench folder: \(workbench.name)
        No file was open when the question was asked.
        """ : """
        === CODE QUESTION CONTEXT ===
        Workbench folder: \(workbench.name)
        File: \(origin.path)
        Asked at line: \(origin.line)
        """)
        let citeExample = origin.path.isEmpty ? "Sources/App.swift:12" : "\(origin.path):\(origin.line)"
        let reading = readingInstructions(provider)
        return """
        You are Watchtower's assistant, answering the owner's question about the code in their workbench \
        "\(workbench.name)".

        \(contextBlock)
        === READING THE FOLDER ===
        \(reading)

        === RESPONSE RULES ===
        - Answer in the language the owner writes in.
        - Cite code as `path:line`, the path relative to the workbench folder (for example `\(citeExample)`).
        - Never claim to have changed a file: you only read.
        - When asked to suggest a change, end the reply with exactly one fenced block tagged `wt-edit` that holds \
        the replacement for the selection only (the cursor line when nothing is selected), and nothing else.
        - Be concise.
        """
    }
}
