import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

/// Which harnesses the connect assistant offers (agent connect spec §5.2):
/// read from the Go-written catalog rows' `connect` column, the managed
/// policy and the providers' readiness, never from a provider name.
@MainActor
final class ConnectHarnessCatalogTests: XCTestCase {
    private var providers: [AIModelCatalog.Provider] { ProviderCatalogFixture.providers() }
    private var everyID: Set<String> { Set(providers.map(\.id)) }

    private func offered(
        allowed: [String]? = nil,
        ready: Set<String>? = nil,
        base: String = "claude",
        providers: [AIModelCatalog.Provider]? = nil
    ) -> (harnesses: [ConnectHarness], initial: ConnectHarness?) {
        ConnectHarnessCatalog.offered(providers: providers ?? self.providers, allowed: allowed,
                                      ready: ready ?? everyID, base: base)
    }

    func testCapabilityDecodesFromTheGoRows() {
        let byID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0.capabilities?.connectMode) })
        XCTAssertEqual(byID["claude"], .browser)
        XCTAssertEqual(byID["codex"], .words)
        XCTAssertEqual(byID["ollama"], ConnectCapability.none)
        XCTAssertEqual(ProviderCapabilities(connect: "teleport").connectMode, ConnectCapability.none,
                       "a value this build does not know offers no assistant")
    }

    func testNoneCapabilityNeverOffered() {
        let ids = offered().harnesses.map(\.id)
        XCTAssertEqual(ids, ["claude", "codex"], "Ollama's connect is none")
        XCTAssertNil(offered(base: "ollama").harnesses.first { $0.id == "ollama" })
    }

    func testPolicyBlockedProviderNeverOffered() {
        let result = offered(allowed: ["claude"], base: "codex")
        XCTAssertEqual(result.harnesses.map(\.id), ["claude"])
        XCTAssertEqual(result.initial?.id, "claude", "a blocked base falls back to the first offered harness")
        XCTAssertNil(offered(allowed: []).initial, "a policy that allows nothing offers nothing")
    }

    func testInitialIsBaseProvider() {
        XCTAssertEqual(offered(base: "claude").initial?.id, "claude")
        XCTAssertEqual(offered(base: "codex").initial?.id, "codex")
        let fromOllama = offered(base: "ollama").initial
        XCTAssertEqual(fromOllama?.id, "claude", "a base that cannot connect opens on the first offered harness")
        XCTAssertEqual(fromOllama?.name, "Claude", "the catalog's display name")
        XCTAssertEqual(fromOllama?.capability, .browser)
    }

    func testHarnessNotReadyIsNotOffered() {
        let result = offered(ready: ["ollama"], base: "ollama")
        XCTAssertTrue(result.harnesses.isEmpty, "Claude not signed in, Codex not installed: nothing to run on")
        XCTAssertNil(result.initial, "no harness, no button")
        let codexOnly = offered(ready: ["codex", "ollama"], base: "claude")
        XCTAssertEqual(codexOnly.harnesses.map(\.id), ["codex"])
        XCTAssertEqual(codexOnly.initial?.id, "codex", "a base that is not ready falls back to a ready harness")
    }

    func testNoHarnessMeansNoButton() {
        let silent = providers.map { provider -> AIModelCatalog.Provider in
            var row = provider
            row.capabilities = .none
            return row
        }
        let result = offered(providers: silent)
        XCTAssertTrue(result.harnesses.isEmpty)
        XCTAssertNil(result.initial)
        let older = providers.map { provider -> AIModelCatalog.Provider in
            var row = provider
            row.capabilities = nil
            return row
        }
        XCTAssertNil(offered(providers: older).initial, "a CLI without capability rows offers no assistant")
    }

    func testCodexWordsOnlyUntilBrowserCapability() throws {
        let codex = try XCTUnwrap(offered().harnesses.first { $0.id == "codex" })
        XCTAssertEqual(codex.capability, .words)
        let panel = ConnectAssistantPresentation(service: "Slack", harness: codex, mode: .browser, state: .empty)
        XCTAssertTrue(panel.wordsOnly)
        XCTAssertEqual(panel.actions, [.start, .setUpByHand], "no Guide me in words: the run is already in words")
        XCTAssertFalse(panel.actions.map(\.title).contains("Guide me in words"))
        XCTAssertEqual(panel.modeLine, "I'll tell you each step")
    }
}
