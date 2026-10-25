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
            p.allowedSources = p.list(.allowedSources, v) { byteIn($0, knownSources) ? nil : "unknown_value" }
        }
        if let v = raw[Key.mobileSync.rawValue] {
            if let s = v as? String {
                if byteIn(s, mobileModes) {
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
            p.allowedAIProviders = p.list(.allowedAIProviders, v) { byteIn($0, knownProviders) ? nil : "unknown_value" }
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

    /// Membership by UTF-8 bytes, as Go compares strings (never Swift's
    /// canonical equivalence: "\u{212A}" is not "K").
    static func byteIn(_ s: String, _ set: [String]) -> Bool {
        set.contains { $0.utf8.elementsEqual(s.utf8) }
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
        allowedSources.map { Self.byteIn(source, $0) } ?? true
    }

    /// `allowed` when the key is absent.
    package var mobileSyncMode: String { mobileSync ?? "allowed" }

    package var shellAllowed: Bool { allowAutomationShell ?? true }

    package func providerAllowed(_ id: String) -> Bool {
        allowedAIProviders.map { Self.byteIn(id, $0) } ?? true
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
        case "stdio":
            // Byte-equal, as Go compares strings: never Swift's canonical equivalence.
            let cmd = Array(command.utf8)
            return cmd.first == 0x2F && allowed.contains { Array($0.utf8) == cmd }
        default: return false
        }
    }

    // MARK: URL matching — Go's net/url by hand (Foundation's parser differs):
    // the same refusals, Go's EscapedPath, byte comparisons.

    /// A parsed https URL: the unescaped host (port included) and Go's
    /// EscapedPath, as bytes, and what else it carried.
    struct HTTPSURL {
        let host: [UInt8]
        let path: [UInt8]
        let hasUser: Bool
        let hasQuery: Bool
        let hasFragment: Bool
    }

    static func parseHTTPS(_ s: String) -> HTTPSURL? {
        var b = Array(s.utf8)
        // Go refuses an ASCII control character anywhere.
        guard !b.contains(where: { $0 < 0x20 || $0 == 0x7F }) else { return nil }
        guard let sep = indexOf(b, [0x3A, 0x2F, 0x2F]),
              b[..<sep].map(asciiLower) == Array("https".utf8) else { return nil }
        b = Array(b[(sep + 3)...])
        var hasFragment = false
        var hasQuery = false
        if let i = b.firstIndex(of: 0x23) { // #
            hasFragment = i + 1 < b.count // Go: an empty fragment is none
            b = Array(b[..<i])
        }
        if let i = b.firstIndex(of: 0x3F) { // ?
            hasQuery = true
            b = Array(b[..<i])
        }
        let authorityEnd = b.firstIndex(of: 0x2F) ?? b.endIndex
        var authority = Array(b[..<authorityEnd])
        let rawPath = Array(b[authorityEnd...])
        var hasUser = false
        if let at = authority.lastIndex(of: 0x40) { // @
            guard validUserinfo(Array(authority[..<at])) else { return nil }
            hasUser = true
            authority = Array(authority[(at + 1)...])
        }
        guard !authority.isEmpty, let host = parseHost(authority), let path = escapedPath(rawPath) else { return nil }
        return HTTPSURL(host: host, path: path, hasUser: hasUser, hasQuery: hasQuery, hasFragment: hasFragment)
    }

    /// An entry: https with a host, no user info, query or fragment (a bare
    /// "#" included), and a safe path.
    static func parseEntry(_ s: String) -> HTTPSURL? {
        guard !s.utf8.contains(0x23), let u = parseHTTPS(s), !u.hasUser, !u.hasQuery, !u.hasFragment,
              pathSafe(u.path) else { return nil }
        return u
    }

    static func isConnectionEntry(_ s: String) -> Bool {
        s.utf8.first == 0x2F || parseEntry(s) != nil
    }

    static func httpMatches(entry: String, url: String) -> Bool {
        guard let e = parseEntry(entry), let c = parseHTTPS(url),
              e.host.map(asciiLower) == c.host.map(asciiLower), pathSafe(c.path) else { return false }
        let slash: [UInt8] = [0x2F]
        let ep = e.path.isEmpty ? slash : e.path
        let cp = c.path.isEmpty ? slash : c.path
        if ep.last == 0x2F { return cp.starts(with: ep) }
        return cp == ep || cp.starts(with: ep + slash)
    }

    /// Refuses an escaped path a server could resolve out of an allowed
    /// prefix: a "." or ".." segment (percent-encoded too), an encoded
    /// separator (%2f, %5c) or a backslash, or a bad escape.
    static func pathSafe(_ path: [UInt8]) -> Bool {
        for seg in path.split(separator: 0x2F, omittingEmptySubsequences: false) {
            guard let dec = percentDecoded(Array(seg)) else { return false }
            if dec == [0x2E] || dec == [0x2E, 0x2E] || dec.contains(0x2F) || dec.contains(0x5C) { return false }
        }
        return true
    }

    /// Go's URL.EscapedPath of a path as written: the path itself when it is
    /// validly encoded, else its decoded bytes escaped again; nil on a bad
    /// escape (Go refuses the URL).
    static func escapedPath(_ raw: [UInt8]) -> [UInt8]? {
        guard let decoded = percentDecoded(raw) else { return nil }
        if raw.allSatisfy(validEncodedPathByte) { return raw }
        var out: [UInt8] = []
        for c in decoded {
            if shouldEscapePath(c) {
                out += [0x25, hexDigit(c >> 4), hexDigit(c & 0xF)]
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// Go's `validEncoded(s, encodePath)` for one byte.
    private static func validEncodedPathByte(_ c: UInt8) -> Bool {
        if Array("!$&'()*+,;=:@[]%".utf8).contains(c) { return true }
        return !shouldEscapePath(c)
    }

    /// Go's `shouldEscape(c, encodePath)`.
    private static func shouldEscapePath(_ c: UInt8) -> Bool {
        if isAlnum(c) || Array("-_.~$&+,/:;=@".utf8).contains(c) { return false }
        return true
    }

    /// Go's parseHost for a host that is not an IPv6 literal: an optional
    /// all-digit port after the last ":", sub-delims and unreserved bytes,
    /// non-ASCII bytes, and %XX only for %25 or a byte >= 0x80. The host is
    /// returned unescaped. nil when Go refuses it.
    static func parseHost(_ host: [UInt8]) -> [UInt8]? {
        if host.first == 0x5B { // [ IPv6 literal: Go's own checks are not mirrored; byte-compared as written
            guard let close = host.lastIndex(of: 0x5D) else { return nil }
            let port = Array(host[(close + 1)...])
            return validOptionalPort(port) ? host : nil
        }
        var name = host
        if let colon = host.lastIndex(of: 0x3A) {
            guard validOptionalPort(Array(host[colon...])) else { return nil }
            name = Array(host[..<colon])
        }
        var i = 0
        while i < name.count {
            let c = name[i]
            if c == 0x25 {
                guard i + 2 < name.count, let hi = hexValue(name[i + 1]), hexValue(name[i + 2]) != nil else { return nil }
                if hi < 8, Array(name[i...(i + 2)]) != Array("%25".utf8) { return nil }
                i += 3
                continue
            }
            if c < 0x80, !isAlnum(c), !Array("-_.~!$&'()*+,;=:[]<>\"".utf8).contains(c) { return nil }
            i += 1
        }
        return percentDecoded(host)
    }

    private static func validOptionalPort(_ port: [UInt8]) -> Bool {
        guard let first = port.first else { return true }
        return first == 0x3A && port.dropFirst().allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    /// Go's validUserinfo.
    private static func validUserinfo(_ u: [UInt8]) -> Bool {
        u.allSatisfy { $0 >= 0x80 || isAlnum($0) || Array("-._:~!$&'()*+,;=%@".utf8).contains($0) }
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

    private static func indexOf(_ b: [UInt8], _ needle: [UInt8]) -> Int? {
        guard b.count >= needle.count else { return nil }
        return (0...(b.count - needle.count)).first { Array(b[$0..<($0 + needle.count)]) == needle }
    }

    private static func isAlnum(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
    }

    private static func asciiLower(_ c: UInt8) -> UInt8 {
        c >= 0x41 && c <= 0x5A ? c + 0x20 : c
    }

    private static func hexDigit(_ v: UInt8) -> UInt8 {
        v < 10 ? 0x30 + v : 0x41 + v - 10
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
