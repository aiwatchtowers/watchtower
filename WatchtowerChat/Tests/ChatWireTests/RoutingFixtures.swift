import ChatWire
import Foundation

/// The routing tests' fixtures: the Go-written capability rows (`WatchtowerDesktop/Tests/Core/Fixtures/
/// ai_models_capabilities.json`, from `go test ./cmd -run TestAIModels_JSONCarriesCapabilities -update`) as a routing
/// catalog, so the presentation is checked against the real table, never a Swift copy of it.
enum RoutingFixtures {
    static func capabilityRows() -> ChatRoutingCatalog {
        let url = ChatWireFixtures.repoRoot.appendingPathComponent("WatchtowerDesktop/Tests/Core/Fixtures/ai_models_capabilities.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["providers"] as? [[String: Any]] else {
            fatalError("RoutingFixtures: unreadable \(url.path)")
        }
        return ChatRoutingCatalog(providers: rows.map { row in
            let caps = row["capabilities"] as? [String: Any] ?? [:]
            let readFolder = caps["read_folder"] as? String ?? "none"
            return ChatRoutingCatalog.Provider(
                id: row["id"] as? String ?? "", displayName: row["display_name"] as? String ?? "",
                reservePeer: caps["reserve_peer"] as? String,
                caps: ChatProviderCaps(images: caps["images"] as? Bool ?? false, pdfs: caps["pdfs"] as? Bool ?? false,
                                       readFolder: !readFolder.isEmpty && readFolder != "none",
                                       claudeAITools: caps["claude_ai_tools"] as? Bool ?? false)
            )
        }, status: nil, statusError: nil)
    }
}

extension ChatRoutingCatalog {
    /// Provider id's capability row; the empty row for an unknown id.
    func capabilities(for id: String) -> ChatProviderCaps { provider(id)?.caps ?? ChatProviderCaps() }
}

/// The fixture catalog's fallback pairs, as the Go rows' `reserve_peer` pairs them (`ProviderCapabilitiesTests` pins
/// that the two agree): presentation tests run both directions without a Swift copy of the pair rule.
extension ProviderFallbackPreview.Pair {
    static let claudeFirst = Self(preferred: .init(id: "claude", name: "Claude"), reserve: .init(id: "codex", name: "Codex"))
    static let codexFirst = claudeFirst.reversed
    static let fixturePairs = [claudeFirst, codexFirst]
}
