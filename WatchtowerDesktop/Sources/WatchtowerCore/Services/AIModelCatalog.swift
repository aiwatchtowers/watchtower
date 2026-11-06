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
        /// The transport's capability row; nil from a CLI older than A2.
        package var capabilities: ProviderCapabilities?

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
            case capabilities
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

    /// The app's one catalog: what the chat surfaces read a provider's
    /// capabilities from (AppState.aiModelCatalog is this instance; it is
    /// read once at launch, and again by Settings and the chat).
    package static let shared = AIModelCatalog()

    package init() {}

    /// A catalog already read (tests, previews).
    package init(providers: [Provider]) {
        self.providers = providers
    }

    /// Replaces the rows as a read would (tests seed the shared catalog
    /// with the Go-written fixture).
    package func replaceProviders(_ providers: [Provider]) {
        self.providers = providers
    }

    package func provider(_ id: String) -> Provider? {
        providers.first { $0.id == id }
    }

    /// Provider id's capability row; `.none` (offers nothing) for an
    /// unknown id or before the catalog is read.
    package func capabilities(for id: String) -> ProviderCapabilities {
        provider(id)?.capabilities ?? .none
    }

    /// The provider a fallback pairs id with: its row's reserve peer when
    /// that provider names id back; nil when id pairs with nothing.
    package func reservePeer(of id: String) -> String? {
        let peer = capabilities(for: id).reservePeer
        guard !peer.isEmpty, capabilities(for: peer).reservePeer == id else { return nil }
        return peer
    }

    /// Whether the catalog has been read (a row for any provider).
    package var isLoaded: Bool { !providers.isEmpty }

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

        let output = await Self.fetchModels(cliPath: cliPath)
        guard output.exitCode == 0 else {
            let detail = CLILog.detail(output.stderr)
            lastError = "watchtower ai models failed (exit \(output.exitCode))" + (detail.isEmpty ? "" : ": \(detail)")
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

    /// `watchtower ai models --json`, set up off the main actor; the login
    /// environment is awaited, never waited on (`resolvedEnvironmentAsync`).
    nonisolated private static func fetchModels(cliPath: String) async -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        process.arguments = ["ai", "models", "--json"]
        process.environment = await Constants.resolvedEnvironmentAsync()
        return await ProcessPipes.run(process)
    }
}
