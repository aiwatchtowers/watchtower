import Foundation
import Testing
@testable import WatchtowerCore

@MainActor
@Suite("AIModelCatalog")
struct AIModelCatalogTests {
    private let sample = """
    {
      "active_provider": "claude",
      "providers": [
        {"id": "claude", "display_name": "Claude", "kind": "cli",
         "default_light": "haiku", "default_strong": "sonnet", "live_models": false,
         "resolved_light": "haiku", "resolved_strong": "claude-opus-4-6"},
        {"id": "codex", "display_name": "Codex", "kind": "cli",
         "default_light": "gpt-5.4-mini", "default_strong": "gpt-5.4", "live_models": false,
         "resolved_light": "gpt-5.4-mini", "resolved_strong": "gpt-5.4"},
        {"id": "ollama", "display_name": "Ollama / Local", "kind": "http",
         "default_light": "gemma4:31b", "default_strong": "gemma4:31b", "live_models": true,
         "resolved_light": "gemma4:31b", "resolved_strong": "gemma4:31b",
         "models": ["llama4:8b", "gemma4:31b"], "error": ""}
      ]
    }
    """

    @Test("Parses the ai models --json envelope")
    func parseEnvelope() throws {
        let output = try AIModelCatalog.parse(Data(sample.utf8))
        #expect(output.activeProvider == "claude")
        #expect(output.providers.count == 3)

        let claude = try #require(output.providers.first { $0.id == "claude" })
        #expect(claude.resolvedStrong == "claude-opus-4-6")
        #expect(claude.liveModels == false)

        let ollama = try #require(output.providers.first { $0.id == "ollama" })
        #expect(ollama.liveModels)
        #expect(ollama.models == ["llama4:8b", "gemma4:31b"])
    }

    @Test("Suggestions dedupe resolved, defaults, and live models in order")
    func suggestionsOrder() throws {
        let output = try AIModelCatalog.parse(Data(sample.utf8))

        let claude = try #require(output.providers.first { $0.id == "claude" })
        #expect(AIModelCatalog.suggestions(for: claude) == ["haiku", "claude-opus-4-6", "sonnet"])

        // Ollama: every value is gemma4:31b except the extra live model —
        // duplicates collapse, live list extends the tail.
        let ollama = try #require(output.providers.first { $0.id == "ollama" })
        #expect(AIModelCatalog.suggestions(for: ollama) == ["gemma4:31b", "llama4:8b"])
    }

    @Test("Missing optional fields parse fine")
    func missingOptionals() throws {
        let json = """
        {"active_provider": "claude", "providers": [
          {"id": "claude", "display_name": "Claude", "kind": "cli",
           "default_light": "haiku", "default_strong": "sonnet", "live_models": false,
           "resolved_light": "haiku", "resolved_strong": "sonnet"}
        ]}
        """
        let output = try AIModelCatalog.parse(Data(json.utf8))
        #expect(output.providers[0].models == nil)
        #expect(output.providers[0].error == nil)
    }
}
