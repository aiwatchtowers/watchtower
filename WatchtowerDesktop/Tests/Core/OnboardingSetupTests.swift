import XCTest
@testable import WatchtowerCore

/// The onboarding steps' non-UI logic: the `claude_path` config edit, the
/// `config set` sequence and the sync banner's progress/ETA math.
final class OnboardingSetupTests: XCTestCase {

    // MARK: - claude_path

    func testYAMLQuoteDoublesSingleQuotes() {
        XCTAssertEqual(OnboardingClaudePathConfig.yamlQuote("/opt/bin/claude"), "'/opt/bin/claude'")
        XCTAssertEqual(OnboardingClaudePathConfig.yamlQuote("/it's/claude"), "'/it''s/claude'")
    }

    func testSettingReplacesAnExistingPathAndKeepsOtherLines() {
        let existing = "digest:\n  language: English\nclaude_path: '/old'\nsync:\n  poll_interval: 15m"
        XCTAssertEqual(
            OnboardingClaudePathConfig.settingClaudePath("/new", in: existing),
            "digest:\n  language: English\nsync:\n  poll_interval: 15m\nclaude_path: '/new'\n"
        )
    }

    func testSettingIntoNoOrAnEmptyFileWritesTheLineAlone() {
        XCTAssertEqual(OnboardingClaudePathConfig.settingClaudePath("/c", in: nil), "claude_path: '/c'\n")
        XCTAssertEqual(OnboardingClaudePathConfig.settingClaudePath("/c", in: ""), "claude_path: '/c'\n")
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testSaveCreatesAMissingConfigOwnerOnly() throws {
        let configPath = try tempDir().appendingPathComponent("nested/config.yaml").path

        try OnboardingClaudePathConfig.save("/opt/claude", configPath: configPath)

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

        try OnboardingClaudePathConfig.save("/new", configPath: configPath)

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

        XCTAssertThrowsError(try OnboardingClaudePathConfig.save("/x\nslack_token: stolen", configPath: configPath))
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

        XCTAssertThrowsError(try OnboardingClaudePathConfig.save("/c", configPath: configPath))
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

        XCTAssertThrowsError(try OnboardingClaudePathConfig.save("/c", configPath: configPath))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: configPath, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    // MARK: - config set

    private actor Calls {
        var argv: [[String]] = []
        func record(_ arguments: [String]) { argv.append(arguments) }
    }

    func testApplyWritesEveryKeyInOrder() async {
        let calls = Calls()
        let failure = await OnboardingSettingsPlan.apply([("digest.language", "English"), ("sync.poll_interval", "15m")]) {
            await calls.record($0)
            return ProcessOutput(exitCode: 0, stdout: "", stderr: "")
        }
        XCTAssertNil(failure)
        let argv = await calls.argv
        XCTAssertEqual(argv, [["config", "set", "digest.language", "English"], ["config", "set", "sync.poll_interval", "15m"]])
    }

    func testApplyStopsAtTheFirstFailedKey() async {
        let calls = Calls()
        let failure = await OnboardingSettingsPlan.apply([("a", "1"), ("b", "2"), ("c", "3")]) { arguments in
            await calls.record(arguments)
            return ProcessOutput(exitCode: arguments[2] == "b" ? 1 : 0, stdout: "", stderr: "bad value")
        }
        XCTAssertEqual(failure, "Failed to set b: bad value")
        let argv = await calls.argv
        XCTAssertEqual(argv.map { $0[2] }, ["a", "b"], "nothing after the failure is written")
    }

    func testApplyFailureWithoutStderrStillSaysWhy() async {
        let fromStdout = await OnboardingSettingsPlan.apply([("a", "1")]) { _ in
            ProcessOutput(exitCode: 1, stdout: "unknown key\n", stderr: " ")
        }
        XCTAssertEqual(fromStdout, "Failed to set a: unknown key")
        let silent = await OnboardingSettingsPlan.apply([("a", "1")]) { _ in
            ProcessOutput(exitCode: 9, stdout: "", stderr: "")
        }
        XCTAssertEqual(silent, "Failed to set a: exit code 9")
    }

    // MARK: - Sync progress

    private func progress(_ phase: String, done: Int = 0, total: Int = 0) throws -> SyncProgressData {
        let counts: [String: Int] = switch phase {
        case "Discovery": ["discovery_pages": done, "discovery_total_pages": total]
        case "Messages": ["msg_channels_done": done, "msg_channels_total": total]
        case "Users": ["user_profiles_done": done, "user_profiles_total": total]
        case "Threads": ["threads_done": done, "threads_total": total]
        default: [:]
        }
        var json: [String: Any] = ["phase": phase, "elapsed_sec": 0]
        for key in [
            "users_total", "users_done", "channels_total", "channels_done", "discovery_pages",
            "discovery_total_pages", "discovery_channels", "discovery_users", "user_profiles_total",
            "user_profiles_done", "msg_channels_total", "msg_channels_done", "messages_fetched"
        ] {
            json[key] = counts[key] ?? 0
        }
        if let threadsDone = counts["threads_done"] { json["threads_done"] = threadsDone }
        if let threadsTotal = counts["threads_total"] { json["threads_total"] = threadsTotal }
        return try JSONDecoder().decode(SyncProgressData.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testPhaseCountsReadThePhasesOwnCounters() throws {
        XCTAssertTrue(OnboardingSyncETA.phaseCounts(try progress("Discovery", done: 2, total: 5)) == (2, 5))
        XCTAssertTrue(OnboardingSyncETA.phaseCounts(try progress("Messages", done: 3, total: 9)) == (3, 9))
        XCTAssertTrue(OnboardingSyncETA.phaseCounts(try progress("Users", done: 4, total: 8)) == (4, 8))
        XCTAssertTrue(OnboardingSyncETA.phaseCounts(try progress("Threads", done: 1, total: 2)) == (1, 2))
        XCTAssertTrue(OnboardingSyncETA.phaseCounts(try progress("Finishing")) == (0, 0))
    }

    func testETAExtrapolatesThePhaseRateAndRestartsOnANewPhase() throws {
        var eta = OnboardingSyncETA()
        let start = Date()

        eta.update(try progress("Messages", done: 0, total: 100), now: start)
        XCTAssertNil(eta.etaSeconds, "a phase's first line only starts its clock")

        eta.update(try progress("Messages", done: 10, total: 100), now: start.addingTimeInterval(1))
        XCTAssertNil(eta.etaSeconds, "under two seconds in, the rate is not trusted")

        eta.update(try progress("Messages", done: 25, total: 100), now: start.addingTimeInterval(10))
        XCTAssertEqual(try XCTUnwrap(eta.etaSeconds), 30, accuracy: 0.001, "2.5/s with 75 left")

        eta.update(try progress("Users", done: 50, total: 100), now: start.addingTimeInterval(11))
        XCTAssertNil(eta.etaSeconds, "a new phase restarts the clock")

        eta.update(try progress("Users", done: 0, total: 100), now: start.addingTimeInterval(20))
        XCTAssertNil(eta.etaSeconds, "nothing done yet: no rate")
    }

    func testFormatting() {
        XCTAssertEqual(OnboardingSyncETA.formatElapsed(42.9), "42s")
        XCTAssertEqual(OnboardingSyncETA.formatElapsed(125), "2m 5s")
        XCTAssertEqual(OnboardingSyncETA.formatETA(3), "< 5s")
        XCTAssertEqual(OnboardingSyncETA.formatETA(45), "~45s")
        XCTAssertEqual(OnboardingSyncETA.formatETA(120), "~2m")
        XCTAssertEqual(OnboardingSyncETA.formatETA(150), "~2m 30s")
    }
}
