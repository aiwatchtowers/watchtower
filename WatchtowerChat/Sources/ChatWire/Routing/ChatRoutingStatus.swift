import Foundation

/// Local metadata from the canonical Go health reader (`ai routing-status`, and the `chat_list` record's
/// `routing.status`). No auth identity, lease tokens or disk paths cross this boundary. A passed reset never means
/// healthy. It decodes the command's bytes (`parse`) and the chat wire's (`ChatWireCoder`, snake_case converted, Unix
/// dates) alike, so one parser reads both.
public struct ChatRoutingStatus: Decodable, Hashable, Sendable {
    public struct Provider: Decodable, Hashable, Sendable {
        public let provider: String
        public let state: String
        public let nextProbeAt: Date?
        public enum ManualCheck: Decodable, Hashable, Sendable {
            case allowed, throttled
            public init(from decoder: Decoder) throws {
                self = try decoder.singleValueContainer().decode(Bool.self) ? .allowed : .throttled
            }
        }
        public var manualAllowed: ManualCheck?

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: WireKey.self)
            provider = try c.required(String.self, "provider")
            state = try c.required(String.self, "state")
            manualAllowed = try c.optional(ManualCheck.self, "manual_allowed")
            nextProbeAt = try c.date("next_probe_at")
        }
    }
    public struct Application: Decodable, Hashable, Sendable {
        public let identity: String
        public let revision: String
        public let preferredProvider: String
        public let savedVersion: String
        public let error: String?

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: WireKey.self)
            identity = try c.required(String.self, "identity")
            revision = try c.required(String.self, "revision")
            preferredProvider = try c.required(String.self, "preferred_provider")
            savedVersion = try c.required(String.self, "saved_version")
            error = try c.optional(String.self, "error")
        }
    }
    public var application: Application?
    public var savedVersion: String?
    public var applicationError: String?
    public let preferredProvider: String
    public let enabled: Bool
    public let revision: String
    public let providers: [Provider]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: WireKey.self)
        application = try c.optional(Application.self, "application")
        savedVersion = try c.optional(String.self, "saved_version")
        applicationError = try c.optional(String.self, "application_error")
        preferredProvider = try c.required(String.self, "preferred_provider")
        enabled = try c.required(Bool.self, "enabled")
        revision = try c.required(String.self, "revision")
        providers = try c.required([Provider].self, "providers")
    }

    public static func parse(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }
    public func provider(_ id: String) -> Provider? { providers.first { $0.provider == id } }
}

/// A key matched as the wire spells it (`preferred_provider`) or as a snake_case-converting decoder hands it
/// (`preferredProvider`).
struct WireKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }

    /// The two spellings of a snake_case key.
    static func spellings(_ snake: String) -> [Self] {
        let parts = snake.split(separator: "_")
        let camel = parts.enumerated().map { $0.offset == 0 ? String($0.element) : $0.element.capitalized }.joined()
        return camel == snake ? [Self(stringValue: snake)] : [Self(stringValue: snake), Self(stringValue: camel)]
    }
}

extension KeyedDecodingContainer where Key == WireKey {
    private func key(_ snake: String) -> WireKey? { WireKey.spellings(snake).first { contains($0) } }

    func optional<T: Decodable>(_ type: T.Type, _ snake: String) throws -> T? {
        guard let key = key(snake) else { return nil }
        return try decodeIfPresent(type, forKey: key)
    }

    func required<T: Decodable>(_ type: T.Type, _ snake: String) throws -> T {
        guard let key = key(snake) else {
            throw DecodingError.keyNotFound(WireKey(stringValue: snake), .init(codingPath: codingPath, debugDescription: "missing \(snake)"))
        }
        return try decode(type, forKey: key)
    }

    /// An RFC 3339 time (with or without fractional seconds), or Unix seconds.
    func date(_ snake: String) throws -> Date? {
        guard let key = key(snake), try !decodeNil(forKey: key) else { return nil }
        if let seconds = try? decode(Double.self, forKey: key) { return Date(timeIntervalSince1970: seconds) }
        let value = try decode(String.self, forKey: key)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) { return date }
        throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Invalid quota timestamp")
    }
}

/// Production chat presentation; the approved catalog owns copy for each state.
public struct ChatRoutingPresentation: Sendable {
    /// The fallback pair (the catalog's `reserve_peer`); nil for a provider
    /// whose capability row has no reserve peer (U3: the line only, no card).
    public let pair: ProviderFallbackPreview.Pair?
    public let automatic: Bool
    public let actualProvider: String?
    public let actualModel: String?
    public let reason: String?
    public let health: ChatRoutingStatus?
    public let busy: Bool
    /// The actual provider's display name (the catalog's), when known.
    public let actualDisplayName: String?
    /// The actual (or chosen) provider's capability row, when known.
    public let capabilities: ChatProviderCaps?

    public init(
        pair: ProviderFallbackPreview.Pair?,
        automatic: Bool,
        actualProvider: String?,
        actualModel: String?,
        reason: String?,
        health: ChatRoutingStatus?,
        busy: Bool,
        actualDisplayName: String? = nil,
        capabilities: ChatProviderCaps? = nil
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
    public var choice: String {
        guard automatic else {
            return ProviderFallbackPreview.pinnedChoice(provider: pair?.preferred.name ?? actualDisplayName ?? "")
        }
        return ProviderFallbackPreview.chatPolicyAutomatic + " · Auto"
    }
    public var actual: String? {
        guard let actualProvider, !actualProvider.isEmpty else { return nil }
        let provider = actualDisplayName ?? pairName(actualProvider) ?? actualProvider
        return "Current provider: " + provider + (actualModel.flatMap { $0.isEmpty ? nil : " · " + $0 } ?? "")
    }
    /// What the provider cannot do, as one caption (U3): nil when it takes
    /// attachments and reads folders, or its row is not known.
    public var missingCapabilities: String? {
        guard let capabilities else { return nil }
        var missing: [String] = []
        if !capabilities.takesAttachments { missing.append("images") } else if !capabilities.pdfs { missing.append("PDFs") }
        if !capabilities.readFolder { missing.append("file reading") }
        guard !missing.isEmpty else { return nil }
        return "No " + missing.joined(separator: " or ") + " with this provider."
    }
    /// The saved quota route and actual capability row remain authoritative
    /// after reopen. Automatic native offerings are not transferred to reserve.
    public var nativeToolsNotice: String? {
        guard automatic, reason == "quota_exhausted", let pair,
              actualProvider == pair.reserve.id, let capabilities, !capabilities.claudeAITools else { return nil }
        return "claude.ai tools are unavailable with \(actualDisplayName ?? pair.reserve.name). This chat continues without them."
    }

    public var preview: ProviderFallbackPreview? {
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
    public var canUsePreferred: Bool { preview?.state == .recovered && !busy }
}
