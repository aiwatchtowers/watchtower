import Foundation

/// The plain words of Settings → System → Privacy → Organization policy
/// (#608): one line per key the profile sets, then the reserved keys it sets
/// and any profile problems. Pure.
package enum OrganizationPolicyPresentation {
    package struct Line: Equatable, Sendable {
        package let label: String
        package let value: String
    }

    package static func lines(_ p: ManagedPolicy) -> [Line] {
        var out: [Line] = []
        if let s = p.allowedSources {
            out.append(Line(label: "Sources you can connect", value: list(s.map(sourceName))))
        }
        if let m = p.mobileSync {
            out.append(Line(label: "iPhone", value: m.replacingOccurrences(of: "_", with: " ")))
        }
        if let c = p.allowedQuickConnections {
            out.append(Line(label: "Quick Connections you can use", value: list(c)))
        }
        if let b = p.allowAutomationShell {
            out.append(Line(label: "Shell commands in automations", value: allowed(b)))
        }
        if let a = p.allowedAIProviders {
            out.append(Line(label: "AI providers", value: list(a.map(providerName))))
        }
        if let b = p.allowClaudeAITools {
            out.append(Line(label: "claude.ai tools in the chat", value: allowed(b)))
        }
        if let b = p.purgeRevokedData {
            out.append(Line(label: "Delete a revoked account's data", value: b ? "on" : "off"))
        }
        if !p.reservedNotEnforced.isEmpty {
            out.append(Line(label: "Not enforced in this version", value: p.reservedNotEnforced.joined(separator: ", ")))
        }
        if !p.problems.isEmpty {
            let problems = p.problems.map { "\($0.key) (\($0.problem.replacingOccurrences(of: "_", with: " ")))" }
            out.append(Line(label: "Profile problems", value: problems.joined(separator: ", ")))
        }
        return out
    }

    /// A policy source's name as Settings → Connections shows it.
    package static func sourceName(_ source: String) -> String {
        switch source {
        case "slack": "Slack"
        case "google": "Google (Gmail, Calendar)"
        case "imap": "Email (IMAP, Outlook)"
        case "caldav": "CalDAV calendars"
        case "jira": "Jira and Confluence"
        case "linear": "Linear"
        default: source
        }
    }

    package static func providerName(_ id: String) -> String {
        switch id {
        case "claude": "Claude"
        case "codex": "Codex"
        case "ollama": "Ollama"
        default: id
        }
    }

    private static func list(_ items: [String]) -> String {
        items.isEmpty ? "none" : items.joined(separator: ", ")
    }

    private static func allowed(_ b: Bool) -> String { b ? "allowed" : "not allowed" }
}
