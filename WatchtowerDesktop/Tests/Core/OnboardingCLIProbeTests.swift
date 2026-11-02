import XCTest
@testable import WatchtowerCore

final class OnboardingCLIProbeTests: XCTestCase {
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Records the calls and answers per provider (nil = configured).
    private actor Fake {
        var tests: [String?] = []
        var switches: [String] = []
        let working: Set<String>
        let switchFails: Bool

        init(working: Set<String>, switchFails: Bool = false) {
            self.working = working
            self.switchFails = switchFails
        }

        func test(_ provider: String?, configured: String) throws -> String {
            tests.append(provider)
            let effective = provider ?? configured
            guard working.contains(effective) else { throw Failure(message: "\(effective) not signed in") }
            return effective
        }

        func switchTo(_ provider: String) throws {
            switches.append(provider)
            if switchFails { throw Failure(message: "config locked") }
        }
    }

    private func run(
        configured: String? = nil,
        unreadable: Bool = false,
        claudeInstalled: Bool = false,
        fake: Fake
    ) async -> OnboardingCLICheck {
        let trimmed = configured?.trimmingCharacters(in: .whitespaces) ?? ""
        let effective = trimmed.isEmpty ? "claude" : trimmed
        return await OnboardingCLIProbe.check(
            .init(configuredProvider: configured, configUnreadable: unreadable, claudeInstalled: claudeInstalled),
            test: { try await fake.test($0, configured: effective) },
            switchProvider: { try await fake.switchTo($0) }
        )
    }

    func testConfiguredWorks_noFallback() async {
        let fake = Fake(working: ["claude", "codex"])
        let result = await run(claudeInstalled: true, fake: fake)
        XCTAssertEqual(result, .ready(provider: "claude"))
        let tests = await fake.tests
        let switches = await fake.switches
        XCTAssertEqual(tests, [nil])
        XCTAssertEqual(switches, [])
    }

    func testNoClaude_onlyCodex_switchesToCodex() async {
        let fake = Fake(working: ["codex"])
        let result = await run(fake: fake)
        XCTAssertEqual(result, .ready(provider: "codex", switched: true))
        let tests = await fake.tests
        let switches = await fake.switches
        XCTAssertEqual(tests, [nil, "codex"])
        XCTAssertEqual(switches, ["codex"])
    }

    func testBlankProvider_treatedAsUnset() async {
        let fake = Fake(working: ["codex"])
        let result = await run(configured: "  ", fake: fake)
        XCTAssertEqual(result, .ready(provider: "codex", switched: true))
    }

    func testClaudeInstalledButFailing_neverSwitched() async {
        // A transient error, a timeout or an expired Claude sign-in must not
        // move an owner who has Claude Code onto Codex for good.
        let fake = Fake(working: ["codex"])
        let result = await run(claudeInstalled: true, fake: fake)
        XCTAssertEqual(result, .failed("claude not signed in"))
        let tests = await fake.tests
        XCTAssertEqual(tests, [nil])
    }

    func testExplicitProvider_neverSwitched() async {
        let fake = Fake(working: ["codex"])
        let result = await run(configured: "claude", fake: fake)
        XCTAssertEqual(result, .failed("claude not signed in"))
        let tests = await fake.tests
        XCTAssertEqual(tests, [nil])
    }

    func testUnreadableConfig_neverSwitched() async {
        let fake = Fake(working: ["codex"])
        let result = await run(unreadable: true, fake: fake)
        XCTAssertEqual(result, .failed("claude not signed in"))
        let switches = await fake.switches
        XCTAssertEqual(switches, [])
    }

    func testNeitherWorks_reportsBothReasons() async {
        let fake = Fake(working: [])
        let result = await run(fake: fake)
        XCTAssertEqual(result, .failed("Claude Code: claude not signed in\nCodex CLI: codex not signed in"))
        let switches = await fake.switches
        XCTAssertEqual(switches, [])
    }

    func testCodexWorksButSwitchFails_isFailed() async {
        let fake = Fake(working: ["codex"], switchFails: true)
        let result = await run(fake: fake)
        guard case .failed(let message) = result else { return XCTFail("expected failed, got \(result)") }
        XCTAssertTrue(message.contains("config locked"))
    }
}
