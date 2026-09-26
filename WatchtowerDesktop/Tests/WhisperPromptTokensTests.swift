import Foundation
import Testing
@testable import WatchtowerDesktop

/// The pure half of prompt encoding: everything WhisperKit's own CLI does to a
/// prompt string before it becomes `DecodingOptions.promptTokens`. The tokenizer
/// is injected, so no model is loaded.
@Suite("whisperPromptTokens")
struct WhisperPromptTokensTests {
    /// Records every string handed to the tokenizer and returns canned token ids.
    private final class Encoder: @unchecked Sendable {
        var tokens: [Int] = []
        private(set) var encoded: [String] = []

        func encode(_ text: String) -> [Int] {
            encoded.append(text)
            return tokens
        }
    }

    @Test("Encodes the trimmed prompt behind a leading space")
    func prependsLeadingSpace() {
        let encoder = Encoder()
        encoder.tokens = [1, 2, 3]

        let tokens = whisperPromptTokens("  hello  ", specialTokenBegin: 100, encode: encoder.encode)

        #expect(tokens == [1, 2, 3])
        #expect(encoder.encoded == [" hello"])
    }

    @Test("Filters out special tokens")
    func filtersSpecialTokens() {
        let encoder = Encoder()
        encoder.tokens = [5, 150, 7, 100]

        #expect(whisperPromptTokens("hi", specialTokenBegin: 100, encode: encoder.encode) == [5, 7])
    }

    @Test("A nil prompt yields nil without encoding")
    func nilPromptIsNil() {
        let encoder = Encoder()

        #expect(whisperPromptTokens(nil, specialTokenBegin: 100, encode: encoder.encode) == nil)
        #expect(encoder.encoded.isEmpty)
    }

    @Test("A whitespace-only prompt yields nil without encoding")
    func whitespaceOnlyPromptIsNil() {
        let encoder = Encoder()

        #expect(whisperPromptTokens("  \n ", specialTokenBegin: 100, encode: encoder.encode) == nil)
        #expect(encoder.encoded.isEmpty)
    }

    @Test("A prompt that filters down to nothing yields nil, not an empty array")
    func emptyAfterFilterIsNil() {
        let encoder = Encoder()
        encoder.tokens = [200, 300]

        #expect(whisperPromptTokens("hi", specialTokenBegin: 100, encode: encoder.encode) == nil,
                "an empty promptTokens array would still cost the prefill cache")
    }
}
