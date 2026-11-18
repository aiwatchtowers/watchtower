# Background AI consent — one explicit "yes" before Watchtower runs AI on its own

**Date:** 2026-11-17 · **Board:** target #1886 · **Status:** draft for review
**Owner decision:** ask #1415 — «Да, один раз в онбординге»: one consent screen in onboarding; existing installs see it once after the upgrade.
**Mockups:** `docs/design/mockups/background-ai-consent/` (DesignShot scenes `ai-consent-*`, light and dark). The PNGs live on branch `feature/1886-background-ai-consent`.

## Goal

Watchtower launches the owner's own Claude Code or Codex CLI, on the owner's own subscription, many times a day without the owner typing anything: digests after each sync, the morning briefing, people cards, memory, scheduled and event automations. OpenAI's Sign in with ChatGPT terms allow "expressly authorized automations or background processes" and require "express consent before background use"; Anthropic's consumer terms ban "automated or non-human means" except where Anthropic "explicitly permit[s] it" and say nothing about consented background runs (vendor-terms research, 2026-11-17, kept outside the repo). The safe shape for both vendors is the same: background AI runs only after the owner said yes on a screen that says what runs, on whose plan, how often, and how to turn it off.

This spec defines:

1. What counts as background AI, and what does not (§2).
2. Where the answer lives and how Go and Swift read it the same way (§3).
3. How every background path is held without the answer, while sync keeps running (§4).
4. The screens: onboarding's last step, the one-time upgrade sheet, Settings, Home, empty states, Automations (§5, §6).
5. The upgrade path, the MDM key, the CLI and headless daemon (§7–§9).
6. Writers, failure modes, tests and the contracts touched (§10–§13).

No production code changes with this spec. The mockups are design-only SwiftUI scenes in the DesignShots test target (`BackgroundAIConsentShotFixtures`, strings in `BackgroundAIConsentMockCopy`, pinned by `BackgroundAIConsentMockCopyTests`).

## Decisions

