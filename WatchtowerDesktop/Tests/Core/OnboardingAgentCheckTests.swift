import XCTest
@testable import WatchtowerCore

private actor Calls {
    var located: [String] = []
    var tested: [String] = []
    var helped: [String] = []
    var entered = 0
    func locate(_ a: String) { located.append(a) }
    func test(_ a: String) { tested.append(a) }
    func help(_ a: String) { helped.append(a) }
    func enter() -> Int { entered += 1; return entered }
    func enteredCount() -> Int { entered }
}

final class OnboardingAgentCheckTests: XCTestCase {
    private typealias Agent = OnboardingAgentChoice.Agent
    private typealias Result = OnboardingAgentTestResult

    private func probes(
        configured: String? = nil,
        allowed: @escaping @Sendable (Agent) -> Bool = { _ in true },
        located: [Agent: String] = [.claude: "/opt/bin/claude", .codex: "/opt/bin/codex"],
        resolve: @escaping @Sendable (String) -> String = { $0 },
        help: @escaping @Sendable (Agent, String) async -> String? = { _, _ in nil },
        calls: Calls,
        test: @escaping @Sendable (String?, String?) async -> Result
    ) -> OnboardingAgentProbes {
        OnboardingAgentProbes(
            configuredProvider: configured,
            allowed: allowed,
            locate: { agent in await calls.locate(agent.rawValue); return located[agent] },
            resolve: resolve,
            help: { agent, exe in await calls.help(agent.rawValue); return await help(agent, exe) },
            test: { provider, exe in await calls.test(provider ?? "<configured>"); return await test(provider, exe) },
            home: "/Users/acme"
        )
    }

    func testForbiddenAgentIsNeverLocatedOrTested() async {
        let calls = Calls()
        let result = await OnboardingAgentCheck.run(probes(allowed: { $0 != .claude }, calls: calls) { _, _ in Result(ok: true) })
        XCTAssertEqual(result.statuses[.claude], .forbidden)
        let located = await calls.located
        let tested = await calls.tested
        XCTAssertFalse(located.contains("claude"))
        XCTAssertFalse(tested.contains("claude"))
    }

    func testMissingAgentCostsNoRequest() async {
        let calls = Calls()
        let result = await OnboardingAgentCheck.run(probes(located: [.claude: "/opt/bin/claude"], calls: calls) { _, _ in Result(ok: true) })
        XCTAssertEqual(result.statuses[.codex], .notInstalled)
        let tested = await calls.tested
        XCTAssertEqual(tested, ["claude"])
    }

    func testStatusFromTheTest() async {
        func status(_ code: String?) async -> OnboardingAgentChoice.Status? {
            let r = await OnboardingAgentCheck.run(probes(located: [.claude: "/opt/bin/claude"], help: { _, _ in "  login [options]\n" }, calls: Calls()) { _, _ in
                code == nil ? Result(ok: true) : Result(ok: false, errorCode: code, error: "boom")
            })
            return r.statuses[.claude]
        }
        let ready = await status(nil)
        let auth = await status("auth")
        let policy = await status("policy")
        let timeout = await status("timeout")
        XCTAssertEqual(ready, .ready)
        XCTAssertEqual(auth, .signedOut)
        XCTAssertEqual(policy, .forbidden)
        XCTAssertEqual(timeout, .failed(OnboardingAgentChoice.failureMessage(.claude, code: "timeout", error: "boom")))
    }

    func testBothInstalledAreTestedInParallel() async {
        let calls = Calls()
        let result = await OnboardingAgentCheck.run(probes(calls: calls) { _, _ in
            _ = await calls.enter()
            // Opens only when both have been entered.
            for _ in 0..<2000 where await calls.enteredCount() < 2 { try? await Task.sleep(nanoseconds: 1_000_000) }
            let count = await calls.enteredCount()
            return Result(ok: count >= 2)
        })
        XCTAssertEqual(result.statuses[.claude], .ready)
        XCTAssertEqual(result.statuses[.codex], .ready)
    }

    func testInstallFromLocatedPath() async {
        let calls = Calls()
        let seen = Calls()
        let resolved = "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"
        let result = await OnboardingAgentCheck.run(probes(
            located: [.codex: "/opt/homebrew/bin/codex"],
            resolve: { $0 == "/opt/homebrew/bin/codex" ? resolved : $0 },
            calls: calls
        ) { _, exe in await seen.test(exe ?? "nil"); return Result(ok: true) })
        XCTAssertEqual(result.installs[.codex], .init(path: resolved, kind: .npm, executable: "/opt/homebrew/bin/codex"))
        let exes = await seen.tested
        XCTAssertEqual(exes, ["/opt/homebrew/bin/codex"])
    }

    func testHelpProbeOnlyForSignedOut() async {
        let calls = Calls()
        let helpSeen = Calls()
        let result = await OnboardingAgentCheck.run(probes(
            help: { agent, exe in await helpSeen.help("\(agent.rawValue)=\(exe)"); return "Commands:\n  logout\n" },
            calls: calls
        ) { provider, _ in provider == "claude" ? Result(ok: false, errorCode: "auth") : Result(ok: true) })
        let helped = await helpSeen.helped
        XCTAssertEqual(helped, ["claude=/opt/bin/claude"])
        XCTAssertEqual(result.outdated, [.claude])
    }

    func testHelpTimeoutCountsAsOutdated() async {
        let result = await OnboardingAgentCheck.run(probes(located: [.claude: "/opt/bin/claude"], help: { _, _ in nil }, calls: Calls()) { _, _ in
            Result(ok: false, errorCode: "auth")
        })
        XCTAssertEqual(result.outdated, [.claude])
    }

    func testOtherProviderWorking() async {
        let calls = Calls()
        let result = await OnboardingAgentCheck.run(probes(configured: "ollama", calls: calls) { _, _ in Result(ok: true) })
        XCTAssertEqual(result.otherProvider, "Ollama")
        XCTAssertNil(result.otherProviderFailure)
        let located = await calls.located
        let tested = await calls.tested
        XCTAssertTrue(located.isEmpty)
        XCTAssertEqual(tested, ["<configured>"])
    }

    func testOtherProviderFailingChecksTheAgents() async {
        let calls = Calls()
        let result = await OnboardingAgentCheck.run(probes(configured: "ollama", calls: calls) { provider, _ in
            provider == nil ? Result(ok: false, errorCode: "transport") : Result(ok: true)
        })
        XCTAssertEqual(result.otherProvider, "Ollama")
        XCTAssertEqual(result.otherProviderFailure, "Couldn’t reach it.")
        XCTAssertEqual(result.statuses[.claude], .ready)
        XCTAssertEqual(result.statuses[.codex], .ready)
    }
}
