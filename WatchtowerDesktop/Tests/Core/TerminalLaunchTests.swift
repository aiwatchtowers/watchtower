import XCTest
@testable import WatchtowerCore

final class TerminalLaunchTests: XCTestCase {
    private let uuid = "3f2a1b4c-0000-4000-8000-000000000001"

    /// The prompt travels in the environment and the command names only the
    /// variable, so no prompt text is ever parsed by the shell.
    func testNewClaudeWithPromptPassesItThroughTheEnvironment() {
        let prompt = TerminalLaunch.workOnTargetPrompt(targetID: 42, vocabulary: .current)
        let l = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp/acme", mode: .newClaude(uuid: uuid, prompt: prompt))
        let command = "exec /bin/sh -c 'exec env -u WATCHTOWER_FIRST_PROMPT claude --session-id \(uuid) \"$WATCHTOWER_FIRST_PROMPT\"'"
        XCTAssertEqual(l.args, ["-l", "-c", command])
        XCTAssertEqual(l.environment, ["WATCHTOWER_FIRST_PROMPT=Work on target #42 using the watchtower-workbench skill."])
        XCTAssertEqual(l.currentDirectory, "/tmp/acme")
    }

    /// A hand-off (spec 2026-10-02 §9.5) is owner and model text: quotes,
    /// `$(…)`, several lines. None of it reaches the shell command.
    func testOwnerTextPromptNeverReachesTheShellCommand() {
        let prompt = "From a Watchtower code question:\nIt's $(rm -rf ~) `x` \"y\"\n- z"
        let l = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp/acme", mode: .newClaude(uuid: uuid, prompt: prompt), rowID: 3)
        let command = "exec /bin/sh -c 'exec env -u WATCHTOWER_FIRST_PROMPT claude --session-id \(uuid) \"$WATCHTOWER_FIRST_PROMPT\"'"
        XCTAssertEqual(l.args, ["-l", "-c", command])
        XCTAssertEqual(l.environment, ["WATCHTOWER_TERMINAL_SESSION_ID=3", "WATCHTOWER_FIRST_PROMPT=\(prompt)"])
    }

    /// Ruling R54(a): the variable is dropped (`env -u`) before `claude`
    /// runs, so nothing Claude Code starts inherits the prompt.
    func testThePromptVariableDoesNotReachClaudesChildren() {
        let l = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp", mode: .newClaude(uuid: uuid, prompt: "x"))
        XCTAssertEqual(l.args.last?.hasPrefix("exec /bin/sh -c 'exec env -u WATCHTOWER_FIRST_PROMPT claude "), true)
        let plain = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp", mode: .newClaude(uuid: uuid, prompt: nil))
        XCTAssertFalse(plain.args.joined().contains("env -u"), "no prompt, no variable")
    }

    /// Ruling R54(b): `claude --help` documents no `--` before the prompt, so
    /// a prompt starting with "-" is passed with a leading space — never a flag.
    func testAPromptStartingWithADashIsNeverAFlag() {
        let l = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp", mode: .newClaude(uuid: uuid, prompt: "--dangerously-skip-permissions"))
        XCTAssertEqual(l.environment, ["WATCHTOWER_FIRST_PROMPT= --dangerously-skip-permissions"])
        XCTAssertEqual(TerminalLaunch.positionalPrompt("-p x"), " -p x")
        XCTAssertEqual(TerminalLaunch.positionalPrompt("From a Watchtower code question:"), "From a Watchtower code question:")
        XCTAssertFalse(TerminalLaunch.positionalPrompt(HandoffText.header).hasPrefix("-"))
    }

