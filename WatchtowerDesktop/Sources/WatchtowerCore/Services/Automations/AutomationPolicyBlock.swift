import Foundation

/// Whether the organization's policy (#608) blocks an automation: Go's
/// `automations.CheckManifestPolicy` over the indexed permissions — a
/// `shell:` entry while shell is not allowed, or an `mcp:<server>/…` entry
/// whose Quick Connection exists and is outside the allowed list. The card
/// says "Blocked by your organization's policy"; the recipe stays listed.
package enum AutomationPolicyBlock {
    package static func isBlocked(_ automation: Automation, policy: ManagedPolicy, connections: [ExternalConnection]) -> Bool {
        let perms = automation.permissions.map { $0.trimmingCharacters(in: .whitespaces) }
        if !policy.shellAllowed, perms.contains(where: { $0.hasPrefix("shell:") }) { return true }
        guard policy.allowedQuickConnections != nil else { return false }
        for perm in perms where perm.hasPrefix("mcp:") {
            let server = String(perm.dropFirst("mcp:".count).prefix { $0 != "/" })
            if let c = connections.first(where: { $0.name == server }), !c.allowed(by: policy) { return true }
        }
        return false
    }
}
