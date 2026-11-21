import Foundation
import GRDB

/// One owner-managed external MCP server ("Quick Connections") from the
/// `external_connections` table (internal/db/migrations/00064_external_connections.sql).
/// A lean subset for the list UI — any secret lives only on the Go side and
/// is never read here; `url` and `command` are read for the organization
/// policy's check (#608, `ManagedPolicy.connectionAllowed`), and with `args`
/// (`args_json`) for the connect assistant's `enable` card, which shows the
/// customer exactly what turning the connection on runs.
package struct ExternalConnection: FetchableRecord, Identifiable, Equatable {
    package let id: Int
    package let name: String
    package let kind: String // "stdio" | "http"
    package let enabled: Bool
    package let status: String
    package let error: String
    package let url: String
    package let command: String
    /// The stdio command's arguments; empty when unreadable or for http.
    package let args: [String]

    package init(row: Row) {
        id = row["id"]
        name = row["name"] ?? ""
        kind = row["kind"] ?? "stdio"
        enabled = row["enabled"] ?? false
        status = row["status"] ?? "ok"
        error = row["error"] ?? ""
        url = row["url"] ?? ""
        command = row["command"] ?? ""
        let argsJSON: String = row["args_json"] ?? "[]"
        args = (try? JSONDecoder().decode([String].self, from: Data(argsJSON.utf8))) ?? []
    }

    /// Whether the organization's policy allows this connection (#608).
    package func allowed(by policy: ManagedPolicy) -> Bool {
        policy.connectionAllowed(kind: kind, url: url, command: command)
    }

    package var isOK: Bool { status == "ok" }

    /// Only a new sign-in fixes it (QC-04: invalid_grant, no refresh token, a
    /// rejected client). Any other non-ok status ("error": a network blip, a
    /// 5xx, the tool list) is retried by the next chat or fixed elsewhere, so
    /// the card offers "Sign in again" for this state alone.
    package var needsSignIn: Bool { status == "revoked" }
}
