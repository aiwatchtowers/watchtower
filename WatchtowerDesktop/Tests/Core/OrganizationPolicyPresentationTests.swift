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
