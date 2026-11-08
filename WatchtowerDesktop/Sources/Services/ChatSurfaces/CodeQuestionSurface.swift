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
///   workbench folder by `ai query --read-folder` when its capability row
///   reads folders; a transport that does not is told so, and its
///   conversation shows `cannotReadFilesNotice` once.
/// - Stored as `chat_conversations` rows with `context_type =
///   'code_question'` and `context_id = '<workbench>:<path>:<line>'` (owner
///   decision 2), which the main chat's list and searches never read
///   (`context_type IS NULL`).
/// - The model (owner decision 3) is the conversation's
///   `provider`/`model`, read when each turn starts, so a follow-up keeps it
///   and a new pick applies from the next turn.
/// - No turn resumes a provider session (#604 G11): each one carries the
///   system prompt and the engine's `EmbeddedChatReplay` block.
@MainActor
enum CodeQuestionSurface {
    static let contextType = CodeQuestionList.contextType
    static let cannotReadFilesNotice =
        "This model cannot read other files: the answer uses only the code sent with the question."
    /// A turn built after the catalog read failed with no rows: the
    /// provider's row is unknown, so the answer had no folder access (shown
    /// once).
    static let capabilitiesUnreadNotice =
        "Provider capabilities could not be read, so the answer uses only the code sent with the question "
        + "— see Settings → System → AI."

    /// The provider/model pick of the composer's picker; `model` "" = Auto,
    /// the provider's default (strong) tier.
    struct ModelChoice: Equatable {
        var provider: AIProvider
        var model: String

        /// A new provider goes back to Auto, as the main chat's picker does.
        func switching(to provider: AIProvider) -> Self {
            provider == self.provider ? self : Self(provider: provider, model: "")
        }
    }

    /// The pick's capability row (the shared catalog).
    static func capabilities(_ choice: ModelChoice) -> ProviderCapabilities {
        AIModelCatalog.shared.capabilities(for: choice.provider.rawValue)
    }

    /// The preselected pick: the configured provider at its default tier.
    static func defaultModelChoice() -> ModelChoice {
        defaultModelChoice(configProvider: ConfigService().aiProvider)
    }

    static func defaultModelChoice(configProvider: String?) -> ModelChoice {
        ModelChoice(provider: AIProvider.fromConfig(configProvider), model: "")
    }

