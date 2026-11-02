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
        var setProviders: [String] = []
        let working: Set<String>
        let setFails: Bool

        init(working: Set<String>, setFails: Bool = false) {
            self.working = working
            self.setFails = setFails
        }

        func test(_ provider: String?, configured: String) throws -> String {
            tests.append(provider)
            let effective = provider ?? configured
            guard working.contains(effective) else { throw Failure(message: "\(effective) not signed in") }
            return provider ?? configured
        }

        func set(_ provider: String) throws {
            setProviders.append(provider)
            if setFails { throw Failure(message: "config locked") }
        }
    }

    private func run(configured: String?, fake: Fake) async -> OnboardingCLICheck {
        let effective = (configured?.isEmpty ?? true) ? "claude" : configured!
        return await OnboardingCLIProbe.check(
            configuredProvider: configured,
            test: { try await fake.test($0, configured: effective) },
            setProvider: { try await fake.set($0) }
        )
    }

    func testConfiguredWorks_noFallback() async {
        let fake = Fake(working: ["claude", "codex"])
        let result = await run(configured: nil, fake: fake)
        XCTAssertEqual(result, .ready(provider: "claude"))
        let tests = await fake.tests
        let sets = await fake.setProviders
        XCTAssertEqual(tests, [nil])
        XCTAssertEqual(sets, [])
    }

    func testUnsetProvider_onlyCodex_switchesToCodex() async {
        let fake = Fake(working: ["codex"])
        let result = await run(configured: nil, fake: fake)
        XCTAssertEqual(result, .ready(provider: "codex"))
        let tests = await fake.tests
        let sets = await fake.setProviders
        XCTAssertEqual(tests, [nil, "codex"])
        XCTAssertEqual(sets, ["codex"])
    }

    func testEmptyProvider_treatedAsUnset() async {
        let fake = Fake(working: ["codex"])
        let result = await run(configured: "  ", fake: fake)
        XCTAssertEqual(result, .ready(provider: "codex"))
    }

    func testNeitherWorks_reportsTheConfiguredFailure() async {
        let fake = Fake(working: [])
        let result = await run(configured: nil, fake: fake)
        XCTAssertEqual(result, .failed("claude not signed in"))
        let sets = await fake.setProviders
        XCTAssertEqual(sets, [])
    }

    func testExplicitProvider_neverSwitched() async {
        let fake = Fake(working: ["codex"])
        let result = await run(configured: "claude", fake: fake)
        XCTAssertEqual(result, .failed("claude not signed in"))
        let tests = await fake.tests
        XCTAssertEqual(tests, [nil])
    }

    func testCodexWorksButSaveFails_isFailed() async {
        let fake = Fake(working: ["codex"], setFails: true)
        let result = await run(configured: nil, fake: fake)
        guard case .failed(let message) = result else { return XCTFail("expected failed, got \(result)") }
        XCTAssertTrue(message.contains("config locked"))
    }
}
