import CoreFoundation
import Foundation

/// Where a company bundle came from; only a stored file (`local`) may carry
/// `personal`.
package enum CompanyBundleOrigin: Sendable {
    case link, mdm, code, local
}

/// Why a bundle is refused — the closed set Go's `companybundle.Refusal`
/// holds; the raw values are Go's.
package enum CompanyBundleRefusal: String, Error, CaseIterable, Sendable {
    case damaged
    case tooLong = "too_long"
    case siteNotHTTPS = "site_not_https"
    case personal
    case newerVersion = "newer_version"
}

/// The company bundle (company setup spec §1): the Swift twin of Go's
/// `internal/companybundle`. A link, an MDM key or a pasted code carries it as
/// base64url without padding; parsing fails closed (unknown or miscased
/// fields, wrong types, a non-https site, malformed ids) and normalizes the
/// rest. Go and Swift are held equal by
/// `internal/companybundle/testdata/bundle_cases.json`. Go owns the stored
/// files; the Desktop only reads.
package struct CompanyBundle: Encodable, Equatable, Sendable {
    package static let version = 1
    package static let maxEncodedLength = 3000
    /// Would collide with the store's draft.json in company/.
    private static let reservedSlug = "draft"

    package struct Slack: Encodable, Equatable, Sendable {
        package var teamID: String
        package var clientID: String
        enum CodingKeys: String, CodingKey { case teamID = "team_id", clientID = "client_id" }
    }

    /// `domain` is empty for a personal project.
    package struct Google: Encodable, Equatable, Sendable {
        package var clientID: String
        package var clientSecret: String
        package var domain: String

        enum CodingKeys: String, CodingKey {
            case clientID = "client_id", clientSecret = "client_secret", domain
        }

        package func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(clientID, forKey: .clientID)
            try c.encode(clientSecret, forKey: .clientSecret)
            if !domain.isEmpty { try c.encode(domain, forKey: .domain) }
        }
    }

    /// `site` is normalized to `https://<host>`.
    package struct Atlassian: Encodable, Equatable, Sendable {
        package var clientID: String
        package var clientSecret: String
        package var site: String
        package var confluence: Bool
        enum CodingKeys: String, CodingKey {
            case clientID = "client_id", clientSecret = "client_secret", site, confluence
        }
    }

    package struct Linear: Encodable, Equatable, Sendable {
        package var clientID: String
        enum CodingKeys: String, CodingKey { case clientID = "client_id" }
    }

    /// `tenantID` is a GUID or a verified domain, lower-cased.
    package struct Microsoft: Encodable, Equatable, Sendable {
        package var clientID: String
        package var tenantID: String
        enum CodingKeys: String, CodingKey { case clientID = "client_id", tenantID = "tenant_id" }
    }

    package var v: Int
    package var company: String
    package var personal = false
    package var slack: Slack?
    package var google: Google?
    package var atlassian: Atlassian?
    package var linear: Linear?
    package var microsoft: Microsoft?
    package var linkDenyHosts: [String] = []

    enum CodingKeys: String, CodingKey {
        case v, company, personal, slack, google, atlassian, linear, microsoft
        case linkDenyHosts = "link_deny_hosts"
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(company, forKey: .company)
        if personal { try c.encode(true, forKey: .personal) }
        try c.encodeIfPresent(slack, forKey: .slack)
        try c.encodeIfPresent(google, forKey: .google)
        try c.encodeIfPresent(atlassian, forKey: .atlassian)
        try c.encodeIfPresent(linear, forKey: .linear)
        try c.encodeIfPresent(microsoft, forKey: .microsoft)
        if !linkDenyHosts.isEmpty { try c.encode(linkDenyHosts, forKey: .linkDenyHosts) }
    }

    // MARK: - Parse

    /// Decodes and validates a wire-form bundle (link, MDM, code).
    package static func parse(_ wire: String, origin: CompanyBundleOrigin) -> Result<Self, CompanyBundleRefusal> {
        let wire = trimASCII(wire)
        guard wire.utf8.count <= maxEncodedLength else { return .failure(.tooLong) }
        guard let data = decodeBase64URL(wire) else { return .failure(.damaged) }
        return parseJSON(data, origin: origin)
    }

    /// Validates a bundle's JSON (a stored file reads with `.local`).
    package static func parseJSON(_ data: Data, origin: CompanyBundleOrigin) -> Result<Self, CompanyBundleRefusal> {
        do {
            return .success(try read(data, origin: origin))
        } catch let refusal as CompanyBundleRefusal {
            return .failure(refusal)
        } catch {
            return .failure(.damaged)
        }
    }

    private static let topKeys: Set<String> = [
        "v", "company", "personal", "slack", "google", "atlassian", "linear", "microsoft", "link_deny_hosts"
    ]

    /// Go's `plainJSONText`, byte for byte: refuses a NUL byte (Foundation
    /// sniffs UTF-16/32 without a BOM), a `\u` escape of a UTF-16 surrogate
    /// (Go reads a lone one as U+FFFD), an object key that is not printable
    /// ASCII without escapes (Swift would merge canonically equal keys), a
    /// key twice in one object, and a comma right before a closing bracket
    /// (Foundation accepts it). A bracket-and-string scan, not a validator.
    private static func plainJSONText(_ raw: [UInt8]) -> Bool {
        struct Frame {
            var object: Bool
            var wantKey: Bool
            var keys: Set<[UInt8]> = []
        }
        var stack: [Frame] = []
        var prev: UInt8 = 0 // the last byte outside strings and whitespace
        var i = 0
        while i < raw.count {
            switch raw[i] {
            case 0:
                return false
            case UInt8(ascii: "{"):
                stack.append(Frame(object: true, wantKey: true))
            case UInt8(ascii: "["):
                stack.append(Frame(object: false, wantKey: false))
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                guard prev != UInt8(ascii: ","), stack.popLast() != nil else { return false }
            case UInt8(ascii: ","):
                if stack.last?.object == true { stack[stack.count - 1].wantKey = true }
            case UInt8(ascii: "\""):
                guard let (end, plainKey) = scanString(raw, from: i) else { return false }
                if let top = stack.last, top.object, top.wantKey {
                    let key = Array(raw[(i + 1)..<end])
                    guard plainKey, !top.keys.contains(key) else { return false }
                    stack[stack.count - 1].keys.insert(key)
                    stack[stack.count - 1].wantKey = false
                }
                i = end // at the closing quote, which becomes prev below
            default:
                break
            }
            if ![UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r")].contains(raw[i]) {
                prev = raw[i]
            }
            i += 1
        }
        return true
    }

    /// Scans the JSON string opening at `open`: the index of its closing
    /// quote and whether it is a plain key (printable ASCII, no escape); nil
    /// for a surrogate escape or an unterminated string.
    private static func scanString(_ raw: [UInt8], from open: Int) -> (end: Int, plainKey: Bool)? {
        var plainKey = true
        var i = open + 1
        while i < raw.count, raw[i] != UInt8(ascii: "\"") {
            let c = raw[i]
            if c < 0x20 || c > 0x7E { plainKey = false }
            if c == UInt8(ascii: "\\") {
                plainKey = false
                if i + 3 < raw.count, raw[i + 1] == UInt8(ascii: "u"),
                   raw[i + 2] == UInt8(ascii: "d") || raw[i + 2] == UInt8(ascii: "D"),
                   Array("89abcdefABCDEF".utf8).contains(raw[i + 3]) {
                    return nil
                }
                i += 1 // the escaped character, so `\\ud800` (an escaped backslash) passes
            }
            i += 1
        }
        return i < raw.count ? (i, plainKey) : nil
    }

    private static func read(_ data: Data, origin: CompanyBundleOrigin) throws -> Self {
        // Go's decoder refuses a byte-order mark and invalid UTF-8;
        // JSONSerialization would accept the first and sniff other encodings.
        guard !data.starts(with: [0xEF, 0xBB, 0xBF]), String(bytes: data, encoding: .utf8) != nil,
              plainJSONText(Array(data)),
              let top = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CompanyBundleRefusal.damaged }
        // The version first: a newer bundle may carry fields this build lacks.
        let version = try integer(top["v"])
        guard version >= 1 else { throw CompanyBundleRefusal.damaged }
        guard version <= Self.version else { throw CompanyBundleRefusal.newerVersion }
        try onlyKeys(top, topKeys)
        let company = trimASCII(try string(top["company"]))
        guard validCompany(company) else { throw CompanyBundleRefusal.damaged }
        var bundle = Self(v: version, company: company)
        bundle.personal = try boolean(top["personal"])
        if bundle.personal, origin != .local { throw CompanyBundleRefusal.personal }
        bundle.slack = try readSlack(top["slack"])
        bundle.google = try readGoogle(top["google"])
        bundle.atlassian = try readAtlassian(top["atlassian"])
        bundle.linear = try readLinear(top["linear"])
        bundle.microsoft = try readMicrosoft(top["microsoft"])
        bundle.linkDenyHosts = try readDenyHosts(top["link_deny_hosts"])
        return bundle
    }

    private static func readSlack(_ raw: Any?) throws -> Slack? {
        guard let m = try block(raw, ["team_id", "client_id"]) else { return nil }
        return Slack(
            teamID: try id(m["team_id"], isSlackTeamID),
            clientID: try id(m["client_id"], isSlackClientID)
        )
    }

    private static func readGoogle(_ raw: Any?) throws -> Google? {
        guard let m = try block(raw, ["client_id", "client_secret", "domain"]) else { return nil }
        let clientID = try id(m["client_id"], isGoogleClientID)
        let secret = try id(m["client_secret"], isSecret)
        let domain = asciiLower(trimASCII(try string(m["domain"])))
        guard domain.isEmpty || isHost(domain) else { throw CompanyBundleRefusal.damaged }
        return Google(clientID: clientID, clientSecret: secret, domain: domain)
    }

    private static func readAtlassian(_ raw: Any?) throws -> Atlassian? {
        guard let m = try block(raw, ["client_id", "client_secret", "site", "confluence"]) else { return nil }
        let clientID = try id(m["client_id"], isPlainID)
        let secret = try id(m["client_secret"], isSecret)
        let site = try normalizeSite(try string(m["site"]))
        return Atlassian(clientID: clientID, clientSecret: secret, site: site, confluence: try boolean(m["confluence"]))
    }

    private static func readLinear(_ raw: Any?) throws -> Linear? {
        guard let m = try block(raw, ["client_id"]) else { return nil }
        return Linear(clientID: try id(m["client_id"], isPlainID))
    }

    private static func readMicrosoft(_ raw: Any?) throws -> Microsoft? {
        guard let m = try block(raw, ["client_id", "tenant_id"]) else { return nil }
        let clientID = asciiLower(trimASCII(try string(m["client_id"])))
        let tenantID = asciiLower(trimASCII(try string(m["tenant_id"])))
        guard isGUID(clientID), isGUID(tenantID) || isHost(tenantID) else { throw CompanyBundleRefusal.damaged }
        return Microsoft(clientID: clientID, tenantID: tenantID)
    }

    /// `https://<host>` with an optional trailing slash, lower-cased without
    /// the slash; another scheme (or none) is `siteNotHTTPS`, a path, port,
    /// query or user part is `damaged`.
    private static func normalizeSite(_ site: String) throws -> String {
        let s = asciiLower(trimASCII(site))
        guard !s.isEmpty else { throw CompanyBundleRefusal.damaged }
        guard s.hasPrefix("https://") else { throw CompanyBundleRefusal.siteNotHTTPS }
        var host = String(s.dropFirst("https://".count))
        if host.hasSuffix("/") { host.removeLast() }
        guard isHost(host) else { throw CompanyBundleRefusal.damaged }
        return "https://" + host
    }

    /// Bare lower-case DNS names only — the form `linkrule.NormalizeHostSet`
    /// keeps unchanged; one hostile entry refuses the bundle.
    private static func readDenyHosts(_ raw: Any?) throws -> [String] {
        guard let raw = present(raw) else { return [] }
        guard let list = raw as? [Any] else { throw CompanyBundleRefusal.damaged }
        return try list.map { item in
            guard let s = item as? String else { throw CompanyBundleRefusal.damaged }
            let host = asciiLower(trimASCII(s))
            guard isHost(host) else { throw CompanyBundleRefusal.damaged }
            return host
        }
    }

    // MARK: - JSON members (absent and null read alike, as in Go)

    private static func present(_ raw: Any?) -> Any? {
        guard let raw, !(raw is NSNull) else { return nil }
        return raw
    }

    private static func block(_ raw: Any?, _ allowed: Set<String>) throws -> [String: Any]? {
        guard let raw = present(raw) else { return nil }
        guard let m = raw as? [String: Any] else { throw CompanyBundleRefusal.damaged }
        try onlyKeys(m, allowed)
        return m
    }

    /// Exact-case keys only (Go checks the same, unlike its decoder's
    /// case-insensitive match).
    private static func onlyKeys(_ m: [String: Any], _ allowed: Set<String>) throws {
        guard Set(m.keys).isSubset(of: allowed) else { throw CompanyBundleRefusal.damaged }
    }

    private static func string(_ raw: Any?) throws -> String {
        guard let raw = present(raw) else { return "" }
        guard let s = raw as? String else { throw CompanyBundleRefusal.damaged }
        return s
    }

    /// A JSON `true`/`false` only — `as? Bool` would also take a number.
    private static func boolean(_ raw: Any?) throws -> Bool {
        guard let raw = present(raw) else { return false }
        guard let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
            throw CompanyBundleRefusal.damaged
        }
        return n.boolValue
    }

    /// A JSON integer literal only — no bool, no `1.0`.
    private static func integer(_ raw: Any?) throws -> Int {
        guard let n = present(raw) as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(n), n.doubleValue == Double(n.intValue)
        else { throw CompanyBundleRefusal.damaged }
        return n.intValue
    }

    private static func id(_ raw: Any?, _ valid: (String) -> Bool) throws -> String {
        let s = trimASCII(try string(raw))
        guard valid(s) else { throw CompanyBundleRefusal.damaged }
        return s
    }

    // MARK: - Shapes (the regular expressions of Go's bundle.go)

    private static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
    private static func isLowerAlnum(_ b: UInt8) -> Bool { isDigit(b) || (b >= 0x61 && b <= 0x7A) }
    private static func isUpperAlnum(_ b: UInt8) -> Bool { isDigit(b) || (b >= 0x41 && b <= 0x5A) }
    private static func isHex(_ b: UInt8) -> Bool { isDigit(b) || (b >= 0x61 && b <= 0x66) }

    /// `^[TE][A-Z0-9]{2,}$`
    private static func isSlackTeamID(_ s: String) -> Bool {
        guard let first = s.utf8.first, first == UInt8(ascii: "T") || first == UInt8(ascii: "E"),
              s.utf8.count >= 3 else { return false }
        return s.utf8.dropFirst().allSatisfy(isUpperAlnum)
    }

    /// `^[0-9]+\.[0-9]+$`
    private static func isSlackClientID(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy(isDigit) }
    }

    /// `^[0-9]+-[a-z0-9]+\.apps\.googleusercontent\.com$`
    private static func isGoogleClientID(_ s: String) -> Bool {
        let suffix = ".apps.googleusercontent.com"
        guard s.hasSuffix(suffix) else { return false }
        let parts = s.dropLast(suffix.count).split(separator: "-", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[0].utf8.allSatisfy(isDigit)
            && !parts[1].isEmpty && parts[1].utf8.allSatisfy(isLowerAlnum)
    }

    /// `^[A-Za-z0-9_-]{1,128}$`
    private static func isPlainID(_ s: String) -> Bool {
        (1...128).contains(s.utf8.count) && s.utf8.allSatisfy(isWireByte)
    }

    /// `^[\x21-\x7e]{1,256}$`
    private static func isSecret(_ s: String) -> Bool {
        (1...256).contains(s.utf8.count) && s.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
    }

    /// A lower-case GUID.
    private static func isGUID(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard b.count == 36 else { return false }
        return b.indices.allSatisfy { [8, 13, 18, 23].contains($0) ? b[$0] == UInt8(ascii: "-") : isHex(b[$0]) }
    }

    /// A lower-case ASCII DNS name of two or more labels whose last label
    /// has a letter (no IPv4 literal), at most 253 characters.
    private static func isHost(_ h: String) -> Bool {
        guard h.utf8.count <= 253 else { return false }
        let labels = h.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let last = labels.last else { return false }
        let labelsOK = labels.allSatisfy { label in
            let b = Array(label.utf8)
            guard (1...63).contains(b.count), let f = b.first, let l = b.last else { return false }
            return isLowerAlnum(f) && isLowerAlnum(l) && b.allSatisfy { isLowerAlnum($0) || $0 == UInt8(ascii: "-") }
        }
        return labelsOK && last.utf8.contains { $0 >= 0x61 && $0 <= 0x7A }
    }

    /// Non-empty, at most 200 UTF-8 bytes, no control, format (bidi overrides,
    /// zero-width characters) or line/paragraph separator characters.
    private static func validCompany(_ c: String) -> Bool {
        guard !c.isEmpty, c.utf8.count <= 200 else { return false }
        return !c.unicodeScalars.contains {
            [.control, .format, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
        }
    }

    // MARK: - Text helpers

    /// Surrounding ASCII spaces, tabs and line breaks only (Go trims the same).
    private static func trimASCII(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n"))
    }

    /// A–Z only; a full Unicode lower-casing would fold look-alikes into ASCII.
    private static func asciiLower(_ s: String) -> String {
        String(bytes: s.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }, encoding: .utf8) ?? s
    }

    private static func isWireByte(_ b: UInt8) -> Bool {
        isDigit(b) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
            || b == UInt8(ascii: "-") || b == UInt8(ascii: "_")
    }

    /// Strict base64url without padding: only the URL alphabet, and the
    /// canonical encoding of what it decodes to (no stray trailing bits).
    private static func decodeBase64URL(_ wire: String) -> Data? {
        guard wire.utf8.allSatisfy(isWireByte), wire.utf8.count % 4 != 1 else { return nil }
        var std = wire.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        std += String(repeating: "=", count: (4 - std.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: std), base64URL(data) == wire else { return nil }
        return data
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Slug and encoding

    /// The file-name stem Go's `companybundle.Slug` gives: ASCII-lower-cased,
    /// each run outside `[a-z0-9]` one dash, no edge dashes, at most 64
    /// characters; "company" when nothing is left, "<slug>-company" for a name
    /// the store reserves.
    package static func slug(_ company: String) -> String {
        var out: [UInt8] = []
        var dash = false
        for byte in asciiLower(company).utf8 {
            guard isLowerAlnum(byte) else {
                dash = true
                continue
            }
            if dash, !out.isEmpty { out.append(UInt8(ascii: "-")) }
            dash = false
            out.append(byte)
        }
        if out.count > 64 {
            out = Array(out.prefix(64))
            while out.last == UInt8(ascii: "-") { out.removeLast() }
        }
        let s = String(bytes: out, encoding: .utf8) ?? ""
        if s.isEmpty { return "company" }
        return s == reservedSlug ? s + "-company" : s
    }

    /// The JSON Go's `Encode` writes: sorted keys, `/` unescaped. With
    /// `encoded()`, the Go-parity check of the shared fixture; the Desktop
    /// never writes a bundle (Go owns the stored files).
    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// The wire form of a parsed (normalized) bundle — Go's `Encode` bytes.
    func encoded() throws -> String {
        Self.base64URL(try encodedJSON())
    }
}