| # | Decision | Source |
|---|---|---|
| D1 | One consent screen. A fresh install answers it as onboarding's last step; an existing install answers it once, in a sheet, after the upgrade. | ask #1415 |
| D2 | Background AI = model calls started by a timer, a sync cycle or an event, in any process: the daemon's AI phases, the history backfill's AI pass, automation runs triggered by `schedule`, `catch_up`, `event` or `sync` (and every process they start), and the spec-review sweep's relaunches. Everything the owner starts with a gesture (a click, a typed command or message, Run now, an Inbox button, a reply) is never gated. | agent proposal, accepted in ask #1452 |
| D3 | A Slack reaction from the owner's dictionary is a gesture: reaction commands run while background AI is paused. Automations that *listen* to reactions (`slack.reaction_added` event recipes) are automations and wait. | ask #1452 (agent proposal, approved) |
| D4 | An automation run is held only when its manifest grants AI (`llm:*`, `agent:run`, `session:start`, or a `builtin:` primitive that calls a model). A recipe that only runs `shell()`, `mcp()` or registry reads keeps running, and so do the mechanical built-ins (Waiting for me, Needs approval). | ask #1452 (agent proposal, approved) |
| D5 | Until an existing install answers, background AI is **paused** (not kept running). Sync keeps running. The sheet appears at the first launch after the upgrade, so the gap is normally minutes. | ask #1452 (agent proposal, approved) |
| D6 | The answer is stored in `config.yaml` as `ai.background_runs: allowed \| paused` (absent = not answered). It is per Mac user, not per workspace. Its only writer is `watchtower ai background allow\|pause`. No consent date is stored. | agent proposal, accepted in ask #1452 |
| D7 | MDM key `AllowBackgroundAI` (boolean). `true` = the organization consents for an owner who has not answered (no prompt); the owner can still pause. `false` = forbidden: paused, the switch locked, `allow` refused. Wrong type = `false` (POLICY-01). | ask #1452 (agent proposal, approved) |
| D8 | The onboarding step comes last (Goals · Connect · Background AI), after the agent is picked and before the daemon starts. It is skipped when the answer is already decided (answered, or decided by policy), so a re-run never asks again. | agent proposal, accepted in ask #1452 |
| D9 | Every path that turns background AI on goes through the one consent screen (the Settings switch, the Home card, the empty-state button all open it). Pausing is one click with no confirmation. | agent proposal, accepted in ask #1452 |
| D10 | **Not now** is an answer (`paused`). Watchtower never asks again by itself; Home, the empty states and Automations offer **Allow background AI…**. | ask #1452 (agent proposal, approved) |
| D11 | Allowing again resumes like a daemon that was stopped: no fast-forward, the pipelines process what accumulated within their existing windows. Automations never catch up a paused window. | agent proposal, accepted in ask #1452 |
| D12 | Pausing stops every background **unit** that has not started yet (a cycle's AI phase, an automation run, a backfill chunk, a reviewer relaunch). A unit already started when the owner pauses finishes within its existing budget; nothing is killed and nothing is left half-done. The history backfill holds (no fetch, rows untouched). | ask #1452 (agent proposal, approved) |
| D13 | One switch for every provider, Ollama included; the screen names the configured agent. | agent proposal, accepted in ask #1452 |
| D14 | `watchtower ai background allow` shows the consent text and asks y/N on a terminal; `--yes` skips the question (the Desktop passes it after its own screen). Non-interactive without `--yes` is refused. | agent proposal, accepted in ask #1452 |
| D15 | Readiness gets one new state, `backgroundAIPaused(managed:)`, placed after `needsDigests` and before `daemonStopped`. Home shows one "Background AI is paused" card above the feed, outside the hideable Getting ready zone, which leaves out the paused features' cards. | agent proposal, accepted in ask #1452 |
| D16 | No telemetry: the answer and the pause are local only; a log line in `watchtower.log` is the only trace. | agent proposal, accepted in ask #1452 |
| D17 | The plan-limit read (the plan-usage poller) is exempt: it is no AI run. Today it reads the plan's limits; with #1885 it launches the `claude` CLI with `get_usage` every 5 minutes. That starts no model turn, writes no `llm_calls` row and spends no usage. It keeps running while background AI is paused. Same exemption as #1885's A8. | ask #1452 (agent proposal, approved) |
| D18 | The gate is not tied to the daemon: every model call carries an **origin** (`owner` or `background`), and the leaf wrappers in every Watchtower process refuse a `background` call without consent. The daemon, the processes it or a background automation run starts, and the spec-review sweep's relaunch are `background`; everything else defaults to `owner` (§4.3). | ask #1452 (agent proposal, approved) |
| D19 | The phone gets one line on Home while the Mac's background AI is paused or forbidden, from a new optional `background_ai` key in the hub heartbeat. The phone cannot allow it; the line says to allow it on the Mac. | ask #1452 (agent proposal, approved) |
| D20 | A spec review's first reviewer launch, made when the agent in the owner's own session files the ask, is part of that session (owner origin). The daemon sweep's relaunch of a queued review is background and waits while paused; the row stays queued and no attempt is spent. | ask #1452 (agent proposal, approved) |

D3, D4, D5, D7, D10, D12 and D17–D20 were approved in ask #1452 (it replaced ask #1445), together with the contracts in §13 and the remaining agent decisions (D2, D6, D8, D9, D11, D13–D16).

## 1. Context (recon, 2026-11-17)

- **The daemon cycle** is `runSync` (`internal/daemon/daemon.go`): the fetch section (purge, Slack, reaction poll, calendar, CalDAV, Gmail, IMAP, Jira, Linear, Confluence, lease purges, automation event flush, agent analytics), then the pipeline section, then the history backfill, coach and the spec-review sweep. Automations are not a phase: `Daemon.Run` runs the scheduler and the executor as goroutines beside the loop (`cmd/automations_daemon.go` `wireAutomations`).
- **The daemon's generators** are built in `cmd/generator.go` (`cliPooledGenerator`, `cliBoundedGenerator`, `routedGenerator`) and every leaf sits behind `policyCheckedGenerator` / `policyCheckedProvider` (`cmd/provider_policy.go`), which already ask the MDM policy per call. This is where a per-call backstop goes.
- **Process role** is set by `cmd/process_role.go` (`daemon` for `sync --daemon`), so a check can know it runs in the daemon.
- **Automation triggers** (`automation_runs.trigger`): `schedule`, `catch_up`, `button`, `event`, `manual`, `dry_run`, `reply`, `sync`. `error_kind` already has `cancelled`; no migration is needed.
- **Readiness** (`docs/features/first-run.md`): `FeatureReadiness.evaluate` over `ReadinessInputs`, first match wins; `FeatureEmptyState` draws the line and the one button; Home's Getting ready zone reads the same states (`GettingReadyPolicy`).
- **Onboarding** (`docs/features/onboarding-v2.md`): `OnboardingV2Step` = `purpose`, `connect`, `complete`, persisted by raw value; the agent (Claude Code or Codex) is picked on Goals; the daemon starts at the finish.
- **MDM** (`docs/features/mdm-policy.md`, POLICY-01..03): forced keys only, Go `internal/policy` and the Swift twin `ManagedPolicy` read one shared fixture.
- **Config writes:** the Desktop writes config through the CLI (`watchtower config set`) or `ConfigService.save`, which re-reads the file before writing and only touches its own keys, so a key it does not manage survives.

## 2. What counts as background AI

### 2.1 Gated (needs the answer)

| Entry point | Where | What it runs | Gate |
|---|---|---|---|
| Channel digests | `phaseChannelDigests` | `digest.channel*`, `digest.daily/weekly/period` | phase gate |
| Image and link descriptions | `phaseMediaDescribe` | `media.describe` | phase gate |
| Custom-track slot, Track my threads | `phaseWatchSlot`, `phaseTrackMyThreads` | `customtrack.*`, `tracks.extract*` | slot skip (manifest rule, §4.2) |
| People cards | `phasePeopleCards` | `people.*` | phase gate |
| Jira and mail digests | `phaseStreamDigests` | `ideas.digest_jira`, `ideas.digest_email` | phase gate |
| Idea finder (built-in) | `phaseIdeaFinder` | `ideas.consolidate` | slot skip (manifest rule, §4.2) |
| Memory | `phaseMemory` | memory extraction | phase gate |
| Next steps | `phaseNextStep` | `targets.next_step` | phase gate |
| Morning brief (briefing, day plan) | `phaseMorningBrief` | `briefing.daily`, `day_plan.generate` | slot skip (manifest rule, §4.2) |
| History backfill | `phaseHistoryBackfill` | the AI pipelines over each chunk | phase gate (whole phase holds, D12) |
| Agent coach | `phaseCoach` (weekly) | `coach.propose` | phase gate |
| Scheduled automations | scheduler | `llm()`, `agent()`, `session()` | scheduler skip + executor check (D4) |
| Event automations | `automations.Bus` | same | bus skip + executor check |
| Built-ins at their slot (`sync` trigger) | `RunSlot` | `builtin:` primitives that call a model | slot skip + executor check |
| Spec-review relaunch | `phaseSpecReviewSweep` → detached `workbench spec-review run --ask N` | the reviewer agent | the sweep holds queued rows (D20) + the child's origin env (§4.3) |
| A process a background unit starts | `shell()` children, `agent()` CLI children and their `mcp --surface automation` server, the reviewer relaunch | any `watchtower` command that calls a model | origin `background` (§4.3) |
| Anything else that calls a model with origin `background` | any process | any | per-call backstop (§4.3) |

### 2.2 Never gated

- **Sync and the mechanical phases:** the mechanical built-ins Waiting for me (`builtin:attention.waiting`) and Needs approval (`builtin:approvals.list`), account purge, every source sync, the reaction poll, the automation event flush (it only queues; the bus drops AI recipes while paused, §4.2), agent analytics, unsnooze, approval sweep, transcript audio cleanup, the knowledge index (mechanical, KB-02), the messages search rebuild, the Inbox (mechanical, attention detection), the spec-review sweep's repairs (failing dead or overdue reviews, the author-loop and question sweeps; only its relaunch is gated), the LLM ledger import. The plan-limit read is exempt by decision D17 (ask #1452).
- **Owner gestures:** every chat (main, embedded, target, tuning, spec-review Discuss, Reviewer), Catch-Up, the workbench terminals and sessions the owner starts or answers, every CLI command typed by the owner (`watchtower sync`, `digest generate`, `briefing generate`, `coach run`, …, including when the Desktop runs it for a button), automation runs triggered by `manual`, `button`, `dry_run` or `reply`, reaction commands (D3), dictation clean-up, meeting notes and recaps after a recording the owner made (on the Mac or the phone), chat and terminal titles of the owner's own sessions, the first reviewer launch of a spec review filed from the owner's session (D20), meeting prep opened by the owner, and the Go hub's work for the phone (phone chats and recordings are the owner's gestures).
- **A session an automation starts** (`session()`) is held with its run: the run itself never starts while paused.

