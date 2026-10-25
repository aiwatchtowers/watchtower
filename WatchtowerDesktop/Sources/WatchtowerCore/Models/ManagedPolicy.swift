import CoreFoundation
import Foundation

/// The settings a company forces on Watchtower through its MDM (board #608):
/// the Swift twin of Go's `internal/policy`. Only forced values of the app's
/// preference domain count (POLICY-01); a wrong type reads as the key's most
/// restrictive value. Go and Swift normalize the same way, held equal by
/// `internal/policy/testdata/policy_cases.json` (POLICY-02).
package struct ManagedPolicy: Equatable, Sendable {
    /// The v1 keys, then the reserved ones (read and shown, not enforced).
    package enum Key: String, CaseIterable, Sendable {
        case allowedSources = "AllowedSources"
        case mobileSync = "MobileSync"
        case allowedQuickConnections = "AllowedQuickConnections"
        case allowAutomationShell = "AllowAutomationShell"
        case allowedAIProviders = "AllowedAIProviders"
        case allowClaudeAITools = "AllowClaudeAITools"
        case purgeRevokedData = "PurgeRevokedData"
        case requireDatabaseEncryption = "RequireDatabaseEncryption"
        case retentionDays = "RetentionDays"
        case bulkReadLimits = "BulkReadLimits"

        package static let reserved: [Self] = [.requireDatabaseEncryption, .retentionDays, .bulkReadLimits]
    }

    /// One defect of the delivered profile; `problem` is `wrong_type`,
    /// `unknown_value` or `invalid_entry`.
    package struct Problem: Equatable, Sendable {
        package let key: String
        package let problem: String
    }

    package static let knownSources = ["slack", "google", "imap", "caldav", "jira", "linear"]
    package static let knownProviders = ["claude", "codex", "ollama"]
    package static let mobileModes = ["allowed", "workbench_only", "off"]

    package var managed = false
    /// nil = the key is absent (no restriction); [] is a real, most
    /// restrictive value.
    package var allowedSources: [String]?
    package var mobileSync: String?
    package var allowedQuickConnections: [String]?
    package var allowAutomationShell: Bool? // swiftlint:disable:this discouraged_optional_boolean
    package var allowedAIProviders: [String]?
    package var allowClaudeAITools: Bool? // swiftlint:disable:this discouraged_optional_boolean
    package var purgeRevokedData: Bool? // swiftlint:disable:this discouraged_optional_boolean
    package var reservedNotEnforced: [String] = []
    package var problems: [Problem] = []

    /// No profile: nothing is restricted.
    package static let none = Self()

    package init() {}

    // MARK: Normalize

    /// Normalizes the forced values (only forced keys, as the reader delivers
    /// them), as Go's `policy.Normalize` does.
    package static func normalize(_ raw: [String: Any]) -> Self {
        var p = Self()
        p.managed = Key.allCases.contains { raw[$0.rawValue] != nil }
        if let v = raw[Key.allowedSources.rawValue] {
            p.allowedSources = p.list(.allowedSources, v) { knownSources.contains($0) ? nil : "unknown_value" }
        }
        if let v = raw[Key.mobileSync.rawValue] {
            if let s = v as? String {
                if mobileModes.contains(s) {
                    p.mobileSync = s
                } else {
                    p.report(.mobileSync, "unknown_value")
                    p.mobileSync = "off"
                }
            } else {
                p.report(.mobileSync, "wrong_type")
                p.mobileSync = "off"
            }
        }
        if let v = raw[Key.allowedQuickConnections.rawValue] {
            p.allowedQuickConnections = p.list(.allowedQuickConnections, v) { isConnectionEntry($0) ? nil : "invalid_entry" }
        }
        if let v = raw[Key.allowAutomationShell.rawValue] {
            p.allowAutomationShell = p.boolean(.allowAutomationShell, v, restrictive: false)
        }
        if let v = raw[Key.allowedAIProviders.rawValue] {
            p.allowedAIProviders = p.list(.allowedAIProviders, v) { knownProviders.contains($0) ? nil : "unknown_value" }
        }
        if let v = raw[Key.allowClaudeAITools.rawValue] {
            p.allowClaudeAITools = p.boolean(.allowClaudeAITools, v, restrictive: false)
        }
        if let v = raw[Key.purgeRevokedData.rawValue] {
            p.purgeRevokedData = p.boolean(.purgeRevokedData, v, restrictive: true)
        }
        for key in Key.reserved {
            guard let v = raw[key.rawValue] else { continue }
            p.reservedNotEnforced.append(key.rawValue)
            let typeOK: Bool
            switch key {
            case .requireDatabaseEncryption: typeOK = isBool(v)
            case .retentionDays: typeOK = isIntegral(v)
            default: typeOK = v is [String: Any]
            }
            if !typeOK { p.report(key, "wrong_type") }
        }
        return p
    }

    private mutating func report(_ key: Key, _ problem: String) {
        let pr = Problem(key: key.rawValue, problem: problem)
        if !problems.contains(pr) { problems.append(pr) }
    }

    /// An array key: a non-array is a wrong type ([]); a non-string entry is
    /// an invalid entry; `check` names the problem of a string it drops.
    private mutating func list(_ key: Key, _ v: Any, check: (String) -> String?) -> [String] {
        guard let arr = v as? [Any] else {
            report(key, "wrong_type")
            return []
        }
        var out: [String] = []
        for e in arr {
            guard let s = e as? String else {
                report(key, "invalid_entry")
                continue
            }
            if let problem = check(s) {
                report(key, problem)
                continue
            }
            out.append(s)
        }
        return out
    }

    /// Only a real boolean counts: an NSNumber 1 (`<integer>1</integer>`,
    /// JSON `1`) is a wrong type, as in Go.
    private mutating func boolean(_ key: Key, _ v: Any, restrictive: Bool) -> Bool {
        guard Self.isBool(v), let b = v as? Bool else {
            report(key, "wrong_type")
            return restrictive
        }
        return b
    }

    static func isBool(_ v: Any) -> Bool {
        CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID()
    }

    static func isNumber(_ v: Any) -> Bool {
        CFGetTypeID(v as CFTypeRef) == CFNumberGetTypeID()
    }

    static func isIntegral(_ v: Any) -> Bool {
        guard isNumber(v), let n = v as? NSNumber else { return false }
        let d = n.doubleValue
        return d.isFinite && d == d.rounded(.towardZero)
    }

    // MARK: Helpers

    package func sourceAllowed(_ source: String) -> Bool {
        allowedSources.map { $0.contains(source) } ?? true
    }

    /// `allowed` when the key is absent.
    package var mobileSyncMode: String { mobileSync ?? "allowed" }

    package var shellAllowed: Bool { allowAutomationShell ?? true }

    package func providerAllowed(_ id: String) -> Bool {
        allowedAIProviders.map { $0.contains(id) } ?? true
    }

    package var claudeAIToolsAllowed: Bool { allowClaudeAITools ?? true }

    /// Whether the key decides its controls (they are locked).
    package func isLocked(_ key: Key) -> Bool {
        switch key {
        case .allowedSources: allowedSources != nil
        case .mobileSync: mobileSync != nil
        case .allowedQuickConnections: allowedQuickConnections != nil
        case .allowAutomationShell: allowAutomationShell != nil
        case .allowedAIProviders: allowedAIProviders != nil
        case .allowClaudeAITools: allowClaudeAITools != nil
        case .purgeRevokedData: purgeRevokedData != nil
        case .requireDatabaseEncryption, .retentionDays, .bulkReadLimits: reservedNotEnforced.contains(key.rawValue)
        }
    }

    /// Go's `Policy.ConnectionAllowed`: kind `http` matches the https entries
    /// (https only, host and port case-insensitive, the path on a "/"
    /// boundary or a plain prefix when the entry path ends in "/", dot
    /// segments and encoded separators refused); kind `stdio` matches the
    /// command byte-equal to an absolute-path entry.
    package func connectionAllowed(kind: String, url: String, command: String) -> Bool {
        guard let allowed = allowedQuickConnections else { return true }
        switch kind {
        case "http": return allowed.contains { Self.httpMatches(entry: $0, url: url) }
        case "stdio": return command.hasPrefix("/") && allowed.contains(command)
        default: return false
        }
    }

    // MARK: URL matching (the Go algorithm, by hand: Foundation's URL parser
    // differs from net/url)

    /// A parsed https URL: host with port as written, the path before any
    /// query or fragment, and what else it carried.
    struct HTTPSURL {
        let host: String
        let path: String
        let hasUser: Bool
        let hasQuery: Bool
        let hasFragment: Bool
    }

    static func parseHTTPS(_ s: String) -> HTTPSURL? {
        guard let sep = s.range(of: "://"), s[..<sep.lowerBound].lowercased() == "https" else { return nil }
        var rest = String(s[sep.upperBound...])
        var hasFragment = false
        var hasQuery = false
        if let i = rest.firstIndex(of: "#") {
            hasFragment = true
            rest = String(rest[..<i])
        }
        if let i = rest.firstIndex(of: "?") {
            hasQuery = true
            rest = String(rest[..<i])
        }
        let authorityEnd = rest.firstIndex(of: "/") ?? rest.endIndex
        var authority = String(rest[..<authorityEnd])
        let path = String(rest[authorityEnd...])
        var hasUser = false
        if let at = authority.lastIndex(of: "@") {
            hasUser = true
            authority = String(authority[authority.index(after: at)...])
        }
        guard !authority.isEmpty else { return nil }
        return HTTPSURL(host: authority, path: path, hasUser: hasUser, hasQuery: hasQuery, hasFragment: hasFragment)
    }

    /// An entry: https with a host, no user info, query or fragment, and a
    /// safe path.
    static func parseEntry(_ s: String) -> HTTPSURL? {
        guard let u = parseHTTPS(s), !u.hasUser, !u.hasQuery, !u.hasFragment, pathSafe(u.path) else { return nil }
        return u
    }

    static func isConnectionEntry(_ s: String) -> Bool {
        s.hasPrefix("/") || parseEntry(s) != nil
    }

    static func httpMatches(entry: String, url: String) -> Bool {
        guard let e = parseEntry(entry), let c = parseHTTPS(url),
              e.host.lowercased() == c.host.lowercased(), pathSafe(c.path) else { return false }
        let ep = e.path.isEmpty ? "/" : e.path
        let cp = c.path.isEmpty ? "/" : c.path
        if ep.hasSuffix("/") { return cp.hasPrefix(ep) }
        return cp == ep || cp.hasPrefix(ep + "/")
    }

    /// Refuses a path a server could resolve out of an allowed prefix: a "."
    /// or ".." segment (percent-encoded too), an encoded separator (%2f,
    /// %5c) or a backslash, or a bad escape.
    static func pathSafe(_ path: String) -> Bool {
        for seg in path.split(separator: "/", omittingEmptySubsequences: false) {
            guard let dec = percentDecoded(Array(seg.utf8)) else { return false }
            if dec == [0x2E] || dec == [0x2E, 0x2E] || dec.contains(0x2F) || dec.contains(0x5C) { return false }
        }
        return true
    }

    /// Bytes with every %XX decoded; nil on a bad escape (Go's PathUnescape).
    static func percentDecoded(_ bytes: [UInt8]) -> [UInt8]? {
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x25 {
                guard i + 2 < bytes.count, let hi = hexValue(bytes[i + 1]), let lo = hexValue(bytes[i + 2]) else { return nil }
                out.append(hi << 4 | lo)
                i += 3
            } else {
                out.append(bytes[i])
                i += 1
            }
        }
        return out
    }

    private static func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: b - 0x30
        case 0x41...0x46: b - 0x41 + 10
        case 0x61...0x66: b - 0x61 + 10
        default: nil
        }
    }
}
