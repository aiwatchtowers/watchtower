# Onboarding AI Agent Choice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Goals step's silent CLI check with the owner's explicit Claude Code / Codex CLI choice. Cover every no-agent, signed-out and outdated path, with sign-in right in the step.

**Architecture:** The pure state and copy already exist and are tested: `OnboardingAgentChoice` in WatchtowerCore. The section view `OnboardingAgentSection`, the extracted `OnboardingGoalCards` / `OnboardingGoalsFooter` and 19 mockup scenes are also done. This plan adds:
- a pure per-agent check (`OnboardingAgentCheck`) over injected probes;
- the Goals model rewired onto the choice (`ai.provider` written only at Continue);
- production probes (locate + resolve, help probe, `ai test --json` with `error_code`);
- an embedded sign-in terminal (SwiftTerm);
- the step view rewired onto it all, plus docs.

**Tech Stack:** Swift 5.10 mode, SwiftUI, WatchtowerCore (no ML stack), SwiftTerm `LocalProcessTerminalView`, the Go CLI (`watchtower ai test --json`, `config set`, and one new read-only command `watchtower ai which`).

**Spec:** `docs/superpowers/specs/2026-11-10-onboarding-agent-choice-design.md` (approved, ask #1172). Mockups: `docs/design/mockups/onboarding-agent/`.

## Global Constraints

- Every UI string comes from `OnboardingAgentChoice` (already tested in `Tests/Core/OnboardingAgentChoiceTests.swift`); a view never spells copy of its own.
- Colours only through `Tone` / `Fill` / `Surface`; no stock look, no dividers between rows; `make lint-swift` clean for touched view files (the kit lint rules).
- The check never writes config. Continue writes `workbench.default_agent` (skipped when equal), then `ai.provider`, only when `OnboardingAgentChoice.providerToSave(configured:)` is non-nil.
- A missing or forbidden agent costs no request; installed agents are tested in parallel with `ai test --json --provider <agent>`.
- The login probe reads help **text** (`Agent.loginSupported(help:)`), never the exit code. A probe that times out (5 s) counts as **outdated**: the update for its install kind runs; `claude update` on a current CLI changes nothing, the re-probe then lands in `updateStuck` (path named, Choose the executable), so a hung CLI never goes straight to a login that can't work (ask #1163) and never loops.
- **One binary, one lookup.** The executable every path uses — the test, the help probe, the sign-in and the update terminal — is the one Go's own lookup returns (`claude.FindBinary(cfg.ClaudePath)` / `codex.FindBinary(cfg.CodexPath)`), asked through `watchtower ai which`. Swift never searches PATH for an agent itself. The terminal runs that path (shell-quoted), not a bare `claude`/`codex`.
- The sign-in terminal runs `OnboardingAgentChoice.terminalCommand` via the login shell, in its own process group, killed (SIGTERM to the group) on Stop, tile switch, leaving the step, Cancel and app quit.
- Inner loop only per task: `make test-swift FILTER=<Class>`, `swiftlint` on touched files; the full gate (`make test-swift`, `make lint-all`) once before the PR.
- Branch: umbrella `feature/onboarding-agent-choice` off `main` (starting from the spec commits on `wt/session-10-5`); task PRs go into it, one PR into `main` at the end.

## Review Focus

1. **Installed while the step is open.** The owner installs Claude in Terminal and comes back; the next check must find `~/.local/bin/claude` without a relaunch. `locate` is evaluated on every check, never cached. Test: Task 3 `testLocateIsFreshEachCall`.
2. **Sign-in process outliving the step.** Continue, Cancel, a tile switch or closing the window while `claude auth login` waits must leave no process behind. Tests: Task 4 `testStopKillsTheProcessGroup`, Task 5 `testLeavingTheStepStopsSignIn`.
3. **A help probe that hangs.** An old CLI may wait on a first-run prompt. The probe has a 5 s timeout, and a timeout counts as outdated (see Global Constraints): the update runs, and if nothing changes the panel stops in `updateStuck` and names the path. Tests: Task 1 `testHelpTimeoutCountsAsOutdated`, Task 3 `testHelpProbeTimesOut`.
4. **Check again pressed repeatedly, or reactivation during a check.** The calls join the check in flight, and an older result never overwrites a newer one. Test: Task 2 `testConcurrentChecksJoinAndStaleResultIsDropped`.
5. **Partial Continue write.** `default_agent` is saved but `ai.provider` fails. The owner stays on the step with "Couldn't save the AI agent." and the error, `ai.provider` is unchanged, and a retry skips the equal `default_agent`. Test: Task 2 `testProviderWriteFailureKeepsTheStep`.

---

### Task 0: `watchtower ai which` (Go)

**Depends on:** none

**Files:**
- Modify: `cmd/ai.go` (subcommand `which` beside `test`)
- Test: `cmd/ai_which_test.go`
- Modify: `docs/guide/reference/cli.md` (one line)

**Interfaces:**
- Produces: `watchtower ai which --provider claude|codex --json` → one line `{"provider":"codex","path":"/opt/homebrew/bin/codex","found":true}`. Pinned keys `provider`, `path`, `found`. `path` is the configured `claude_path`/`codex_path` when it is an executable file (`FindBinary`'s own override rule), else the package seams `claudeFindBinary()` (`cmd/integrate.go`) / `codexFindBinary()` (`cmd/workbench_launch_args.go`) — the same `FindBinary` lookups, swappable in tests, so the per-process `sync.Once` cache inside `FindBinary` never leaks between tests. `found` is false when that is the bare fallback name or not an executable file (then `path` is `""`). No request, no auth read, no config write, no migration (skip the schema hook as `ai test` does). Exit 0 either way; an unknown provider exits 2.

- [ ] **Step 1: Failing tests** `TestAIWhich_ConfiguredPath` (a temp executable set as `codex_path` → found, that path), `TestAIWhich_NotFound` (no override; the seams swapped to return the bare fallback `"claude"` / `""` with `devpack.ErrCodexNotFound` — `testmain_test.go` already defaults `codexFindBinary` to not found — → `found:false`, `path:""`), `TestAIWhich_SeamPath` (seam returns a temp executable → found, that path), `TestAIWhich_PinnedKeys`, `TestAIWhich_UnknownProvider` (exit 2).
- [ ] **Step 2: Run** `go test ./cmd -run TestAIWhich` → FAIL.
- [ ] **Step 3: Implement** in `cmd/ai.go`; register in the audit classification as `ai test` is (read-only).
- [ ] **Step 4: Run** → PASS; `make lint-diff` clean.
- [ ] **Step 5: Commit** — `feat(ai): ai which — the agent binary Go would run (#1521)`.

### Task 1: Per-agent check (Core)

**Depends on:** none (uses Task 0's JSON shape only through the `locate` probe)

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/OnboardingAgentCheck.swift`
- Test: `WatchtowerDesktop/Tests/Core/OnboardingAgentCheckTests.swift`

**Interfaces:**
- Consumes: `OnboardingAgentChoice.Agent`, `.Status`, `.Install`, `.InstallKind.of(_:resolvedPath:home:)`, `Agent.loginSupported(help:)`, `OnboardingAgentChoice.failureMessage(_:code:error:)`.
- Produces:
  ```swift
  package struct OnboardingAgentTestResult: Equatable, Sendable { package var ok: Bool; package var errorCode: String?; package var error: String? }
  package struct OnboardingAgentProbes: Sendable {
      package var configuredProvider: String?            // ai.provider, nil/blank = unset
      package var allowed: @Sendable (OnboardingAgentChoice.Agent) -> Bool          // ManagedPolicy
      package var locate: @Sendable (OnboardingAgentChoice.Agent) async -> String? // Go's binary (`ai which`), nil = not found
      package var resolve: @Sendable (String) -> String                            // symlinks followed, for InstallKind
      package var help: @Sendable (OnboardingAgentChoice.Agent, String) async -> String? // nil = timed out
      package var test: @Sendable (String?, String?) async -> OnboardingAgentTestResult // (provider or nil = configured, executable for --cli-path)
      package var home: String
  }
  package struct OnboardingAgentCheckResult: Equatable, Sendable {
      package var statuses: [OnboardingAgentChoice.Agent: OnboardingAgentChoice.Status]
      package var installs: [OnboardingAgentChoice.Agent: OnboardingAgentChoice.Install]
      package var outdated: Set<OnboardingAgentChoice.Agent>
      package var otherProvider: String?        // display name, e.g. "Ollama"
      package var otherProviderFailure: String?
  }
  package enum OnboardingAgentCheck { package static func run(_ probes: OnboardingAgentProbes) async -> OnboardingAgentCheckResult }
  ```

- Also modifies `OnboardingAgentChoice` (Core, existing): `Install` gains `executable: String` (Go's path, what runs) beside `path` (resolved, for the kind and the stuck note). `terminalCommand` and the Terminal fallback step become `shellQuote(executable) + " auth login"` / `" login"`, and for the native Claude update `shellQuote(executable) + " update"`. The Homebrew, npm and Codex-script updates stay as they are. An agent with no `Install` falls back to the bare name. Tests in `OnboardingAgentChoiceTests`: `testTerminalRunsTheLocatedExecutable` (`/Users/acme/.local/bin/claude` → `'/Users/acme/.local/bin/claude' auth login`; a path with a quote is escaped `'\''`), and the existing copy tests updated.

- [ ] **Step 1: Write the failing tests** (fake probes, counting calls):
  - `testForbiddenAgentIsNeverLocatedOrTested`: `allowed(.claude) == false` → `.forbidden`, `locate`/`test` call counts for claude are 0.
  - `testMissingAgentCostsNoRequest`: `locate(.codex) == nil` → `.notInstalled`, no `test("codex")`.
  - `testStatusFromTheTest`: ok → `.ready`; `errorCode "auth"` → `.signedOut`; `"policy"` → `.forbidden`; `"timeout"` → `.failed(failureMessage(.claude, code: "timeout", error: …))`.
  - `testBothInstalledAreTestedInParallel`: each fake `test` waits on a shared gate that opens only when both have been entered; `run` completes (no deadlock).
  - `testInstallFromLocatedPath`: locate returns `"/opt/homebrew/bin/codex"`, resolve maps it to `".../node_modules/@openai/codex/bin/codex.js"` → `installs[.codex] == .init(path: resolved, kind: .npm, executable: "/opt/homebrew/bin/codex")`; the test probe gets that executable (see Task 3: `--cli-path`).
  - `testHelpProbeOnlyForSignedOut`: help is called for a `.signedOut` agent only, with the located executable; a help text without a `login` row → `outdated == [.claude]`.
  - `testHelpTimeoutCountsAsOutdated`: `help` returns nil → `outdated == [.claude]`.
  - `testOtherProviderWorking`: configured `"ollama"`, `test(nil)` ok → `otherProvider == "Ollama"`, no agent located or tested.
  - `testOtherProviderFailingChecksTheAgents`: configured `"ollama"`, `test(nil)` fails with `"transport"` → `otherProviderFailure` set, both agents checked.

- [ ] **Step 2: Run to see them fail** — `make test-swift FILTER=OnboardingAgentCheckTests` → FAIL (types missing).

- [ ] **Step 3: Implement `OnboardingAgentCheck.run`.** Use `withTaskGroup` over `Agent.allCases`. The provider display name is `AIModelCatalog.shared.displayName(id)` (WatchtowerCore). Run the other-provider test first, and skip the agents when it passes. Each agent's test passes its located executable, so the test runs the same binary as everything else.

- [ ] **Step 4: Run** — same filter → PASS.

- [ ] **Step 5: Commit** — `feat(onboarding): per-agent check over injected probes (#1521)`.

### Task 2: Goals model on the choice

**Depends on:** Task 1

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/OnboardingGoalsModel.swift`
- Delete: `WatchtowerDesktop/Sources/WatchtowerCore/Services/OnboardingCLIProbe.swift`, `WatchtowerDesktop/Tests/Core/OnboardingCLIProbeTests.swift`
- Modify: `WatchtowerDesktop/Tests/Core/OnboardingGoalsModelTests.swift`, `WatchtowerDesktop/Tests/AppStateTests.swift:586`

**Interfaces:**
- Consumes: Task 1 `OnboardingAgentCheckResult`.
- Produces (on `OnboardingGoalsModel`):
  - `init(defaults:systemLanguage:checkAgents: @escaping () async -> OnboardingAgentCheckResult, configuredProvider: @escaping () -> String?, actions:)`; `OnboardingCLICheck` and `checkCLI` are removed.
  - `package private(set) var agentChoice: OnboardingAgentChoice`
  - `package func runAgentCheck() async` (replaces `runCLICheck`, same join/generation rules); `package func pickAgent(_:)`; `package func windowBecameActive() async` (runs a check only when `!agentChoice.canContinue` and `agentChoice.signIn != .running`); `signInStarted()`, `signInEnded(exitCode:)` (on 0: `runAgentCheck()`), `signInStopped()` forwarding to the choice.
  - `OnboardingGoalsActions.saveAgent: (String) async throws -> Void` (writes default_agent if different, then `ai.provider`).
  - `onProviderSwitched` fires after a successful `saveAgent`, never from a check.
  - `canContinue = agentChoice.canContinue && !isContinuing && !isCheckingAgents`.

- [ ] **Step 1: Rewrite the tests that used `cliCheck`, and add:**
  - `testCheckAppliesResultAndDefault`: result with claude ready/codex ready, configured `nil` → `agentChoice.selected == .claude`, `canContinue`.
  - `testCheckNeverWrites`: after `runAgentCheck`, `saveAgent` call count 0 and `wroteChanges == false`.
  - `testContinueSavesTheChangedPickFirst`: pick `.codex` with configured `"claude"` → `submit` calls `saveAgent("codex")` before `initWorkspace`; `onProviderSwitched` gets `"codex"`; `wroteChanges`.
  - `testContinueSkipsAnUnchangedAgent`: configured `"claude"`, pick claude → `saveAgent` not called.
  - `testProviderWriteFailureKeepsTheStep`: `saveAgent` throws `"permission denied"` → `submit` returns nil, `continueError == OnboardingAgentChoice.saveFailure + " permission denied"`, `onProviderSwitched` not called.
  - `testConcurrentChecksJoinAndStaleResultIsDropped`: the existing gated-check pattern (`release(_:with:)`) moved onto `checkAgents`.
  - `testSignInExitZeroRechecks` / `testWindowBecameActiveChecksOnlyWhenNotReady`.
  - `AppStateTests:586`: `XCTAssertEqual(appState.onboardingGoals.agentChoice, OnboardingAgentChoice())`.

- [ ] **Step 2: Run** — `make test-swift FILTER='OnboardingGoalsModelTests|AppStateTests'` → FAIL to compile.

- [ ] **Step 3: Implement.** After each check: assign `statuses`, `installs`, `otherProvider`/`otherProviderFailure`, call `applyLoginProbe(outdated:)`, then `applyDefault(configured: configuredProvider())`. `submit` saves the agent before the workspace step. Delete the probe files.

- [ ] **Step 4: Run** — same filter plus `OnboardingAgentChoiceTests` → PASS.

- [ ] **Step 5: Commit** — `feat(onboarding): Goals model on the agent choice, provider written at Continue (#1521)`.

### Task 3: Production probes and path config

**Depends on:** Task 0, Task 1, Task 2

**Files:**
- Modify: `WatchtowerDesktop/Sources/App/OnboardingGoalsModel+Production.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/WatchtowerAIService.swift` (add a non-throwing result call)
- Rename + generalise: `OnboardingClaudePathConfig.swift` → `OnboardingAgentPathConfig.swift` (`save(_ path:, for agent:, configPath:)`, key `agent.pathKey`)
- Modify: `WatchtowerDesktop/Sources/App/AppState+Chat.swift:48` (comment: the switch now comes from Continue)
- Test: `WatchtowerDesktop/Tests/Core/OnboardingAgentPathConfigTests.swift` (move the existing claude_path tests, add codex), `WatchtowerDesktop/Tests/Core/WatchtowerAIServiceTests.swift`, `WatchtowerDesktop/Tests/OnboardingAgentProbesTests.swift`

**Interfaces:**
- Consumes: Task 1 `OnboardingAgentProbes`, `OnboardingAgentTestResult`.
- Consumes: Task 0 `ai which`.
- Produces: `WatchtowerAIService.testResult(provider: String?, cliPath: String?) async -> OnboardingAgentTestResult` (`ai test --json [--provider p] [--cli-path x]`; decodes `ok`/`error`/`error_code`; launch failure → `ok:false, errorCode:"launch"`); `WatchtowerAIService.which(provider:) async -> String?` (`ai which --json`, nil unless `found`); `OnboardingAgentProbes.production(config: ConfigService, policy: ManagedPolicy) -> OnboardingAgentProbes`; `OnboardingAgentPathConfig.save(_:for:configPath:)`.

- [ ] **Step 1: Failing tests:**
  - `testTestResultDecodesErrorCode` (`{"ok":false,"provider":"claude","model":"m","error":"x","error_code":"auth"}` → `errorCode == "auth"`); `testTestResultOk`.
  - `testSavesCodexPath` / `testKeepsOtherLines` for `codex_path` (mirror the claude ones).
  - `testWhichDecodes` (`{"provider":"codex","path":"/x/codex","found":true}` → `"/x/codex"`; `found:false` → nil).
  - `testResolveFollowsSymlinks` (temp dir: a symlink `bin/codex` → `pkg/codex.js` → the target).
  - `testLocateIsFreshEachCall` (stubbed CLI: `ai which` answers not found, then found → the second call returns the path; nothing cached in Swift).
  - `testHelpProbeTimesOut` (a stub script that sleeps 10 s → `help` returns nil within ~5 s and its process group is gone).
  - `testHelpRunsTheRightArguments` (stub prints its argv: `auth --help` for claude, `login --help` for codex).

- [ ] **Step 2: Run** — `make test-swift FILTER='WatchtowerAIServiceTests|OnboardingAgentPathConfigTests|OnboardingAgentProbesTests'` → FAIL.

- [ ] **Step 3: Implement.** `locate` = `WatchtowerAIService.which(provider:)` (a fresh `ai which` process per check; never `Constants.findInPath`). `resolve` = `URL(fileURLWithPath:).resolvingSymlinksInPath().path`. `test` = `testResult(provider:cliPath:)`. `help`: `Process` with the login env from `Constants.resolvedEnvironmentAsync()`, 5 s timeout, the process group reaped on timeout. `allowed`: `ManagedPolicy.providerAllowed`. Wire `checkAgents` and `saveAgent` (`config set workbench.default_agent` when different, then `config set ai.provider`).

- [ ] **Step 4: Run** — same filter → PASS; `swiftlint` on touched files clean.

- [ ] **Step 5: Commit** — `feat(onboarding): production agent probes, codex_path config (#1521)`.

### Task 4: Sign-in terminal

**Depends on:** none

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Onboarding/OnboardingSignInTerminal.swift`
- Test: `WatchtowerDesktop/Tests/OnboardingSignInTerminalTests.swift`

**Interfaces:**
- Produces:
  ```swift
  @MainActor final class OnboardingSignInSession {
      init(environment: [String: String], onExit: @escaping (Int32) -> Void)
      // `command` is `OnboardingAgentChoice.terminalCommand`: the located
      // executable shell-quoted (Task 1), so the login shell's PATH never
      // picks another copy.
      var view: LocalProcessTerminalView { get }
      func start(command: String)   // runs `/bin/zsh -lc <command>` in a new process group; a start failure calls onExit(127)
      func stop()                    // SIGTERM to the group; onExit is NOT called again after stop
      var isRunning: Bool { get }
      deinit                         // stops a running process group
  }
  struct OnboardingSignInTerminal: NSViewRepresentable { let session: OnboardingSignInSession }
  ```

- [ ] **Step 1: Failing tests:** `testExitCodeIsReported` (`exit 3` → onExit(3)); `testZeroExit` (`true` → onExit(0)); `testStopKillsTheProcessGroup` (`sleep 60 & sleep 60; wait` → after `stop()` no process in the group, checked with `kill(-pgid, 0) == -1 && errno == ESRCH` within 2 s); `testStartFailureReportsEnded` (an environment without a shell, or a nonexistent shell path seam → onExit(127)). Every test stops the session in `t.Cleanup`-style `addTeardownBlock`.

- [ ] **Step 2: Run** — `make test-swift FILTER=OnboardingSignInTerminalTests` → FAIL.

- [ ] **Step 3: Implement** on SwiftTerm `LocalProcessTerminalView` (see `TerminalCenter`'s `PalettedTerminalView` for the palette and the process delegate). `processTerminated` maps to `onExit`. Use `setsid` via the shell's own `exec` or `posix_spawn` attributes so the shell leads its own group.

- [ ] **Step 4: Run** — same filter → PASS.

- [ ] **Step 5: Commit** — `feat(onboarding): embedded sign-in terminal session (#1521)`.

### Task 5: Step view on the agent section

**Depends on:** Task 2, Task 3, Task 4

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Onboarding/OnboardingGoalsStepView.swift` (remove `cliStatusLine`, `cliRequiredBox`, `goalChips`, `manualPathRow`, `saveManualPath`, `codeBlock`; body = goal cards with `developmentPitch`, customize line, `AssistantLanguageRow`, `OnboardingAgentSection`, `OnboardingGoalsFooter`; tokens instead of raw metrics/opacities in the file)
- Modify: `WatchtowerDesktop/Sources/App/OnboardingV2View.swift` (Cancel/leave stops sign-in)
- Test: `WatchtowerDesktop/Tests/OnboardingGoalsStepTests.swift`; `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+OnboardingAgent.swift`: an `onboarding-step-live-<scene>` shot of the real `OnboardingGoalsStepView` (on `AppState(workbenchDefaults: AppState.isolatedDefaults)`, model seeded through a fake `checkAgents` / `saveAgent`) for **every scene a check result and the model's API reach**: checking, both-ready, both-ready-codex, only-codex, signed-out-stopped, none, none-codex, none-narrow, failed, policy, policy-both, other-provider, other-provider-failed, save-error, signed-out-update-stuck — 15 of 19. The three running-terminal scenes (`signed-out`, `signed-out-outdated`, `signed-out-update-failed`) need a live PTY and `continuing` a held Continue; those four are checked by hand in the Gate.

**Interfaces:**
- Consumes: Task 2 model API, Task 3 `OnboardingAgentPathConfig.save(_:for:configPath:)`, Task 4 `OnboardingSignInSession`.

- [ ] **Step 1: Failing tests:** `testAppQuitStopsSignIn` (running session → post `NSApplication.willTerminateNotification` → `stop()` called before the handler returns); `testUpdateThenSignInOpensByItself` (claude signed out and outdated, native install → the first session runs `'<exe>' update`; report exit 0 → the model rechecks (fake `checkAgents` now returns not outdated) → a second session starts with `'<exe>' auth login` by itself); `testAutoOpensSignInOnce` (model with claude signed out → the step's coordinator starts a session with `agentChoice.terminalCommand`, and a second render does not start another); `testLeavingTheStepStopsSignIn` (running session → `onDisappear`/Cancel → `stop()` called, model `signIn == .ended(nil)`); `testPickingTheOtherTileStopsSignIn`; `testChooseExecutableSavesThePickedAgentsPath`.

- [ ] **Step 2: Run** — `make test-swift FILTER=OnboardingGoalsStepTests` → FAIL.

- [ ] **Step 3: Implement.** A small `@MainActor` coordinator owned by the view holds the `OnboardingSignInSession?` and observes `NSApplication.willTerminateNotification` (stop). `.onChange(of: model.agentChoice.signInToOpen)` starts it. `NSApplication.didBecomeActiveNotification` → `model.windowBecameActive()`. Choose the executable = `NSOpenPanel` → `OnboardingAgentPathConfig.save` → `runAgentCheck()`. The section's `signInTerminal` returns `OnboardingSignInTerminal(session:)`.

- [ ] **Step 4: Run** the filter, then `DESKTOP_SHOTS_DIR=<scratch> swift test --filter DesignShotsTests/testOnboardingAgentShotsRender` and compare each `onboarding-step-live-<scene>` PNG with its `onboarding-agent-<scene>` mockup by eye, light and dark (15 pairs). Any difference is fixed or explained in the commit.

- [ ] **Step 5: `swiftlint` on the step file** — no `kit_*` violations left in it.

- [ ] **Step 6: Commit** — `feat(onboarding): Goals step on the agent section with sign-in terminal (#1521)`.

### Task 6: Docs and guide

**Depends on:** Task 5

**Files:**
- Modify: `docs/onboarding-flow.md` (Goals box: per-agent check, the pick, write at Continue, sign-in terminal)
- Modify: `docs/features/onboarding-v2.md` (CLI check paragraph → agent section, link the spec)
- Modify: `docs/guide/start/setup.md`, `docs/guide/troubleshooting/ai-tool-not-found-or-not-signed-in.md` (curl installers, Other ways to install, signing in from the step, the update path), following `docs/guide/WRITING.md`

- [ ] **Step 1: Edit the four pages**; no `OnboardingCLIProbe` mention left (`grep -rn OnboardingCLIProbe docs WatchtowerDesktop/Sources` → empty).
- [ ] **Step 2: Run** — `go test ./docs/guide/...` → PASS (8 KB section cap, links).
- [ ] **Step 3: Commit** — `docs(onboarding): agent choice in the flow, feature note and guide (#1521)`.

### Gate (controller, once)

- [ ] `make test-swift` and `make lint-all` green; `go test ./docs/guide/...` green.
- [ ] **Hand checks by the owner, in a separate macOS user account** (spec Acceptance H items 4, 5, 6, and the four scenes without a live shot). A throwaway `HOME` isolates nothing that matters here. The onboarding progress lives in `UserDefaults` for `com.watchtower.desktop`, which `cfprefsd` keeps per macOS user. Claude keeps its sign-in in the user's Keychain (one `Claude Code-credentials` item, whatever `CLAUDE_CONFIG_DIR` says). A real sign-in in the owner's account could therefore replace the owner's own Claude login. So the controller files one `ask_owner` of kind `check` with the steps below, to run in a test user (System Settings → Users & Groups → Add User; delete it afterwards). Its preferences, Keychain, Application Support and config are all fresh. The controller copies the built app and the stub script to `/Users/Shared/wt-check/` first.
  1. **Signed out** (`signed-out`, `signed-out-stopped`): in the test user, install Claude Code with the step's own command and open `/Users/Shared/wt-check/Watchtower.app`. The tile reads Installed · not signed in, and the terminal opens with `'<path>' auth login`. Stop it; see "Sign-in stopped before it finished." and **Sign in again**; sign in for real (the test user's own Keychain); the tile turns Ready.
  2. **Continue held** (`continuing`): press Continue; the spinner shows while `config set` writes (compare with the mockup).
  3. **Quit**: on a fresh run with the sign-in terminal open, quit the app; `pgrep -f "auth login"` in Terminal is empty.
  4. **Outdated and failed update** (`signed-out-outdated`, `signed-out-update-failed`): `/Users/Shared/wt-check/stub/claude` handles three cases. `auth --help` prints a general help with no `login` row. `update` sleeps 3 s and exits 1. Anything else prints the line `Not logged in · Please run /login` (the exact diagnostic Go's `providers` classifier reads as `auth`) and exits 1. In the test user, before launching: `/Users/Shared/wt-check/Watchtower.app/Contents/Resources/watchtower config set claude_path /Users/Shared/wt-check/stub/claude`. Then open the app: the update terminal runs, then "Update stopped before it finished (exit code 1)." with **Update again**. Compare both with their mockups.
  5. Delete the test user (System Settings → Users & Groups).
  The controller does not wait on this ask to merge the task PRs into the umbrella branch; the umbrella PR into `main` waits for the check.

- [ ] Umbrella PR `feature/onboarding-agent-choice` → `main` with `/local-review` (debate-review on the final PR).
