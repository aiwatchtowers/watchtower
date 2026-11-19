# Watchman — Behavior Inventory

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/watchman/`, `internal/watchmanact/`,
> `internal/askanswer/`, `internal/db/watchman*.go`, `internal/daemon/watchman*.go`,
> `cmd/watchman*.go` or `cmd/workbench_watchman_guard.go`, read this file first. Any
> proposed change that would break a guard test or remove a contract must be
> raised as a question before touching code.

**Module:** `internal/watchman/` + `internal/watchmanact/` + `internal/askanswer/` (the answer write) + `internal/db/watchman*.go` + `internal/db/migrations/00198_watchman.sql` … `00207_watchman_items_moves.sql` + `internal/daemon/watchman*.go` + `cmd/watchman*.go` + `cmd/workbench_watchman_guard.go` + `internal/devpack/workbench_settings.go` (the guard's hook entry) + `internal/tools/workbench_watchman.go` (wait points, finish gate)
**Last full audit:** 2026-11-18 (phase 2: WATCHMAN-01, -02, -04, -05 added; -03 and -06 amended)
**Owner approval:** spec `docs/superpowers/specs/2026-11-16-watchman-design.md` (ask #1385; contracts ask #1373; Sleep-only phase 2 ask #1578; D47 ask #1583, WATCHMAN-04 amendment ask #1591); plan `docs/superpowers/plans/2026-11-18-watchman-phase-2.md` (ask #1588); feature note `docs/features/watchman.md`.

---

## WATCHMAN-01 — the twin never decides a hard limit, and the guard layers deny it while armed

**Status:** Enforced (Go).

**Observable:** The hard limits are Go tables; the model never decides one. Permission requests and Bash commands go through `watchman.CheckLimits` = the built-in table `ParkedBy` (rows in this order: `unreadable` — a command the reader cannot read; `send_pack` — `git send-pack` in any form; `main_ref` — a push to or rebase onto the default branch and, in phase 2, **every PR merge whatever its base** (`gh pr merge` in any form, `gh api …/merge`, GraphQL `mergePullRequest`, plus a textual backstop: a merge word next to `gh`/`hub`/`api`/`graphql`/`pulls`/`curl` parks); `tag`; `release`; `testflight`; `force_push`; `reset_shared` — a forced move of a shared branch (with the shared branches unknown, every destructive ref move with an explicit target parks); `delete_outside` — `rm` outside the session's worktrees, `rm` counted in any position; `outward` — a message or comment other people see; `standing_grant` — a write to `.claude/settings*.json` or `.codex/config.toml`; `outside_folder` — a file tool outside the workbench folder and its worktrees), then the owner's rows (`owner`). A clipped summary, an unknown placement and a request the table cannot read park. Ask text goes through `watchman.AskParkedBy` (`main_ref`, `release`, `tag`, `testflight`, `outward`, `inventory`) on the title, summary and questions **before** the model and on them plus the twin's choice **after**; the light-tier label call may only add a park, and its error or timeout parks. Before any twin Approve, Go parks a diff that touches `docs/inventory/**` or a guard test (`ProtectedChange`) and a spec or plan that may change a contract (`ProtectedDoc`, D46). A parked item is answered `Parked for the owner: <reason>` (an ask), denied with `decided_by = 'watchman'` (a permission) or left without an Approve, and journalled under **WAITING FOR YOU**.

Two modes read the same table: the twin and the backtest are **strict** (every shape the reader cannot see into — a subshell, a command substitution, a loop, a background job, `eval`, a pipe into a shell — parks as `unreadable`); the guard hook is **lenient** (`PermissionAsk.Lenient`: such a shape parks only when the command also names a hard-limit action, the merge backstop ignores comments, and a commit or PR heredoc body is blanked only when every sibling part of the command is on a plain-command allowlist), so ordinary agent commands in an armed session are not denied. While armed, the PreToolUse hook `workbench watchman-guard` denies a covered tool call with `Parked for the owner: <limit> — continue with other work` and journals it as a `guard` item; armed and unable to read its input, the owner's limits (from the database, or a sidecar marked `limits-unavailable`) or a sidecar that exists, or on a panic, it denies `unreadable`; the database not read within 500 ms → the arm sidecar decides with the `limit <kind> <pattern>` lines it carries. The chaining `pre-push` hook refuses, in an armed worktree, a push to `main`/`master`, a tag push and a non-fast-forward push, and then runs the repository's own `pre-push`. The owner can add limits (`watchman limits add`, Settings **Add a Limit…**) and remove only his own; no built-in row can be removed (`BuiltinLimits`).

**Why locked:** These are the actions only the owner may take (CLAUDE.md, spec §5). A model that could talk itself past one, a guard that failed open, or a removable built-in row would let one confident wrong decision at night merge, publish or delete for him.

**Test guards:**
- `internal/watchmanact/twin_permission_test.go::TestWATCHMAN01_TwinNeverDecidesHardLimit` (every built-in row and an owner's row: denied for the owner, `decided_by = 'watchman'`, the model never called)
- `cmd/workbench_watchman_guard_test.go::TestWATCHMAN01_HardLimitsDeniedWhileArmed` (every row and an owner's row: denied with the parked reason while armed, allowed when not)
- `internal/watchmanact/twin_review_test.go::TestWATCHMAN01_TwinNeverApprovesContractChange` (a diff touching `docs/inventory/**` and a plan naming a guard test park without an Approve)
- supporting: `internal/watchman/hardlimit_test.go::TestParkedBy` (one case per row) and `TestParkedBy_HiddenShapesStrictAndLenient`, `TestParkedBy_HeredocIdiomAndMoreHiddenShapes`; `internal/watchman/asklimit_test.go::TestAskParkedBy`; `internal/watchman/extralimit_test.go::TestCheckLimits_OwnerRowsAdd`, `TestBuiltinLimits_ListsTheTable`; `internal/watchmanact/protected_test.go::TestProtectedChange`, `TestProtectedDoc`, `TestProtectedDoc_InventoryDir`; `internal/watchmanact/twin_test.go::TestTwin_HardLimitParksBeforeModel`, `TestTwin_ChoiceParkedAfterModel`, `TestTwin_LabelOnlyAddsPark`, `TestTwin_LabelErrorParks`; `internal/watchmanact/githooks_test.go::TestPrePush_RefusesMainFromNestedScript`, `TestPrePush_RefusesTagDeleteAndNonFastForward`; `cmd/workbench_watchman_guard_test.go::TestWatchmanGuard_UnreadableInputDeniedWhileArmed`, `TestWatchmanGuard_LimitsReadErrorDenies`, `TestWatchmanGuard_DBUnreadableUsesSidecar`, `TestWatchmanGuard_SidecarLimitsUnavailableDenies`, `TestWatchmanGuard_HiddenShapesNeedALimitWord`; `internal/watchmanact/sidecar_test.go::TestRefreshSidecar_UnwritableLimitRowMarksUnavailable`; `cmd/watchman_limits_test.go::TestWatchmanLimits_RefusedUnderAgent`

**Locked since:** 2026-11-18

## WATCHMAN-02 — a twin write never overwrites the owner's answer

**Status:** Enforced (Go).

**Observable:** The twin writes only through `askanswer.Answerer` (asks, spec review verdicts with their marks, permission requests, typed lines) and the review-round functions in `internal/db` (`SendReviewRoundTx`, `ApproveReviewRoundTx`). Every write is a compare-and-set on the row's open state (`owner_asks.status = 'open'`, `permission_requests.status = 'pending'`, the round's open-state guard), and the item's outcome, spec marks and review comments are written in the **same transaction** as the answer. The loser writes nothing, types nothing and runs no `Also`; the item is journalled `owner_first` (`the owner answered first`). The twin never overwrites an answer the owner stored first, at the Mac or from the phone; the first stored answer wins.

**Why locked:** The owner's own answer is the ground truth; a twin that overwrote it, or wrote marks or comments for an answer it lost, would put words in his mouth.

**Test guards:**
- `internal/askanswer/answerer_test.go::TestWATCHMAN02_TwinNeverOverwritesOwnerAnswer`
- supporting: `internal/askanswer/answerer_test.go::TestAnswerer_MarksOnlyByWinner`, `TestAnswerer_ClosePermissionOwnerFirst`; `internal/watchmanact/twin_test.go::TestTwin_OwnerFirstJournalledNothingDelivered`, `TestTwin_OwnerAnsweredBeforeLeaseIsOwnerFirst`; `internal/watchmanact/twin_permission_test.go::TestTwin_PermissionOwnerFirst`; `internal/watchmanact/twin_review_test.go::TestTwin_ReviewDocOwnerFirstWritesNoMarks`, `TestTwin_ReviewRoundOwnerClosedFirst`

**Locked since:** 2026-11-18

## WATCHMAN-03 — twin decisions become precedents only after the owner's OK

**Status:** Enforced (Go).

**Observable:** Watchman learns from one closed list of sources, `DBSources()` + `TurnSource` + `GitSource` (`ask`, `review`, `spec`, `permission`, `turn`, `git`), each reading only decisions the owner made himself, in a workbench: answered asks (not an automation's, not dismissed), his diff-review and spec-review marks, permission prompts he allowed or denied, his own lines in agent sessions he started (not an automation's) and his own commits (by the folder's `user.email`, no agent trailer) and merges. No source reads a decision a twin took: an ask, spec verdict, permission (`decided_by = 'watchman'`) or review round the twin wrote is left out of the `ask`, `spec`, `permission` and `review` sources — only what the twin wrote: an answer or verdict it decided, or a park or hand-back text it wrote onto the ask; the owner's later answer to an item the twin parked or handed back, and an owner-first or superseded item, stay his decisions. Since phase 2 the closed list has a seventh source, `journal` (`SourceJournal`, migration 00203): a twin decision becomes a precedent only once the owner marked it **OK** in the morning journal (the twin's choice, weight 1) or **Correct…**-ed it (his own words, weight 3; a correction without text is skipped). An item without feedback, and a parked, handed, owner-first or check item (the Desktop writes no feedback on those), is never read.

**Why locked:** A twin that learns from its own unconfirmed decisions drifts away from the owner and then grades itself on its own answers; every precedent must trace to something the owner actually did or confirmed.

**Test guards:**
- `internal/watchman/guard_test.go::TestWATCHMAN03_SourcesAreOwnerOnly` (the source names are the closed list, `journal` included; automation, open and dismissed asks, pending, expired and answered-on-Mac permissions, and every ask, spec verdict, permission and review round a twin item decided are not read; the owner's answer after a twin park or hand-back, and owner-first and superseded items, are read)
- `internal/watchman/source_journal_test.go::TestJournalSource_UnreviewedItemIsNot`, `TestJournalSource_OKBecomesPrecedent`, `TestJournalSource_CorrectionWeighsMore`, `TestJournalSource_CorrectionWithoutTextIsSkipped` (phase 2); `WatchtowerDesktop/Tests/Core/WatchmanFeedbackQueriesTests.swift` (the Desktop writes feedback only on a finished, not yet judged twin decision)
- `internal/watchman/source_asks_test.go::TestAsksSource_SkipsAutomationAndOpen`, `internal/watchman/source_permission_test.go::TestPermissionSource_SkipsPendingExpiredAndAnsweredOnMac`, `internal/watchman/source_git_test.go::TestGitSource_SkipsAgentCommits`, `internal/watchman/source_git_test.go::TestGitSource_ForeignAuthorNotOwner` (a colleague's commit is not the owner's), `internal/watchman/source_turns_test.go::TestTurnSource_SkipsAutomationSessions`

## WATCHMAN-04 — nothing acts on a session that is not armed

**Status:** Enforced (Go). Amended before shipping by D47 (ask #1583, #1591): the spec's "nothing acts while `platform.Away` says present or cannot be read" became "nothing acts on a session that is not armed".

**Observable:** Arming is the delegation (phase 2): the twin decides only for a session that is armed itself or lies under an armed target (`watchman_arming`, written only by `watchman arm|disarm`, owner verbs refused under an AI agent's markers; the Desktop arms through them). `watchman.Mode` is pure and reads only the arming: armed → Sleep since `armed_at`, not armed → Off, whatever the owner's presence, away state or sleep window; Away (phase 3) is never returned. The lease (`LeaseArmedWatchmanItem`) re-checks the arming in its own statement, so a disarm (**Take back**) leaves queued items queued and untouched; an item already deciding when he takes it back finishes and races normally (WATCHMAN-02); an arming that cannot be read leaves everything queued. A handover's next session starts only while the session's arming row or a target covering its destination is still armed, checked again in the start's claim. The guard hook and the `pre-push` check are pass-through for a session or worktree that is not armed.

**Why locked:** The owner hands work over explicitly; a twin that acted on a session he did not hand it, or kept acting after **Take back**, would decide behind his back.

**Test guards:**
- `internal/watchmanact/twin_test.go::TestWATCHMAN04_NothingActsOnUnarmedSession` (never armed, and armed then disarmed: no lease, no attempt, no model call)
- supporting: `internal/watchman/mode_test.go::TestMode`, `TestMode_ReadsNothingElse`; `internal/watchmanact/twin_test.go::TestTwin_ActsWhileOwnerPresent` (D47), `TestTwin_DisarmLeavesQueued`, `TestTwin_ArmingReadErrorLeavesQueued`, `TestTwin_DecidingItemFinishesAfterDisarm`, `TestTwin_HandoverStartStopsWhenDisarmed`, `TestTwin_HandoverStartNeedsTheDestinationArmed`; `internal/watchmanact/githooks_test.go::TestPrePush_UnarmedPassesThrough`; `cmd/workbench_watchman_guard_test.go::TestWatchmanGuard_UnarmedReadsOneRow`; `cmd/watchman_arming_test.go::TestWatchmanArm_RefusedUnderAgent`

**Locked since:** 2026-11-18

## WATCHMAN-05 — the guard hook is installed only through `integrate` with the other workbench hooks

**Status:** Enforced (Go).

**Observable:** `workbench watchman-guard --workbench N` is installed only by `integrate claude-code --workbench N` (and its resync, Re-run Setup and Repair) as exactly one `PreToolUse` command entry in its own `"*"` group, synchronous, `timeout: 5`, beside the ask tool block and the state hook (PROJ-04), and taken out by `integrate remove`; Codex sessions get it as one more launch-flag `PreToolUse` hook (no matcher, timeout 5) in `devpack.CodexHookSet`. Nothing else installs or edits it: arming never touches the folder's settings. The hook always exits 0; its stdout is the decision.

**Why locked:** One install path keeps the owner's settings rules (PROJ-04) and the removal in force; a guard written by arming would edit his repository behind his back and could outlive a removal.

**Test guards:**
- `internal/devpack/workbench_watchman_guard_test.go::TestWATCHMAN05_GuardInstalledOnlyByIntegrate` (one entry in its own `"*"` group, a second install changes nothing, the removal takes it out, no other file of the package names its spec)
- supporting: `internal/devpack/codex_hooks_test.go::TestCodexHookSet_GoldenOrderAndTimeouts`; `internal/devpack/workbench_ask_guard_test.go::TestProj04_AskGuardReplacesOurEditedPromptAndKeepsOwnerHooks` (four `PreToolUse` groups)

**Locked since:** 2026-11-18

## WATCHMAN-06 — learning and the backtest never act

**Status:** Enforced (Go).

**Observable:** Phase 1 reads, labels, profiles and measures; it answers no ask, decides no permission, writes no review, merges nothing and types into no session. `internal/watchman` imports none of `internal/hub`, `internal/sessionhost` and `internal/tools`. Phase 2's acting code lives in its own package, `internal/watchmanact` (the twin worker, the git hooks, the arm sidecar, `ProtectedChange`/`ProtectedDoc`), so this contract stays true for learning and the backtest; `watchman.Mode` takes plain values (`ModeInputs`), not a `platform.Away`, and the hard-limit tables in `internal/watchman` only classify. `Decide` never writes, and `watchman learn --start` and `watchman backtest` are the owner's verbs, refused under an AI agent's environment markers (AGENT-07).

**Why locked:** Phase 1 is the measurement that decides whether the twin may act at all (the go/stop verdict); code that could act inside the learning package would let a measurement change what it measures.

**Test guards:**
- `internal/watchman/guard_test.go::TestWATCHMAN06_NoActingImports` (no non-test file of the package imports the three packages or their subpackages)

**Locked since:** 2026-11-16

---

## Changelog

- 2026-11-19 (multi-folder workbench merged with Watchman, board #2003): additive, no guard relaxed — WATCHMAN-04 holds for folder suggestions too (a `kind='folder'` ask is never queued, answered or learned by the twin; `TestScanWatchmanWaitPoints_SkipsFolderAsks`, `TestTextAnswer_RefusesAFolderAsk`); a review ask's protected-document check reads the inventory of its own document folder and parks on an unresolvable one (`TestTwin_ReviewDocUsesTheDocFoldersInventory`); arming checks every covered repository (`TestWatchmanArm_ChecksTheCoveredFolders`). v1 limits (feature note): precedents dedupe by key on a bench merge, the merged bench's cursors drop, sibling-folder edits are denied as `outside_folder`, the git source reads the home folder's PR states only.
- 2026-11-16 (phase 1, board #1823): file created with WATCHMAN-03 and WATCHMAN-06 (new, beyond the spec's five).
- 2026-11-16 (final review fixes): WATCHMAN-03 tightened — git commits count only for the folder's `user.email`, automation-started sessions leave the turn source; guards added.
- 2026-11-17 (Task 12, asks #1422/#1423): the backtest's metric changed (judge grades, strong = ≤ 5 % bad and none bad while sure, go needs `permission`, `design` or `scope`); WATCHMAN-03 and WATCHMAN-06 unchanged.
- 2026-11-18 (phase 1b): the backtest measures decisions only, with handoffs and a 20-scored floor; WATCHMAN-03 and WATCHMAN-06 unchanged.
- 2026-11-18 (phase 2, plan `docs/superpowers/plans/2026-11-18-watchman-phase-2.md`, **contracts approved by the owner in ask #1373**, Sleep-only phase 2 ask #1578, plan ask #1588): **WATCHMAN-01, -02, -04 and -05 added** with their guards (Tasks 4, 5, 7, 9, 10, 12). WATCHMAN-01 records the controller rulings of the phase: `send_pack` joins the table, every PR merge parks in phase 2 whatever its base (`main_ref`), the twin is strict and the guard lenient, the owner's extra limits are add-only and travel in the sidecar as `limit` lines (`limits-unavailable` fails closed).
- 2026-11-18 (phase 2, D47, **owner approved the amendment in ask #1591**, decision ask #1583): WATCHMAN-04 reads "nothing acts on a session that is not armed" instead of the spec's presence rule; **Going to sleep** is dropped from phase 2.
- 2026-11-18 (phase 2 Task 14, ask #1373): WATCHMAN-03 amended — the `journal` source joins the closed list (only owner-OK'd or corrected twin decisions; migration 00203), and rows a twin item decided are left out of the `ask`, `spec`, `permission` and `review` sources; the guard asserts both. No guard relaxed.
- 2026-11-19 (phase 2 final review, codex 3): WATCHMAN-03 made exact — the `ask`, `spec`, `permission` and `review` sources leave out only what the twin wrote (`answered`, `approved`, `changes`, and a park or hand-back whose text stands in the ask's answer); the owner's later answer to a parked or handed item, owner-first and superseded items are read again. The guard is extended, not relaxed.
- 2026-11-18 (phase 2, ask #1373): WATCHMAN-06 amended — the acting code is `internal/watchmanact`; the guard is unchanged.
