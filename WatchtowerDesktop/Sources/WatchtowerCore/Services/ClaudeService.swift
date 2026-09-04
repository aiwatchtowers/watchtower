import Foundation

package enum StreamEvent {
    case text(String)         // streaming delta (append)
    case turnComplete(String) // full turn text (replace — only last turn shown)
    case sessionID(String)
    case done
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
}

extension AIServiceProtocol {
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
