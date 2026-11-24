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
/// - The config's provider at its strong tier, reading the workbench folder
///   (`ai query --read-folder`, read only), `--purpose ask.explain` for the
///   usage ledger.
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
        target: (title: String, intent: String)?
    ) -> ChatSurfaceSpec {
        let runOptions = { @MainActor () -> ChatRunOptions in
            ChatRunOptions(readFolder: folder.isEmpty ? nil : folder, purpose: AskExplainKey.purpose)
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