    /// A new conversation for one question, holding the owner's pick. The
    /// write waits on the writer queue, never on the main thread (board #670).
    static func createConversation(
        workbenchID: Int64, origin: CodeQuestionOrigin, choice: ModelChoice, dbPool: DatabasePool
    ) async throws -> Int64 {
        let title = "\(origin.path):\(origin.line)"
        let contextType = contextType
        let contextID = origin.contextID(workbenchID: workbenchID)
        let provider = choice.provider.rawValue
        let model = choice.model.isEmpty ? nil : choice.model
        return try await dbPool.write { db in
            let conversation = try ChatConversationQueries.create(
                db, title: title, contextType: contextType, contextID: contextID)
            try ChatConversationQueries.setProviderModel(db, id: conversation.id, provider: provider, model: model)
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

    static func setModelChoice(_ choice: ModelChoice, conversationID: Int64, dbPool: DatabasePool) async throws {
        let provider = choice.provider.rawValue
        let model = choice.model.isEmpty ? nil : choice.model
        try await dbPool.write { db in
            try ChatConversationQueries.setProviderModel(db, id: conversationID, provider: provider, model: model)
            guard db.changesCount > 0 else { throw ChatContextGoneError() }
        }
    }

    static func spec(
        workbench: Workbench,
        origin: CodeQuestionOrigin,
        conversationID: Int64,
        dbPool: DatabasePool,
        context: CodeQuestionContext?
    ) -> ChatSurfaceSpec {
        spec(workbench: workbench, origin: origin, conversationID: conversationID, dbPool: dbPool) { context }
    }

    /// `context` is read when each turn starts (ruling R41: every turn's
    /// system prompt carries it): the first-turn context built where the
    /// question was asked, or rebuilt from the file when it was reopened;
    /// nil while there is none, and the prompt then names the file and line
    /// only. The usages "Where is it used?" attached after the first turn
    /// are part of it (ruling R45).
    static func spec(
        workbench: Workbench,
        origin: CodeQuestionOrigin,
        conversationID: Int64,
        dbPool: DatabasePool,
        context: @escaping @MainActor () -> CodeQuestionContext?
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
            noteTurnStart(conversationID: conversationID, unread: AIModelCatalog.shared.unreadReason != nil)
            let choice = currentChoice()
            return ChatRunOptions(provider: choice.provider.rawValue,
                                  model: choice.model.isEmpty ? nil : choice.model,
                                  readFolder: capabilities(choice).readsFolder ? workbench.folderPath : nil)
        }
        return ChatSurfaceSpec(
            key: EmbeddedChatKey(contextType: contextType, contextID: origin.contextID(workbenchID: workbench.id),
                                 conversationID: conversationID),
            persistence: .database(conversationID: conversationID),
            toolAccess: .draftOnly,
            ownerInstructions: true,
            systemPrompt: {
                buildSystemPrompt(workbench: workbench, origin: origin, context: context(),
                                  capabilities: capabilities(currentChoice()))
            },
            turnPrompt: { $0.text },
            postTurn: { input in
                var result = ChatPostTurnResult.identity(input)
                // The model's notice is stored for good: written only when the
                // row is known. A turn built after the catalog read failed says so.
                let unread = unreadAtTurnStart.contains(conversationID)
                if let notice = turnNotice(unreadAtStart: unread, catalog: .shared, choice: currentChoice()),
                   !hasNotice(notice, conversationID: conversationID, dbPool: dbPool) {
                    result.notices = [notice]
                }
                return result
            },
            emptyHint: "Ask about this code. The assistant reads the workbench folder and never changes it.",
            runOptions: runOptions
        )
    }

    /// Conversations whose running turn started after the catalog read
    /// failed: its run options gave no folder, whatever a later read says.
    /// Kept here, not in the spec, which the views rebuild while a turn runs.
    private static var unreadAtTurnStart: Set<Int64> = []

    private static func noteTurnStart(conversationID: Int64, unread: Bool) {
        if unread { unreadAtTurnStart.insert(conversationID) } else { unreadAtTurnStart.remove(conversationID) }
    }

    /// The notice a finished turn carries: the catalog could not be read
    /// when it started (the turn had no folder), or the model reads no
    /// files; nil while the rows are not known and no read failed.
    static func turnNotice(unreadAtStart: Bool, catalog: AIModelCatalog, choice: ModelChoice) -> String? {
        if unreadAtStart { return capabilitiesUnreadNotice }
        guard catalog.isLoaded, !catalog.capabilities(for: choice.provider.rawValue).readsFolder else { return nil }
        return cannotReadFilesNotice
    }

    /// Whether the conversation already shows `notice` (its model reads no
    /// files, or its capabilities were unread). A failed read shows it again
    /// rather than never.
    private static func hasNotice(_ notice: String, conversationID: Int64, dbPool: DatabasePool) -> Bool {
        do {
            return try dbPool.read { db in
                try Bool.fetchOne(db, sql: """
                    SELECT EXISTS (SELECT 1 FROM chat_messages
                                   WHERE conversation_id = ? AND role = 'system' AND text = ?)
                    """, arguments: [conversationID, notice]) ?? false
            }
        } catch {
            NSLog("CodeQuestionSurface: reading the notices of conversation %lld: %@",
                  conversationID, error.localizedDescription)
            return false
        }
    }

    // MARK: - System prompt

    /// What the transport can do with the folder (ruling R55), worded for
    /// how its row says it reads: file tools (Read/Grep/Glob/LS), a shell
    /// under a read-only sandbox, or not at all.
    static func readingInstructions(_ capabilities: ProviderCapabilities) -> String {
        switch capabilities.readFolder {
        case "tools":
            """
            You run inside the workbench folder with the read-only file tools Read, Grep, Glob and LS. Read other \
            files of the folder when the answer needs them; paths are relative to the folder. You cannot change, \
            create or delete any file, run commands or reach the web.
            """
        case "shell_sandbox":
            """
            You run inside the workbench folder under a read-only sandbox. Read-only shell commands that inspect \
            files of the folder (cat, ls, rg, grep, sed -n, head) are fine when the answer needs them; paths are \
            relative to the folder. Never modify, create or delete anything, and do not reach the web.
            """
        default:
            """
            You cannot read any other file, run commands or reach the web: answer from the code above only, and \
            say so when the answer needs code you have not been shown.
            """
        }
    }

    static func buildSystemPrompt(
        workbench: Workbench,
        origin: CodeQuestionOrigin,
        context: CodeQuestionContext?,
        capabilities: ProviderCapabilities
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
        let reading = readingInstructions(capabilities)
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