The rule in one line, used in docs and code comments: **background = started by a timer, a sync cycle or an event; not by the owner's own gesture.**

### 2.3 Background starts outside the daemon (recon, 2026-11-17)

The gate must not depend on which process makes the call (D18). Recon of every non-daemon place that can start a model run without a gesture:

- **Processes the daemon starts.** `grep -n "exec.Command" internal/daemon/*.go cmd/workbench_spec_review_launch.go` finds `ps` (process identity) and `LaunchSpecReview`'s `workbench spec-review run`; the automation runtime starts `claude`/`codex` children for `agent()`, their `watchtower mcp --surface automation` server, and `/bin/sh -c` for `shell()` (`internal/automations/sdk_agent.go`, `sdk_shell.go`). Every one of them is background when the unit that started it is, so it carries the origin (§4.3).
- **launchd.** `internal/service/launchd.go` installs one LaunchAgent, `<exe> sync --daemon` (`KeepAlive`, no `StartInterval`/`StartCalendarInterval`): it is the daemon itself. `packaging/` holds only the Homebrew tap. No other scheduled job exists.
- **The Desktop.** Every Desktop call of a model-running CLI command sits behind a view or a button: `BriefingViewModel` and `DayPlanViewModel` (`generate`), `CatchUpViewModel` (`catchup run`), `CoachCenter.runNow` (`coach run`), `TargetNextStepService`/`TargetSuggestLinksService` (`TargetDetailView`), `TargetExtractService` (`PromoteSubItemSheet`, `TargetExtractCenter`), `TrackComposeService`/`TrackScanService` (track sheets), `MeetingTopicsExtractService`/`MeetingRecapService` (their sheets), `TranscriptSaveService` (the recap after a recording the owner made), `MeetingPrepViewModel.startIfNeeded` (when the owner opens a meeting's prep). `grep -rln "Timer\.\|scheduledTimer\|Task.sleep"` over `WatchtowerDesktop/Sources`, crossed with the files that run the CLI, finds polls of status, usage, analytics, purge, hub and session state, none of which runs a model. The Desktop starts no model run on a timer today.
- **The Go hub.** `internal/hub` has no model call (`grep -rln "digest.Generator\|ai.Provider\|QuerySync" internal/hub` finds nothing); it serves the phone's requests.

- **Every background launch of the `claude` (or `codex`) CLI**, for the record:
  - the daemon's AI phases (through the generator leaves): gated;
  - `agent()` children of background automation runs: gated;
  - the reviewer process of a sweep relaunch, which starts the reviewer agent: gated (D20);
  - **the plan-limit read** (`claude` with `get_usage` every 5 minutes after #1885; no model turn, no `llm_calls` row): **exempt**, D17, ask #1452;
  - the Codex rate-limit read through `codex app-server` (`account/rateLimits/read`, no model turn): exempt on the same grounds, under the same decision.

So today every background start is the daemon or something the daemon started. The origin model of §4.3 still puts the check in the leaf of every process, so a future timer outside the daemon only has to declare its origin, and the guard tests of §12 make that mandatory for the daemon's own spawns.

## 3. The answer and where it lives

### 3.1 Inputs

- **Owner answer** — `config.yaml`, `ai.background_runs`: `allowed`, `paused`, or absent (not answered). Any other value reads as absent (and is logged once). Written only by `watchtower ai background allow|pause` through the same config writer as `config set` (D6). `config set ai.background_runs …` is refused with "use `watchtower ai background allow|pause`".
- **Policy** — the forced `AllowBackgroundAI` boolean of `com.watchtower.desktop` (§8): absent, `true` or `false`.

### 3.2 The effective state

One pure function on each side: Go `aiconsent.Resolve(answer, policy) State`, Swift `BackgroundAIConsent.resolve(answer:policy:)` (WatchtowerCore). `State` = `{effective: allowed|paused, reason: unanswered|owner|organization, prompt: bool, locked: bool}`.

| Owner answer | Policy | Effective | Reason | Prompt (sheet / step) | Settings switch |
|---|---|---|---|---|---|
| absent | absent | paused | unanswered | yes | off, usable |
| allowed | absent | allowed | owner | no | on, usable |
| paused | absent | paused | owner | no | off, usable |
| absent | `true` | allowed | organization | no | on, usable (caption "Allowed by your organization…") |
| allowed | `true` | allowed | owner | no | on, usable |
| paused | `true` | paused | owner | no | off, usable |
| any | `false` | paused | organization | no | off, locked |
| any | wrong type | paused | organization | no | off, locked (POLICY-01) |

Shared fixture: `internal/aiconsent/testdata/consent_cases.json`, run by `TestBGAI03_SharedFixture` (Go) and `BackgroundAIConsentTests.sharedFixture` (Swift) — the POLICY-02 pattern.

### 3.3 Reading it

- **Go** (`internal/aiconsent`, a leaf package): `Current()` reads the owner answer from the config file with an mtime cache (a `stat` per call, a re-parse only when the file changed) and the policy through `policy.Current()` (30 s cache). A config file that cannot be read or parsed reads as absent (paused, fail closed; logged once per change). `Check(ctx)` runs in every process and refuses only a call whose origin is `background` (§4.3), so typed CLI commands are never gated.
- **Swift:** `ConfigService` reads `ai.background_runs` with the rest of the `ai` map (read only, never written by `save()`); `ManagedPolicyCenter` publishes `AllowBackgroundAI`; `AppState.backgroundAI` is `BackgroundAIConsent.resolve(...)`, recomputed when either changes. The Desktop re-reads the config after its own `allow`/`pause` call.

## 4. Enforcement

### 4.1 The daemon cycle

One helper, `d.aiPhase(name, fn)`, wraps every phase marked "phase gate" in §2.1 (the slot phases gate per built-in in `RunSlot`, §4.2, which reads the state the same way). It reads `aiconsent.Current()` **before each phase**. That is cheap: a `stat` of `config.yaml` per read, a re-parse only when its mtime changed, and the policy's 30 s cache. A pause written mid-cycle therefore lets the running phase finish (D12) and skips the next AI phase. The parallel group (Track my threads and People cards) reads once, when the group starts. Paused → the phase returns before any nil check, lock, `pipeline_runs` row or `automation_runs` row (the FEAT-01 position), and the daemon logs one line per state change:

`background AI: paused (not answered yet) — sync keeps running; allow it in Watchtower or with "watchtower ai background allow"` (reason `owner`: "paused by you"; `organization`: "turned off by your organization").

The fetch section is untouched. The history backfill holds whole (D12): no fetch, no row change, no hold strike.

### 4.2 Automations

- **Which manifests grant AI:** `Manifest.UsesAI()` is true for `llm:light|strong`, `agent:run`, `session:start`, and a `builtin:<primitive>` whose primitive calls a model. Each built-in primitive declares it (`builtin.Primitive.UsesAI`, beside `Primitives` in the registry; today `tracks.extract`, `ideas.consolidate`, `brief.compose`, `plan.compose`, `reaction.compose` and the custom-track primitives are AI, `attention.waiting` and `approvals.list` are not). `TestBuiltin_EveryPrimitiveDeclaresAI` fails on a primitive with no declaration.
- **Scheduler:** at a due time of a runnable `schedule` automation whose confirmed manifest grants AI while paused, it advances `last_scheduled_for` with the same compare-and-set as a `skip` policy and inserts nothing. Allowing again therefore never produces a `catch_up` for the paused window (D11; AUTO-10 amended, §13).
- **Event bus:** `Begin` leaves AI recipes out of the cycle's subscribers while paused, so no snapshot is taken for them and no run is queued.
- **Slots:** `RunSlot` skips a built-in whose manifest grants AI while paused, before its row, gate or pipelines are read (the FEAT-01 position, as `TestRunner_OffWritesNothing` pins for a built-in that is off); the mechanical built-ins run. The Reactions built-in's `reaction.compose` runs are owner-started (D3) and pass.
- **Executor (the backstop for runs):** before claiming a queued run whose trigger is `schedule`, `catch_up`, `event` or `sync` and whose snapshot manifest grants AI, it reads the state; paused → the run ends `cancelled`, `error_kind = 'cancelled'`, error "Background AI is paused" (no migration). `manual`, `button`, `dry_run` and `reply` runs are claimed as before, and the executor marks their context `aiconsent.WithOwnerStarted(ctx)`.
- **A run already running** when the owner pauses finishes (D12). Its context was marked `aiconsent.WithAdmitted(ctx)` when it was claimed under consent, so its later `llm()`/`agent()` calls pass. The pause applies to the next run.

  Why not cancel at the next `llm()`: a run that already ran `shell()` or `mcp()` steps, or proposed registry writes, would end `cancelled` half-done. Its side effects stay, and AUTO-04 drops its state, so the next run repeats the work. Consent is given per unit: the owner allowed this run to start, and its budget (minutes and tokens, AUTO-08) bounds what it can still spend. The rule therefore reads "no background unit **starts** without consent" (BGAI-01), not "no call". It is a known trade-off: up to one run's budget (15 minutes for the built-ins) runs after the pause. The same holds for a cycle phase already running and a reviewer already launched.

### 4.3 The per-call backstop

Every model call has an **origin**, `owner` or `background` (D18):

1. **The context wins.** `aiconsent.WithOwnerStarted(ctx)` (executor `manual`/`button`/`dry_run`/`reply` runs, the reaction-command dispatcher, D3) → owner. `aiconsent.WithAdmitted(ctx)` (a background unit that started under consent: a cycle phase, a claimed run, a reviewer relaunch) → background, admitted.
2. **Else the process default.** The daemon (`sync --daemon`) → background. A process started with `WATCHTOWER_AI_ORIGIN=background` → background. A process under the automation run marker `WATCHTOWER_AUTOMATION_RUN_ID` (the `mcp --surface automation` server, `shell()` children, `agent()` children's own `watchtower` calls) → the origin of that run's trigger, read once at start. Everything else → owner.

`policyCheckedGenerator`, `policyCheckedProvider`, the `agentloop` runner and the `agent()` CLI runner call `aiconsent.Check(ctx)` before the policy check, **in every process**. A `background` call that is not admitted, while the effective state is not `allowed`, returns `aiconsent.ErrPaused`. `trackedPipelineRun` treats `ErrPaused` as a skip, not an error (no `error` row, no "Didn't work yet" line).

**Who sets the env.** Every spawn made by a background unit sets `WATCHTOWER_AI_ORIGIN=background`, and, when the unit was admitted, `WATCHTOWER_AI_ADMITTED=<unit id>`. That covers `LaunchSpecReview` when the daemon's sweep calls it, the `agent()` children and their MCP server config (codex's `env_vars` list gains both names, as it carries the run marker today), and `shell()`'s environment. The child reads them once at start. `TestBGAI01_EveryDaemonSpawnSetsOrigin` parses `internal/daemon`, `internal/automations` and the launchers they call, and fails on an `exec.Command`/`os.StartProcess` that neither sets the origin nor is listed as non-model (`ps`, `/bin/sh` for a non-AI manifest), in the LLMUSAGE-01 checker's style.

The backstop keeps a path added later honest. A new daemon AI path that forgets `d.aiPhase` is refused, not run. So is a future Desktop timer that runs the CLI with the background origin. The guard test (§12) runs a full cycle with every feature on and a counting generator.

### 4.4 Allow and pause from outside the daemon

`ai background allow|pause` writes the key; the daemon sees it on its next read (no restart). `allow` also sends the running daemon the existing sync signal (`SIGUSR1`), best effort, so the paused pipelines run within seconds instead of at the next poll. `pause` sends nothing: the next unit is refused when it would start.

## 5. The consent screen

One view, `BackgroundAIConsentView`, over one model, `BackgroundAIConsentModel` (WatchtowerCore: the copy for the configured agent and reserve, the "what runs" rows from `sync.poll_interval` and `sync.backfill_days`, the saving and error state, the CLI call). Two hosts: onboarding's last step and the sheet.

| Mockup | State |
|---|---|
| `ai-consent-step-claude` | onboarding step, Claude Code picked |
| `ai-consent-step-codex` | Codex picked: the ChatGPT plan line |
| `ai-consent-step-ollama` | another provider: no subscription line |
| `ai-consent-step-claudeReserve` | the automatic reserve is on: one more line naming Codex |
| `ai-consent-step-saving` | the answer is being written: buttons disabled, "Saving your choice…" |
| `ai-consent-step-error` | the write failed: the error line, both buttons usable again |
| `ai-consent-step-claude-narrow` | 600 pt window |
| `ai-consent-sheet-claude` | the upgrade sheet (no Back, no step indicator) |
| `ai-consent-sheet-error` | the sheet after a failed write |

Layout, top to bottom: the step indicator (step host only), the title, two sentences (what Watchtower uses, whose plan and limits), the reserve line when it applies, a card "What can run on its own" with five rows, then two caption lines (gestures always run; where to change it), then the buttons: **Back** (step host only, quiet), **Not now** (secondary), **Allow background AI** (primary, the one prominent action), and under them the Not now note or the error.

- **Allow** → `watchtower ai background allow --yes`; success → the step finishes onboarding (the daemon starts) or the sheet closes.
- **Not now** → `watchtower ai background pause`; success → the same.
- **Failure** (either) → the error line in `Tone.error`, "Couldn't save your choice: <error>. Nothing runs in the background until it is saved." The step stays; the sheet stays. Nothing ran meanwhile: an unanswered install is already paused.
- The sheet has no close button and ignores Esc (`interactiveDismissDisabled`): it is answered once.

### 5.1 Copy

The strings are `BackgroundAIConsentMockCopy` today and move to `BackgroundAIConsentCopy` (WatchtowerCore) with their tests.

- Title: "Let Watchtower run AI in the background?"
- Intro: "Watchtower uses **<agent>** on this Mac to write your digests, briefings, tracks and people cards, and to run your automations. Most of this starts on its own, on a schedule or after each sync, without you asking each time." — `<agent>` = Claude Code, Codex, or the provider's display name.
- Plan, Claude: "These runs use your own Claude subscription and count toward its usage limits, the same as when you use Claude Code yourself. Watchtower never pays for, sees or shares your sign-in."
- Plan, Codex: "These runs use your own ChatGPT plan and count toward its Codex usage limits, the same as when you use Codex yourself. Watchtower never pays for, sees or shares your sign-in."
- Plan, other: "These runs use <name>, the model server set in Settings → AI."
- Reserve (only while the automatic reserve is on): "When Claude's usage limit is reached, runs switch to Codex and use your ChatGPT plan." (and the mirror for Codex → Claude).
- "What can run on its own":
  1. "After each sync, about every <poll> min: channel digests, tracks, memory, next steps, image and link descriptions"
  2. "Every few hours: ideas, Jira and mail digests"
  3. "Once a day: the morning briefing, day plan and people cards. Once a week: agent coaching"
  4. "After you connect a source: its last <backfill_days> days of history, a little at each sync"
  5. "Your automations that use AI, at the times and on the events you set"
- "Chats, Catch-Up, Run now and anything else you start yourself always run, whatever you pick here."
- "You can change this any time in Settings → System → AI → Background AI."
- Buttons: "Allow background AI", "Not now", "Back". Saving: "Saving your choice…".
- When the answer is saved but onboarding's finish fails: "Try again" (runs the finish only; the answer is not written again).
- Instead of the sheet while config.yaml cannot be read (an alert): title "Watchtower can't read config.yaml", body "Your background AI choice can't be saved until the file is fixed."
- Settings' switch turned off and the pause failed (§6.1): "Couldn't pause background AI: <error>. It is still on."
- Under the buttons: "Not now: Slack, mail, calendar and Jira keep syncing. AI features and automations wait until you allow them."

The rows list what *can* run (every AI feature), not only what is on now: the owner turns features on later without a second consent, and the list stays one fixed shape (D13 keeps one switch).

### 5.2 Onboarding

`OnboardingV2Step` gains `aiConsent` (raw value `aiConsent`, indicator "Background AI") between `connect` and `complete`. `OnboardingRoute.skips(.aiConsent)` is true when `AppState.backgroundAI.prompt` is false (answered, or decided by policy). Connect's Continue (or Goals' Continue on a Development-only route) moves to it; its answer runs `leaveOnboardingStep(.aiConsent)`, which is the finish that used to follow Connect. An install parked on `connect` from an older build gets the step at the end; an install already `complete` gets the sheet instead (§7).

## 6. Where the answer shows afterwards

### 6.1 Settings → System → AI → Background AI

A `SettingsSection` "Background AI" in `ProviderSettings`, under the provider sections, one `SettingRow` "Run AI in the background" with a switch.

| Mockup | State | Switch | Caption |
|---|---|---|---|
| `ai-consent-settings-allowed` | allowed by the owner | on | "On. Digests, briefings, tracks, people cards, memory and your automations run on their own, using your Claude subscription." (no "using …" for a provider without a plan) |
| `ai-consent-settings-paused` | paused (owner or not answered) | off | "Paused. Slack, mail, calendar and Jira keep syncing; AI features and automations wait." |
| `ai-consent-settings-orgOff` | policy `false` | off, locked (`managedByOrganization`) | "Your organization turned background AI off. Chats and anything you start yourself still work." |
| `ai-consent-settings-orgAllowed` | policy `true`, not answered | on | "Allowed by your organization. Turn it off to pause it for yourself." |
| `ai-consent-settings-saving` | a call in flight | disabled, section spinner | unchanged |
| `ai-consent-settings-error` | the call failed | back to the stored value | the pause-failed line in `Tone.error` (§5.1) |

Footer: "Turning it on shows what runs and asks you to confirm. Turning it off pauses at once; a model call already running finishes." Switching **on** opens the consent sheet (D9) and the switch follows the stored value; switching **off** runs `pause` directly.

### 6.2 Readiness and empty states

New `Readiness` case `backgroundAIPaused(managed: Bool)` for the AI features only — `ReadinessFeature.usesBackgroundAI` is true for `digests`, `streamDigests`, `tracks`, `peopleCards`, `briefing`, `dayPlan`, `ideas`, `memory`, and false for `slackSync`, `inbox`, `knowledgeIndex`, `calendar`, `jira`, `linear`. Precedence (D15): after 3b `needsDigests`, before 4 `daemonStopped`. Content still wins (a tab with data shows it). `honoringOwner` keeps it (it is not a promise).

| Mockup | Line | Button |
|---|---|---|
| `ai-consent-empty-paused` | "Paused — background AI is off" | "Allow background AI…" (opens the sheet) |
| `ai-consent-empty-org` | "Off — your organization turned background AI off" | none |

### 6.3 Home

While background AI is paused or forbidden, Home shows **one card at the top of the feed column, outside `GettingReadyPolicy`'s hideable Getting ready zone**, drawn by `HomeContent` from `AppState.backgroundAI` (not a Getting ready card). **Hide** on the Getting ready zone therefore never removes it (D10). The Getting ready zone leaves out the cards of features in `backgroundAIPaused`, because the one card speaks for them, and the zone keeps its other cards and its Hide as today.

| Mockup | Title | Body | Action |
|---|---|---|---|
| `ai-consent-home-paused` | "Background AI is paused" | "Digests, briefings, tracks, people cards, memory and automations wait. Slack, mail, calendar and Jira keep syncing." | "Allow background AI…" |
| `ai-consent-home-org` | "Background AI is off" + Managed badge | "Your organization turned it off. Chats, Catch-Up and anything you start yourself still work." | none |

**Re-entry after Not now (D10).** The Home card stays for as long as background AI is paused by the owner or not answered (above). Settings → System → AI keeps the switch, every AI empty state keeps its line and button, the Automations tab keeps its notice, and the phone keeps its line (§6.5). Each of these opens the one consent screen. That is enough to come back without being nagged: no sheet, notification or alert appears again by itself.

### 6.4 Automations

While paused and at least one runnable automation's manifest grants AI, the Automations tab shows one notice card above the list; each such row's run chip reads "Waiting".

| Mockup | Notice |
|---|---|
| `ai-consent-automations-paused` | "Background AI is paused: scheduled and event automations that use AI wait. Run now still works." + "Allow background AI…" |
| `ai-consent-automations-org` | "Your organization turned background AI off: scheduled and event automations that use AI don't run. Run now still works." |

No tray or notification change: the sheet is the one prompt.

### 6.5 Phone

The phone's Home and feeds show what the Mac produced, so while paused they go stale and look broken. The hub heartbeat gains one optional, additive key, `background_ai`. It is defined in the wire type `wire.Heartbeat` (`internal/hub/wire/payloads.go`, pinned by `internal/hub/wire/contract_test.go`) and its Kit twin `HeartbeatPayload`, and written by `internal/hub/slices/heartbeat.go`. Its values are `allowed`, `paused` (owner or not answered) or `organization`. It is absent from an older hub, and the phone then shows nothing. The hub reads `aiconsent.Current()` when it writes the heartbeat (every 900 s and on publish), so the line follows within one heartbeat.

| Mockup | Line (phone Home, above the feed) |
|---|---|
| `ai-consent-phone-paused` | "Digests and briefings aren't updating: background AI is paused on your Mac. Allow it in Watchtower on the Mac." |
| `ai-consent-phone-org` | "Digests and briefings aren't updating: your organization turned background AI off." |

The phone cannot allow it: consent is given on the Mac's screen, where the full text is shown. Strings live in `BackgroundAIConsentCopy` (the Kit's copy for the phone side), and tests pin them and the heartbeat key's decoding (absent, unknown value → no line).

