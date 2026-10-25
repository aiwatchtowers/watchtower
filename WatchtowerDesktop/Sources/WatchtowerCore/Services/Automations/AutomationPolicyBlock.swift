import Foundation

/// Whether the organization's policy (#608) blocks an automation: Go's
/// `automations.CheckManifestPolicy` over the indexed permissions, parsed as
/// Go's `ParsePermission` does (trimmed, the head case-insensitive) — a
/// `shell:` entry while shell is not allowed, or an `mcp:<server>/…` entry
/// whose Quick Connection exists and is outside the allowed list. The card
/// says "Blocked by your organization's policy"; the recipe stays listed.
package enum AutomationPolicyBlock {
    /// `connections` nil = not loaded: an `mcp:` entry under an allowed list
    /// then counts as blocked (fail closed), never silently allowed.
    package static func isBlocked(_ automation: Automation, policy: ManagedPolicy, connections: [ExternalConnection]?) -> Bool {
        let entries = automation.permissions.compactMap(entry)
        if !policy.shellAllowed, entries.contains(where: { $0.head == "shell" }) { return true }
        guard policy.allowedQuickConnections != nil else { return false }
        for e in entries where e.head == "mcp" {
            let server = e.rest.prefix { $0 != "/" }
            guard let connections else { return true }
            if let c = connections.first(where: { $0.name.utf8.elementsEqual(server.utf8) }), !c.allowed(by: policy) {
                return true
            }
        }
        return false
    }

    /// A permission's lowercased head and the text after its first ":".
    private static func entry(_ raw: String) -> (head: String, rest: Substring)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = s.firstIndex(of: ":") else { return nil }
        return (s[..<colon].lowercased(), s[s.index(after: colon)...])
    }
}
