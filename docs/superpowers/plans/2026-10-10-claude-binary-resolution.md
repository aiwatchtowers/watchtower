# Claude Binary Resolution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every place Watchtower launches `claude` finds the same binary, even when the owner's `PATH` export lives only in `~/.zshrc`.

**Architecture:** A Swift resolver `Constants.claudeBinary()` (config `claude_path` → `findInPath`) mirrors Go `claude.FindBinary`. The embedded terminal passes the resolved path in an environment variable and execs it through `/bin/sh`. Exit 127 offers an in-place path picker. `resolvedEnvironment()` gains the well-known dirs, and Go `integrate` switches to `claude.FindBinary`.

**Tech Stack:** Swift 5.10 mode (WatchtowerCore + Desktop app target, XCTest), Go 1.25 (cobra `cmd/`).

**Spec:** `docs/superpowers/specs/2026-10-10-claude-binary-resolution-design.md`

## Global Constraints

- No `-i` (interactive) shells anywhere; the login shell (`-l`) stays the first process of a terminal session.
- Never edit the owner's shell files.
- The binary path never appears in a shell command string; it travels only in the environment (`WATCHTOWER_CLAUDE_BIN`).
- With no resolved binary, the terminal command is byte-for-byte today's (existing `TerminalLaunchTests` stay green unchanged).
- Dual path: Swift `Constants.claudeBinary()` ↔ Go `claude.FindBinary`; each carries a comment naming the other.
- Inner loop only per task: `make test-swift FILTER=<Class>`, `go test ./cmd -run <Name>`, `make lint-diff`. The full gate runs once at the end.
- Tests that spawn processes bound them and reap them on timeout.
- Public repo: no real paths, ids or names in tests and docs (`/opt/acme/claude`, temp dirs).

## Review Focus