## 7. Upgrade path for existing installs

1. The upgrade ships the Go gate and the Desktop screens together (one app bundle, the CLI inside it).
2. The new daemon starts with the key absent and no policy → **paused** (D5). Every source keeps syncing; the AI phases and AI automations wait; the log says so once.
3. The Desktop, on its first launch with `onboarding_done = 1` and `backgroundAI.prompt == true`, brings the main window forward once (after the release-notes window `UpdateService` opens on a new version, so the two never stack) and presents the sheet (`BackgroundAIConsentPrompt.shouldPresent(onboardingDone:state:)`). The sheet appears on every launch until it is answered — answering is the only way to close it.
4. **Allow** → the key is written, the daemon is signalled, the next cycle runs the pipelines over what synced meanwhile (D11). **Not now** → `paused` is written; Home and the empty states offer it from then on.
5. A managed Mac with `AllowBackgroundAI` set never sees the sheet: `true` runs as before the upgrade, `false` stays paused with the managed lines.

What pauses before the answer, in full: §2.1. What keeps running: §2.2.

**Why pause and not keep running (D5).** OpenAI's text asks for consent *before* background use; running on until the sheet is answered would be implied consent. The in-app updater (`UpdateService`) installs and restarts the app, so the sheet appears right away and the gap is minutes for an owner at the Mac; an update installed while nobody watches waits for the next window open. The cost lands on an owner who upgrades and leaves: digests wait until they come back, and nothing is lost (D11). The alternative ("keep running until answered") is listed in the owner ask.

