import Foundation

/// The provider/model registry as reported by `watchtower ai models --json`.
/// This is the Desktop app's single source of model lists — no model names
/// are hardcoded in Swift. `load()` is best-effort: on any failure the
/// catalog keeps its rows (empty before the first read), logs the failure's
/// class, and `unreadReason` names it on the surfaces it degrades.
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

    /// What a capability-gated surface shows while it runs degraded because
    /// no read has succeeded (draft-only chats, a code question without the
    /// folder).
    package static let unreadNotice = "Provider capabilities could not be read — see Settings → System → AI."

    /// `unreadNotice` when the last read failed and no earlier one gave rows;
    /// nil while the rows are known or before any read finished.
    package var unreadReason: String? { !isLoaded && lastError != nil ? Self.unreadNotice : nil }

    /// `watchtower ai models --json`'s output; nil when the CLI is not found.
    package typealias Fetch = @Sendable () async -> ProcessOutput?

    /// Posted on the main actor after a read replaced the rows: surfaces that
    /// decided something before the catalog was read (AGENT-04's tool
    /// access) decide again.
    package static let didLoadNotification = Notification.Name("AIModelCatalog.didLoad")

    /// The app's one catalog: what the chat surfaces read a provider's
    /// capabilities from (AppState.aiModelCatalog is this instance; it is
    /// read at launch, tray-only included, and again by Settings and the chat).
    package static let shared = AIModelCatalog()

    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    package init(fetch: @escaping Fetch = AIModelCatalog.fetchFromCLI) {
        self.fetch = fetch
    }

    /// A catalog already read (tests, previews).
    package init(providers: [Provider]) {
        fetch = Self.fetchFromCLI
        self.providers = providers
    }

    /// Replaces the rows as a read would (tests seed the shared catalog
    /// with the Go-written fixture), and says so like a read.
    package func replaceProviders(_ providers: [Provider]) {
        self.providers = providers
        NotificationCenter.default.post(name: Self.didLoadNotification, object: self)
    }

    package func provider(_ id: String) -> Provider? {
        providers.first { $0.id == id }
    }

    /// The providers' ids in the catalog's order: the one list the provider
    /// pickers and the chat's menu offer (A7b). Empty before the first read.
    package var providerIDs: [String] { providers.map(\.id) }

    /// Provider id's display name: its catalog row's, else
    /// `fallbackDisplayName` (before the first read, or a failed one).
    package func displayName(_ id: String) -> String {
        provider(id)?.displayName ?? Self.fallbackDisplayName(id)
    }

    /// The display name shown before the catalog is read: a presentation
    /// fallback only, pinned to the Go catalog's `display_name` by
    /// `ProviderCatalogRegistryTests`; an id it does not know shows as itself.
    nonisolated package static func fallbackDisplayName(_ id: String) -> String {
        switch id {
        case "claude": "Claude"
        case "codex": "Codex"
        case "ollama": "Ollama / Local"
        default: id
        }
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

    /// Provider id as one side of a fallback pair: its display name from the
    /// row, the id itself when the row is not known.
    package func fallbackSide(_ id: String) -> ProviderFallbackPreview.Provider {
        .init(id: id, name: provider(id)?.displayName ?? id)
    }

    /// The fallback pair with id preferred; nil when id pairs with nothing
    /// or the catalog is not read yet (no routing card, no reserve).
    package func fallbackPair(preferred id: String) -> ProviderFallbackPreview.Pair? {
        reservePeer(of: id).map { .init(preferred: fallbackSide(id), reserve: fallbackSide($0)) }
    }

    /// Whether provider id is a local HTTP server (the registry's `kind`,
    /// runtime B): a server URL instead of a CLI path, tested over HTTP, and
    /// the draft-only surfaces of AGENT-04. False for an unknown id.
    package func isLocalServer(_ id: String) -> Bool {
        provider(id)?.kind == "http"
    }

    /// Whether provider id is known to run as a CLI child (the registry's
    /// `kind`): false for a local server, an unknown id or a catalog not read
    /// yet, so AGENT-04's tool surfaces fail closed.
    package func isKnownCLI(_ id: String) -> Bool {
        provider(id)?.kind == "cli"
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

    /// Fetch the registry from the CLI. Safe to call repeatedly: a call
    /// while a read runs waits for that read instead of starting another.
    package func load() async {
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { await performLoad() }
        loadTask = task
        await task.value
        loadTask = nil
    }

    /// Returns when the read in flight, if any, has finished; starts none.
    package func readInFlight() async {
        await loadTask?.value
    }

    /// The launch read: `load()`, tried again after each of `retryDelays`
    /// while it keeps failing (a CLI not resolved yet at launch, a crash),
    /// so the capability rows do not wait for the Chat tab or Settings to
    /// open. Stops at the first success, including another caller's read
    /// during a wait, and when the task is cancelled.
    package func loadRetrying(
        retryDelays: [Duration] = [.seconds(5), .seconds(30), .seconds(120)],
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async {
        await load()
        for delay in retryDelays {
            guard lastError != nil else { return }
            do { try await sleep(delay) } catch { return }
            guard lastError != nil else { return }
            await load()
        }
    }

    private func performLoad() async {
        isLoading = true
        defer { isLoading = false }
        guard let output = await fetch() else {
            fail("watchtower CLI not found", logged: "cli_not_found")
            return
        }
        guard output.exitCode == 0 else {
            let detail = CLILog.detail(output.stderr)
            fail("watchtower ai models failed (exit \(output.exitCode))" + (detail.isEmpty ? "" : ": \(detail)"),
                 logged: "exit \(output.exitCode)")
            return
        }
        do {
            let parsed = try Self.parse(Data(output.stdout.utf8))
            lastError = nil
            replaceProviders(parsed.providers)
        } catch {
            fail("parsing ai models output: \(error.localizedDescription)", logged: "unparsable output")
        }
    }

    /// A failed read: the owner's text in `lastError` (Settings shows it),
    /// only the class in the log — the CLI's stderr can carry paths and
    /// names (FILES-01).
    private func fail(_ message: String, logged failureClass: String) {
        lastError = message
        NSLog("AIModelCatalog: reading the provider catalog failed: %@", failureClass)
    }

    /// The production read: the CLI found by `Constants.findCLIPath`.
    nonisolated package static func fetchFromCLI() async -> ProcessOutput? {
        guard let cliPath = Constants.findCLIPath() else { return nil }
        return await fetchModels(cliPath: cliPath)
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
