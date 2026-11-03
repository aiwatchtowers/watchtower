import Foundation

/// Local metadata from the canonical Go health reader. No auth identity, lease
/// tokens or disk paths cross this boundary. A passed reset never means healthy.
package struct ChatRoutingStatus: Decodable, Equatable, Sendable {
    package struct Provider: Decodable, Equatable, Sendable {
        package let provider: String
        package let state: String
        package let nextProbeAt: Date?
        enum CodingKeys: String, CodingKey {
            case provider, state
            case nextProbeAt = "next_probe_at"
        }
    }
    package let preferredProvider: String
    package let enabled: Bool
    package let revision: String
    package let providers: [Provider]
    enum CodingKeys: String, CodingKey {
        case enabled, revision, providers
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
    package let preferred: ProviderFallbackPreview.Provider
    package let automatic: Bool
    package let actualProvider: String?
    package let actualModel: String?
    package let reason: String?
    package let health: ChatRoutingStatus?
    package let busy: Bool

    package init(
        preferred: ProviderFallbackPreview.Provider,
        automatic: Bool,
        actualProvider: String?,
        actualModel: String?,
        reason: String?,
        health: ChatRoutingStatus?,
        busy: Bool
    ) {
        self.preferred = preferred
        self.automatic = automatic
        self.actualProvider = actualProvider
        self.actualModel = actualModel
        self.reason = reason
        self.health = health
        self.busy = busy
    }
    package var choice: String {
        automatic ? ProviderFallbackPreview.chatPolicyAutomatic + " · Auto"
            : ProviderFallbackPreview.pinnedChoice(provider: preferred.rawValue)
    }
    package var actual: String? {
        guard let actualProvider, !actualProvider.isEmpty else { return nil }
        let provider = ProviderFallbackPreview.Provider.allCases.first { $0.rawValue.lowercased() == actualProvider }?.rawValue
            ?? actualProvider
        return "Current provider: " + provider + (actualModel.flatMap { $0.isEmpty ? nil : " · " + $0 } ?? "")
    }
    package var preview: ProviderFallbackPreview? {
        let state: ProviderFallbackPreview.State
        if !automatic { state = .pinned } else if actualProvider == preferred.other.rawValue.lowercased(), reason == "quota_exhausted" {
            let preferredState = health?.provider(preferred.rawValue.lowercased())?.state
            state = health?.enabled == true && health?.preferredProvider == preferred.rawValue.lowercased()
                && preferredState == "available" ? .recovered : .fallback
        } else if reason == "required_capability_missing" { state = .unsupported } else { return nil }
        let next = health?.provider(preferred.rawValue.lowercased())?.nextProbeAt?
            .formatted(date: .omitted, time: .shortened)
        return ProviderFallbackPreview(preferred: preferred, state: state, nextCheck: next)
    }
    package var canUsePreferred: Bool { preview?.state == .recovered && !busy }
}
