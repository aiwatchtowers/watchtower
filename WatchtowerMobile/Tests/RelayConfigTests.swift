import XCTest
@testable import WatchtowerMobile

/// The relay origin setting (relay client Phase 3, Task 2): an empty origin is "not configured", which is how
/// every committed build — and so every Release build — ships dark.
final class RelayConfigTests: XCTestCase {
    func testEmptyOrUnexpandedOriginIsNotConfigured() {
        XCTAssertNil(RelayConfig.parse(nil).origin)
        XCTAssertNil(RelayConfig.parse("").origin)
        XCTAssertNil(RelayConfig.parse("   \n").origin)
        XCTAssertNil(RelayConfig.parse("$(WATCHTOWER_RELAY_ORIGIN)").origin)
        XCTAssertNil(RelayConfig.parse("https://relay.example.com/$(X)").origin)
        XCTAssertNil(RelayConfig.parse("not a url").origin)
        XCTAssertNil(RelayConfig.parse("https://relay.example.com/path").origin)
        XCTAssertNil(RelayConfig.parse("ftp://relay.example.com").origin)
    }

    func testHTTPSOriginIsTrimmedOfItsSlash() {
        XCTAssertEqual(RelayConfig.parse("https://relay.example.com/").origin?.string, "https://relay.example.com")
        XCTAssertEqual(RelayConfig.parse(" https://relay.example.com ").origin?.string, "https://relay.example.com")
        XCTAssertEqual(RelayConfig.parse("https://relay.example.com:8443").origin?.string, "https://relay.example.com:8443")
    }

    func testPlainHTTPOnlyToLoopbackOrLAN() {
        for allowed in [
            "http://127.0.0.1:8787", "http://localhost:8787", "http://[::1]:8787",
            "http://10.0.0.5:8787", "http://172.16.0.1:8787", "http://172.31.255.254:8787",
            "http://192.168.1.20:8787/"
        ] {
            XCTAssertNotNil(RelayConfig.parse(allowed).origin, allowed)
        }
        for refused in [
            "http://relay.example.com", "http://8.8.8.8:8787", "http://172.32.0.1:8787",
            "http://172.15.0.1:8787", "http://192.169.0.1:8787", "http://11.0.0.1",
            "http://10.0.0", "http://localhost.example.com"
        ] {
            XCTAssertNil(RelayConfig.parse(refused).origin, refused)
        }
    }

    func testReleaseCarriesNoOrigin() throws {
        let base = try Self.read("Base.xcconfig")
        let originLines = Self.settingLines(base, key: "WATCHTOWER_RELAY_ORIGIN")
        XCTAssertEqual(originLines, ["WATCHTOWER_RELAY_ORIGIN ="], "the committed origin must be empty")
        let project = try Self.read("project.yml")
        XCTAssertFalse(project.contains("WATCHTOWER_RELAY_ORIGIN"), "project.yml must not set an origin")
        let info = try Self.read("Info.plist")
        XCTAssertTrue(info.contains("<key>WTRelayOrigin</key>\n\t<string>$(WATCHTOWER_RELAY_ORIGIN)</string>"))
        // The test host itself was built from the committed settings: no origin.
        XCTAssertNil(RelayConfig.from(bundle: .main).origin)
    }

    func testEntitlementsNameTheAppAttestEnvironmentPerConfiguration() throws {
        let entitlements = try Self.read("WatchtowerMobile.entitlements")
        XCTAssertTrue(entitlements.contains(
            "<key>com.apple.developer.devicecheck.appattest-environment</key>\n\t<string>$(WT_APP_ATTEST_ENV)</string>"
        ))
        let base = try Self.read("Base.xcconfig")
        XCTAssertEqual(Self.settingLines(base, key: "WT_APP_ATTEST_ENV"), ["WT_APP_ATTEST_ENV = development"])
        let app = try Self.targetBlock("WatchtowerMobile")
        XCTAssertTrue(app.contains("        Release:\n          WT_APP_ATTEST_ENV: production"),
                      "Release must set the production App Attest environment")
        XCTAssertFalse(app.contains("WT_APP_ATTEST_ENV: development"))
    }

    func testOnlyTheAppTargetLinksTheRelayProduct() throws {
        XCTAssertTrue(try Self.targetBlock("WatchtowerMobile").contains("product: WatchtowerHostedRelay\n"))
        XCTAssertFalse(try Self.targetBlock("NotifyService").contains("WatchtowerHostedRelay"))
        XCTAssertFalse(try Self.targetBlock("NotifyContent").contains("WatchtowerHostedRelay"))
    }

    // MARK: - Project files

    private static let mobileRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    private static func read(_ name: String) throws -> String {
        try String(contentsOf: mobileRoot.appendingPathComponent(name), encoding: .utf8)
    }

    /// Non-comment lines of an xcconfig that assign `key` (any configuration condition included).
    private static func settingLines(_ xcconfig: String, key: String) -> [String] {
        xcconfig.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && ($0.hasPrefix(key + " ") || $0.hasPrefix(key + "=") || $0.hasPrefix(key + "[")) }
    }

    /// The `targets:` entry for `name` in project.yml, up to the next target.
    private static func targetBlock(_ name: String) throws -> String {
        let lines = try read("project.yml").components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "  \(name):") else {
            XCTFail("no target \(name) in project.yml")
            return ""
        }
        var block: [String] = []
        for line in lines[(start + 1)...] {
            // The next entry (or its leading comment) sits at two spaces; a top-level key at none.
            if !line.isEmpty, !line.hasPrefix("   ") { break }
            block.append(line)
        }
        return block.joined(separator: "\n") + "\n"
    }
}
