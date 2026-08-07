import Foundation
import Testing
@testable import WatchtowerDesktop

/// Engine-level retry-on-empty: a prompted decode that collapses to nothing is
/// retried once clean. Driven through the injected decode closure, so no
/// WhisperKit model (and no CoreML) is ever loaded.
@Suite("decodeWithPromptFallback")
struct WhisperPromptFallbackTests {
    /// Records the prompt tokens of every decode call and returns canned results
    /// in call order (empty past the end).
    private final class Decoder: @unchecked Sendable {
        struct DecodeError: Error {}

        var results: [[TranscribedSegment]] = []
        var error: Error?
        private(set) var calls: [[Int]?] = []

        func decode(_ promptTokens: [Int]?) async throws -> [TranscribedSegment] {
            calls.append(promptTokens)
            if let error { throw error }
            let idx = calls.count - 1
            return idx < results.count ? results[idx] : []
        }
    }

    private func speech(_ text: String) -> [TranscribedSegment] {
        [TranscribedSegment(text: text, startSec: 0, endSec: 1)]
    }

    @Test("A prompted decode that produced speech is kept as-is")
    func promptedSpeechIsKept() async throws {
        let decoder = Decoder()
        decoder.results = [speech("hello")]

        let out = try await decodeWithPromptFallback(promptTokens: [1, 2], decode: decoder.decode)

        #expect(out == speech("hello"))
        #expect(decoder.calls == [[1, 2]])
    }

    @Test("An empty prompted decode retries once without the prompt")
    func emptyPromptedDecodeRetriesClean() async throws {
        let decoder = Decoder()
        decoder.results = [[], speech("recovered")]

        let out = try await decodeWithPromptFallback(promptTokens: [7], decode: decoder.decode)

        #expect(out == speech("recovered"))
        #expect(decoder.calls == [[7], nil])
    }

    @Test("A prompted decode of only blank text counts as empty")
    func blankPromptedDecodeRetriesClean() async throws {
        let decoder = Decoder()
        decoder.results = [speech("  \n "), speech("recovered")]

        let out = try await decodeWithPromptFallback(promptTokens: [7], decode: decoder.decode)

        #expect(out == speech("recovered"))
        #expect(decoder.calls == [[7], nil])
    }

    @Test("An unprompted empty decode is never retried")
    func unpromptedEmptyDecodeIsNotRetried() async throws {
        let decoder = Decoder()
        decoder.results = [[]]

        let out = try await decodeWithPromptFallback(promptTokens: nil, decode: decoder.decode)

        #expect(out.isEmpty)
        #expect(decoder.calls == [nil], "silence with no prompt to blame must not cost a second decode")
    }

    @Test("Genuine silence stays silent after the clean retry")
    func genuineSilenceStaysSilent() async throws {
        let decoder = Decoder()
        decoder.results = [[], []]

        let out = try await decodeWithPromptFallback(promptTokens: [3], decode: decoder.decode)

        #expect(out.isEmpty)
        #expect(decoder.calls == [[3], nil], "exactly one retry, never a loop")
    }

    @Test("A failing decode surfaces instead of being retried")
    func decodeErrorIsNotSwallowed() async throws {
        let decoder = Decoder()
        decoder.error = Decoder.DecodeError()

        await #expect(throws: Decoder.DecodeError.self) {
            try await decodeWithPromptFallback(promptTokens: [1], decode: decoder.decode)
        }
        #expect(decoder.calls.count == 1)
    }
}
