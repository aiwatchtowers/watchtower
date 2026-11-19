# Behavior Inventory — Background AI consent

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: before adding a model call that a timer, a sync cycle or an
> event starts, or a component that reads the consent, read this file first.
> Any proposed change that would break a guard test must be raised as a
> question before touching code.

**Module:** `internal/aiconsent` (state, reading, origin, the per-call backstop) and the consent gates: `internal/daemon/ai_consent.go` (`aiPhase`), the cycle in `internal/daemon/daemon.go` (`runSync`), `internal/automations/{scheduler,bus,executor}.go`, `internal/automations/builtin/{runner,watchslot}.go`, the spec-review sweep (`internal/daemon/spec_review_sweep.go`), the leaves' backstop (`cmd/` generators, `internal/agentloop`), the spawn origin env (`internal/automations/sdk_shell.go`, `cmd/automations_backends.go`, `cmd/workbench_spec_review_launch.go`), `cmd/ai_background.go`; Swift twin `WatchtowerDesktop/Sources/WatchtowerCore/Models/BackgroundAIConsent.swift`.
**Spec:** `docs/superpowers/specs/2026-11-17-background-ai-consent-design.md` (§2, §3.2, §4, §13).
**Rule:** background = started by a timer, a sync cycle or an event; not by the owner's own gesture.

## BGAI-01 — No background AI without the effective `allowed`; a unit started under it may finish

**Status:** Enforced

**Observable:** No background unit (spec §2.1, in any process) calls a model unless the effective state is `allowed`. While it is not — the owner has not answered, has paused, or the organization's profile turned it off — a sync cycle still runs every source sync and every mechanical phase, but makes no model call, writes no `pipeline_runs` row for an AI phase (digests, media, tracks, people, stream digests, ideas, memory, next step, briefing, day plan, coach, history backfill), starts no AI automation run (a due `schedule` recipe gets no run and its window is not caught up later, AUTO-10; an AI `event` recipe is left out of the bus; a queued `schedule`/`catch_up`/`event`/`sync` run of an AI recipe ends `cancelled` with `Background AI is paused`), skips the AI built-ins at their slots before the gate and the row, holds the history backfill whole (no fetch, no row change, no strike) and holds the spec-review relaunch (the row stays queued). A refusal by the backstop is a skip, never an error row or a spent attempt. A component built without a consent reader reads `aiconsent.Current`, never "ungated"; with no config path, or a config that cannot be read or parsed, that reads paused. A unit that started while allowed — a running phase, a claimed run — finishes when the owner pauses mid-way (D12); the next one does not start.

**Mechanism:** `aiconsent.Current` resolves the owner's `ai.background_runs` answer with the forced `AllowBackgroundAI` key (spec §3.2). The daemon reads it before each AI phase (`aiPhase`, admitting the phase's ctx as `phase:<name>`); the scheduler once per Tick; the bus at each Begin; the executor when it claims a background run (admitting the run); the built-in runner after a queued Run Now is taken. Every model leaf calls `aiconsent.Check`, which refuses a background, non-admitted call while paused (`ErrPaused`). Processes a background unit starts carry `WATCHTOWER_AI_ORIGIN=background` (and `WATCHTOWER_AI_ADMITTED` when admitted), so their own leaves apply the same rule.

**Why locked:** Background AI spends the owner's plan or money and sends their data to a model without a gesture. The owner's answer is the only thing that starts it; a gate missed anywhere (a new phase, a component built without a reader, a new spawn) would spend in the background while the app says "paused".

