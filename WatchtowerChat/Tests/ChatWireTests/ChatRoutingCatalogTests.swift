import ChatWire
import XCTest

/// The routing pill's catalog (#1822 T17): the Go-written `routing_catalog.json` decodes through the chat wire coder,
/// and a `chat_list` record without `routing` (an older daemon) still offers its models.
final class ChatRoutingCatalogTests: XCTestCase {
    func testDecodesGoFixture() throws {
        let routing = try Data(contentsOf: ChatWireFixtures.goFixture("chatengine/testdata/routing_catalog.json"))
        let models = """
            [{"provider":"claude","model":"opus","display_name":"Claude","images":true,"pdf":true},
             {"provider":"codex","model":"gpt-5.6-sol","display_name":"Codex","images":true,"pdf":false}]
            """
        let routingJSON = try XCTUnwrap(String(bytes: routing, encoding: .utf8))
        let record = Data(("{\"conversations\":[],\"projects\":[],\"models\":\(models),\"routing\":" + routingJSON + "}").utf8)
        let list = try ChatWireCoder.makeDecoder().decode(ChatList.self, from: record)
        let catalog = ChatRoutingCatalog(list: list)
        XCTAssertEqual(catalog.providers.map(\.id), ["claude", "codex"])
        XCTAssertEqual(catalog.providers.map(\.models), [["opus"], ["gpt-5.6-sol"]])
        XCTAssertEqual(catalog.pair(preferred: "claude"),
                       ProviderFallbackPreview.Pair(preferred: .init(id: "claude", name: "Claude"),
                                                    reserve: .init(id: "codex", name: "Codex")))
        XCTAssertEqual(catalog.provider("claude")?.caps, ChatProviderCaps(images: true, pdfs: true, readFolder: true, claudeAITools: true))
        XCTAssertEqual(catalog.provider("codex")?.caps, ChatProviderCaps(images: true, pdfs: false, readFolder: true, claudeAITools: false))
        let status = try XCTUnwrap(catalog.status)
        XCTAssertEqual(status.preferredProvider, "claude")
        XCTAssertTrue(status.enabled)
        XCTAssertNil(status.application)
        XCTAssertEqual(status.provider("claude")?.state, "quota_wait")
        XCTAssertEqual(status.provider("claude")?.nextProbeAt, ISO8601DateFormatter().date(from: "2026-01-02T10:05:00Z"))
        XCTAssertTrue(catalog.capabilitiesKnown)
        XCTAssertNil(catalog.statusError)
    }

    func testListWithoutRoutingBuildsProvidersFromModels() throws {
        let record = Data("""
            {"conversations":[],"projects":[],"models":[
             {"provider":"claude","model":"opus","display_name":"Claude","images":true,"pdf":true},
             {"provider":"claude","model":"haiku","display_name":"Claude","images":true,"pdf":true},
             {"provider":"codex","model":"gpt-5.6-sol","display_name":"Codex","images":true,"pdf":false}]}
            """.utf8)
        let list = try ChatWireCoder.makeDecoder().decode(ChatList.self, from: record)
        XCTAssertNil(list.routing)
        let catalog = ChatRoutingCatalog(list: list)
        XCTAssertEqual(catalog.providers.map(\.id), ["claude", "codex"])
        XCTAssertEqual(catalog.providers.map(\.models), [["opus", "haiku"], ["gpt-5.6-sol"]])
        XCTAssertEqual(catalog.providers.map(\.reservePeer), [nil, nil])
        XCTAssertNil(catalog.pair(preferred: "claude"))
        XCTAssertNil(catalog.status)
        XCTAssertEqual(catalog.provider("claude")?.caps, ChatProviderCaps(images: true, pdfs: true))
        XCTAssertEqual(catalog.provider("codex")?.caps, ChatProviderCaps(images: true, pdfs: false))
        XCTAssertFalse(catalog.capabilitiesKnown, "no capability line from models[] alone")
    }

    /// The command's bytes (RFC 3339 strings, snake_case keys) and the wire's (converted keys) decode alike.
    func testStatusDecodesFromTheCommandAndTheWire() throws {
        let bytes = Data("""
            {"preferred_provider":"codex","enabled":false,"revision":"r","saved_version":"v",
             "providers":[{"provider":"codex","state":"available","manual_allowed":true,"next_probe_at":"2020-01-01T00:00:00.5Z"}]}
            """.utf8)
        let command = try ChatRoutingStatus.parse(bytes)
        let wire = try ChatWireCoder.makeDecoder().decode(ChatRoutingStatus.self, from: bytes)
        XCTAssertEqual(command, wire)
        XCTAssertEqual(command.savedVersion, "v")
        XCTAssertEqual(command.provider("codex")?.manualAllowed, .allowed)
        XCTAssertNotNil(command.provider("codex")?.nextProbeAt)
    }

    func testAnUnreadableRoutingLeavesTheListDecodable() throws {
        let record = Data("""
            {"conversations":[],"models":[],"routing":{"providers":[{"id":"claude","display_name":"Claude"}],
             "status":{"enabled":"nonsense"},"error":"Couldn't read provider availability"}}
            """.utf8)
        let list = try ChatWireCoder.makeDecoder().decode(ChatList.self, from: record)
        let catalog = ChatRoutingCatalog(list: list)
        XCTAssertEqual(catalog.providers.map(\.id), ["claude"])
        XCTAssertNil(catalog.status)
        XCTAssertEqual(catalog.statusError, "Couldn't read provider availability")
    }
}
