import Darwin
import XCTest
@testable import WatchtowerCore
@testable import WatchtowerDesktop

/// #1521: the production probes — one lookup through `ai which`, the
/// login-help probe in its own process group, `ai test --json` decoding.
@MainActor
final class OnboardingAgentProbesTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("agent-probes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func script(_ name: String, _ body: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func probes(watchtower: String? = nil, helpTimeout: TimeInterval = 5) -> OnboardingAgentProbes {
        .production(
            config: ConfigService(configPath: dir.appendingPathComponent("config.yaml").path),
            policy: .none,
            watchtower: watchtower,
            helpTimeout: helpTimeout
        )
    }

    func testResolveFollowsSymlinks() throws {
        let pkg = dir.appendingPathComponent("pkg")
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let target = pkg.appendingPathComponent("codex.js")
        try "x".write(to: target, atomically: true, encoding: .utf8)
        let link = bin.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let resolved = probes().resolve(link.path)

        XCTAssertEqual(resolved, target.resolvingSymlinksInPath().path)
    }

    /// Nothing is cached in Swift: the stub answers not found, then found.
    func testLocateIsFreshEachCall() async throws {
        let counter = dir.appendingPathComponent("count").path
        let stub = try script("watchtower", """
        n=$(cat "\(counter)" 2>/dev/null || echo 0)
        echo $((n+1)) > "\(counter)"
        if [ "$n" = "0" ]; then
          echo '{"provider":"codex","path":"","found":false}'
        else
          echo '{"provider":"codex","path":"/x/codex","found":true}'
        fi
        """)
        let probes = probes(watchtower: stub)

        let first = await probes.locate(.codex)
        let second = await probes.locate(.codex)

        XCTAssertEqual(first, .notFound)
        XCTAssertEqual(second, .found("/x/codex"))
    }

    func testLocateAsksForTheAgentJSON() async throws {
        let argvFile = dir.appendingPathComponent("argv").path
        let stub = try script("watchtower", "echo \"$@\" > \"\(argvFile)\"; echo '{\"provider\":\"claude\",\"path\":\"/x/claude\",\"found\":true}'")

        let path = await probes(watchtower: stub).locate(.claude)

        XCTAssertEqual(path, .found("/x/claude"))
        XCTAssertEqual(try String(contentsOfFile: argvFile, encoding: .utf8), "ai which --provider claude --json\n")
    }

    func testTestPassesProviderAndCliPath() async throws {
        let argvFile = dir.appendingPathComponent("argv").path
        let stub = try script("watchtower", "echo \"$@\" > \"\(argvFile)\"; echo '{\"ok\":true,\"provider\":\"codex\",\"model\":\"m\"}'")

        let result = await probes(watchtower: stub).test("codex", "/x/codex")

        XCTAssertTrue(result.ok)
        XCTAssertEqual(try String(contentsOfFile: argvFile, encoding: .utf8), "ai test --json --provider codex --cli-path /x/codex\n")
    }

    func testHelpRunsTheRightArguments() async throws {
        let echo = try script("agent", "echo \"args: $@\"; echo err >&2")
        let probes = probes()

        let claude = await probes.help(.claude, echo)
        let codex = await probes.help(.codex, echo)

        XCTAssertEqual(claude?.contains("args: auth --help"), true)
        XCTAssertEqual(claude?.contains("err"), true, "stderr is captured too")
        XCTAssertEqual(codex?.contains("args: login --help"), true)
    }

    func testHelpProbeTimesOutAndReapsItsGroup() async throws {
        let leaderFile = dir.appendingPathComponent("leader").path
        let childFile = dir.appendingPathComponent("grandchild").path
        // The grandchild sleeps too: the group, not just the child, must die.
        let slow = try script("agent", "echo $$ > \"\(leaderFile)\"\nsleep 30 &\necho $! > \"\(childFile)\"\nsleep 30")
        let started = Date()
        // Teardown reaps the group even when the code under test regressed.
        addTeardownBlock {
            for (file, group) in [(leaderFile, true), (childFile, false)] {
                guard let raw = try? String(contentsOfFile: file, encoding: .utf8),
                      let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    XCTFail("the stub never recorded \(file)")
                    continue
                }
                if group { _ = killpg(pid, SIGKILL) }
                _ = kill(pid, SIGKILL)
            }
        }

        let text = await probes(helpTimeout: 1).help(.claude, slow)

        XCTAssertNil(text)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let pid = try XCTUnwrap(Int32(String(contentsOfFile: childFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        var gone = false
        for _ in 0..<50 where !gone {
            if kill(pid, 0) != 0 { gone = true } else { try await Task.sleep(for: .milliseconds(100)) }
        }
        XCTAssertTrue(gone, "the grandchild is gone with its group")
    }

    /// The probed child inherits only 0, 1, 2: a descriptor the app has open
    /// (no FD_CLOEXEC, like another probe's pipe end) must not reach it.
    func testChildDoesNotInheritOtherDescriptors() async throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        let high = fcntl(fds[0], F_DUPFD, 200)  // not close-on-exec
        XCTAssertGreaterThanOrEqual(high, 200)
        addTeardownBlock {
            close(fds[0]); close(fds[1]); close(high)
        }
        let lister = try script("lister", "ls /dev/fd")

        let helped = await probes().help(.claude, lister)
        let text = try XCTUnwrap(helped)

        let listed = Set(text.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) })
        XCTAssertTrue(listed.isSuperset(of: [0, 1, 2]), "the capture fds are there: \(listed)")
        XCTAssertFalse(listed.contains(high), "the app's descriptor \(high) leaked into the child: \(listed)")
        XCTAssertFalse(listed.contains { $0 > 10 }, "unexpected descriptors: \(listed)")
    }

    func testAllowedFollowsThePolicy() {
        let policy = ManagedPolicy.normalize(["AllowedAIProviders": ["codex"]])
        let probes = OnboardingAgentProbes.production(
            config: ConfigService(configPath: dir.appendingPathComponent("config.yaml").path),
            policy: policy
        )
        XCTAssertFalse(probes.allowed(.claude))
        XCTAssertTrue(probes.allowed(.codex))
    }
}
