import XCTest
@testable import WatchtowerCore

/// Spec 2026-10-12 §7 (board #399): the Codex launch, built from
/// `launch-args`, and the Claude argv pinned byte for byte.
final class TerminalLaunchCodexTests: XCTestCase {
    private let uuid = "3f2a1b4c-0000-4000-8000-000000000001"
    /// A canonical UUIDv7, the shape Codex mints.
    private let codexID = "0199d1c2-7a3b-7c4d-8e5f-0a1b2c3d4e5f"
    /// Raw argv elements as `launch-args` prints them: TOML with quotes, a
    /// single-quoted binary inside a hook command, a space, a `$`.
    private let rawArgs = [
        "--no-daemon", "-c", "check_for_update_on_startup=false",
        "-c", #"mcp_servers.watchtower-workbench.args=["mcp","--workbench","7","--agent","codex"]"#,
        "-c", #"hooks.SessionStart=[{hooks=[{type="command",command="'/Users/example/Application Support/watchtower' "#
            + #"workbench brief --agent codex",timeout=10}]}]"#,
        "-c", "x=$HOME `id` it's"
    ]

    private func args(binary: String = "/Users/example/.nvm/bin/codex", pathPrepend: String = "/Users/example/.nvm/bin")
        -> CodexLaunchArgs {
        CodexLaunchArgs(binary: binary, pathPrepend: pathPrepend, args: rawArgs)
    }

    // MARK: - Claude, unchanged

    /// Every Claude mode, byte for byte as before #399.
    func testClaudeArgvGoldenUnchanged() {
        let new = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp/acme", mode: .newClaude(uuid: uuid, prompt: nil), rowID: 4)
        XCTAssertEqual(new.args, ["-l", "-c", "exec claude --session-id \(uuid)"])
        XCTAssertEqual(new.environment, ["WATCHTOWER_TERMINAL_SESSION_ID=4"])
        let prompted = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp/acme", mode: .newClaude(uuid: uuid, prompt: "-x"), rowID: 4)
        XCTAssertEqual(prompted.args, ["-l", "-c", "exec /bin/sh -c 'exec env -u WATCHTOWER_FIRST_PROMPT claude --session-id "
            + "\(uuid) \"$WATCHTOWER_FIRST_PROMPT\"'"])
        XCTAssertEqual(prompted.environment, ["WATCHTOWER_TERMINAL_SESSION_ID=4", "WATCHTOWER_FIRST_PROMPT= -x"])
        let resumed = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp/acme", mode: .resumeClaude(uuid: uuid), rowID: 4)
        XCTAssertEqual(resumed.args, ["-l", "-c", "exec claude --resume \(uuid)"])
        XCTAssertEqual(resumed.environment, ["WATCHTOWER_TERMINAL_SESSION_ID=4"])
        XCTAssertEqual(TerminalLaunch.Mode.newClaude(uuid: uuid, prompt: nil), .newAgent(.claude, sessionID: uuid, prompt: nil))
        XCTAssertEqual(TerminalLaunch.Mode.resumeClaude(uuid: uuid), .resumeAgent(.claude, sessionID: uuid))
    }

    // MARK: - Codex argv

