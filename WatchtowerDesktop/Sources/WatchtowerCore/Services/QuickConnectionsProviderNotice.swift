import Foundation

/// Quick Connections (external MCP servers) reach a provider whose
/// capability row says `tools: watchtower+quick_connections` (spec
/// 2026-11-05 §3.3). This is the pure decision behind the Settings caption
/// that tells the owner when their active provider cannot use the
/// connections they have enabled, so "Enabled" is never a silent lie.
package enum QuickConnectionsProviderNotice {
    /// Nil when the provider's transport takes the connections, or when its
    /// row is not known yet (the catalog not read: nil); otherwise the
    /// caption.
    package static func caption(capabilities: ProviderCapabilities?) -> String? {
        guard let capabilities, !capabilities.takesQuickConnections else { return nil }
        return "Quick Connections don't reach the current AI provider. Enabled connections are inert under it."
    }

    /// The UserDefaults key of the one-time codex import notice.
    package static let codexImportNoticeDismissedKey = "quickConnections.codexImportNoticeDismissed"

    /// The one-time notice for codex chat users (board #594): their own
    /// codex MCP servers no longer load in the chat until imported. Nil for
    /// another provider, once dismissed (or after an import), or when their
    /// codex config declares no MCP server (`codex_servers`, nil = unknown).
    package static func codexImportNotice(forProvider provider: String?, dismissed: Bool, codexServers: Int?) -> String? {
        guard provider == "codex", !dismissed, (codexServers ?? 0) > 0 else { return nil }
        return "Your own codex MCP servers are no longer loaded in the Watchtower chat. "
            + "Import them to use them here, with read-only tools only."
    }
}
