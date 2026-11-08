import XCTest
@testable import WatchtowerCore

/// A7b — the Desktop's provider lists come from the Go catalog
/// (`ai models --json`; the Go-written `Fixtures/ai_models_capabilities.json`).
/// The Swift lists that must exist before a read (the policy's known ids,
/// the display-name fallback) are pinned to it here, so a provider Go adds
/// fails a test instead of falling back at run time.
@MainActor
final class ProviderCatalogRegistryTests: XCTestCase {
    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/ai_models_capabilities.json")

    /// The Go catalog's rows: id → display name, in its order.
    static func goProviders() throws -> [(id: String, name: String)] {
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any]
        let rows = try XCTUnwrap(raw?["providers"] as? [[String: Any]], "ai_models_capabilities.json has no providers")
        return try rows.map { row in
            let id = try XCTUnwrap(row["id"] as? String, "a catalog row without an id")
            let name = try XCTUnwrap(row["display_name"] as? String, "\(id): the catalog row has no display_name")
            return (id, name)
        }
    }

    func testThePolicysKnownProvidersAreTheCatalogs() throws {
        let go = Set(try Self.goProviders().map(\.id))
        let swift = Set(ManagedPolicy.knownProviders)
        XCTAssertTrue(go.subtracting(swift).isEmpty,
                      "the Go catalog has provider(s) \(go.subtracting(swift).sorted()) that ManagedPolicy.knownProviders "
                          + "lacks: add them there and to policy_cases.json (POLICY-02)")
        XCTAssertTrue(swift.subtracting(go).isEmpty,
                      "ManagedPolicy.knownProviders has \(swift.subtracting(go).sorted()) that the Go catalog does not list: "
                          + "remove them, or add the provider to internal/providers first")
    }

    /// The fallback shown before the catalog is read says what the catalog
    /// would, for every provider it lists.
    func testTheDisplayNameFallbackMatchesTheCatalog() throws {
        for provider in try Self.goProviders() {
            XCTAssertEqual(AIModelCatalog.fallbackDisplayName(provider.id), provider.name,
                           "\(provider.id): AIModelCatalog.fallbackDisplayName must equal the catalog's display_name")
        }
        XCTAssertEqual(AIModelCatalog.fallbackDisplayName("newer"), "newer", "an id it does not know shows as itself")
    }

    func testTheCatalogsRowsDecideListAndNames() throws {
        let catalog = AIModelCatalog(providers: [])
        XCTAssertEqual(catalog.providerIDs, [], "nothing is offered before a read")
        XCTAssertEqual(catalog.displayName("codex"), AIModelCatalog.fallbackDisplayName("codex"))

        let json = #"{"active_provider":"claude","providers":["#
            + #"{"id":"newer","display_name":"Newer AI","kind":"cli","default_light":"","default_strong":"","#
            + #""live_models":false,"resolved_light":"","resolved_strong":""},"#
            + #"{"id":"claude","display_name":"Claude (catalog)","kind":"cli","default_light":"","default_strong":"","#
            + #""live_models":false,"resolved_light":"","resolved_strong":""}]}"#
        catalog.replaceProviders(try AIModelCatalog.parse(Data(json.utf8)).providers)
        XCTAssertEqual(catalog.providerIDs, ["newer", "claude"], "the catalog's order, a provider Swift never named included")
        XCTAssertEqual(catalog.displayName("newer"), "Newer AI")
        XCTAssertEqual(catalog.displayName("claude"), "Claude (catalog)", "the row wins over the fallback")
    }

    /// Settings' preferred-provider picker: the catalog's providers the
    /// policy allows, the current choice always kept (before a read too).
    func testThePreferredPickerListsTheCatalog() {
        XCTAssertEqual(ProviderSettingsCopy.preferredChoices(catalogIDs: ["claude", "codex", "newer"], preferred: "claude") { _ in true },
                       ["claude", "codex", "newer"])
        XCTAssertEqual(ProviderSettingsCopy.preferredChoices(catalogIDs: ["claude", "codex"], preferred: "codex") { $0 == "claude" },
                       ["claude", "codex"], "a forbidden current choice stays listed")
        XCTAssertEqual(ProviderSettingsCopy.preferredChoices(catalogIDs: [], preferred: "codex") { _ in true }, ["codex"],
                       "before a read: the current choice only, no Swift list")
    }
}