    func testCodexNewArgvQuotesEveryArg() throws {
        let l = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp", mode: .newAgent(.codex, sessionID: nil, prompt: nil),
                                    rowID: 9, codex: args())
        let quoted = rawArgs.map { "'" + $0.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }.joined(separator: " ")
        let script = #"PATH='/Users/example/.nvm/bin':"$PATH" exec env -u WATCHTOWER_FIRST_PROMPT '/Users/example/.nvm/bin/codex' "#
            + quoted
        XCTAssertEqual(l.args, ["-l", "-c", "exec /bin/sh -c " + TerminalLaunch.shellQuote(script)])
        XCTAssertEqual(l.environment, ["WATCHTOWER_TERMINAL_SESSION_ID=9"])
        XCTAssertEqual(try run(.newAgent(.codex, sessionID: nil, prompt: nil)).argv, rawArgs,
                       "every element arrives whole, nothing appended")
    }

    /// `resume '<id>'` follows the launch args, and nothing follows it: a
    /// `-c` after the subcommand would drop the hooks and the MCP server.
    func testCodexResumeArgv() throws {
        let l = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp", mode: .resumeAgent(.codex, sessionID: codexID),
                                    rowID: 9, codex: args())
        XCTAssertTrue(l.args[2].hasSuffix(#" resume '\''"# + codexID + #"'\'''"#), l.args[2])
        XCTAssertEqual(try run(.resumeAgent(.codex, sessionID: codexID)).argv, rawArgs + ["resume", codexID],
                       "nothing follows resume <id>")
        XCTAssertEqual(l.environment, ["WATCHTOWER_TERMINAL_SESSION_ID=9"], "a resume carries no prompt")
    }

    func testCodexPromptViaEnvNotArgv() throws {
        let prompt = "Work on target #4.\nIt's $(rm -rf ~) `x` \"y\""
        let l = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp", mode: .newAgent(.codex, sessionID: nil, prompt: prompt),
                                    rowID: 9, codex: args())
        XCTAssertFalse(l.args.joined().contains("rm -rf"), "no prompt text in the command")
        XCTAssertTrue(l.args[2].contains(#"-- "$WATCHTOWER_FIRST_PROMPT""#))
        XCTAssertEqual(l.environment, ["WATCHTOWER_TERMINAL_SESSION_ID=9", "WATCHTOWER_FIRST_PROMPT=\(prompt)"])
        let result = try run(.newAgent(.codex, sessionID: nil, prompt: prompt))
        XCTAssertEqual(result.argv, rawArgs + ["--", prompt])
        XCTAssertFalse(result.promptVisible, "env -u drops the variable before codex runs")
    }

    /// `--` goes before the prompt, so one starting with "-" is no flag;
    /// the prompt itself is passed as written.
    func testCodexLeadingDashPromptGuarded() throws {
        let prompt = "--dangerously-bypass-approvals-and-sandbox"
        let l = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp", mode: .newAgent(.codex, sessionID: nil, prompt: prompt),
                                    codex: args())
        XCTAssertEqual(l.environment, ["WATCHTOWER_FIRST_PROMPT=\(prompt)"])
        XCTAssertEqual(try run(.newAgent(.codex, sessionID: nil, prompt: prompt)).argv, rawArgs + ["--", prompt])
    }

    func testCodexPathPrependedBeforePATH() throws {
        let launched = try run(.newAgent(.codex, sessionID: nil, prompt: nil), pathPrepend: "/Users/example/it's node/bin")
        XCTAssertEqual(launched.path, "/Users/example/it's node/bin:/usr/bin:/bin")
        let bare = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp", mode: .newAgent(.codex, sessionID: nil, prompt: nil),
                                       codex: args(pathPrepend: ""))
        XCTAssertFalse(bare.args[2].contains("PATH="), "no prefix, PATH untouched")
        XCTAssertEqual(try run(.newAgent(.codex, sessionID: nil, prompt: nil), pathPrepend: "").path, "/usr/bin:/bin")
    }

    /// The same command under csh, whose quoting differs from sh's.
    func testCodexLaunchUnderCsh() throws {
        XCTAssertEqual(try run(.newAgent(.codex, sessionID: nil, prompt: "-p x"), shell: "/bin/csh").argv,
                       rawArgs + ["--", "-p x"])
    }

    /// No launch args, no binary: the launch exits 127, the "not found" line.
    func testCodexWithoutLaunchArgsExits127() {
        let l = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp", mode: .newAgent(.codex, sessionID: nil, prompt: nil))
        XCTAssertEqual(l.args, ["-l", "-c", "exit 127"])
    }

    // MARK: - Ids and messages

    func testUUIDv7Accepted() {
        XCTAssertTrue(TerminalLaunch.isValidSessionID(codexID))
        XCTAssertTrue(TerminalLaunch.isValidSessionID(uuid))
    }

    func testUppercaseOrNonUUIDRejected() {
        XCTAssertFalse(TerminalLaunch.isValidSessionID(codexID.uppercased()))
        XCTAssertFalse(TerminalLaunch.isValidSessionID("0199d1c2-7a3b-7c4d-8e5f-0a1b2c3d4e5"))
        XCTAssertFalse(TerminalLaunch.isValidSessionID("0199d1c2-7a3b-7c4d-8e5f-0a1b2c3d4e5f'"))
        XCTAssertFalse(TerminalLaunch.isValidSessionID("0199d1c27a3b7c4d8e5f0a1b2c3d4e5f0000"))
        XCTAssertFalse(TerminalLaunch.isValidSessionID("019g d1c2-7a3b-7c4d-8e5f-0a1b2c3d4e5f"))
    }

    func testExitMessagesNameTheAgent() {
        XCTAssertEqual(TerminalLaunch.exitMessage(code: 127, agent: .codex),
                       "Codex was not found. Install it, or set codex_path in Watchtower's config, then try again.")
        XCTAssertEqual(TerminalLaunch.exitMessage(code: 2, agent: .codex), "Codex exited (code 2).")
        XCTAssertEqual(TerminalLaunch.exitMessage(code: nil, agent: .codex), "Codex exited.")
        XCTAssertEqual(TerminalLaunch.exitMessage(code: 127, agent: .claude), TerminalLaunch.exitMessage(code: 127))
        XCTAssertEqual(TerminalLaunch.exitMessage(code: 127),
                       "Claude Code was not found on your login-shell PATH. Install it, or add it to PATH, then Restart.")
    }

    func testLaunchArgsDecode() throws {
        let json = #"{"binary":"/opt/codex","path_prepend":"/opt","args":["--no-daemon","-c","a=b"]}"#
        XCTAssertEqual(try JSONDecoder().decode(CodexLaunchArgs.self, from: Data(json.utf8)),
                       CodexLaunchArgs(binary: "/opt/codex", pathPrepend: "/opt", args: ["--no-daemon", "-c", "a=b"]))
        XCTAssertThrowsError(try JSONDecoder().decode(CodexLaunchArgs.self, from: Data(#"{"error":"codex_not_found"}"#.utf8)))
    }

    // MARK: - Running the command

    private struct Run {
        let argv: [String]
        let path: String
        let promptVisible: Bool
    }

    /// Runs `mode`'s shell command (without `-l`, so no profile) with a stub
    /// `codex` as the binary that prints its PATH, whether the prompt
    /// variable reached it, then its arguments NUL-separated. Bounded.
    private func run(
        _ mode: TerminalLaunch.Mode, shell: String = "/bin/sh", pathPrepend: String = "/Users/example/.nvm/bin"
    ) throws -> Run {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wt codex launch \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = dir.appendingPathComponent("codex")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$PATH\"\nenv | grep -c WATCHTOWER_FIRST_PROMPT\nprintf '%s\\0' \"$@\"\n"
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let launch = TerminalLaunch.make(shell: shell, folder: dir.path, mode: mode,
                                         codex: args(binary: stub.path, pathPrepend: pathPrepend))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.args.filter { $0 != "-l" }  // csh takes -l only alone
        process.currentDirectoryURL = dir
        var env = ["PATH": "/usr/bin:/bin"]
        for entry in launch.environment {
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            env[parts[0]] = parts[1]
        }
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        if exited.wait(timeout: .now() + 10) == .timedOut {
            process.terminate()
            process.waitUntilExit()
            XCTFail("the launch did not finish")
        }
        return try parse(data)
    }

    private func parse(_ data: Data) throws -> Run {
        let text = try XCTUnwrap(String(bytes: data, encoding: .utf8))
        let lines = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard lines.count == 3 else {
            XCTFail("unexpected output: \(text)")
            return Run(argv: [], path: "", promptVisible: true)
        }
        let argv = lines[2].split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
        return Run(argv: argv, path: lines[0], promptVisible: lines[1] != "0")
    }
}
