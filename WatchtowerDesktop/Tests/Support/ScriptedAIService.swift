import Foundation
import WatchtowerCore

/// An `AIServiceProtocol` whose streams the test drives by hand: every call
/// is recorded and its continuation kept, so a test can emit events, finish
/// or fail a turn at exactly the point it is asserting about.
package final class ScriptedAIService: AIServiceProtocol, @unchecked Sendable {
    package struct Call {
        package let prompt: String
        package let systemPrompt: String?
        package let sessionID: String?
        package let dbPath: String?
        package let toolMode: ChatToolMode?
        package let model: String?
        package let provider: String?
        package let readFolder: String?
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _continuations: [AsyncThrowingStream<StreamEvent, Error>.Continuation] = []
    private var _terminated: [Bool] = []

    package init() {}

    package var calls: [Call] { lock.withLock { _calls } }
    /// Whether each call's stream was torn down by its consumer (Stop).
    package var terminated: [Bool] { lock.withLock { _terminated } }

    package func stream(
        prompt: String,
        systemPrompt: String?,
        sessionID: String?,
        dbPath: String?,
        model: String?,
        provider: String?,
        toolMode: ChatToolMode?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        stream(prompt: prompt, systemPrompt: systemPrompt, sessionID: sessionID, dbPath: dbPath,
               model: model, provider: provider, toolMode: toolMode, readFolder: nil)
    }

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
        let (stream, continuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        let index: Int = lock.withLock {
            _calls.append(Call(prompt: prompt, systemPrompt: systemPrompt, sessionID: sessionID,
                               dbPath: dbPath, toolMode: toolMode, model: model, provider: provider,
                               readFolder: readFolder))
            _continuations.append(continuation)
            _terminated.append(false)
            return _continuations.count - 1
        }
        continuation.onTermination = { [weak self] reason in
            if case .cancelled = reason { self?.lock.withLock { self?._terminated[index] = true } }
        }
        return stream
    }

    package func emit(_ events: StreamEvent..., call: Int? = nil) {
        let continuation = lock.withLock { _continuations[call ?? _continuations.count - 1] }
        for event in events { continuation.yield(event) }
    }

    package func finish(call: Int? = nil, throwing error: Error? = nil) {
        let continuation = lock.withLock { _continuations[call ?? _continuations.count - 1] }
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }
}