**Test guards:**
- `internal/daemon/bgai_cycle_test.go::TestBGAI01_PausedCycleMakesNoModelCall`, `::TestBGAI01_PausedCycleSkipsMemory`, `::TestBGAI01_NilReaderFailsClosed`, `::TestBGAI01_RunStartedBeforePauseFinishes`
- `internal/automations/bgai_default_test.go::TestBGAI01_NilReaderFailsClosed`
- `internal/daemon/ai_consent_test.go::TestBGAI01_PauseMidCycleFinishesPhaseSkipsNext`, `::TestBGAI01_PauseMidCycleSkipsWithoutErrorRow`, `::TestBGAI01_PausedHoldsBackfillWhole`, `::TestBGAI01_PausedTrackGroupSkipsLegacyTracksAndRollups`, `::TestBGAI01_PausedLegacyMorningBriefSpendsNothing`, `::TestBGAI01_PausedLegacyIdeaFinderStampsNothing`, `::TestBGAI01_PausedLegacyCustomTrackScanWritesNothing`, `::TestBGAI01_ErrPausedSpendsNoAttempt`, `::TestBGAI01_PausedLegacyMorningBriefKeepsConflictPhase`, `::TestBGAI01_PausedSkipsActiveMorningBriefSlot`, `::TestDaemon_ConsentLogOncePerChange`
- `internal/daemon/bgai_spawn_test.go::TestBGAI01_EveryDaemonSpawnSetsOrigin`, `::TestBGAI01_SpawnCheckerCatchesNewSpawn`
- `internal/daemon/spec_review_sweep_test.go::TestSpecReviewSweep_HoldsWhilePaused`
- `internal/daemon/history_backfill_test.go::TestPhaseMemory_NoWaitForPausedOrOverdueBackfill`
- `internal/automations/consent_test.go::TestScheduler_PausedAdvancesWithoutRun`, `::TestScheduler_AllowAfterPauseDoesNotCatchUp`, `::TestScheduler_NonAIRecipeRunsWhilePaused`, `::TestBus_PausedSkipsAIRecipes`, `::TestExecutor_PausedCancelsBackgroundAIRun`, `::TestExecutor_PausedRunsNonAIRecipe`, `::TestExecutor_BackgroundSyncRunHeldInline`, `::TestExecutor_AdmittedCallerSyncRunStillHeld`, `::TestExecutor_AdmittedRunFinishesAfterPause`, `::TestManifest_UsesAISharedFixture`, `::TestAutomationUsesAI_UndecodablePermissionsFailClosed`, `::TestRunMarkerEnv_MatchesAiconsent`
- `internal/automations/sdk_shell_test.go::TestShellEnv_CarriesOrigin`
- `internal/automations/builtin/consent_test.go::TestBuiltinRows_UseAI`, `::TestRunner_PausedSkipsAIBuiltinWritesNothing`, `::TestRunner_MechanicalBuiltinRunsWhilePaused`, `::TestRunner_PauseDuringGateWritesNoRun`, `::TestRunner_AdmittedSyncRunFinishesAfterPause`
- `internal/automations/builtin/registry_test.go::TestBuiltin_EveryPrimitiveDeclaresAI`
- `internal/automations/builtin/watchslot_test.go::TestRunWatchSlot_PausedSkipsWithoutGate`
- `internal/db/automation_runs_test.go::TestCancelQueuedBackgroundPaused_OnlyQueued`
- `internal/aiconsent/aiconsent_test.go::TestCurrent_NoPathIsPaused`, `::TestCurrent_UnreadableConfigIsPaused`, `::TestCurrent_UnreadableConfigWithPermissiveProfileIsPaused`, `::TestCurrent_UnparsableConfigWithPermissiveProfileIsPaused`, `::TestCurrent_AmbiguousKeyCaseIsPaused`, `::TestCurrent_UnknownValueReadsAbsent`, `::TestCurrent_FailedParseIsRetried`, `::TestCurrent_RereadsOnlyOnMtimeChange`, `::TestCurrent_RereadsOnModeChange`, `::TestCheck_DaemonBackgroundIsRefused`, `::TestCheck_NilReaderReadsCurrent`
- `internal/aiconsent/origin_test.go::TestOrigin_ContextBeatsProcess`, `::TestOrigin_EnvMarksBackground`, `::TestOrigin_AutomationMarkerTakesRunTrigger`, `::TestOrigin_AutomationMarkerFailsClosed`, `::TestOrigin_FailedLookupReturnsAResolvedMark`, `::TestCheck_AdmittedBackgroundPasses`, `::TestOverrideHookOnlyInTests`
- `internal/agentloop/client_test.go::TestAgentloop_RefusesUnadmittedBackground`
- `internal/jira/board_refresh_test.go::TestCheckAndRefreshProfiles_PausedSkipsBackgroundRefresh`, `::TestCheckAndRefreshProfiles_ErrPausedSpendsNoAttempt`
- `cmd/ai_consent_leaf_test.go::TestPolicyCheckedGenerator_RefusesBackgroundOriginInAnyProcess`, `::TestBGAI01_BackgroundCLIAIQueryEndToEnd`, `::TestCLIAgentRunner_PausedSpawnsNothing`, `::TestToolRouteProvider_PausedBuildsNoLeaf`, `::TestOneOffClients_BackgroundProcessPausedRefused`, `::TestREPLClient_ChecksConsentPerCall`, `::TestPlanUsagePoller_NotGatedByConsent` (the plan-limit read is exempt, D17)
- `cmd/automations_backends_test.go::TestAutomationAgentEnv_CarriesOrigin`, `::TestCodexAgentServerEnv_NamesOrigin`
- `cmd/workbench_spec_review_launch_test.go::TestLaunchSpecReview_SweepSetsOrigin`
- `cmd/workbench_spec_review_test.go::TestSpecReviewRun_BackgroundOriginPausedLeavesQueued`
- `cmd/builtin_upgrade_test.go::TestCustomTracksUpgrade_PausedStaysPaused`
- `WatchtowerDesktop/Tests/Core/DesktopModelLaunchSitesTests.swift::testEveryProcessLaunchOfTheCLIIsListed`, `::testNoStaleEntries`, `::testLiteralModelArgsUseRunModel` (every Desktop launch of a model command names its origin, plan Decision 11)

