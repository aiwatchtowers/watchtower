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
        XCTAssertEqual(Self.settingLines(base, key: "WATCHTOWER_RELAY_ORIGIN"), ["WATCHTOWER_RELAY_ORIGIN ="],
                       "the committed origin must be empty")
        // Release forces it empty in the target's settings, which beat any xcconfig (a local Signing.xcconfig too).
        XCTAssertEqual(try Self.configSetting("WatchtowerMobile", config: "Release", key: "WATCHTOWER_RELAY_ORIGIN"),
                       "\"\"")
        XCTAssertNil(try Self.configSetting("WatchtowerMobile", config: "Debug", key: "WATCHTOWER_RELAY_ORIGIN"))
        let info = try Self.read("Info.plist")
        XCTAssertTrue(info.contains("<key>WTRelayOrigin</key>\n\t<string>$(WATCHTOWER_RELAY_ORIGIN)</string>"))
    }

    func testEntitlementsNameTheAppAttestEnvironmentPerConfiguration() throws {
        // Debug: the App Attest key, development (Base.xcconfig).
        XCTAssertNil(try Self.configSetting("WatchtowerMobile", config: "Debug", key: "CODE_SIGN_ENTITLEMENTS"))
        let debug = try Self.read("WatchtowerMobile.entitlements")
        XCTAssertTrue(debug.contains(
            "<key>\(Self.appAttestKey)</key>\n\t<string>$(WT_APP_ATTEST_ENV)</string>"
        ))
        let base = try Self.read("Base.xcconfig")
        XCTAssertEqual(Self.settingLines(base, key: "WT_APP_ATTEST_ENV"), ["WT_APP_ATTEST_ENV = development"])
        // Release: its own entitlements without the key until Phase 4.
        let releaseFile = try XCTUnwrap(
            try Self.configSetting("WatchtowerMobile", config: "Release", key: "CODE_SIGN_ENTITLEMENTS")
        )
        XCTAssertNotEqual(releaseFile, "WatchtowerMobile.entitlements")
        let release = try Self.read(releaseFile)
        XCTAssertFalse(release.contains(Self.appAttestKey))
        XCTAssertFalse(release.contains("WT_APP_ATTEST_ENV"))
        XCTAssertNil(try Self.configSetting("WatchtowerMobile", config: "Release", key: "WT_APP_ATTEST_ENV"))
        // Everything else matches the Debug file: the Release file is that file without the App Attest key.
        XCTAssertEqual(Self.keys(release), Self.keys(debug).filter { $0 != Self.appAttestKey })
    }

    func testOnlyTheAppTargetLinksTheRelayProduct() throws {
        XCTAssertTrue(try Self.targetBlock("WatchtowerMobile").contains("product: WatchtowerHostedRelay"))
        XCTAssertFalse(try Self.targetBlock("NotifyService").contains("WatchtowerHostedRelay"))
        XCTAssertFalse(try Self.targetBlock("NotifyContent").contains("WatchtowerHostedRelay"))
    }

    // MARK: - Project files

    private static let appAttestKey = "com.apple.developer.devicecheck.appattest-environment"

    private static let mobileRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    /// A project file read from the checkout; skipped where the checkout is out of reach (a device run).
    private static func read(_ name: String) throws -> String {
        let url = mobileRoot.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("project files are not reachable from this run (\(name))")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Non-comment lines of an xcconfig that assign `key` (any configuration condition included).
    private static func settingLines(_ xcconfig: String, key: String) -> [String] {
        xcconfig.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") && ($0.hasPrefix(key + " ") || $0.hasPrefix(key + "=") || $0.hasPrefix(key + "[")) }
    }

    /// The `<key>` names of a plist file, in order.
    private static func keys(_ plist: String) -> [String] {
        plist.components(separatedBy: "<key>").dropFirst().compactMap { $0.components(separatedBy: "</key>").first }
    }

    /// The lines of the `targets:` entry for `name` in project.yml, up to the next target.
    private static func targetLines(_ name: String) throws -> [String] {
        let lines = try read("project.yml").components(separatedBy: "\n")
        let targets = try XCTUnwrap(lines.firstIndex(of: "targets:"), "no targets in project.yml")
        guard let start = lines[targets...].firstIndex(of: "  \(name):") else {
            XCTFail("no target \(name) in project.yml")
            return []
        }
        // The next entry (or its leading comment) sits at two spaces; a top-level key at none.
        return Array(lines[(start + 1)...].prefix { $0.isEmpty || $0.hasPrefix("   ") })
    }

    private static func targetBlock(_ name: String) throws -> String {
        try targetLines(name).joined(separator: "\n")
    }

    /// The value `key` has in the target's `settings.configs.<config>` block, nil when that block does not set it.
    private static func configSetting(_ target: String, config: String, key: String) throws -> String? {
        let lines = try targetLines(target)
        func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }
        func children(of header: String, in lines: ArraySlice<String>) -> ArraySlice<String>? {
            guard let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else {
                return nil
            }
            let level = indent(lines[index])
            return lines[(index + 1)...].prefix { $0.isEmpty || indent($0) > level }
        }
        guard let settings = children(of: "settings:", in: lines[...]),
              let configs = children(of: "configs:", in: settings),
              let block = children(of: "\(config):", in: configs)
        else { return nil }
        let prefix = key + ":"
        for line in block {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(prefix) {
                return trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
