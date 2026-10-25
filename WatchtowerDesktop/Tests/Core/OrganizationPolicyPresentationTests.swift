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
            "AI providers: Claude, Ollama",
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
}
