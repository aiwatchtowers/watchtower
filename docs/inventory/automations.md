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
`internal/db/automation_reads.go`, `internal/db/automation_grants.go`,
`internal/db/migrations/00113_automations.sql`,
`internal/db/migrations/00117_automation_tool_grants.sql`,
`internal/db/automation_run_replay.go`, `internal/db/migrations/00146_automation_run_replay.sql`,
`internal/automations/replay.go` (resume after a restart, board #795),
`cmd/automations*.go` (incl. `cmd/automations_auto.go`), `cmd/automations_registry.go`,
`internal/briefing/automations.go` (the FROM YOUR AUTOMATIONS block),
`internal/daemon/automation_wake.go`, `internal/automations/bus.go`,
`internal/automations/eventsrc*.go`, `internal/daemon/automation_events.go`,
`internal/db/approvals.go`, `internal/automations/builtin/approvals.go`,
`internal/daemon/approval_sweep.go`, `cmd/inbox_approvals.go` (the approval trigger),
`internal/db/automation_event_sources.go` (P4 event bus and sources),
`internal/tools/emails.go`,
`internal/tools/automation_reads.go`, `internal/automations/authoring/` (`draft_automation`,
`save_automation`, P3), the Desktop's automation views and Core services
(`WatchtowerDesktop/Sources/Views/Automations/`,
`WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/`, P3),
`internal/db/automation_builtins.go`, `internal/db/migrations/00150_builtin_automations.sql`,
`internal/automations/sdk_builtin.go` and `internal/automations/builtin/` (`registry.go`,
`recipes/morning-brief.md`, `sync.go`, `runner.go`, `ownercopy.go`, `card.go`; built-in
automations, C2)
**Last full audit:** 2026-10-16 (Automations P3)

Phases: P1 (core), P2 (writes), P3 (authoring + Desktop), P4 (events), P5
(workbench) and P6 (mcp, agent, templates) are all in code; each flipped its
**Planned** part in the same commit as its code, exactly one plan per part. Guard tests are named `TestAutoNN_…` (Go) and `testAutoNN_…` (Swift);
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
the scope, so the call needs `@*`. An output shortcut needs its kind in
`outputs`; `output.slack` needs more (D28, ask #315,
`(*Manifest).AllowOutputTool`): `outputs: [slack]` **and** a permission that
admits the `send_slack_message` call itself — `slack:write@<account>` for the
resolved account, `slack:write@*`, or the unscoped `tool:send_slack_message`
(which admits it like `slack:write@*`); `output.target` needs only
`outputs: [target]`. A Jira project grant covers what the tool
returns with that project's issues, linked issues of other projects included
(owner ruling, ask #287). An uncaught `PermissionDenied` ends the run
`failed`/`permission`.

**Why locked:** The owner confirms one manifest; everything the script can do
must follow from that text alone. A second source of permission (a trust
switch, a default, a lenient scope match) would let a recipe do what the
owner never read.

**Test guards:**
- P6 (`mcp()`, `agent()`): `cmd/automations_backends_test.go` — `TestMCP_OnlyQC02AllowedTools` (a tool outside QC-02's allowed list of an enabled, listed connection never reaches the server); `internal/automations/sdk_mcp_test.go` — `TestMCPModule_ManifestFirst` (the manifest check precedes any backend call); `internal/automations/agent_toolset_test.go` — `TestAgent_ToolSetIsIntersection` (the effective set is the manifest's grants intersected with the run's tool surface); `cmd/mcp_automation_test.go` — `TestAgentMCPServer_GatesEachCallByManifest`; `internal/agentloop/loop_test.go` — `TestAgentLoop_GateRefusesUnofferedAndOutOfScope`
- `internal/automations/sdk_test.go` — `TestAuto01_DeniedCallThrowsAndWritesDeniedStep` (the fake registry records zero calls), `TestLLM_StrongNeedsStrongPermission`, `TestOutput_GateAndBodyLimit`
- `internal/automations/sandbox_test.go` — `TestSandbox_DeniedCallWritesDeniedStep`
- `internal/automations/manifest_test.go` — `TestManifest_ScopeMatching`, `TestManifest_JiraScopeFromRealArgs`, `TestManifest_EmailScopeMatchesLabelOrAddress`, `TestManifest_UnscopedSourceReadsNeedStar`, `TestManifest_D23ToolScopes`, `TestManifest_KnowledgeToolsOnlyByToolEntry`, `TestManifest_ToolNotOnAutomationSurfaceDenied`, `TestManifest_ScopeOfErrorIsADeniedNotAPanic`, `TestManifest_LLMStrongImpliesLight`, `TestManifest_OutputGate`, `TestManifest_AllowOutputToolSlackNeedsWriteScope`, `TestManifest_AdmitsWrite`
- `internal/automations/sdk_output_p2_test.go` — `TestOutput_SlackNeedsSlackWriteScope` (D28), `TestOutput_TargetGateIsOutputsNotTool`
- `internal/automations/capabilities_test.go` — `TestManifest_LinearCapability`, `TestLinearScope_MovedIssueUsesCurrentTeam`, `TestLinearScope_TeamArgsAndTeamsList`, `TestLinearScope_RowsWithoutTeamKeyAreAbsentScope`, `TestLinearScope_WriteTools` (the `linear` capability, 2026-10-18)
- `internal/automations/manifest_scope_test.go` — `TestManifest_JiraProjectGrantCoversLinkedData`, `TestManifest_CaseVariantScopeArgRefused`, `TestManifest_NilDBDeniedNotPanic`
- `cmd/automations_registry_test.go` — `TestToolCapabilities_CoversEveryAutomationTool` (every tool visible on `automation` has a capability entry or is deliberately `tool:`-only)
- `internal/automations/executor_test.go` — `TestExecutor_UncaughtPermissionDeniedFailsWithPermissionKind` (the run-level mapping)

**Locked since:** 2026-10-14

## AUTO-02 — Writes only through the registry

**Status:** Enforced (P1: the read side; P2: the write side — `tool()` writes
and `output.target`/`output.slack` through `Registry.Propose`)

**Observable:** The only SDK paths that change data outside the automation's
own tables are `Registry.Propose` (and the `Apply` it triggers) on the
`automation` surface, `shell()` and `session()` (P5); `output.inbox`/`report`/`briefing`
write only `automation_outputs`, and `state.set` only
`automation_state`, both through the run's commit (AUTO-04). `tool()` reads
go through `Registry.CallRead`; `tool()` writes (P2's `ToolWriteModule`) go
only through `Registry.Propose` under the run's automation binding
(`Surface='automation'`, `context_type='automation_run'`, `context_id` and
`AutomationRunID` = the run id, never `DirectApply`), after the manifest check:
each write is one `agent_actions` row, pending unless the automation trust
order decides `execute` (AGENT-03), and a dry run never reaches the registry
(AUTO-12). `output.target(args)` and `output.slack(args)` are shortcuts for the
same path: each proposes `create_target`/`send_slack_message` through
`Registry.Propose` under the run's binding (a pending row unless a grant or
trust decides execute), gated by `outputs` (plus, for `output.slack`, the
`slack:write` scope of D28 — AUTO-01), and throw `NotAvailable` when the tool is
not visible on the `automation` surface. A workbench automation's run writes
through the same paths (since P5): the registry resolves its workbench from
run → `automations.project_id` at Propose, Approve and every Apply and checks
`WorkbenchAlive` and the tool's `Scope` against it, so a proposal whose
workbench was deleted fails at Apply, and a row whose run is gone fails closed
(`ErrAutomationRunGone`, `NotAvailable` to the script) (AGENT-01). The automation read
tools write nothing either: `memory_open` skips its access-stat bump on the
`automation` surface and `buildAutomationRegistry` mounts `memory_recall`
without the shadow handle, so it writes no shadow row. An Inbox card may carry
a `target` button (`{label, target: {title, intent?, parent?}}`, Inbox builder
A, ask #445): writing the card creates nothing; the button needs
`outputs: [target]` (`PermissionDenied` otherwise), and its press only proposes
`create_target` through `Registry.Propose` on the `inbox` surface, so nothing
is written until the owner's Approve.

**Why locked:** Every write an automation makes must be one reviewable
`agent_actions` row (AGENT-01) or a declared automation output; a module that
wrote a table directly would bypass the Inbox, trust and the owner's Approve.

**Test guards:**
- `internal/automations/sdk_tool_write_test.go` — `TestAuto02_ToolWriteGoesThroughPropose` (P2: a `tool()` write is one pending `agent_actions` row on the `automation` surface with `context_type='automation_run'`; no target is created before an approval), `TestToolWait_AppliedRejectedFailed`
- `internal/automations/sdk_output_card_test.go` — `TestOutput_TargetActionNeedsTargetOutput` (a target action — on the card or in a list row of its blocks — is a `PermissionDenied` without `outputs: [target]`, nothing buffered)
- `cmd/actions_target_button_test.go` — `TestAuto02_TargetButtonOnlyProposes` (the target button's press, `actions propose --tool create_target --surface inbox` without `--approve`, records one pending row with the button's `automation_output` context and creates no target); `internal/tools/targets_inbox_test.go` — `TestCreateTarget_ParentIDOnlyOnInbox` (`parent_id` refused on main, reaction and automation, no row; on the inbox the approved row creates the child under its parent)
- `internal/automations/sdk_output_p2_test.go` — `TestOutput_TargetGateIsOutputsNotTool`, `TestOutput_SlackIsAProposalUnlessGranted`, `TestOutput_ToolOffTheAutomationSurfaceIsNotAvailable`, `TestWorkbenchAutomation_WritesAreProposals`
- `internal/tools/registry_automation_test.go` — `TestAgent01_AutomationWriteRecordsProposalOnly`, `TestWorkbenchAutomation_ProposesInItsRunsWorkbench`, `TestWorkbenchAutomation_RowAppliesOnlyWhileItsWorkbenchLives`
- `internal/tools/automation_reads_test.go` — `TestMemoryOpen_NoAccessBumpOnAutomationSurface`, `TestD23Tools_AutomationSurfaceOnly`
- `cmd/automations_registry_test.go` — `TestBuildAutomationRegistry_AddsMemoryTools` (recall on this registry writes no shadow row)

**Locked since:** 2026-10-14

## AUTO-03 — Auto only by the owner, bound to the hash

**Status:** Enforced

**Observable:** An auto grant is written only by `automations auto … on`
outside AI-agent markers with the current `approval_hash`; it applies only
while that hash equals the run's; any script/permission change deactivates
it until the owner grants the new hash or the recipe returns to the exact
granted text (the grant compares hashes only); every auto write is one `agent_actions` row through
`Apply`'s claim plus an `auto=1` step. AlwaysAsk tools are never auto. The
grant table is `automation_tool_grants` (migration 00117; store
`internal/db/automation_grants.go`). `automations auto <id|slug> <tool> on
--hash <sha> [--workbench N]` refuses, in order: an AI-agent marker (AGENT-07), a missing
`--hash`, an unknown automation, a hash other than the row's current `approval_hash` ("the recipe
changed; reload and confirm again"), an unparsable recipe, a tool not in the
automation registry, an AlwaysAsk tool ("never auto", D14) and a tool the
manifest does not admit as a write (`Manifest.AdmitsWrite`: write access, on
the `automation` surface, admitted by the manifest for `tool()` or through the
output shortcut — `outputs: [target]` for `create_target`; `outputs: [slack]`
alone does not admit `send_slack_message`, which needs `slack:write`, D28).
`auto … off` stays open, is idempotent and needs no registry check. A call
inside an automation's `agent()` (`Binding.AutomationAgent`) is never auto
(the branch is in code; nothing sets the flag until P6's `agent()`). The
amendment of AGENT-03 (spec §14.2, owner-approved in ask #265) is in
`agent-actions.md`. P3: the Desktop runs `auto … on` only from an explicit
owner gesture — an **Auto** toggle in the edit form (with the loaded
`approval_hash`) or a checked "Keep auto for <tool>" box in the Automations panel's draft column
(with the saved hash). A save that changes `approval_hash` lists the grants it
pauses with every box **unchecked**, and no `auto … on` runs unless the owner
checks one. `save_automation` never carries a grant over to the saved hash
(spec §6.4).

**Why locked:** Auto is the one place an External write runs without a
per-call click; it is safe only while it is bound to exactly the code and
permissions the owner reviewed.

**Test guards:**
- `cmd/automations_auto_test.go` — `TestAuto03_GrantInactiveAfterEditAndReactivatedByNewHash`, `TestAgent03_AutoGrantRefusedUnderAgentMarkers`
- `internal/tools/registry_automation_test.go` — `TestAgent03_AutoGrantAppliesExternalOnlyOnAutomationSurfaceWithMatchingHash`, `TestAgent03_AutoGrantNeverCoversAnotherAutomationOrSurface`, `TestAgent03_RecipeEditMakesAutoGrantInactive`, `TestAgent03_AlwaysAskIsNeverAuto`, `TestTrustOrder_AutomationSurface` (incl. its `AutomationAgent` rows)
- `internal/db/automation_grants_test.go` — `TestMigration00117_GrantsTable`, `TestGrant_StaleReGrantKeepsExistingGrant`
- `internal/automations/manifest_test.go` — `TestManifest_AdmitsWrite`
- C2 built-ins: `cmd/builtins_test.go` — `TestAuto03_BuiltinGetsNoAutoGrant` (`automations auto` on a built-in is refused; a built-in never holds a grant)
- P3: `internal/automations/authoring/save_test.go` — `TestSaveAutomation_GrantsNotCarriedOver`; `WatchtowerDesktop/Tests/Core/AutomationFormTests.swift` — `testAuto03_KeepAutoBoxesUncheckedByDefault`; `WatchtowerDesktop/Tests/Core/AutomationEditorCenterTests.swift` — `testNoAutoOnWithoutACheckedBox`
- see AGENT-03 in `agent-actions.md`

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
run never commits. A succeeded script whose journal lost a write still commits
(its writes already happened; failing it would make the next run repeat them),
and the run's error notes the incomplete journal (board #562). The same
commit upserts living outputs by `(automation_id, output_key)` (migration
00182: a changed `content_hash` moves `changed_at` and clears the read, done,
dismissed and press state; a same-hash rewrite moves only `written_at` and
the explicit `folder_id` (the last run's choice, Inbox builder B); the read
state is kept) and
applies `output.remove` (`RunCommit.Removals`, delete by key, a missing key
is a no-op); every other terminal status leaves living rows byte-identical
too (Inbox builder A, ask #961). The run's buffer keeps one operation per
living key — the later of `output.inbox({key})` and `output.remove({key})`
wins — so a commit never writes and removes one key, and the outputs cap
counts each kept output once; a resumed run's replay rebuilds the same
buffer.

**Why locked:** A run that dies halfway must be safe to rerun; a half-written
cursor in `state` would silently skip or repeat work.

**Test guards:**
- `internal/db/automation_runs_test.go` — `TestAuto04_FinishCommitOnlyOnSuccess`, `TestFinish_RefusesTerminalRun`, `TestFinish_RefusesForeignOutput`
- `internal/db/automation_outputs_living_test.go` — `TestAuto04_LivingUpsertCommittedOnlyOnSuccess`, `TestAuto04_RemoveCommittedOnlyOnSuccess` (Inbox builder A)
- `internal/automations/executor_test.go` — `TestAuto04_FailedRunLeavesStateAndOutputsUnchanged` (failed, timed out, over budget, cancelled), `TestAuto04_SucceededCommitsStateAndOutputsAtomically`
- `internal/automations/sdk_test.go` — `TestState_ReadsCommittedPlusOwnSets`, `TestState_RejectsUnserialisableValues`
- `internal/automations/sdk_output_blocks_test.go` — `TestAuto04_LivingRunCommitsUpsertAndRemoval`, `TestOutput_RemoveLaterWins`, `TestOutput_OutputsCapCountsKeptOutputs`, `TestAuto08_ResumeRebuildsLivingBuffer` (Inbox builder A: the SDK buffer and the executor's commit of living outputs)
- `internal/automations/sdk_output_p2_test.go` — `TestOutput_BriefingBufferedAndCommittedOnSuccess` (P2: `output.briefing` is buffered like `report` and committed only with `succeeded`)
- `internal/automations/run_limits_test.go` — `TestAuto04_JournalErrorAfterSuccessStillCommits` (board #562)
- `internal/automations/inbox_folder_field_test.go` — `TestAuto04_FailedRunWritesNoFolder` (Inbox builder B: a failed run writes no `folder_id`, no artifact and no missing-folder journal line)

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

A recipe that keeps living artifacts (`artifacts: living`, Inbox builder A,
ask #961) must declare `concurrency: 1`: the parser refuses any other value
("concurrency: an automation with living artifacts runs one at a time; set
concurrency: 1"), so two runs never upsert one key at once. The serial-run
reasons live in one function, `automations.serialRunReasons`.

**Test guards:**
- `internal/automations/recipe_test.go` — `TestAuto05_LivingArtifactsNeedConcurrencyOne`
- `internal/db/automation_runs_test.go` — `TestAuto05_OneActiveRunPerAutomation`, `TestAuto05_ConcurrencyN`, `TestAuto05_ConcurrentClaimsOneWinner` (8 goroutines on a file DB), `TestClaimWithin_HonoursTheGlobalRunningBound`, `TestResumeIfSlot_WaitsForAFreeRunningSlot`
- `internal/automations/executor_test.go` — `TestAuto05_OneActiveRunPerAutomation`, `TestExecutor_MaxConcurrentRuns`, `TestExecutor_ReadyWaitsGetFreedSlotsBeforeQueuedRuns`, `TestWaiter_ResumeWaitsForAFreeSlot`

**Locked since:** 2026-10-14

## AUTO-06 — Only confirmed content runs

**Status:** Enforced (P1: the executor, the indexer and the CLI, including
the CLI dry-run refusal of ask #271; P3: the `draft_automation` half, ask
#271; C2: amended for shipped built-ins, ask #500)

**Observable:** A run is claimed only when `confirmed_hash = approval_hash`
(and the row is parsed, enabled and not removed — `Automation.Runnable()`); a
queued run of a non-runnable automation ends `cancelled`/`not_runnable`. The
executor runs the indexed copy (`recipe_text`, snapshotted on the run as
`recipe_snapshot` at claim), never the file; an edit on disk during a run
does not touch that run, and the next rescan makes the automation
non-runnable when `approval_hash` changed. `approval_hash` covers the script,
permissions, outputs, scope, the trigger (without a button's cosmetic label;
its `confirm` counts), the `missed` policy, the budget (tokens and minutes)
and `concurrency` (ask #294), and `artifacts` when it is `living` (absent
for feed, so every feed recipe's hash is unchanged; ask #961), so a schedule,
missed-policy, budget, concurrency or feed → living edit waits for the owner
like a script edit; a name, `summary`, description
or button-label edit does not (`summary` since 2026-10-24). A recipe new to the index, or
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
changed between the check and the claim is cancelled, never run.
`draft_automation` refuses the same way (P3): when the draft's
`approval_hash` equals that of an indexed, not removed, unconfirmed
automation it validates but does not dry-run (`dry_run.status="refused"`, no
model call, no registry call) — owner-confirmed reading in ask #280. The
comparison is within the draft's scope: `approval_hash` covers the scope, so
the same text with another `workbench_id` hashes differently and dry-runs,
which is equivalent to the allowed one-line edit (any edit makes a draft).
The owner's preview (`automations preview --stdin --json`, the Look step's
**Dry run**, Inbox builder A, ask #445) shares `draft_automation`'s
evaluation (`authoring.EvaluateDraft`) and, as the owner's press, dry-runs
an unconfirmed recipe too: it refuses under every marker
(`WATCHTOWER_AUTOMATION_RUN_ID` included) before reading stdin, then runs
only after the owner confirms the text in the running Desktop (AGENT-07; the
Desktop's own launch is granted without a window), and the D16 refusal
above stays on the chat path (the zero evaluation options refuse; only
`EvaluateDraft` allows).
`save_automation` (P3) is the third caller of `ConfirmAutomation`: an
`AlwaysAsk` write whose `Execute` runs only after the owner's Approve
(AGENT-07) and confirms only the pinned `approval_hash`, refusing when the
re-parsed text hashes differently or the file's content hash changed since
propose (a hand edit, a file that appeared at a new slug, one that vanished).
Its card shows what Approve confirms: every hashed field (missed policy,
concurrency and artifacts included) and the code — the whole text of a new recipe, the diff
of an edit (`SaveAutomationCardModelTests`).
The built-ins' one-time upgrade step (C2) is the fourth caller: it confirms
only the owner copy it rendered from a customised prompt-store row that was
already running, after the index shows exactly those bytes. The daemon runs
the step at start, under agent markers too (it carries no code); its Retry,
`automations upgrade-builtins`, is owner-only and refuses under every marker.
The Desktop confirms only what it showed (as amended with the owner's approval in ask #475). Its confirming screen is the draft column of the Automations panel: it shows every hashed field of the exact bytes it saves. In the editor the column is stepped (What it collects · Look · When it runs, as amended with the owner's approval in ask #486), and the confirming screen is the current step plus the Changed row pinned above the footer: for an edit with a known diff, every changed field in the Changed box's words on each step but What it collects (where the box is); otherwise every field the step does not show with its value, under the box's "First confirmation" or unknown-diff line — with the scope named, a workbench by its name; the column as a whole shows — the script (through **Show recipe**), permissions, outputs, scope, trigger, missed policy, budget, concurrency and artifacts — and the hashed fields changed since the confirmed text (`validate --against` `changes`), or says the change is unknown (D26). The column shows the Go-reported hashed fields (`validate --json` `fields`), and every save and confirm button is off when it cannot show them. **Save and Turn On**, **Save and Confirm** and **Save Turned Off** save with `--confirm-hash` = the `approval_hash` `validate` returned for the very bytes saved and `--expect-content-hash` of the file the draft started from (a recipe changed on disk is refused, never overwritten); while a validation is in flight, or the bytes changed since the last one, every save and confirm button is disabled, and a press that finds the bytes changed re-validates instead of saving. **Confirm** and **Confirm and Turn On** on unchanged bytes pass the hash the column displayed (`confirm --hash <shown>`; a stale one is refused and re-read). A draft saved from the panel is enabled unless the owner picks **Save Turned Off**: `enable` runs as a separate owner call after the confirmed save, and **Save Turned Off** on an enabled automation disables it before saving. A template is installed from its panel only after the column showed `install-template --render`'s validation of the rendered text in the chosen scope; **Save and Turn On** then runs `install-template`, which still installs unconfirmed and disabled, and confirms each installed copy only when its `approval_hash` equals the one shown, then enables it — two further owner gestures. A mismatch stops at Needs confirmation; a failed confirm or enable leaves the installed copy in the list with its chip and is never rolled back. Quick run (P3, D27) never runs what the CLI would refuse: a palette or tray row that is unconfirmed, disabled or unreadable runs nothing — it opens the automation's card — and a `confirm: true` recipe runs only after **Run** in its sheet or alert. A run from the iPhone (`automation_run`, as amended with the owner's approval in ask #692) takes the same path for a workbench recipe only: the hub re-reads the row and refuses the same unconfirmed, disabled and unreadable recipes, and runs a `confirm: true` one only when the request carries `confirmed: true`, which the phone sends only after **Run** in its own "Run “<name>” on the Mac?" — so the confirmation is on the phone, and no sheet comes up on the Mac.
Switching a recipe on and deleting an automation are owner gestures too
(ask #293): `automations enable` and `automations delete` refuse under every
marker before anything is read or written (AGENT-07); `disable` stays open.
A gallery template installed by `install-template` (P6) is indexed like any
new file: unconfirmed and disabled, never runnable until the owner confirms
and enables it.
`inbox:reply` is a manifest entry like any other (2026-10-21, ask #475): it is
in `approval_hash`, the confirming screen lists it as "Reacts to its own Inbox
buttons", and `output.inbox` refuses a `reply` action without it
(`PermissionDenied`). `automations reply` refuses a press when the automation
is not runnable or its confirmed recipe lacks the capability, and the executor
fails a `reply` run whose claimed snapshot lacks it (`error_kind='permission'`).
A press runs the currently confirmed text; a button's `value` and `data` only
steer code the owner confirmed. A press names its button by its index in the
card's flattened action list (the card's own actions, then each block action
in document order, Inbox builder A). With `--content-hash` (the Desktop
always passes the hash of the card it drew) a press on a card whose
`content_hash` changed since is refused (`db.ErrOutputChanged`, "This card
changed — look again") and nothing is queued. The press writes the card's
`content_hash` into the run's payload, and the executor, on every start of a
`reply` run (a resumed one too), ends the run `cancelled`/`cancelled` before
its script when the card no longer carries that hash or was removed: the
button it was pressed for is gone. A payload without the hash (a card or a
press from before content hashes) runs as before.
A built-in automation (`origin = 'builtin'`) whose recipe bytes equal the
version shipped in the running app is runnable without the owner's
confirmation — the release is its confirmation: the built-in indexer
(`builtin.Sync`) confirms exactly that text with `db.ConfirmShippedBuiltin`,
which refuses any other bytes. Everything else holds: the owner's copy
(`.builtin/<id>.md`) runs only after the owner confirms it, a hand edit of
any hashed field makes it unconfirmed, the one-time upgrade step's carried
prompt is confirmed as the owner's content already running, and only built-in recipes may
declare a `sync` trigger or a `builtin:` capability, with one Personal
exception (C3): a Personal (non-workbench, non-built-in) recipe may declare
`trigger: {sync: custom_tracks}` only when its manifest holds `track:scan`;
`track:scan` is personal-only (refused in workbench and built-in scopes) and
requires that trigger. Every other slot and every `builtin:` entry stays
refused outside a built-in automation. An owner copy that is a
symlink, directory or special file is never read (the shipped text is used);
one that cannot be read leaves the row as it was. A slot run of an
unconfirmed built-in is never written, and its queued manual runs are
cancelled `not_runnable`; `ExecuteBuiltinInline` refuses an unconfirmed
built-in the same way.
A Personal recipe with `track:scan` (Watch for something) runs only after the owner confirms it, like any Personal recipe; it runs at the `custom_tracks` slot of the sync cycle on the slot executor, never in the executor's queue. The owner-only commands `tracks create|watch|start|instruction` (Task 11) confirm only the recipe they render from the template, and the one-time upgrade confirms only the watch recipes it renders for custom tracks that were already scanning (Task 12).
The watch slot (`builtin.Runner.RunWatchSlot`) writes no run for an unconfirmed watch recipe and cancels its queued manual runs `not_runnable`; a hand edit stops its scans until the owner confirms again, and the instruction mirrored onto the track is only ever the confirmed text's. A recipe whose file is gone (`removed_at`) is never run, and its track is unbound and paused with its events kept. `builtin.CapturePrompts` lends a recipe's prompt to a Go drain (`ideas mine --from`) only from confirmed text (`ErrNotRunnable` otherwise), by a dry run in memory that calls no primitive.

**Why locked:** "What was confirmed is exactly what runs" is the whole
security model: a git pull, a hand edit or an agent's edit must never run
code or permissions the owner did not see.

**Test guards:**
- `internal/automations/executor_test.go` — `TestAuto06_UnconfirmedRecipeIsCancelledNotRun`, `TestAuto06_DryRunOfUnconfirmedRecipeRuns`, `TestAuto06_ExecutorRunsIndexedCopyNotFile`, `TestAuto06_EditDuringRunDoesNotAffectRunningSnapshot`, `TestExecutor_ExecuteInlinePinnedRefusesChangedRecipe`
- `internal/automations/indexer_test.go` — `TestRescan_IndexesNewRecipeUnconfirmedAndDisabled`, `TestRescan_ChangedOutsideWatchtowerNeedsConfirmation`, `TestAuto06_ScheduleBudgetEditNeedsConfirmation`, `TestAuto06_ButtonLabelEditKeepsConfirmation`, `TestApprovalHash_GoldenCanonicalBytes`, `TestApprovalHash_ButtonLabelIsCosmetic`
- `internal/db/automations_test.go` — `TestAutomationIndex_RunnableTable`, `TestAutomationIndex_ConfirmRefusesStaleHash`, `TestAutomationIndex_UpsertKeepsOwnerColumns`, `TestAutomationIndex_InsertNeverSetsOwnerColumns`, `TestAutomationIndex_UpsertChangedApprovalHashNeedsConfirmation`
- `cmd/automations_test.go` — `TestAutomationsCLI_ConfirmRefusedUnderAgentMarkers`, `TestAutomationsCLI_SaveIsAtomicAndIndexes` (`--confirm-hash` under a marker refused, file not written), `TestAutomationsCLI_DryRunUnconfirmedRefusedUnderAgentMarkers`, `TestAutomationsCLI_DryRunRecipeChangedBeforeClaimRefused`, `TestAutomationsCLI_EnableDeleteRefusedUnderAgentMarkers`
- `cmd/automations_templates_test.go` — `TestInstallTemplate_InstalledUnconfirmedAndDisabled` (P6: an installed template is unconfirmed and disabled; `run` is refused and a queued run is cancelled `not_runnable`), `TestInstallTemplate_RenderHashMatchesInstall`
- P3: `internal/automations/authoring/draft_test.go` — `TestDraftAutomation_RefusesDryRunOfUnconfirmedRecipe`, `TestDraftAutomation_RemovedUnconfirmedRecipeDoesNotBlock`; `internal/automations/authoring/save_test.go` — `TestSaveAutomation_AlwaysAskAndPinsHash`, `TestSaveAutomation_RefusesWhenFileChangedSincePropose`, `TestSaveAutomation_RefusesWhenFileAppearedForNewSlug`, `TestSaveAutomation_RefusesHashDrift`; `cmd/automations_test.go` — `TestAutomationsCLI_SaveRefusesWhenFileChangedSinceLoad`, `TestAutomationsCLI_ShowChangesFromConfirmedSnapshot`, `TestAutomationsCLI_ShowChangesUnknownWithoutSource`, `TestAutomationsCLI_ShowChangesUnknownAfterRehash`
- P3 Desktop: `WatchtowerDesktop/Tests/Core/AutomationEditorCenterTests.swift` — `testSaveConfirmsTheValidatedHashOnly`, `testAuto06_ConfirmSheetPassesTheShownHash`, `testAuto06_ConfirmSheetShowsHashedFieldChanges`, `testAuto06_SavePressAfterAnUnflushedEditRechecksInsteadOfSaving`, `testAuto06_SaveDisabledWhileChecking`; `WatchtowerDesktop/Tests/Core/AutomationDraftColumnModelTests.swift` — `testAuto06_EveryHashedFieldVisibleWhereverAPressLands`, `testAuto06_ChangeMarkOnEveryStep`; `WatchtowerDesktop/Tests/Core/AutomationTemplatePanelModelTests.swift` — `testAuto06_TemplateConfirmsOnlyTheShownHash`; `WatchtowerDesktop/Tests/Core/AutomationCardPresentationTests.swift` — `testButtonsForStates`; quick run: `WatchtowerDesktop/Tests/Core/QuickRunCenterTests.swift` — `testDimmedRowOpensInsteadOfRunning`, `testConfirmRecipeRunsOnlyAfterRun`; `WatchtowerDesktop/Tests/Core/TrayRunAutomationMenuTests.swift` — `testDisabledItemsAreNotActionable`

- C2 built-ins (ask #500): `internal/automations/builtin/sync_test.go` — `TestAuto06_ShippedBuiltinRunsWithoutOwnerConfirmation`, `TestAuto06_OwnerCopyNeedsConfirmation`, `TestAuto06_HandEditedCopyStopsTheBuiltIn`, `TestAuto06_CopyEqualToShippedRuns`, `TestBuiltinSync_CopySymlinkIsNeverRead`, `TestBuiltinSync_ShippedUpdateMovesSilently`, `TestBuiltinSync_OverriddenKeepsCopyAndFlagsUpdate`, `TestBuiltinSync_ResetReturnsToShipped`, `TestBuiltinSync_PersonalSlugTwinIsSeparate`, `TestBuiltinSync_PersonalRecipeDeclaringSyncIsAParseError`; `internal/automations/builtin/runner_test.go` — `TestRunner_UnconfirmedCancelsQueuedManual`; `internal/automations/sdk_builtin_test.go` — `TestAuto06_BuiltinInlineRefusesUnconfirmed`; `internal/automations/manifest_test.go` — `TestAuto06_PersonalRecipeCannotDeclareSyncOrBuiltinCapability`; `internal/db/automation_builtins_test.go` — `TestAuto06_ConfirmShippedBuiltinRefusesOtherBytes`, `TestBuiltinAutomation_UpsertNeverSetsOwnerColumns`, `TestGetAutomationBySlug_IgnoresBuiltinTwin`, `TestMarkAutomationsRemovedExcept_LeavesBuiltinRows`; `cmd/builtins_test.go` — `TestBriefingGenerate_RefusedForUnconfirmedCopy`, `TestAutomationsReset_RefusedUnderAgentMarkers`, `TestAutomationsSave_BuiltinRefusedUnderAgentBeforeReading`, `TestAutomationsCLI_BuiltinEnableDisableDeletePointers`; `cmd/builtin_upgrade_test.go` — `TestAuto06_UpgradeConfirmsOnlyCarriedPrompt`, `TestBuiltinUpgrade_RetryRefusedUnderAgentMarkers`

- C3 watch recipes (board #801, spec §6.3/§8): `internal/automations/recipe_test.go` — `TestParseRecipe_SyncTriggerBuiltinOnly`, `TestParseRecipe_PersonalWatchRecipeParses`, `TestParseRecipe_WatchShapeRefusals`, `TestApprovalHash_TrackScanIsHashed`; `internal/automations/manifest_test.go` — `TestCapabilityForPrimitive_TrackScanIsPersonal`; `internal/automations/sdk_builtin_test.go` — `TestExecutor_PollNeverClaimsWatchRecipeRuns`, `TestExecutor_InlineRunsWatchRecipeOnlyWhenEnabled`, `TestAuto06_InlineRefusesUnconfirmedWatchRecipe` (Task 3); `internal/automations/builtin/watchslot_test.go` — `TestWatchSlot_RunsConfirmedEnabledRecipes`, `TestWatchSlot_HandEditedRecipeStopsTheScan`, `TestWatchSlot_DeletedRecipeLeavesTrackUnbound`, `TestWatchSlot_InstructionMirroredToTrack`; `internal/automations/builtin/runner_test.go` — `TestRunSyncInline_OffOrUnconfirmedWritesNothing`; `internal/automations/builtin/capture_test.go` — `TestCapturePrompts_RefusesUnconfirmed` (Task 8); `cmd/tracks_test.go` — `TestTracksCreate_WritesConfirmedWatch`, `TestTracksCreate_UnderAgentLeavesUnconfirmed`, `TestTracksStart_RefusedUnderAgentMarkers`, `TestTracksInstruction_RewritesAndConfirms`, `TestTracksInstruction_RefusesEditedRecipe`, `TestTracksGenerate_RefusedForUnconfirmedCopy`, `TestTracksScan_BoundUnconfirmedRecipeNeverScanned` (Task 11); `cmd/builtin_upgrade_test.go` — `TestAuto06_UpgradeConfirmsOnlyRenderedWatchRecipes`, `TestCustomTracksUpgrade_DismissedStaysUnbound` (Task 12)

- 2026-11-03 (Inbox builder A, owner preview, ask #445): `cmd/automations_preview_test.go` — `TestAutomationsCLI_PreviewRefusedUnderAgentMarkers`, `TestAutomationsCLI_PreviewNeedsTheDesktopsConfirmation`; `internal/automations/authoring/draft_test.go` — `TestEvaluateDraft_DryRunsAnUnconfirmedRecipe`
- 2026-11-03 (Inbox builder A, reply on a changed card): `cmd/automations_reply_test.go` — `TestAutomationsCLI_ReplyRefusedWhenCardChanged`; `internal/automations/executor_reply_card_test.go` — `TestExecutor_ReplyRunOnChangedCardCancelled`, `TestAuto08_ResumedReplyRunIsCheckedForChangedCard`; `internal/db/automation_outputs_press_blocks_test.go` — `TestPressInboxOutputAction_ContentHash`
- 2026-11-03 (Inbox builder A, `artifacts`): `internal/automations/recipe_test.go` — `TestApprovalHash_ArtifactsIsHashed`; `internal/automations/indexer_test.go` — the `artifacts` case of `TestAuto06_ScheduleBudgetEditNeedsConfirmation`
- 2026-10-21 (Inbox Reply): `internal/automations/indexer_test.go` — `TestApprovalHash_InboxReplyIsHashed`; `internal/automations/sdk_output_card_test.go` — `TestOutput_ReplyActionNeedsInboxReply`; `cmd/automations_reply_test.go` — `TestAutomationsCLI_ReplyRefusedWhenNotRunnableOrNoCapability`; `internal/automations/executor_test.go` — `TestExecutor_ReplyRunWithoutCapabilityFails`

**Locked since:** 2026-10-14

## AUTO-07 — The script sees the world only through the SDK

**Status:** Enforced

**Observable:** One fresh goja runtime per run. No `require`, `console`,
filesystem, network, timers or promises: `async`/`await`/`Promise`/
`setTimeout`/`setInterval` are refused before the run ("the script API is
synchronous"), and so is a BigInt literal ("BigInt is not available in
automations"; `BigInt`, the BigInt typed arrays and DataView's BigInt
accessors are absent, ask #331); `eval`, `Function` and every function prototype's
`.constructor` are unavailable (no code from strings); a script that breaks
out of its wrapper function is a parse error. SDK results reach the script as
plain JSON values (never a Go object), and no SDK result carries a token, a
secret file's content, an OAuth grant or a config value.

**Why locked:** The manifest (AUTO-01) bounds only what the SDK can do; a
runtime that also offered I/O, timers or a code-from-string escape would put
the script outside it.

**Test guards:**
- `internal/automations/sandbox_test.go` — `TestAuto07_NoRequireFsNetTimers`, `TestRecipe_AsyncScriptRefused`, `TestSandbox_PreParseRefusesAsync`
- `internal/automations/sandbox_bombs_test.go` — `TestSandbox_BigIntNotAvailable` (ask #331)
- `internal/automations/sandbox_hardening_test.go` — `TestAuto07_NoCodeFromStrings`, `TestSandbox_WrapperBreakoutRefused`, `TestSandbox_SDKResultsArePlainJSValues`
- P6: `cmd/automations_agent_test.go` — `TestAgent_CLIChildEnvHasRunMarkerAndNoSecrets` (an `agent()` CLI child gets only PATH, HOME, LANG, USER, the run marker and, when the daemon has them set, the proxy variables (`HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY`/`ALL_PROXY` and lowercase forms), `NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`, `SSL_CERT_DIR` and `TMPDIR` (ask #185), plus a scrubbed `CODEX_HOME` on codex; no API key, token, secret or Quick Connection reaches it); `cmd/mcp_automation_test.go` — `TestAgentMCPServer_RefusesWithoutMatchingMarkerOrRunningRun`, `TestAgentMCPServer_RefusedInsideATerminalSession` (refused with `WATCHTOWER_TERMINAL_SESSION_ID` set)

**Locked since:** 2026-10-14

## AUTO-08 — Every run is bounded and ends

**Status:** Enforced

**Observable:** Active time ≤ `budget.minutes` (time spent waiting is
excluded), tokens ≤ `budget.tokens` (fresh input + output per model call,
on every provider and on both the direct and the routed path; cache reads
and cache writes are not debited, ask #488 — an OpenAI-compatible provider
reports no cache split, so its `prompt_tokens` is debited whole; a call
without provider usage debits `ceil(len/4)` and marks the run estimated), and
waits ≤ `pause_timeout_hours` (→ `expired`). There is no token cap across runs
(ask #294): what other runs spent never stops a run. The deadline, budget and
cancel interrupts cannot be caught by the script's `catch`. A script stuck in
a native builtin past `AbandonGrace` (2 s) after an interrupt is abandoned:
its run ends, and its automation is disabled ("runaway script — check and
re-enable"). Deep or huge data cannot end the daemon process through the
builtins the sandbox caps (the Hardening list in `docs/features/automations.md`:
nesting deeper than 1000 in `JSON.parse`, `JSON.stringify` and `flat`, a bound
name past 10 000 characters, and one capped call past 16 Mi characters or
elements): each throws a
`RangeError` the script can catch, and nothing is disabled for it. A run
whose live heap grows past `RunHeapBudget` (1 GiB over its baseline; not
read while it waits, re-based when it resumes or another run starts or ends,
by at most one budget in all, so never more than 2 GiB past its start)
ends with "the automation used too much memory", failed, also without a
disable; it is stopped within about one 10 ms poll of its live heap passing
that limit (a GC is forced when the heap's objects pass it first), plus one
native step still running.
Every run reaches exactly one terminal status, including after a
daemon restart: on start the executor ends every `running` run, and every
`waiting` run that cannot be resumed, `failed`/`interrupted` — except a live
CLI dry run, which is swept only past its deadline plus one minute. A
resumable waiting run continues at its wait (board #795, ask #464): a live
run whose replay log (`automation_run_replay`) holds every completed call,
waiting in its last step — the only open one — whose automation is still
runnable and confirmed at the run's `recipe_hash`, and not flagged
`not_resumable` (a result past 1 MiB, a log past 16 MiB). Its script is
re-executed from its `recipe_snapshot`; every completed call is answered
from the log (no backend call, no new step), the waiting call re-enters the
same ask, action or session wait (`pause_timeout_hours` still counts from
that wait's start), `Date.now()`/`new Date()` and `Math.random` give back
the recorded values, and the meter starts from the tokens and active time
already spent. A call that differs from its record, or a script that ends
before its waiting call, ends the run `failed`/`script` ("the recipe ran
differently after the restart (step N); it was not resumed") with nothing
executed. A stop mid-run (inside or between calls) ends it
`failed`/`interrupted`; a stop while a resumable run waits leaves it
`waiting` with its ask, action or session untouched.
Ending a run closes its still-open steps in the same transaction.
A finish the database refuses is retried three times, then the run is ended
`failed`/`backend` without its commit, so it never holds its slots until the
next restart (board #562). A run makes at most 2000 SDK calls (the call past
it is an error step, then the run ends `failed`/`script`, uncatchably), files
at most 50 buffered outputs and starts at most 10 sessions with `session()`
(a refused or invalid call does not count; each call past either cap is a
catchable `ValidationError`). A finish without a commit keeps its own
status and error; a deterministic refusal (`db.ErrInvalidRunFinish`) is not
retried, nor is any finish once the daemon is stopping.
Built-in runs (`origin = 'builtin'`) are swept apart: the executor's start
sweep leaves them, and the daemon ends its own interrupted built-in runs at
start, before its first slot (`db.MarkInterruptedBuiltinRuns`); the
guarantee — exactly one terminal status after a restart — is unchanged.
The daemon's sweep is retried before each slot until it succeeds, so a
built-in run a previous daemon or a dead CLI left never blocks its next
slot run; the stale-run guard for a killed CLI's run is under AUTO-09. A
CLI inline built-in run (a `running` `manual` run, `briefing generate`) is
swept only past its deadline, like a live CLI dry run; a sync run and a
waiting run are swept at once. A runaway-disabled built-in stays off until
the owner turns it on: the slot skips it (`disabled`) and cancels its queued
Run Now, Run Now and `automations run` refuse it, the built-in sync's
on/off mirror (`db.SetBuiltinEnabled`) never turns a row with a
`disabled_reason` on, and only the owner's turn-on (`features enable` of one
of its features — the card's Turn On —, owner-only under AI-agent markers)
clears it (`db.ResumeBuiltin`).
A run is also bounded by the read budget (READ-01 in
`docs/inventory/agent-actions.md`, key `run:<id>`; approved 2026-10-25, ask
#567): every company-data `tool()` read and every `mcp()` call counts as one
call, and reaching the budget is a catchable `ValidationError` on that call,
not an interrupt — the run goes on (a result over the per-response cap is a
catchable `ResultTooLarge`). An `agent()` CLI child keeps its own counter
under the same key, so a run can read its own budget plus one per `agent()`
call; the audit log ties them to one run id.
An `agent()` call stops at 12 model turns (model responses) on every
transport (asks #507 and #514, decision A with the unit of N4): claude by
`--max-turns 12`, runtime B by `agentloop`'s `MaxIterations` (12), codex by
counting the model responses its run's rollout records (one `token_count`
with usage per response, or the earlier `token_usage_record` where codex
writes it; N5, ask #522) — the run is not `--ephemeral` and its rollout
lives only in the per-run `CODEX_HOME`, removed with it — with the stream
rule of the design's §3.4 as the logged fallback when the rollout cannot be
read or records no response while the stream shows a finished one (during the run once a model item follows a tool result with no marker recorded at all, at the end once the stream saw any turn; a long first response of serial calls is no drift). Where codex writes `token_usage_record`, those records decide (a repeated `token_count` does not count). Parallel tool calls of one response are one turn. The response past
the cap ends the call with a `budget` failure ("stopped after 12 model
turns"; codex kills the child's process group), never a success text. The
token meaning is unchanged (ask #488).

**Why locked:** An automation runs unattended; a run that never ends holds a
concurrency slot forever, and one that never stops spending burns the owner's
model quota.

**Test guards:**
- `internal/automations/sandbox_test.go` — `TestAuto08_InterruptOnTimeout`, `TestSandbox_InterruptIsNotCatchable`
- `internal/automations/sandbox_hardening_test.go` — `TestSandbox_CatastrophicRegexEndsWithinDeadline`, `TestSandbox_StuckNativeIsAbandonedAfterGrace`
- `internal/automations/sandbox_bombs_test.go` — `TestSandbox_NativeBombsEndTheRunNotTheProcess` (each bomb of security review #5 runs in the test process: Go-stack recursion in `JSON.parse`/reviver/`flat`, unbounded `replace`/`replaceAll`/`@@replace`/`JSON.stringify`/`toLocaleString`/`flat`/`flatMap` results, `bind` chains)
- `internal/automations/executor_test.go` — `TestAuto08_InterruptOnBudget`, `TestAuto08_CatchAllLoopStillEndsOnBudget`, `TestAuto08_NoDailyCapAcrossRuns`, `TestAuto08_RestartMarksInterrupted`, `TestBudget_EstimatesTokensWhenUsageMissing`, `TestWaiter_PauseTimeoutExpires`, `TestExecutor_DaemonStopMidRunEndsInterrupted`, `TestExecutor_AbandonedRunDisablesAutomation`, `TestExecutor_SweepsStaleDryRuns`, `TestExecutor_StartSparesLiveCLIDryRun`
- `internal/automations/dryrun_memory_test.go` — `TestDryRunInMemory_BudgetBound`
- P6 (`agent()`): `internal/automations/sdk_agent_test.go` — `TestAgent_BudgetCarvedFromRun`, `TestAgent_CarvedDeadlineThrowsCatchableBudgetExceeded` (a spent carved minutes deadline throws a catchable `BudgetExceeded`; the run's own deadline stays uncatchable), `TestAgent_ResultUsageDebitedOnce`; `cmd/automations_agent_test.go` — `TestAgent_RunBudgetCrossedInterruptsRun`, `TestAgent_LocalBudgetSpentThrowsCatchable`, `TestAgent_IterationsCapped12` (runtime B fails with `budget` at the cap since 2026-11-06), `TestAgent_CLIUsageDebitedOrEstimated`, `TestAgent_CancelKillsCLIChild` (the whole process group dies); `internal/ai/client_child_test.go` — `TestCLIAgent_SIGINTIgnoringGroupKilledWithinGrace` (`ai.GroupKillGrace` = 1 s, inside the 2 s `AbandonGrace`)
- `internal/db/automation_runs_test.go` — `TestAuto08_RestartMarksInterrupted`, `TestAuto08_RestartSparesLiveDryRun`, `TestRunEnd_ClosesOpenSteps`
- `internal/automations/replay_test.go` — `TestAuto08_ResumeAtAskWait`, `TestAuto08_ResumeAtApprovalWait`, `TestAuto08_ResumeAtSessionWait`, `TestAuto08_DivergenceEndsTheRunWithoutExecuting`, `TestAuto08_ChangedRecipeIsNotResumed`, `TestAuto08_LargeResultMakesTheRunNotResumable`, `TestAuto08_TimeAndRandomReplay`, `TestAuto08_ResumedTokensNotDoubleCounted`, `TestAuto08_ResumedWaitKeepsItsPauseTimeout`, `TestAuto08_StopWhileRunningStillInterrupts`, `TestAuto08_ResumeAfterAgent`, `TestAuto08_ResumeAfterDefaultAgentChanged`, `TestAuto08_StopDuringReplayReturnsToWaiting`, `TestAuto08_DeadlineDuringReplayKeepsItsEnd`, `TestAuto08_ClockReadOverflowMakesTheRunNotResumable`, `TestAuto08_KeptRunChangedBeforeItsClaimIsNotResumed`; `internal/automations/replay_internal_test.go` — `TestAuto08_ReplayLogCapCountsTheStoredLog` (board #795: resume after a restart; the ask test also pins AUTO-11 — one step per call across both daemon lives — and AUTO-04 — the replayed `state.set`/`output.inbox` are committed once, only with the success)
- `internal/db/automation_run_replay_test.go` — `TestAuto08_RestartKeepsResumableWaitingRun`, `TestAuto08_ReplayLogDeletedOnFinish` (board #795)
- C2 built-ins: `internal/db/automation_builtins_test.go` — `TestMarkInterrupted_BuiltinRunsSweptApart`, `TestMarkInterruptedBuiltinRuns_LiveManualRunSurvives` (a CLI inline run is swept only past its deadline), `TestSetBuiltinEnabled_NeverTurnsOnARunawayStop`; `internal/automations/builtin/runner_test.go` — `TestRunner_RunawayStoppedBuiltinStaysOff`; `cmd/builtins_test.go` — `TestBuiltin_RunawayStopStaysUntilTheOwnerTurnsItOn`
- `internal/automations/run_limits_test.go` — `TestAuto08_StepCapEndsTheRun`, `TestAuto08_FinishFailureRetries`, `TestAuto08_FinishFailureEndsTheRunFailed`, `TestAuto08_FinishFailureWithoutCommitKeepsItsEnd`, `TestAuto08_FinishSkipsRetriesWhenStopping`, `TestAuto08_FinishDoesNotRetryAnInvalidFinish`, `TestOutputs_CapPerRun`, `TestSession_CapPerRun` (board #562); `internal/automations/workbench_e2e_test.go` — `TestPRReviewRounds_MorePRsThanTheSessionCap`
- C2 built-ins (more): `internal/daemon/morning_brief_test.go` — `TestMorningBrief_InterruptedRunDoesNotBlockNextCycle`; `internal/automations/sdk_builtin_test.go` — `TestBuiltinSDK_UsageCountsAgainstBudget` (a primitive's reported usage is debited from the run's budget)
- `internal/automations/sdk_readlimit_test.go` — `TestAuto08_ReadLimitIsCatchable`, `TestAuto08_MCPCountsAgainstRunBudget`, `TestAuto08_ToolResultTooLargeName`, `TestAuto08_MCPLineOutcomes`, `TestAuto08_MCPOverTheByteCapIsDropped` (board #606: the read budget bounds a run)
- `internal/automations/sdk_output_card_test.go` — `TestAuto08_ResumeRebuildsInboxCard` (2026-10-21: a resumed run's replayed `output.inbox` rebuilds its card with the link and actions)
- Turn cap (2026-11-06, asks #507, #514, #522): `cmd/automations_agent_test.go` — `TestAuto08_CodexAgentStopsAtTheSameCap`, `TestCodexAgent_StopsAtCapFromRollout`, `TestCodexAgent_TempHomeRemovedAfterRun`; `internal/codex/turncap_test.go` — `TestCodexClient_StopsWhenTurnNPlus1Starts`, `TestCodexClient_RolloutStopsWhenTurnNPlus1Starts`, `TestTurnCounter_RolloutTokenCountIsOneTurnPerResponse`, `TestTurnCounter_UnreadableRolloutFallsBackToStream`, `TestTurnCounter_RolloutWithoutRecordsFallsBackToStream`, `TestTurnCounter_ParallelCallsAreOneTurn`, `TestTurnCounter_IdLessToolsPairInOrder`, `TestCodexClient_OwnFailureIsNotRelabelledBudget`, `TestRolloutTurns_RecordsWinOverRepeatedTokenCounts`, `TestTurnCounter_TokenCountAfterSequentialToolsKeepsTheRollout`, `TestCodexClient_UsageAfterTheCapStillCounts`, `TestCodexClient_RetryNoticeDoesNotHideTheCap`; `internal/agentloop/loop_test.go` — `TestAgentloop_CapIsBudgetFailure`; the contract suite's `turn-cap-*` cells (`internal/transporttest`)
- `internal/automations/budget_cache_test.go` — `TestLLMBudgetDebitsUncachedInputOnEveryProvider`, `TestAuto08_DebitIsFreshPlusOutputOnEveryProvider` (2026-11-06, ask #514: claude, codex and runtime B shapes of the one `llmusage.Tokens` block, direct and routed); `cmd/automations_agent_test.go` — `TestAgent_BudgetDebitsUncachedInputOnEveryProvider` (2026-11-05, ask #488: `llm()` and `agent()` debit fresh input + output on claude and codex, direct and routed)

**Locked since:** 2026-10-14

## AUTO-09 — Triggers only queue

**Status:** Enforced (P1: scheduler and CLI `run`; P4: the event bus). The
Desktop buttons (P3's Run now, P5's header buttons) add guards without a
status change.

**Observable:** The scheduler, the event bus, CLI `run` and the Desktop
buttons only insert `queued` rows (`db.EnqueueAutomationRun`, the only way to
create a run; a second trigger of the same kind while one is queued is
coalesced onto it, except an Inbox Reply press (`trigger='reply'`), which is
never coalesced: one press is one run); only the daemon's executor runs them. The one exception
is `automations dry-run`, which executes its own `trigger='dry_run'` row in
the CLI process and writes nothing outside its journal; the daemon never
picks up a dry-run row. The automation wake is `SIGUSR2`; it never starts a
sync cycle. The event bus's `Flush` only inserts `queued` rows (one per
automation per cycle) and merges into a still-queued event run; event runs
carry ids, labels, enums and counts only. A Reply press (`automations reply`,
2026-10-21, ask #475) inserts exactly one `queued` `trigger='reply'` row, in the
transaction that records the press on the output, and wakes the daemon. It
does not go through the event bus; its `event_json` is `{"reply": {output_id,
action, value, data, card}}` built from the stored output, never from the
caller.
Built-ins (C2, plan 2026-10-22 Task 7, owner-approved in ask #502):
`automations run <id>` on a built-in only queues a `manual` row and asks the
daemon for a sync (`signalSyncNow`); the daemon's slot executor runs it at the
built-in's slot (`at_next_sync`). The second exception: `briefing generate`
and `day-plan generate` run the Morning brief's confirmed recipe (the shipped
text or the owner's confirmed copy) inline in the CLI process as one
`manual` run with its input (`builtin.Runner.RunNow`, the brief's or the
plan's primitive only), refused while another run of it is active or a Run
Now with other input is queued (a queued Run Now with the same input is
coalesced and run by this call). A run such a CLI left running when it was killed is ended by
the stale-run guard (`db.MarkStaleBuiltinRuns`, before each slot and Run Now):
only a `running` built-in run past `started_at` + budget + 1 minute that never
waited (no waiting status, no resume pending, no step that waited) — a run
that waited or resumed is never ended by it. So a CLI run killed after any
wait is not ended by the guard: it holds the built-in (Morning brief) until the
daemon's start sweep (`db.MarkInterruptedBuiltinRuns`). The main executor's poll
never claims, cancels or resumes a slot automation's run (`RunsAtSlot`: its
trigger is `sync` — a built-in at its slot or a watch recipe); only the slot
executor and the CLI's `RunNow` execute them.

**Why locked:** One executor in one process is what makes concurrency
(AUTO-05), budgets (AUTO-08) and restarts (AUTO-08) hold; a trigger that ran
a script inline would escape all three.

**Test guards:**
- `internal/automations/scheduler_test.go` — `TestAuto09_SchedulerOnlyQueues`
- `cmd/automations_test.go` — `TestAuto09_RunCommandOnlyQueues`
- `internal/db/automation_runs_test.go` — `TestRun_CoalescesSecondTrigger`, `TestNextQueued_SkipsDryRun`, `TestRun_ReplyIsNeverCoalesced` (2026-10-21)
- `cmd/automations_reply_test.go` — `TestAuto09_ReplyCommandOnlyQueues` (2026-10-21)
- `internal/db/automation_outputs_press_test.go` — `TestPressInboxOutputAction_OnePressOneRun` (2026-10-21)
- `WatchtowerDesktop/Tests/Core/InboxReplyPressTests.swift` — `testAuto09_ReplyPressOnlyQueues` (2026-10-21)
- `internal/daemon/automation_wake_test.go` — `TestDaemon_AutomationWakeSignalDoesNotStartSync`
- `WatchtowerDesktop/Tests/Core/WorkbenchHeaderAutomationButtonsTests.swift` — `testAuto09_HeaderButtonOnlyQueues` (a workbench header button's click is exactly `automations run <id> --json`; Swift writes no run)
- `internal/automations/bus_test.go` — `TestAuto09_FlushOnlyQueues`, `TestBus_OneRunPerAutomationPerCycle` (P4)
- `internal/automations/events_test.go` — `TestBus_EventsCarryNoContent` (P4)
- The approval trigger (Inbox builder B, 2026-11-06): `internal/automations/builtin/approvals_test.go` — `TestApprovalFire_QueuesOneEventRunAndWakes`, `TestApprovalFire_SecondFireMergesIntoTheQueuedRun`, `TestApprovalFire_101RefsCapAt100AndTruncated`, `TestApprovalFire_NotRunnableQueuesNothing`, `TestSweepApprovals`; `cmd/inbox_approvals_test.go` — `TestInboxApprovalsChanged_QueuesWithoutADaemon`
- C2 built-ins: `cmd/builtins_test.go` — `TestAuto09_BuiltinRunNowOnlyQueues`, `TestBriefingGenerate_RefusedWhileSlotRuns`; `internal/db/automation_builtins_test.go` — `TestMarkStaleBuiltinRuns_EndsOnlyBuiltinRunsPastDeadline`, `TestMarkStaleBuiltinRuns_NeverEndsARunThatWaited`; `internal/automations/builtin/runner_test.go` — `TestRunner_StaleRunOfAKilledCLIIsEnded`, `TestRunner_RunNowWithAnotherInputQueuedIsNotClaimed`, `TestRunner_RunNowWhileActiveCancelsItsRun`, `TestRunner_QueuedManualRunsAtSlotWithoutGate`; `internal/automations/sdk_builtin_test.go` — `TestExecutor_PollNeverClaimsBuiltinRuns`, `TestExecutor_PollNeverResumesBuiltinRuns`; `cmd/builtins_test.go` — `TestAutomationsRun_BuiltinWithoutRunNowRefused`, `TestAutomationsRun_BuiltinRerunOfRefused`, `TestBriefingGenerate_QueuedRunAndBrokenCopyRefusals`

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
first index, an enable, a confirm that changes the confirmed hash and a rescan
that makes the row runnable again all restart the schedule from now. A clock stepped back waits for the clock to
pass `last_scheduled_for` (no duplicate); one more than a day behind it
restarts from now.

**Why locked:** A Mac that slept over two morning reports must produce one
report, not two and not zero; a restart must not produce a third.

**Test guards:**
- `internal/automations/scheduler_test.go` — `TestAuto10_SleepAcrossTwoDueTimesRunsOnceCatchUp`, `TestAuto10_SkipPolicyRunsNone`, `TestAuto10_RestartDoesNotRepeatCatchUp`, `TestScheduler_OnTimeWithinGrace`, `TestScheduler_NewAndReenabledDoNotCatchUp`, `TestScheduler_ClockBackwardsNoDuplicate`, `TestScheduler_DSTTransition`, `TestScheduler_DSTSleepOverGapCatchesUpOnce`, `TestScheduler_ConcurrentConfirmSkipsRow`
- `internal/db/automation_runs_test.go` — `TestEnqueue_AdvancesScheduleAtomically`, `TestEnqueue_ScheduleCompareAndSet`
- `internal/db/automations_test.go` — `TestAutomationIndex_EnableSetsLastScheduledForNow`, `TestAutomationIndex_ConfirmSetsLastScheduledForNow`
- `internal/automations/indexer_test.go` — `TestRescan_FirstIndexSetsLastScheduledForNow`, `TestRescan_RunnableAgainRestartsScheduleNow`

**Locked since:** 2026-10-14

## AUTO-11 — Complete journal

**Status:** Enforced

**Observable:** Every SDK call, denied ones included, has exactly one step row
(`automation_run_steps`, dense `seq` per run) with its status, tokens and
duration; `args_json` and `result_summary` are clipped to 4 KiB. A step whose
result cannot be encoded is re-closed as an error, never left `ok`. `log` is
capped at 200 ok steps plus one cap-error step per run, even when getters log
while their arguments are converted. A run's SDK calls are capped at 2000
steps plus one cap-error step, after which the run ends (AUTO-08), so no call
goes unjournaled.

**Why locked:** The journal is the owner's only view of what an unattended
script did; a call missing from it is an action nobody can audit.

**Test guards:**
- `internal/automations/sdk_test.go` — `TestAuto11_EveryCallHasOneStep`, `TestLog_Capped`, `TestLog_CapHoldsAgainstNestedGetterLogs`
- `internal/automations/sandbox_hardening_test.go` — `TestEnvCall_EncodingFailureReclosesStepAsError`
- `internal/db/automation_runs_test.go` — `TestSteps_SeqIsDenseAndOrdered`
- P6: `internal/automations/sdk_mcp_test.go` — `TestMCPModule_OneStepPerCall` (an `mcp()` call is one step, denied or not); `agent()` is one step too — the inner tool calls of its loop are summarised in that step's result, not journaled apart (`internal/automations/sdk_agent_test.go` `TestAgent_RequestStepAndActions`)

**Locked since:** 2026-10-14

## AUTO-12 — Dry run writes nothing outside its journal

**Status:** Enforced (P1: no `agent_actions` row, no output, no state
change; P5: no `shell()` process, no session, no ask; ask #326: a draft calls
no Quick Connection)

**Observable:** A dry run makes no `agent_actions` row, no output, no state
change, starts no session and runs no `shell()`: `output.*` (`output.remove`
included: it removes nothing) and `state.set`
steps record `status='dry_run'` and nothing is committed; `llm` and read
tools run for real and their tokens count on the run. The in-memory dry run (`DryRunInMemory`, P3's `draft_automation`)
writes no row of any table, not even a run row, and does not execute
`agent()` (its step closes `dry_run` with a note, no child, no tokens) or
call a Quick Connection through `mcp()`: after the manifest check (a tool the
draft does not declare is still `PermissionDenied`) the first `mcp()` call
closes its step `dry_run` with a note and ends the draft with status
`stopped` (`automations.DryRunStopped`, not a failure; the steps before it
are kept) — the server is never reached, because a draft's script is
chat-written and a read tool's arguments still carry data out (ask #326).
`automations.Env.InMemoryDraft` is the one test for "this is a draft" that
`agent()` and `mcp()` share. A dry run of a saved recipe (the card's **Dry run**) calls `mcp()` for
real, QC-02 reads only. The
editor's draft cache (`<workspace>/automation-drafts/<conversation id>.jsonl`,
P3) is a UI cache of the tool's own result written by `draft_automation`
itself, not by the script, and no database row. The owner's preview
(`automations preview --stdin --json`, Inbox builder A, ask #445) is the
same dry run in memory: no row of any table, no draft-cache entry (its
database handle is `query_only`), `output.remove` journaled `dry_run`.

**Why locked:** Dry run is how the owner (and, for a confirmed recipe, the
assistant) checks a recipe before trusting it; a dry run with side effects
would make checking as dangerous as running.

**Test guards:**
- `internal/automations/executor_test.go` — `TestAuto12_DryRunWritesNoActionsOutputsOrState`
- `internal/automations/sdk_tool_write_test.go` — `TestAuto12_DryRunWriteNeverReachesRegistry` (P2: a `tool()` write, `{wait:true}` included)
- `internal/automations/sdk_output_p2_test.go` — `TestOutput_P2KindsDryRun` (P2: `output.briefing`/`target`/`slack` in a dry run commit nothing and propose nothing)
- `internal/automations/dryrun_memory_test.go` — `TestDryRunInMemory_WritesNoRows`
- `internal/automations/sdk_test.go` — `TestOutput_DryRunWritesAreDryRunSteps`
- `internal/automations/sdk_output_blocks_test.go` — `TestOutput_RemoveDryRun`, `TestAuto12_LivingDryRunWritesNothing` (Inbox builder A: a dry-run `output.remove` journals `dry_run`; a living dry run with blocks commits no card and removes nothing)
- P3: `internal/automations/authoring/draft_test.go` — `TestDraftAutomation_WritesNothing` (a draft whose script calls `output.*`, `state.set` and a write tool writes no row); `internal/automations/dryrun_memory_test.go` — `TestDryRunInMemory_AgentIsNotRun`, `TestDryRunInMemory_MCPIsNotCalled` (ask #326: a draft's `mcp()` never reaches the caller and stops the draft cleanly), `TestDryRunInMemory_MCPOutsideManifestIsDenied` (the manifest check precedes the stop)
- P6: `cmd/automations_agent_test.go` — `TestAgent_DryRunRemovesWriteTools` (a dry-run `agent()` is offered no write tool; `mcp()` is real in a saved recipe's dry run, QC-02 reads only, and never called in a draft); `cmd/mcp_automation_test.go` — `TestAgentMCPServer_DryRunMountsNoWrites`
- `internal/automations/sdk_shell_test.go` — `TestShell_DryRunStartsNoProcess` (P5: a dry-run `shell()` returns `{status:"dry_run"}`, journals a `dry_run` step and starts no process)
- `internal/automations/sdk_session_test.go` — `TestSession_DryRunWaitsForNothing` (P5: a dry-run `session()` returns `{status:"dry_run"}` and asks the Desktop for nothing); `internal/automations/sdk_ask_test.go` — `TestAsk_DryRunCreatesNoRow`
- `internal/automations/templates_e2e_test.go` — `TestTemplates_DryRunE2E` (P6: every gallery template — the personal ones and each workbench recipe — installed and dry-run, journals its outputs, state writes, `shell()` and `session()` calls `dry_run` while reads and `llm()` run for real; each recipe's journal is pinned step by step, so an empty journal fails)
- C2: `internal/automations/sdk_builtin_test.go` — `TestAuto12_BuiltinPrimitiveDryRunCallsNothing` (a dry run of a built-in calls no primitive: `brief.compose`/`plan.compose` close their steps `dry_run`)
- `internal/automations/workbench_e2e_test.go` — `TestAuto12_DryRunStartsNoSessionOrShell` (P5: a dry run of each workbench recipe — `pr-review-rounds`, `release`, `deploy-test`, `deploy-stage` — runs no `shell()` command, leaves no waiting session step, no `terminal_sessions`, `owner_asks`, `agent_actions` or output row, and journals its `shell`/`session` steps `dry_run`)

**Locked since:** 2026-10-14

## AUTO-13 — Exact shell commands, workbench only

**Status:** Enforced

**Observable:** `shell(cmd)` runs only a command byte-equal to a `shell:` entry,
only in a workbench automation, in the workbench folder, with the spec §13.2
environment. The checks run in this order, and none of the refusals starts a
process: a non-string or empty `cmd` is a `ValidationError`; a personal
recipe's call is `PermissionDenied` (its manifest cannot hold `shell:` — P1
refuses the entry at parse time); an `AllowShell` miss is `PermissionDenied`
with `needed` = `shell:"<cmd>"` (no trimming, no prefix match, no `&&`
chaining); a dry run returns `{status:"dry_run"}` (AUTO-12); a workbench in a
protected folder is `NotAvailable` with exactly "this workbench is in a
protected folder; use session() or move the folder", decided from the
resolver before the folder is looked at (D9); a missing folder is
`NotAvailable` "the workbench folder is missing"; a folder path whose
folder or any ancestor is a symlink is `NotAvailable` "the workbench folder
path contains a symlink; rebind the workbench to its real folder", decided
by lstats only before any stat or process (`fsutil.NoSymlinkComponents`); a nil `Backends.Shell` is
`NotAvailable`. The command runs as `/bin/sh -c <cmd>` (`NewProcessShellRunner`,
`Backends.Shell` in the daemon and the CLI) in its own process group, with an
environment of exactly `PATH` (the daemon's resolved rich PATH,
`claude.RichPATH`), `HOME`, `LANG`, `USER` from the daemon's (absent ones omitted) and `WATCHTOWER_AUTOMATION_RUN_ID=<run id>` — no token,
no session marker. Its deadline is the run's remaining active time; on the
deadline or the run ending (cancel) the whole group is killed (`SIGKILL`) and
the run ends `timed_out`/`cancelled`; once the shell exits its group is killed
too, so no background child outlives the call. A non-zero exit is a result
(`exit_code`). Each stream keeps its last 256 KiB (`MaxShellStreamBytes`);
oversized output is truncated, never a failure (owner decision ask #272, spec
§20.1 D19): when the serialised result exceeds the 256 KiB SDK result limit
both tails are cut further (each at most half the room after the envelope, a
shorter stream's unused share to the other, UTF-8 boundaries, JSON escaping
counted) until it fits; `truncated: true` marks any cut and the step's
`result_summary` names `exit_code` and the cut streams. `shell()` never throws
`ResultTooLarge`.

**Why locked:** A shell command is the widest power an automation can hold;
anything but exact, owner-read commands in the owner's own repository would
turn a recipe into arbitrary code execution.

**Test guards:**
- `internal/automations/sdk_shell_test.go` — `TestAuto13_ShellExactCommandInWorkbenchFolder`, `TestAuto13_ShellRefusedInPersonalRecipe`, `TestShell_RefusedInProtectedFolder`, `TestShell_RefusedWhenTheFolderPathHasALink`, `TestShell_NotAvailable`, `TestShell_ValidationError`, `TestShell_EnvHasRunMarkerAndNoSecrets`, `TestShell_KillsProcessGroupOnInterrupt`, `TestShell_TimeoutIsRemainingActiveBudget`, `TestShell_OutputTailCappedAt256KiB`, `TestShell_OversizedOutputTruncatedNeverFails`, `TestShell_NonZeroExitIsAResult`, `TestShell_DryRunStartsNoProcess`
- `internal/automations/manifest_test.go` — `TestManifest_PersonalRefusesShellSessionAsk`, `TestManifest_ShellExactOnly` (P1)
- `cmd/automations_agent_test.go` — `TestAutomationBackends_WireMCPAndAgent` (`Backends.Shell` and `Backends.Workbench` wired)
- Inbox builder A (ask #445): `cmd/automations_preview_test.go` — `TestAutomationsCLI_PreviewWritesNoRows` (every table's row count unchanged, `llm()` faked); `internal/automations/sdk_output_blocks_test.go` — `TestOutput_RemoveDryRun`

**Locked since:** 2026-10-14

**Amendment to AUTO-13 and the `mcp()` path (2026-10-25, #608):** `automations.CheckManifestPolicy` refuses a recipe whose `shell:` entries the organization's `AllowAutomationShell = false` forbids, or whose `mcp:` connection is outside `AllowedQuickConnections`, at validate, save (CLI and `save_automation`, again at apply) and confirm — never at indexing, so the recipe stays listed (`policy_blocked` in `show`/`list --json`). At run time `shell()` throws `PolicyError` before the manifest check (dry run included) and `mcp()` / `agent()` refusals throw `PolicyError`; a policy-failed run ends failed and never disables the automation. Guards: `internal/automations/policy_check_test.go`, `cmd/automations_policy_test.go`, `internal/automations/authoring/save_policy_test.go`.

## Changelog

- 2026-11-08 (Inbox builder A Task 16, board #1400, sub-project A complete; asks #961, #445, #451, #486): docs only — the sub-project's summary. Blocks (`internal/automations/blocks`, the shared fixture), `output.inbox` `blocks`/`key`, the `folder` hook, `output.remove`, `artifacts: feed|living`, migration 00182 and the living upsert, the flattened press address with `--content-hash`, the `target` action kind and its Task button, the owner preview CLI and the editor's Look step changed AUTO-02, AUTO-04, AUTO-05, AUTO-06 and AUTO-12 as the per-task lines below record; AGENT-05 is in `agent-actions.md`. Feature note `docs/features/inbox-card-blocks.md`, guide `docs/guide/features/automations-card-look.md`. No contract text changed and no guard touched in this entry.
- 2026-11-06 (Inbox builder B Task 8, board #1400, **covered by ask #961**; spec `2026-11-03-inbox-builder-b-folders-menu-design.md` "Needs approval"): **the built-in `needs-approval`** — `trigger: {event: approval}`, `concurrency: 1`, `artifacts: living`, `outputs: [inbox]`, the one capability `builtin:approvals.list` (AUTO-01: in its manifest), no `llm()`; feature `approval-cards` (config `approval_cards.enabled`, default on), default folder `needs-approval` (route seeded by `builtin.Sync`). It runs on the main executor's poll after the approval trigger's wake (`RunsAtSlot` false), never at a slot. **Read primitives:** `automations.ReadPrimitiveNames` gains `approvals.list` (a tool step outside the meter, called in dry runs too; `builtin.ReadPrimitives` carries it into every executor and dry run). `approvals.list` reads `db.ReadApprovalsView` — the same open clauses, order (created_at, actions before reminders, id) and `MaxOutputsPerRun` cap as the sweep's `ApprovalDriftOf` — and returns the keys of every artifact whose approval is closed or gone, which the recipe removes, so a succeeded run leaves the sweep no drift. **AUTO-04 holds:** a failed read fails the run and leaves every earlier card byte-identical (`TestNeedsApproval_PrimitiveErrorFailsRunKeepsArtifacts`). **AUTO-06 holds:** the shipped bytes are confirmed by `ConfirmShippedBuiltin`; an owner copy needs the owner, and the built-in indexer now checks each entry's own trigger (`builtin.Entry.Trigger`: `sync: <slot>`, or `event: approval` without `where` for an entry with no slot) — any other trigger in the copy is the row's parse error (`TestNeedsApproval_CopyMustKeepTheApprovalTrigger`). `features disable` turns off at once the row of every built-in whose features are now all off, so `Fire` queues nothing before the daemon's next built-in sync (`TestFeaturesDisable_ApprovalCardsTurnsTheBuiltinOffAtOnce`, `TestNeedsApproval_FeatureOffQueuesNothing`). Tests also: `TestApprovalsList_FixtureOpenSet`, `TestApprovalsList_ItemFields`, `TestNeedsApproval_ClosedApprovalLeavesOthersUnchanged`, `TestNeedsApproval_51OpenWritesThe50Oldest`, `TestBuiltinSDK_ApprovalsListIsAReadStep`. No guard relaxed.
- 2026-11-06 (Inbox builder B Task 7, board #1400, **owner approved in ask #961**; spec `2026-11-03-inbox-builder-b-folders-menu-design.md` "The `approval` trigger"): **AUTO-09 holds for a new trigger** — `approval` is an event type (`automations.ApprovalEvent`, no `where` fields, built-in only through `approvalTriggerAllowed`; runs are `trigger='event'`, so no CHECK change). Every approval writer in `internal/db` (`InsertAgentAction`, `InsertInboxButtonProposal`, `TransitionAgentAction`, `DismissAgentAction`, `ApproveAgentActionWithArgs`, `InsertReminder`, `MarkReminderDone`, `SnoozeReminder`) calls the handle's approval hook (`db.SetApprovalHook`) with `action:<id>` / `reminder:<id>` after a statement that changed a row that is or was an open approval (an action inserted pending, a transition from or to pending/failed, a dismiss, an approve with edits, every reminder write), outside any transaction; `Fire` skips an action whose row can never be an approval (`db.ActionCanBeApproval`: a workbench audit row, the inbox surface's one-press `apply_track_action` row — review fix, guards `TestApprovalHook_DirectApplyQueuesNoRun`, `TestApprovalHook_OnePressInboxToolQueuesNoRun`, `TestApprovalHook_InboxTargetButtonQueuesARun` (a card's target button waits for Approve, so it is an approval — STRIP-01 narrowing), `TestApprovalHook_RealApprovalQueuesARun`, `TestApprovalHook_SkipsTransitionsNeverOpen`); the hook is `builtin.Fire`, which **only queues** a `needs-approval` event run (`db.EnqueueAutomationRun`, or `MergeQueuedAutomationRunEvents` into the queued one: ≤ 100 events + `truncated`, the refs in its `cycles`, so a repeated ref is a no-op) and wakes — the daemon's in-process executor (`Daemon.installApprovalHook` at `Run`), elsewhere SIGUSR2 (`installApprovalHook` in `buildToolRegistry`, the one registry builder every approval write passes); a built-in not indexed, not runnable or stopped (AUTO-08) queues nothing; an enqueue or wake failure is logged (`approval hook: <ref>: …`, ids only) and never changes the writer's result. The hidden `inbox approvals changed --ref <kind>:<id>` (the Desktop's call after a reminder write) is the same `Fire`. The daemon's `phaseApprovalSweep` (after `phaseUnsnooze`) only reads (`db.ApprovalDriftOf`, a read-only transaction) and fires once (`ref: sweep`) when an open approval has no artifact written at or after its last change, a reminder came due, or an artifact's approval is closed. AUTO-05 holds (one queued run takes a burst). Guards added (listed under AUTO-09) plus `TestApprovalFire_EnqueueErrorLoggedAndSwallowed`, `TestApprovalFire_ClaimedRunGetsANewOne`, `TestApprovalHook_EveryWriterNotifies` (with a source scan of `internal/db`), `TestApprovalHook_NeverCalledInsideTransaction`, `TestApprovalHook_WakeErrorLogged`, `TestApprovalSweep_ReadErrorLoggedCycleContinues`, `TestDaemon_ApprovalSweepAfterUnsnooze`, `TestRecipe_ApprovalTriggerBuiltinOnly`, `TestRecipe_ApprovalTriggerRefusesWhere`; `TestExecutor_PollClaimsEventBuiltinRuns` gains an approval event run (the non-slot trigger branch). `TestRecipe_TriggerExactlyOne`'s accepted-event loop skips `approval` (it has no where field to sample; its own tests above). No guard relaxed.
- 2026-11-06 (Inbox builder B Task 9, board #1400; spec `2026-11-03-inbox-builder-b-folders-menu-design.md` "Waiting for me"): new built-in **Waiting for me** (`waiting-for-me`, `artifacts: living`, `outputs: [inbox]`, `FeatureIDs: [secretary-inbox]`, default folder the root, Run Now) on a new sync slot `waiting_for_me` (`automations.SyncSlots`, `builtin.SlotWaitingForMe`), run by the daemon's `phaseWaitingForMe` right after `phaseInbox`, due when what it would show changed since its last succeeded run (`builtin.WaitingFingerprint`, kept in daemon memory; Run Now bypasses the gate). Its capability `builtin:attention.waiting` names the first **read primitive** (`automations.ReadPrimitiveNames`): it takes no argument, calls no model, runs as one `tool` step outside the run's meter (a dry run calls it, as it calls a read tool) and fails the call as `PrimitiveFailed` on a read error. **AUTO-01** enforced (the capability is in its manifest); **AUTO-04** enforced (a failed read fails the run and leaves the earlier `waiting` artifact byte-identical: `TestWaitingForMe_PrimitiveErrorFailsRunKeepsArtifact`); **AUTO-06** enforced (its shipped bytes are confirmed by the release like every built-in's). Tests: `TestWaitingForMe_*`, `TestBuiltinSDK_ReadPrimitiveIsAToolStep`, `TestBuiltinSDK_ReadPrimitiveErrorAndDryRun`, `TestPhaseWaitingForMe_*`, `TestWaitingFingerprint`, `TestDaemon_WaitingForMeRunsRightAfterInbox`; no guard relaxed.
- 2026-11-06 (Inbox builder B Task 6 review, board #1400, **covered by ask #961**, spec §5): **AUTO-04 Observable amended** — a same-hash living rewrite also moves the explicit `folder_id` (the last run's choice); the read state is kept, as the Task 6 line below records. Wording only, guarded by `TestInboxFolders_LivingUpsertMovesFolder`; no guard relaxed.
- 2026-11-06 (Inbox builder B Task 6, board #1400, **owner approved in ask #961**): `output.inbox` gains `folder` (the field A reserved; registered by `DefaultModules` through `RegisterInboxField`, `internal/automations/inbox_folder_field.go`): a non-empty string, the slug of an Inbox folder, else `output.inbox(): folder must be a folder name`; the call only buffers it (`db.AutomationOutput.FolderSlug`), and the run's commit resolves it to `automation_outputs.folder_id` inside its own transaction (`resolveOutputFolderTx`), so a folder deleted after the call never fails the commit. A slug no folder takes — never created, deleted mid-run, or Needs approval named by any automation but the needs-approval built-in — leaves `folder_id` NULL (the card follows its route, else the root) and writes one `log` step `folder "<slug>" not found — shown in <route title>` in the same transaction (AUTO-11: a step like any other; never written by a run that did not succeed). A living upsert now rewrites `folder_id` too — the last run's choice wins, also on a same-hash rewrite, which keeps the read state. `folder` is not part of the content hash or `approval_hash` (placement, not content). `DraftOutput` (draft_automation and `automations preview`) gains `folder` and `folder_title` (the folder's title read for the preview only, "" when no folder takes the slug; a draft has no automation, so Needs approval never resolves there) — added keys (`TestAutomationsCLI_PreviewPinnedKeys` key list extended); a dry run writes nothing (AUTO-12). **AUTO-04 holds for `folder_id`:** guard `TestAuto04_FailedRunWritesNoFolder` added, and the AUTO-04 fixture dump (`exFixture.dump`) now includes `folder_id`. A's interim refusal `folder is not available yet` and its test `TestOutput_InboxFolderReserved` (not an inventory guard) are replaced by `TestOutput_InboxFolderFieldRegistered`; the `create-automation` skill teaches `folder`. No guard relaxed.
- 2026-11-06 (Inbox builder B Task 5, board #1400; spec `2026-11-03-inbox-builder-b-folders-menu-design.md`): AUTO-09 wording amended to the spec's predicate (asks #961/#451) — the poll leaves alone a slot automation's run (`RunsAtSlot`: its trigger is `sync`), no longer every built-in's; no guard relaxed. **`RunsAtSlot` narrowed to sync-triggered automations** (`db.Automation.RunsAtSlot` = `TriggerKind == sync`, `slotAutomationSQL` = `a.trigger_kind = 'sync'`, `slotRunSQL` with it): a built-in at its slot and a Personal watch recipe are still slot automations; a built-in with another trigger (the event built-ins B adds) is claimed, run and swept by the main executor like an owner recipe. The C2 guards `TestExecutor_PollNeverClaimsBuiltinRuns` and `TestExecutor_PollNeverResumesBuiltinRuns` (sync built-ins) are unchanged and green. `TestAutomation_RunsAtSlotMatchesSlotSQL` now covers a sync built-in, an event built-in, a watch recipe, an owner event recipe, a manual owner recipe and a workbench row with a sync trigger (now true: the predicate is the trigger alone; no workbench recipe parses with one); `TestAutomation_RunsAtSlotHoldsPersonalSyncRecipes` swaps its manual-built-in case (was true) for an event built-in and an unparsable built-in (false), and its workbench-with-a-sync-trigger case flips to true (the predicate is the trigger alone). The run sweeps (`slotRunSQL`) also count a built-in row with no trigger (an owner copy reindexed to a parse error), so a live inline run keeps AUTO-08's deadline rule; guard added: `TestMarkInterruptedRuns_BuiltinReindexedToParseErrorKeepsLiveInlineRun`. Guard added: `TestExecutor_PollClaimsEventBuiltinRuns`. **The built-in route seed:** `builtin.Entry.DefaultFolder` (card key `default_folder`); `builtin.Sync` seeds a route to a non-root default only when the built-in has none (`db.SeedInboxFolderRoute`, revision bumped on a write), a failure logged and retried at the next sync. Tests: `TestBuiltinIndex_RouteSeededOnceAndOwnerMoveKept`, `TestBuiltinIndex_RootDefaultSeedsNoRoute`, `TestBuiltinIndex_RouteSeedFailureKeepsBuiltin`, `TestRegistry_DefaultFolderExists`, `TestSeedInboxFolderRoute_OnlyWhenNoneAndBumpsRevision`.
- 2026-11-06 (LLM transport independence, plan Task G5, **N6 decided by the owner in ask #516**): **AUTO-11 kept** — `session()` gains a fourth end, `not_watched` (`sessionNotWatched`): a working session the Mac cannot watch (`agent_watch_issue`, migration 00175) ends the wait at once with `{session_id, status: "not_watched", summary: "", reason}`, by default and with no option key (`TestSessionWait_NoNotWatchedOptionKey`). The step is journalled `ok` with that result like every other end, and the run log gets one `log` step with the reason (`TestSessionWait_NotWatchedEndsAtOnceWithReason`); a failure written first ends with `error` (`TestSessionWait_FailureBeforeWatchIssueEndsWithError`). The four shipped templates that wait on a session handle it (`TestTemplates_SessionWaitersHandleNotWatched`); the `create-automation` skill says recipes must. No guard changed.
- 2026-11-06 (transport independence, task A3, spec approved in ask #514): **AUTO-08 unchanged** (ask #488 meaning kept) — every provider now hands the meter one `llmusage.Tokens` block and the meter reads its `Input` (fresh) plus `Output`; claude splits cache reads and writes off, codex its cache reads, runtime B fills `Input` whole. No guard relaxed; the existing usage guards stay green. Guard added: `TestAuto08_DebitIsFreshPlusOutputOnEveryProvider`.
- 2026-11-06 (LLM transport independence, Task G2, **owner approved in asks #507, #514 and #522**): **AUTO-08 amended** — an `agent()` call stops at 12 model turns on every transport: claude `--max-turns`, runtime B `MaxIterations` (which now fails with `budget` at the cap instead of returning "I couldn't complete that within the tool-call limit", L13), codex by the model responses its run's rollout records (N5: the run drops `--ephemeral` and runs in the per-run `CODEX_HOME`, removed after it, rollout included; the stream rule is the logged fallback). Parallel tool calls of one response are one turn (N4). The token meaning is unchanged (ask #488). Strengthening; no guard relaxed: `TestAgent_IterationsCapped12` keeps its 12 model calls and per-call debits and now asserts the `budget` failure (failed run, error step) where it asserted the old success text, as L13 of the approved plan requires. Guards added: `TestAuto08_CodexAgentStopsAtTheSameCap`, `TestCodexAgent_StopsAtCapFromRollout`, `TestCodexAgent_TempHomeRemovedAfterRun`, `TestCodexClient_StopsWhenTurnNPlus1Starts`, `TestCodexClient_RolloutStopsWhenTurnNPlus1Starts`, `TestTurnCounter_RolloutTokenCountIsOneTurnPerResponse`, `TestTurnCounter_UnreadableRolloutFallsBackToStream`, `TestTurnCounter_RolloutWithoutRecordsFallsBackToStream`, `TestTurnCounter_ParallelCallsAreOneTurn`, `TestTurnCounter_IdLessToolsPairInOrder`, `TestCodexClient_OwnFailureIsNotRelabelledBudget`, `TestRolloutTurns_RecordsWinOverRepeatedTokenCounts`, `TestTurnCounter_TokenCountAfterSequentialToolsKeepsTheRollout`, `TestCodexClient_UsageAfterTheCapStillCounts`, `TestCodexClient_RetryNoticeDoesNotHideTheCap`, `TestAgentloop_CapIsBudgetFailure`.
- 2026-11-05 (Inbox builder A Task 12, board #1400, **AUTO-06 amended, owner approved in ask #486**): the editor's draft column is a step picker (What it collects · Look · When it runs), so no step shows every hashed field on its own. A save or confirm press on a step confirms what the step shows plus a **Changed** row pinned above the footer on every step: for an edit with a known diff, every changed field as the Changed box words them (old → new) on Look and When it runs — the box itself is on What it collects; for a new recipe, one never confirmed or an unknown diff, every hashed field (script, permissions, outputs, scope, trigger, missed, budget, concurrency, artifacts) the step does not show with its value (**Also confirms**), under the box's "First confirmation" / unknown-diff line; the scope is named, a workbench by its name; absent when the step shows them all; lines wrap, none is cut. The rule is pure Core (`AutomationDraftColumnModel.confirmationRow(on:)`/`visibleFields(on:)`, `AutomationEditorStep.shownFields`). The footer's AI-step line comes from `validate --json` `adds_llm`. Strengthening, no guard relaxed: `testAuto06_SaveDisabledWhileChecking` and `testAuto06_ConfirmSheetShowsHashedFieldChanges` unchanged. Guards added: `testAuto06_EveryHashedFieldVisibleWhereverAPressLands` (every step × every changed field, all at once, an unknown diff, a new recipe) and `testAuto06_ChangeMarkOnEveryStep` (D26: each changed field's line, or the unknown-diff / first-confirmation line, on every step). Tests added: `testConfirmationRowPerStep`, `testConfirmationRowForANewDraftNamesTheWorkbench`; shot `look-save-changed-row`.
- 2026-11-05 (Inbox builder A Task 11, board #1400): `DraftOutput` (draft_automation and `automations preview`) gains `actions`, the card's own buttons in the form `automation_outputs.actions` stores (`[]` when none), so the Look step previews the card as the Inbox draws it. An added key only; no guard changed. Tests: `TestDraftAutomation_OutputCarriesCardActions`, the preview key pin.
- 2026-11-05 (codex parity, branch `feature/codex-parity`, **owner approved in ask #488**, superseding ask #487): **AUTO-08 amended** — the run's token budget counts fresh input + output per model call on every provider and on both paths (direct and routed through provider fallback); cache reads and cache writes are not debited (owner: accept the fresh-input budget; do not count Claude cache writes). An OpenAI-compatible provider (runtime B, `agentloop`) reads no cache split, so its reported `prompt_tokens` is debited whole (over-, never under-debited). The Observable's "input + output" becomes "fresh input + output". Side effect, approved in the same ask: codex `InputTokens`, and so the stored `input_tokens` of codex rows (digests, people, tracks, briefing, pipeline progress), now hold fresh input only, so codex rows written before this change are not comparable with later ones; the `llm_calls` ledger is unchanged and keeps the full split. The other AUTO-08 guards are unchanged; no guard relaxed. Guards added: `TestLLMBudgetDebitsUncachedInputOnEveryProvider` (`internal/automations`), `TestAgent_BudgetDebitsUncachedInputOnEveryProvider` (`cmd`).
- 2026-11-03 (go hub plan 3 Task 24, spec `docs/superpowers/specs/2026-10-31-go-hub-design.md` §13 "Ported guards", approved with the spec; asks #692, #807): the Swift hub is deleted, and with it `AutomationRunHandler`, `QuickRunCenter.runFromPhone` and the `.phone` quick-run origin; **no guard relaxed**. AUTO-06's phone guards keep their same-meaning Go twins in `internal/hub/actions/handlers/automation_test.go`: `AutomationRunHandlerTests.testAConfirmRecipeRunsOnlyWhenThePhoneConfirmedIt` → `TestAConfirmRecipeRunsOnlyWhenThePhoneConfirmedIt` (unconfirmed: failed `conflict` with the same text and nothing run; confirmed: one run, trigger `button`), `AutomationRunHandlerTests.testARecipeThatCannotRunIsRefusedWithItsReason` → `TestARecipeThatCannotRunIsRefusedWithItsReason` (the three refusals, verbatim, nothing run). Its other rows: `testARunnableRecipeRunsThroughQuickRun`, `testAPhoneWithoutTheStartGrantIsRefused`, `testARecipeOfAnotherWorkbenchOrAPersonalOneIsRefused`, `testARunningRecipeAnswersWithItsRun` and `testARunIsNeverReplayed` keep their names in Go; `testARefusedRunIsFailedWithTheCLIMessage` → `TestARefusedRunIsFailedWithTheWriteError` (Go queues the run itself, no CLI); `testMissingParamsAndAnUnloadedHubAreRefused` → `TestMissingAutomationParamsAreRefused`. The Swift asserts that no sheet came up on the Mac have no Go side: the hub has no sheet. The `QuickRunCenterTests` phone-run cases went with `runFromPhone`.
- 2026-11-03 (Inbox builder A Task 6, board #1400, **AUTO-06/AUTO-12 amended, owner approved in ask #445**): the owner preview `watchtower automations preview --stdin --json [--slug S] [--workbench N] [--builtin ID]` — the editor Look step's **Dry run** — evaluates the text on stdin as `draft_automation` does (`authoring.EvaluateDraft`: validate, widening, `DryRunInMemory` with the draft bounds) and prints its `DraftResult` (draft_automation's keys; `DraftOutput` gains `blocks` (null when none), `key` and `content_hash`). **AUTO-12**: it writes no row of any table and no draft-cache entry (`query_only` handle). **AUTO-06**: owner-only, refused under every agent marker before stdin is read and then run only after the owner's confirmation in the Desktop (AGENT-07); as the owner's press it dry-runs an unconfirmed recipe too, the D16 refusal staying on the chat path. A new dry-run path, no guard relaxed. Guards added: `TestAutomationsCLI_PreviewRefusedUnderAgentMarkers`, `TestAutomationsCLI_PreviewNeedsTheDesktopsConfirmation`, `TestAutomationsCLI_PreviewWritesNoRows` (a real `list_messages` read and `llm()`), `TestEvaluateDraft_DryRunsAnUnconfirmedRecipe`.
- 2026-11-03 (Inbox builder A Task 5, board #1400, **owner approved in asks #961 and #445**): the SDK side of blocks and living artifacts. `output.inbox` takes `blocks` (exclusive with `body`; stored canonical, `body` = its plain text), `key` (required with `artifacts: living`, refused otherwise) and hook-registered fields (`folder` reserved for sub-project B); every inbox card carries `blocks.ContentHash` (an omitted priority hashes as `medium`). `output.remove({key})` (gated by `outputs: [inbox]` and `artifacts: living`) is buffered and committed only with the success (**AUTO-04**), journaled `dry_run` in a dry run (**AUTO-12**); the buffer keeps one operation per key, the later wins. A target action inside a block needs `outputs: [target]` like a card's (**AUTO-02**); the card's own actions count toward the 50-action cap. Strengthening, no guard relaxed. Guards added: `TestOutput_RemoveDryRun`, `TestAuto12_LivingDryRunWritesNothing`, `TestAuto04_LivingRunCommitsUpsertAndRemoval`, `TestOutput_RemoveLaterWins`, `TestOutput_OutputsCapCountsKeptOutputs`, `TestAuto08_ResumeRebuildsLivingBuffer`; `TestOutput_TargetActionNeedsTargetOutput` gains its list-row case.
- 2026-11-03 (board #1400, Inbox builder A, **owner approved in ask #961**): **AUTO-04 extended** — the run's one finish transaction also upserts living Inbox outputs by `(automation_id, output_key)` and deletes the keys `output.remove` buffered (migration 00182: `blocks_json`, `output_key`, `content_hash`, `written_at`, `changed_at`, partial unique index `idx_automation_outputs_key`); only a changed content hash makes a card new again (moves `changed_at`, clears read/done/dismissed/press). A failed, timed-out, over-budget or cancelled run leaves living rows byte-identical, like every other output. Guards added: `TestAuto04_LivingUpsertCommittedOnlyOnSuccess`, `TestAuto04_RemoveCommittedOnlyOnSuccess`. No guard relaxed.
- 2026-11-03 (board #1400, Inbox builder A Task 4, **owner approved in ask #961**): **AUTO-05 extended** — `artifacts: living` requires `concurrency: 1` and `outputs: [inbox]` (parse errors otherwise; one rule function, `serialRunReasons`). **AUTO-06 extended** — `artifacts` is in `approval_hash`, written to the canonical form only when `living`, so feed recipes hash as before (`TestApprovalHash_GoldenCanonicalBytes` unchanged); `ApprovalFields` and `validate --json` `fields` carry `artifacts` so the confirming screen lists it. Strengthening, no guard relaxed. Guards added: `TestAuto05_LivingArtifactsNeedConcurrencyOne`, `TestApprovalHash_ArtifactsIsHashed`, the `artifacts` case of `TestAuto06_ScheduleBudgetEditNeedsConfirmation`.
- 2026-11-03 (Inbox builder A Task 14, board #1400, AUTO-02 as amended in ask #445): the press path lands — `create_target` on the `inbox` surface (never trusted, so always pending until the owner's Approve) with `parent_id` accepted only there; one open proposal per button and one task per proposal (AGENT-05, `docs/inventory/agent-actions.md`). Guards added: `TestAuto02_TargetButtonOnlyProposes`, `TestCreateTarget_ParentIDOnlyOnInbox`.
- 2026-11-03 (board #1400, Inbox builder A Task 7, **owner approved in ask #961**): **AUTO-06 extended** — a Reply press addresses its button by the card's flattened action list (card actions, then block actions in document order); `automations reply --content-hash` refuses a press on a card changed since it was drawn (`ErrOutputChanged`, nothing queued); the reply payload carries `content_hash`, and the executor ends a `reply` run `cancelled`/`cancelled` before its script, on every start, when its card changed or was removed. A payload without the hash runs as before. Strengthening, no guard relaxed (the existing reply guards pass unchanged). Guards added: `TestAutomationsCLI_ReplyRefusedWhenCardChanged`, `TestExecutor_ReplyRunOnChangedCardCancelled`, `TestAuto08_ResumedReplyRunIsCheckedForChangedCard`, `TestPressInboxOutputAction_ContentHash`.
- 2026-11-03 (Inbox builder A Task 2, board #1400, **AUTO-02 amended, owner approved in ask #445**): an Inbox card's actions gain the `target` kind; the card action grammar moves into `internal/automations/blocks` (`blocks.ValidateAction`, shared with block actions); a target action needs `outputs: [target]`. The press path (`create_target` on the `inbox` surface) lands with Task 14. Strengthening, no guard relaxed. Guard added: `TestOutput_TargetActionNeedsTargetOutput`.
- 2026-10-28 (board #1194, **AUTO-06 amended, owner approved in ask #692**): quick run gains a third origin, the iPhone (`QuickRunCenter.runFromPhone` through `AutomationRunHandler`), for workbench recipes only; the not-runnable states refuse as on the Mac, and a `confirm: true` recipe needs the phone's own confirmation, carried as `confirmed: true` and checked by the hub. No guard relaxed (`testDimmedRowOpensInsteadOfRunning`, `testConfirmRecipeRunsOnlyAfterRun` unchanged). Guards added: `AutomationRunHandlerTests.testAConfirmRecipeRunsOnlyWhenThePhoneConfirmedIt`, `testARecipeThatCannotRunIsRefusedWithItsReason`.
- 2026-10-25 (board #606, ask #567): **AUTO-08 amended** — a run is also bounded by the read budget (READ-01, key `run:<id>`, `mcp()` counts as a call); reaching it is a catchable `ValidationError`, not an interrupt; an `agent()` CLI child keeps its own counter under the same key. Strengthening, no guard relaxed. Guards added: `TestAuto08_ReadLimitIsCatchable`, `TestAuto08_MCPCountsAgainstRunBudget`, `TestAuto08_ToolResultTooLargeName`, `TestAuto08_MCPLineOutcomes`.
- 2026-10-23 (board #801, C2 final review fix batch 1): **AUTO-08 strengthened** — a runaway-disabled built-in stays off until the owner turns it on (the slot runner, Run Now and `automations run` check `disabled_reason`; the built-in sync's mirror never turns such a row on; only the owner's `features enable` — the card's Turn On — clears it, and not under AI-agent markers), and a CLI inline built-in run (a running `manual` run) is swept at daemon start only past its deadline, as a live CLI dry run is. No guard relaxed. Guards added: `TestMarkInterruptedBuiltinRuns_LiveManualRunSurvives`, `TestSetBuiltinEnabled_NeverTurnsOnARunawayStop`, `TestRunner_RunawayStoppedBuiltinStaysOff`, `TestBuiltin_RunawayStopStaysUntilTheOwnerTurnsItOn`.
- 2026-10-22 (board #801, plan C3 Task 8, spec §6.3/§8): **AUTO-06 amended** — the one Personal exception to "only built-in recipes declare a `sync` trigger" (a recipe with `track:scan` and `trigger: {sync: custom_tracks}`, Watch for something) and how it runs: only after the owner confirms it, at the `custom_tracks` slot on the slot executor, never in the executor's queue; the owner-only `tracks create|watch|start|instruction` commands and the one-time custom-tracks upgrade confirm only the recipes they render; the watch slot never runs a removed or unconfirmed recipe and `builtin.CapturePrompts` lends only confirmed text. amended (spec §6.3, ask #500); no guard relaxed. Guards added as listed under AUTO-06 ("C3 watch recipes": Tasks 2, 3, 8, 11 and 12).
- 2026-10-22 (board #801, plan C2 Task 8, within ask #500's AUTO-06 amendment): the one-time upgrade step is the fourth `ConfirmAutomation` caller: it confirms only the owner copy it rendered from a customised prompt-store row that was already running. **AUTO-08** notes that built-in runs are swept at daemon start by `db.MarkInterruptedBuiltinRuns`; the guarantee is unchanged. No guard relaxed. Its Retry, `automations upgrade-builtins`, refuses under AI-agent markers like the other CLI paths to `ConfirmAutomation`; the daemon's step runs under them. Guards added: `TestAuto06_UpgradeConfirmsOnlyCarriedPrompt`, `TestBuiltinUpgrade_RetryRefusedUnderAgentMarkers` (AUTO-06); `TestMarkInterrupted_BuiltinRunsSweptApart` listed under AUTO-08.
- 2026-10-22 (board #801, plan C2 approved in ask #502): **AUTO-09 amended** — `automations run` on a built-in only queues a `manual` run for the daemon's next sync slot; `briefing generate` / `day-plan generate` run the Morning brief's confirmed recipe inline in the CLI process as one `manual` run (the second exception after `dry-run`), with the stale-run guard for a killed CLI's run (`db.MarkStaleBuiltinRuns`: running, past budget + 1 minute, never waited). **AUTO-03 extended** — a built-in gets no auto grant. Docs pass (Task 11): AUTO-09 says a queued Run Now refuses the CLI only when its input differs, that a CLI run killed after a wait holds the built-in until the daemon's start sweep, and that the poll never runs a built-in's run; AUTO-08 records the built-ins' own start sweep; existing built-in tests listed as guards (AUTO-06, AUTO-08, AUTO-09). No guard relaxed. Guards added: `TestAuto09_BuiltinRunNowOnlyQueues`, `TestBriefingGenerate_RefusedWhileSlotRuns`, `TestMarkStaleBuiltinRuns_EndsOnlyBuiltinRunsPastDeadline`, `TestMarkStaleBuiltinRuns_NeverEndsARunThatWaited`, `TestRunner_StaleRunOfAKilledCLIIsEnded`, `TestAuto03_BuiltinGetsNoAutoGrant`.
- 2026-10-23 (board #801, plan C3 Tasks 3, 8, 10, 11; consistency with the C2 entries above, **no guard relaxed**): **AUTO-03** unchanged — a watch recipe holds `track:scan`, which admits no registry tool, so no auto grant can apply to it, and the three C3 built-ins get no grants like the Morning brief. **AUTO-08** — the Reactions built-in stopped by a runaway pauses claiming (polling, seeding and `slack.reaction_added` continue and nothing is claimed or lost), and a stopped or unconfirmed copy never writes a run. **AUTO-09** — `automations run <watch id> [--since]` only queues a manual run for the daemon's next slot (`at_next_sync`), the built-ins' Run Now is the same; `tracks generate`, `ideas mine` and `tracks scan <id>` are the owner's explicit commands and run the confirmed recipe inline through `ExecuteBuiltinInline`, which refuses an unconfirmed or disabled one.
- 2026-10-22 (board #801, spec 2026-10-22 §5.2, **AUTO-06 amended, owner approved in ask #500**): shipped built-in bytes run without the owner's confirmation — the built-in indexer confirms a built-in row only while its text is byte-equal to the recipe embedded in the running app (`db.ConfirmShippedBuiltin` refuses any other bytes, an owner row, or a stale hash). The owner's copy `<workspace>/automations/.builtin/<id>.md` is indexed unconfirmed and runs only after the owner confirms it; a hand edit makes it unconfirmed again; a copy that is not a regular file is never read. Only built-in recipes may declare a `sync` trigger or a `builtin:` capability; the Personal scanner never treats a built-in row as a file of its folder (a Personal recipe with a built-in's slug gets a row of its own). A dry run of a built-in calls no primitive (AUTO-12). No guard relaxed. Guards added: as listed under AUTO-06 ("C2 built-ins") and AUTO-12 (`TestAuto12_BuiltinPrimitiveDryRunCallsNothing`).
- 2026-10-21 (Inbox card actions, spec 2026-10-21 §B3–B4, **owner approved in ask #475**): **AUTO-09 amended** — the Reply press is a trigger that only queues, never coalesced (one press, one run), outside the event bus; **AUTO-06 extended** — `inbox:reply` is hashed and checked at write, press and run. Strengthening; no guard relaxed; `TestRun_CoalescesSecondTrigger` and `TestBus_EventsCarryNoContent` unchanged. Guards added: `TestAuto09_ReplyCommandOnlyQueues`, `TestRun_ReplyIsNeverCoalesced`, `TestPressInboxOutputAction_OnePressOneRun`, `testAuto09_ReplyPressOnlyQueues`, `TestApprovalHash_InboxReplyIsHashed`, `TestOutput_ReplyActionNeedsInboxReply`, `TestAutomationsCLI_ReplyRefusedWhenNotRunnableOrNoCapability`, `TestExecutor_ReplyRunWithoutCapabilityFails`, and `TestAuto08_ResumeRebuildsInboxCard` (AUTO-08).
- 2026-10-21 (Automations in the panel, board #405; spec `2026-10-21-automations-panel-and-inbox-design.md` §A, **AUTO-06 amended, owner approved in ask #475**): strengthening, no guard relaxed. The Desktop's confirming screen moves from the confirmation and Save sheets to the Automations panel's draft column, which shows every hashed field of the exact bytes saved and the changes since the confirmed text (`validate --json` gains `changes`/`changes_known`, and `fields`: a column that cannot show them turns every save and confirm button off); a press on changed bytes re-validates instead of saving. A panel save is enabled unless the owner picks **Save Turned Off** (`enable` after the confirmed save; Save Turned Off disables first). A template installs from its panel after `install-template --render` showed its validation; `install-template` stays unconfirmed and disabled (`TestInstallTemplate_InstalledUnconfirmedAndDisabled` unchanged) and the Desktop confirms an installed copy only when its `approval_hash` equals the shown one, then enables it. Quick run on a dimmed row opens the card instead of the sheet (`testDimmedRowOpensInsteadOfRunning` unchanged). Guards whose call sites moved with the sheets keep their names and assertions: `testSaveConfirmsTheValidatedHashOnly` and `testNoAutoOnWithoutACheckedBox` save through `check` + `commit(…, turnOn:)`; `testButtonsForStates` is unchanged (the card's ⋯ shows Turn Off / Turn On from a separate helper). AUTO-03 names the draft column's Keep auto boxes (still unchecked by default, `testAuto03_KeepAutoBoxesUncheckedByDefault`). Guards added: `testAuto06_SavePressAfterAnUnflushedEditRechecksInsteadOfSaving`, `testAuto06_SaveDisabledWhileChecking`, `testAuto06_TemplateConfirmsOnlyTheShownHash`, `TestInstallTemplate_RenderHashMatchesInstall`.
- 2026-10-21 (board #799): the `new-mail-summary` gallery template remembers summed-up messages by id over a two-day lookback window instead of a per-mailbox time cursor (rule 1 of the create-automation skill's "Reliable recipes"), so mail synced after a newer message was summed up is no longer skipped. State `mail = {base, boxes}` with minutes relative to `base`; the done entries are bounded under `MaxStateBytes` by a fair per-mailbox share (a quiet mailbox is never cut by a busy one), a mailbox over its share dropping its oldest whole minutes behind a floor; an older script's `cursors` are re-keyed through the `list_emails` name probe and migrated (mail at or before the cursor marked done, the cursor dropped). Its pinned dry-run journal in `TestTemplates_DryRunE2E` (AUTO-12) gains the second `state.get` (the old `cursors`, read for the migration) — a template change, not a relaxed guard. `TestTemplate_NewMailSummaryKeepsPerAccountCursor` (not an inventory guard) becomes `TestTemplate_NewMailSummaryKeepsPerAccountDone` with message dates relative to now (the window is read against the real clock), asserting the done ids and that a later run still reads the whole window; the `TestTemplates_RunE2E` mail cases assert the done ids where they asserted the cursor, and gain the late-mail, cursor-migration, cursor-by-label, state-budget (fair share) and eviction-floor cases (each floor check, the floor's exclusivity, the name re-keying and the fair share verified to fail the tests when removed). No guard relaxed.

- 2026-10-21 (board #795, **owner decision ask #463/#464**): **AUTO-08 amended — a waiting run survives a daemon restart.** "On start the executor ends every `running`/`waiting` run `failed`/`interrupted`" becomes "every `running` run, and every `waiting` run that cannot be resumed"; a resumable waiting run continues at its wait by deterministic replay of its recorded calls (migration 00146 `automation_run_replay`, `automation_runs.resume_pending`/`not_resumable`/`random_seed`; spec `docs/superpowers/specs/2026-10-21-automation-wait-survives-restart-design.md`). A run running at the stop, a waiting run outside a journaled call, a dry run, a run whose recipe was re-confirmed at another hash or whose log is incomplete still end `failed`/`interrupted` as before. AUTO-11 (a replayed call writes no step) and AUTO-04 (the replay re-buffers state and outputs; they commit only with the success) are unchanged and now also pinned across a resume. The existing guards keep their assertions — `TestAuto08_RestartMarksInterrupted` (db and executor), `TestExecutor_DaemonStopMidRunEndsInterrupted` and `TestWaiter_DaemonStopDuringWaitEndsInterrupted` pass unchanged (their runs have no resumable waiting step). Guards added: `TestAuto08_ResumeAtAskWait`, `TestAuto08_ResumeAtApprovalWait`, `TestAuto08_ResumeAtSessionWait`, `TestAuto08_DivergenceEndsTheRunWithoutExecuting`, `TestAuto08_ChangedRecipeIsNotResumed`, `TestAuto08_LargeResultMakesTheRunNotResumable`, `TestAuto08_TimeAndRandomReplay`, `TestAuto08_ResumedTokensNotDoubleCounted`, `TestAuto08_ResumedWaitKeepsItsPauseTimeout`, `TestAuto08_StopWhileRunningStillInterrupts`, `TestAuto08_ResumeAfterAgent`, `TestAuto08_ResumeAfterDefaultAgentChanged`, `TestAuto08_StopDuringReplayReturnsToWaiting`, `TestAuto08_DeadlineDuringReplayKeepsItsEnd`, `TestAuto08_ClockReadOverflowMakesTheRunNotResumable`, `TestAuto08_KeptRunChangedBeforeItsClaimIsNotResumed`, `TestAuto08_ReplayLogCapCountsTheStoredLog`, `TestAuto08_RestartKeepsResumableWaitingRun`, `TestAuto08_ReplayLogDeletedOnFinish`. No guard relaxed.

- 2026-10-20 (board #788, workbench header redesign): controls moved (header → title row / session strip, header buttons → ⚡ menu); no contract, guard test or status changed.

- 2026-10-18 (Linear tools, board #694): **AUTO-01 gains the `linear` capability** (`linear:read|write@<TEAM>|*`; a strengthening of the grammar, no guard relaxed). Linear reads and the five Linear writes are scoped by the team key; issue tools by the issue's **current** team (a moved issue answers to its new team); a list call without `team` is the absent scope and needs `linear:read@*` or `tool:<name>`. Guards: `TestManifest_LinearCapability`, `TestLinearScope_MovedIssueUsesCurrentTeam`, `TestLinearScope_TeamArgsAndTeamsList`, `TestLinearScope_RowsWithoutTeamKeyAreAbsentScope`, `TestLinearScope_WriteTools`. `list_linear_cycles` is offered on the `automation` surface only (like `list_jira_sprints`).
- 2026-10-18 (board #568, **AGENT-07 amended, owner approved in ask #357**): strengthening, no guard changed. The owner gestures this file lists as refused under an AI-agent marker stay refused there; without a marker they now also need the owner's Confirm in the running Desktop, whose window shows the whole recipe (trigger, permissions, outputs, text), and no Desktop is a refusal. See AGENT-07 in `agent-actions.md`.
- 2026-10-18 (board #562, **owner decision ask #304 q4**; security review A5, tech review E1–E3): strengthening. **AUTO-08:** per-run caps — 2000 SDK calls (`MaxStepsPerRun`; the call past it is an error step and ends the run `failed`/`script`, uncatchably), 50 buffered outputs (`MaxOutputsPerRun`) and 10 sessions started by `session()` (`MaxSessionCalls`; refused or invalid calls do not count), each past its cap a catchable `ValidationError`. The session cap is 10, not the 3 first proposed, because the shipped `pr-review-rounds` template starts one session per changed pull request: it now starts at most 10 per round and moves its `last_round` mark (to the round's start) only after a round that left none, with state `reviewed` holding when each open pull request's review ended, so every pull request still gets one session and a retry after an error or a failed launch; its pinned dry-run journal in `TestTemplates_DryRunE2E` (AUTO-12) gains the second `state.get`/`state.set` — a template change, not a relaxed guard. A refused run finish with a commit is retried 3 times (not after the daemon's ctx ended, not for a deterministic `db.ErrInvalidRunFinish`), then written `failed`/`backend` without its commit, so a busy database no longer leaves a run holding its slots until restart; a finish without a commit keeps its own status and error. **AUTO-04:** a succeeded script whose journal lost a write commits (no repeated writes on the next run) and notes the incomplete journal in the run's error. **AUTO-11:** the step cap adds one cap-error step, like `log`'s. Guard `TestSandbox_InterruptIsNotCatchable`'s external-interrupt case paces its SDK loop (a busy loop after each `echo`, still inside the `try`) so the new step cap does not end it before the interrupt; its assertion (an uncatchable `budget` interrupt) is unchanged. Guards added: `TestAuto08_StepCapEndsTheRun`, `TestAuto08_FinishFailureRetries`, `TestAuto08_FinishFailureEndsTheRunFailed`, `TestAuto08_FinishFailureWithoutCommitKeepsItsEnd`, `TestAuto08_FinishSkipsRetriesWhenStopping`, `TestAuto08_FinishDoesNotRetryAnInvalidFinish`, `TestOutputs_CapPerRun`, `TestSession_CapPerRun`, `TestPRReviewRounds_MorePRsThanTheSessionCap`, `TestPRReviewRounds_CarryOverEdgeCases`, `TestAuto04_JournalErrorAfterSuccessStillCommits`. `TestPRReviewRounds_E2E` (not an inventory guard) now expects `last_round` to stay when a review session ended with an error, since that pull request is retried. No guard relaxed.

- 2026-10-17 (board #561, **owner decision ask #331**): **AUTO-07 narrowed — BigInt is removed from the sandbox.** Its `**` and `<<` operators computed results of any size in one native step (an OOM kill of the daemon no wrapper can prevent). A BigInt literal is refused when the script compiles (an AST walk, so no lexical trick hides one) with "BigInt is not available in automations"; `BigInt`, `BigInt64Array`, `BigUint64Array` and DataView's BigInt accessors are deleted. Guard `TestState_RejectsUnserialisableValues` (AUTO-04) loses its `10n` case, which can no longer run, and instead asserts that `state.set("k", 10n)` is refused by `PreParse` — the guarantee (no BigInt reaches state) is unchanged. Guard added: `TestSandbox_BigIntNotAvailable`.
- 2026-10-17 (board #561, security review #5; owner decision ask #304 q3 — "a clear error instead of a daemon crash"): **AUTO-08 strengthened** — deep or huge data can no longer end the daemon through the capped builtins (goja's `JSON.parse`/`flat` overflowed the Go stack, an unrecoverable fatal error, and several builtins allocated without bound, so the abandon net never ran and the daemon crash-looped). Each limit throws a catchable `RangeError`, like the caps before it; no automation is disabled for it. Guards added: `TestSandbox_NativeBombsEndTheRunNotTheProcess`, `TestSandbox_HeapBudgetStopsTheRun`, `TestSandbox_HeapBudgetSparesSiblingRuns`, `TestSandbox_HeapBudgetSparesAWaitingRun`, `TestSandbox_MemoryStopThenStuckIsAbandoned` (the per-run memory budget), `TestSandbox_HeapBudgetForgivenessIsCapped`, `TestSandbox_ExecCallsAreTimed`, `TestSandbox_ExecRewriteSkipsSuperAndOptionalChains`, `TestSandbox_DeletedExecIsATypeError`. No guard relaxed.
- 2026-10-18 (**owner decision, ask #372**; board #671): **AUTO-10 amended** — "and enabling the `automations` feature" is dropped from the no-catch-up list (the feature switch is gone: Automations are always on), and its guard `TestFastForward_Automations` (FEAT-03, `features.md`) is removed with the hook. No other AUTO contract text changed and no other guard relaxed. An install that had Automations off gets a one-time daemon upgrade step instead: every enabled recipe is paused (`disabled_reason` "Paused by the update: Automations was turned off. Turn it on to run it again.") and queued non-dry runs are cancelled; the owner's re-enable restarts the schedule from now, as AUTO-10 already pins for an enable. The feature-off refusals in `automations run`/`wake` and in `draft_automation`/`save_automation` (R-P3-2) are removed with their tests (`TestAutomationsCLI_FeatureOffRefusesRunAndSkipsWake`, `TestDraftAutomation_FeatureOffRefused`, `TestSaveAutomation_FeatureOffRefused`). Guards added: `cmd/automations_upgrade_test.go`, `TestPauseAutomationsForUpgrade_PausesEnabledAndCancelsQueued`.
- 2026-10-17 (**owner decision, ask #326**; board #557, security review F4): strengthening, no guard relaxed. AUTO-12: `draft_automation`'s in-memory dry run (run id 0) no longer calls a Quick Connection — after the manifest check the first `mcp()` call closes its step `dry_run` with the note "Stopped at mcp(): external calls are not made in a draft; dry-run the saved recipe from its card to see the rest" and ends the draft with status `stopped` (not a failure, earlier steps kept; the Desktop Draft panel shows the note). Closes a no-click exfiltration path: a chat-written draft could pass synced text as a QC-02 read tool's arguments. A saved recipe's card dry run and real runs are unchanged. Guards added: `TestDryRunInMemory_MCPIsNotCalled`, `TestDryRunInMemory_MCPOutsideManifestIsDenied`.
- 2026-10-17 (Automations P4, board #753; spec §8): **the event half of AUTO-09 flips from Planned to Enforced** — the one P4 status flip. Observable gains the event bus: `Flush` (once per sync cycle, cycle id = `syncStart` in RFC 3339 UTC, called right after `phaseExternalSync`) only inserts `queued` rows, one per automation per cycle, and merges into a still-queued event run; event runs carry ids, labels, enums and counts only. Guards added: `TestAuto09_FlushOnlyQueues`, `TestBus_OneRunPerAutomationPerCycle` (`internal/automations/bus_test.go`), `TestBus_EventsCarryNoContent` (`internal/automations/events_test.go`). Module list gains `internal/automations/bus.go`, `internal/automations/eventsrc*.go`, `internal/daemon/automation_events.go`, `internal/db/automation_event_sources.go`. No new AUTO number; no AGENT/STRIP/REACT entry touched (reaction commands are not an event source). No guard relaxed.
- 2026-10-16 (Automations P5 part 2, board #753; spec §12.4, §13.1, §13.3, §13.4, §14.6): P5 part 2 — workbench saves (PROJ-03 amended, ask #272, `docs/inventory/workbench.md`), the Desktop session launch center (`AutomationSessionCenter`), header buttons, automation asks in the Desktop, rescans on page open and on recipe-folder changes. **AUTO-09's Desktop guard for the header buttons is in place** (`testAuto09_HeaderButtonOnlyQueues`, Task 11, listed under AUTO-09); no status flip — the event half stays Planned for P4. Change in words is on for workbench recipes (R-P3-5 lifted for the editor chat too); an automation's closed asks get their own "⚙ Automations" line instead of "Outside the app". No guard relaxed.
- 2026-10-16 — agent() child env adds proxy, CA and TMPDIR variables (owner, ask #185). AUTO-07's guard `TestAgent_CLIChildEnvHasRunMarkerAndNoSecrets` is extended, not relaxed: it still proves no API key, token or `CLAUDECODE` reaches the child. `shell()`'s env is unchanged.
- 2026-10-16 (Automations P3 final review, fix wave 1): AUTO-06 records that the `save_automation` card shows every hashed field and the whole text of a new recipe (J1). Strengthening only; no guard touched.
- 2026-10-16 (Automations P3, board #753 group #353; spec §11, §12, §14.3–§14.5): **the `draft_automation` half of AUTO-06 flips from Planned to Enforced (ask #271)** — the one P3 status flip; every other AUTO entry P3 touches was already Enforced. Strengthening, no guard relaxed. AUTO-06 records `draft_automation`'s refusal (compared within the draft's scope), `save_automation` as the third `ConfirmAutomation` caller (AlwaysAsk, pinned hash and content hash), the Desktop's hash binding (`--confirm-hash` from `validate`, `--expect-content-hash`, the confirmation sheet's shown hash and **Changed** block, D26) and the quick-run pins (a dimmed row never runs; `confirm: true` runs only after **Run**); AUTO-03 records that the Desktop's Save sheet keeps every "Keep auto" box unchecked and that `save_automation` carries no grant over; AUTO-12 records that a draft writes nothing (`TestDraftAutomation_WritesNothing`, also in AGENT-06's chat-mode guard) and does not execute `agent()` (Ruling K). Guards added as listed under AUTO-03, AUTO-06 and AUTO-12. Related: AGENT-04 amended for the `automation_editor` surface (D11) and AGENT-06 extended (`agent-actions.md`); STRIP-01 amended for automation outputs (D10, `reaction-commands.md`). A P1 journal bug was fixed on the way: a generic step's `result_summary` is now its JSON, no longer the base64 of it (`TestDryRunInMemory_StepResultIsJSON`; AUTO-11 unchanged).
- 2026-10-16 (Automations P6 part 2 final-review fixes, board #753): strengthening and one narrowing, no guard relaxed. **AUTO-01 narrowing:** a manifest `@scope` holding `<` or `>` is refused (`checkScopePresence`: an installed template placeholder such as `jira:read@<PROJECT>` must be replaced before the recipe parses; no real account, project or space name carries those characters). **AUTO-12:** `TestTemplates_DryRunE2E` now pins every workbench recipe's dry-run journal too (it formerly checked only the step statuses, so an empty journal passed). Tool contracts: `list_jira_issues` returns lean rows on every surface (no `RawJSON`/`CustomFieldsJSON`, description clipped at 512 bytes — `TestListJiraIssues_LeanRows`; `get_jira_issue` unchanged) and `list_emails` gains an exclusive `before` (`TestListEmails_BeforePagesOlder`). `install-template` rolls back on any failure after its first write and, with `save`, refuses a workbench recipe folder behind a symlink; `templates`/`install-template` carry template `notes`.
- 2026-10-16 (Automations P6 part 2, board #753; spec §10, §12.3, §15): P6 part 2 — template gallery, `install-template`; the four P5 workbench fixtures moved from `internal/automations/testdata/workbench/` into `internal/automations/templates/`. Guards added: AUTO-12 `TestTemplates_DryRunE2E`, AUTO-06 `TestInstallTemplate_InstalledUnconfirmedAndDisabled`. No guard relaxed.
- 2026-10-16 (Automations P5 part 1 final-review fixes, board #753): strengthening, no guard relaxed. A workbench folder path whose folder or any ancestor is a symlink is never followed: the daemon's rescan skips it and `shell()` refuses it with `NotAvailable` before any stat or process (`fsutil.NoSymlinkComponents`; guards `TestScheduler_NeverFollowsAnAncestorLink`, `TestShell_RefusedWhenTheFolderPathHasALink`). `shell()`'s PATH is the daemon's resolved rich PATH (`claude.RichPATH`), not launchd's minimal one; the env keys are unchanged. `automations session-launched`/`session-ended` are refused under AGENT-07's markers. Guards renamed to say what they pin, assertions unchanged: `TestWorkbenchAutomation_WritesNotAvailable` → `TestWorkbenchAutomation_WritesAreProposals` (and the three `internal/tools` ones listed in agent-actions.md).
- 2026-10-16 (Automations P5 Task 11, board #753; spec §12.4): the Desktop half of AUTO-09 for the workbench header buttons — guard `testAuto09_HeaderButtonOnlyQueues` added (a runnable button's click issues exactly `automations run <id> --json` through `AutomationsViewModel.runNow`, no other CLI call and no row written from Swift). No status flip, no guard relaxed.
- 2026-10-16 (Automations P5 part 1, board #753; spec §6.1, §13, §15): P5 part 1 — workbench recipes indexed by the daemon, shell(), session(), ask(), workbench writes. **AUTO-12 and AUTO-13 are Enforced** with the guards listed on them (Tasks 4 and 7); the Desktop half of AUTO-09 (header buttons) and the Swift launch guards follow in part 2. Fail-closed fix: a stored `automation_run` row whose context id does not parse (or is 0) is refused with `ErrAutomationRunGone` at Propose, Approve and Apply instead of applying with no workbench check (`internal/tools/registry_automation_test.go::TestWorkbenchAutomation_UnparsableRunContextFailsClosed`). The workbench fixtures' failure path no longer files an `output.report` before its `throw` (a failed run commits no outputs, AUTO-04); the failure is the run's error, which carries the stderr tail. No guard relaxed.
- 2026-10-16 (Automations P5 Task 7, board #753; spec §6.1, §13, §15 #2/#5): **AUTO-12 is Enforced in full** — its session half joins with `TestAuto12_DryRunStartsNoSessionOrShell` over the four workbench recipes (`internal/automations/testdata/workbench/`, since moved into `internal/automations/templates/`), `TestSession_DryRunWaitsForNothing` and `TestAsk_DryRunCreatesNoRow`. **AUTO-02:** the P2 workbench write gate is lifted (spec §13): a workbench automation's run writes through `Registry.Propose` like a personal one, and the registry resolves its workbench from the run at Propose, Approve and Apply (AGENT-01 amended in `agent-actions.md`); `TestWorkbenchAutomation_WritesNotAvailable` keeps its name and now pins that a live run's writes are proposals, a dry run records none, and Apply after the workbench was deleted fails. No other guard relaxed.
- 2026-10-16 (Automations P5 Task 4, board #753; spec §5, §13.2, §20.1 D19): **AUTO-13 flips from Planned to Enforced** with the `shell()` guards listed there; **AUTO-12's `shell()` half is Enforced** (`TestShell_DryRunStartsNoProcess`), its session half stays Planned. `NewProcessShellRunner` is wired as `Backends.Shell`. Oversized `shell()` output is cut to fit, never `ResultTooLarge` (owner decision ask #272, replacing R-P5-1). No guard relaxed.
- 2026-10-16 (Automations P6 part 1, board #753; spec §5, §6.5, §14.7): **`mcp()` and `agent()` land (runtime B, the claude CLI and the codex CLI); the templates and the gallery CLI follow in the second P6 part.** No status flips (AUTO-01/07/08/11/12 were Enforced since P1) and no guard relaxed; guards added to AUTO-01/07/08/11/12 as listed there. `agent()` is one journal step: its inner tool calls are summarised in that step (AUTO-11 counts SDK calls). Behaviours recorded with their tests: the `--surface automation` server's `get_action` shows only the bound run's own rows (`TestGetAction_ScopedToAutomationRun`); `internalmcp.WithResultCheck` applies the 256 KiB `ResultTooLarge` refusal on that server and runtime B applies `CheckAgentResult` per tool result (`TestChatMode_ResultCheckReplacesResult`, `TestAgentLoop_ResultCheckRefusesResult`, `TestCheckAgentResult_RefusesOverLimit`); a codex child runs in a per-run temporary `CODEX_HOME` (`TestAgent_CodexChildBoundToRun`); an empty `ai.provider` runs `agent()` through the claude CLI (`TestAutomationBackends_WireMCPAndAgent`); a carved minutes deadline throws a catchable `BudgetExceeded`.
- 2026-10-15 (Automations P2 Task 9, board #814): **AUTO-02 (write side) and AUTO-03 flip from Planned to Enforced.** AUTO-02 names `output.target`/`output.slack` (shortcuts through `Registry.Propose`) and the P2 workbench write gate (until P5); AUTO-03 records the grant table (migration 00117 — 00114–00116 are unrelated main migrations), the `automations auto` refusal order and the dormant `AutomationAgent` branch (P6); AUTO-01 records D28 (ask #315: `output.slack` needs `outputs: [slack]` and `slack:write@<account>`; an unscoped `tool:send_slack_message` counts as `slack:write@*`), which changed the `TestManifest_AdmitsWrite` case formerly named "outputs slack" (admitted) to "outputs slack alone admits no grant (D28)" (refused) (a narrowing). AUTO-04/12 gain the P2 output and dry-run guards. P1's interim `TestTool_WriteNotAvailableInP1` stays retired (entry below). No guard relaxed.
- 2026-10-15 (Automations P2 Task 5): AUTO-02's P1 guard `TestTool_WriteNotAvailableInP1` is retired as planned (P2 plan Task 5, Step 3): it pinned P1's interim "writes arrive in a later phase" branch, not a contract. `tool()` writes now go through `Registry.Propose` on the `automation` surface (`ToolWriteModule`); the write-side guard `TestAuto02_ToolWriteGoesThroughPropose` replaces it. AUTO-12 gains `TestAuto12_DryRunWriteNeverReachesRegistry` (a dry-run write, `{wait:true}` included, returns `{status:"dry_run"}` and writes no `agent_actions` row). The status flips of AUTO-02/AUTO-03 stay with Task 9.
- 2026-10-15 (**owner decision, ask #294**; spec §20.3 D26, amending D5): strengthening, no guard relaxed. AUTO-06's `approval_hash` now also binds the trigger (without a button's cosmetic label; `confirm` counts), the `missed` policy, the budget (tokens and minutes) and `concurrency`, so a schedule or budget edit needs the owner's confirmation again. `TestApprovalHash_GoldenCanonicalBytes` gets new canonical bytes and hex (computed outside Go); guards `TestAuto06_ScheduleBudgetEditNeedsConfirmation`, `TestAuto06_ButtonLabelEditKeepsConfirmation`, `TestApprovalHash_ButtonLabelIsCosmetic` added. Upgrade effect: every recipe is re-hashed once, so every recipe confirmed before this change is unconfirmed until the owner confirms it again.
- 2026-10-15 (**owner decision, ask #294**; spec §20.3 D25): **AUTO-08 amended — the daily-cap clause is removed** (owner-approved in ask #294). `automations.daily_budget_tokens`, `ExecutorOptions.DailyBudgetTokens`, the meter's live daily total and `InterruptDailyCap` are gone; `error_kind='daily_cap'` stays in the CHECK but is no longer produced. Guards retired with that approval: `TestAuto08_DailyCap`, `TestAuto08_DailyCapSeesConcurrentSpend`, `TestAuto08_DailyCapDayFollowsTheExecutorZone`, `TestAuto08_DailyCapWindowIsTheRunStartDay`, `TestExecutor_DailyCapZeroSpendsNothing`, `TestSandbox_DailyCapInterruptsUncatchably` (plus the meter unit tests `TestMeter_DailyRemainderInterrupts`, `TestMeter_LiveDailyTotalAcrossRuns`, `TestMeter_DailyTotalReadErrorRefusesCall`). Added `TestAuto08_NoDailyCapAcrossRuns`. The per-run token budget, time budget, pause timeout and terminal-status guards are unchanged.
- 2026-10-15 (**owner decision, ask #293**; spec §20.3 D24): strengthening, no guard relaxed. AUTO-06 notes that `automations enable` and `automations delete` are owner-only (refused under AGENT-07 markers before anything is read or written); guard `TestAutomationsCLI_EnableDeleteRefusedUnderAgentMarkers` added.
- 2026-10-15 (Automations P1, board #753): file created with AUTO-01..13 from spec §14.1. Enforced: AUTO-01, 04, 05, 07, 08, 10, 11; AUTO-02 (read side), AUTO-06 (executor, indexer, CLI — ask #271), AUTO-09 (scheduler and CLI), AUTO-12 (P1 half). Planned: AUTO-03 (P2), AUTO-13 (P5), the write side of AUTO-02 (P2), the `draft_automation` half of AUTO-06 (P3), the event half of AUTO-09 (P4), the session/shell half of AUTO-12 (P5). Owner rulings recorded: ask #280 (D16 draft refusal keyed by `approval_hash`; D22 `slack:read@*` or `tool:list_messages`), ask #287 (a Jira project grant covers linked data; `digests:read` and `find_experts` under `people:read` kept). Related strengthening elsewhere: AGENT-07 marker and refused commands (`agent-actions.md`), the DEV-01/AGENT-06 telemetry narrowing (`dev-surface.md`, `agent-actions.md`), the FEAT-03 `automations` fast-forward hook (`features.md`).
- 2026-10-25 (board #608, approved 2026-10-25, asks #569 and #572): AUTO-13 and the `mcp()` path gain the organization-policy refusals; `TestAutomationsCLI_ShowJSONKeys` gains the key `policy_blocked` (a case added, nothing relaxed).
- 2026-11-03 (CI flake of `TestSandbox_HeapBudgetStopsTheRun`): strengthening, no guard relaxed. A run's memory baseline no longer takes in garbage past one `RunHeapBudget` (a GC is forced first), so back-to-back memory bombs no longer each get twice the room of the one before; guard `TestSandbox_HeapBaselineLeavesGarbageOut` added.
- 2026-11-11 (board #1735, no wall-clock waits in tests): guards rewritten to wait on events, not real time; no guard relaxed. `TestAuto08_InterruptOnTimeout`, the sandbox deadline/interrupt guards and `TestSandbox_StuckNativeIsAbandonedAfterGrace`/`TestExecutor_AbandonedRunDisablesAutomation` expire the deadline and the abandon grace on a fake clock (the sandbox times both on the meter's `Clock`, `RealClock` in production) and now also assert the run was not abandoned where the script must stop. The heap-budget guards drive the watchdog sample by sample (`heapTicker` seam); `TestSandbox_HeapWatchdogTicksOnItsOwn` pins the production ticker in a synctest bubble ("stopped within one 10 ms poll"). The regex guards time calls on a test clock (`regexClock`); `TestSandbox_CatastrophicMatchEndsByItsOwnTimeout` still runs a real catastrophic match through regexp2's own timeout. AUTO-13: `TestShell_KillsProcessGroupOnInterrupt` and the new `TestShell_RunnerDeadlineKillsTheGroup` see the group's end as EOF on a FIFO held by children that never exit on their own; `TestShell_TimeoutIsRemainingActiveBudget` checks the command deadline on a fake shell. Executor/replay/waiter guards run in synctest bubbles; the replay guards' loop still ends only through the interrupt reaching running JS.
