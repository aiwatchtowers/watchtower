# Background AI Consent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Watchtower runs no background AI unit (daemon AI phase, background automation run, backfill chunk, spec-review relaunch, or a process one of them starts) until the owner, or the organization's `AllowBackgroundAI` profile, has said yes on one consent screen. Sync and every owner gesture keep running.

**Architecture:** A new leaf Go package `internal/aiconsent` resolves the effective state from `config.yaml` `ai.background_runs` and the forced `AllowBackgroundAI` policy key, and gives every model call an **origin** (`owner` | `background`, admitted or not). Background units check the state before they start: the daemon's `aiPhase` helper, `builtin.Runner.RunSlot`, the scheduler, the event bus, the executor's claim and the spec-review sweep. A per-call backstop in every leaf wrapper of every process refuses an unadmitted background call. The only writer of the answer is `watchtower ai background allow|pause`. The Desktop resolves the same state through a Swift twin (one shared fixture), shows the consent screen as onboarding's last step or as a one-time upgrade sheet, and shows the paused state in Settings, readiness empty states, Home and Automations. The phone gets one line from a new optional heartbeat key.

**Tech Stack:** Go 1.26 (cobra CLI, viper config writer, `go/ast` static checker, `testing/synctest`), SwiftUI + Observation (WatchtowerCore, DesignKit, DesignShots), WatchtowerKit (`WatchtowerSync`, `WatchtowerKit`), the iPhone app (`WatchtowerMobile`).

