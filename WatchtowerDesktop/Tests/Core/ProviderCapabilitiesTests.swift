import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The Go↔Swift dual path of the capability table (spec 2026-11-05 §3.3):
/// `ai_models_capabilities.json` is written by Go
/// (`go test ./cmd -run TestAIModels_JSONCarriesCapabilities -update`) and
/// decoded here, so a key renamed on either side fails a test.
final class ProviderCapabilitiesTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Row: Decodable {
            let id: String
            let capabilities: ProviderCapabilities
        }
        let providers: [Row]
    }

    private static func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ai_models_capabilities.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testDecodesGoFixture() throws {
        let rows = try Self.fixture().providers
        XCTAssertEqual(rows.map(\.id), ["claude", "codex", "ollama"])
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.capabilities) })
        let claude = try XCTUnwrap(byID["claude"])
        XCTAssertTrue(claude.images && claude.pdfs && claude.webSearch && claude.claudeAITools)
        XCTAssertEqual(claude.reservePeer, "codex")
        XCTAssertEqual(claude.readFolder, "tools")
        let codex = try XCTUnwrap(byID["codex"])
        XCTAssertTrue(codex.images)
        XCTAssertFalse(codex.pdfs)
        XCTAssertEqual(codex.reservePeer, "claude")
        XCTAssertEqual(codex.readFolder, "shell_sandbox")
        let ollama = try XCTUnwrap(byID["ollama"])
        XCTAssertFalse(ollama.takesAttachments)
        XCTAssertFalse(ollama.readsFolder)
        XCTAssertTrue(ollama.hasTools)
        XCTAssertEqual(ollama.reservePeer, "")
    }

    /// The catalog reads the same rows from `ai models --json`; the reserve
    /// pair is the table's, both ways, and an unknown provider offers nothing.
    @MainActor
    func testCatalogReadsCapabilitiesAndReservePeer() {
        let catalog = AIModelCatalog(providers: ProviderCatalogFixture.providers())
        XCTAssertEqual(catalog.reservePeer(of: "claude"), "codex")
        XCTAssertEqual(catalog.reservePeer(of: "codex"), "claude")
        XCTAssertNil(catalog.reservePeer(of: "ollama"))
        XCTAssertEqual(catalog.capabilities(for: "gemini"), .none)
        XCTAssertNotNil(ProviderCapabilities.none.attachUnavailableReason)
        XCTAssertNil(catalog.capabilities(for: "codex").attachUnavailableReason)
        XCTAssertEqual(catalog.capabilities(for: "codex").pdfUnavailableReason, "PDFs need a provider that reads them.",
                       "Codex takes images, not PDFs")
        XCTAssertNil(catalog.capabilities(for: "claude").pdfUnavailableReason)
        XCTAssertNil(ProviderCapabilities.none.pdfUnavailableReason, "no attachments at all: U1's reason covers PDFs")

        XCTAssertEqual(catalog.fallbackPair(preferred: "claude"), .claudeFirst)
        XCTAssertEqual(catalog.fallbackPair(preferred: "codex"), .codexFirst)
        XCTAssertNil(catalog.fallbackPair(preferred: "ollama"), "no reserve peer, no pair")
        XCTAssertNil(AIModelCatalog().fallbackPair(preferred: "claude"), "a catalog not read knows no pair")
    }

    /// A session_ready names its provider's row; one without (the routing
    /// placeholder) decodes to nil.
    func testSessionReadyCarriesCapabilities() throws {
        let caps = #"{"tools":"watchtower+quick_connections","tool_events":true,"text_stream":"message","usage":"split","#
            + #""cost_reported":false,"images":true,"pdfs":false,"web_search":false,"read_folder":"shell_sandbox","#
            + #""turn_cap":"counted","interrupt":"kill_turn","warm_session":false,"claude_ai_tools":false,"#
            + #""reserve_peer":"claude","quota":true}"#
        let line = #"{"type":"session_ready","provider":"codex","model":"m","capabilities":"# + caps + "}"
        guard case let .sessionReady(_, provider, _, _, capabilities)? = ChatEvent.parse(line) else {
            return XCTFail("not a session_ready")
        }
        XCTAssertEqual(provider, "codex")
        XCTAssertEqual(capabilities?.reservePeer, "claude")
        guard case let .sessionReady(_, _, _, _, none)? = ChatEvent.parse(#"{"type":"session_ready","routing_mode":"preferred_reserve"}"#) else {
            return XCTFail("not a session_ready")
        }
        XCTAssertNil(none)
    }
}
