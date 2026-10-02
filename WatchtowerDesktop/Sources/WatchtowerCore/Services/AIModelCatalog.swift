import Foundation

/// The provider/model registry as reported by `watchtower ai models --json`.
/// This is the Desktop app's single source of model lists — no model names
/// are hardcoded in Swift. `load()` is best-effort: on any failure the
/// catalog stays empty and callers fall back to free-text input.
@Observable
@MainActor
package final class AIModelCatalog {
    package struct Provider: Decodable, Identifiable, Equatable, Sendable {
        package let id: String
        package let displayName: String
        package let kind: String
        package let defaultLight: String
        package let defaultStrong: String
        package let liveModels: Bool
        package let resolvedLight: String
        package let resolvedStrong: String
        package var models: [String]?
        package var error: String?

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
            case kind
            case defaultLight = "default_light"
            case defaultStrong = "default_strong"
            case liveModels = "live_models"
            case resolvedLight = "resolved_light"
            case resolvedStrong = "resolved_strong"
            case models
            case error
        }
    }

    package struct Output: Decodable, Sendable {
        package let activeProvider: String
        package let providers: [Provider]

        enum CodingKeys: String, CodingKey {
            case activeProvider = "active_provider"
            case providers
        }
    }

    package private(set) var providers: [Provider] = []
    package private(set) var isLoading = false
    package private(set) var lastError: String?

    package init() {}

    package func provider(_ id: String) -> Provider? {
        providers.first { $0.id == id }
    }

    /// Model suggestions for one provider's picker/menu: the resolved tier
    /// models and registry defaults first, then the live server list, deduped
    /// in order.
    package func suggestions(for providerID: String) -> [String] {
        guard let p = provider(providerID) else { return [] }
        return Self.suggestions(for: p)
    }

    package static func suggestions(for p: Provider) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for model in [p.resolvedLight, p.resolvedStrong, p.defaultLight, p.defaultStrong] + (p.models ?? []) {
            guard !model.isEmpty, seen.insert(model).inserted else { continue }
            out.append(model)
        }
        return out
    }

    package static func parse(_ data: Data) throws -> Output {
        try JSONDecoder().decode(Output.self, from: data)
    }

    /// Fetch the registry from the CLI. Safe to call repeatedly; concurrent
    /// calls collapse into one run.
    package func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        guard let cliPath = Constants.findCLIPath() else {
            lastError = "watchtower CLI not found"
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        process.arguments = ["ai", "models", "--json"]
        process.environment = Constants.resolvedEnvironment()
        // Both streams drained, off the concurrency pool (`ProcessPipes`).
        let output = await ProcessPipes.run(process)
        guard output.exitCode == 0 else {
            lastError = "watchtower ai models failed"
            return
        }
        let data = Data(output.stdout.utf8)
        do {
            let parsed = try Self.parse(data)
            providers = parsed.providers
            lastError = nil
        } catch {
            lastError = "parsing ai models output: \(error.localizedDescription)"
        }
    }
}