    /// Board #361: the variable is read by `/bin/sh`, so a login shell
    /// with another `$VAR` syntax still hands the prompt over as one
    /// argument. Runs the command under `/bin/csh` — which refuses a
    /// multi-line `"$VAR"` ("Unmatched '"'.") — with a stub `claude` that
    /// prints its arguments; bounded, and reaped on timeout.
    func testThePromptReachesClaudeAsOneArgumentUnderCsh() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wt-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = dir.appendingPathComponent("claude")
        try "#!/bin/sh\nprintf '%s\\n' \"$#\" \"$3\"\nenv | grep -c WATCHTOWER_FIRST_PROMPT\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let prompt = "It's $(echo x) \"y\"\n- z"
        let l = TerminalLaunch.make(shell: "/bin/csh", folder: dir.path, mode: .newClaude(uuid: uuid, prompt: prompt))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: l.executable)
        process.arguments = l.args.filter { $0 != "-l" }  // csh takes -l only alone
        process.currentDirectoryURL = dir
        var env = ["PATH": "\(dir.path):/usr/bin:/bin"]
        for entry in l.environment {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            env[parts[0]] = parts[1]
        }
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + 10) == .timedOut {
            process.terminate()
            process.waitUntilExit()
            XCTFail("the launch did not finish")
        }
        let printed = String(bytes: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        XCTAssertEqual(printed, "3\n\(prompt)\n0\n", "--session-id, the id, then the prompt whole; the variable dropped")
    }

    func testNewClaudeWithoutPrompt() {
        let l = TerminalLaunch.make(shell: "/bin/bash", folder: "/tmp/acme dir", mode: .newClaude(uuid: uuid, prompt: nil))
        XCTAssertEqual(l.executable, "/bin/bash")
        XCTAssertEqual(l.args, ["-l", "-c", "exec claude --session-id \(uuid)"])
        XCTAssertEqual(l.currentDirectory, "/tmp/acme dir")
    }

    func testResume() {
        let l = TerminalLaunch.make(shell: nil, folder: "/tmp/acme", mode: .resumeClaude(uuid: uuid))
        XCTAssertEqual(l.executable, "/bin/zsh")
        XCTAssertEqual(l.args.last, "exec claude --resume \(uuid)")
    }

    /// A claude launch names its row for the project's SessionStart hook
    /// (board #160); a shell runs no hook and gets nothing.
    func testClaudeLaunchCarriesTheRowIDInItsEnvironment() {
        let env = ["\(TerminalLaunch.sessionRowEnv)=7"]
        XCTAssertEqual(TerminalLaunch.sessionRowEnv, "WATCHTOWER_TERMINAL_SESSION_ID", "Go terminalSessionEnv")
        XCTAssertEqual(TerminalLaunch.make(shell: nil, folder: "/tmp", mode: .newClaude(uuid: uuid, prompt: nil), rowID: 7).environment, env)
        XCTAssertEqual(TerminalLaunch.make(shell: nil, folder: "/tmp", mode: .resumeClaude(uuid: uuid), rowID: 7).environment, env)
        XCTAssertEqual(TerminalLaunch.make(shell: nil, folder: "/tmp", mode: .shell, rowID: 7).environment, [])
        XCTAssertEqual(TerminalLaunch.make(shell: nil, folder: "/tmp", mode: .resumeClaude(uuid: uuid)).environment, [])
    }

    func testShellIsPlainLoginShell() {
        XCTAssertEqual(TerminalLaunch.make(shell: "/bin/bash", folder: "/tmp", mode: .shell).args, ["-l"])
    }

    func testFirstRunKeepsTheSetupPrompt() {
        let prompt = TerminalLaunch.firstRunPrompt(.current)
        let l = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp/acme", mode: .newClaude(uuid: uuid, prompt: prompt))
        XCTAssertEqual(l.environment, ["\(TerminalLaunch.firstPromptEnv)=\(prompt)"])
    }

    func testSessionIDValidation() {
        XCTAssertTrue(TerminalLaunch.isValidSessionID(uuid))
        XCTAssertFalse(TerminalLaunch.isValidSessionID("3F2A1B4C-0000-4000-8000-000000000001"))
        XCTAssertFalse(TerminalLaunch.isValidSessionID("x; rm -rf ~"))
        XCTAssertFalse(TerminalLaunch.isValidSessionID("\(uuid)\n"))
        XCTAssertFalse(TerminalLaunch.isValidSessionID(""))
    }

    func testFixedPromptsHoldNoQuote() {
        for vocabulary in [WorkbenchVocabulary.current, .legacy] {
            XCTAssertFalse(TerminalLaunch.firstRunPrompt(vocabulary).contains("'"))
            XCTAssertFalse(TerminalLaunch.workOnTargetPrompt(targetID: 9_223_372_036_854_775_807, vocabulary: vocabulary).contains("'"))
            XCTAssertFalse(TerminalLaunch.workOnGroupPrompt(targetID: 9_223_372_036_854_775_807, vocabulary: vocabulary).contains("'"))
        }
    }

    /// A folder set up before the Workbench rename has only the old skill
    /// (spec 2026-10-02 §5.3); the prompts name what the folder has, and stay
    /// one line without control characters.
    func testPromptsNameTheFoldersSkill() {
        // The skill's "Working a target" / "Working a group" sections key on the
        // "Work on target #" / "Work on group #" prefixes: keep them in step with
        // internal/devpack/workbench_skill_tools_test.go TestWorkbenchSkill_ExplainsBothWorkOnPrompts.
        XCTAssertEqual(TerminalLaunch.firstRunPrompt(.current),
                       "Set up this Watchtower workbench using the watchtower-workbench skill.")
        XCTAssertEqual(TerminalLaunch.firstRunPrompt(.legacy),
                       "Set up this Watchtower workbench using the watchtower-project skill.")
        XCTAssertEqual(TerminalLaunch.workOnTargetPrompt(targetID: 7, vocabulary: .current),
                       "Work on target #7 using the watchtower-workbench skill.")
        XCTAssertEqual(TerminalLaunch.workOnTargetPrompt(targetID: 7, vocabulary: .legacy),
                       "Work on target #7 using the watchtower-project skill.")
        XCTAssertEqual(TerminalLaunch.workOnGroupPrompt(targetID: 7, vocabulary: .current),
                       "Work on group #7 using the watchtower-workbench skill.")
        XCTAssertEqual(TerminalLaunch.workOnGroupPrompt(targetID: 7, vocabulary: .legacy),
                       "Work on group #7 using the watchtower-project skill.")
        XCTAssertEqual(TerminalLaunch.workOnPrompt(targetID: 7, isGroup: true, vocabulary: .current),
                       TerminalLaunch.workOnGroupPrompt(targetID: 7, vocabulary: .current))
        XCTAssertEqual(TerminalLaunch.workOnPrompt(targetID: 7, isGroup: false, vocabulary: .current),
                       TerminalLaunch.workOnTargetPrompt(targetID: 7, vocabulary: .current))
        for vocabulary in [WorkbenchVocabulary.current, .legacy] {
            for prompt in [
                TerminalLaunch.firstRunPrompt(vocabulary),
                TerminalLaunch.workOnTargetPrompt(targetID: 7, vocabulary: vocabulary),
                TerminalLaunch.workOnGroupPrompt(targetID: 7, vocabulary: vocabulary)
            ] {
                XCTAssertFalse(prompt.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) })
            }
        }
    }

    func testMissingOrRelativeShellFallsBackToZsh() {
        XCTAssertEqual(TerminalLaunch.make(shell: nil, folder: "/tmp", mode: .shell).executable, "/bin/zsh")
        XCTAssertEqual(TerminalLaunch.make(shell: "", folder: "/tmp", mode: .shell).executable, "/bin/zsh")
        XCTAssertEqual(TerminalLaunch.make(shell: "zsh", folder: "/tmp", mode: .shell).executable, "/bin/zsh")
    }

    private let bin = "/opt/acme/claude"

    /// A pinned `claude_path` wins over the login PATH: the command execs
    /// the variable, its directory leads PATH, and `env -u` drops it before
    /// `claude` runs. The path itself never reaches a shell parser.
    func testAPinnedBinaryIsExecdThroughTheEnvironment() {
        let pathFix = "export PATH=\"${WATCHTOWER_CLAUDE_BIN%/*}:$PATH\"; "
        let new = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp", mode: .newClaude(uuid: uuid, prompt: nil), rowID: 7,
                                      claudeBinary: .pinned(bin))
        let newCommand = "exec /bin/sh -c '\(pathFix)exec env -u WATCHTOWER_CLAUDE_BIN \"$WATCHTOWER_CLAUDE_BIN\" --session-id \(uuid)'"
        XCTAssertEqual(new.args, ["-l", "-c", newCommand])
        XCTAssertEqual(new.environment, ["WATCHTOWER_TERMINAL_SESSION_ID=7", "WATCHTOWER_CLAUDE_BIN=\(bin)"])

        let prompted = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp", mode: .newClaude(uuid: uuid, prompt: "go"),
                                           claudeBinary: .pinned(bin))
        let unset = "-u WATCHTOWER_CLAUDE_BIN -u WATCHTOWER_FIRST_PROMPT"
        let promptedCommand =
            "exec /bin/sh -c '\(pathFix)exec env \(unset) \"$WATCHTOWER_CLAUDE_BIN\" --session-id \(uuid) \"$WATCHTOWER_FIRST_PROMPT\"'"
        XCTAssertEqual(prompted.args.last, promptedCommand)
        XCTAssertEqual(prompted.environment, ["WATCHTOWER_CLAUDE_BIN=\(bin)", "WATCHTOWER_FIRST_PROMPT=go"])

        let resume = TerminalLaunch.make(shell: nil, folder: "/tmp", mode: .resumeClaude(uuid: uuid), claudeBinary: .pinned(bin))
        let resumeCommand = "exec /bin/sh -c '\(pathFix)exec env -u WATCHTOWER_CLAUDE_BIN \"$WATCHTOWER_CLAUDE_BIN\" --resume \(uuid)'"
        XCTAssertEqual(resume.args.last, resumeCommand)

        for launch in [new, prompted, resume] {
            XCTAssertFalse(launch.args.joined().contains(bin), "the path never reaches a shell parser")
        }
    }

    /// A binary only found in a well-known dir is a fallback: the owner's
    /// login PATH picks `claude` first, and the found directory is appended
    /// only when that PATH has none.
    func testAFoundBinaryIsOnlyAFallbackForTheLoginPath() {
        let fallback = "command -v claude >/dev/null 2>&1 || export PATH=\"$PATH:${WATCHTOWER_CLAUDE_BIN%/*}\"; "
        let resume = TerminalLaunch.make(shell: nil, folder: "/tmp", mode: .resumeClaude(uuid: uuid), claudeBinary: .fallback(bin))
        XCTAssertEqual(resume.args.last, "exec /bin/sh -c '\(fallback)exec env -u WATCHTOWER_CLAUDE_BIN claude --resume \(uuid)'")
        XCTAssertEqual(resume.environment, ["WATCHTOWER_CLAUDE_BIN=\(bin)"])
        let prompted = TerminalLaunch.make(shell: nil, folder: "/tmp", mode: .newClaude(uuid: uuid, prompt: "go"), claudeBinary: .fallback(bin))
        let unset = "-u WATCHTOWER_CLAUDE_BIN -u WATCHTOWER_FIRST_PROMPT"
        XCTAssertEqual(prompted.args.last,
                       "exec /bin/sh -c '\(fallback)exec env \(unset) claude --session-id \(uuid) \"$WATCHTOWER_FIRST_PROMPT\"'")
    }

    func testAShellIgnoresTheResolvedBinary() {
        let l = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp", mode: .shell, rowID: 7, claudeBinary: .pinned(bin))
        XCTAssertEqual(l.args, ["-l"])
        XCTAssertEqual(l.environment, [])
    }

    /// Review Focus 2 and 3, and the owner's PATH first: under zsh and csh,
    /// a found binary in a directory with a space, a quote and `$` runs when
    /// the login PATH has no `claude`, the owner's own `claude` runs when it
    /// has one, and a pinned binary runs either way; the variable never
    /// reaches `claude`. The test drops `-l` (no owner profile in a test);
    /// csh/tcsh refuse `-l` together with `-c`, a limit that predates this
    /// change (v1 limits in docs/features/workbench.md). Bounded, reaped.
    func testTheResolvedBinaryRunsUnderZshAndCshWithoutOverridingTheOwnersPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wt-bin-\(UUID().uuidString)")
        let found = root.appendingPathComponent("my 'odd' $dir")
        let owners = root.appendingPathComponent("owner")
        for (dir, tag) in [(found, "found"), (owners, "owner")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stub = dir.appendingPathComponent("claude")
            try "#!/bin/sh\nprintf '%s\\n' \(tag) \"$#\" \"$1\"\nenv | grep -c WATCHTOWER_CLAUDE_BIN\n"
                .write(to: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = found.appendingPathComponent("claude").path
        let cases: [(ClaudeBinary, String, String)] = [
            (.fallback(stub), "/usr/bin:/bin", "found"),
            (.fallback(stub), "\(owners.path):/usr/bin:/bin", "owner"),
            (.pinned(stub), "\(owners.path):/usr/bin:/bin", "found")
        ]
        for shell in ["/bin/zsh", "/bin/csh"] {
            for (binary, path, expected) in cases {
                let l = TerminalLaunch.make(shell: shell, folder: root.path, mode: .resumeClaude(uuid: uuid), claudeBinary: binary)
                let printed = try run(l, path: path)
                XCTAssertEqual(printed, "\(expected)\n2\n--resume\n0\n", "\(shell) \(binary) PATH=\(path)")
            }
        }
    }

    /// Runs `launch` without `-l`, with `path` as PATH; its stdout. HOME and
    /// ZDOTDIR point at the launch folder, so the developer's `~/.zshenv` or
    /// `~/.cshrc` cannot put a real `claude` on PATH. Bounded, reaped.
    private func run(_ launch: TerminalLaunch, path: String) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.args.filter { $0 != "-l" }
        process.currentDirectoryURL = URL(fileURLWithPath: launch.currentDirectory)
        var env = ["PATH": path, "HOME": launch.currentDirectory, "ZDOTDIR": launch.currentDirectory]
        for entry in launch.environment {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            env[parts[0]] = parts[1]
        }
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + 10) == .timedOut {
            process.terminate()
            process.waitUntilExit()
            XCTFail("the launch did not finish")
        }
        return String(bytes: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    /// Review Focus 4: a shell's 127 is the owner's last command, not a
    /// missing `claude`.
    func testOnlyAClaudeSessionsExit127OffersThePathFix() {
        XCTAssertTrue(TerminalLaunch.offersClaudePathFix(code: 127, isClaude: true))
        XCTAssertFalse(TerminalLaunch.offersClaudePathFix(code: 127, isClaude: false))
        XCTAssertFalse(TerminalLaunch.offersClaudePathFix(code: 1, isClaude: true))
        XCTAssertFalse(TerminalLaunch.offersClaudePathFix(code: nil, isClaude: true))
    }

    func testExitMessageNamesAMissingClaudeForCommandNotFound() {
        XCTAssertEqual(TerminalLaunch.exitMessage(code: 127),
                       "Claude Code was not found. Set its path, or add it to your login shell's PATH, then Restart.")
        XCTAssertEqual(TerminalLaunch.exitMessage(code: 1), "Claude Code exited (code 1).")
        XCTAssertEqual(TerminalLaunch.exitMessage(code: nil), "Claude Code exited.")
    }
}
