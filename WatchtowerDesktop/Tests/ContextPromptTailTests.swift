import Foundation
import Testing
@testable import WatchtowerDesktop

/// Truth table of the shared `contextPromptTail` helper. Both transcribers call
/// it, so its behaviour is pinned once here; the transcriber suites pin the
/// wiring (when it is called and where `prevText` is updated).
@Suite("contextPromptTail")
struct ContextPromptTailTests {
    private func config(contextPrompt: Bool = true) -> TranscriptionConfig {
        var config = TranscriptionConfig()
        config.contextPrompt = contextPrompt
        return config
    }

    @Test("Same language passes the previous text through")
    func sameLanguagePassesThrough() {
        #expect(contextPromptTail(prevText: "hello there", prevLang: "en",
                                  language: "en", config: config()) == "hello there")
    }

    @Test("Language flip drops the context")
    func languageFlipDropsContext() {
        #expect(contextPromptTail(prevText: "привет", prevLang: "ru",
                                  language: "en", config: config()) == nil)
    }

    @Test("No previous speech window yields nil")
    func noPreviousWindow() {
        #expect(contextPromptTail(prevText: nil, prevLang: nil,
                                  language: "en", config: config()) == nil)
    }

    @Test("Empty previous text yields nil")
    func emptyPreviousText() {
        #expect(contextPromptTail(prevText: "", prevLang: "en",
                                  language: "en", config: config()) == nil)
    }

    @Test("Disabled gate yields nil even with a matching language")
    func disabledGate() {
        #expect(contextPromptTail(prevText: "hello", prevLang: "en",
                                  language: "en", config: config(contextPrompt: false)) == nil)
    }

    @Test("Long previous text is capped to its last 200 characters")
    func capsAtTwoHundredCharacters() throws {
        let long = String(repeating: "a", count: 150) + String(repeating: "b", count: 150)
        let tail = try #require(contextPromptTail(prevText: long, prevLang: "en",
                                                  language: "en", config: config()))
        #expect(tail.count == 200)
        #expect(tail == String(repeating: "a", count: 50) + String(repeating: "b", count: 150))
    }
}
