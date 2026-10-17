import Foundation

package enum StreamEvent {
    case text(String)         // streaming delta (append)
    case turnComplete(String) // full turn text (replace — only last turn shown)
    case reset                // a tool call interrupted the turn: discard the
                              // text shown so far (pre-tool preamble) and rebuild
                              // the visible answer from the deltas that follow
    case sessionID(String)
    case error(String)        // the provider's own error text (`ai query` v1
                              // `error` line, which exits 0)
    case done

    /// The pre-`.error` fold: an error line as visible `[Error] …` text. Kept
    /// for the chats not yet on `EmbeddedChatEngine`, so they render exactly
    /// what they did before the case existed.
    package var foldingErrorIntoText: Self {
        if case .error(let message) = self { return .text("[Error] \(message)") }
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
    /// without a folder.
    func stream(
        prompt: String,
        systemPrompt: String?,
        sessionID: String?,
        dbPath: String?,
        model: String?,
        provider: String?,
        toolMode: ChatToolMode?,
        readFolder: String?
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
