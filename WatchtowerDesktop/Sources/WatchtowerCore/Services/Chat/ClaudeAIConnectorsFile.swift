import Foundation

/// The claude.ai connector list the main chat's `ai session` writes beside
/// the database (#737, spec D2). Go is the only writer; the contract is the
/// comment at the top of `internal/chat/connectors.go`, pinned by the fixture
/// `internal/chat/testdata/claude_ai_connectors.json`. Keys this type does not
/// know are ignored, and a status other than the five it knows reads as
/// `failed`, as Go writes it.
package struct ClaudeAIConnectorsFile: Decodable, Equatable, Sendable {
    /// Go's `chat.ConnectorsFileName`, in the database's directory.
    package static let fileName = "claude-ai-connectors.json"

    package enum Status: String, Sendable {
        case connected
        case needsAuth = "needs-auth"
        case failed
        case pending
        case disabled
    }

    package struct Tool: Decodable, Equatable, Sendable {
        package let name: String
        /// True only when the connector declares the hint; absent reads false.
        package let readOnly: Bool
        package let destructive: Bool

        package init(name: String, readOnly: Bool = false, destructive: Bool = false) {
            self.name = name
            self.readOnly = readOnly
            self.destructive = destructive
        }

        private enum CodingKeys: String, CodingKey {
            case name
            case readOnly = "read_only"
            case destructive
        }

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
            destructive = try c.decodeIfPresent(Bool.self, forKey: .destructive) ?? false
        }
    }

    package struct Server: Decodable, Equatable, Sendable, Identifiable {
        package var id: String { name }
        /// The display name without the "claude.ai " prefix — the spelling
        /// `ai.claude_ai.disabled_connectors` holds.
        package let name: String
        package let status: Status
        package let tools: [Tool]

        package init(name: String, status: Status, tools: [Tool] = []) {
            self.name = name
            self.status = status
            self.tools = tools
        }

        private enum CodingKeys: String, CodingKey { case name, status, tools }

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            status = Status(rawValue: try c.decode(String.self, forKey: .status)) ?? .failed
            tools = try c.decodeIfPresent([Tool].self, forKey: .tools) ?? []
        }
    }

    package let updatedAt: Date
    /// False: claude.ai tools are off for the main chat, for `unavailableReason`.
    package let available: Bool
    package let unavailableReason: String
    package let servers: [Server]

    package init(updatedAt: Date, available: Bool, unavailableReason: String = "", servers: [Server]) {
        self.updatedAt = updatedAt
        self.available = available
        self.unavailableReason = unavailableReason
        self.servers = servers
    }

    private enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case available
        case unavailableReason = "unavailable_reason"
        case servers
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let stamp = try c.decode(String.self, forKey: .updatedAt)
        guard let date = ISO8601DateFormatter().date(from: stamp) else {
            throw DecodingError.dataCorruptedError(forKey: .updatedAt, in: c,
                                                   debugDescription: "not an RFC 3339 time: \(stamp)")
        }
        updatedAt = date
        available = try c.decode(Bool.self, forKey: .available)
        unavailableReason = try c.decodeIfPresent(String.self, forKey: .unavailableReason) ?? ""
        servers = try c.decodeIfPresent([Server].self, forKey: .servers) ?? []
    }

    /// The file at `path`; nil when there is none yet (no main-chat session
    /// has listed the connectors). A file that is present but unreadable or
    /// undecodable throws — it is not "no file".
    package static func read(at path: String) throws -> Self? {
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch let error as DecodingError {
            throw ClaudeAIConnectorsReadError(message: "\(fileName) is not in the expected shape: \(error.detail)")
        }
    }
}

/// A file the claude.ai section reads is present but can't be used; the
/// message says which and why.
package struct ClaudeAIConnectorsReadError: LocalizedError, Equatable {
    package let message: String
    package var errorDescription: String? { message }
}

private extension DecodingError {
    /// The coding path and the decoder's own description, which
    /// `localizedDescription` drops.
    var detail: String {
        let context: Context
        switch self {
        case let .typeMismatch(_, c), let .valueNotFound(_, c), let .keyNotFound(_, c), let .dataCorrupted(c): context = c
        @unknown default: return String(describing: self)
        }
        let path = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
    }
}
