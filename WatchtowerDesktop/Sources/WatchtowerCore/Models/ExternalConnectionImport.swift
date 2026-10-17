import Foundation

/// The MCP servers of the owner's own codex and Claude Code configs, as
/// `watchtower connections import --json` lists them
/// (`cmd/connections_import.go`'s `connectionImportListJSON`). Which ones can
/// be imported, and why not, is Go's verdict (`externalmcp.DiscoverImports`);
/// the Desktop only renders it. Secrets never reach this JSON.
package struct ExternalConnectionImportList: Decodable, Equatable {
    package let servers: [Server]
    package let warnings: [String]

    package struct Server: Decodable, Equatable, Identifiable {
        package let name: String
        /// "codex" or "claude".
        package let source: String
        package let kind: String
        package let command: String?
        package let url: String?
        /// Why it cannot be imported; nil when it can.
        package let skip: String?

        package var id: String { name }
        package var canImport: Bool { (skip ?? "").isEmpty }

        /// What the row shows under the name: the command or the URL.
        package var target: String { (kind == "http" ? url : command) ?? "" }

        enum CodingKeys: String, CodingKey {
            case name, source, kind, command, url, skip
        }

        package init(name: String, source: String, kind: String, command: String?, url: String?, skip: String?) {
            self.name = name
            self.source = source
            self.kind = kind
            self.command = command
            self.url = url
            self.skip = skip
        }
    }

    package init(servers: [Server], warnings: [String]) {
        self.servers = servers
        self.warnings = warnings
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
