import Foundation
import GRDB
import WatchtowerCore

/// An `AIServiceProtocol` whose streams the test drives by hand: every call
/// is recorded and its continuation kept, so a test can emit events, finish
/// or fail a turn at exactly the point it is asserting about.
///
/// A `--persist` call (a database chat's turn) also does what `ai query
/// --persist` writes (`FakeEmbeddedPersist`): the owner row and the reply's
/// placeholder, then `.started`; each emitted event folded into the reply;
/// its end at `finish`.
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
        package let ownerInstructions: Bool
        package let purpose: String?
        package let readFolderAskID: Int64?
        package let readFolderRoundID: Int64?
        package var persist: ChatQueryPersist?
    }

    private let lock = NSLock()
    private let signal = StateSignal()
    private var _calls: [Call] = []
    private var _continuations: [AsyncThrowingStream<StreamEvent, Error>.Continuation] = []
    private var _terminated: [Bool] = []
    private var _persists: [Int: FakeEmbeddedPersist] = [:]
    /// A `--persist` turn whose start write fails with this (the owner text stays).
    package var persistStartError: Error?

    package init() {}

    package var calls: [Call] { lock.withLock { _calls } }

    /// Returns once at least `count` streams have been asked for — the
    /// service's own signal, no clock.
    package func untilCalls(_ count: Int) async {
        await signal.until { [self] in calls.count >= count }
    }
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
               model: model, provider: provider, toolMode: toolMode, readFolder: nil,
               ownerInstructions: false, purpose: nil, readFolderAskID: nil, readFolderRoundID: nil)
    }

    // swiftlint:disable:next function_parameter_count
    package func stream(
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
        readFolderAskID: Int64?,
        readFolderRoundID: Int64?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream()
        let index: Int = lock.withLock {
            _calls.append(Call(prompt: prompt, systemPrompt: systemPrompt, sessionID: sessionID,
                               dbPath: dbPath, toolMode: toolMode, model: model, provider: provider,
                               readFolder: readFolder, ownerInstructions: ownerInstructions,
                               purpose: purpose, readFolderAskID: readFolderAskID,
                               readFolderRoundID: readFolderRoundID))
            _continuations.append(continuation)
            _terminated.append(false)
            return _continuations.count - 1
        }
        signal.changed()
        continuation.onTermination = { [weak self] reason in
            if case .cancelled = reason { self?.lock.withLock { self?._terminated[index] = true } }
        }
        return stream
    }

    // swiftlint:disable:next function_parameter_count
    package func stream(
        prompt: String,
        systemPrompt: String?,
        dbPath: String?,
        model: String?,
        provider: String?,
        toolMode: ChatToolMode?,
        readFolder: String?,
        ownerInstructions: Bool,
        purpose: String?,
        readFolderAskID: Int64?,
        readFolderRoundID: Int64?,
        persist: ChatQueryPersist
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        let stream = stream(prompt: prompt, systemPrompt: systemPrompt, sessionID: nil, dbPath: dbPath, model: model,
                            provider: provider, toolMode: toolMode, readFolder: readFolder,
                            ownerInstructions: ownerInstructions, purpose: purpose, readFolderAskID: readFolderAskID,
                            readFolderRoundID: readFolderRoundID)
        let failure = persistStartError
        let (index, continuation) = lock.withLock { () -> (Int, AsyncThrowingStream<StreamEvent, Error>.Continuation) in
            let index = _continuations.count - 1
            _calls[index].persist = persist
            return (index, _continuations[index])
        }
        guard let dbPath, let emulator = FakeEmbeddedPersist(dbPath: dbPath, persist: persist, provider: provider) else {
            continuation.finish(throwing: ChatWriteError(sentence: "--persist needs a database"))
            return stream
        }
        lock.withLock { _persists[index] = emulator }
        emulator.queue.async {
            if let failure {
                continuation.yield(.failure(ChatSessionError(turnID: persist.turnID, code: .internalError,
                                                             message: failure.localizedDescription, retryable: false)))
                continuation.finish()
                return
            }
            do {
                continuation.yield(try emulator.begin())
            } catch {
                continuation.finish(throwing: error)
            }
        }
        return stream
    }

    package func emit(_ events: StreamEvent..., call: Int? = nil) {
        let (continuation, persist) = lock.withLock { () -> (AsyncThrowingStream<StreamEvent, Error>.Continuation, FakeEmbeddedPersist?) in
            let index = call ?? _continuations.count - 1
            return (_continuations[index], _persists[index])
        }
        guard let persist else {
            for event in events { continuation.yield(event) }
            return
        }
        persist.queue.async {
            for event in events {
                persist.apply(event)
                continuation.yield(event)
            }
        }
    }

    package func finish(call: Int? = nil, throwing error: Error? = nil) {
        let (continuation, persist) = lock.withLock { () -> (AsyncThrowingStream<StreamEvent, Error>.Continuation, FakeEmbeddedPersist?) in
            let index = call ?? _continuations.count - 1
            return (_continuations[index], _persists[index])
        }
        let end = {
            if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        }
        guard let persist else { return end() }
        persist.queue.async {
            persist.finish(failed: error != nil)
            end()
        }
    }
}
