import Foundation

/// One connection's tool list as `watchtower connections tools <id> --json`
/// prints it (`cmd/connections_tools.go`'s `connectionToolsJSON`). The
/// verdicts come from Go (`externalmcp.ResolveTools`/`IsReadOnly`/
/// `IsAnnotatedWrite`) — the Desktop never re-derives the QC-02 policy, it
/// only renders it and builds the next `--allow` list from it.
package struct ExternalConnectionTools: Decodable, Equatable {
    package let id: Int64
    package let name: String
    /// False until the server's `tools/list` was cached once; no tool is
    /// available to the chat before that (fail closed).
    package let listed: Bool
    package let listedAt: String?
    /// The owner's explicit allow list replaces the read-only default.
    package let explicit: Bool
    package let tools: [Tool]

    package struct Tool: Decodable, Equatable, Identifiable {
        package let name: String
        package let allowed: Bool
        package let readOnly: Bool
        /// The server declares it a write: no allow list admits it (QC-02,
        /// owner decision 2026-10-02), so it gets no toggle.
        package let write: Bool

        package var id: String { name }

        package enum Kind: Equatable { case readOnly, unmarked, write }

        package var kind: Kind {
            if write { return .write }
            return readOnly ? .readOnly : .unmarked
        }

        package var canToggle: Bool { !write }

        enum CodingKeys: String, CodingKey {
            case name, allowed, write
            case readOnly = "read_only"
        }

        package init(name: String, allowed: Bool, readOnly: Bool, write: Bool) {
            self.name = name
            self.allowed = allowed
            self.readOnly = readOnly
            self.write = write
        }

        package init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            allowed = try c.decode(Bool.self, forKey: .allowed)
            readOnly = try c.decode(Bool.self, forKey: .readOnly)
            // A CLI older than the field: a write tool then shows a toggle,
            // and `--allow` refuses it with a visible error.
            write = try c.decodeIfPresent(Bool.self, forKey: .write) ?? false
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, listed, explicit, tools
        case listedAt = "listed_at"
    }

    package init(id: Int64, name: String, listed: Bool, listedAt: String?, explicit: Bool, tools: [Tool]) {
        self.id = id
        self.name = name
        self.listed = listed
        self.listedAt = listedAt
        self.explicit = explicit
        self.tools = tools
    }

    /// `connections tools <id> --json`: the current list, read-only.
    package static func listArgs(id: Int64, refresh: Bool = false) -> [String] {
        ["connections", "tools", String(id)] + (refresh ? ["--refresh"] : []) + ["--json"]
    }

    /// `connections tools <id> --default --json`: back to the read-only default.
    package static func defaultArgs(id: Int64) -> [String] {
        ["connections", "tools", String(id), "--default", "--json"]
    }

    /// The command that turns `tool` on or off, built from this (fresh)
    /// snapshot: the tools allowed now, plus or minus `tool`. A set equal to
    /// the read-only default goes back to `--default`, so tools the server
    /// adds later keep following the default; any other set is an explicit
    /// list, one `--allow=<name>` each (`--allow=` alone allows none). Tools
    /// allowed now are all listed and not writes, so `--allow` accepts them.
    package func allowArgs(setting tool: String, allowed: Bool) -> [String] {
        let names = tools
            .filter { $0.name == tool ? allowed : $0.allowed }
            .map(\.name)
        let readOnlyNames = tools.filter(\.readOnly).map(\.name)
        if Set(names) == Set(readOnlyNames) {
            return Self.defaultArgs(id: id)
        }
        let allow = names.isEmpty ? ["--allow="] : names.map { "--allow=\($0)" }
        return ["connections", "tools", String(id)] + allow + ["--json"]
    }
}
