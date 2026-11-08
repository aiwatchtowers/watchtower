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
         "resolved_light": "haiku", "resolved_strong": "claude-opus-4-6",
         "models": ["haiku", "sonnet", "opus"]},
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
        #expect(AIModelCatalog.suggestions(for: claude) == ["haiku", "claude-opus-4-6", "sonnet", "opus"])

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

    @Test("A failed launch read is retried until it succeeds, and names its reason meanwhile")
    func launchReadRetries() async throws {
        let rows = sample
        let calls = CallCounter()
        let catalog = AIModelCatalog {
            calls.bump() < 3 ? ProcessOutput(exitCode: 2, stdout: "", stderr: "boom")
                : ProcessOutput(exitCode: 0, stdout: rows, stderr: "")
        }
        let seen = WaitLog()
        await catalog.loadRetrying(retryDelays: [.seconds(1), .seconds(2), .seconds(3), .seconds(4)]) { delay in
            await MainActor.run { seen.record(delay, reason: catalog.unreadReason) }
        }
        #expect(calls.count == 3)
        #expect(seen.waits == [.seconds(1), .seconds(2)], "stops at the first success")
        #expect(seen.reasons == [AIModelCatalog.unreadNotice, AIModelCatalog.unreadNotice])
        #expect(catalog.isLoaded)
        #expect(catalog.unreadReason == nil)
        #expect(catalog.lastError == nil)
    }

    @Test("The retries are bounded; a read that never works keeps its honest reason")
    func launchReadGivesUp() async {
        let calls = CallCounter()
        let catalog = AIModelCatalog { calls.bump(); return nil }
        await catalog.loadRetrying(retryDelays: [.zero, .zero]) { _ in }
        #expect(calls.count == 3)
        #expect(catalog.lastError == "watchtower CLI not found")
        #expect(catalog.unreadReason == AIModelCatalog.unreadNotice)
    }

    @Test("A cancelled wait ends the retries")
    func launchReadStopsWhenCancelled() async {
        let calls = CallCounter()
        let catalog = AIModelCatalog { calls.bump(); return nil }
        await catalog.loadRetrying(retryDelays: [.seconds(1), .seconds(1)]) { _ in throw CancellationError() }
        #expect(calls.count == 1)
    }

    @Test("Rows from an earlier read are not unread: no reason after a later failure")
    func laterFailureKeepsRows() async throws {
        let rows = sample
        let calls = CallCounter()
        let catalog = AIModelCatalog {
            calls.bump() == 1 ? ProcessOutput(exitCode: 0, stdout: rows, stderr: "") : nil
        }
        #expect(catalog.unreadReason == nil, "nothing failed before the first read")
        await catalog.load()
        await catalog.load()
        #expect(catalog.lastError != nil)
        #expect(catalog.isLoaded)
        #expect(catalog.unreadReason == nil)
    }

    @Test("readInFlight waits for a running read and starts none")
    func readInFlightWaits() async {
        let calls = CallCounter()
        let idle = AIModelCatalog { calls.bump(); return nil }
        await idle.readInFlight()
        #expect(calls.count < 1, "no read in flight: none started")

        let rows = sample
        let (gate, open) = AsyncStream<Void>.makeStream()
        let catalog = AIModelCatalog {
            for await _ in gate { break }
            return ProcessOutput(exitCode: 0, stdout: rows, stderr: "")
        }
        let running = Task { await catalog.load() }
        while !catalog.isLoading { await Task.yield() }
        open.yield()
        await catalog.readInFlight()
        #expect(catalog.isLoaded)
        await running.value
    }
}

/// Counts a fetch's calls across its `@Sendable` boundary.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    /// The call's number, from 1.
    @discardableResult
    func bump() -> Int { lock.withLock { value += 1; return value } }
}

/// What `loadRetrying` showed at each wait.
@MainActor
private final class WaitLog {
    private(set) var waits: [Duration] = []
    private(set) var reasons: [String?] = []
    func record(_ delay: Duration, reason: String?) {
        waits.append(delay)
        reasons.append(reason)
    }
}
