import Foundation

/// The MCP servers of the owner's own codex and Claude Code configs, as
/// `watchtower connections import --json` lists them
/// (`cmd/connections_import.go`'s `connectionImportListJSON`). Which ones can
/// be imported, and why not, is Go's verdict (`externalmcp.DiscoverImports`);
/// the Desktop only renders it. Secrets never reach this JSON.
package struct ExternalConnectionImportList: Decodable, Equatable {
    package let servers: [Server]
    package let warnings: [String]
    /// The two files the CLI read (nil from an older CLI).
    package let sources: Sources?
    /// How many servers the codex config declares, importable or not.
    package let codexServers: Int?

    package struct Sources: Decodable, Equatable {
        package let codex: String
        package let claude: String

        package init(codex: String, claude: String) {
            self.codex = codex
            self.claude = claude
        }

        /// "<codex path> and <claude path>", the home folder shown as ~.
        package func described(home: String = NSHomeDirectory()) -> String {
            "\(Self.tilde(codex, home: home)) and \(Self.tilde(claude, home: home))"
        }

        package static func tilde(_ path: String, home: String) -> String {
            path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        }
    }

    enum CodingKeys: String, CodingKey {
        case servers, warnings, sources
        case codexServers = "codex_servers"
    }

    package struct Server: Decodable, Equatable, Identifiable {
        package let name: String
        /// "codex" or "claude".
        package let source: String
        package let kind: String
        package let command: String?
        package let url: String?
        /// Why it cannot be imported; nil when it can.
        package let skip: String?
        /// Why its name differs from the one in its config.
        package let note: String?
        /// False when its config turned it off: it is imported disabled,
        /// and the sheet leaves it unticked.
        package let enabled: Bool

        package var id: String { name }
        package var canImport: Bool { (skip ?? "").isEmpty }
        /// Ticked when the sheet opens.
        package var pickedByDefault: Bool { canImport && enabled }

        /// What the row shows under the name: the command or the URL.
        package var target: String { (kind == "http" ? url : command) ?? "" }

        enum CodingKeys: String, CodingKey {
            case name, source, kind, command, url, skip, note, enabled
        }

        package init(
            name: String,
            source: String,
            kind: String,
            command: String?,
            url: String?,
            skip: String?,
            note: String? = nil,
            enabled: Bool = true
        ) {
            self.name = name
            self.source = source
            self.kind = kind
            self.command = command
            self.url = url
            self.skip = skip
            self.note = note
            self.enabled = enabled
        }

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            source = try c.decode(String.self, forKey: .source)
            kind = try c.decode(String.self, forKey: .kind)
            command = try c.decodeIfPresent(String.self, forKey: .command)
            url = try c.decodeIfPresent(String.self, forKey: .url)
            skip = try c.decodeIfPresent(String.self, forKey: .skip)
            note = try c.decodeIfPresent(String.self, forKey: .note)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        }
    }

    package init(servers: [Server], warnings: [String], sources: Sources? = nil, codexServers: Int? = nil) {
        self.servers = servers
        self.warnings = warnings
        self.sources = sources
        self.codexServers = codexServers
    }

    /// `connections import --json`: what can be imported, read-only.
    package static let listArgs = ["connections", "import", "--json"]

    /// `connections import --json -- <name>…`: imports and enables them.
    package static func importArgs(names: [String]) -> [String] {
        listArgs + ["--"] + names
    }
}

/// One imported name, as `connections import --json <name>…` reports it
/// (`connectionImportResultJSON`). `id` is nil when nothing was created.
/// `signIn`: an http server with no headers whose tools could not be listed
/// — it most likely needs an OAuth sign-in (`connections oauth <id>`).
package struct ExternalConnectionImportResult: Decodable, Equatable {
    package let name: String
    package let id: Int64?
    package let status: String?
    package let error: String?
    package let signIn: Bool

    enum CodingKeys: String, CodingKey {
        case name, id, status, error
        case signIn = "sign_in"
    }

    /// The line the import sheet shows when nothing was created.
    package var failure: String? {
        id == nil ? "\(name): \(error ?? "not imported")" : nil
    }
}