## 8. MDM: `AllowBackgroundAI`

- Boolean, forced values only (POLICY-01). `true` = the organization consents for every owner who has not answered (no prompt, runs allowed); the owner can still pause for themselves (a tighter choice, POLICY-03 keeps the owner's value). `false` = forbidden: paused whatever the owner chose, the Settings switch locked, the step and the sheet never shown, `ai background allow` refused with the policy text before writing. Wrong type → `false`.
- Go: `policy.KeyAllowBackgroundAI`, `Policy.AllowBackgroundAI *bool`, `Normalize` with the most restrictive value `false`; `policy show` lists it under `keys`. Swift: the `ManagedPolicy` twin, the shared fixture `policy_cases.json` gains its rows; `OrganizationPolicySection` lists it; `docs/examples/watchtower-policy.mobileconfig` and `docs/guide/reference/organization-policy.md` document it.
- `TestPolicy01_KeysNeverCollideWithAppDefaults` covers the new key.
- This is the first key that can *grant* rather than only restrict: `true` stands in for the owner's answer. POLICY-03's "Loosening … never turns anything on by itself" needs an amendment that says so (§13).

## 9. CLI and the headless daemon

- `watchtower ai background status [--json]` — the effective state; JSON keys pinned: `effective` (`allowed|paused`), `reason` (`unanswered|owner|organization`), `answer` (`allowed|paused|""`), `policy` (`true|false|null`). Reads config and policy only, no database.
- `watchtower ai background allow [--yes]` — on a terminal prints the §5.1 text for the configured agent and asks "Allow background AI? [y/N]"; `--yes` skips the question; no terminal and no `--yes` → refused ("run with --yes to confirm"). Refused under policy `false`. Writes `allowed`, signals the daemon (§4.4), prints the new state.
- `watchtower ai background pause` — writes `paused`, prints the new state. Never refused.
- `watchtower status` adds one line: "Background AI: allowed" / "Background AI: paused (not answered) — allow with `watchtower ai background allow`" / "… paused by you" / "… turned off by your organization".
- A daemon started without the Desktop behaves exactly as above: paused until the owner runs `allow`; its log says how.
- Origin, not process role, decides (§4.3). Typed commands, the MCP servers of the owner's own sessions and `ai session`/`ai query` default to owner. A command started by a background unit inherits `background` through the environment.

## 10. Writers and readers

| Data | Writer | Readers |
|---|---|---|
| `config.yaml` `ai.background_runs` | `watchtower ai background allow\|pause` (the config writer `config set` uses; `config set` refuses the key) — called by the consent screen and the Settings switch with `--yes` | `aiconsent.Current()` (daemon per cycle / per call / per scheduler tick / per claim), `ConfigService` (read only), `ai background status`, `watchtower status` |
| `AllowBackgroundAI` (forced pref) | the organization's MDM profile | `policy.Current()`, `ManagedPolicyCenter` |
| `automation_runs` cancelled rows | the executor (§4.2) | Automations tab, `automations runs` |
| `last_scheduled_for` | the scheduler (§4.2, existing CAS) | the scheduler |
| `watchtower.log` lines | the daemon | the owner |

Nothing new in the database; no migration.

## 11. Failure modes

| Failure | Behaviour |
|---|---|
| The CLI write fails (permissions, disk full, config parse error) | The screen shows the error and stays; the stored answer is unchanged; an unanswered install stays paused. |
| `config.yaml` unreadable or unparsable in the daemon | Read as absent → paused (fail closed), logged once per change; sync runs. |
| The Desktop's `ConfigService.save()` runs with a stale snapshot | It re-reads the file before writing and never writes `ai.background_runs`, so the answer survives (test pins it). |
| The owner pauses while a phase is mid-way | The phase was admitted when it started and finishes; the cycle's later AI phases skip. |
| The owner pauses while an automation run is mid-way (after `shell()`/`mcp()` steps) | The run finishes within its budget and commits normally (no half-done run). The next run of any background AI automation is not started. |
| A child of a background unit started without the origin env (a spawn the checker missed) | It defaults to owner and is not gated. `TestBGAI01_EveryDaemonSpawnSetsOrigin` exists to make this a test failure. |
| An old hub (no `background_ai` key) | The phone shows no line, as today. |
| A run was queued just before the pause | The executor's claim check cancels it. |
| The daemon is older than the Desktop (mixed versions during an upgrade) | The old daemon ignores the key and keeps running AI until it is restarted; the Desktop restarts the daemon after an upgrade as today. The sheet is honest about the new daemon only. |
| The policy changes while the daemon runs | `policy.Current()`'s 30 s cache applies; a call within that window may still run. |
| `allow` cannot signal the daemon (not running, PID file stale) | The write stands; the next cycle runs the pipelines. |
| Two writers at once (Settings and CLI) | The last write wins; both write the same config writer under its file lock. |
| A recipe's manifest is widened to add `llm:` while paused | Confirming a new hash already restarts the schedule from now (AUTO-10); it is then held like any AI recipe. |
| The owner never answers the sheet (quits) | Stays paused; the sheet comes back at the next launch. |
| Onboarding is re-run | The step is skipped (already answered). |

## 12. Tests

**Go**

- `internal/aiconsent`: `TestBGAI03_SharedFixture` (the table of §3.2), `TestCurrent_UnreadableConfigIsPaused`, `TestCurrent_RereadsOnlyOnMtimeChange`, `TestCheck_NoopOutsideTheDaemon`, `TestCheck_OwnerStartedPasses`.
- `internal/daemon` (cycle): `TestBGAI01_PauseMidCycleFinishesPhaseSkipsNext` (a fake phase writes `paused` mid-way: that phase's calls all run, the next AI phase writes no `pipeline_runs` row and makes no call, the sync phases of the next cycle still run), `TestBGAI01_PausedCycleMakesNoModelCall` — every feature on, Slack/mail/Jira fakes with data, a counting generator, consent paused: zero model calls, no AI `pipeline_runs` or `automation_runs` rows, every sync phase ran, the backfill row untouched; then allowed: the same cycle calls the model. `TestBGAI01_PauseMidCycleSkipsWithoutErrorRow`. `TestDaemon_ReactionCommandsRunWhilePaused` (D3).
- `internal/automations/builtin`: `TestBuiltin_EveryPrimitiveDeclaresAI`, `TestRunner_PausedSkipsAIBuiltinWritesNothing`, `TestRunner_MechanicalBuiltinRunsWhilePaused` (Waiting for me, Needs approval).
- `internal/automations`: `TestScheduler_PausedAdvancesWithoutRun`, `TestScheduler_AllowAfterPauseDoesNotCatchUp`, `TestScheduler_NonAIRecipeRunsWhilePaused` (D4), `TestBus_PausedSkipsAIRecipes`, `TestExecutor_PausedCancelsBackgroundAIRun`, `TestBGAI02_ManualRunWhilePaused` (and `button`, `dry_run`, `reply`).
- `internal/aiconsent`: `TestOrigin_ContextBeatsProcess`, `TestOrigin_EnvMarksBackground`, `TestOrigin_AutomationMarkerTakesRunTrigger` (a `manual` run's marker → owner, a `schedule` run's → background), `TestCheck_AdmittedBackgroundPasses`.
- `internal/daemon`: `TestBGAI01_EveryDaemonSpawnSetsOrigin` (static checker, with its own testdata like `TestLLMUsageLeavesCatchesNewLeaf`), `TestSpecReviewSweep_HoldsWhilePaused` (the row stays queued, `attempt` unchanged), `TestBGAI01_RunStartedBeforePauseFinishes`.
- `cmd`: `TestPolicyCheckedGenerator_RefusesBackgroundOriginInAnyProcess` (a non-daemon process with `WATCHTOWER_AI_ORIGIN=background`), `TestLaunchSpecReview_SweepSetsOrigin`, `TestAIBackground_AllowNeedsYesWithoutTTY`, `TestAIBackground_AllowRefusedByPolicy` (writes nothing), `TestAIBackground_StatusJSONKeys`, `TestConfigSet_RefusesBackgroundRunsKey`, `TestBGAI02_TypedCommandNotGated` (`digest generate` in a CLI process with consent paused calls the model).
- `internal/policy`: the new rows in `policy_cases.json`; `TestPolicy01_WrongTypesFailClosed` gains `AllowBackgroundAI`.

**Swift** (`Tests/Core` unless noted)

- `BackgroundAIConsentTests.sharedFixture` (the Go fixture), `BackgroundAIConsentCopyTests` (the strings above, agent and reserve variants, poll and backfill numbers), `BackgroundAIConsentModelTests` (allow/pause call the CLI with the right args, error and saving states, the sheet's close only after success).
- `FeatureReadinessTests`: `testBackgroundAIPausedOnlyForAIFeatures`, `testContentWinsOverPaused`, `testPausedBeforeDaemonStopped`, `testManagedPausedHasNoButton`.
- `GettingReadyPolicyTests.testPausedLeavesAIFeatureCardsOut`; `HomeContentTests.testPausedCardSurvivesHidingGettingReady`.
- `OnboardingStateMachineV2Tests`: `testConsentStepSkippedWhenDecided`, `testParkedOnConnectResumesThroughConsent`, `testUnknownRawValueStillStartsAtGoals`.
- `BackgroundAIConsentPromptTests.testShownOnceUntilAnsweredAfterOnboarding`.
- `ConfigServiceTests.testSaveKeepsBackgroundRunsKey`.
- Kit: `HeartbeatPayloadTests.testBackgroundAIKeyIsOptional` (absent and unknown → nil), `BackgroundAIConsentCopyTests` for the phone lines; Go `internal/hub/wire/contract_test.go` gains the key (optional, omitted when empty), and `internal/hub/slices`: `TestHeartbeat_CarriesBackgroundAI`.
- Mockups: `DesignShotsTests.testBackgroundAIConsentShotsRender`; the implementation adds live-view shots of the real step, sheet and Settings section beside the mockups (the `onboarding-step-live-*` pattern).

## 13. Contracts touched (for owner approval)

| Contract | Change | Kind |
|---|---|---|
| **New `docs/inventory/background-ai.md`** | **BGAI-01** — no background unit (§2.1, any process) starts without the effective `allowed`; a unit started under consent may finish (D12); guards `TestBGAI01_*`, `TestExecutor_PausedCancelsBackgroundAIRun`, the backstop and origin tests. **BGAI-02** — an owner gesture is never gated; guards `TestBGAI02_*`, `TestDaemon_ReactionCommandsRunWhilePaused`. **BGAI-03** — Go and Swift resolve the same state; guard the shared fixture. | new |
| POLICY-01 | `AllowBackgroundAI` added; most restrictive value `false`. | amendment (strengthening) |
| POLICY-02 | the shared fixture gains the key's rows. | amendment (strengthening) |
| POLICY-03 | "Loosening never turns anything on by itself" gets one exception: `AllowBackgroundAI = true` stands in for an owner who has not answered; it never overrides the owner's own `paused`, and removing the profile brings the prompt back. | amendment that loosens the text — approved in ask #1452 |
| AUTO-10 | "No catch-up ever covers a window in which the automation could not run" names the paused window: the scheduler advances `last_scheduled_for` with no run. | amendment (same rule, one more case) |
| FEAT-01 | The paused gate sits at the same early position: no `pipeline_runs` rows, no locks. Listed as a sibling gate, not a feature flag. | note |
| BACKFILL-01..02 | Unchanged; the runner holds whole while paused (no state change), as it does for a policy-forbidden source. | note |
| STRIP-01 / REACT-01..05 | Unchanged; reaction commands keep running (D3). | none |
| LLMUSAGE-01 | Unchanged; the new origin checker reuses its parsing style and does not edit its lists. | none |
| Spec review (no inventory id) | The sweep's relaunch waits while paused (D20). | note in `docs/features/spec-review.md` |
| Phone heartbeat (protocol §9 notes) | One optional additive key. | note in `docs/features/go-hub.md` / `mobile-companion.md` |

## 14. Owner decisions

All answered in ask #1452: D5 pause until the owner answers; BGAI-01..03, the POLICY-01/02 key, the AUTO-10 amendment and the POLICY-03 exception for `AllowBackgroundAI = true` approved; D12 a started run finishes; the other decisions (D2–D4, D6, D8–D11, D13–D20) accepted as proposed. Nothing is open.

## 15. Docs to update with the implementation

- New feature note `docs/features/background-ai-consent.md`; its line in `CLAUDE.md` and its summary in `docs/features/README.md`.
- `docs/features/onboarding-v2.md`, `docs/onboarding-flow.md` (the third step), `docs/features/first-run.md` (the readiness state, Home's card), `docs/features/automations.md` (scheduler, bus, executor), `docs/features/mdm-policy.md` (the key), `docs/features/built-in-automations.md` (slots held).
- User guide (`docs/guide/WRITING.md` rules; `go test ./docs/guide`): `start/setup.md` (the step), `reference/settings.md` (Background AI), `reference/organization-policy.md` (the key), `reference/cli.md` (`ai background`), `concepts/features-on-and-off.md` (paused vs off).
- `docs/examples/watchtower-policy.mobileconfig`.

## 16. Out of scope

- Reading Claude Code's OAuth token for the plan-limits gauge (flagged separately by the same research; its own target).
- Accepting Anthropic's Commercial Terms or moving to Sign in with ChatGPT (vendor-side steps, not product behaviour).
- Per-feature or per-automation consent (one switch, D13).
- Rate or volume caps beyond the existing budgets.
- The private always-on hub: it follows its own repository.
