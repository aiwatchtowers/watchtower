import Foundation

/// How a provider's agent can guide the owner through connecting a source
/// (agent connect spec §5.2): the Go capability table's `connect` column
/// (`internal/providers/caps`), read from `ai models --json`.
package enum ConnectCapability: String, Sendable {
    /// The agent drives the owner's browser.
    case browser
    /// The agent tells each step in text and checks it.
    case words
    /// The provider offers no connect assistant.
    case none
}

/// A provider the connect assistant can run on: its id, display name and
/// connect capability, all from the provider catalog (LLMTRANSPORT-01: the
/// assistant decides by `capability`, never by `id`).
package struct ConnectHarness: Equatable, Hashable, Sendable {
    package let id: String
    package let name: String
    package let capability: ConnectCapability

    package init(id: String, name: String, capability: ConnectCapability) {
        self.id = id
        self.name = name
        self.capability = capability
    }
}

/// Which harnesses the connect assistant offers (spec §5.2).
package enum ConnectHarnessCatalog {
    /// The harnesses the assistant may run on and the one it opens with.
    ///
    /// - Parameters:
    ///   - providers: the catalog's providers (`ai models --json`), in its order.
    ///   - allowed: the managed policy's allowed provider ids; nil when no policy limits them.
    ///   - ready: the providers whose CLI is installed and signed in (`ai test --json`).
    ///   - base: the owner's base provider from onboarding.
    /// - Returns: every provider that can connect (`connect` is not `none`),
    ///   is allowed and is ready; `initial` is `base` when it is offered, else
    ///   the first offered one, else nil — then no entry point shows a button.
    package static func offered(
        providers: [AIModelCatalog.Provider],
        allowed: [String]?,
        ready: Set<String>,
        base: String
    ) -> (harnesses: [ConnectHarness], initial: ConnectHarness?) {
        let harnesses = providers.compactMap { provider -> ConnectHarness? in
            let capability = provider.capabilities?.connectMode ?? ConnectCapability.none
            guard capability != .none,
                  allowed?.contains(provider.id) ?? true,
                  ready.contains(provider.id) else { return nil }
            return ConnectHarness(id: provider.id, name: provider.displayName, capability: capability)
        }
        return (harnesses, harnesses.first { $0.id == base } ?? harnesses.first)
    }
}
