import Foundation
import WatchtowerCore

/// Seeds `AIModelCatalog.shared` with the Go-written capability rows
/// (`Tests/Core/Fixtures/ai_models_capabilities.json`, from
/// `go test ./cmd -run TestAIModels_JSONCarriesCapabilities -update`), as
/// the app's launch read does: tests of surfaces that read a provider's
/// capabilities run against the real table, never a Swift copy of it.
package enum ProviderCatalogFixture {
    @MainActor
    package static func seedShared() {
        AIModelCatalog.shared.replaceProviders(providers())
    }

    /// The fixture's rows as `ai models --json` providers.
    @MainActor
    package static func providers() -> [AIModelCatalog.Provider] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Support
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Core/Fixtures/ai_models_capabilities.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["providers"] as? [[String: Any]] else {
            fatalError("ProviderCatalogFixture: unreadable \(url.path)")
        }
        let providers = rows.map { row -> [String: Any] in
            ["id": row["id"] ?? "", "display_name": row["display_name"] ?? row["id"] ?? "", "kind": "cli", "default_light": "",
             "default_strong": "", "live_models": false, "resolved_light": "", "resolved_strong": "",
             "capabilities": row["capabilities"] ?? [:]]
        }
        guard let output = try? JSONSerialization.data(withJSONObject: ["active_provider": "claude", "providers": providers]),
              let parsed = try? AIModelCatalog.parse(output) else {
            fatalError("ProviderCatalogFixture: undecodable rows")
        }
        return parsed.providers
    }
}
