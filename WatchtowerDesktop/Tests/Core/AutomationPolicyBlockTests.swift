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

    @Test("the shared fixture with Go's CheckManifestPolicy")
    func sharedFixture() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/automations/testdata/policy_block_cases.json")
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let conns = try #require(obj["connections"] as? [[String: Any]]).enumerated().map { i, c in
            ExternalConnection(row: Row(["id": i + 1, "name": c["name"] as? String ?? "", "kind": c["kind"] as? String ?? "",
                                         "url": c["url"] as? String ?? "", "command": c["command"] as? String ?? ""]))
        }
        let cases = try #require(obj["cases"] as? [[String: Any]])
        #expect(cases.count >= 10)
        for c in cases {
            let perms = c["permissions"] as? [String] ?? []
            let policy = ManagedPolicy.normalize(c["policy"] as? [String: Any] ?? [:])
            let blocked = AutomationPolicyBlock.isBlocked(Automation(id: 1, slug: "x", permissions: perms), policy: policy,
                                                          connections: conns)
            #expect(blocked == !((c["want"] as? String ?? "").isEmpty), "\(c["name"] ?? "?")")
        }
    }

    @Test("a recipe that does not parse is not blocked, as Go's show/list say")
    func unparseableNotBlocked() {
        let noShell = ManagedPolicy.normalize(["AllowAutomationShell": false])
        let broken = Automation(id: 1, slug: "s", permissions: [#"shell:"x""#], parseError: "bad")
        #expect(!AutomationPolicyBlock.isBlocked(broken, policy: noShell, connections: []))
    }
}
