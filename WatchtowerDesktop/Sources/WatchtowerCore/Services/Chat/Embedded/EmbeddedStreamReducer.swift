import Foundation

/// The one fold of `watchtower ai query` events into a turn's visible text —
/// what eight chat view models used to copy (backlog 2026-09-26). `.text`
/// appends (the v2 stream sends nothing else for text, so text streamed
/// before a tool call stays); the v1 shapes a test double may still send:
/// `.turnComplete` replaces with the whole answer and arms "the next `.text`
/// starts over", `.reset` drops the text so far. Steps and usage are not
/// text: the engine reads them before the reducer.
package struct EmbeddedStreamReducer: Sendable {
    package enum Effect: Equatable, Sendable {
        /// The turn's full text changed to this value.
        case text(String)
        case sessionID(String)
        /// The provider reported an error (its own text).
        case failed(String)
        case none
    }

    package private(set) var text = ""
    private var sawTurnComplete = false

    package init() {}

    package mutating func apply(_ event: StreamEvent) -> Effect {
        switch event {
        case .text(let chunk):
            if sawTurnComplete {
                text = chunk
                sawTurnComplete = false
            } else {
                text += chunk
            }
            return .text(text)
        case .turnComplete(let full):
            text = full
            sawTurnComplete = true
            return .text(text)
        case .reset:
            text = ""
            sawTurnComplete = false
            return .text(text)
        case .sessionID(let sid):
            return .sessionID(sid)
        case .error(let message):
            return .failed(message)
        case .failure(let error):
            return .failed(error.message)
        case .routing, .toolStart, .toolEnd, .usage, .done:
            return .none
        }
    }
}

/// Collects a whole stream into its final text — for the one-shot calls that
/// never render a chat (onboarding's profile extraction). An error event
/// throws instead of being folded into the text.
package enum AIStreamText {
    package struct ProviderError: LocalizedError, Equatable {
        package let message: String
        package var errorDescription: String? { message }
    }

    package static func collect(_ stream: AsyncThrowingStream<StreamEvent, Error>) async throws -> String {
        var reducer = EmbeddedStreamReducer()
        for try await event in stream {
            if case .failed(let message) = reducer.apply(event) { throw ProviderError(message: message) }
        }
        return reducer.text
    }
}
