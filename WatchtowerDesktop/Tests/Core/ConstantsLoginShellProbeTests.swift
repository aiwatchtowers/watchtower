import XCTest
@testable import WatchtowerCore

/// `Constants.resolvedEnvironment`'s login-shell probe (board #399, spec
/// 2026-10-12 §7): PATH and the login shell's CODEX_HOME, read back past
/// whatever the shell's startup files print.
final class ConstantsLoginShellProbeTests: XCTestCase {
    func testParsesPathAndCodexHomePastNoise() {
        let output = """
            Welcome back!
            WATCHTOWER_PROBE_PATH=/opt/homebrew/bin:/usr/bin
            WATCHTOWER_PROBE_CODEX_HOME=/Users/example/.codex-work
            """
        let probed = Constants.parseLoginShellProbe(output)
        XCTAssertEqual(probed.path, "/opt/homebrew/bin:/usr/bin")
        XCTAssertEqual(probed.codexHome, "/Users/example/.codex-work")
    }

    func testEmptyOrMissingValuesAreNil() {
        let unset = Constants.parseLoginShellProbe("WATCHTOWER_PROBE_PATH=/usr/bin\nWATCHTOWER_PROBE_CODEX_HOME=\n")
        XCTAssertEqual(unset.path, "/usr/bin")
        XCTAssertNil(unset.codexHome, "an unset CODEX_HOME leaves the app's own")

        for output in ["", "\n", "/usr/bin\n", "garbage"] {
            let probed = Constants.parseLoginShellProbe(output)
            XCTAssertNil(probed.path, output)
            XCTAssertNil(probed.codexHome, output)
        }
    }

    /// The probe command itself, run by shells without startup files: the
    /// values come back verbatim, spaces included.
    func testProbeRunsUnderShAndZsh() throws {
        for (shell, flag) in [("/bin/sh", "-c"), ("/bin/zsh", "-fc")] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = [flag, Constants.loginShellProbe]
            process.environment = ["PATH": "/usr/bin:/bin:/Users/example/my tools", "CODEX_HOME": "/Users/example/codex home"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let probed = Constants.parseLoginShellProbe(output)
            XCTAssertEqual(probed.path, "/usr/bin:/bin:/Users/example/my tools", shell)
            XCTAssertEqual(probed.codexHome, "/Users/example/codex home", shell)
        }
    }

    /// `resolvedEnvironmentIfReady`'s store: empty until the resolve
    /// returns (the caller then gets the app's own environment), then the
    /// first value for good. No login shell runs here.
    func testResolvedEnvironmentBoxKeepsTheFirstValue() {
        let box = ResolvedEnvironmentBox()
        XCTAssertNil(box.get())
        box.set(["CODEX_HOME": "/Users/example/cx"])
        box.set(["CODEX_HOME": "/Users/example/other"])
        XCTAssertEqual(box.get(), ["CODEX_HOME": "/Users/example/cx"])
    }

    /// A login shell that did not answer is not cached: the next resolve
    /// probes again; the first answer stays for good (#399 F1, F2). The probe
    /// is injected — no shell runs.
    func testLoginEnvironmentResolverRetriesUntilAnAnswer() async {
        let answers = ProbeAnswers([nil, ["CODEX_HOME": "/Users/example/cx"], ["CODEX_HOME": "/Users/example/other"]])
        let resolver = LoginEnvironmentResolver { answers.next() }

        let first = await resolver.resolve()
        XCTAssertNil(first, "the shell did not answer")
        let second = await resolver.resolve()
        XCTAssertEqual(second, ["CODEX_HOME": "/Users/example/cx"])
        let third = await resolver.resolve()
        XCTAssertEqual(third, ["CODEX_HOME": "/Users/example/cx"], "an answer is cached")
        XCTAssertEqual(answers.calls, 2, "no probe after the answer")
    }
}

/// Probe answers in order, thread-safe (the resolver probes on a thread of
/// its own).
private final class ProbeAnswers: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [[String: String]?]
    private(set) var calls = 0

    init(_ answers: [[String: String]?]) {
        self.answers = answers
    }

    func next() -> [String: String]? {
        lock.withLock {
            calls += 1
            return answers.isEmpty ? nil : answers.removeFirst()
        }
    }
}

/// Board #592: the async variant is the resolved environment itself, never
/// the app's own fallback, and once it returns the non-blocking variant agrees.
final class ConstantsResolvedEnvironmentAsyncTests: XCTestCase {
    func testAsyncVariantMatchesTheResolvedEnvironment() async {
        let awaited = await Constants.resolvedEnvironmentAsync()
        XCTAssertEqual(Constants.resolvedEnvironmentIfReady(), awaited, "resolved, so IfReady has it too")
        let again = await Constants.resolvedEnvironmentAsync()
        XCTAssertEqual(again, awaited, "the cached value")
        XCTAssertEqual(Constants.resolvedEnvironment(), awaited, "the same resolve")
    }
}