**Spec:** `docs/superpowers/specs/2026-11-17-background-ai-consent-design.md` (approved in ask #1471; decisions D1–D20 and the §13 contracts BGAI-01..03, POLICY-01/02/03, AUTO-10 approved in ask #1452 — final). Mockups: `docs/design/mockups/background-ai-consent/` (DesignShot scenes `ai-consent-*`).

**Base.** This branch is behind `main`. Before Task 1, rebase `feature/1886-background-ai-consent` onto `origin/main`. Every path and name below was checked against `origin/main` on 2026-11-18.

## Global Constraints

- The rule, for code comments and docs: **background = started by a timer, a sync cycle or an event; not by the owner's own gesture.**
- Config key `ai.background_runs`: `allowed` | `paused` | absent. Any other value reads as absent (logged once). Its only writer is `watchtower ai background allow|pause`. `config set ai.background_runs …` is refused with the text `use "watchtower ai background allow|pause"`. No consent date is stored.
- MDM key `AllowBackgroundAI` (boolean, forced only). Wrong type = `false`. `true` stands in for an owner who has not answered and never overrides the owner's `paused`. `false` = paused, switch locked, `allow` refused before writing.
- Effective state table: spec §3.2, verbatim, in the shared fixture `internal/aiconsent/testdata/consent_cases.json`.
- Env names: `WATCHTOWER_AI_ORIGIN=background`, `WATCHTOWER_AI_ADMITTED=<unit id>`; the run marker stays `WATCHTOWER_AUTOMATION_RUN_ID`.
- Background triggers: `schedule`, `catch_up`, `event`, `sync`. Owner triggers: `manual`, `button`, `dry_run`, `reply`.
- A paused executor claim ends the run `cancelled`, `error_kind = 'cancelled'`, error exactly `Background AI is paused`. No migration anywhere in this plan.
- Daemon log line, once per state change: `background AI: paused (not answered yet) — sync keeps running; allow it in Watchtower or with "watchtower ai background allow"`; reason `owner` says `paused by you`, `organization` says `turned off by your organization`.
- The plan-limit read (plan-usage poller, Codex rate-limit read) is never gated (D17).
- No telemetry: the only trace is `watchtower.log` (D16).
- Every write of `config.yaml` (Go `config set`/`setConfigKey`/`setAIConfigKey`/the schema-format bump, Swift `ConfigService.save`) re-reads and writes under an exclusive `flock(2)` on `<config.yaml>.lock` (spec §11; Decision 7).
- UI strings live in models with tests (`BackgroundAIConsentCopy` in WatchtowerCore; the phone's `BackgroundAIConsentCopy` in WatchtowerKit). The exact strings are spec §5.1, §6.1–§6.5. They already sit in `WatchtowerDesktop/Tests/DesignShots/BackgroundAIConsentMockCopy.swift` and move from there unchanged.
- Colours only through `Tone` (`WatchtowerKit/Sources/WatchtowerDesign/Tone.swift`); error lines use `Tone.error`. Desktop screens are built from `WatchtowerDesktop/Sources/DesignKit/` and checked against the named `ai-consent-*` mockups.
- Tests never wait on wall-clock time: injected clocks, `aiconsent.Reader` fakes, `testing/synctest`. A test that spawns a process kills its process group and waits for it in `t.Cleanup`.
- Inventory: no existing guard is weakened, renamed or split. New BGAI guards and the POLICY-01/02/03 and AUTO-10 amendments go in with a Changelog entry naming ask #1452.
- Public repo: placeholder ids only, no local absolute paths, English only.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Inner loop per task as named in its Verify step; `make lint-diff` for Go, `make lint-swift` for Swift (lint-diff never checks Swift). The controller runs the full gate (`make test`, `make test-swift`, `make lint-all`, `make mobile-test`) once at the end.

## Review Focus

1. **The owner's own chat while paused, hosted by the daemon.** `withChatAndHub` (`cmd/sync.go`) runs the main chat engine and the Go hub inside `sync --daemon`, whose process default is `background`. Each owner turn runs in its own `watchtower ai session` child (`chatengine.execStart`/`listenStart`), and that child must start with owner origin. Anything the hub or the engine would ever run in-process without a per-request owner mark must stay gated. Task 4 `TestBGAI02_ChatEngineChildIsOwner`, `TestBGAI02_HubAndChatEngineMakeNoInProcessModelCall`.
2. **Run Now of an AI built-in while paused.** A built-in's Run Now executes only at its slot (`RunSlot` → `TakeQueuedBuiltinRun`), so a slot skip placed "before its row" would swallow an owner gesture. Task 7 `TestRunner_PausedStillRunsQueuedRunNow`.
3. **A reaction command while paused.** `dispatchReaction` queues a **`sync`**-trigger Reactions run, which the executor backstop would cancel. Task 5 `TestDaemon_ReactionCommandsRunWhilePaused` and Task 6 `TestExecutor_OwnerStartedSyncRunPasses`.
4. **A hand-edited `config.yaml`** (`ai.background_runs: yes`, or a YAML syntax error) must read as paused, log once, and never crash the daemon or the CLI. Task 2 `TestCurrent_UnknownValueReadsAbsent`, `TestCurrent_UnreadableConfigIsPaused`.
5. **A Desktop-only install with no `config.yaml` yet** answering the onboarding step: `allow` must create the file, not fail. Task 3 `TestAIBackground_AllowCreatesMissingConfig`.

---

## Agent decisions (resolutions of spec gaps, within the approved decisions)

Source "agent, plan" = written with the plan; "agent, review #1484" = changed or added after the plan review.

1. **Run Now at a slot (D2, BGAI-02 vs §4.2 "Slots").** The paused check in `runEntry` sits after `TakeQueuedBuiltinRun`: a queued manual run executes; with none, the built-in is skipped as `SkippedPaused` before its gate or any run row. Nothing is written in the skip path. Source: agent, plan.
2. **Reactions (D3).** Reaction runs are `sync`-trigger runs queued by `dispatchReaction`. `phaseReactionCommands` marks its ctx `aiconsent.WithOwnerStarted` (one mark per poll of the owner's reactions). The executor's inline path honours an owner-started ctx before it looks at the trigger. Source: agent, plan.
3. **Owner work hosted by the daemon (§2.2): per request, never on a root.** Recon (2026-11-18): the chat engine runs every turn in a spawned `watchtower ai session` child (`internal/chatengine/session.go` `execStart`, `reattach.go` `listenStart`). The engine's only ticker drives a turn already started. `internal/hub` and `internal/chatengine` import no model leaf (`internal/ai`, `internal/digest`, `internal/agentloop`, `internal/transport`, `internal/claude`, `internal/codex`), and phone recordings go to the Desktop's transcriber. No root context is marked. The two chat spawns build their env with `aiconsent.OwnerEnv(os.Environ())`, because each serves one owner request. Every other in-process path in the daemon keeps the `background` default, so it stays gated (fail closed). A future in-process model call that serves an owner request marks that request's ctx `WithOwnerStarted` at its handler. Two static guards pin the boundary: `TestBGAI02_HubAndChatEngineMakeNoInProcessModelCall` and the spawn checker extended to `internal/chatengine` and `internal/hub`. Cost if wrong: an unmarked owner call in the daemon is refused while paused (visible, fail-closed), never a silent background run. Source: agent, review #1484 (replaces the plan's root marking).
4. **Where `UsesAI` per primitive lives (§4.2).** `automations.Manifest.UsesAI` needs it, and `builtin` imports `automations`. The declaration is `automations.PrimitiveUsesAI`, beside `BuiltinPrimitiveNames`. `TestBuiltin_EveryPrimitiveDeclaresAI` lives in `internal/automations/builtin` as the spec names it. Source: agent, plan.
5. **The Desktop needs the same rule** for the Automations notice and chip. This is a dual path with the shared fixture `internal/automations/testdata/uses_ai_cases.json`, run by Go `TestManifest_UsesAISharedFixture` and Swift `AutomationAIUseTests.sharedFixture`. Source: agent, plan.
6. **Policy field.** The spec's `Policy.AllowBackgroundAI` is `Policy.Keys.AllowBackgroundAI *bool` (`Keyset`). Source: agent, plan.
7. **The config file lock (§11), followed as written.** No lock exists today: `writeConfigAtomic` writes a temp file and renames it, and `ConfigService.save` re-reads and writes. The plan adds one exclusive `flock(2)` on `<config.yaml>.lock`, taken around read-modify-write by every Go writer (`withConfigLock` in `cmd/config.go`) and by `ConfigService.save` (`ConfigFileLock` in WatchtowerCore). Without it, a Desktop save racing the CLI could write back a snapshot taken before `allow`, and the answer would be lost. Readers take no lock (the rename is atomic). Source: agent, review #1484 (replaces "last write wins").
8. **Test homes that do not exist.** `HomeContent` is a View, so the Home card model is `HomeBackgroundAICard` (Core), tested in `HomeBackgroundAICardTests`. `GettingReadyPolicyTests` is the existing `GettingReadyTests`. `HeartbeatPayloadTests` is new. The phone's Home is the **Now** tab (`NowView`). Source: agent, plan.
9. **Fail-closed default for consent readers.** The daemon, `Scheduler`, `Bus`, `Executor` and `builtin.Runner` take an optional injected `aiconsent.Reader`. A nil reader reads `aiconsent.Current`, never "ungated", so a component built anywhere is gated. `aiconsent.Current()` with no config path reads as paused. The test packages that build these components call `aiconsenttest.AllowByDefault()` in `TestMain` (`cmd`, `internal/daemon`, `internal/automations`, `internal/automations/builtin`, plus any other package whose existing tests go red only because of the default). Their assertions stay unchanged. `TestBGAI01_NilReaderFailsClosed` pins the default. Source: agent, review #1484 (replaces "nil = ungated").
10. **The reviewer child (D20).** The reviewer agent is not called through a generator leaf, so `runSpecReviewRun` calls `aiconsent.Check` before `specreview.Run` claims the row. Refused → the row stays queued. Source: agent, plan.
11. **Desktop launch sites carry an origin, guarded statically.** Recon (2026-11-18) re-checked every Desktop CLI launch of a model-running command (`BriefingViewModel`, `DayPlanViewModel`, `CatchUpViewModel`, `CoachCenter.runNow`, `TargetNextStepService`, `TargetSuggestLinksService`, `TargetExtractService`, `TrackComposeService`, `TrackScanService`, `MeetingTopicsExtractService`, `MeetingRecapService`, `TranscriptSaveService`, `TranscriptChaptersCenter`, `TranscriptNotesCenter`, `MeetingPrepViewModel`, `WorkbenchCLI` session start and spec-review start). All of them follow a gesture: a click, opening a view the owner chose, or a recording the owner made (spec §2.2). The Desktop's timers (`CoachCenter` and `CatchUpViewModel` polls, `SessionBackgroundProber`, `SessionCleanupCenter`, `SessionReportCenter`, `DaemonManager`, `ConfigService` routing status) run only commands that call no model. The plan adds `CLIRunner` origin support (`.background` sets `WATCHTOWER_AI_ORIGIN=background`). The guard `DesktopModelLaunchSitesTests` fails on any Desktop file that launches a command from the shared list `internal/aiconsent/testdata/model_commands.json` without a classified entry (owner + the gesture, or background + `origin: .background`). Go `TestModelCommands_ExistInCLI` keeps that list's paths real. The list is hand-kept: a new model-running command must be added to it, and the feature note says so. The hub's own spawns are covered by the Go spawn checker (Decision 3). Source: agent, review #1484.
12. **An answer given outside the Desktop** (`watchtower ai background allow|pause` in a terminal, or a profile change). The Desktop re-reads `config.yaml` on `NSApplication.didBecomeActiveNotification`, the same trigger `ManagedPolicyCenter` uses, and after its own CLI call. `BackgroundAIConsentRefresher` (Core) owns this. An upgrade sheet that is open closes once `prompt` turns false. A sheet opened from Settings, Home or an empty state closes once the state turns `allowed`. No file watcher is added: the owner who answered in a terminal comes back to the app, and that activation re-reads. Source: agent, review #1484.

---

## File map

| Area | Files |
|---|---|
| Consent core (Go) | Create `internal/aiconsent/{aiconsent.go,current.go,origin.go,aiconsent_test.go,origin_test.go,testdata/consent_cases.json}` |
| Policy | `internal/policy/policy.go`, `testdata/policy_cases.json`, `policy_test.go`, `collision_test.go`; Swift `WatchtowerCore/Models/ManagedPolicy.swift`, `Views/Settings/OrganizationPolicySection.swift`, `Tests/Core/ManagedPolicyTests.swift` |
| CLI | Create `cmd/ai_background.go`, `cmd/ai_background_test.go`, `internal/aiconsent/testdata/model_commands.json`; modify `cmd/config.go` (+ `withConfigLock`), `cmd/status.go`, `cmd/root.go` |
| Leaves | `cmd/provider_policy.go`, `internal/agentloop/client.go`, `cmd/automations_backends.go`, `internal/chatengine/{session.go,reattach.go}` (owner env for turn children) |
| Daemon | Create `internal/daemon/ai_consent.go`; modify `daemon.go`, `media.go`, `coach.go`, `history_backfill.go`, `spec_review_sweep.go`, `morning_brief.go`/`builtin_slots.go` (ctx only) |
| Automations | `internal/automations/{manifest.go,scheduler.go,bus.go,executor.go,sdk_shell.go}`, `builtin/{registry.go,runner.go,watchslot.go}`, `internal/db/automation_runs.go`, `testdata/uses_ai_cases.json` |
| Spawns | `cmd/workbench_spec_review_launch.go`, `cmd/workbench_spec_review.go`, `cmd/sync.go` (`SetSpecReviewLaunch`), create `internal/daemon/bgai_spawn_test.go` + `testdata/spawns/` |
| Hub/phone | `internal/hub/wire/payloads.go`, `wire/contract_test.go` (+ its fixture), `internal/hub/slices/heartbeat.go`, `internal/hub/runtime.go`; Kit `WatchtowerSync/Relay/HeartbeatPayload.swift`, create `WatchtowerKit/Sources/WatchtowerKit/Copy/BackgroundAIConsentCopy.swift`; phone `Features/Now/NowView.swift` |
| Desktop | Create `WatchtowerCore/Models/BackgroundAIConsent.swift`, `WatchtowerCore/Services/BackgroundAIConsentCopy.swift`, `BackgroundAIConsentModel.swift`, `BackgroundAIConsentPrompt.swift`, `BackgroundAISettingsPresentation.swift`, `HomeBackgroundAICard.swift`, `Automations/AutomationAIUse.swift`; `Views/Onboarding/BackgroundAIConsentView.swift`, `Views/Settings/BackgroundAISettingsSection.swift`; modify `Services/ConfigService.swift`, `App/AppState.swift`, `OnboardingStateMachineV2.swift`, `Readiness.swift`, `FeatureReadiness.swift`, `GettingReadyPolicy.swift`, `Views/Components/FeatureEmptyState.swift`, `Views/Home/HomeView.swift`, `Views/Settings/ProviderSettings.swift`, `Automations/AutomationListSections.swift`, the Automations list view |
| Desktop launch guard | `WatchtowerCore/Services/CLIRunner.swift` (origin), create `Tests/Core/DesktopModelLaunchSitesTests.swift`, `Tests/Core/Support/DesktopModelLaunchSites.swift` |
| Docs | `docs/inventory/{background-ai.md,README.md,policy.md,automations.md,features.md,history-backfill.md}`, `docs/features/*`, `docs/guide/*`, `CLAUDE.md`, `docs/examples/watchtower-policy.mobileconfig` |

## Lanes

- **Lane G1 (Go core, serial):** Task 1 → Task 2 → Task 3.
- **After Task 2, in parallel:** Lane G2 Task 4; Lane G3 Task 5; then Task 8 after Tasks 4 and 5; Lane G4 Task 6 → Task 7; Lane H Task 10 → Task 11 (phone); Lane S Task 12 → Task 13 → {Task 14, Task 15} (two lanes).
- **Task 16** after Task 6 and Task 13. **Task 18** (Desktop launch guard) after Task 3 and Task 12. **Task 9** (full-cycle guards and the BGAI inventory) after Tasks 3, 5, 7 and 8. **Task 17** (docs and guide) last.
- Lanes never share a working tree. Swift lanes use their own `.build` copies (CLAUDE.md, cache hygiene).

---

### Task 1: `AllowBackgroundAI` policy key (Go + Swift twin)

**Depends on:** none

**Files:**
- Modify: `internal/policy/policy.go` (const `KeyAllowBackgroundAI = "AllowBackgroundAI"`, appended to `Keys`; `Keyset.AllowBackgroundAI *bool \`json:"AllowBackgroundAI"\``; `Normalize` → `n.boolean(KeyAllowBackgroundAI, v, false)`)
- Modify: `internal/policy/testdata/policy_cases.json`, `internal/policy/policy_test.go` (`TestPolicy01_WrongTypesFailClosed` table gains the key), `internal/policy/collision_test.go` (key list, if enumerated by hand)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/ManagedPolicy.swift` (`case allowBackgroundAI = "AllowBackgroundAI"`, `allowBackgroundAI: Bool?`), `WatchtowerDesktop/Tests/Core/ManagedPolicyTests.swift` (`goShape` gains the key)
- Modify: `WatchtowerDesktop/Sources/Views/Settings/OrganizationPolicySection.swift` (one row: "Background AI" — "Allowed by your organization" / "Turned off by your organization")
- Modify: `docs/examples/watchtower-policy.mobileconfig`, `docs/guide/reference/organization-policy.md`, `docs/inventory/policy.md` (POLICY-01 key list and most-restrictive value `false`; POLICY-02 fixture rows; POLICY-03 exception text from spec §13 verbatim; Changelog entry "<date> (board #1886, ask #1452): …")

**Interfaces:**
- Produces: `policy.KeyAllowBackgroundAI`, `policy.Keyset.AllowBackgroundAI *bool`, Swift `ManagedPolicy.allowBackgroundAI: Bool?`.

- [ ] **Step 1: Failing tests.** Add fixture rows to `policy_cases.json`: `{"AllowBackgroundAI": true}` → `true`, `false` → `false`, `"yes"` → `false` with error `{key: AllowBackgroundAI, problem: wrong_type}`, absent → `null`. Add `"AllowBackgroundAI": "1"` to the wrong-type table of `TestPolicy01_WrongTypesFailClosed` expecting `false`.
- [ ] **Step 2: Run** `go test ./internal/policy` → FAIL (unknown key).
- [ ] **Step 3: Implement** the Go key. Then the Swift twin, so `ManagedPolicyTests.sharedFixture` reads the same rows.
- [ ] **Step 4: Verify** `go test ./internal/policy` PASS (`TestPolicy02_SharedFixture`, `TestPolicy01_*`, `TestPolicy01_KeysNeverCollideWithAppDefaults`). Run `make test-swift FILTER='ManagedPolicyTests|OrganizationPolicy'` PASS, then `make lint-swift`, `make lint-diff`, and `go test ./docs/guide`.
- [ ] **Step 5: Commit** `feat(policy): AllowBackgroundAI key (#1886)`.

---

### Task 2: `internal/aiconsent` — state, reading, origin, backstop check

**Depends on:** Task 1

**Files:**
- Create: `internal/aiconsent/aiconsent.go` (types, `Resolve`, `ParseAnswer`, `LogLine`), `current.go` (config read with mtime cache), `origin.go` (context marks, process origin, `Check`, `ChildEnv`)
- Create: `internal/aiconsent/aiconsent_test.go`, `origin_test.go`, `testdata/consent_cases.json`
- Create: `internal/aiconsent/aiconsenttest/aiconsenttest.go` (`AllowByDefault`, through an unexported-by-convention hook `aiconsent.SetCurrentOverrideForTest`; the hook's doc says tests only, and `TestOverrideHookOnlyInTests` greps non-test Go files for callers and allows only `aiconsenttest`)

**Interfaces (Produces — every later Go task uses these exact names):**
```go
type Effective string // EffectiveAllowed = "allowed", EffectivePaused = "paused"
type Reason string    // ReasonUnanswered = "unanswered", ReasonOwner = "owner", ReasonOrganization = "organization"
type Answer string    // AnswerNone = "", AnswerAllowed = "allowed", AnswerPaused = "paused"
type State struct {
    Effective Effective; Reason Reason; Answer Answer; Policy *bool
    Prompt, Locked bool
}
func (s State) Allowed() bool
func Resolve(answer Answer, policy *bool) State      // pure, spec §3.2
func ParseAnswer(raw string) (a Answer, known bool)  // "" → (AnswerNone, true); unknown → (AnswerNone, false)
func LogLine(s State) string                         // the Global Constraints daemon line; "" when allowed
type Reader func() State
func SetConfigPath(path string)
func Current() State                                 // config (mtime cache) + policy.Current()
var ErrPaused = errors.New("Background AI is paused")
type Origin int // OriginOwner, OriginBackground
func WithOwnerStarted(ctx context.Context) context.Context
func WithAdmitted(ctx context.Context, unit string) context.Context
func OriginOf(ctx context.Context) (o Origin, admitted bool)
const EnvOrigin = "WATCHTOWER_AI_ORIGIN"; const EnvAdmitted = "WATCHTOWER_AI_ADMITTED"
const RunMarkerEnv = "WATCHTOWER_AUTOMATION_RUN_ID" // equals automations.RunEnvMarker (pinned in Task 6)
func InitProcess(role string, getenv func(string) string)
func SetRunTriggerLookup(f func(runID int64) (trigger string, err error))
func BackgroundTrigger(trigger string) bool          // schedule|catch_up|event|sync
func Check(ctx context.Context) error                // CheckWith(ctx, Current)
func CheckWith(ctx context.Context, r Reader) error
func ChildEnv(ctx context.Context) []string          // [EnvOrigin=background(, EnvAdmitted=<unit>)] for a background ctx, nil for owner
func OwnerEnv(env []string) []string                 // env without EnvOrigin/EnvAdmitted: a spawn that serves one owner request
// package aiconsent/aiconsenttest (test-only import):
func AllowByDefault()                                // Current() returns allowed-by-owner until the process ends; for TestMain
```
Rules: the package is a leaf. It imports only `internal/policy` and the stdlib plus `gopkg.in/yaml.v3`, and never `internal/db` or `internal/config`. `OriginOf` order: the ctx mark wins. With no mark, the process default applies: role `daemon` → background; else `EnvOrigin=background` → background, with `EnvAdmitted` non-empty → admitted; else `RunMarkerEnv` set → the trigger read once via the lookup (`BackgroundTrigger` → background; a lookup error → background, fail closed); else owner. `CheckWith` returns `ErrPaused` only for a background, unadmitted call while `!r().Allowed()`. `Current` stats the config each call and re-parses only on an mtime or size change. A read or parse failure gives `AnswerNone` and is logged once per distinct failure. No path set → paused.

- [ ] **Step 1: Write `testdata/consent_cases.json`** with the eight rows of spec §3.2: `{name, answer: "allowed"|"paused"|"bogus"|null, policy_raw: true|false|"yes"|absent, want: {effective, reason, prompt, locked}}`. The "wrong type" row uses `"yes"`, and the test runs it through `policy.Normalize` first.
- [ ] **Step 2: Failing tests** (`aiconsent_test.go`):
  - `TestBGAI03_SharedFixture`: every row → `Resolve(ParseAnswer(answer), policy.Normalize(raw).Keys.AllowBackgroundAI)` matches `want`.
  - `TestCurrent_UnreadableConfigIsPaused`: a config with invalid YAML → `Effective == paused`, `Reason == unanswered`.
  - `TestCurrent_UnknownValueReadsAbsent`: `ai: {background_runs: yes}` → `Answer == ""`, paused; the log captures one line after two calls.
  - `TestCurrent_RereadsOnlyOnMtimeChange`: count parses through an unexported `parseHook`. Two calls → 1 parse. Rewrite the file with `os.Chtimes` to a later mtime → 2 parses.
  - `TestCheck_NoopOutsideTheDaemon`: role `"cli"`, no env, reader paused → `nil`.
  - `TestCheck_OwnerStartedPasses`: role `daemon`, `WithOwnerStarted`, paused → `nil`.
- [ ] **Step 3: Failing tests** (`origin_test.go`): `TestOrigin_ContextBeatsProcess` (daemon role + `WithOwnerStarted` → owner); `TestOrigin_EnvMarksBackground` (role `cli`, `EnvOrigin=background` → background, unadmitted; plus `EnvAdmitted=run:7` → admitted); `TestOrigin_AutomationMarkerTakesRunTrigger` (marker `7`: a lookup returning `manual` → owner, `schedule` → background, an error → background); `TestCheck_AdmittedBackgroundPasses`; `TestChildEnv_BackgroundAndAdmitted` (owner ctx → nil; daemon ctx admitted `phase:digests` → both entries); `TestOwnerEnv_StripsOrigin`; `TestOverrideHookOnlyInTests`.
- [ ] **Step 4: Run** `go test ./internal/aiconsent` → FAIL.
- [ ] **Step 5: Implement** the three files. Process state lives in package vars set by `InitProcess`. Tests reset it through an unexported `resetForTest(t)` that restores it in `t.Cleanup`.
- [ ] **Step 6: Verify** `go test ./internal/aiconsent` PASS, then `make lint-diff`.
- [ ] **Step 7: Commit** `feat(aiconsent): consent state, origin and per-call check (#1886)`.

---

### Task 3: `watchtower ai background`, `config set` refusal, `status` line, process wiring

**Depends on:** Task 2

**Files:**
- Create: `cmd/ai_background.go`, `cmd/ai_background_test.go`
- Modify: `cmd/ai.go` (`aiCmd.AddCommand(aiBackgroundCmd)`), `cmd/config.go` (`runConfigSet` refusal; `knownConfigKeys` untouched; `func withConfigLock(configPath string, fn func() error) error` takes `syscall.Flock(LOCK_EX)` on `<configPath>.lock` (created `0600`) and wraps the read-modify-write of `setConfigKey`, `setAIConfigKey`, `runConfigSet` and the schema-format bump), `cmd/status.go` (one line), `cmd/root.go` (`Execute`: `aiconsent.InitProcess(role, os.Getenv)`; root pre-run: `aiconsent.SetConfigPath(<resolved config path>)` and `aiconsent.SetRunTriggerLookup(<reads automation_runs.trigger by id through a read-only db handle opened lazily>)`)

- Create: `internal/aiconsent/testdata/model_commands.json`: the CLI command paths that can call a model, as arrays (`["digest","generate"]`, `["briefing","generate"]`, `["day-plan","generate"]`, `["catchup","run"]`, `["coach","run"]`, `["targets","next-step"]`, `["targets","suggest-links"]`, `["targets","extract"]`, `["tracks","create"]`, `["tracks","scan"]`, `["meeting-prep"]` (every subcommand), `["ai","query"]`, `["ai","session"]`, `["workbench","session","start"]`, `["workbench","spec-review","start"]`, `["workbench","spec-review","run"]`, plus every other command whose RunE builds a generator or AI client, found by `grep -ln 'cliPooledGenerator\|cliGenerator\|newAIClient\|checkedGenerator\|cliBoundedGenerator' cmd/*.go`)

**Interfaces:**
- Consumes: Task 2.
- Produces: the CLI verbs (spec §9); `withConfigLock`; `model_commands.json` (read by Task 18). `aiBackgroundStatusJSON{Effective string "effective"; Reason string "reason"; Answer string "answer"; Policy *bool "policy"}`. `consentText(agent, reserve string, pollMinutes, backfillDays int) string` holds the Go copy of the spec §5.1 text. `var signalDaemonFn = signalSyncNow` and `var stdinIsTTY func() bool` are test seams. `allow` writes through `setConfigKey(configPath, "ai.background_runs", "allowed")`.

- [ ] **Step 1: Failing tests** (`cmd/ai_background_test.go`, temp config via `t.TempDir()`, policy through the `policytest` seam):
  - `TestAIBackground_StatusJSONKeys`: the keys are exactly `effective, reason, answer, policy`. An unanswered install gives `"paused","unanswered","",null`.
  - `TestAIBackground_AllowNeedsYesWithoutTTY`: no TTY, no `--yes` → error containing `run with --yes to confirm`, config unchanged.
  - `TestAIBackground_AllowRefusedByPolicy`: policy `false` → error, file bytes unchanged, no signal.
  - `TestAIBackground_AllowWritesAndSignals`: `--yes` → `ai.background_runs: allowed`, `signalDaemonFn` called once. A signal error still exits 0.
  - `TestAIBackground_AllowCreatesMissingConfig`: no `config.yaml` → created with the key.
  - `TestAIBackground_PauseNeverRefused`: under policy `false` → writes `paused`, no signal.
  - `TestAIBackground_TTYPromptDefaultsNo`: TTY, input `"\n"` → nothing written. Input `"y\n"` → written. The printed text contains the spec §5.1 title and the Claude plan line for `ai.provider: claude`.
  - `TestConfigSet_RefusesBackgroundRunsKey`: `config set ai.background_runs allowed` (any case) → error containing `watchtower ai background allow|pause`, nothing written.
  - `TestStatus_BackgroundAILine`: the four spec §9 lines for unanswered, allowed, owner-paused and organization.
  - `TestConfigLock_ExcludesSecondHolder`: while `withConfigLock` runs its fn, a second `flock(LOCK_EX|LOCK_NB)` on the same lock file fails with `EWOULDBLOCK`; after it returns, the second lock succeeds.
  - `TestSetConfigKey_LocksAroundReadAndWrite`: a recording `lockConfig` seam sees the order `lock, read, write, unlock` for `setConfigKey`, `setAIConfigKey` and `runConfigSet`.
  - `TestModelCommands_ExistInCLI`: every path in `model_commands.json` resolves through `rootCmd.Find`, and every command file the grep above finds is listed.
- [ ] **Step 2: Run** `go test ./cmd -run 'TestAIBackground|TestConfigSet_Refuses|TestStatus_BackgroundAI'` → FAIL.
- [ ] **Step 3: Implement** the verbs, the refusal (before the type parse in `runConfigSet`), the status line and the root wiring.
- [ ] **Step 4: Verify** with `go test ./cmd -run 'TestAIBackground|TestConfigSet|TestConfigLock|TestSetConfigKey|TestModelCommands|TestStatus|TestCLIAudit|InitTestTemplate|LLMUSAGE|LLMTRANSPORT'`, then `go test ./internal/aiconsent`, then `make lint-diff`. All PASS.
- [ ] **Step 5: Commit** `feat(cli): watchtower ai background allow|pause|status (#1886)`.

---

### Task 4: Per-call backstop in every leaf; chat-turn children run as owner

**Depends on:** Task 2

**Files:**
- Modify: `cmd/provider_policy.go` (`policyCheckedGenerator.Generate`/`GenerateWithImage`, `policyCheckedProvider.Query`/`QuerySync`, `policyCheckedBackend.Turn`: `aiconsent.Check(ctx)` **before** `providers.Allowed`; a refused `Query` returns `newRefusedProvider(aiconsent.ErrPaused)`)
- Modify: `internal/agentloop/client.go` (`Query`, `QuerySync` → `aiconsent.Check(ctx)` first)
- Modify: `cmd/automations_backends.go` (`cliAgentRunner.Run`, `runtimeBAgentRunner.Run`: `aiconsent.Check(ctx)` before spawning; refused → `automations.PolicyError(aiconsent.ErrPaused)`-style error with nothing spawned or metered)
- Modify: `internal/chatengine/session.go` `execStart` and `internal/chatengine/reattach.go` `listenStart`: `cmd.Env = aiconsent.OwnerEnv(os.Environ())` (each spawn serves one owner turn; Decision 3). `withChatAndHub` is **not** changed: no root ctx is marked.
- Create: `internal/chatengine/owner_env_test.go`, `internal/hub/bgai_boundary_test.go`
- Tests: `cmd/provider_policy_test.go` (or a new `cmd/ai_consent_leaf_test.go`), `internal/agentloop/client_test.go`

**Interfaces:**
- Consumes: `aiconsent.Check`, `ErrPaused`, `OwnerEnv`, `InitProcess`.
- Produces: `aiconsent.ErrPaused` surfaces from every leaf. Callers detect it with `errors.Is`.

- [ ] **Step 1: Failing tests.**
  - `TestPolicyCheckedGenerator_RefusesBackgroundOriginInAnyProcess`: `InitProcess("cli", env{EnvOrigin: background})`, a paused reader through the package seam, a counting fake inner → `errors.Is(err, aiconsent.ErrPaused)`, 0 inner calls. The same with `EnvAdmitted` set → 1 call.
  - `TestBGAI02_TypedCommandNotGated`: `InitProcess("cli", empty env)`, paused → the `digest generate` generator chain (`cliPooledGenerator` with a fake transport registered for the test provider) calls the model once.
  - `TestBGAI02_ChatEngineChildIsOwner` (`internal/chatengine`): with `WATCHTOWER_AI_ORIGIN=background` and `WATCHTOWER_AI_ADMITTED=x` set in the test process (`t.Setenv`), the `*exec.Cmd` that `execStart` and `listenStart` build has an `Env` without either name. Capture it through an unexported `newCmd` seam; nothing starts.
  - `TestBGAI02_HubAndChatEngineMakeNoInProcessModelCall` (`internal/hub`): `go/parser` over the non-test files of `internal/hub/...` and `internal/chatengine` → no import of `watchtower/internal/ai`, `/digest`, `/agentloop`, `/transport` (the LLM transport, not `internal/hub/transport`), `/claude` or `/codex`. The failure message says: mark the serving request `aiconsent.WithOwnerStarted` at its handler and update this test.
  - `TestBGAI02_DaemonUnmarkedCallStaysGated`: role `daemon`, paused, a plain `context.Background()` through `policyCheckedGenerator` → `ErrPaused` (the fail-closed side of Decision 3).
  - `TestAgentloop_RefusesUnadmittedBackground` (`internal/agentloop`): daemon role, paused → `ErrPaused`, no HTTP request to the fake server.
  - `TestCLIAgentRunner_PausedSpawnsNothing`: daemon role, unadmitted ctx, paused → error, the fake spawner recorded no start.
  - `TestPlanUsagePoller_NotGatedByConsent`: daemon role, paused. `planUsagePoller(...)` with a fake `Client` polls once and stores the read (D17).
- [ ] **Step 2: Run** the tests above → FAIL.
- [ ] **Step 3: Implement.** Keep `newAIClient`'s construction-time policy check as it is. The per-call checks are additive.
- [ ] **Step 4: Verify** with `go test ./cmd -run 'TestPolicyChecked|TestBGAI02|TestCLIAgentRunner|TestPlanUsage|TestCLIAudit|InitTestTemplate|LLMUSAGE|LLMTRANSPORT'`, then `go test ./internal/agentloop ./internal/llmusage ./internal/chatengine ./internal/hub/...`, then `make lint-diff`. All PASS.
- [ ] **Step 5: Commit** `feat(ai): refuse unadmitted background calls in every leaf (#1886)`.

---

### Task 5: Daemon cycle gate (`aiPhase`), backfill hold, reaction commands as gestures

**Depends on:** Task 2

**Files:**
- Create: `internal/daemon/ai_consent.go`: `func (d *Daemon) SetConsent(r aiconsent.Reader)`, `func (d *Daemon) aiPhase(ctx context.Context, name string, fn func(ctx context.Context))`, `func (d *Daemon) consentNow() aiconsent.State` (nil reader → `aiconsent.Current()`, Decision 9); `internal/daemon` `TestMain` calls `aiconsenttest.AllowByDefault()`, `d.consentLogged` (the last logged state, for the once-per-change line)
- Modify: `internal/daemon/daemon.go` `runSync`: wrap `phaseChannelDigests`, `phaseMediaDescribe`, `phaseStreamDigests`, `phaseMemory`, `phaseNextStep`, `phaseCoach` and `phaseHistoryBackfill` (the backfill on `fetchCtx`) in `d.aiPhase`. The parallel group (`phaseTrackMyThreads` + `phasePeopleCards`) reads the state once at group start, skips People cards when paused and passes the admitted ctx to both. `phaseReactionCommands(aiconsent.WithOwnerStarted(fetchCtx))`. `trackedPipelineRun`: a `stats.err` that `errors.Is(…, aiconsent.ErrPaused)` completes the row with no error text (`errMsg = ""`) and logs `skipped: background AI is paused`.
- No inventory text changes here (Task 9 writes the FEAT-01 and BACKFILL notes).
- Tests: create `internal/daemon/ai_consent_test.go`

**Interfaces:**
- Consumes: `aiconsent.Reader`, `State`, `LogLine`, `WithAdmitted`, `WithOwnerStarted`, `ErrPaused`.
- Produces: `(*Daemon).SetConsent`. The unit ids are `phase:<name>`, used by `WithAdmitted`.

- [ ] **Step 1: Failing tests** (fake reader whose value a test flips; the existing daemon fakes; no wall-clock):
  - `TestBGAI01_PauseMidCycleFinishesPhaseSkipsNext`: the channel-digest fake generator flips the reader to paused on its first call and makes 3 calls. All 3 run. `phaseMediaDescribe`'s fake makes 0 calls, and no `pipeline_runs` row named `media` exists. The next `runSync` still calls the Slack and Jira fakes.
  - `TestBGAI01_PauseMidCycleSkipsWithoutErrorRow`: a phase whose generator returns `aiconsent.ErrPaused` → its `pipeline_runs` row has `error = ''`.
  - `TestBGAI01_PausedHoldsBackfillWhole`: paused → the `history_backfill` rows are byte-identical before and after, the backfill fetch fake has 0 calls, and the hold-strike count is unchanged.
  - `TestDaemon_ReactionCommandsRunWhilePaused`: paused, reaction commands on, one Slack account, a fake `reactionCmdPipe` → `Run` is called once with a ctx whose `OriginOf` is owner.
  - `TestDaemon_ConsentLogOncePerChange`: three paused cycles → one log line equal to `aiconsent.LogLine(paused-unanswered)`. Allowed, then paused by owner → a second line containing `paused by you`.
- [ ] **Step 2: Run** `go test ./internal/daemon -run 'TestBGAI01_Pause|TestDaemon_ReactionCommandsRunWhilePaused|TestDaemon_ConsentLog'` → FAIL.
- [ ] **Step 3: Implement.** `aiPhase` returns before any nil check, lock, `pipeline_runs` row or `automation_runs` row (the FEAT-01 position).
- [ ] **Step 4: Verify** `go test ./internal/daemon` PASS (the existing FEAT-01, BACKFILL and REACT guards included), then `make lint-diff`.
- [ ] **Step 5: Commit** `feat(daemon): hold AI phases while background AI is paused (#1886)`.

---

### Task 6: Automations — `UsesAI`, scheduler, bus, executor backstop

**Depends on:** Task 2

**Files:**
- Modify: `internal/automations/manifest.go`: `var PrimitiveUsesAI = map[string]bool{"brief.compose": true, "plan.compose": true, "tracks.extract": true, "ideas.consolidate": true, "reaction.compose": true, "track.scan": true, PrimitiveAttentionWaiting: false, PrimitiveApprovalsList: false}`; `func (m *Manifest) UsesAI() bool` (true for capability `llm`, `agent:run`, `session:start[@kind]`, `builtin:<p>` with `PrimitiveUsesAI[p]`, and `track:scan`); `func PermissionsUseAI(entries []string) bool`; `func AutomationUsesAI(a *db.Automation) bool` (decodes `PermissionsJSON`; a decode error → true, fail closed); `const BackgroundAIPausedMessage = "Background AI is paused"`
- Create: `internal/automations/testdata/uses_ai_cases.json` (`[{permissions:[…], uses_ai: bool}]`: `llm:light`, `llm:strong`, `agent:run`, `session:start`, `session:start@review`, `builtin:brief.compose`, `builtin:attention.waiting`, `track:scan`, `mcp:x.y`, `shell:make`, `slack:read`, empty)
- Modify: `internal/automations/scheduler.go`: `func (s *Scheduler) SetConsent(r aiconsent.Reader)`. In `scheduleOne`, when the reader says paused and `AutomationUsesAI(&a)`, a `dec.trigger != ""` becomes no run plus `CompareAndSetAutomationSchedule(a.ID, a.LastScheduledFor, dec.advanceTo, dec.nextRunAt)`. Read the state once per `Tick`.
- Modify: `internal/automations/bus.go`: `func (b *Bus) SetConsent(r aiconsent.Reader)`. `Begin` leaves out rows with `AutomationUsesAI` while paused.
- Modify: `internal/automations/executor.go`: `ExecutorOptions.Consent aiconsent.Reader`; `func (e *Executor) heldForConsent(ctx context.Context, r *db.AutomationRun, a *db.Automation) bool`, called in `poll.consider` before `claim` and in `ExecuteInlinePinned`/`ExecuteBuiltinInline`/`ExecuteRun` before their claim. Held → `db.CancelQueuedBackgroundPaused`. In `runClaimed` and the inline paths, the run's ctx becomes `aiconsent.WithOwnerStarted` for owner triggers or an owner-started incoming ctx, and `aiconsent.WithAdmitted(ctx, fmt.Sprintf("run:%d", id))` for background triggers.
- Modify: `internal/db/automation_runs.go`: `func (db *DB) CancelQueuedBackgroundPaused(runID int64, now time.Time) error` (status `cancelled`, `error_kind='cancelled'`, `error='Background AI is paused'`, only while `queued`; `ErrRunNotQueued` otherwise)
- Modify: `docs/inventory/automations.md` (AUTO-10 text gains the paused window, spec §13; Changelog naming ask #1452 and guards `TestScheduler_PausedAdvancesWithoutRun`, `TestScheduler_AllowAfterPauseDoesNotCatchUp`)
- Tests: `internal/automations/consent_test.go` (new), `internal/automations/builtin/registry_test.go`, `internal/db/automation_runs_test.go`

**Interfaces:**
- Consumes: Task 2.
- Produces: `automations.PrimitiveUsesAI`, `(*Manifest).UsesAI`, `PermissionsUseAI`, `AutomationUsesAI`, `BackgroundAIPausedMessage`, `(*Scheduler).SetConsent`, `(*Bus).SetConsent`, `ExecutorOptions.Consent`, `db.CancelQueuedBackgroundPaused`.

- [ ] **Step 1: Failing tests:**
  - `TestBuiltin_EveryPrimitiveDeclaresAI` (`builtin`): every name in every `All()[i].Primitives`, in `automations.BuiltinPrimitiveNames` and in the keys of `automations.PrimitiveCapability` has an entry in `PrimitiveUsesAI`.
  - `TestManifest_UsesAISharedFixture`: every fixture row → `PermissionsUseAI(row.permissions) == row.uses_ai`.
  - `TestRunMarkerEnv_MatchesAiconsent`: `RunEnvMarker == aiconsent.RunMarkerEnv`.
  - `TestScheduler_PausedAdvancesWithoutRun`: an AI recipe due at the fake clock's 09:00 with paused consent → no `automation_runs` row, and `last_scheduled_for` = 09:00.
  - `TestScheduler_AllowAfterPauseDoesNotCatchUp`: paused across 09:00, 10:00 and 11:00 ticks with `missed: catch_up`, then allowed at 11:30 → no `catch_up` row. The next 12:00 tick inserts one `schedule` row.
  - `TestScheduler_NonAIRecipeRunsWhilePaused`: a `shell:`-only recipe → one `schedule` row.
  - `TestBus_PausedSkipsAIRecipes`: two event recipes on `slack.reaction_added` (one `llm:light`, one `mcp:`), paused → `Wants` is true, and `Flush` queues exactly the `mcp:` one.
  - `TestExecutor_PausedCancelsBackgroundAIRun`: a queued `schedule` run of an AI recipe, paused → `Step` gives `cancelled`/`cancelled`/`Background AI is paused`, and the fake backends saw no call.
  - `TestBGAI02_ManualRunWhilePaused`: `manual`, `button`, `dry_run` and `reply` runs of the same recipe, paused → each is claimed and runs, and the fake `llm()` backend's ctx is owner.
  - `TestExecutor_OwnerStartedSyncRunPasses`: a `sync` run executed through `ExecuteRun` with a `WithOwnerStarted` ctx while paused → runs.
  - `TestExecutor_AdmittedRunFinishesAfterPause` (BGAI-01 D12): the fake `shell()` step flips the reader to paused and the following `llm()` call still runs. The run ends `succeeded`.
  - `TestCancelQueuedBackgroundPaused_OnlyQueued` (`db`).
- [ ] **Step 2: Run** `go test ./internal/automations/... ./internal/db -run 'Consent|UsesAI|Paused|ManualRunWhilePaused|OwnerStarted|AdmittedRun|EveryPrimitive|RunMarkerEnv|CancelQueuedBackground'` → FAIL.
- [ ] **Step 3: Implement.** A nil reader everywhere reads `aiconsent.Current` (Decision 9). Add `aiconsenttest.AllowByDefault()` to the `TestMain` of `internal/automations` and of every other package whose existing tests go red only because of that default. Change no assertion.
- [ ] **Step 4: Verify** with `go test ./internal/automations/... ./internal/db` PASS. The AUTO guards are unchanged, including the existing AUTO-10 guards. Then `make lint-diff`.
- [ ] **Step 5: Commit** `feat(automations): hold background AI runs while paused (#1886)`.

---

### Task 7: Built-in slots — paused skip, Run Now still runs

**Depends on:** Task 6

**Files:**
- Modify: `internal/automations/builtin/runner.go`: `const SkippedPaused = "paused"`; `func (r *Runner) SetConsent(c aiconsent.Reader)` (nil → `aiconsent.Current`); `builtin` `TestMain` calls `aiconsenttest.AllowByDefault()`. In `runEntry`, after the `Enabled`, `DisabledReason` and `Confirmed` checks and `TakeQueuedBuiltinRun`: a queued manual run executes; otherwise, when paused and `AutomationUsesAI(a)`, return `SkippedPaused` with no gate call, no `EnqueueAutomationRun` and no `cancelQueued`. A sync run that executes gets `aiconsent.WithAdmitted(ctx, "slot:<id>")`.
- Modify: `internal/automations/builtin/registry.go`: `func (e Entry) UsesAI() bool` (any primitive in `automations.PrimitiveUsesAI`)
- Modify: `internal/automations/builtin/watchslot.go` `RunWatchSlot`: the same paused rule per watch recipe (a queued `RunWatchNow` runs; otherwise skipped before the `WatchGate`)
- Modify: `internal/daemon/morning_brief.go`, `builtin_slots.go`: pass the slot's ctx as is. Admission happens in the runner.
- Tests: `internal/automations/builtin/runner_test.go`, `watchslot_test.go`

**Interfaces:**
- Consumes: Task 6 (`AutomationUsesAI`, `PrimitiveUsesAI`), Task 2.
- Produces: `(*builtin.Runner).SetConsent`, `builtin.SkippedPaused`, `Entry.UsesAI`.

- [ ] **Step 1: Failing tests:**
  - `TestRunner_PausedSkipsAIBuiltinWritesNothing`: Morning brief confirmed, a gate fake that counts calls, paused → outcome `Skipped == "paused"`, gate calls 0, `automation_runs` count unchanged, `pipeline_runs` count unchanged.
  - `TestRunner_MechanicalBuiltinRunsWhilePaused`: Waiting for me at its slot, paused, gate due → one `sync` run that succeeds. Needs approval queued by its trigger → the executor claims it.
  - `TestRunner_PausedStillRunsQueuedRunNow`: a queued manual run of Morning brief, paused → executed. The executor's ctx is owner.
  - `TestRunWatchSlot_PausedSkipsWithoutGate`.
  - `TestEntry_UsesAI`: `morning-brief`, `track-my-threads`, `idea-finder`, `reactions` → true; `waiting-for-me`, `needs-approval` → false.
- [ ] **Step 2: Run** `go test ./internal/automations/builtin` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify** with `go test ./internal/automations/... ./internal/daemon` PASS (`TestRunner_OffWritesNothing` unchanged), then `make lint-diff`.
- [ ] **Step 5: Commit** `feat(builtin): paused slots skip AI built-ins, Run Now still runs (#1886)`.

---

### Task 8: Spawns carry the origin; spec-review sweep holds; reviewer backstop; static checker

**Depends on:** Task 4, Task 5

**Files:**
- Modify: `cmd/automations_backends.go`: `automationAgentEnv(ctx context.Context, runID int64) []string` appends `aiconsent.ChildEnv(ctx)`; `codexAgentServerEnv = []string{automations.RunEnvMarker, aiconsent.EnvOrigin, aiconsent.EnvAdmitted}`. The MCP server env passed to claude carries the same entries.
- Modify: `internal/automations/sdk_shell.go` `shellEnv(env *Env)`: append `aiconsent.ChildEnv(env.Ctx)` after the marker.
- Modify: `cmd/workbench_spec_review_launch.go`: `LaunchSpecReview(exe string, askID int64, logDir string, originEnv []string) error` appends `originEnv` to `c.Env`. The owner path in `specReviewLauncher` passes `nil`.
- Modify: `cmd/sync.go` `d.SetSpecReviewLaunch`: the closure becomes `func(ctx context.Context, askID int64) error` and passes `aiconsent.ChildEnv(ctx)`.
- Modify: `internal/daemon/spec_review_sweep.go`: `SetSpecReviewLaunch(f func(ctx context.Context, askID int64) error)`. While `!d.consentNow().Allowed()`, the queued loop is skipped whole: no `RelaunchQueuedSpecReview`, no `ClaimSpecReview`, no failing, no attempt spent. The running-row repairs, `sweepSpecLoops` and `sweepSpecReviewQuestions` still run. When allowed, each relaunch gets `aiconsent.WithAdmitted(ctx, fmt.Sprintf("review:%d", id))`.
- Modify: `cmd/workbench_spec_review.go` `runSpecReviewRun`: `if err := aiconsent.Check(ctx); errors.Is(err, aiconsent.ErrPaused) { log; return nil }` before `specreview.Run`
- Create: `internal/daemon/bgai_spawn_test.go` (the checker) + `internal/daemon/testdata/spawns/{bad,good}/*.go`
- Modify: `docs/features/spec-review.md` (one paragraph: the sweep's relaunch waits while paused, D20)
- Tests: `cmd/workbench_spec_review_launch_test.go`, `cmd/workbench_spec_review_test.go`, `internal/daemon/spec_review_sweep_test.go`, `internal/automations/sdk_shell_test.go`, `cmd/automations_backends_test.go`

**Interfaces:**
- Consumes: Task 2 (`ChildEnv`, `EnvOrigin`, `EnvAdmitted`, `Check`), Task 4 (the leaf checks in `cmd/automations_backends.go`), and `(*Daemon).consentNow` from Task 5.
- Produces: the new `LaunchSpecReview` and `SetSpecReviewLaunch` signatures.

- [ ] **Step 1: Failing tests:**
  - `TestBGAI01_EveryDaemonSpawnSetsOrigin`: a `go/ast` walk over `internal/daemon`, `internal/automations` (non-test) and the launchers they call (`cmd/workbench_spec_review_launch.go`, `cmd/automations_backends.go`). Each `exec.Command`/`exec.CommandContext`/`os.StartProcess` call must set the env with an `aiconsent.ChildEnv(...)`, `originEnv` or `automationAgentEnv(ctx, …)` value reaching its `Env`, or sit in the allowlist `{"ps": "process identity, no model", "/bin/sh": "shellEnv sets the origin"}`. The roots also include `internal/chatengine` and `internal/hub/...` (Decision 3). There a spawn must use `aiconsent.OwnerEnv(...)` (one owner request) or `aiconsent.ChildEnv(...)`, or carry an allowlist entry with its reason (the hub's CloudKit bridge helper in `internal/hub/desktop.go`: no model; `ps`). `internal/sessionstart` is listed with the reason "`AutomationRunEnv` marker: the origin is the run's trigger (§4.3)". Model it on `checkLeaves` in `internal/llmusage/leaves_test.go`. `TestBGAI01_SpawnCheckerCatchesNewSpawn` runs the checker over `testdata/spawns/bad` (one bare `exec.Command("watchtower", …)`), expects exactly that finding, and expects none for `good`.
  - `TestLaunchSpecReview_SweepSetsOrigin`: `LaunchSpecReview` with `/usr/bin/true` (reaped in `t.Cleanup`) and the origin env → the started `*exec.Cmd`'s `Env` contains `WATCHTOWER_AI_ORIGIN=background`. Capture it through a `startCmd` seam so no process outlives the test.
  - `TestSpecReviewSweep_HoldsWhilePaused`: a queued row older than a minute, paused → the launcher fake is not called, `status = 'queued'`, `attempt` unchanged. A dead running row is still failed.
  - `TestSpecReviewRun_BackgroundOriginPausedLeavesQueued`: `InitProcess("cli", {EnvOrigin: background})`, paused → the row stays queued and the agent fake is not called.
  - `TestShellEnv_CarriesOrigin`, `TestAutomationAgentEnv_CarriesOrigin`, `TestCodexAgentServerEnv_NamesOrigin`.
- [ ] **Step 2: Run** them → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify** with `go test ./internal/daemon ./internal/automations/... ./internal/specreview`, then `go test ./cmd -run 'TestLaunchSpecReview|TestSpecReview|TestAutomationAgent|TestCodexAgent|TestCLIAudit|InitTestTemplate|LLMUSAGE|LLMTRANSPORT'`, then `make lint-diff`. All PASS.
- [ ] **Step 5: Commit** `feat(daemon): background spawns carry the AI origin; review sweep waits (#1886)`.

---

### Task 9: Fail-closed default, full-cycle guards, BGAI inventory

**Depends on:** Task 3, Task 5, Task 7, Task 8

**Files:**
- No wiring change: production constructors leave the reader nil, which reads `aiconsent.Current` (Decision 9).
- Create: `internal/automations/bgai_default_test.go`
- Create: `internal/daemon/bgai_cycle_test.go`
- Create: `docs/inventory/background-ai.md` (BGAI-01, BGAI-02, BGAI-03, each with Observable, Mechanism and Guards, from spec §13; Changelog: "<date> (board #1886, ask #1452): BGAI-01..03 added"). Modify `docs/inventory/README.md` (module → file line: `internal/aiconsent`, the consent gates → `background-ai.md`), `docs/inventory/features.md` (FEAT-01 note: the paused gate is a sibling gate at the same position), `docs/inventory/history-backfill.md` (BACKFILL note: the runner holds whole while paused)

**Interfaces:**
- Consumes: every earlier Go task's `SetConsent`/`Consent` and their nil default.

- [ ] **Step 1: Failing tests:**
  - `TestBGAI01_NilReaderFailsClosed` (`internal/automations`, and a twin in `internal/daemon`): clear the test override (`aiconsenttest` restore in `t.Cleanup`) and point `aiconsent.SetConfigPath` at an unanswered temp config. With nil readers: `Scheduler.Tick` inserts no AI run, `Bus.Begin` drops the AI recipe, `Executor.Step` cancels a queued AI `schedule` run with `Background AI is paused`, `builtin.Runner.RunSlot` skips Morning brief, and the daemon's `aiPhase` does not call its fn.
  - `TestBGAI01_PausedCycleMakesNoModelCall`: every feature on, Slack, mail and Jira fakes with data, one AI `schedule` recipe due, one AI `event` recipe matching, a counting generator, consent paused → `runSync` plus one scheduler `Tick` plus one executor `Step`. The result: 0 model calls, no AI `pipeline_runs` rows (digests, media, tracks, people, streams, ideas, memory, next step, briefing, coach), no `automation_runs` row in `running`/`succeeded`, every sync fake called, the `history_backfill` rows untouched. Then allowed: the same sequence calls the model more than 0 times.
  - `TestBGAI01_RunStartedBeforePauseFinishes`: a claimed AI `schedule` run whose first step flips the reader to paused ends `succeeded`. A second due run is cancelled with `Background AI is paused`.
- [ ] **Step 2: Run** → FAIL wherever a nil default is still ungated.
- [ ] **Step 3: Fix** any default left ungated, and write the inventory file. The Guards list names every BGAI test from Tasks 2–9 by its file path.
- [ ] **Step 4: Verify** with `go test ./internal/daemon ./internal/automations/... ./internal/aiconsent`, then `go test ./cmd -run 'TestBGAI|TestCLIAudit|InitTestTemplate|LLMUSAGE|LLMTRANSPORT'`, then `make lint-diff`. All PASS.
- [ ] **Step 5: Commit** `feat(daemon): fail-closed consent default; BGAI inventory (#1886)`.

---

### Task 10: Heartbeat `background_ai` key (Go hub + Kit)

**Depends on:** Task 2

**Files:**
- Modify: `internal/hub/wire/payloads.go`: `Heartbeat.BackgroundAI string \`json:"background_ai,omitempty"\``; consts `BackgroundAIAllowed = "allowed"`, `BackgroundAIPaused = "paused"`, `BackgroundAIOrganization = "organization"`
- Modify: `internal/hub/slices/heartbeat.go`: `HeartbeatFacts.BackgroundAI func() string` (nil → absent). A change of its value restamps at once, as `caps` does.
- Modify: `internal/hub/runtime.go` `heartbeat(...)`: `BackgroundAI: func() string { return backgroundAIValue(aiconsent.Current()) }`; `func backgroundAIValue(s aiconsent.State) string` (allowed → `allowed`; paused with reason `organization` → `organization`; otherwise `paused`)
- Modify: `internal/hub/wire/contract_test.go` and its fixture (optional, omitted when empty)
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Relay/HeartbeatPayload.swift`: `public let backgroundAI: BackgroundAIStatus?` with `public enum BackgroundAIStatus: String { case allowed, paused, organization }`. A custom decode maps an unknown value to `nil`.
- Create: `WatchtowerKit/Tests/WatchtowerSyncTests/HeartbeatPayloadTests.swift`
- Modify: `docs/features/go-hub.md`, `docs/features/mobile-companion.md` (protocol §9 note: one optional additive key)

**Interfaces:**
- Produces: `wire.Heartbeat.BackgroundAI`, `HeartbeatPayload.backgroundAI: BackgroundAIStatus?`.

- [ ] **Step 1: Failing tests:**
  - `TestHeartbeat_CarriesBackgroundAI`: facts returning `paused` → the payload JSON has `"background_ai":"paused"`. With nil facts the key is absent. A change from `paused` to `allowed` restamps without waiting for `HeartbeatInterval` (fake `Clock`).
  - `TestBackgroundAIValue`: the four §3.2 shapes map as specified.
  - The contract fixture gains a heartbeat case with the key, and `TestHubContractFixture` decodes it.
  - Kit `HeartbeatPayloadTests.testBackgroundAIKeyIsOptional`: absent → nil, `"later"` → nil, `"organization"` → `.organization`. The existing Kit fixture tests (`KitFixtureTests`, `KitGoHubInteropTests`) still pass.
- [ ] **Step 2: Run** `go test ./internal/hub/...` and `make kit-test FILTER=HeartbeatPayloadTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify** with `go test ./internal/hub/...` PASS, then `make kit-test FILTER='HeartbeatPayloadTests|KitFixtureTests|KitGoHubInteropTests'` PASS, then `make lint-diff` and `make lint-swift`.
- [ ] **Step 5: Commit** `feat(hub): heartbeat carries background_ai (#1886)`.

---

### Task 11: Phone line on Now

**Depends on:** Task 10

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerKit/Copy/BackgroundAIConsentCopy.swift`: `public enum BackgroundAIConsentCopy { public static func phoneLine(_ s: BackgroundAIStatus?) -> String? }` (`.paused` → spec §6.5 paused line, `.organization` → org line, `.allowed`/nil → nil)
- Create: `WatchtowerKit/Tests/WatchtowerKitTests/BackgroundAIConsentCopyTests.swift`
- Modify: `WatchtowerMobile/Sources/Features/Now/NowView.swift`: one line above the feed from `hubSession.heartbeat?.backgroundAI`, styled as the existing notice rows, colour from `Tone`, no button
- Test: `WatchtowerMobile/Tests/NowWiringTests.swift` (`testBackgroundAILineFollowsHeartbeat`)

**Interfaces:**
- Consumes: Task 10's `BackgroundAIStatus`.

- [ ] **Step 1: Failing tests:** `BackgroundAIConsentCopyTests.testPhoneLines` (the exact strings of mockups `ai-consent-phone-paused` and `ai-consent-phone-org`, and nil for allowed or absent); `NowWiringTests.testBackgroundAILineFollowsHeartbeat`.
- [ ] **Step 2: Run** `make kit-test FILTER=BackgroundAIConsentCopyTests` and `make mobile-test MOBILE_FILTER=NowWiringTests` → FAIL.
- [ ] **Step 3: Implement.** Compare the screen with `ai-consent-phone-paused` and `ai-consent-phone-org`.
- [ ] **Step 4: Verify** that both commands PASS and `make lint-swift` passes. If phone files were added, run `make mobile-gen` and commit the regenerated project.
- [ ] **Step 5: Commit** `feat(mobile): background AI line on Now (#1886)`.

---

### Task 12: Desktop consent core — Swift resolve, copy, config read, AppState

**Depends on:** Task 1, Task 2

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/BackgroundAIConsent.swift`: `package enum BackgroundAIConsent { package enum Effective: String { case allowed, paused }; package enum Reason: String { case unanswered, owner, organization }; package struct State: Equatable, Sendable { effective, reason, prompt, locked; package static let allowedByOwner }; package static func resolve(answer: String?, policy: Bool?) -> State }`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/BackgroundAIConsentCopy.swift`: every Desktop string of spec §5.1, §6.1–§6.4, moved from `BackgroundAIConsentMockCopy` unchanged in content, with the same `Agent` enum (`claude`, `codex`, `other(name:)`)
- Delete: `WatchtowerDesktop/Tests/DesignShots/BackgroundAIConsentMockCopy.swift`, `BackgroundAIConsentMockCopyTests.swift`. Point `DesignShotFixtures+BackgroundAIConsent.swift` at `BackgroundAIConsentCopy`.
- Create: `WatchtowerDesktop/Tests/Core/BackgroundAIConsentTests.swift`, `BackgroundAIConsentCopyTests.swift` (the moved and extended copy tests)
- Modify: `WatchtowerDesktop/Sources/Services/ConfigService.swift`: `private(set) var backgroundRuns: String?`, read in `reload()` from `yaml["ai"]["background_runs"]`, never written by `save()`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/ConfigFileLock.swift`: `package enum ConfigFileLock { static func withLock<T>(configPath: String, _ body: () throws -> T) throws -> T }`, an exclusive `flock(2)` on `<configPath>.lock` (Decision 7). `ConfigService.save()` runs its re-read and write inside it, through an injectable `lock` seam.
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/BackgroundAIConsentRefresher.swift`: `@MainActor package final class BackgroundAIConsentRefresher { init(center: NotificationCenter, activation: Notification.Name, reload: @escaping @MainActor () -> Void); func start(); func stop() }` (Decision 12). `AppState` starts it with `NSApplication.didBecomeActiveNotification` and `reload = reloadBackgroundAI`.
- Modify: `WatchtowerDesktop/Tests/ConfigServiceTests.swift` (`testSaveKeepsBackgroundRunsKey`, `testSaveHoldsConfigLockAroundReadAndWrite`); create `Tests/Core/ConfigFileLockTests.swift`, `Tests/Core/BackgroundAIConsentRefresherTests.swift`
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift`: `var backgroundAI: BackgroundAIConsent.State`, recomputed from `configService.backgroundRuns` and `managedPolicyCenter.policy.allowBackgroundAI` whenever either changes; `func reloadBackgroundAI()` re-reads the config

**Interfaces:**
- Consumes: Task 1 (`ManagedPolicy.allowBackgroundAI`), Task 2's fixture file.
- Produces: `BackgroundAIConsent.State`, `.resolve`, `BackgroundAIConsentCopy` (all members of the old mock copy), `AppState.backgroundAI`, `AppState.reloadBackgroundAI()`.

- [ ] **Step 1: Failing tests:**
  - `BackgroundAIConsentTests.sharedFixture`: reads `internal/aiconsent/testdata/consent_cases.json` (path resolved like `ManagedPolicyTests.fixture()`). The wrong-type row goes through `ManagedPolicy` decoding first, then `resolve` gives each row's `want`.
  - `BackgroundAIConsentCopyTests`: the old mock tests plus the Codex and other-provider plan lines, the reserve line in both directions, `whatRuns(pollMinutes: 15, backfillDays: 30)`, and the Settings captions per agent.
  - `ConfigServiceTests.testSaveKeepsBackgroundRunsKey`: the file has `ai.background_runs: allowed`. Load, change another AI key, `save()` → the key is still `allowed`.
  - `ConfigServiceTests.testSaveHoldsConfigLockAroundReadAndWrite`: a recording lock seam sees `lock`, then the file read, then the write, then `unlock`.
  - `ConfigFileLockTests.testSecondNonBlockingLockFails`: inside `withLock`, a second `flock(LOCK_EX|LOCK_NB)` on the lock file fails; after it returns, the second lock succeeds.
  - `BackgroundAIConsentRefresherTests.testActivationRereadsAnswer`: posting the activation name on a private `NotificationCenter` calls `reload` once. After `stop()` it is not called.
- [ ] **Step 2: Run** `make test-swift FILTER='BackgroundAIConsentTests|BackgroundAIConsentCopyTests|ConfigServiceTests|ConfigFileLockTests|BackgroundAIConsentRefresherTests'` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Verify** that those filters plus `DesignShotsTests` PASS, then `make lint-swift`.
- [ ] **Step 5: Commit** `feat(desktop): background AI consent state and copy (#1886)`.

---

### Task 13: Consent screen — onboarding step and upgrade sheet

**Depends on:** Task 12

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/BackgroundAIConsentModel.swift`: `@MainActor @Observable package final class BackgroundAIConsentModel { init(runner: CLIRunnerProtocol, configPath: String, agent: BackgroundAIConsentCopy.Agent, reserve: BackgroundAIConsentCopy.Agent?, pollMinutes: Int, backfillDays: Int); private(set) var isSaving: Bool; private(set) var errorLine: String?; func allow() async -> Bool; func notNow() async -> Bool }`. `allow` runs `["--config", configPath, "ai", "background", "allow", "--yes"]`, `notNow` runs `[…, "pause"]`. A failure sets `errorLine = BackgroundAIConsentCopy.saveFailed(<stderr or description>)`.
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/BackgroundAIConsentPrompt.swift`: `package enum BackgroundAIConsentPrompt { enum Opened { case upgrade, reEntry }; static func shouldPresent(onboardingDone: Bool, state: BackgroundAIConsent.State) -> Bool; static func shouldClose(opened: Opened, state: BackgroundAIConsent.State) -> Bool }` (upgrade: `!state.prompt`; reEntry: `state.effective == .allowed`; Decision 12)
- Create: `WatchtowerDesktop/Sources/Views/Onboarding/BackgroundAIConsentView.swift`: `BackgroundAIConsentView(model:, host: .step(onBack:) | .sheet)` with the layout of spec §5 from DesignKit components. The error line is `Tone.error`. The sheet has no close button and sets `.interactiveDismissDisabled()`.
- Modify: `OnboardingStateMachineV2.swift`: `case aiConsent` (raw `aiConsent`, indicator `"Background AI"`) between `connect` and `complete`. `OnboardingRoute` gains `consentPrompt: Bool` (init parameter, default `false`). `skips(.aiConsent) == !consentPrompt`.
- Modify: `AppState.swift`: the onboarding host builds the route with `consentPrompt: backgroundAI.prompt`. The step's answer calls `reloadBackgroundAI()` and then `leaveOnboardingStep(.aiConsent, …)`. Add `var isBackgroundAIConsentPresented: Bool` and `func presentBackgroundAIConsent()` (the entry point that Settings, Home, empty states and Automations call, D9). Present the sheet once per launch when `BackgroundAIConsentPrompt.shouldPresent` holds and the release-notes window from `UpdateService` is not open; if it is open, present when it closes. Bring the main window forward first.
- Tests: `Tests/Core/BackgroundAIConsentModelTests.swift`, `Tests/Core/BackgroundAIConsentPromptTests.swift`, `Tests/Core/OnboardingStateMachineV2Tests.swift`
- Modify: `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+BackgroundAIConsent.swift`: add live shots `ai-consent-step-live-claude`, `ai-consent-step-live-codex`, `ai-consent-step-live-claude-narrow` (600 pt), `ai-consent-sheet-live-claude`, `ai-consent-sheet-live-error`, beside the mockups

**Interfaces:**
- Consumes: Task 12. The CLI contract from Task 3 is used through `CLIRunnerProtocol` only, so tests use a fake runner.
- Produces: `BackgroundAIConsentModel`, `BackgroundAIConsentView`, `AppState.presentBackgroundAIConsent()`, `OnboardingV2Step.aiConsent`, `OnboardingRoute.consentPrompt`.

- [ ] **Step 1: Failing tests:**
  - `BackgroundAIConsentModelTests`: `testAllowCallsCLIWithYes` (exact args); `testNotNowCallsPause`; `testSavingDisablesThenClears` (a fake runner suspended on a continuation: `isSaving` is true during the call and false after); `testFailureShowsErrorAndReturnsFalse` (the error line equals `saveFailed("disk full")`); `testSheetClosesOnlyAfterSuccess` (allow → false on failure, true on success).
  - `BackgroundAIConsentPromptTests.testClosesWhenAnsweredElsewhere`: `shouldClose(.upgrade, owner-paused)` → true, `shouldClose(.upgrade, unanswered)` → false, `shouldClose(.reEntry, owner-paused)` → false, `shouldClose(.reEntry, allowed)` → true.
  - `BackgroundAIConsentPromptTests.testShownOnceUntilAnsweredAfterOnboarding`: `(true, unanswered)` → true; `(false, unanswered)` → false; `(true, owner-paused)` → false; `(true, org-allowed)` → false; `(true, org-off)` → false.
  - `OnboardingStateMachineV2Tests`: `testConsentStepSkippedWhenDecided` (route `consentPrompt: false` → `step(after: .connect) == .complete`; true → `.aiConsent`; Development-only goals with `consentPrompt: true` → `step(after: .purpose) == .aiConsent`); `testParkedOnConnectResumesThroughConsent`; `testUnknownRawValueStillStartsAtGoals`; `testIndicatorShowsBackgroundAI`.
- [ ] **Step 2: Run** `make test-swift FILTER='BackgroundAIConsentModelTests|BackgroundAIConsentPromptTests|OnboardingStateMachineV2Tests'` → FAIL.
- [ ] **Step 3: Implement.** Compare the live shots with `ai-consent-step-claude`, `-codex`, `-ollama`, `-claudeReserve`, `-saving`, `-error`, `-claude-narrow`, `ai-consent-sheet-claude` and `ai-consent-sheet-error`, using `make desktop-shots DESKTOP_SHOTS=<dir>`.
- [ ] **Step 4: Verify** with `make test-swift FILTER='BackgroundAIConsent|OnboardingStateMachineV2Tests|DesignShotsTests'` PASS, then `make lint-swift`.
- [ ] **Step 5: Commit** `feat(desktop): background AI consent step and upgrade sheet (#1886)`.

---

### Task 14: Settings → AI → Background AI

**Depends on:** Task 13

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/BackgroundAISettingsPresentation.swift`: `package struct BackgroundAISettingsPresentation: Equatable { isOn: Bool; locked: Bool; caption: String; captionIsError: Bool; static func make(state: BackgroundAIConsent.State, agent: BackgroundAIConsentCopy.Agent, isSaving: Bool, error: String?) -> Self }`
- Create: `WatchtowerDesktop/Sources/Views/Settings/BackgroundAISettingsSection.swift`: a `SettingsSection("Background AI", footer: settingsFooter)` with one `SettingRow("Run AI in the background")` switch and `.managedByOrganization(locked)`. Switching on calls `appState.presentBackgroundAIConsent()`, and the switch keeps following the stored value. Switching off runs `pause` through `BackgroundAIConsentModel.notNow()` with no confirmation. A section spinner shows while saving. An error caption uses `Tone.error`.
- Modify: `WatchtowerDesktop/Sources/Views/Settings/ProviderSettings.swift` (the section under the provider sections)
- Test: `Tests/Core/BackgroundAISettingsPresentationTests.swift`; live shots `ai-consent-settings-live-allowed`, `-paused`, `-orgOff`, `-orgAllowed`, `-error`

**Interfaces:**
- Consumes: Task 13 (`presentBackgroundAIConsent`, `BackgroundAIConsentModel`).

- [ ] **Step 1: Failing tests:** `BackgroundAISettingsPresentationTests` covers the six rows of spec §6.1: `testAllowedClaude`, `testAllowedOllamaHasNoPlanClause`, `testPausedOwnerAndUnanswered`, `testOrgOffLocked`, `testOrgAllowedCaption`, `testSavingKeepsCaption`, and `testErrorFallsBackToStored` (`isOn` follows the stored state and `captionIsError` is true).
- [ ] **Step 2: Run** `make test-swift FILTER=BackgroundAISettingsPresentationTests` → FAIL.
- [ ] **Step 3: Implement.** Compare with `ai-consent-settings-allowed`, `-paused`, `-orgOff`, `-orgAllowed`, `-saving` and `-error`.
- [ ] **Step 4: Verify** with `make test-swift FILTER='BackgroundAISettings|DesignShotsTests'` PASS, then `make lint-swift`.
- [ ] **Step 5: Commit** `feat(desktop): Background AI switch in Settings (#1886)`.

---

### Task 15: Readiness state, empty states, Getting ready, Home card

**Depends on:** Task 13

**Files:**
- Modify: `WatchtowerCore/Models/Readiness.swift`: `case backgroundAIPaused(managed: Bool)`; `ReadinessFeature.usesBackgroundAI` (true for `digests`, `streamDigests`, `tracks`, `peopleCards`, `briefing`, `dayPlan`, `ideas`, `memory`); `ReadinessInputs.backgroundAI: BackgroundAIConsent.State = .allowedByOwner`
- Modify: `WatchtowerCore/Services/FeatureReadiness.swift` `evaluate`: the new state goes after `needsDigests` and before `daemonStopped`. Content still wins. `honoringOwner` keeps it.
- Modify: `Views/Components/FeatureEmptyState.swift`: `readinessPaused` + the "Allow background AI…" button (→ `presentBackgroundAIConsent()`), or `readinessOrg` with no button
- Modify: `WatchtowerCore/Services/GettingReadyPolicy.swift`: leave out the cards of features in `backgroundAIPaused`
- Create: `WatchtowerCore/Services/HomeBackgroundAICard.swift`: `package struct HomeBackgroundAICard: Equatable { title; body; actionTitle: String?; managed: Bool; static func make(_ s: BackgroundAIConsent.State) -> HomeBackgroundAICard? }` (nil when allowed)
- Modify: `Views/Home/HomeView.swift` `HomeContent`: the card at the top of the feed column, outside the Getting ready zone
- Modify: `Services/ReadinessCenter.swift` (feeds `appState.backgroundAI` into the inputs)
- Tests: `Tests/Core/FeatureReadinessTests.swift`, `Tests/Core/GettingReadyTests.swift`, create `Tests/Core/HomeBackgroundAICardTests.swift`; live shots `ai-consent-empty-live-paused`, `ai-consent-home-live-paused`, `ai-consent-home-live-org`

**Interfaces:**
- Consumes: Task 12 `State`, Task 13 `presentBackgroundAIConsent()`.

- [ ] **Step 1: Failing tests:** `FeatureReadinessTests.testBackgroundAIPausedOnlyForAIFeatures` (paused → every `usesBackgroundAI` feature is `.backgroundAIPaused(managed: false)`, and `slackSync`, `inbox`, `knowledgeIndex`, `calendar`, `jira`, `linear` are unchanged); `testContentWinsOverPaused`; `testPausedBeforeDaemonStopped` (daemon down past grace and paused → paused); `testManagedPausedHasNoButton` (org-off → `managed: true`). `GettingReadyTests.testPausedLeavesAIFeatureCardsOut` (the zone keeps its Connect rows and its Hide). `HomeBackgroundAICardTests.testPausedCardSurvivesHidingGettingReady` (with `memory.hiddenByOwner = true`, `GettingReadyPolicy.step` is hidden while `HomeBackgroundAICard.make(paused)` is non-nil with the spec title, body and action), `testOrgCardHasNoAction`, `testAllowedHasNoCard`.
- [ ] **Step 2: Run** `make test-swift FILTER='FeatureReadinessTests|GettingReadyTests|HomeBackgroundAICardTests'` → FAIL.
- [ ] **Step 3: Implement.** Compare with `ai-consent-empty-paused`, `ai-consent-empty-org`, `ai-consent-home-paused` and `ai-consent-home-org`.
- [ ] **Step 4: Verify** with `make test-swift FILTER='FeatureReadiness|GettingReady|HomeBackgroundAICard|ReadinessCenterTests|DesignShotsTests'` PASS, then `make lint-swift`.
- [ ] **Step 5: Commit** `feat(desktop): paused readiness, empty states and Home card (#1886)`.

---

### Task 16: Automations tab notice and Waiting chip

**Depends on:** Task 6, Task 13

**Files:**
- Create: `WatchtowerCore/Services/Automations/AutomationAIUse.swift`: `package enum AutomationAIUse { static func usesAI(permissions: [String]) -> Bool }` (the Swift twin of `automations.PermissionsUseAI`)
- Modify: `WatchtowerCore/Services/Automations/AutomationListSections.swift`: `AutomationRowChip.waitingForBackgroundAI` (title from `BackgroundAIConsentCopy.automationWaitingChip`). `chips(_:consent:)` adds it for a runnable item with `usesAI` and a `schedule`, `event` or `sync` trigger while paused. `package struct AutomationsBackgroundAINotice { text; actionTitle: String?; static func make(state:items:) -> Self? }`.
- Modify: `AutomationsViewModel.swift` (passes `backgroundAI`) and the Automations list view (the notice card above the list; the action → `presentBackgroundAIConsent()`)
- Tests: create `Tests/Core/AutomationAIUseTests.swift`; modify `Tests/Core/AutomationListSectionsTests.swift`; live shots `ai-consent-automations-live-paused`, `-org`

**Interfaces:**
- Consumes: Task 6's `internal/automations/testdata/uses_ai_cases.json`, Task 13.

- [ ] **Step 1: Failing tests:** `AutomationAIUseTests.sharedFixture` (every Go fixture row); `AutomationListSectionsTests.testPausedAIRowShowsWaiting`, `testPausedNonAIRowHasNoWaiting`, `testNoticeOnlyWithAnAIRow`, `testOrgNoticeHasNoAction`.
- [ ] **Step 2: Run** `make test-swift FILTER='AutomationAIUseTests|AutomationListSectionsTests'` → FAIL.
- [ ] **Step 3: Implement.** Compare with `ai-consent-automations-paused` and `ai-consent-automations-org`.
- [ ] **Step 4: Verify** with `make test-swift FILTER='AutomationAIUse|AutomationListSections|AutomationsViewModelTests|DesignShotsTests'` PASS, then `make lint-swift`.
- [ ] **Step 5: Commit** `feat(desktop): Automations show what waits for background AI (#1886)`.

---

### Task 17: Feature note, docs and user guide

**Depends on:** Task 9, Task 11, Task 14, Task 15, Task 16, Task 18

**Files:**
- Create: `docs/features/background-ai-consent.md` (the contract summary, the two paths Go/Swift and the shared fixtures, origin rules, the config lock, writers, v1 limits from spec §11, and the rule "a new command that can call a model goes into `internal/aiconsent/testdata/model_commands.json`; a new in-daemon owner path marks its request ctx")
- Modify: `CLAUDE.md` (Feature Notes line `- Background AI consent — \`background-ai-consent.md\``), `docs/features/README.md` (one-paragraph summary: `internal/aiconsent`, `ai.background_runs`, `AllowBackgroundAI`, `watchtower ai background`, BGAI-01..03, the two shared fixtures)
- Modify: `docs/inventory/background-ai.md` (BGAI-01 Guards gain Task 18's `DesktopModelLaunchSitesTests`; Changelog line naming ask #1452 and review #1484)
- Modify: `docs/features/onboarding-v2.md`, `docs/onboarding-flow.md` (third step), `docs/features/first-run.md` (readiness state, Home card), `docs/features/automations.md` (scheduler, bus, executor), `docs/features/mdm-policy.md` (the key), `docs/features/built-in-automations.md` (slots held, Run Now runs)
- Modify (guide, per `docs/guide/WRITING.md`): `docs/guide/start/setup.md`, `docs/guide/reference/settings.md`, `docs/guide/reference/cli.md`, `docs/guide/concepts/features-on-and-off.md` (paused vs off). `organization-policy.md` already changed in Task 1.

- [ ] **Step 1: Write** the docs. Every statement must match the code merged in Tasks 1–16.
- [ ] **Step 2: Verify** with `go test ./docs/guide` PASS (page size cap included), then `scripts/leak-check.sh` over the branch's commits.
- [ ] **Step 3: Commit** `docs: background AI consent (#1886)`.

---

### Task 18: Desktop launch sites carry an origin (static guard)

**Depends on:** Task 3, Task 12

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/CLIRunner.swift`: `package enum CLIOrigin { case owner, background }`. `CLIRunnerProtocol` gains `func run(args: [String], origin: CLIOrigin) async throws -> Data`, with a protocol-extension default that calls `run(args:)` for `.owner`. `CLIRunner` implements `.background` by adding `WATCHTOWER_AI_ORIGIN=background` to the resolved environment.
- Create: `WatchtowerDesktop/Tests/Core/Support/DesktopModelLaunchSites.swift`: `enum DesktopModelLaunchSites { static let sites: [String: Classification] }`, keyed by Sources-relative file path, with `Classification = .owner(gesture: String) | .background`. Seed it with the files and gestures of Decision 11.
- Create: `WatchtowerDesktop/Tests/Core/DesktopModelLaunchSitesTests.swift`

**Interfaces:**
- Consumes: `internal/aiconsent/testdata/model_commands.json` (Task 3).
- Produces: `CLIOrigin`, `CLIRunnerProtocol.run(args:origin:)`.

- [ ] **Step 1: Failing tests:**
  - `DesktopModelLaunchSitesTests.testEveryModelLaunchIsClassified`: scan every `.swift` file under `WatchtowerDesktop/Sources` for string-array literals (`[" … "]`, after `args:`, `arguments:`, `var args =` or `let args =`) whose leading string tokens match a path in `model_commands.json`. Every matching file must have an entry in `sites`, and the failure names the file and the command.
  - `testBackgroundSitesPassBackgroundOrigin`: every `.background` file contains `origin: .background`.
  - `testNoStaleEntries`: every key in `sites` still exists and still matches a model command.
  - `CLIRunnerTests.testBackgroundOriginSetsEnv`: a `.background` run against a fake environment provider puts `WATCHTOWER_AI_ORIGIN=background` in the child environment; `.owner` does not. Assert on the built `Process` through the existing environment seam; nothing is launched.
- [ ] **Step 2: Run** `make test-swift FILTER='DesktopModelLaunchSitesTests|CLIRunnerTests'` → FAIL.
- [ ] **Step 3: Implement.** No existing call site changes (all are owner today, Decision 11).
- [ ] **Step 4: Verify** that those filters PASS, then `make lint-swift`.
- [ ] **Step 5: Commit** `test(desktop): every Desktop model launch is classified by origin (#1886)`.

---

## Promises → tasks → tests

| Spec promise / writer / failure mode | Task | Test |
|---|---|---|
| §3.2 effective-state table, Go = Swift (BGAI-03) | 2, 12 | `TestBGAI03_SharedFixture`, `BackgroundAIConsentTests.sharedFixture` |
| §3.1 unknown value reads absent, logged once | 2 | `TestCurrent_UnknownValueReadsAbsent` |
| §3.3 mtime cache | 2 | `TestCurrent_RereadsOnlyOnMtimeChange` |
| §11 unreadable/unparsable config → paused | 2 | `TestCurrent_UnreadableConfigIsPaused` |
| §4.3 origin: ctx wins, env, marker → run trigger | 2 | `TestOrigin_ContextBeatsProcess`, `TestOrigin_EnvMarksBackground`, `TestOrigin_AutomationMarkerTakesRunTrigger`, `TestCheck_AdmittedBackgroundPasses`, `TestCheck_NoopOutsideTheDaemon`, `TestCheck_OwnerStartedPasses` |
| §4.3 backstop in every process's leaves | 4 | `TestPolicyCheckedGenerator_RefusesBackgroundOriginInAnyProcess`, `TestAgentloop_RefusesUnadmittedBackground`, `TestCLIAgentRunner_PausedSpawnsNothing` |
| §2.2 typed commands never gated (BGAI-02) | 4 | `TestBGAI02_TypedCommandNotGated` |
| §2.2 chats hosted by the daemon are gestures; the hub's own work stays gated | 4, 8 | `TestBGAI02_ChatEngineChildIsOwner`, `TestBGAI02_HubAndChatEngineMakeNoInProcessModelCall`, `TestBGAI02_DaemonUnmarkedCallStaysGated`, `TestBGAI01_EveryDaemonSpawnSetsOrigin` (chatengine and hub roots) |
| §2.3 Desktop launches: gestures only, any background one carries the origin | 3, 18 | `TestModelCommands_ExistInCLI`, `DesktopModelLaunchSitesTests`, `CLIRunnerTests.testBackgroundOriginSetsEnv` |
| D17 plan-limit read exempt | 4 | `TestPlanUsagePoller_NotGatedByConsent` |
| §4.1 phase gate, D12 running phase finishes | 5 | `TestBGAI01_PauseMidCycleFinishesPhaseSkipsNext` |
| §4.3 `ErrPaused` is a skip, not an error row | 5 | `TestBGAI01_PauseMidCycleSkipsWithoutErrorRow` |
| D12 backfill holds whole | 5 | `TestBGAI01_PausedHoldsBackfillWhole` |
| D3 reaction commands run | 5, 6 | `TestDaemon_ReactionCommandsRunWhilePaused`, `TestExecutor_OwnerStartedSyncRunPasses` |
| §4.1 log line once per change; writer `watchtower.log` | 5 | `TestDaemon_ConsentLogOncePerChange` |
| D4 which manifests grant AI; every primitive declares | 6 | `TestBuiltin_EveryPrimitiveDeclaresAI`, `TestManifest_UsesAISharedFixture` |
| §4.2 scheduler advance, writer `last_scheduled_for`; D11 no catch-up (AUTO-10) | 6 | `TestScheduler_PausedAdvancesWithoutRun`, `TestScheduler_AllowAfterPauseDoesNotCatchUp` |
| D4 non-AI recipe keeps running | 6 | `TestScheduler_NonAIRecipeRunsWhilePaused` |
| §4.2 bus skips AI recipes | 6 | `TestBus_PausedSkipsAIRecipes` |
| §4.2 executor backstop; writer cancelled rows; §11 run queued before pause | 6 | `TestExecutor_PausedCancelsBackgroundAIRun`, `TestCancelQueuedBackgroundPaused_OnlyQueued` |
| BGAI-02 manual/button/dry_run/reply | 6 | `TestBGAI02_ManualRunWhilePaused` |
| §4.2 / §11 admitted run finishes after pause | 6, 9 | `TestExecutor_AdmittedRunFinishesAfterPause`, `TestBGAI01_RunStartedBeforePauseFinishes` |
| §4.2 slots skip AI built-ins, mechanical run | 7 | `TestRunner_PausedSkipsAIBuiltinWritesNothing`, `TestRunner_MechanicalBuiltinRunsWhilePaused`, `TestRunWatchSlot_PausedSkipsWithoutGate` |
| Run Now at a slot (Decision 1) | 7 | `TestRunner_PausedStillRunsQueuedRunNow` |
| §4.3 every daemon spawn sets the origin; §11 missed spawn | 8 | `TestBGAI01_EveryDaemonSpawnSetsOrigin`, `TestBGAI01_SpawnCheckerCatchesNewSpawn`, `TestShellEnv_CarriesOrigin`, `TestAutomationAgentEnv_CarriesOrigin`, `TestCodexAgentServerEnv_NamesOrigin` |
| D20 sweep holds, reviewer backstop | 8 | `TestSpecReviewSweep_HoldsWhilePaused`, `TestLaunchSpecReview_SweepSetsOrigin`, `TestSpecReviewRun_BackgroundOriginPausedLeavesQueued` |
| BGAI-01 whole paused cycle makes no model call | 9 | `TestBGAI01_PausedCycleMakesNoModelCall` |
| A component built without a reader is gated (fail closed) | 2, 9 | `TestBGAI01_NilReaderFailsClosed`, `TestOverrideHookOnlyInTests` |
| §9 CLI status JSON, allow/pause, TTY, policy refusal; writer `config.yaml` | 3 | `TestAIBackground_*` |
| §3.1 `config set` refuses the key | 3 | `TestConfigSet_RefusesBackgroundRunsKey` |
| §4.4 allow signals, failure tolerated; §11 cannot signal | 3 | `TestAIBackground_AllowWritesAndSignals` |
| §9 `watchtower status` line | 3 | `TestStatus_BackgroundAILine` |
| §8 / POLICY-01/02 key, wrong type = false | 1 | `TestPolicy02_SharedFixture`, `TestPolicy01_WrongTypesFailClosed`, `TestPolicy01_KeysNeverCollideWithAppDefaults`, `ManagedPolicyTests.sharedFixture` |
| §6.5 / D19 heartbeat key, absent from old hub | 10 | `TestHeartbeat_CarriesBackgroundAI`, `TestBackgroundAIValue`, `TestHubContractFixture`, `HeartbeatPayloadTests.testBackgroundAIKeyIsOptional` |
| §6.5 phone line | 11 | `BackgroundAIConsentCopyTests.testPhoneLines`, `NowWiringTests.testBackgroundAILineFollowsHeartbeat` |
| §5.1 copy | 12 | `BackgroundAIConsentCopyTests` (Desktop) |
| §11 stale `ConfigService.save` keeps the answer; two writers share the file lock | 3, 12 | `ConfigServiceTests.testSaveKeepsBackgroundRunsKey`, `testSaveHoldsConfigLockAroundReadAndWrite`, `ConfigFileLockTests`, `TestConfigLock_ExcludesSecondHolder`, `TestSetConfigKey_LocksAroundReadAndWrite` |
| An answer given in a terminal reaches the Desktop | 12, 13 | `BackgroundAIConsentRefresherTests.testActivationRereadsAnswer`, `BackgroundAIConsentPromptTests.testClosesWhenAnsweredElsewhere` |
| §5 model: allow/pause args, saving, error; §11 write fails | 13 | `BackgroundAIConsentModelTests` |
| §5.2 / D8 onboarding step, skipped when decided; §11 re-run | 13 | `OnboardingStateMachineV2Tests.testConsentStepSkippedWhenDecided`, `testParkedOnConnectResumesThroughConsent`, `testUnknownRawValueStillStartsAtGoals` |
| §7 sheet once until answered; §11 never answered | 13 | `BackgroundAIConsentPromptTests.testShownOnceUntilAnsweredAfterOnboarding` |
| §6.1 Settings switch states | 14 | `BackgroundAISettingsPresentationTests` |
| §6.2 / D15 readiness | 15 | `FeatureReadinessTests.testBackgroundAIPausedOnlyForAIFeatures`, `testContentWinsOverPaused`, `testPausedBeforeDaemonStopped`, `testManagedPausedHasNoButton` |
| §6.3 / D10 Home card survives Hide | 15 | `GettingReadyTests.testPausedLeavesAIFeatureCardsOut`, `HomeBackgroundAICardTests.testPausedCardSurvivesHidingGettingReady` |
| §6.4 Automations notice and chip | 16 | `AutomationAIUseTests.sharedFixture`, `AutomationListSectionsTests.testPausedAIRowShowsWaiting` and siblings |
| Mockups render; live views beside them | 12–16 | `DesignShotsTests.testBackgroundAIConsentShotsRender` (filter `ai-consent-`) |
| §11 policy changes while running (30 s cache) | 2 | inherited `policy.Current()` cache; documented in Task 17 |
| §11 old daemon / mixed versions | — | not testable in-process; documented in Task 17 |
| §13 contracts: BGAI inventory, POLICY, AUTO-10, FEAT-01, BACKFILL, spec-review, heartbeat notes | 1, 6, 8, 9, 10 | inventory Changelog entries naming ask #1452 |
| §15 docs and guide | 17 | `go test ./docs/guide` |
