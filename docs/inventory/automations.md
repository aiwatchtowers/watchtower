# Behavior Inventory — Automations

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.

Owner-written recipes (a Markdown file with a permission manifest and one
synchronous JavaScript block) that the daemon runs on a schedule or on demand,
in a goja sandbox whose only world is the automation SDK. Feature note:
`docs/features/automations.md`. Design:
`docs/superpowers/specs/2026-10-14-automations-design.md` (§14.1 is the source
of these entries; decisions §20, §20.1).

**Module:** `internal/automations/`, `internal/db/automations.go`,
`internal/db/automation_runs.go`, `internal/db/automation_stats.go`,
`internal/db/automation_reads.go`, `internal/db/migrations/00113_automations.sql`,
`cmd/automations*.go`, `cmd/automations_registry.go`,
`internal/daemon/automation_wake.go`, `internal/tools/emails.go`,
`internal/tools/automation_reads.go`
**Last full audit:** 2026-10-15 (Automations P1)

Phases: P1 (core) is in code. P2 (writes), P3 (authoring + Desktop), P4
(events), P5 (workbench) and P6 (mcp, agent, templates) each flip their
**Planned** part in the same commit as its code; exactly one plan flips each
part. Guard tests are named `TestAutoNN_…` (Go) and `testAutoNN_…` (Swift);
the other guards listed are pinned by name too.

## AUTO-01 — The manifest is the only source of permissions

**Status:** Enforced

