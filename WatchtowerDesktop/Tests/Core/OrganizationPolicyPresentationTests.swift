import Foundation
import Testing
@testable import WatchtowerCore

@Suite("OrganizationPolicyPresentation")
struct OrganizationPolicyPresentationTests {
    private func text(_ raw: [String: Any]) -> [String] {
        OrganizationPolicyPresentation.lines(ManagedPolicy.normalize(raw)).map { "\($0.label): \($0.value)" }
    }

    @Test("no profile, no lines")
    func noPolicyNoLines() {
        #expect(OrganizationPolicyPresentation.lines(.none).isEmpty)
    }

    @Test("each key in plain words")
    func eachKeyInPlainWords() {
        #expect(text([
            "AllowedSources": ["slack", "jira"],
            "MobileSync": "workbench_only",
            "AllowedQuickConnections": ["https://mcp.example.com/"],
            "AllowAutomationShell": false,
            "AllowedAIProviders": ["claude", "ollama"],
            "AllowClaudeAITools": true,
            "PurgeRevokedData": true
        ]) == [
            "Sources you can connect: Slack, Jira and Confluence",
            "iPhone: workbench only",
            "Quick Connections you can use: https://mcp.example.com/",
            "Shell commands in automations: not allowed",
            "AI providers: Claude, Ollama / Local",
            "claude.ai tools in the chat: allowed",
            "Delete a revoked account's data: on"
        ])
    }

    @Test("PurgeGraceHours: hours, none for 0, the standard notice for a refused value")
    func graceLine() {
        #expect(text(["PurgeGraceHours": 24]) == ["Notice before data is deleted: 24 hours"])
        #expect(text(["PurgeGraceHours": 0]) == ["Notice before data is deleted: none (deleted at the next sync)"])
        #expect(text(["PurgeGraceHours": 1000]) == [
            "Notice before data is deleted: 72 hours (profile value ignored)",
            "Profile problems: PurgeGraceHours (unknown value)"
        ])
        #expect(text(["PurgeGraceHours": "24"]) == [
            "Notice before data is deleted: 72 hours (profile value ignored)",
            "Profile problems: PurgeGraceHours (wrong type)"
        ])
    }

    @Test("the company keys: the company's name only, never the bundle; tokens and own projects")
    func newKeyLines() {
        let base64 = Data(#"{"v":1,"company":"Acme","linear":{"client_id":"lin-acme-1"}}"#.utf8).base64EncodedString()
        let wire = base64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let lines = text([
            "CompanyBundle": wire,
            "AllowAtlassianAPIToken": false,
            "AllowOwnGoogleProject": true
        ])
        #expect(lines == [
            "Company: Acme",
            "Atlassian API tokens: not allowed",
            "Own Google projects: allowed"
        ])
        #expect(!lines.joined().contains(wire))
        #expect(!lines.joined().contains("lin-acme-1"))
    }

    @Test("a refused company bundle shows no company line, only the problem")
    func refusedBundleHasNoCompanyLine() {
        #expect(text(["CompanyBundle": "not-a-bundle"]) == ["Profile problems: CompanyBundle (invalid entry)"])
    }

    @Test("Background AI in plain words")
    func backgroundAIInPlainWords() {
        #expect(text(["AllowBackgroundAI": true]) == ["Background AI: Allowed by your organization"])
        #expect(text(["AllowBackgroundAI": false]) == ["Background AI: Turned off by your organization"])
    }

    @Test("reserved keys and profile problems are listed")
    func problemsAndReservedListed() {
        #expect(text(["RetentionDays": 30, "AllowAutomationShell": 1]) == [
            "Shell commands in automations: not allowed",
            "Not enforced in this version: RetentionDays",
            "Profile problems: AllowAutomationShell (wrong type)"
        ])
    }

    @Test("an empty list says none")
    func emptySourcesSaysNone() {
        #expect(text(["AllowedSources": [String](), "AllowedAIProviders": [String]()]) == [
            "Sources you can connect: none",
            "AI providers: none — AI features cannot run"
        ])
    }

    @Test("SlackApps lists the workspaces it sets up")
    func slackAppsListed() {
        let apps: [[String: Any]] = [
            ["team_id": "T0ACME", "client_id": "1111.2222"],
            ["team_id": "T0BETA", "client_id": "3333.4444"]
        ]
        #expect(text(["SlackApps": apps])
            == ["Slack workspaces set up for you: T0ACME, T0BETA"])
        #expect(text(["SlackApps": [Any]()]) == ["Slack workspaces set up for you: none"])
    }
}
