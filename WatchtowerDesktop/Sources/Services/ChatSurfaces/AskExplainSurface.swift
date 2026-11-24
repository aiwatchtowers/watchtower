import Foundation
import GRDB
import WatchtowerCore

// MARK: - AskExplainSurface

/// The "Not clear?" chat about an owner ask (spec 2026-11-24 "The
/// assistant"), on the shared embedded chat component.
///
/// - Draft-only (review-rules "The assistant & chat contracts", AGENT-04):
///   no tool mode; the assistant explains and never changes anything.
/// - One conversation per ask, `context_type = 'owner_ask_explain'` and
///   `context_id = '<workbench>:<ask>'` (`AskExplainKey`), found or created
///   with Go's `chat.new` (`reuse: true`), so two windows opening the same
///   ask get one conversation.
/// - The config's provider at its strong tier, `--purpose ask.explain` for
///   the usage ledger. It reads the workbench folder (`ai query
///   --read-folder`, read only) only when its capability row reads folders,
///   as `CodeQuestionSurface` does: `ai query` refuses the flag for a
///   provider without file tools (ollama), which then answers from the ask
///   alone (the prompt says so: "If you cannot…").
/// - The system prompt carries the ask as fenced data (`AskExplainPrompt`).
@MainActor
enum AskExplainSurface {
    /// The ask's conversation, created on first use.
    nonisolated static func conversationID(ask: OwnerAsk, dbPool: DatabasePool, writes: ChatWrites) async throws -> Int64 {
        try await DatabaseEmbeddedChatStore.conversationID(
            dbPool: dbPool, writes: writes, contextType: AskExplainKey.contextType,
            contextID: AskExplainKey.contextID(workbenchID: ask.projectID, askID: ask.id),
            title: AskExplainKey.title(askID: ask.id))
    }

    static func spec(
        ask: OwnerAsk,
        conversationID: Int64,
        folder: String,
        target: (title: String, intent: String)?,
        configProvider: @escaping @MainActor () -> String? = { ConfigService().aiProvider },
        catalog: AIModelCatalog = .shared
    ) -> ChatSurfaceSpec {
        // Read when each turn starts: the provider the turn runs on decides.
        let runOptions = { @MainActor () -> ChatRunOptions in
            let provider = AIProvider.fromConfig(configProvider())
            let reads = !folder.isEmpty && catalog.capabilities(for: provider.rawValue).readsFolder
            return ChatRunOptions(readFolder: reads ? folder : nil, purpose: AskExplainKey.purpose)
        }
        return ChatSurfaceSpec(
            key: EmbeddedChatKey(contextType: AskExplainKey.contextType,
                                 contextID: AskExplainKey.contextID(workbenchID: ask.projectID, askID: ask.id),
                                 conversationID: conversationID),
            persistence: .database(conversationID: conversationID),
            toolAccess: .draftOnly,
            ownerInstructions: true,
            systemPrompt: { AskExplainPrompt.system(ask: ask, target: target) },
            emptyHint: AskExplainCopy.emptyHint,
            runOptions: runOptions
        )
    }
}