**Observable:** Every SDK call is checked against the recipe's `permissions`
and `outputs` before its backend runs (`(*Manifest).AllowTool`, `AllowLLM`,
`AllowOutput`, `AllowCapability`, `AllowMCP`, `AllowShell`). A miss throws a
JS `PermissionDenied` (`{name, message, needed}`) into the script, writes one
step row with `status='denied'` and the permission it lacked, and touches no
backend (the registry, the generator and the commit buffer see nothing). No
trust row, grant, surface or argument widens it: a registry tool must also be
visible on the `automation` surface whatever the manifest says; a call whose
scope argument is absent is admitted only by `@*` or `tool:<name>`;
`list_messages`/`list_upcoming_events` are always unscoped (only
`slack:read@*`/`calendar:read@*` or `tool:<name>`, ask #273); the broad
knowledge tools, `list_inbox`, the memory tools and `get_writing_style` have
no capability and are admitted only by `tool:<name>` (asks #273, #277); a scope
argument spelled in another case (`PROJECT`, `Key`, `Account`) is not read as
the scope, so the call needs `@*`. A Jira project grant covers what the tool
returns with that project's issues, linked issues of other projects included
(owner ruling, ask #287). An uncaught `PermissionDenied` ends the run
`failed`/`permission`.

**Why locked:** The owner confirms one manifest; everything the script can do
must follow from that text alone. A second source of permission (a trust
switch, a default, a lenient scope match) would let a recipe do what the
owner never read.

**Test guards:**
- `internal/automations/sdk_test.go` — `TestAuto01_DeniedCallThrowsAndWritesDeniedStep` (the fake registry records zero calls), `TestLLM_StrongNeedsStrongPermission`, `TestOutput_GateAndBodyLimit`
- `internal/automations/sandbox_test.go` — `TestSandbox_DeniedCallWritesDeniedStep`
- `internal/automations/manifest_test.go` — `TestManifest_ScopeMatching`, `TestManifest_JiraScopeFromRealArgs`, `TestManifest_EmailScopeMatchesLabelOrAddress`, `TestManifest_UnscopedSourceReadsNeedStar`, `TestManifest_D23ToolScopes`, `TestManifest_KnowledgeToolsOnlyByToolEntry`, `TestManifest_ToolNotOnAutomationSurfaceDenied`, `TestManifest_ScopeOfErrorIsADeniedNotAPanic`, `TestManifest_LLMStrongImpliesLight`, `TestManifest_OutputGate`
- `internal/automations/manifest_scope_test.go` — `TestManifest_JiraProjectGrantCoversLinkedData`, `TestManifest_CaseVariantScopeArgRefused`, `TestManifest_NilDBDeniedNotPanic`
- `cmd/automations_registry_test.go` — `TestToolCapabilities_CoversEveryAutomationTool` (every tool visible on `automation` has a capability entry or is deliberately `tool:`-only)
- `internal/automations/executor_test.go` — `TestExecutor_UncaughtPermissionDeniedFailsWithPermissionKind` (the run-level mapping)

**Locked since:** 2026-10-14

## AUTO-02 — Writes only through the registry

**Status:** Enforced (P1: the read side — no SDK path writes outside the
automation's own tables) · Planned (P2: the write side, `tool` writes through
`Registry.Propose`)

**Observable:** The only SDK paths that change data outside the automation's
own tables are `Registry.Propose` (and the `Apply` it triggers) on the
`automation` surface, `shell()` and `session()`; `output.inbox`/`report`
(and P2's `briefing`) write only `automation_outputs`, and `state.set` only
`automation_state`, both through the run's commit (AUTO-04). In P1, `tool()`
reaches only `Registry.CallRead`: a write tool throws `NotAvailable` ("writes
arrive in a later phase") and never reaches `Propose`. The automation read
tools write nothing either: `memory_open` skips its access-stat bump on the
`automation` surface and `buildAutomationRegistry` mounts `memory_recall`
without the shadow handle, so it writes no shadow row.

**Why locked:** Every write an automation makes must be one reviewable
`agent_actions` row (AGENT-01) or a declared automation output; a module that
wrote a table directly would bypass the Inbox, trust and the owner's Approve.

**Test guards:**
- `internal/automations/sdk_test.go` — `TestTool_WriteNotAvailableInP1`
- `internal/tools/automation_reads_test.go` — `TestMemoryOpen_NoAccessBumpOnAutomationSurface`, `TestD23Tools_AutomationSurfaceOnly`
- `cmd/automations_registry_test.go` — `TestBuildAutomationRegistry_AddsMemoryTools` (recall on this registry writes no shadow row)
- P2 adds the write-side guard (plan `2026-10-14-automations-p2.md`) and flips this entry.

**Locked since:** 2026-10-14

## AUTO-03 — Auto only by the owner, bound to the hash

**Status:** Planned (P2)

**Observable:** An auto grant is written only by `automations auto … on`
outside AI-agent markers with the current `approval_hash`; it applies only
while that hash equals the run's; any script/permission change makes it
inactive until re-granted; every auto write is one `agent_actions` row through
`Apply`'s claim plus an `auto=1` step. AlwaysAsk tools are never auto. (The
AGENT-03 amendment of spec §14.2, owner-approved in ask #265, lands with it.)

**Why locked:** Auto is the one place an External write runs without a
per-call click; it is safe only while it is bound to exactly the code and
permissions the owner reviewed.

**Test guards:** none yet — P2 adds them (plan `2026-10-14-automations-p2.md`)
and flips this entry. P1 already refuses trust on the `automation` surface
(`internal/tools/registry_test.go` `TestSetTrust_RefusesReadToolsAndTheAutomationSurface`,
see `agent-actions.md`).

**Locked since:** 2026-10-14

## AUTO-04 — State commits only on success

**Status:** Enforced

**Observable:** `state.set` and `output.*` (local) are buffered in the run's
`CommitBuffer` and committed in one transaction with `status='succeeded'`
(`db.FinishAutomationRun(runID, RunFinish, *RunCommit)`; a commit with any
other status is refused with `ErrCommitOnFailure`, a commit on a run that is
no longer active with `ErrRunNotActive`). Any other terminal status —
`failed`, `timed_out`, `budget_exceeded`, `cancelled`, `expired`, an
interrupted run — leaves `automation_state` and `automation_outputs`
byte-identical. Reads see the committed state plus the run's own sets. A dry
run never commits.

**Why locked:** A run that dies halfway must be safe to rerun; a half-written
cursor in `state` would silently skip or repeat work.

**Test guards:**
- `internal/db/automation_runs_test.go` — `TestAuto04_FinishCommitOnlyOnSuccess`, `TestFinish_RefusesTerminalRun`, `TestFinish_RefusesForeignOutput`
- `internal/automations/executor_test.go` — `TestAuto04_FailedRunLeavesStateAndOutputsUnchanged` (failed, timed out, over budget, cancelled), `TestAuto04_SucceededCommitsStateAndOutputsAtomically`
- `internal/automations/sdk_test.go` — `TestState_ReadsCommittedPlusOwnSets`, `TestState_RejectsUnserialisableValues`

**Locked since:** 2026-10-14

## AUTO-05 — Bounded concurrency per automation

**Status:** Enforced

**Observable:** At most `concurrency` (default 1, 1–4) runs of one automation
are `running`/`waiting` at once; the claim is one conditional update in one
`BEGIN IMMEDIATE` transaction, so of racing claimers (the daemon and a CLI dry
run, two daemons during a restart) exactly one wins. Across all automations at
most `MaxConcurrentRuns` (2) are `running` (waiting runs do not count): the
daemon's claim checks it in the same statement (`ClaimAutomationRunWithin`),
and a waiting run resumes only into a free running slot
(`ResumeAutomationRunIfSlot`), ahead of queued runs.

**Why locked:** An automation written for one run at a time (a cursor in
`state`, a post per day) must never see two of itself; the global bound keeps
a burst of schedules from loading the machine.

**Test guards:**
- `internal/db/automation_runs_test.go` — `TestAuto05_OneActiveRunPerAutomation`, `TestAuto05_ConcurrencyN`, `TestAuto05_ConcurrentClaimsOneWinner` (8 goroutines on a file DB), `TestClaimWithin_HonoursTheGlobalRunningBound`, `TestResumeIfSlot_WaitsForAFreeRunningSlot`
- `internal/automations/executor_test.go` — `TestAuto05_OneActiveRunPerAutomation`, `TestExecutor_MaxConcurrentRuns`, `TestExecutor_ReadyWaitsGetFreedSlotsBeforeQueuedRuns`, `TestWaiter_ResumeWaitsForAFreeSlot`

**Locked since:** 2026-10-14

## AUTO-06 — Only confirmed content runs

**Status:** Enforced (P1: the executor, the indexer and the CLI, including
the CLI dry-run refusal of ask #271) · Planned (P3: the `draft_automation`
half)

**Observable:** A run is claimed only when `confirmed_hash = approval_hash`
(and the row is parsed, enabled and not removed — `Automation.Runnable()`); a
queued run of a non-runnable automation ends `cancelled`/`not_runnable`. The
executor runs the indexed copy (`recipe_text`, snapshotted on the run as
`recipe_snapshot` at claim), never the file; an edit on disk during a run
does not touch that run, and the next rescan makes the automation
non-runnable when `approval_hash` changed. A recipe new to the index, or
changed outside an owner save, is indexed unconfirmed (an insert never sets
`confirmed_hash`/`enabled`; an upsert never touches them). `confirmed_hash`
is set only by `db.ConfirmAutomation(id, hash, now)`, which refuses any hash
but the current `approval_hash` (`ErrHashMismatch`); the CLI paths to it —
`automations confirm` and `automations save --confirm-hash` — refuse under
AI-agent markers (AGENT-07). Dry runs are exempt (they write nothing,
AUTO-12), but only the owner dry-runs an unconfirmed recipe (ask #271):
`automations dry-run` of an unconfirmed recipe refuses under every marker
(`WATCHTOWER_AUTOMATION_RUN_ID` included) and writes no run row; the CLI pins
the `approval_hash` its gate checked (`ExecuteInlinePinned`), so a recipe
changed between the check and the claim is cancelled, never run. P3 adds the
same refusal to `draft_automation` (a draft whose `approval_hash` is an
indexed unconfirmed recipe's, owner-confirmed reading in ask #280).
Switching a recipe on and deleting an automation are owner gestures too
(ask #293): `automations enable` and `automations delete` refuse under every
marker before anything is read or written (AGENT-07); `disable` stays open.

**Why locked:** "What was confirmed is exactly what runs" is the whole
security model: a git pull, a hand edit or an agent's edit must never run
code or permissions the owner did not see.

**Test guards:**
- `internal/automations/executor_test.go` — `TestAuto06_UnconfirmedRecipeIsCancelledNotRun`, `TestAuto06_DryRunOfUnconfirmedRecipeRuns`, `TestAuto06_ExecutorRunsIndexedCopyNotFile`, `TestAuto06_EditDuringRunDoesNotAffectRunningSnapshot`, `TestExecutor_ExecuteInlinePinnedRefusesChangedRecipe`
- `internal/automations/indexer_test.go` — `TestRescan_IndexesNewRecipeUnconfirmedAndDisabled`, `TestRescan_ChangedOutsideWatchtowerNeedsConfirmation`
- `internal/db/automations_test.go` — `TestAutomationIndex_RunnableTable`, `TestAutomationIndex_ConfirmRefusesStaleHash`, `TestAutomationIndex_UpsertKeepsOwnerColumns`, `TestAutomationIndex_InsertNeverSetsOwnerColumns`, `TestAutomationIndex_UpsertChangedApprovalHashNeedsConfirmation`
- `cmd/automations_test.go` — `TestAutomationsCLI_ConfirmRefusedUnderAgentMarkers`, `TestAutomationsCLI_SaveIsAtomicAndIndexes` (`--confirm-hash` under a marker refused, file not written), `TestAutomationsCLI_DryRunUnconfirmedRefusedUnderAgentMarkers`, `TestAutomationsCLI_DryRunRecipeChangedBeforeClaimRefused`, `TestAutomationsCLI_EnableDeleteRefusedUnderAgentMarkers`
- P3 adds the `draft_automation` guard (plan `2026-10-14-automations-p3.md`) and flips that half.

**Locked since:** 2026-10-14

## AUTO-07 — The script sees the world only through the SDK

**Status:** Enforced

**Observable:** One fresh goja runtime per run. No `require`, `console`,
filesystem, network, timers or promises: `async`/`await`/`Promise`/
`setTimeout`/`setInterval` are refused before the run ("the script API is
synchronous"); `eval`, `Function` and every function prototype's
`.constructor` are unavailable (no code from strings); a script that breaks
out of its wrapper function is a parse error. SDK results reach the script as
plain JSON values (never a Go object), and no SDK result carries a token, a
secret file's content, an OAuth grant or a config value.

**Why locked:** The manifest (AUTO-01) bounds only what the SDK can do; a
runtime that also offered I/O, timers or a code-from-string escape would put
the script outside it.

**Test guards:**
- `internal/automations/sandbox_test.go` — `TestAuto07_NoRequireFsNetTimers`, `TestRecipe_AsyncScriptRefused`, `TestSandbox_PreParseRefusesAsync`
- `internal/automations/sandbox_hardening_test.go` — `TestAuto07_NoCodeFromStrings`, `TestSandbox_WrapperBreakoutRefused`, `TestSandbox_SDKResultsArePlainJSValues`

**Locked since:** 2026-10-14

## AUTO-08 — Every run is bounded and ends

**Status:** Enforced

**Observable:** Active time ≤ `budget.minutes` (time spent waiting is
excluded), tokens ≤ `budget.tokens` (input + output per model call; a call
without provider usage debits `ceil(len/4)` and marks the run estimated), and
waits ≤ `pause_timeout_hours` (→ `expired`). There is no token cap across runs
(ask #294): what other runs spent never stops a run. The deadline, budget and
cancel interrupts cannot be caught by the script's `catch`. A script stuck in
a native builtin past `AbandonGrace` (2 s) after an interrupt is abandoned:
its run ends, and its automation is disabled ("runaway script — check and
re-enable"). Every run reaches exactly one terminal status, including after a
daemon restart: on start the executor ends every `running`/`waiting` run
`failed`/`interrupted` — except a live CLI dry run, which is swept only past
its deadline plus one minute; a stop mid-run ends it `failed`/`interrupted`.
Ending a run closes its still-open steps in the same transaction.

**Why locked:** An automation runs unattended; a run that never ends holds a
concurrency slot forever, and one that never stops spending burns the owner's
model quota.

**Test guards:**
- `internal/automations/sandbox_test.go` — `TestAuto08_InterruptOnTimeout`, `TestSandbox_InterruptIsNotCatchable`
- `internal/automations/sandbox_hardening_test.go` — `TestSandbox_CatastrophicRegexEndsWithinDeadline`, `TestSandbox_StuckNativeIsAbandonedAfterGrace`
- `internal/automations/executor_test.go` — `TestAuto08_InterruptOnBudget`, `TestAuto08_CatchAllLoopStillEndsOnBudget`, `TestAuto08_NoDailyCapAcrossRuns`, `TestAuto08_RestartMarksInterrupted`, `TestBudget_EstimatesTokensWhenUsageMissing`, `TestWaiter_PauseTimeoutExpires`, `TestExecutor_DaemonStopMidRunEndsInterrupted`, `TestExecutor_AbandonedRunDisablesAutomation`, `TestExecutor_SweepsStaleDryRuns`, `TestExecutor_StartSparesLiveCLIDryRun`
- `internal/automations/dryrun_memory_test.go` — `TestDryRunInMemory_BudgetBound`
- `internal/db/automation_runs_test.go` — `TestAuto08_RestartMarksInterrupted`, `TestAuto08_RestartSparesLiveDryRun`, `TestRunEnd_ClosesOpenSteps`

**Locked since:** 2026-10-14

## AUTO-09 — Triggers only queue

**Status:** Enforced (P1: scheduler and CLI `run`) · Planned (P4: the event
bus). The Desktop buttons (P3's Run now, P5's header buttons) add guards
without a status change.

**Observable:** The scheduler, the event bus, CLI `run` and the Desktop
buttons only insert `queued` rows (`db.EnqueueAutomationRun`, the only way to
create a run; a second trigger of the same kind while one is queued is
coalesced onto it); only the daemon's executor runs them. The one exception
is `automations dry-run`, which executes its own `trigger='dry_run'` row in
the CLI process and writes nothing outside its journal; the daemon never
picks up a dry-run row. The automation wake is `SIGUSR2`; it never starts a
sync cycle.

**Why locked:** One executor in one process is what makes concurrency
(AUTO-05), budgets (AUTO-08) and restarts (AUTO-08) hold; a trigger that ran
a script inline would escape all three.

**Test guards:**
- `internal/automations/scheduler_test.go` — `TestAuto09_SchedulerOnlyQueues`
- `cmd/automations_test.go` — `TestAuto09_RunCommandOnlyQueues`
- `internal/db/automation_runs_test.go` — `TestRun_CoalescesSecondTrigger`, `TestNextQueued_SkipsDryRun`
- `internal/daemon/automation_wake_test.go` — `TestDaemon_AutomationWakeSignalDoesNotStartSync`
- P4 adds the bus guard (plan `2026-10-14-automations-p4.md`) and flips that half.

**Locked since:** 2026-10-14

## AUTO-10 — Missed schedules

**Status:** Enforced

**Observable:** After a gap covering N ≥ 1 missed due times: `missed:
run_once` inserts exactly one `catch_up` run (for the latest missed time),
`missed: skip` none; when the latest due time is on time (within the 2-minute
grace) only that `schedule` run is inserted. `last_scheduled_for` advances in
the same transaction as the insert, as a compare-and-set on the value the
scheduler read, so a crash, a restart or a concurrent writer never repeats
it. No catch-up ever covers a window in which the automation could not run: a
first index, an enable, a confirm that changes the confirmed hash, a rescan
that makes the row runnable again and enabling the `automations` feature all
restart the schedule from now. A clock stepped back waits for the clock to
pass `last_scheduled_for` (no duplicate); one more than a day behind it
restarts from now.

**Why locked:** A Mac that slept over two morning reports must produce one
report, not two and not zero; a restart must not produce a third.

**Test guards:**
- `internal/automations/scheduler_test.go` — `TestAuto10_SleepAcrossTwoDueTimesRunsOnceCatchUp`, `TestAuto10_SkipPolicyRunsNone`, `TestAuto10_RestartDoesNotRepeatCatchUp`, `TestScheduler_OnTimeWithinGrace`, `TestScheduler_NewAndReenabledDoNotCatchUp`, `TestScheduler_ClockBackwardsNoDuplicate`, `TestScheduler_DSTTransition`, `TestScheduler_DSTSleepOverGapCatchesUpOnce`, `TestScheduler_ConcurrentConfirmSkipsRow`
- `internal/db/automation_runs_test.go` — `TestEnqueue_AdvancesScheduleAtomically`, `TestEnqueue_ScheduleCompareAndSet`
- `internal/db/automations_test.go` — `TestAutomationIndex_EnableSetsLastScheduledForNow`, `TestAutomationIndex_ConfirmSetsLastScheduledForNow`
- `internal/automations/indexer_test.go` — `TestRescan_FirstIndexSetsLastScheduledForNow`, `TestRescan_RunnableAgainRestartsScheduleNow`
- `internal/features/fastforward_test.go` — `TestFastForward_Automations` (FEAT-03)

**Locked since:** 2026-10-14

## AUTO-11 — Complete journal

**Status:** Enforced

**Observable:** Every SDK call, denied ones included, has exactly one step row
(`automation_run_steps`, dense `seq` per run) with its status, tokens and
duration; `args_json` and `result_summary` are clipped to 4 KiB. A step whose
result cannot be encoded is re-closed as an error, never left `ok`. `log` is
capped at 200 ok steps plus one cap-error step per run, even when getters log
while their arguments are converted.

**Why locked:** The journal is the owner's only view of what an unattended
script did; a call missing from it is an action nobody can audit.

**Test guards:**
- `internal/automations/sdk_test.go` — `TestAuto11_EveryCallHasOneStep`, `TestLog_Capped`, `TestLog_CapHoldsAgainstNestedGetterLogs`
- `internal/automations/sandbox_hardening_test.go` — `TestEnvCall_EncodingFailureReclosesStepAsError`
- `internal/db/automation_runs_test.go` — `TestSteps_SeqIsDenseAndOrdered`

**Locked since:** 2026-10-14

## AUTO-12 — Dry run writes nothing outside its journal

**Status:** Enforced (P1: no `agent_actions` row, no output, no state
change) · Planned (P5: no session, no `shell()`)

**Observable:** A dry run makes no `agent_actions` row, no output, no state
change, starts no session and runs no `shell()`: `output.*` and `state.set`
steps record `status='dry_run'` and nothing is committed; `llm` and read
tools run for real and their tokens count on the run. The in-memory dry run (`DryRunInMemory`, P3's `draft_automation`)
writes no row of any table, not even a run row.

**Why locked:** Dry run is how the owner (and, for a confirmed recipe, the
assistant) checks a recipe before trusting it; a dry run with side effects
would make checking as dangerous as running.

**Test guards:**
- `internal/automations/executor_test.go` — `TestAuto12_DryRunWritesNoActionsOutputsOrState`
- `internal/automations/dryrun_memory_test.go` — `TestDryRunInMemory_WritesNoRows`
- `internal/automations/sdk_test.go` — `TestOutput_DryRunWritesAreDryRunSteps`
- P5 adds the session/shell guard (plan `2026-10-14-automations-p5.md`) and flips that half.

**Locked since:** 2026-10-14

## AUTO-13 — Exact shell commands, workbench only

**Status:** Planned (P5)

**Observable:** `shell()` runs only a command byte-equal to a `shell:` entry,
only in a workbench automation, in the workbench folder, with the spec §13.2
environment. (P1 already refuses `shell:`/`session:`/`ask:` entries in a
personal recipe at parse time and matches `shell:` entries byte-exactly in
`AllowShell` — `internal/automations/manifest_test.go`
`TestManifest_PersonalRefusesShellSessionAsk`, `TestManifest_ShellExactOnly`.)

**Why locked:** A shell command is the widest power an automation can hold;
anything but exact, owner-read commands in the owner's own repository would
turn a recipe into arbitrary code execution.

**Test guards:** none yet — P5 adds them (plan
`2026-10-14-automations-p5.md`) and flips this entry.

**Locked since:** 2026-10-14

## Changelog

- 2026-10-15 (**owner decision, ask #294**; spec §20.3 D25): **AUTO-08 amended — the daily-cap clause is removed** (owner-approved in ask #294). `automations.daily_budget_tokens`, `ExecutorOptions.DailyBudgetTokens`, the meter's live daily total and `InterruptDailyCap` are gone; `error_kind='daily_cap'` stays in the CHECK but is no longer produced. Guards retired with that approval: `TestAuto08_DailyCap`, `TestAuto08_DailyCapSeesConcurrentSpend`, `TestAuto08_DailyCapDayFollowsTheExecutorZone`, `TestAuto08_DailyCapWindowIsTheRunStartDay`, `TestExecutor_DailyCapZeroSpendsNothing`, `TestSandbox_DailyCapInterruptsUncatchably` (plus the meter unit tests `TestMeter_DailyRemainderInterrupts`, `TestMeter_LiveDailyTotalAcrossRuns`, `TestMeter_DailyTotalReadErrorRefusesCall`). Added `TestAuto08_NoDailyCapAcrossRuns`. The per-run token budget, time budget, pause timeout and terminal-status guards are unchanged.
- 2026-10-15 (**owner decision, ask #293**; spec §20.3 D24): strengthening, no guard relaxed. AUTO-06 notes that `automations enable` and `automations delete` are owner-only (refused under AGENT-07 markers before anything is read or written); guard `TestAutomationsCLI_EnableDeleteRefusedUnderAgentMarkers` added.
- 2026-10-15 (Automations P1, board #753): file created with AUTO-01..13 from spec §14.1. Enforced: AUTO-01, 04, 05, 07, 08, 10, 11; AUTO-02 (read side), AUTO-06 (executor, indexer, CLI — ask #271), AUTO-09 (scheduler and CLI), AUTO-12 (P1 half). Planned: AUTO-03 (P2), AUTO-13 (P5), the write side of AUTO-02 (P2), the `draft_automation` half of AUTO-06 (P3), the event half of AUTO-09 (P4), the session/shell half of AUTO-12 (P5). Owner rulings recorded: ask #280 (D16 draft refusal keyed by `approval_hash`; D22 `slack:read@*` or `tool:list_messages`), ask #287 (a Jira project grant covers linked data; `digests:read` and `find_experts` under `people:read` kept). Related strengthening elsewhere: AGENT-07 marker and refused commands (`agent-actions.md`), the DEV-01/AGENT-06 telemetry narrowing (`dev-surface.md`, `agent-actions.md`), the FEAT-03 `automations` fast-forward hook (`features.md`).