1. A `claude_path` pointing to a directory, a deleted file or a non-executable file must fall through to `findInPath`, not launch it → Task 1 test.
2. A binary path with a space, a single quote and `$` must reach `exec` intact → Task 2 real-`/bin/sh` test.
3. A non-POSIX login shell (`/bin/csh`) with a resolved binary must still launch it → Task 2 runs the real test under both zsh and csh.
4. A plain shell session that exits 127 must not offer "Set Claude Path…" (that 127 is the owner's last command, not a missing `claude`) → Task 3 `offersClaudePathFix` test.
5. After the owner sets a path, Restart must use it without an app restart (the resolver is not cached) → Task 2 `TerminalCenterTests` test with a changing seam.

---

### Task 1: Swift resolver and well-known dirs in `resolvedEnvironment`

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Utilities/Constants.swift` (next to `findInPath`, and the `resolvedEnvironment()` cache closure)
- Test: `WatchtowerDesktop/Tests/Core/ConstantsClaudeBinaryTests.swift` (create)

**Interfaces:**
- Produces:
  - `package nonisolated static func claudePathOverride(configPath: String = Constants.configPath) -> String?`
  - `package nonisolated static func claudeBinary(configPath: String = Constants.configPath) -> String?`
  - `package nonisolated static func appendingWellKnownDirs(to path: String, home: String, claudePath: String?, isDirectory: (String) -> Bool) -> String`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import WatchtowerCore

final class ConstantsClaudeBinaryTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("wt-claude-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func config(_ claudePath: String) throws -> String {
        let path = dir.appendingPathComponent("config.yaml").path
        try "active_workspace: acme\nclaude_path: '\(claudePath)'\n".write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func executable(_ name: String) throws -> String {
        let path = dir.appendingPathComponent(name).path
        try "#!/bin/sh\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    func testAnExecutableOverrideWins() throws {
        let bin = try executable("claude")
        XCTAssertEqual(Constants.claudeBinary(configPath: try config(bin)), bin)
    }

    /// Review Focus 1: a directory, a missing file or a non-executable file
    /// is never launched; the lookup falls through to `findInPath`.
    func testAnUnusableOverrideFallsThrough() throws {
        let plain = dir.appendingPathComponent("plain").path
        try "x".write(toFile: plain, atomically: true, encoding: .utf8)
        for override in [dir.path, dir.appendingPathComponent("gone").path, plain] {
            let configPath = try config(override)
            XCTAssertNil(Constants.claudePathOverride(configPath: configPath), override)
            XCTAssertEqual(Constants.claudeBinary(configPath: configPath), Constants.findInPath("claude"), override)
        }
    }

    func testNoConfigFallsThrough() {
        let missing = dir.appendingPathComponent("none.yaml").path
        XCTAssertNil(Constants.claudePathOverride(configPath: missing))
        XCTAssertEqual(Constants.claudeBinary(configPath: missing), Constants.findInPath("claude"))
    }

    /// Go `fallbackPATH` mirrored: the owner's order first, missing
    /// well-known dirs appended, nothing duplicated, absent dirs skipped.
    func testWellKnownDirsAreAppendedOnce() {
        let present: Set<String> = ["/h/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/opt/acme"]
        let merged = Constants.appendingWellKnownDirs(
            to: "/usr/bin:/opt/homebrew/bin", home: "/h", claudePath: "/opt/acme/claude",
            isDirectory: { present.contains($0) }
        )
        XCTAssertEqual(merged, "/usr/bin:/opt/homebrew/bin:/h/.local/bin:/usr/local/bin:/opt/acme")
    }

    func testAnEmptyPathGetsJustTheWellKnownDirs() {
        let merged = Constants.appendingWellKnownDirs(to: "", home: "/h", claudePath: nil, isDirectory: { $0 == "/h/.local/bin" })
        XCTAssertEqual(merged, "/h/.local/bin")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `make test-swift FILTER=ConstantsClaudeBinaryTests`
Expected: compile failure — `claudeBinary`, `claudePathOverride`, `appendingWellKnownDirs` not found.

- [ ] **Step 3: Implement**

In `Constants.swift`, directly above `findInPath`:

```swift
    /// `claude_path` from config.yaml when it names an executable file (not a
    /// directory) — the override step of `claudeBinary()`.
    package nonisolated static func claudePathOverride(configPath: String = Constants.configPath) -> String? {
        guard let data = FileManager.default.contents(atPath: configPath),
              let str = String(data: data, encoding: .utf8),
              let yaml = try? Yams.load(yaml: str) as? [String: Any],
              let path = yaml["claude_path"] as? String, !path.isEmpty else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    /// The `claude` binary a launch runs: the configured `claude_path`, else
    /// the well-known dirs and `PATH` (`findInPath`); nil when none. The Swift
    /// twin of Go `claude.FindBinary` (a dual path). Not cached: the owner may
    /// set the path or install Claude Code while the app runs.
    package nonisolated static func claudeBinary(configPath: String = Constants.configPath) -> String? {
        claudePathOverride(configPath: configPath) ?? findInPath("claude")
    }

    /// `path` with the well-known install dirs (and `claudePath`'s directory)
    /// appended when they exist and are missing — Go `fallbackPATH` mirrored.
    /// A login shell's `PATH` misses an export that lives only in `.zshrc`.
    package nonisolated static func appendingWellKnownDirs(
        to path: String, home: String, claudePath: String?, isDirectory: (String) -> Bool
    ) -> String {
        var parts = path.split(separator: ":").map(String.init)
        var candidates = ["\(home)/.local/bin", "\(home)/.claude/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.volta/bin"]
        if let claudePath { candidates.append((claudePath as NSString).deletingLastPathComponent) }
        for dir in candidates where !parts.contains(dir) && isDirectory(dir) {
            parts.append(dir)
        }
        return parts.joined(separator: ":")
    }
```

In `resolvedEnvironment()`'s `Cache.env` closure, right before `return env` (after the nvm/fnm loop):

```swift
                env["PATH"] = Constants.appendingWellKnownDirs(
                    to: env["PATH"] ?? "", home: NSHomeDirectory(), claudePath: Constants.claudePathOverride(),
                    isDirectory: { dir in
                        var isDirectory: ObjCBool = false
                        return FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory) && isDirectory.boolValue
                    }
                )
```

If the compiler refuses calling `Constants` from the nested `Cache` (the existing comment there says it once could not), move the two helpers' bodies into file-private free functions and have the `Constants` methods forward to them; keep the public names above.

Add to the comment on Go `FindBinary` in `internal/claude/resolve.go` one line: `// Swift twin: Constants.claudeBinary() (WatchtowerCore).`

- [ ] **Step 4: Run to verify they pass**

Run: `make test-swift FILTER=ConstantsClaudeBinaryTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Utilities/Constants.swift WatchtowerDesktop/Tests/Core/ConstantsClaudeBinaryTests.swift internal/claude/resolve.go
git commit -m "feat(desktop): one claude binary resolver, well-known dirs in the resolved PATH"
```

---

### Task 2: Terminal launches the resolved binary

**Depends on:** Task 1.

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/TerminalLaunch.swift` (`make`, new `claudeBinaryEnv`, new `claudeCommand`, `exitMessage`)
- Modify: `WatchtowerDesktop/Sources/Services/TerminalCenter.swift:136` (new seam) and `:648` (pass it)
- Modify: `docs/features/workbench.md` (one paragraph in the embedded terminal part)
- Test: `WatchtowerDesktop/Tests/Core/TerminalLaunchTests.swift`, `WatchtowerDesktop/Tests/TerminalCenterTests.swift`

**Interfaces:**
- Consumes: `Constants.claudeBinary() -> String?` (Task 1).
- Produces:
  - `TerminalLaunch.claudeBinaryEnv == "WATCHTOWER_CLAUDE_BIN"`
  - `TerminalLaunch.make(shell: String?, folder: String, mode: Mode, rowID: Int64? = nil, claudeBinary: String? = nil) -> TerminalLaunch`
  - `TerminalCenter.claudeBinary: () -> String?` (seam, default `{ Constants.claudeBinary() }`)

- [ ] **Step 1: Write the failing tests**

Append to `TerminalLaunchTests`:

```swift
    private let bin = "/opt/acme/claude"

    /// The resolved binary travels in the environment; the command names
    /// only the variable, prepends its directory to PATH and drops it
    /// before `claude` runs.
    func testAResolvedBinaryRunsThroughTheEnvironment() {
        let pathFix = "export PATH=\"$(dirname \"$WATCHTOWER_CLAUDE_BIN\")\":\"$PATH\"; "
        let new = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp", mode: .newClaude(uuid: uuid, prompt: nil), rowID: 7, claudeBinary: bin)
        XCTAssertEqual(new.args, ["-l", "-c",
            "exec /bin/sh -c '\(pathFix)exec env -u WATCHTOWER_CLAUDE_BIN \"$WATCHTOWER_CLAUDE_BIN\" --session-id \(uuid)'"])
        XCTAssertEqual(new.environment, ["WATCHTOWER_TERMINAL_SESSION_ID=7", "WATCHTOWER_CLAUDE_BIN=\(bin)"])

        let prompted = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp", mode: .newClaude(uuid: uuid, prompt: "go"), claudeBinary: bin)
        XCTAssertEqual(prompted.args.last,
            "exec /bin/sh -c '\(pathFix)exec env -u WATCHTOWER_CLAUDE_BIN -u WATCHTOWER_FIRST_PROMPT \"$WATCHTOWER_CLAUDE_BIN\" --session-id \(uuid) \"$WATCHTOWER_FIRST_PROMPT\"'")
        XCTAssertEqual(prompted.environment, ["WATCHTOWER_CLAUDE_BIN=\(bin)", "WATCHTOWER_FIRST_PROMPT=go"])

        let resume = TerminalLaunch.make(shell: nil, folder: "/tmp", mode: .resumeClaude(uuid: uuid), claudeBinary: bin)
        XCTAssertEqual(resume.args.last,
            "exec /bin/sh -c '\(pathFix)exec env -u WATCHTOWER_CLAUDE_BIN \"$WATCHTOWER_CLAUDE_BIN\" --resume \(uuid)'")

        for launch in [new, prompted, resume] {
            XCTAssertFalse(launch.args.joined().contains(bin), "the path never reaches a shell parser")
        }
    }

    func testAShellIgnoresTheResolvedBinary() {
        let l = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp", mode: .shell, rowID: 7, claudeBinary: bin)
        XCTAssertEqual(l.args, ["-l"])
        XCTAssertEqual(l.environment, [])
    }

    /// Review Focus 2 and 3: a path with a space, a quote and `$`, in a
    /// directory not on PATH, is exec'd intact under zsh and csh; its
    /// directory leads PATH and the variable is dropped. Bounded, reaped.
    func testAResolvedBinaryWithAnAwkwardPathRunsUnderZshAndCsh() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wt-bin-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("my 'odd' $dir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = dir.appendingPathComponent("claude")
        try "#!/bin/sh\nprintf '%s\\n' \"$#\" \"$1\" \"${PATH%%:*}\"\nenv | grep -c WATCHTOWER_CLAUDE_BIN\n"
            .write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        for shell in ["/bin/zsh", "/bin/csh"] {
            let l = TerminalLaunch.make(shell: shell, folder: root.path, mode: .resumeClaude(uuid: uuid), claudeBinary: stub.path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: l.executable)
            process.arguments = l.args.filter { $0 != "-l" }  // no owner profile in a test; csh takes -l only alone
            process.currentDirectoryURL = root
            var env = ["PATH": "/usr/bin:/bin"]
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
                XCTFail("\(shell): the launch did not finish")
            }
            let printed = String(bytes: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            XCTAssertEqual(printed, "2\n--resume\n\(dir.path)\n0\n", shell)
        }
    }
```

Replace the 127 assertion in the existing exit-message test (`TerminalLaunchTests.swift:176`):

```swift
        XCTAssertEqual(TerminalLaunch.exitMessage(code: 127),
                       "Claude Code was not found. Set its path, or add it to your login shell's PATH, then Restart.")
```

In `TerminalCenterTests.makeCenter`, after `center.shell = { "/bin/zsh" }`, add `center.claudeBinary = { nil }` (keeps every existing argv assertion machine-independent). Then add:

```swift
    /// Review Focus 5: the binary is resolved per launch, so a path set
    /// after an exit-127 reaches the next start without an app restart.
    func testEachLaunchResolvesTheClaudeBinaryAgain() throws {
        let center = makeCenter()
        var resolved: String?
        center.claudeBinary = { resolved }
        let s = try session()
        center.start(s, fresh: true, prompt: nil)
        XCTAssertFalse(try XCTUnwrap(sessions.last?.launches.last).environment.contains { $0.hasPrefix("WATCHTOWER_CLAUDE_BIN=") })
        sessions.last?.exit(127)
        resolved = "/opt/acme/claude"
        center.start(s, fresh: false, prompt: nil)
        XCTAssertTrue(try XCTUnwrap(sessions.last?.launches.last).environment.contains("WATCHTOWER_CLAUDE_BIN=/opt/acme/claude"))
    }
```

Use the file's existing helper that inserts a Claude session row (the one the `start(s, fresh:…)` tests at lines 130–165 use) in place of `session()`; match its name and arguments exactly.

- [ ] **Step 2: Run to verify they fail**

Run: `make test-swift FILTER='TerminalLaunchTests|TerminalCenterTests'`
Expected: compile failure — no `claudeBinary:` parameter, no `claudeBinary` seam.

- [ ] **Step 3: Implement**

In `TerminalLaunch`, next to `firstPromptEnv`:

```swift
    /// The resolved `claude` binary (`Constants.claudeBinary()`), read by
    /// `/bin/sh` like `firstPromptEnv`, so the path is never parsed by a
    /// shell and a login `PATH` without it (an export only in `.zshrc`) still
    /// launches it (spec 2026-10-10).
    package static let claudeBinaryEnv = "WATCHTOWER_CLAUDE_BIN"
```

Change `make`'s signature and the two Claude cases:

```swift
    package static func make(shell: String?, folder: String, mode: Mode, rowID: Int64? = nil,
                             claudeBinary: String? = nil) -> Self {
        let executable = shell.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? fallbackShell
        let args: [String]
        switch mode {
        case let .newClaude(uuid, prompt):
            args = ["-l", "-c", claudeCommand("--session-id \(uuid)", resolved: claudeBinary != nil, withPrompt: prompt != nil)]
        case let .resumeClaude(uuid):
            args = ["-l", "-c", claudeCommand("--resume \(uuid)", resolved: claudeBinary != nil, withPrompt: false)]
        case .shell:
            args = ["-l"]
        }
        var launch = Self(executable: executable, args: args, currentDirectory: folder)
        if let rowID, mode != .shell {
            launch.environment = ["\(sessionRowEnv)=\(rowID)"]
        }
        if let claudeBinary, mode != .shell {
            launch.environment.append("\(claudeBinaryEnv)=\(claudeBinary)")
        }
        if case let .newClaude(_, prompt?) = mode {
            launch.environment.append("\(firstPromptEnv)=\(positionalPrompt(prompt))")
        }
        return launch
    }

    /// The login shell's command for `claude <tail>`. Bare `exec claude`
    /// when nothing travels in the environment; otherwise `/bin/sh` reads
    /// the variables (the login shell only runs a single-quoted literal, so
    /// one whose `$VAR` is not POSIX — nushell's `$env.VAR` — or that
    /// quotes differently — csh — still works) and `env -u` drops them
    /// before `claude` runs, so its children never see them. A resolved
    /// binary's directory leads `PATH`, so a hook running `claude` by name
    /// finds the same one.
    private static func claudeCommand(_ tail: String, resolved: Bool, withPrompt: Bool) -> String {
        guard resolved || withPrompt else { return "exec claude \(tail)" }
        var unset = resolved ? ["-u \(claudeBinaryEnv)"] : []
        if withPrompt { unset.append("-u \(firstPromptEnv)") }
        let pathFix = resolved ? "export PATH=\"$(dirname \"$\(claudeBinaryEnv)\")\":\"$PATH\"; " : ""
        let binary = resolved ? "\"$\(claudeBinaryEnv)\"" : "claude"
        let prompt = withPrompt ? " \"$\(firstPromptEnv)\"" : ""
        return "exec /bin/sh -c '\(pathFix)exec env \(unset.joined(separator: " ")) \(binary) \(tail)\(prompt)'"
    }
```

Remove the now-duplicated `env -u` comment lines inside the old `.newClaude` case and update the type's doc comment at the top of the file to mention the resolved binary in one clause.

`exitMessage` 127 case:

```swift
        case 127?:
            "Claude Code was not found. Set its path, or add it to your login shell's PATH, then Restart."
```

and its doc comment: "127 is the shell's "command not found": no `claude` was resolved and the login shell's PATH has none."

In `TerminalCenter`, after the `shell` seam (line 136):

```swift
    /// The `claude` binary of a launch, resolved per start so a path set
    /// after an exit-127 applies on Restart. A seam for tests.
    @ObservationIgnored var claudeBinary: () -> String? = { Constants.claudeBinary() }
```

and at line 648:

```swift
        process.start(.make(shell: shell(), folder: session.folderPath, mode: mode, rowID: id,
                            claudeBinary: mode == .shell ? nil : claudeBinary()))
```

In `docs/features/workbench.md`, in the embedded terminal part, add: "A Claude session runs the binary `Constants.claudeBinary()` resolves (`claude_path`, else the well-known install dirs, else the resolved PATH — Go `claude.FindBinary`'s twin), passed in `WATCHTOWER_CLAUDE_BIN` and exec'd by `/bin/sh`, so an install whose PATH export lives only in `~/.zshrc` still launches (2026-10-10). Exit 127 offers **Set Claude Path…**."

- [ ] **Step 4: Run to verify they pass**

Run: `make test-swift FILTER='TerminalLaunchTests|TerminalCenterTests'`
Expected: PASS, including every pre-existing test unchanged except the 127 text.

- [ ] **Step 5: Lint and commit**

Run: `make lint-diff` — expected: no new issues.

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Services/TerminalLaunch.swift WatchtowerDesktop/Sources/Services/TerminalCenter.swift WatchtowerDesktop/Tests/Core/TerminalLaunchTests.swift WatchtowerDesktop/Tests/TerminalCenterTests.swift docs/features/workbench.md
git commit -m "fix(workbench): terminal sessions exec the resolved claude binary"
```

---

### Task 3: "Set Claude Path…" on exit 127

**Depends on:** Task 2 (the exit message and the per-launch resolution).

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/OnboardingClaudePathConfig.swift` (add `saveIfExecutable`)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/TerminalLaunch.swift` (add `offersClaudePathFix`)
- Create: `WatchtowerDesktop/Sources/Views/Common/ClaudeExecutablePanel.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Onboarding/OnboardingGoalsStepView.swift:265-293` (use the panel and `saveIfExecutable`)
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkbenchSessionView.swift` (`TerminalSessionPane`'s `.exited` bar)
- Test: `WatchtowerDesktop/Tests/Core/TerminalLaunchTests.swift`, the existing `OnboardingClaudePathConfig` test file in `WatchtowerDesktop/Tests/Core/` (find it with `grep -l OnboardingClaudePathConfig WatchtowerDesktop/Tests -r`; create `OnboardingClaudePathConfigTests.swift` there if none)

**Interfaces:**
- Consumes: `TerminalLaunch.exitMessage(code:)` (Task 2), `OnboardingClaudePathConfig.save(_:configPath:)` (existing), `TerminalSession.kind` (existing, `.claude`).
- Produces:
  - `OnboardingClaudePathConfig.saveIfExecutable(_ path: String, configPath: String) -> String?` — the error line, nil once saved.
  - `TerminalLaunch.offersClaudePathFix(code: Int32?, isClaude: Bool) -> Bool`
  - `ClaudeExecutablePanel.pick() -> String?` (`@MainActor`)

- [ ] **Step 1: Write the failing tests**

In `TerminalLaunchTests`:

```swift
    /// Review Focus 4: a shell's 127 is the owner's last command, not a
    /// missing `claude`.
    func testOnlyAClaudeSessionsExit127OffersThePathFix() {
        XCTAssertTrue(TerminalLaunch.offersClaudePathFix(code: 127, isClaude: true))
        XCTAssertFalse(TerminalLaunch.offersClaudePathFix(code: 127, isClaude: false))
        XCTAssertFalse(TerminalLaunch.offersClaudePathFix(code: 1, isClaude: true))
        XCTAssertFalse(TerminalLaunch.offersClaudePathFix(code: nil, isClaude: true))
    }
```

In the `OnboardingClaudePathConfig` tests:

```swift
    func testSaveIfExecutableRefusesAFileThatCannotRun() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wt-cp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let configPath = dir.appendingPathComponent("config.yaml").path
        let missing = dir.appendingPathComponent("claude").path
        XCTAssertEqual(OnboardingClaudePathConfig.saveIfExecutable(missing, configPath: configPath),
                       "File not found or not executable: \(missing)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: configPath), "nothing written")
    }

    func testSaveIfExecutablePinsTheClaudePath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wt-cp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let configPath = dir.appendingPathComponent("config.yaml").path
        let bin = dir.appendingPathComponent("claude").path
        try "#!/bin/sh\n".write(toFile: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin)
        XCTAssertNil(OnboardingClaudePathConfig.saveIfExecutable(bin, configPath: configPath))
        XCTAssertEqual(Constants.claudePathOverride(configPath: configPath), bin)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `make test-swift FILTER='TerminalLaunchTests|OnboardingClaudePathConfig'`
Expected: compile failure — `offersClaudePathFix`, `saveIfExecutable` not found.

- [ ] **Step 3: Implement the Core helpers**

In `OnboardingClaudePathConfig`:

```swift
    /// `path` checked to be executable and pinned as `claude_path`: the
    /// error line to show, nil once saved. Onboarding's manual-path row and
    /// a workbench session's exit-127 bar share it.
    package static func saveIfExecutable(_ path: String, configPath: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return "File not found or not executable: \(path)"
        }
        do {
            try save(path, configPath: configPath)
        } catch {
            return "Could not save the path to \(configPath): \(error.localizedDescription)"
        }
        return nil
    }
```

In `TerminalLaunch`, under `exitMessage`:

```swift
    /// Whether the exit bar offers **Set Claude Path…**: only a Claude
    /// session's 127 — a shell's 127 is the owner's last command.
    package static func offersClaudePathFix(code: Int32?, isClaude: Bool) -> Bool {
        isClaude && code == 127
    }
```

- [ ] **Step 4: Run to verify they pass**

Run: `make test-swift FILTER='TerminalLaunchTests|OnboardingClaudePathConfig'`
Expected: PASS.

- [ ] **Step 5: The panel and the two views**

Create `WatchtowerDesktop/Sources/Views/Common/ClaudeExecutablePanel.swift`:

```swift
import AppKit

/// The open panel for the `claude` executable: onboarding's manual-path row
/// and a workbench session's exit-127 bar.
enum ClaudeExecutablePanel {
    @MainActor static func pick() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the 'claude' executable"
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
```

In `OnboardingGoalsStepView`, the Browse button body becomes:

```swift
                Button("Browse…") {
                    if let path = ClaudeExecutablePanel.pick() { manualPath = path }
                }
```

and `saveManualPath()` becomes:

```swift
    private func saveManualPath() {
        let path = manualPath.trimmingCharacters(in: .whitespacesAndNewlines)
        manualPathError = OnboardingClaudePathConfig.saveIfExecutable(path, configPath: Constants.configPath)
        if manualPathError == nil { Task { await model.runCLICheck() } }
    }
```

In `TerminalSessionPane` (`WorkbenchSessionView.swift`), add `@State private var claudePathError: String?` next to the other properties. In the `.exited(code)?` case, inside the `HStack` right before the `Button("Restart")`, add:

```swift
                    if let session, TerminalLaunch.offersClaudePathFix(code: code, isClaude: session.kind == .claude) {
                        Button("Set Claude Path…") {
                            guard let path = ClaudeExecutablePanel.pick() else { return }
                            claudePathError = OnboardingClaudePathConfig.saveIfExecutable(path, configPath: Constants.configPath)
                            if claudePathError == nil { Task { await vm?.open(session, placement: .inPlace) } }
                        }
                    }
```

and after that `HStack`'s `.padding(8)`:

```swift
                if let claudePathError {
                    Text(claudePathError)
                        .font(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding([.horizontal, .bottom], 8)
                }
```

Clear it on a new run: add `.onChange(of: state) { claudePathError = nil }` on the pane's `VStack` if `state` is `Equatable`; if it is not, clear it inside the button before `open` and leave it otherwise.

- [ ] **Step 6: Build and lint**

Run: `cd WatchtowerDesktop && swift build 2>&1 | tail -5; echo "exit=$?"` then `make lint-diff`.
Expected: build succeeds, no new lint issues.

- [ ] **Step 7: Commit**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Services/OnboardingClaudePathConfig.swift WatchtowerDesktop/Sources/WatchtowerCore/Services/TerminalLaunch.swift WatchtowerDesktop/Sources/Views/Common/ClaudeExecutablePanel.swift WatchtowerDesktop/Sources/Views/Onboarding/OnboardingGoalsStepView.swift WatchtowerDesktop/Sources/Views/Workbench/WorkbenchSessionView.swift WatchtowerDesktop/Tests
git commit -m "feat(workbench): Set Claude Path on a session's exit 127"
```

---

### Task 4: Go `integrate` uses `claude.FindBinary`

**Depends on:** none (parallel-safe with Tasks 1–3; different language, different files).

**Files:**
- Modify: `cmd/integrate.go` (`runIntegrateClaudeCode`, `runIntegrateRemove`, `registerMCPWithClaudeCode`; new `integrateClaudeBinary`, new `unregisterMCPFromClaudeCode`)
- Test: `cmd/integrate_test.go`

**Interfaces:**
- Consumes: `claude.FindBinary(override string) string` (`internal/claude`), `config.Load(path string) (*config.Config, error)`, `flagConfig` (the root `--config` flag var).
- Produces:
  - `func integrateClaudeBinary() string` — absolute path, "" when none
  - `func registerMCPWithClaudeCode(claudeBin string) error`
  - `func unregisterMCPFromClaudeCode(claudeBin string) error`

- [ ] **Step 1: Write the failing tests**

Append to `cmd/integrate_test.go` (add imports `os`, `path/filepath`, `strings` if missing):

```go
// claudeStub writes an executable `claude` into a fresh dir (not on PATH)
// that records its arguments next to itself; it exits at once, and
// CombinedOutput waits for it.
func claudeStub(t *testing.T) (bin, argsFile string) {
	t.Helper()
	dir := t.TempDir()
	bin = filepath.Join(dir, "claude")
	argsFile = filepath.Join(dir, "args")
	script := "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$(dirname \"$0\")/args\"\n"
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return bin, argsFile
}

func TestRegisterMCPRunsTheGivenClaudeBinary(t *testing.T) {
	bin, argsFile := claudeStub(t)
	if err := registerMCPWithClaudeCode(bin); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(argsFile)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(string(got), "mcp\nadd\nwatchtower\n--\n") || !strings.HasSuffix(string(got), "\nmcp\n") {
		t.Fatalf("claude got %q", got)
	}
}

func TestUnregisterMCPRunsTheGivenClaudeBinary(t *testing.T) {
	bin, argsFile := claudeStub(t)
	if err := unregisterMCPFromClaudeCode(bin); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(argsFile)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "mcp\nremove\nwatchtower\n" {
		t.Fatalf("claude got %q", got)
	}
}

func TestRegisterMCPWithoutClaudeSucceedsAndRunsNothing(t *testing.T) {
	if err := registerMCPWithClaudeCode(""); err != nil {
		t.Fatal(err)
	}
	if err := unregisterMCPFromClaudeCode(""); err != nil {
		t.Fatal(err)
	}
}

// The configured claude_path wins even when it is not on PATH — the
// Desktop terminal's binary (Constants.claudeBinary) and this one agree.
func TestIntegrateClaudeBinaryUsesTheConfiguredPath(t *testing.T) {
	bin, _ := claudeStub(t)
	cfgPath := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(cfgPath, []byte("claude_path: '"+bin+"'\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	old := flagConfig
	flagConfig = cfgPath
	t.Cleanup(func() { flagConfig = old })
	if got := integrateClaudeBinary(); got != bin {
		t.Fatalf("integrateClaudeBinary() = %q, want %q", got, bin)
	}
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `go test ./cmd -run 'TestRegisterMCP|TestUnregisterMCP|TestIntegrateClaudeBinary'`
Expected: build failure — wrong arity for `registerMCPWithClaudeCode`, `unregisterMCPFromClaudeCode` and `integrateClaudeBinary` undefined.

- [ ] **Step 3: Implement**

Add near `registerMCPWithClaudeCode` (import `watchtower/internal/claude` and `watchtower/internal/config` if `integrate.go` lacks them):

```go
// integrateClaudeBinary is the claude CLI integrate runs: config's
// claude_path, then claude.FindBinary's PATH, login-shell and well-known-dir
// lookups — the binary the Desktop terminal launches (Swift
// Constants.claudeBinary). "" when none is found. A config that fails to
// load only drops the override.
func integrateClaudeBinary() string {
	override := ""
	if cfg, err := config.Load(flagConfig); err == nil {
		override = cfg.ClaudePath
	}
	p, err := exec.LookPath(claude.FindBinary(override))
	if err != nil {
		return ""
	}
	return p
}
```

`registerMCPWithClaudeCode` takes `claudeBin string`: replace its `exec.LookPath("claude")` guard with `if claudeBin == "" {` (same body), and `exec.Command("claude", "mcp", "add", …)` with `exec.Command(claudeBin, "mcp", "add", …)`. Update its doc comment: "When no claude CLI was found (claudeBin empty)…".

Move the unregister block of `runIntegrateRemove` (from `if _, err := exec.LookPath("claude")` to the final `return nil`) into:

```go
// unregisterMCPFromClaudeCode removes the watchtower MCP server from
// Claude Code. Like registration, a missing CLI or a failed call prints the
// command to run by hand and does not fail integrate remove.
func unregisterMCPFromClaudeCode(claudeBin string) error {
	if claudeBin == "" {
		fmt.Println("\nclaude CLI not found — remove the MCP server yourself with:")
		fmt.Println("  claude mcp remove watchtower")
		return nil
	}
	out, err := exec.Command(claudeBin, "mcp", "remove", "watchtower").CombinedOutput()
	if err != nil {
		fmt.Printf("\nCould not unregister the MCP server (%v). Remove it with:\n", err)
		fmt.Println("  claude mcp remove watchtower")
		fmt.Printf("%s\n", out)
		return nil
	}
	fmt.Println("\nMCP server unregistered.")
	return nil
}
```

`runIntegrateClaudeCode` ends with `return registerMCPWithClaudeCode(integrateClaudeBinary())`; `runIntegrateRemove` ends with `return unregisterMCPFromClaudeCode(integrateClaudeBinary())`. Keep the `//nolint:nilerr` comments only where `err` is still in scope; drop them where it no longer is.

- [ ] **Step 4: Run to verify they pass**

Run: `go test ./cmd -run 'TestRegisterMCP|TestUnregisterMCP|TestIntegrateClaudeBinary|TestResolveMCPScope|TestShouldTouchMCP'`
Expected: PASS.

- [ ] **Step 5: Lint and commit**

Run: `make lint-diff` — expected: no new issues.

```bash
git add cmd/integrate.go cmd/integrate_test.go
git commit -m "fix(integrate): run the claude binary FindBinary resolves"
```

---

### Phase gate (controller, once, after Tasks 1–4)

- [ ] `bash scripts/dev-health.sh` — proceed only if not `HEALTH: overloaded`.
- [ ] `make test > /tmp/… ; echo "exit=$?"` (log to the scratchpad), `make test-swift`, `make lint-all` — all green.
- [ ] Ask the owner for the manual check (`ask_owner`, kind `check`): with `~/.local/bin` exported only in `~/.zshrc`, launch the app from Finder, open a new workbench session → Claude Code starts; temporarily point `claude_path` at a missing file and rename the binary → exit bar shows **Set Claude Path…**, picking the binary restarts the session.
