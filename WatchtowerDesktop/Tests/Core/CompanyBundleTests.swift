import Foundation
import Testing
@testable import WatchtowerCore

/// The Swift twin reads every company bundle exactly as Go's
/// `internal/companybundle`, over the one shared fixture.
@Suite("CompanyBundle")
struct CompanyBundleTests {
    private static func cases() throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/companybundle/testdata/bundle_cases.json")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try #require(obj as? [[String: Any]])
    }

    private static let origins: [String: CompanyBundleOrigin] = [
        "link": .link, "mdm": .mdm, "code": .code, "local": .local
    ]

    private static func canonical(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        return try #require(String(bytes: data, encoding: .utf8))
    }

    private static func check(
        _ result: Result<CompanyBundle, CompanyBundleRefusal>, _ want: [String: Any], _ label: String
    ) throws {
        let ok = try #require(want["ok"] as? Bool)
        switch result {
        case .success(let bundle):
            #expect(ok, "\(label): accepted, want \(want["reason"] ?? "?")")
            guard ok else { return }
            let got = try JSONSerialization.jsonObject(with: try bundle.encodedJSON())
            #expect(try canonical(got) == canonical(try #require(want["bundle"])), "\(label)")
            #expect(CompanyBundle.slug(bundle.company) == want["slug"] as? String, "\(label): slug")
        case .failure(let refusal):
            #expect(!ok, "\(label): refused \(refusal.rawValue)")
            #expect(refusal.rawValue == want["reason"] as? String, "\(label)")
        }
    }

    @Test("every fixture case parses as in Go")
    func sharedFixture() throws {
        let cases = try Self.cases()
        #expect(cases.count >= 50)
        for c in cases {
            let name = c["name"] as? String ?? "?"
            let origin = try #require(Self.origins[c["origin"] as? String ?? ""], "\(name)")
            let want = try #require(c["want"] as? [String: Any])
            if let wire = c["wire"] as? String {
                try Self.check(CompanyBundle.parse(wire, origin: origin), want, "\(name) / parse")
            } else {
                let json = try #require(c["json"] as? String, "\(name)")
                let data = Data(json.utf8)
                try Self.check(CompanyBundle.parseJSON(data, origin: origin), want, "\(name) / parseJSON")
                try Self.check(
                    CompanyBundle.parse(CompanyBundle.base64URL(data), origin: origin), want, "\(name) / parse(wire)"
                )
            }
        }
    }

    @Test("an accepted bundle encodes to Go's exact wire form and parses back equal")
    func roundTripMatchesGoEncoding() throws {
        var pinned = 0
        for c in try Self.cases() {
            let want = try #require(c["want"] as? [String: Any])
            guard want["ok"] as? Bool == true, c["origin"] as? String != "local" else { continue }
            let name = c["name"] as? String ?? "?"
            let wantBundle = try JSONSerialization.data(withJSONObject: try #require(want["bundle"]))
            let bundle = try CompanyBundle.parseJSON(wantBundle, origin: .link).get()
            let wire = try bundle.encoded()
            #expect(!wire.contains("="), "\(name)")
            #expect(try CompanyBundle.parse(wire, origin: .link).get() == bundle, "\(name)")
            if let goWire = want["encoded"] as? String {
                pinned += 1
                #expect(wire == goWire, "\(name)")
            }
        }
        #expect(pinned > 0)
    }

    @Test("the refusal enum is Go's closed set")
    func refusalsAreClosedSet() {
        #expect(CompanyBundleRefusal.allCases.map(\.rawValue)
            == ["damaged", "too_long", "site_not_https", "personal", "newer_version"])
    }

    @Test("slugs match Go's", arguments: [
        ("Acme", "acme"), ("Acme Inc.", "acme-inc"), ("Ачме", "company"), ("", "company"),
        ("Ачме Acme", "acme"), ("Acme Ачме 2", "acme-2"), ("Draft", "draft-company"), ("---", "company")
    ])
    func slug(_ input: String, _ want: String) {
        #expect(CompanyBundle.slug(input) == want)
    }
}
