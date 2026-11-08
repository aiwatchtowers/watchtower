import Foundation

/// Local metadata from the canonical Go health reader. No auth identity, lease
/// tokens or disk paths cross this boundary. A passed reset never means healthy.
package struct ChatRoutingStatus: Decodable, Equatable, Sendable {
    package struct Provider: Decodable, Equatable, Sendable {
        package let provider: String
        package let state: String
        package let nextProbeAt: Date?
        package enum ManualCheck: Decodable, Equatable, Sendable {
            case allowed, throttled
            package init(from decoder: Decoder) throws {
                self = try decoder.singleValueContainer().decode(Bool.self) ? .allowed : .throttled
            }
        }
        package var manualAllowed: ManualCheck?
        enum CodingKeys: String, CodingKey {
            case provider, state
            case manualAllowed = "manual_allowed"
            case nextProbeAt = "next_probe_at"
        }
    }
    package struct Application: Decodable, Equatable, Sendable {
        package let identity: String
        package let revision: String
        package let preferredProvider: String
        package let savedVersion: String
        package let error: String?
        enum CodingKeys: String, CodingKey {
            case identity, revision, error
            case preferredProvider = "preferred_provider"
            case savedVersion = "saved_version"
        }
    }
    package var application: Application?
    package var savedVersion: String?
    package var applicationError: String?
    package let preferredProvider: String
    package let enabled: Bool
    package let revision: String
    package let providers: [Provider]
    enum CodingKeys: String, CodingKey {
        case enabled, revision, providers, application
        case applicationError = "application_error"
        case savedVersion = "saved_version"
        case preferredProvider = "preferred_provider"
    }
    package static func parse(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid quota timestamp"))
        }
        return try decoder.decode(Self.self, from: data)
    }
    package func provider(_ id: String) -> Provider? { providers.first { $0.provider == id } }
}

/// Production chat presentation; the approved catalog owns copy for each state.
package struct ChatRoutingPresentation {
    /// The fallback pair (the catalog's `reserve_peer`); nil for a provider
    /// whose capability row has no reserve peer (U3: the line only, no card).
    package let pair: ProviderFallbackPreview.Pair?
    package let automatic: Bool
    package let actualProvider: String?
    package let actualModel: String?
    package let reason: String?
    package let health: ChatRoutingStatus?
    package let busy: Bool
    /// The actual provider's display name (the catalog's), when known.
    package let actualDisplayName: String?
    /// The actual (or chosen) provider's capability row, when known.
    package let capabilities: ProviderCapabilities?

    package init(
        pair: ProviderFallbackPreview.Pair?,
        automatic: Bool,
        actualProvider: String?,
        actualModel: String?,
        reason: String?,
        health: ChatRoutingStatus?,
        busy: Bool,
        actualDisplayName: String? = nil,
        capabilities: ProviderCapabilities? = nil
    ) {
        self.actualDisplayName = actualDisplayName
        self.capabilities = capabilities
        self.pair = pair
        self.automatic = automatic
        self.actualProvider = actualProvider
        self.actualModel = actualModel
        self.reason = reason
        self.health = health
        self.busy = busy
    }
    package var choice: String {
        guard automatic else {
            return ProviderFallbackPreview.pinnedChoice(provider: pair?.preferred.name ?? actualDisplayName ?? "")
        }
        return ProviderFallbackPreview.chatPolicyAutomatic + " · Auto"
    }
    package var actual: String? {
        guard let actualProvider, !actualProvider.isEmpty else { return nil }
        let provider = actualDisplayName ?? pairName(actualProvider) ?? actualProvider
        return "Current provider: " + provider + (actualModel.flatMap { $0.isEmpty ? nil : " · " + $0 } ?? "")
    }
    /// What the provider cannot do, as one caption (U3): nil when it takes
    /// attachments and reads folders, or its row is not known.
    package var missingCapabilities: String? {
        guard let capabilities else { return nil }
        var missing: [String] = []
        if !capabilities.takesAttachments { missing.append("images") } else if !capabilities.pdfs { missing.append("PDFs") }
        if !capabilities.readsFolder { missing.append("file reading") }
        guard !missing.isEmpty else { return nil }
        return "No " + missing.joined(separator: " or ") + " with this provider."
    }
    /// The saved quota route and actual capability row remain authoritative
    /// after reopen. Automatic native offerings are not transferred to reserve.
    package var nativeToolsNotice: String? {
        guard automatic, reason == "quota_exhausted", let pair,
              actualProvider == pair.reserve.id, let capabilities, !capabilities.claudeAITools else { return nil }
        return "claude.ai tools are unavailable with \(actualDisplayName ?? pair.reserve.name). This chat continues without them."
    }

    package var preview: ProviderFallbackPreview? {
        guard let pair else { return nil }
        let state: ProviderFallbackPreview.State
        if !automatic { state = .pinned } else if actualProvider == pair.reserve.id, reason == "quota_exhausted" {
            let preferredState = health?.provider(pair.preferred.id)?.state
            // Available includes a fresh/missing scope, not observed background completion.
            state = health?.enabled == true && health?.preferredProvider == pair.preferred.id
                && preferredState == "available" ? .recovered : .fallback
        } else if reason == "required_capability_missing" { state = .unsupported } else { return nil }
        let next = health?.provider(pair.preferred.id)?.nextProbeAt?
            .formatted(date: .omitted, time: .shortened)
        return ProviderFallbackPreview(pair: pair, state: state, nextCheck: next,
                                       observedProvider: actualProvider.map { pairName($0) ?? $0 }, observedModel: actualModel)
    }
    /// The display name of a provider id on either side of the pair.
    private func pairName(_ id: String) -> String? {
        pair.flatMap { [$0.preferred, $0.reserve].first { $0.id == id }?.name }
    }
    package var canUsePreferred: Bool { preview?.state == .recovered && !busy }
}
