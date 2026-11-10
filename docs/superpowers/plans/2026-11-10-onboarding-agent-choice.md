# Onboarding AI Agent Choice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Goals step's silent CLI check with the owner's explicit Claude Code / Codex CLI choice. Cover every no-agent, signed-out and outdated path, with sign-in right in the step.

**Architecture:** The pure state and copy already exist and are tested: `OnboardingAgentChoice` in WatchtowerCore. The section view `OnboardingAgentSection`, the extracted `OnboardingGoalCards` / `OnboardingGoalsFooter` and 19 mockup scenes are also done. This plan adds:
- a pure per-agent check (`OnboardingAgentCheck`) over injected probes;
- the Goals model rewired onto the choice (`ai.provider` written only at Continue);
- production probes (locate + resolve, help probe, `ai test --json` with `error_code`);
- an embedded sign-in terminal (SwiftTerm);
- the step view rewired onto it all, plus docs.

**Tech Stack:** Swift 5.10 mode, SwiftUI, WatchtowerCore (no ML stack), SwiftTerm `LocalProcessTerminalView`, the Go CLI (`watchtower ai test --json`, `config set`). No Go changes.

**Spec:** `docs/superpowers/specs/2026-11-10-onboarding-agent-choice-design.md` (approved, ask #1172). Mockups: `docs/design/mockups/onboarding-agent/`.

## Global Constraints

- Every UI string comes from `OnboardingAgentChoice` (already tested in `Tests/Core/OnboardingAgentChoiceTests.swift`); a view never spells copy of its own.
- Colours only through `Tone` / `Fill` / `Surface`; no stock look, no dividers between rows; `make lint-swift` clean for touched view files (the kit lint rules).
- The check never writes config. Continue writes `workbench.default_agent` (skipped when equal), then `ai.provider`, only when `OnboardingAgentChoice.providerToSave(configured:)` is non-nil.
- A missing or forbidden agent costs no request; installed agents are tested in parallel with `ai test --json --provider <agent>`.
- The login probe reads help **text** (`Agent.loginSupported(help:)`), never the exit code.
- The sign-in terminal runs `OnboardingAgentChoice.terminalCommand` via the login shell, in its own process group, killed (SIGTERM to the group) on Stop, tile switch, leaving the step, Cancel and app quit.
- Inner loop only per task: `make test-swift FILTER=<Class>`, `swiftlint` on touched files; the full gate (`make test-swift`, `make lint-all`) once before the PR.
- Branch: umbrella `feature/onboarding-agent-choice` off `main` (starting from the spec commits on `wt/session-10-5`); task PRs go into it, one PR into `main` at the end.

## Review Focus

1. **Installed while the step is open.** The owner installs Claude in Terminal and comes back; the next check must find `~/.local/bin/claude` without a relaunch. `locate` is evaluated on every check, never cached. Test: Task 3 `testLocateIsFreshEachCall`.
2. **Sign-in process outliving the step.** Continue, Cancel, a tile switch or closing the window while `claude auth login` waits must leave no process behind. Tests: Task 4 `testStopKillsTheProcessGroup`, Task 5 `testLeavingTheStepStopsSignIn`.
3. **A help probe that hangs.** An old CLI may wait on a first-run prompt. The probe has a 5 s timeout, and a timeout reads as "login supported": the sign-in then fails visibly, with Sign in again and the Terminal fallback, instead of an update the owner may not need. Test: Task 3 `testHelpProbeTimeoutCountsAsSupported`.
4. **Check again pressed repeatedly, or reactivation during a check.** The calls join the check in flight, and an older result never overwrites a newer one. Test: Task 2 `testConcurrentChecksJoinAndStaleResultIsDropped`.
5. **Partial Continue write.** `default_agent` is saved but `ai.provider` fails. The owner stays on the step with "Couldn't save the AI agent." and the error, `ai.provider` is unchanged, and a retry skips the equal `default_agent`. Test: Task 2 `testProviderWriteFailureKeepsTheStep`.

---

### Task 1: Per-agent check (Core)

**Depends on:** none

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
      package var locate: @Sendable (OnboardingAgentChoice.Agent) async -> String? // resolved executable or nil
      package var help: @Sendable (OnboardingAgentChoice.Agent, String) async -> String? // nil = timed out
      package var test: @Sendable (String?) async -> OnboardingAgentTestResult    // provider or nil = configured
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

- [ ] **Step 1: Write the failing tests** (fake probes, counting calls):
  - `testForbiddenAgentIsNeverLocatedOrTested`: `allowed(.claude) == false` → `.forbidden`, `locate`/`test` call counts for claude are 0.
  - `testMissingAgentCostsNoRequest`: `locate(.codex) == nil` → `.notInstalled`, no `test("codex")`.
  - `testStatusFromTheTest`: ok → `.ready`; `errorCode "auth"` → `.signedOut`; `"policy"` → `.forbidden`; `"timeout"` → `.failed(failureMessage(.claude, code: "timeout", error: …))`.
  - `testBothInstalledAreTestedInParallel`: each fake `test` waits on a shared gate that opens only when both have been entered; `run` completes (no deadlock).
  - `testInstallKindFromLocatedPath`: locate returns `"/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js"` → `installs[.codex] == .init(path: that, kind: .npm)`.
  - `testHelpProbeOnlyForSignedOut`: help is called for a `.signedOut` agent only; a help text without a `login` row → `outdated == [.claude]`; `help` returning nil (timeout) → not outdated.
  - `testOtherProviderWorking`: configured `"ollama"`, `test(nil)` ok → `otherProvider == "Ollama"`, no agent located or tested.
  - `testOtherProviderFailingChecksTheAgents`: configured `"ollama"`, `test(nil)` fails with `"transport"` → `otherProviderFailure` set, both agents checked.

- [ ] **Step 2: Run to see them fail** — `make test-swift FILTER=OnboardingAgentCheckTests` → FAIL (types missing).

- [ ] **Step 3: Implement `OnboardingAgentCheck.run`.** Use `withTaskGroup` over `Agent.allCases`. The provider display name comes from `AIModelCatalog.shared.displayName(id)`. If that is not in Core, pass a `displayName` closure in `OnboardingAgentProbes` and state so in the commit. Run the other-provider test first, and skip the agents when it passes.

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

**Depends on:** Task 1, Task 2

**Files:**
- Modify: `WatchtowerDesktop/Sources/App/OnboardingGoalsModel+Production.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/WatchtowerAIService.swift` (add a non-throwing result call)
- Rename + generalise: `OnboardingClaudePathConfig.swift` → `OnboardingAgentPathConfig.swift` (`save(_ path:, for agent:, configPath:)`, key `agent.pathKey`)
- Modify: `WatchtowerDesktop/Sources/App/AppState+Chat.swift:48` (comment: the switch now comes from Continue)
- Test: `WatchtowerDesktop/Tests/Core/OnboardingAgentPathConfigTests.swift` (move the existing claude_path tests, add codex), `WatchtowerDesktop/Tests/Core/WatchtowerAIServiceTests.swift`, `WatchtowerDesktop/Tests/OnboardingAgentProbesTests.swift`

**Interfaces:**
- Consumes: Task 1 `OnboardingAgentProbes`, `OnboardingAgentTestResult`.
- Produces: `WatchtowerAIService.testResult(provider: String?) async -> OnboardingAgentTestResult` (decodes `ok`/`error`/`error_code` from `ai test --json`; launch failure → `ok:false, errorCode:"launch"`); `OnboardingAgentProbes.production(config: ConfigService, policy: ManagedPolicy) -> OnboardingAgentProbes`; `OnboardingAgentPathConfig.save(_:for:configPath:)`.

- [ ] **Step 1: Failing tests:**
  - `testTestResultDecodesErrorCode` (`{"ok":false,"provider":"claude","model":"m","error":"x","error_code":"auth"}` → `errorCode == "auth"`); `testTestResultOk`.
  - `testSavesCodexPath` / `testKeepsOtherLines` for `codex_path` (mirror the claude ones).
  - `testLocatePrefersConfiguredPathAndResolvesSymlinks` (temp dir: a symlink `bin/codex` → `pkg/codex.js`, configured path = the symlink → returns the resolved target).
  - `testLocateIsFreshEachCall` (file absent → nil; create it; same probe → path).
  - `testHelpProbeTimeoutCountsAsSupported` (a stub script that sleeps 10 s → `help` returns nil within ~5 s; the check treats nil as supported, per Task 1).
  - `testHelpRunsTheRightArguments` (stub prints its argv: `auth --help` for claude, `login --help` for codex).

- [ ] **Step 2: Run** — `make test-swift FILTER='WatchtowerAIServiceTests|OnboardingAgentPathConfigTests|OnboardingAgentProbesTests'` → FAIL.

- [ ] **Step 3: Implement.** `locate`: the configured `claude_path`/`codex_path` if executable, else `Constants.findInPath(name)`, then `URL(fileURLWithPath:).resolvingSymlinksInPath().path`. `help`: `Process` with the login env from `Constants.resolvedEnvironmentAsync()`, 5 s timeout, the process group reaped on timeout. `allowed`: `ManagedPolicy.providerAllowed`. Wire `checkAgents` and `saveAgent` (`config set workbench.default_agent` when different, then `config set ai.provider`).

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
      var view: LocalProcessTerminalView { get }
      func start(command: String)   // runs `/bin/zsh -lc <command>` in a new process group; a start failure calls onExit(127)
      func stop()                    // SIGTERM to the group; onExit is NOT called again after stop
      var isRunning: Bool { get }
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
- Test: `WatchtowerDesktop/Tests/OnboardingGoalsStepTests.swift`; `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+OnboardingAgent.swift` (add `onboarding-step-live-none`, `-signed-out`, `-both-ready` shots of the real `OnboardingGoalsStepView` on an `AppState(workbenchDefaults: AppState.isolatedDefaults)` seeded via a fake `checkAgents`)

**Interfaces:**
- Consumes: Task 2 model API, Task 3 `OnboardingAgentPathConfig.save(_:for:configPath:)`, Task 4 `OnboardingSignInSession`.

- [ ] **Step 1: Failing tests:** `testAutoOpensSignInOnce` (model with claude signed out → the step's coordinator starts a session with `agentChoice.terminalCommand`, and a second render does not start another); `testLeavingTheStepStopsSignIn` (running session → `onDisappear`/Cancel → `stop()` called, model `signIn == .ended(nil)`); `testPickingTheOtherTileStopsSignIn`; `testChooseExecutableSavesThePickedAgentsPath`.

- [ ] **Step 2: Run** — `make test-swift FILTER=OnboardingGoalsStepTests` → FAIL.

- [ ] **Step 3: Implement.** A small `@MainActor` coordinator owned by the view holds the `OnboardingSignInSession?`. `.onChange(of: model.agentChoice.signInToOpen)` starts it. `NSApplication.didBecomeActiveNotification` → `model.windowBecameActive()`. Choose the executable = `NSOpenPanel` → `OnboardingAgentPathConfig.save` → `runAgentCheck()`. The section's `signInTerminal` returns `OnboardingSignInTerminal(session:)`.

- [ ] **Step 4: Run** the filter, then `DESKTOP_SHOTS_DIR=<scratch> swift test --filter DesignShotsTests/testOnboardingAgentShotsRender` and compare the `onboarding-step-live-*` PNGs with `onboarding-agent-none`, `-signed-out`, `-both-ready` by eye (light and dark). Any difference is fixed or explained in the commit.

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
- [ ] By hand on this Mac (spec Acceptance H items 4, 5, 6): start the step with Claude signed out (`claude auth logout` in a throwaway `HOME`/`CLAUDE_CONFIG_DIR`), watch the terminal open and close, and the tile turn Ready.
- [ ] Umbrella PR `feature/onboarding-agent-choice` → `main` with `/local-review` (debate-review on the final PR).
