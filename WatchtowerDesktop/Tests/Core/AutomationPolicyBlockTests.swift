import Foundation
import GRDB
import Testing
@testable import WatchtowerCore

@Suite("AutomationPolicyBlock")
struct AutomationPolicyBlockTests {
    private let acme = ExternalConnection(row: Row(["id": 1, "name": "acme", "kind": "http", "url": "https://other.example.com/mcp"]))
    private let list = ManagedPolicy.normalize(["AllowedQuickConnections": ["https://mcp.example.com"]])

    @Test("shell: is blocked while shell is not allowed, the head case-insensitive and trimmed as in Go")
    func shell() {
        let noShell = ManagedPolicy.normalize(["AllowAutomationShell": false])
        for perm in [#"shell:"make test""#, #"Shell:"x""#, " \n SHELL:\"x\"\n"] {
            #expect(AutomationPolicyBlock.isBlocked(Automation(id: 1, slug: "s", permissions: [perm]), policy: noShell, connections: []),
                    "\(perm)")
        }
        #expect(!AutomationPolicyBlock.isBlocked(Automation(id: 1, slug: "s", permissions: [#"shell:"x""#]), policy: .none,
                                                 connections: []))
    }

    @Test("mcp: is blocked for an existing connection outside the list")
    func mcp() {
        let mcp = Automation(id: 2, slug: "m", permissions: ["MCP:acme/*"])
        #expect(AutomationPolicyBlock.isBlocked(mcp, policy: list, connections: [acme]))
        #expect(!AutomationPolicyBlock.isBlocked(Automation(id: 3, slug: "x", permissions: ["mcp:gone/*"]), policy: list,
                                                 connections: [acme]))
        #expect(!AutomationPolicyBlock.isBlocked(mcp, policy: .none, connections: [acme]))
    }

    @Test("connections not loaded: an mcp: entry under a list fails closed")
    func connectionsNotLoaded() {
        let mcp = Automation(id: 2, slug: "m", permissions: ["mcp:acme/*"])
        #expect(AutomationPolicyBlock.isBlocked(mcp, policy: list, connections: nil))
        #expect(!AutomationPolicyBlock.isBlocked(mcp, policy: .none, connections: nil))
    }
}
