import GRDB

/// One owner-managed external MCP server ("Quick Connections") from the
/// `external_connections` table (internal/db/migrations/00064_external_connections.sql).
/// A lean subset for the list UI — `command`/`args_json`/`url` (and any secret)
/// live only on the Go side and are never read here.
package struct ExternalConnection: FetchableRecord, Identifiable, Equatable {
    package let id: Int
    package let name: String
    package let kind: String // "stdio" | "http"
    package let enabled: Bool
    package let status: String
    package let error: String

    package init(row: Row) {
        id = row["id"]
        name = row["name"] ?? ""
        kind = row["kind"] ?? "stdio"
        enabled = row["enabled"] ?? false
        status = row["status"] ?? "ok"
        error = row["error"] ?? ""
    }

    package var isOK: Bool { status == "ok" }
}
