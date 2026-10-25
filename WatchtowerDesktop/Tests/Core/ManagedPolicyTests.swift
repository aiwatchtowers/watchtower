import Foundation
import Testing
@testable import WatchtowerCore

/// POLICY-02: the Swift twin normalizes and matches exactly as Go's
/// `internal/policy`, over the one shared fixture.
@Suite("ManagedPolicy")
struct ManagedPolicyTests {
    private static func fixture() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/policy/testdata/policy_cases.json")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try #require(obj as? [String: Any])
    }

    /// The policy in Go's `policy show --json` shape.
    private static func goShape(_ p: ManagedPolicy) -> [String: Any] {
        func opt(_ v: Any?) -> Any { v ?? NSNull() }
        let keys: [String: Any] = [
            "AllowedSources": opt(p.allowedSources),
            "MobileSync": opt(p.mobileSync),
            "AllowedQuickConnections": opt(p.allowedQuickConnections),
            "AllowAutomationShell": opt(p.allowAutomationShell),
            "AllowedAIProviders": opt(p.allowedAIProviders),
            "AllowClaudeAITools": opt(p.allowClaudeAITools),
            "PurgeRevokedData": opt(p.purgeRevokedData)
        ]
        return [
            "managed": p.managed, "domain": Constants.bundleID, "keys": keys,
            "reserved_not_enforced": p.reservedNotEnforced,
            "errors": p.problems.map { ["key": $0.key, "problem": $0.problem] }
        ]
    }

    private static func canonical(_ v: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: v, options: [.sortedKeys])
        return try #require(String(bytes: data, encoding: .utf8))
    }

    @Test("every fixture case normalizes to Go's result")
    func sharedFixture() throws {
        let f = try Self.fixture()
        let cases = try #require(f["cases"] as? [[String: Any]])
        #expect(cases.count >= 20)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let raw = c["raw"] as? [String: Any] ?? [:]
            let got = try Self.canonical(Self.goShape(ManagedPolicy.normalize(raw)))
            let want = try Self.canonical(try #require(c["want"]))
            #expect(got == want, "\(name)")
        }
    }

    @Test("every fixture connection case matches as in Go, path safety included")
    func sharedConnectionCases() throws {
        let f = try Self.fixture()
        let cases = try #require(f["connection_cases"] as? [[String: Any]])
        #expect(cases.count >= 30)
        for c in cases {
            var raw: [String: Any] = [:]
            if let allowed = c["allowed"], !(allowed is NSNull) {
                raw[ManagedPolicy.Key.allowedQuickConnections.rawValue] = allowed
            }
            let got = ManagedPolicy.normalize(raw).connectionAllowed(
                kind: c["kind"] as? String ?? "", url: c["url"] as? String ?? "", command: c["command"] as? String ?? ""
            )
            #expect(got == (c["want"] as? Bool), "\(c["name"] ?? "?")")
        }
    }

    @Test("a boolean given as the integer 1 is a wrong type, read as false")
    func boolAsIntegerIsWrongType() {
        let p = ManagedPolicy.normalize(["AllowAutomationShell": NSNumber(value: 1), "AllowClaudeAITools": 1])
        #expect(p.allowAutomationShell == false)
        #expect(p.allowClaudeAITools == false)
        #expect(!p.shellAllowed)
        #expect(p.problems.map(\.problem) == ["wrong_type", "wrong_type"])
        #expect(ManagedPolicy.normalize(["AllowAutomationShell": true]).shellAllowed)
    }

    @Test("the keys are Go's keys")
    func keysAreSameAsGo() throws {
        let f = try Self.fixture()
        let cases = try #require(f["cases"] as? [[String: Any]])
        var names = Set<String>()
        for c in cases {
            if let keys = (c["want"] as? [String: Any])?["keys"] as? [String: Any] { names.formUnion(keys.keys) }
            if let reserved = (c["want"] as? [String: Any])?["reserved_not_enforced"] as? [String] { names.formUnion(reserved) }
        }
        #expect(Set(ManagedPolicy.Key.allCases.map(\.rawValue)) == names)
    }

    @Test("no profile restricts and locks nothing")
    func noneRestrictsNothing() {
        let p = ManagedPolicy.none
        #expect(!p.managed)
        #expect(p.sourceAllowed("linear"))
        #expect(p.mobileSyncMode == "allowed")
        #expect(p.providerAllowed("codex"))
        #expect(p.claudeAIToolsAllowed)
        #expect(ManagedPolicy.Key.allCases.allSatisfy { !p.isLocked($0) })
    }
}
