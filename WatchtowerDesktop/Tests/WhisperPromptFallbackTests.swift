import Foundation
import Testing
@testable import WatchtowerDesktop

/// Engine-level retry-on-collapse: a prompted decode that comes back empty or
/// throws is retried once clean. Driven through the injected decode closure, so
/// no WhisperKit model (and no CoreML) is ever loaded.
@Suite("decodeWithPromptFallback")
struct WhisperPromptFallbackTests {
    /// Records the prompt tokens of every decode call and returns canned
    /// outcomes in call order (empty past the end).
    private final class Decoder: @unchecked Sendable {
        struct DecodeError: Error, Equatable {
            let tag: String
        }

        var outcomes: [Result<[TranscribedSegment], Error>] = []
        private(set) var calls: [[Int]?] = []

        func decode(_ promptTokens: [Int]?) async throws -> [TranscribedSegment] {
            calls.append(promptTokens)
            let idx = calls.count - 1
            guard idx < outcomes.count else { return [] }
            return try outcomes[idx].get()
        }

        /// Decode that parks until the run is cancelled, so a cancellation is
        /// always delivered before the fallback decides whether to retry.
        func decodeAwaitingCancellation(_ promptTokens: [Int]?) async throws -> [TranscribedSegment] {
            do {
                let segments = try await decode(promptTokens)
                while !Task.isCancelled { await Task.yield() }
                return segments
            } catch {
                while !Task.isCancelled { await Task.yield() }
                throw error
            }
        }
    }

    private func speech(_ text: String) -> [TranscribedSegment] {
        [TranscribedSegment(text: text, startSec: 0, endSec: 1)]
    }

    // MARK: - Empty-decode retry

    @Test("A prompted decode that produced speech is kept as-is")
    func promptedSpeechIsKept() async throws {
        let decoder = Decoder()
        decoder.outcomes = [.success(speech("hello"))]

        let out = try await decodeWithPromptFallback(promptTokens: [1, 2], decode: decoder.decode)

        #expect(out == speech("hello"))
        #expect(decoder.calls == [[1, 2]])
    }

    @Test("An empty prompted decode retries once without the prompt")
    func emptyPromptedDecodeRetriesClean() async throws {
        let decoder = Decoder()
        decoder.outcomes = [.success([]), .success(speech("recovered"))]

        let out = try await decodeWithPromptFallback(promptTokens: [7], decode: decoder.decode)

        #expect(out == speech("recovered"))
        #expect(decoder.calls == [[7], nil])
    }

    @Test("A prompted decode of only blank text counts as empty")
    func blankPromptedDecodeRetriesClean() async throws {
        let decoder = Decoder()
        decoder.outcomes = [.success(speech("  \n ")), .success(speech("recovered"))]

        let out = try await decodeWithPromptFallback(promptTokens: [7], decode: decoder.decode)

        #expect(out == speech("recovered"))
        #expect(decoder.calls == [[7], nil])
    }

    @Test("An unprompted empty decode is never retried")
    func unpromptedEmptyDecodeIsNotRetried() async throws {
        let decoder = Decoder()
        decoder.outcomes = [.success([])]

        let out = try await decodeWithPromptFallback(promptTokens: nil, decode: decoder.decode)

        #expect(out.isEmpty)
        #expect(decoder.calls == [nil], "silence with no prompt to blame must not cost a second decode")
    }

    @Test("Genuine silence stays silent after the clean retry")
    func genuineSilenceStaysSilent() async throws {
        let decoder = Decoder()
        decoder.outcomes = [.success([]), .success([])]

        let out = try await decodeWithPromptFallback(promptTokens: [3], decode: decoder.decode)

        #expect(out.isEmpty)
        #expect(decoder.calls == [[3], nil], "exactly one retry, never a loop")
    }

    // MARK: - Throwing-decode retry

    @Test("A prompted decode that throws retries once without the prompt")
    func promptedThrowRetriesClean() async throws {
        let decoder = Decoder()
        decoder.outcomes = [
            .failure(Decoder.DecodeError(tag: "prompted")),
            .success(speech("recovered"))
        ]

        let out = try await decodeWithPromptFallback(promptTokens: [1], decode: decoder.decode)

        #expect(out == speech("recovered"), "a poisoned prompt must not cost the window")
        #expect(decoder.calls == [[1], nil])
    }

    @Test("An error from the clean retry propagates")
    func cleanRetryErrorPropagates() async throws {
        let decoder = Decoder()
        decoder.outcomes = [
            .failure(Decoder.DecodeError(tag: "prompted")),
            .failure(Decoder.DecodeError(tag: "clean"))
        ]

        await #expect(throws: Decoder.DecodeError(tag: "clean")) {
            try await decodeWithPromptFallback(promptTokens: [1], decode: decoder.decode)
        }
        #expect(decoder.calls == [[1], nil],
                "an error reaching the transcriber always means the CLEAN decode failed")
    }

    @Test("An unprompted decode that throws surfaces immediately")
    func unpromptedThrowPropagatesImmediately() async throws {
        let decoder = Decoder()
        decoder.outcomes = [.failure(Decoder.DecodeError(tag: "clean"))]

        await #expect(throws: Decoder.DecodeError(tag: "clean")) {
            try await decodeWithPromptFallback(promptTokens: nil, decode: decoder.decode)
        }
        #expect(decoder.calls == [nil])
    }

    // MARK: - Cancellation

    @Test("A cancelled run does not retry an empty prompted decode")
    func cancelledRunDoesNotRetryEmptyDecode() async throws {
        let decoder = Decoder()
        decoder.outcomes = [.success([])]

        let task = Task {
            try await decodeWithPromptFallback(promptTokens: [1], decode: decoder.decodeAwaitingCancellation)
        }
        task.cancel()
        let out = try await task.value

        #expect(out.isEmpty)
        #expect(decoder.calls == [[1]], "the engine-slot residency bound is one window")
    }

    @Test("A cancelled run rethrows the original error instead of retrying")
    func cancelledRunRethrowsOriginalError() async throws {
        let decoder = Decoder()
        decoder.outcomes = [.failure(Decoder.DecodeError(tag: "prompted"))]

        let task = Task {
            try await decodeWithPromptFallback(promptTokens: [1], decode: decoder.decodeAwaitingCancellation)
        }
        task.cancel()

        await #expect(throws: Decoder.DecodeError(tag: "prompted")) {
            try await task.value
        }
        #expect(decoder.calls == [[1]])
    }
}
