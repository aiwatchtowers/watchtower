import XCTest
@testable import WatchtowerCore

/// The agent check's `claude_path` / `codex_path` config edit ("Choose the executable…").
final class OnboardingAgentPathConfigTests: XCTestCase {

    // MARK: - claude_path

    func testYAMLQuoteDoublesSingleQuotes() {
        XCTAssertEqual(OnboardingAgentPathConfig.yamlQuote("/opt/bin/claude"), "'/opt/bin/claude'")
        XCTAssertEqual(OnboardingAgentPathConfig.yamlQuote("/it's/claude"), "'/it''s/claude'")
    }

    func testSettingReplacesAnExistingPathAndKeepsOtherLines() {
        let existing = "digest:\n  language: English\nclaude_path: '/old'\nsync:\n  poll_interval: 15m"
        XCTAssertEqual(
            OnboardingAgentPathConfig.settingPath("/new", for: .claude, in: existing),
            "digest:\n  language: English\nsync:\n  poll_interval: 15m\nclaude_path: '/new'\n"
        )
    }

    func testSettingIntoNoOrAnEmptyFileWritesTheLineAlone() {
        XCTAssertEqual(OnboardingAgentPathConfig.settingPath("/c", for: .claude, in: nil), "claude_path: '/c'\n")
        XCTAssertEqual(OnboardingAgentPathConfig.settingPath("/c", for: .claude, in: ""), "claude_path: '/c'\n")
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testSaveCreatesAMissingConfigOwnerOnly() throws {
        let configPath = try tempDir().appendingPathComponent("nested/config.yaml").path

        try OnboardingAgentPathConfig.save("/opt/claude", for: .claude, configPath: configPath)

        XCTAssertEqual(try String(contentsOfFile: configPath, encoding: .utf8), "claude_path: '/opt/claude'\n")
        let mode = try FileManager.default.attributesOfItem(atPath: configPath)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testSaveRewritesAnExistingConfig() throws {
        let dir = try tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let configPath = dir.appendingPathComponent("config.yaml").path
        try "active_workspace: acme\nclaude_path: '/old'\n".write(toFile: configPath, atomically: true, encoding: .utf8)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: configPath)

        try OnboardingAgentPathConfig.save("/new", for: .claude, configPath: configPath)

        XCTAssertEqual(try String(contentsOfFile: configPath, encoding: .utf8), "active_workspace: acme\nclaude_path: '/new'\n")
        let mode = try FileManager.default.attributesOfItem(atPath: configPath)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600, "a rewrite locks a loose config down")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["config.yaml"], "no staged file left")
    }

    /// A line break in the path would end the quoted scalar's line: refused,
    /// the config untouched.
    func testSaveRefusesAPathWithALineBreak() throws {
        let dir = try tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let configPath = dir.appendingPathComponent("config.yaml").path
        try "active_workspace: acme\n".write(toFile: configPath, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try OnboardingAgentPathConfig.save("/x\nslack_token: stolen", for: .claude, configPath: configPath))
        XCTAssertEqual(try String(contentsOfFile: configPath, encoding: .utf8), "active_workspace: acme\n")
    }

    /// The old writer fell back to overwriting a config it could not read as
    /// UTF-8 with the single line, wiping the owner's settings.
    func testSaveLeavesAnUnreadableConfigAlone() throws {
        let dir = try tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let configPath = dir.appendingPathComponent("config.yaml").path
        let garbage = Data([0x61, 0x3A, 0x20, 0xFF, 0xFE, 0x0A])
        try garbage.write(to: URL(fileURLWithPath: configPath))

        XCTAssertThrowsError(try OnboardingAgentPathConfig.save("/c", for: .claude, configPath: configPath))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: configPath)), garbage)
    }

    /// A failed write surfaces instead of passing silently — and an unreadable
    /// config is never overwritten with the single line.
    func testSaveThrowsWhenTheConfigCannotBeWritten() throws {
        let dir = try tempDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A directory where the file should be: neither readable as text nor writable.
        let configPath = dir.appendingPathComponent("config.yaml").path
        try FileManager.default.createDirectory(atPath: configPath, withIntermediateDirectories: true)

        XCTAssertThrowsError(try OnboardingAgentPathConfig.save("/c", for: .claude, configPath: configPath))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: configPath, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    func testSavesCodexPath() throws {
        let configPath = try tempDir().appendingPathComponent("nested/config.yaml").path

        try OnboardingAgentPathConfig.save("/opt/codex", for: .codex, configPath: configPath)

        XCTAssertEqual(try String(contentsOfFile: configPath, encoding: .utf8), "codex_path: '/opt/codex'\n")
    }

    func testKeepsOtherLinesIncludingTheOtherAgentsPath() {
        let existing = "claude_path: '/c'\ncodex_path: '/old'\nsync:\n  poll_interval: 15m"
        XCTAssertEqual(
            OnboardingAgentPathConfig.settingPath("/new", for: .codex, in: existing),
            "claude_path: '/c'\nsync:\n  poll_interval: 15m\ncodex_path: '/new'\n"
        )
    }
}
