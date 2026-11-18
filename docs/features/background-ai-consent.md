# Background AI consent — one explicit "yes" before Watchtower runs AI on its own (2026-11-18, board #1886)

Spec: `docs/superpowers/specs/2026-11-17-background-ai-consent-design.md` (decisions D1–D20, ask #1452). Plan: `docs/superpowers/plans/2026-11-18-background-ai-consent.md` (agent decisions 1–12, review #1484). Inventory: BGAI-01..03 in [`docs/inventory/background-ai.md`](../inventory/background-ai.md); POLICY-01/02/03 and AUTO-10 amended (ask #1452). User guide: `docs/guide/reference/settings.md` (Background AI), `docs/guide/concepts/features-on-and-off.md` (paused vs off), `docs/guide/reference/cli.md` (`ai background`), `docs/guide/reference/organization-policy.md` (`AllowBackgroundAI`).

**The rule, for code comments and docs:** background = started by a timer, a sync cycle or an event; not by the owner's own gesture. Sync and every gesture keep running while background AI is paused; only background model work waits.

## The answer and the effective state

- **Owner answer:** `config.yaml` `ai.background_runs: allowed | paused`; absent = not answered. Any other value reads as absent (logged once). Per Mac user, not per workspace; no consent date is stored, no telemetry (D16) — `watchtower.log` is the only trace.
- **Policy:** the forced MDM key `AllowBackgroundAI` (`policy.Keyset.AllowBackgroundAI *bool`, Swift `ManagedPolicy.allowBackgroundAI`). `true` stands in for an owner who has not answered (no prompt) and never overrides the owner's `paused`; `false` (and a wrong type, POLICY-01) = paused, switch locked, `allow` refused before writing. It is the first policy key that grants rather than restricts — POLICY-03 carries the exception.
- **Resolver, one per language:** Go `aiconsent.Resolve(answer, policy) State`, Swift `BackgroundAIConsent.resolve(answer:policy:)` (WatchtowerCore). `State` = effective (`allowed|paused`), reason (`unanswered|owner|organization`), `prompt`, `locked`. The table is spec §3.2, verbatim in the shared fixture **`internal/aiconsent/testdata/consent_cases.json`** (BGAI-03: `TestBGAI03_SharedFixture`, `BackgroundAIConsentTests.testSharedFixture`).
- **Go reading** (`internal/aiconsent`, a leaf package): `Current()` stats `config.yaml` per call and re-parses only on an mtime/mode change; the policy comes through `policy.Current()` (30 s cache). No config path, a file that cannot be read or parsed, or an ambiguous key case → paused (fail closed). `SetConfigPath` is wired in `cmd/root.go` for every process.
- **Swift reading:** `ConfigService` reads `ai.background_runs` (keys folded as Go's `lookupFold`) and never writes it from `save()`; `AppState.backgroundAI` resolves it with `ManagedPolicyCenter`'s value, observed. `BackgroundAIConsentRefresher` re-reads the answer on `NSApplication.didBecomeActiveNotification` (the policy's trigger) and after the Desktop's own CLI call — no file watcher (plan Decision 12). An unreadable `config.yaml` reads paused and sets `AppState.backgroundAIConfigUnreadable`.

## Writers

| Data | Writer | Readers |
|---|---|---|
| `ai.background_runs` | `watchtower ai background allow\|pause` only (`cmd/ai_background.go`, through `setConfigKey`); `config set ai.background_runs …` is refused ("… use \"watchtower ai background allow\|pause\"; nothing was written") | `aiconsent.Current()`, `ConfigService` (read only), `ai background status`, `watchtower status` |
| `AllowBackgroundAI` | the organization's profile | `policy.Current()`, `ManagedPolicyCenter` |
| `automation_runs` cancelled rows | the executor's claim check (`db.CancelQueuedBackgroundPaused`) | Automations tab, `automations runs` |
| `last_scheduled_for` | the scheduler (existing CAS) | the scheduler |

**The config lock.** Every writer of `config.yaml`, in both languages, re-reads and writes it inside one exclusive `flock(2)` on `<config.yaml>.lock`: Go `config.WithWriteLock(path, func(*config.WriteLock) error)` (the token has no exported constructor; the low-level writers require it, so a write outside the lock does not compile), Swift `ConfigFileLock.withLock` + `ConfigFileWriter.write` (atomic temp + rename, `0600`). Each writer changes only its own keys, so a Desktop `save()` with a stale snapshot can never drop the answer. Go blocks for the lock; Swift tries `LOCK_NB` with a ~2 s bounded retry, then a retryable busy error (it runs on the main actor). The lock is not re-entrant: a nested `WithWriteLock` in one process returns `config.ErrWriteLockHeld` at once. In-process writers are not queued. Readers take no lock. Guards: `TestConfigWriters_OnlyThroughWriteLock` (Go AST), `ConfigWritersTests.testOnlyConfigFileWriterWritesConfig` (Swift scan).

## Origin: who started a model call

Every model call is `owner` or `background` (D18):

1. **The ctx wins.** `aiconsent.WithOwnerStarted(ctx)` → owner (executor `manual`/`button`/`dry_run`/`reply` runs, the reaction poll, the daemon-hosted chat title). `aiconsent.WithAdmitted(ctx, unit)` → background, admitted (a cycle phase `phase:<name>`, a claimed run, a reviewer relaunch).
2. **Else the process default** (`aiconsent.InitProcess`, `cmd/root.go`): `sync --daemon` → background; `WATCHTOWER_AI_ORIGIN=background` → background (`WATCHTOWER_AI_ADMITTED=<unit>` → admitted); under `WATCHTOWER_AUTOMATION_RUN_ID` → the run's trigger (`aiconsent.BackgroundTrigger`: `schedule`, `catch_up`, `event`, `sync`), read once at start, a failed lookup → background; everything else → owner.

`aiconsent.Check(ctx)` refuses a background, non-admitted call while the state is not `allowed` with `aiconsent.ErrPaused` ("Background AI is paused"). It runs in every process, in the leaves: `policyCheckedGenerator` / `policyCheckedProvider` (`cmd/provider_policy.go`), the tool-route provider, the one-off and REPL clients, the `agentloop` runner and the `agent()` CLI runner. Callers treat `ErrPaused` as a skip: no `error` row, no "Didn't work yet", no spent attempt (`trackedPipelineRun`, the morning brief, Jira board refresh).

**Spawns.** A background unit's child gets `aiconsent.ChildEnv(ctx)` (origin plus admitted unit): `LaunchSpecReview` from the sweep, the `agent()` children and their `mcp --surface automation` server (codex's `env_vars` names both), `shell()`'s environment. The chat engine's turn children (`execStart`, `listenStart`) build theirs with `aiconsent.OwnerEnv(os.Environ())`: each serves one owner request, so the owner's chat works while paused even though the daemon hosts the engine (plan Decision 3). No root ctx is ever marked owner.

## Enforcement points

- **Daemon cycle:** `(*Daemon).aiPhase(ctx, name, fn)` (`internal/daemon/ai_consent.go`) reads `consentNow()` before each AI phase (digests, media, stream digests, memory, next step, history backfill, coach, and the legacy fallbacks of the morning brief, the idea finder and the custom-track scan; Track my threads and people cards read it once when their parallel group starts) and returns before the phase's own checks, lock or `pipeline_runs` row (FEAT-01's position). The fetch section, the reaction poll, the event flush and every mechanical phase are untouched. The backfill holds whole (no fetch, no row change, no strike); memory does not wait for a paused backfill. The paused line (`aiconsent.LogLine`) is logged once per state change.
- **Built-ins at their slot:** `builtin.Runner.RunSlot` executes a queued Run Now first (`TakeQueuedBuiltinRun`, an owner gesture), then skips an AI built-in as `SkippedPaused` before its gate and row, and re-checks after the gate read. Watch slots do the same. Mechanical built-ins (Waiting for me, Needs approval) run.
- **Scheduler:** once per Tick; a due time of a runnable AI `schedule` automation advances `last_scheduled_for` with the existing CAS and inserts nothing, so allowing again never catches up a paused window (AUTO-10 as amended).
- **Bus:** `Begin` leaves AI recipes out of the cycle's subscribers while paused.
- **Executor:** `heldForConsent` before a claim — a queued `schedule`/`catch_up`/`event`/`sync` run of an AI recipe ends `cancelled`, `error_kind = 'cancelled'`, error `Background AI is paused`. An owner-started ctx is never held, whatever the trigger: a reaction command queues a `sync` run (D3), and it runs.
- **Which recipes are AI** (`automations.PermissionsUseAI` / `AutomationUsesAI`, Swift twin `AutomationAIUse.usesAI`): `llm:*`, `agent:run`, `session:start`, `track:scan`, or `builtin:<p>` where `automations.PrimitiveUsesAI[p]`. An undecodable `permissions_json` is AI in Go (fail closed). Shared fixture **`internal/automations/testdata/uses_ai_cases.json`** (`TestManifest_UsesAISharedFixture`, `AutomationAIUseTests.testSharedFixture`); `TestManifest_UsesAIFixtureCoversEveryPrimitive` needs a row per primitive, `TestBuiltin_EveryPrimitiveDeclaresAI` a declaration per primitive.
- **Spec review (D20):** the sweep holds queued rows while paused (no relaunch, `attempt` unchanged); `runSpecReviewRun` calls `aiconsent.Check` before claiming. The first launch from the owner's session is owner work. See `spec-review.md`.
- **Jira board auto-refresh** is background and gated too; a typed `jira boards analyze` is not.
- **Never gated:** the plan-limit read and the Codex rate-limit read (D17, `TestPlanUsagePoller_NotGatedByConsent`), sync, and every gesture of spec §2.2.

A unit already admitted when the owner pauses finishes within its budget (D12); the next one does not start.

## Desktop

- **Consent screen:** `BackgroundAIConsentView` over `BackgroundAIConsentModel` (Core), strings in `BackgroundAIConsentCopy` (Core; phone strings in the Kit's own `BackgroundAIConsentCopy`). Allow → `ai background allow --yes`; Not now → `ai background pause`. The agent, reserve, poll interval and backfill days it discloses are read from `config.yaml` as saved (`BackgroundAIConsentSetup.read`), never Settings' edit buffer. Two hosts: onboarding's `aiConsent` step (`BackgroundAIConsentStep`, see `onboarding-v2.md`) and the upgrade sheet.
- **Upgrade sheet:** `BackgroundAIConsentPresenter` on `MainNavigationView`, state in `BackgroundAIConsentSheet` (Core). Once per launch while `onboarding_done = 1` and `prompt`; waits for the What's New pass to settle (`UpdateService.isWhatsNewSettled`) and for the release-notes window to close; no close button, Esc ignored. A sheet on screen is only brought forward by a re-entry; one wanted but never mounted is re-asserted with a model rebuilt from the saved file. An unreadable `config.yaml` shows the alert "Watchtower can't read config.yaml" instead of the sheet.
- **Re-entry (D9, D10):** `AppState.presentBackgroundAIConsent()` is the one entry for Settings' switch (on), Home's card, the empty states and the Automations notice. Off in Settings runs `pause` directly (`BackgroundAISettingsModel`); a failed pause shows "Couldn't pause background AI: <error>. It is still on."
- **Settings → System → AI → Background AI:** `BackgroundAISettingsSection` in `ProviderSettings`, captions from `BackgroundAISettingsPresentation` (the caption's agent is `ConfigService.savedAIProvider`).
- **Readiness, Home, empty states:** `Readiness.backgroundAIPaused(managed:)` for `ReadinessFeature.usesBackgroundAI` features; Home's `HomeBackgroundAICard` above Getting ready; see `first-run.md`.
- **Automations:** `AutomationsBackgroundAINotice` and the row chip **Waiting** (`AutomationRowPresentation.isHeld`: runnable, trigger `schedule|event|sync`, AI); see `automations.md`.
- **Model launches carry an origin** (plan Decision 11, Task 18). Model commands launch only through `CLIRunnerProtocol.runModel(args:origin:…)` (`CLIOrigin.owner|background`, no default); every generic `CLIRunner` entry refuses a final argv that matches the model-command list, however it was built. `TerminalTitleService` takes the origin from the session: owner, unless an automation run started it. Guards: `DesktopModelLaunchSitesTests` (every Process launch of the CLI listed with a reason, no stale entries, model-argv literals only beside `runModel`), `ModelCommandsTests`.
- **Phone (D19):** the hub heartbeat's optional `background_ai` key (`allowed|paused|organization`, see `go-hub.md`) drives one line on the phone's Now tab; the phone cannot allow.

## The model-command list

**`internal/aiconsent/testdata/model_commands.json`** lists every CLI command path that can call a model. Go `TestModelCommands_ExistInCLI` keeps each path real and `TestModelCommands_JSONIsSorted` its order. The Desktop's `ModelCommands.paths` is a compiled Swift literal (Core has no resource bundle in the packaged app), checked byte for byte against the JSON by `ModelCommandsTests.testBundledListMatchesGoFixture`, so an edit to either side alone fails. `ModelCommands.globalValueFlags` must name every root persistent flag that takes a value (`testGlobalValueFlagsMatchTheGoRoot`).

## Adding something that calls a model

- **A new CLI command that can call a model** goes into `internal/aiconsent/testdata/model_commands.json` and the Swift `ModelCommands.paths` literal, in the same change. Nothing finds the command for you: `TestModelCommands_ExistInCLI` only checks that listed paths exist.
- **A new in-daemon path that serves the owner** (a hub or chat-engine callback, a handler) marks that request's ctx `aiconsent.WithOwnerStarted`; never mark a root ctx. Unmarked, it stays background and is refused while paused (fail closed).
- **A new background unit** gates where it starts (`aiPhase`, or a consent reader read before its row), admits its ctx (`WithAdmitted`) and gives every child `aiconsent.ChildEnv(ctx)`. `TestBGAI01_EveryDaemonSpawnSetsOrigin` walks `internal/daemon`, `internal/automations`, `internal/chatengine`, `internal/hub` and the launchers in `cmd`.
- **A new component with a consent reader** defaults to `aiconsent.Current` when nil (never "ungated"). Test packages that build gated components call `aiconsenttest.AllowByDefault()` in `TestMain`.
- **A new built-in primitive** declares `automations.PrimitiveUsesAI` and gets a row in `uses_ai_cases.json`.

## CLI

- `watchtower ai background status [--json]` — keys `effective`, `reason`, `answer` (`allowed|paused|""`), `policy` (`true|false|null`); reads config and policy only, no database.
- `watchtower ai background allow [--yes]` — refused under policy `false` before anything; without `--yes` it needs a terminal, prints the consent text and asks "Allow background AI? [y/N]" (no → "Nothing changed."); writes `allowed`, sends the daemon `SIGUSR1` best effort (a failure is a stderr line, the write stands), prints the new status line. Creates `config.yaml` when it is missing.
- `watchtower ai background pause` — writes `paused`; never refused.
- `watchtower status` prints one line: "Background AI: allowed" / "paused (not answered) — allow with `watchtower ai background allow`" / "paused by you" / "turned off by your organization".
- A daemon run without the Desktop is paused until `allow`; its log says how.

## v1 limits

- **Started units finish.** Up to one run's budget (15 min for the built-ins), one running phase or one launched reviewer can still spend after a pause (D12).
- **Policy cache.** A profile change applies within `policy.Current()`'s 30 s cache.
- **Mixed versions.** An older daemon ignores the key and keeps running AI until restarted; the Desktop restarts it after an upgrade.
- **Tray-only launch.** The upgrade sheet lives on the main window; with the window closed it appears when the window next opens.
- **Phone wording on a headless server.** The phone's paused line says "on your Mac" also when the hub runs on a headless server Tower; a server variant needs new copy from the owner.
- **Automation terminal titles after a run is deleted.** `terminal_sessions.automation_run_id` is `SET NULL` when its run row is deleted, so an automation session titled after that reads as the owner's and is titled while paused. A fix needs a launch-origin column (a migration).
- **Undecodable `permissions_json` (UI only).** Go reads it as AI and holds the run; Swift decodes it to `[]`, so the row shows no **Waiting** chip.
- **Stale unreadable flag on a sheet retry.** An unmounted sheet's retry trusts the cached `configUnreadable`; a file repaired between the cache and the retry shows a stale alert until the next activation refresh.
- **Spawn checker heuristics.** `TestBGAI01_EveryDaemonSpawnSetsOrigin` matches `ProcAttr` evidence by name across blocks and can false-positive on a `var` value spec, so a rare unmarked spawn sharing a name could pass the static net (the per-call `Check` still refuses it).
- **Callback checker scope.** `TestBGAI02_HostedCallbacksNameTheirOrigin` inspects func literals handed to the hub or chat engine only; a named func, method value or constructor result is not inspected (a missed one is refused while paused).
- **Track my threads paused test.** Its "no row while paused" test is vacuous on its own (the gate also needs digests and an owner); the runner's shared pre-enqueue check is proven on the morning brief and the idea finder instead.
- **Non-ASCII key folding.** Go and Viper may fold a hand-written non-ASCII duplicate of the key differently (config keys are ASCII).
- **A dry run started from inside an admitted background run** (by its `agent()` child) is a `dry_run` trigger, so its calls get owner origin (spec §4.2 taken literally).
