import Foundation

/// One event of an embedded chat's turn. `WatchtowerAIService` runs
/// `ai query --events v2` and yields `.text` (append), `.toolStart`/`.toolEnd`
/// (a tool call as a step), `.usage`, `.routing`, `.failure` and `.done`;
/// `.turnComplete`, `.reset`, `.sessionID` and `.error` are the v1 shapes a
/// test double may still yield, and every consumer still folds them.
package enum StreamEvent {
    case text(String)         // streaming delta (append)
    case turnComplete(String) // full turn text (replace — only last turn shown)
    case reset                // a tool call interrupted the turn: discard the
                              // text shown so far (pre-tool preamble) and rebuild
                              // the visible answer from the deltas that follow
    case sessionID(String)
    case error(String)        // the provider's own error text (`ai query` v1
                              // `error` line, which exits 0)
    case failure(ChatSessionError)
    case routing(provider: String, model: String, metadata: ChatRoutingMetadata?)
    case toolStart(ChatToolStart)
    case toolEnd(ChatToolEnd)
    case usage(ChatUsage)
    case done

    /// The pre-`.error` fold: an error line as visible `[Error] …` text. Kept
    /// for the chats not yet on `EmbeddedChatEngine`, so they render exactly
    /// what they did before the case existed.
    package var foldingErrorIntoText: Self {
        if case .error(let message) = self { return .text("[Error] \(message)") }
        if case .failure(let failure) = self { return .text("[Error] \(failure.message)") }
        return self
    }
}

package protocol AIServiceProtocol: Sendable {
    func stream(
        prompt: String,
        systemPrompt: String?,
        sessionID: String?,
        dbPath: String?,
        model: String?,
        provider: String?,
        toolMode: ChatToolMode?
    ) -> AsyncThrowingStream<StreamEvent, Error>

    /// The same run with `readFolder` set: `ai query --read-folder`, which
    /// checks the folder is a workbench (spec 2026-10-02 §9.1). No provider
    /// reads files in it yet (rulings R42/R44): Claude runs as without the
    /// flag and Codex only turns web search off. Only `WatchtowerAIService`
    /// runs it; a test double that does not model it falls back to the run
    /// without a folder. `ownerInstructions` is the bare `--owner-instructions`
    /// flag (the CLI adds the owner's chat instructions to the system prompt;
    /// it carries no content). `purpose` is `--purpose`, the usage ledger's
    /// tag for the run's calls (nil = none). `readFolderAskID` is
    /// `--read-folder-ask N`: the CLI reads the folder review ask N's reviewer
    /// read (never with `readFolder`).
    func stream( // swiftlint:disable:this function_parameter_count
        prompt: String,
        systemPrompt: String?,
        sessionID: String?,
        dbPath: String?,
        model: String?,
        provider: String?,
        toolMode: ChatToolMode?,
        readFolder: String?,
        ownerInstructions: Bool,
        purpose: String?,
        readFolderAskID: Int64?
    ) -> AsyncThrowingStream<StreamEvent, Error>
}

extension AIServiceProtocol {
    package func stream(
        prompt: String,
        systemPrompt: String?,
        sessionID: String?,
        dbPath: String?,
        model: String?,
        provider: String?,
        toolMode: ChatToolMode?,
        readFolder: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        stream(
            prompt: prompt,
            systemPrompt: systemPrompt,
            sessionID: sessionID,
            dbPath: dbPath,
            model: model,
            provider: provider,
            toolMode: toolMode,
            readFolder: readFolder,
            ownerInstructions: false,
            purpose: nil,
            readFolderAskID: nil
        )
    }

    /// A double that models none of the three flags runs without them.
    package func stream( // swiftlint:disable:this function_parameter_count
        prompt: String,
        systemPrompt: String?,
        sessionID: String?,
        dbPath: String?,
        model: String?,
        provider: String?,
        toolMode: ChatToolMode?,
        readFolder: String?,
        ownerInstructions: Bool,
        purpose: String?,
        readFolderAskID: Int64?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        stream(
            prompt: prompt,
            systemPrompt: systemPrompt,
            sessionID: sessionID,
            dbPath: dbPath,
            model: model,
            provider: provider,
            toolMode: toolMode
        )
    }

    package func stream(
        prompt: String,
        systemPrompt: String?,
        sessionID: String?,
        dbPath: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        stream(
            prompt: prompt,
            systemPrompt: systemPrompt,
            sessionID: sessionID,
            dbPath: dbPath,
            model: nil,
            provider: nil,
            toolMode: nil
        )
    }

    package func stream(
        prompt: String,
        systemPrompt: String?,
        sessionID: String?,
        dbPath: String?,
        model: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        stream(
            prompt: prompt,
            systemPrompt: systemPrompt,
            sessionID: sessionID,
            dbPath: dbPath,
            model: model,
            provider: nil,
            toolMode: nil
        )
    }

    /// Variant used by call sites that need to pin both the model and the
    /// backend provider (e.g. the main chat's provider picker) without
    /// touching every other call site's overload.
    package func stream(
        prompt: String,
        systemPrompt: String?,
        sessionID: String?,
        dbPath: String?,
        model: String?,
        provider: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        stream(
            prompt: prompt,
            systemPrompt: systemPrompt,
            sessionID: sessionID,
            dbPath: dbPath,
            model: model,
            provider: provider,
            toolMode: nil
        )
    }

    package func stream(
        prompt: String,
        systemPrompt: String?,
        sessionID: String?,
        dbPath: String?,
        toolMode: ChatToolMode?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        stream(
            prompt: prompt,
            systemPrompt: systemPrompt,
            sessionID: sessionID,
            dbPath: dbPath,
            model: nil,
            provider: nil,
            toolMode: toolMode
        )
    }
}
