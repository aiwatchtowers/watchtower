import Foundation

/// The plain words of Settings → System → Privacy → Organization policy
/// (#608): one line per key the profile sets, then the reserved keys it sets
/// and any profile problems. Pure. The IT guide row under them is
/// `ManagedPolicyHelp`'s.
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
            let names = a.map(AIModelCatalog.fallbackDisplayName)
            out.append(Line(label: "AI providers", value: a.isEmpty ? "none — AI features cannot run" : list(names)))
        }
        if let b = p.allowClaudeAITools {
            out.append(Line(label: "claude.ai tools in the chat", value: allowed(b)))
        }
        if let b = p.purgeRevokedData {
            out.append(Line(label: "Delete a revoked account's data", value: b ? "on" : "off"))
        }
        if let h = p.purgeGraceHours {
            out.append(Line(label: graceLabel, value: h == 0 ? "none (deleted at the next sync)" : "\(h) hours"))
        } else if p.problems.contains(where: { $0.key == ManagedPolicy.Key.purgeGraceHours.rawValue }) {
            // A refused value leaves the standard notice (`watchtower policy show` says the same).
            out.append(Line(label: graceLabel, value: "72 hours (profile value ignored)"))
        }
        // The company's name only: the bundle carries client ids and secrets.
        if let wire = p.companyBundle, case .success(let bundle) = CompanyBundle.parse(wire, origin: .mdm) {
            out.append(Line(label: "Company", value: bundle.company))
        }
        if let b = p.allowAtlassianAPIToken {
            out.append(Line(label: "Atlassian API tokens", value: allowed(b)))
        }
        if let b = p.allowOwnGoogleProject {
            out.append(Line(label: "Own Google projects", value: allowed(b)))
        }
        if let b = p.allowBackgroundAI {
            out.append(Line(label: "Background AI", value: b ? "Allowed by your organization" : "Turned off by your organization"))
        }
        if let apps = p.slackApps {
            out.append(Line(label: "Slack workspaces set up for you", value: list(apps.map(\.teamID))))
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

    private static let graceLabel = "Notice before data is deleted"

    /// A policy source's name as the Connections tab shows it.
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

    private static func list(_ items: [String]) -> String {
        items.isEmpty ? "none" : items.joined(separator: ", ")
    }

    private static func allowed(_ b: Bool) -> String { b ? "allowed" : "not allowed" }
}