**Locked since:** 2026-11-18

## BGAI-02 — An owner gesture is never gated

**Status:** Enforced

**Observable:** Whatever the consent state, the owner's own gestures call the model as before: a CLI command the owner types (or the Desktop runs for a button), every chat the owner starts or answers — also when the daemon hosts it (each turn runs in a child with owner origin), an automation run triggered by `manual`, `button`, `dry_run` or `reply`, a Run Now of a built-in at its slot, and reaction commands (D3). A model call the daemon makes on the owner's behalf names its origin explicitly; an unmarked one in the daemon stays gated (fail closed).

**Mechanism:** The process default origin is owner outside the daemon and background inside it (`aiconsent.InitProcess`); a ctx mark wins over it (`WithOwnerStarted`, `WithAdmitted`). The chat engine's spawns build their env with `aiconsent.OwnerEnv`; the reaction poll marks its ctx owner-started; owner triggers are not background (`aiconsent.BackgroundTrigger`). The hub and the chat engine make no in-process model call, and callbacks the daemon hosts name their origin (static guards).

**Why locked:** Consent is about work the owner did not start. Gating a gesture would make the app look broken (a button that does nothing) and push the owner to allow background AI just to use features they asked for.

**Test guards:**
- `cmd/ai_consent_leaf_test.go::TestBGAI02_TypedCommandNotGated`, `::TestBGAI02_DaemonUnmarkedCallStaysGated`, `::TestBGAI02_DaemonChatTitleIsOwnerCall`
- `internal/automations/consent_test.go::TestBGAI02_ManualRunWhilePaused`, `::TestExecutor_OwnerStartedSyncRunPasses`
- `internal/automations/builtin/consent_test.go::TestRunner_PausedStillRunsQueuedRunNow`
- `internal/daemon/ai_consent_test.go::TestDaemon_ReactionCommandsRunWhilePaused`
- `internal/daemon/bgai_spawn_test.go::TestBGAI02_HostedCallbacksNameTheirOrigin`, `::TestBGAI02_CallbackCheckerCatchesUnmarkedModelCall`
- `internal/chatengine/owner_env_test.go::TestBGAI02_ChatEngineChildIsOwner`
- `internal/hub/bgai_boundary_test.go::TestBGAI02_HubAndChatEngineMakeNoInProcessModelCall`
- `internal/reactioncmd/dispatch_test.go::TestReactionCmd_PausedClaimsNothingButPublishes`, `::TestReactionCmd_ResumeDispatchesWhatWasPlacedWhilePaused`
- `internal/aiconsent/aiconsent_test.go::TestCheck_NoopOutsideTheDaemon`, `::TestCheck_OwnerStartedPasses`

**Locked since:** 2026-11-18

## BGAI-03 — Go and Swift resolve the same state

**Status:** Enforced

**Observable:** For every combination of the owner's answer (absent, `allowed`, `paused`, an unknown value) and the forced `AllowBackgroundAI` key (absent, `true`, `false`), the daemon and the CLI (Go) and the Desktop (Swift) show and enforce the same effective state and reason — the table of spec §3.2.

**Mechanism:** One shared fixture, `internal/aiconsent/testdata/consent_cases.json`, read by both resolvers' tests.

**Why locked:** A Desktop that says "allowed" while the daemon holds (or the reverse) breaks the owner's trust in the switch.

**Test guards:**
- `internal/aiconsent/aiconsent_test.go::TestBGAI03_SharedFixture`
- `WatchtowerDesktop/Tests/Core/BackgroundAIConsentTests.swift::testSharedFixture`

**Locked since:** 2026-11-18

## Changelog

- 2026-11-18 (board #1886, ask #1452): BGAI-01..03 added.
- 2026-11-18 (board #1886, ask #1452, review #1484): BGAI-01 gains the Desktop launch-site guards (`DesktopModelLaunchSitesTests`, Task 18): a strengthening, no guard weakened. Feature note: `docs/features/background-ai-consent.md`.
- 2026-11-19 (Watchman phase 2 merged with main, Task 20): Watchman's learning, profiles and weekly backtest go through `aiPhase`, the twin leases nothing while paused, and `cmd/watchman_backtest.go` joins `bgaiSpawnRoots` (its child carries the phase's origin); `watchman learn`/`backtest` join `model_commands.json`. A strengthening, no guard weakened.
