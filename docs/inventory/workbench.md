# Workbench — Behavior Inventory

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/db/workbenches.go`,
> `workbench_comments.go`, `workbench_board.go`, the `project_id` exclusions in
> the targets readers, `internal/tools/workbench*.go`, `cmd/workbench*.go`,
> `cmd/integrate_workbench.go`, `internal/devpack/workbench*.go`,
> `internal/gitbin/`, `internal/workbenchgit/`, `internal/sessionreport/`, or
> `WatchtowerDesktop/Sources/**/Workbench*`, read this file first. Any proposed change that would break a guard test or
> remove a contract must be raised as a question before touching code.

A workbench is a folder with a board of targets, owner↔agent target
comments and the agent's asks to the owner (`owner_asks`, PROJ-12/13),
worked on by Claude Code through
`watchtower mcp --workbench N` (DEV-06 in `dev-surface.md`), a workbench skill,
a `SessionStart` hook (the brief), a `Stop` hook (the board drift check, PROJ-07),
the session state hooks (PROJ-11) and the ask guard (a `Stop` prompt hook and a
`PreToolUse` block of `AskUserQuestion`, PROJ-13). Each Desktop terminal session
has a report of its own work, and the agent marks it finished with
`finish_session` (PROJ-14). Design:
`docs/superpowers/specs/2026-09-29-project-board-poc-design.md`; owner asks:
`docs/superpowers/specs/2026-10-03-workbench-owner-asks-design.md`; session
report and states: `docs/superpowers/specs/2026-10-03-workbench-session-report-design.md`; board
archive: `docs/superpowers/specs/2026-10-04-workbench-board-archive-design.md`.

**Naming (2026-10-02):** this feature was called *Projects* until the
Workbench rename (`docs/superpowers/specs/2026-10-02-workbench-rename-design.md`).
The contracts keep their `PROJ-NN` ids and their meaning, and the guard tests
keep their `TestProjNN_…`/`testProjNN_…` names (only their files moved).
Storage and wire keep `project`: the `projects`/`project_*` tables, the
`project_id` columns, DB values such as `custom_label='project'`, the kb
source `project_doc`, `<workspace>/project_files/`, the `projects.*`
UserDefaults keys and every CLI `--json` key. A folder set up before the
rename keeps working through the legacy aliases (`watchtower project …`,
`--project N`, the `watchtower-project` server and skill, the old tool names
under `mcp --project N`) until the owner resyncs it; see
`docs/features/workbench.md`, "Rename".

**Module:** `internal/db/{workbenches,workbench_comments,workbench_board}.go` +
`internal/tools/{workbenches,workbench_targets,workbench_docs,workbench_asks,workbench_finish,workbench_images,workbench_scope,workbench_names}.go` +
`internal/db/workbench_images.go` + `internal/workbenchfiles/` +
`internal/asks/` + `internal/db/owner_asks.go` + `internal/db/migrations/00100_owner_asks.sql` + `internal/kb/{fileset,source_workbench}.go` +
`cmd/{workbench,workbench_brief,workbench_brief_session,workbench_check,workbench_askguard,workbench_session_state,workbench_flags,integrate_workbench}.go` + `internal/devpack/{workbench,workbench_settings}.go` + `internal/devpack/askguard_prompt.md` + `internal/workbenchdocs/` + `internal/workbenchcheck/` +
`internal/db/terminal_sessions.go` + `internal/db/migrations/00098_terminal_session_agent_state.sql` +
`internal/db/session_report.go` + `internal/db/migrations/00101_workbench_session_report.sql` +
`internal/db/workbench_archive_reads.go` + `internal/db/migrations/00103_workbench_board_archive.sql` + `internal/tools/workbench_board.go` +
`internal/sessionreport/` + `cmd/workbench_session_report.go` +
`WatchtowerDesktop/Sources/Views/Workbench/` + `WatchtowerDesktop/Sources/Services/SessionAgentStateCenter.swift` +
`WatchtowerDesktop/Sources/WatchtowerCore/{Models/SessionAgentStatus,Services/SessionAgentNoticePolicy}.swift` +
`WatchtowerDesktop/Sources/WatchtowerCore/{Models/SessionReport,Services/SessionStatePresentation,Services/SessionSwitcherPresentation,Services/SessionReportPresentation}.swift` +
`WatchtowerDesktop/Sources/WatchtowerCore/{Models/OwnerAsk,Database/Queries/OwnerAskQueries,Services/OwnerAsk*}.swift` +
`WatchtowerDesktop/Sources/ViewModels/OwnerAsksViewModel.swift`
**Last full audit:** 2026-09-29

## PROJ-01 — workbench targets never reach a non-board reader

**Status:** Enforced (Go and Desktop; the Desktop half landed with Task 20)

**Observable:** A target with `project_id` set lives only on its workbench's
board. Every non-board Go reader filters `project_id IS NULL`: `GetTargets` by
default (`TargetFilter.WorkbenchID == 0`), `GetTargetsNeedingNextStep`,
`GetTargetsForBriefing`, `GetTargetCounts`, `NotifyDueTargets`,
`ListCatchupTargets`, `ListTargetsForMirror`, `internal/dayplan/gather.go`,
`internal/db/channel_stats.go`, and the extract/dedup snapshots in
`internal/targets/pipeline.go`; `nextstep.go`'s single-target path skips a
workbench target. The registry's `list_targets`/`get_target` return a workbench
target only inside that workbench's own session (`watchtower mcp --workbench N`);
any other session is told `no target with id N`.

**Why locked:** Owner decision D4. An agent decomposes a plan into dozens of
sub-targets; letting them into the Targets tab, the day plan, next-step,
Catch-Up, memory mirrors or the inbox overdue notification would flood every
personal surface with the agent's own bookkeeping — and spend next-step AI
calls on it.

**Test guards:**
- `internal/db` — `TestProj01_ProjectTargetsNeverReachNonBoardReaders` (Task 3)
- `internal/tools/workbenches_test.go::TestProj01_TargetReadsFollowTheSessionScope`

**Locked since:** 2026-09-29

## PROJ-02 — delete leaves nothing

**Status:** Enforced

**Observable:** `watchtower workbench delete N` first runs the folder removal
(`workbenchRemoveInstall`, wired to `devpack.RemoveWorkbench`: the
`watchtower-workbench` skill, our hook entries — `SessionStart`, `Stop` and,
since 2026-10-03, the session state entries under `UserPromptSubmit`,
`Notification`, `PostToolUse` and `StopFailure` (PROJ-11) and the two ask
guard entries — the `Stop` prompt hook and the `PreToolUse` command hook
matched to `AskUserQuestion` (PROJ-13) — the local
`watchtower-workbench` MCP registration and the `.git/info/exclude` lines
Watchtower added) — a removal failure is reported and the delete still
happens — then deletes the workbench row, which removes every workbench target,
source, owner ask, comment, target-image row and terminal session row
— and with the sessions their target links (`terminal_session_targets`,
since 2026-10-03), plus the workbench's PR cache (`workbench_pr_states`) —
in the same transaction (`db.DeleteWorkbench`, `ON DELETE CASCADE` from `projects`)
together with its folder files' search index entries (`kb_documents`/`kb_chunks`
of source `project_doc` for that workbench, PROJ-08) and, since 2026-10-04,
its code questions (`chat_conversations` of context type `code_question`
whose `context_id` starts with `<id>:`, the prefix matched exactly, with
their messages and search rows by cascade), and then removes
the workbench's stored image copies (`<workspace>/project_files/<id>/`,
`workbenchfiles.Store.RemoveWorkbench`; a failure is reported as `files_ok:
false` and never undoes the delete). Deleting one workbench target
(`watchtower targets delete`) removes the stored copies no other target of
the workbench still names; `update_target`'s `remove_image_ids` does the same
for a detached image. A Claude Code
session still connected answers `workbench N no longer exists` on every tool
(DEV-06). The folder's files themselves are the owner's and stay in the
folder. An exclude line is removed only when its path is gone — a skill the
owner edited (kept, PROJ-04) or a settings file holding the owner's own keys
keeps its line, so removal never surfaces an owner file in `git status`.
The removal takes away both vocabularies (since 2026-10-02): a folder set up
before the Workbench rename and never resynced loses its legacy
`project brief --project N`/`project check --project N` hook entries, its
`watchtower-project` skill (through the same DEV-04 rule, so an edited copy
stays, PROJ-04), its `watchtower-project` registration and their exclude
lines, exactly as a current folder does.

**Why locked:** Owner decision D7. A half-deleted workbench — orphan targets, a
hook that briefs about a workbench that no longer exists, an MCP server
registered against a dead id — is worse than no workbench at all, and the owner
must be able to undo the whole feature for a folder in one step.

**Test guards:**
- `internal/db/workbenches_test.go::TestProj02_DeleteProjectLeavesNoRows` (owner asks included — an open one bound to a session and a target, an answered one — while another workbench's ask survives; no `terminal_session_targets` or `workbench_pr_states` row of it is left, another workbench's PR cache row survives; its code questions and their messages and search rows are gone, another workbench's question and a main-chat row with the same `context_id` survive)
- `cmd/workbench_images_test.go::TestProj02_ProjectDeleteRemovesStoredTargetImages`
- `cmd/workbench_images_test.go::TestProj02_TargetDeleteDiscardsItsUnsharedImages`
- `internal/tools/registry_workbench_test.go::TestProjectBinding_DeletedProjectAnswersNoLongerExists`
- `internal/mcp/workbench_test.go::TestProjectMode_DeletedProjectEveryToolAnswersNoLongerExists`
- `internal/devpack/workbench_test.go::TestProj02_RemoveProjectLeavesNothingInstalled` (the fixture asserts every hook, the state hooks and both ask guard hooks included, is installed before the removal)
- `internal/devpack/workbench_test.go::TestProj02_RemoveProjectLeavesGitStatusClean`
- `internal/devpack/workbench_test.go::TestProj02_RemoveProjectKeepsOwnerSettingsButDropsOurHook` (two owner `PreToolUse` groups — an `AskUserQuestion` command and a `Bash` prompt hook — come back exactly the owner's)
- `cmd/integrate_workbench_test.go::TestProj02_ProjectDeleteRunsTheFolderRemoval`
- `cmd/workbench_check_test.go::TestProj02_ProjectDeleteLeavesNoHookOfTheProject` (no hook of the deleted workbench — brief, drift check, session state or ask guard — survives in `settings.local.json`; the owner's own `Stop`, `UserPromptSubmit` and `PreToolUse` hooks and keys do)
- `internal/devpack/workbench_legacy_test.go::TestProj02_RemoveLegacyFolderLeavesNothingInstalled` (a never-resynced pre-rename folder: legacy hooks, skill, registration and exclude lines gone, `git status` clean, `integrate status` reports nothing installed)

**Locked since:** 2026-09-29

## PROJ-03 — the Desktop never writes a workbench document behind anyone's back

**Status:** Enforced (amended 2026-10-02 — the code viewer may write the owner's own edits, never over a newer version; amended 2026-10-03 — the document view is gone with attached documents)

**Observable:** The Desktop writes files of the workbench folder only through
the code viewer — the owner's own actions there: the Files pane editor's saves
under the 2026-10-02 rule below (never over a version it has not seen), and the
FILES tree's create, rename/move and Move to Trash (the sessions panel's FILES
section, `WorkbenchFilesSection`; see the Code viewer notes in
`docs/features/workbench.md`). No workbench MCP tool writes a file in the
workbench folder: `ask_owner` only resolves and reads its `doc_path`
(`tools.ResolveWorkbenchDocumentPath`, then a read through `os.OpenRoot` on
the folder) into the ask's `doc_snapshot`, `get_ask`, `list_asks` and
`withdraw_ask` touch only `owner_asks` rows, and a target image is copied
*out* of wherever it is into Watchtower's own workspace directory
(`project_files/`), never into the folder.

**Amended 2026-10-02 (board #234, owner decision in the code-viewer review):**
the Files pane's editor writes a file of the workbench folder — an attached
document included — only with the owner's own typed edits, and never over a
version it has not seen: every save re-reads the disk and refuses when the
file changed, was deleted or no longer reads as text since the edits began
(`CodeFileBuffer.saveNow`), an edit typed before a disk reload reached the page
counts as a conflict, and the owner then picks Reload from disk or Keep mine
(Write it back for a file deleted under the edits — Cmd+S does the same, an
explicit save; Write mine over it for a version that no longer reads as
text). The autosave never takes any of these choices by itself.
The document view, its comments and every workbench tool still never write
the file.

**Amended 2026-10-03 (owner asks, spec
`docs/superpowers/specs/2026-10-03-workbench-owner-asks-design.md` §9,
approved by the owner):** the Desktop document view, its comments and their
re-anchoring are removed with attached documents; the contract is the Files
pane rule above plus "no workbench tool writes the folder".

**Amendment 2026-10-03 (owner-approved; code questions,
spec `docs/superpowers/specs/2026-10-02-code-navigation-design.md` §9.2,
ruling R47):** besides the owner's typed edits, the editor writes text the
owner explicitly applies from a code-question suggestion (**Apply** in the
popover at the selection): one undoable edit in the editor page, refused
while the buffer has a problem with its disk version or when the selected
text changed since the question, then the same base-revision, autosave and
conflict path as a typed edit. The assistant never writes a file itself.

**Why locked:** Owner decision D8. Two writers on one file — Claude Code in
the terminal and the Desktop — would race and lose either the agent's or
the owner's edits. The 2026-10-02 amendment keeps that promise for the
agent's side (nothing it wrote is ever overwritten unseen) while letting the
owner fix a line by hand.

**Test guards:**
- `WatchtowerDesktop/Tests/CodeFileBufferTests.swift::testProj03FilesEditorNeverWritesOverANewerDiskVersion`
- `WatchtowerDesktop/Tests/CodeFileBufferTests.swift::testProj03AnEditTypedBeforeAReloadIsAConflictNotASave`
- `WatchtowerDesktop/Tests/CodeFileBufferTests.swift::testProj03ADeletionUnderEditsIsNeverUndoneByTheAutosave`
- `WatchtowerDesktop/Tests/CodeFileBufferTests.swift::testProj03AnUnreadableDiskVersionIsNeverWrittenOver`
- `internal/tools/workbench_asks_test.go::TestProj03_AskOwnerNeverWritesTheFolder` (a tree snapshot — content hash, mode and mtime per entry — is unchanged across a review ask, a supersede, an answer, `get_ask`, `list_asks`, a question ask and a withdraw)
- Go side, by review: `grep -nE "os\.(WriteFile|Create|OpenFile|Rename|Remove)" internal/tools/workbench_docs.go internal/tools/workbench_asks.go`
(expected: no match).

**Locked since:** 2026-09-29

## PROJ-04 — the install never overwrites the owner's content

**Status:** Enforced

**Observable:** `watchtower integrate claude-code --workbench N` merges into
`DIR/.claude/settings.local.json` preserving every key and every hook the
owner has, adding a fixed set of entries of ours: one under `SessionStart`
(the brief); under `Stop` the drift check (PROJ-07) and, since 2026-10-03,
the ask guard prompt hook (PROJ-13) — two entries of ours on that event; one
each under `UserPromptSubmit`, `Notification`, `PostToolUse` and
`StopFailure` (the session state hooks, PROJ-11); and, since 2026-10-03, one
`PreToolUse` command entry in its own group with matcher `AskUserQuestion`
(the ask tool block, PROJ-13). A command entry is recognised per event by its
command suffix after a `watchtower` binary, the prompt entry by its first
line being exactly the marker `[watchtower-workbench ask-guard N]`
(installing twice leaves one of each; the state and ask guard entries have no
legacy spelling, so nothing else is taken for one). Our prompt entry whose
text was edited is set back in place, the owner's other keys on it kept; our
`PreToolUse` entry found in another matcher group is taken out of that group
(the owner's hooks there kept) and re-added in its own `AskUserQuestion`
group. A malformed settings file — `hooks`, or the entry list of any event
we own (`PreToolUse` included since 2026-10-03), of the wrong type — is left
byte-identical and reported once; `integrate remove --workbench N` deletes
only those entries. The `watchtower-workbench` skill follows DEV-04: a copy the owner
edited (differs from both what we ship and its `.watchtower-shipped` digest)
is never overwritten or deleted. The same holds for the pre-rename
`watchtower-project` skill (since 2026-10-02): a resync (`workbench resync`,
Re-run Setup, `integrate claude-code --workbench N`) deletes it only when it
is our marked, un-edited copy; an edited or foreign copy stays byte-identical,
is reported, and keeps its exclude line. The resync replaces our own legacy
hook entries in place (one `SessionStart` and one drift-check `Stop` entry of
ours afterwards, plus the state and ask guard entries added, the owner's hooks
and keys byte-exact), and allow rules naming
`mcp__watchtower-project__…` are only counted for a suggestion, never
rewritten.

**Why locked:** The workbench folder is the owner's repository. An installer
that dropped one of the owner's settings keys or hooks, or clobbered an edited
skill, would make every later `integrate` a risk to the owner's own setup.

**Test guards:**
- `internal/devpack/workbench_settings_test.go::TestProj04_InstallKeepsOwnerSettingsKeysAndHooks`
- `internal/devpack/workbench_settings_test.go::TestProj04_MalformedSettingsLeftByteIdentical`
- `internal/devpack/workbench_settings_test.go::TestProj04_RemoveDeletesOnlyOurHook`
- `internal/devpack/workbench_test.go::TestProj04_EditedProjectSkillIsNeverClobbered`
- `internal/devpack/workbench_stop_hook_test.go::TestProj04_StopHookKeepsOwnerStopHooksAndRemovesOnlyOurs`
- `internal/devpack/workbench_stop_hook_test.go::TestProj04_MalformedStopLeavesTheFileByteIdentical`
- `internal/devpack/workbench_settings_test.go::TestProj04_RemoveLeavingNothingThroughASymlinkEmptiesTheTarget`
- `internal/devpack/workbench_legacy_test.go::TestProj04_ResyncKeepsAnEditedLegacySkill` (an edited legacy skill and its sidecar stay byte-identical, reported `drifted`, its exclude line kept; a later removal keeps it too)
- `internal/devpack/workbench_state_hooks_test.go::TestProj04_StateHooksKeepOwnerHooksAndKeys` (the owner's own entries under the state events — a matcher, `async`, unknown keys and number literals — stay as they were next to exactly one entry of ours; remove takes only ours)
- `internal/devpack/workbench_state_hooks_test.go::TestProj04_MalformedStateEventLeavesTheFileByteIdentical` (each state event of the wrong type leaves the file byte-identical)
- `internal/devpack/workbench_ask_guard_test.go::TestProj04_AskGuardReplacesOurEditedPromptAndKeepsOwnerHooks` (our edited prompt entry is set back in place with the owner's keys on it kept; the owner's `Stop` and `PreToolUse` hooks stay)
- `internal/devpack/workbench_ask_guard_test.go::TestProj04_MalformedPreToolUseLeavesTheFileByteIdentical`
- supporting: `internal/devpack/workbench_ask_guard_test.go::TestAskToolBlock_InAnotherMatcherGroupIsRepaired` (our entry under `""`, `"*"`, no matcher or `Bash` counts as missing and moves back to its own group, the owner's hooks there kept)

**Locked since:** 2026-09-29

## PROJ-05 — a workbench parent's status never lags its children

**Status:** Enforced (Go and Desktop — one implementation, in SQLite)

**Observable:** When a workbench target (`project_id` set) is inserted,
deleted, or changes `status`, `parent_id` or `project_id`, its parent's
status is re-derived from the parent's direct children of the same workbench
(closed = `done`|`dismissed`): all closed with at least one `done` → `done`;
all `dismissed` → `dismissed`; every open child
`blocked` → `blocked`; any child `in_progress`, `in_review` or `done` →
`in_progress` (`in_review` since `00086`);
otherwise → `todo`; no children → untouched. The change walks up the ancestor
chain and stops at the first ancestor whose status does not change, and
below any `dismissed` ancestor — a dismissed parent is never re-derived, and
nothing above it moves because of that change. A status
set on a parent itself stands until one of its children changes — the
parent's own update is never rolled up, and an ancestor none of whose
children changed keeps its status. `updated_at` moves only with a real
status change. A non-workbench target, and a row of another workbench, is never
read as a child nor written. The rule is migration `00085`'s triggers
(`targets_project_status_rollup_{ai,au,ad}`), so every writer — the Go
MCP/CLI and the Desktop's direct GRDB writes — gets it with no dual path, and
it does not depend on `PRAGMA recursive_triggers`. The migration re-derives
every existing board once, deepest parent first, without bumping
`updated_at` and leaving a dismissed or snoozed parent as it is. The `watchtower-workbench`
skill tells the agent never to set a parent's status. A change the rollup
makes is recorded in the status history (#119) with actor `system`.

**Why locked:** Owner decision (board target #124). Before the rollup a
parent kept whatever status someone last set — boards sat in `todo` while
half their children were done — and keeping it right fell to the agent,
which forgot. A parent status the owner cannot trust makes the board useless
at a glance.

**Test guards:**
- `internal/db/proj05_status_rollup_test.go::TestProj05_ProjectParentStatusFollowsChildren`
  (and the other `TestProj05_*` in that file: multi-level chain, override,
  insert/delete/move, non-workbench and other-workbench rows, `updated_at`,
  `recursive_triggers` on, workbench delete with a multi-level board)
- `internal/db/proj05_status_rollup_edges_test.go` — moves out of a parent that keeps children,
  a shared ancestor, a child leaving/joining the workbench, multi-row updates, deletes, a
  100-level chain, and `TestProj05_SwiftTestSchemaMirrorsTheTriggers` (the Swift test
  schema's copy of the triggers equals the migration's)
- `internal/db/project_status_rollup_migration_test.go::TestMigration00085_RecomputesExistingBoards`
- `WatchtowerDesktop/Tests/Core/WorkbenchStatusRollupTests.swift::testGRDBChildStatusUpdateRollsTheChainUp`
- `WatchtowerDesktop/Tests/WorkbenchBoardViewModelTests.swift::testStatusWriteReportsTheParentsTheRollupMoved`
  (parents the rollup moved in an owner's write count as the owner's writes — no "done" notice)

**Locked since:** 2026-09-30

## PROJ-06 — every workbench target status transition is recorded with time and actor

**Status:** Enforced (Go and Desktop — one implementation, in SQLite)

**Observable:** A workbench target (`project_id` set) can be `in_review`
between `in_progress` and `done`; a personal target never can (`CHECK(status
!= 'in_review' OR project_id IS NOT NULL)`, migration `00086`). Every workbench
target's creation and every change of its status — by any writer: the
agent's `watchtower mcp --workbench N` tools, the CLI, the Desktop's direct
GRDB writes, the PROJ-05 rollup — adds exactly one `target_status_history`
row `{target_id, from_status (NULL at creation), to_status, changed_at (UTC
ISO-8601), actor}`, written by the triggers `targets_status_history_{ai,au}`,
never by application code. `actor` is what the write claimed in
`targets.status_actor` in the same statement — `agent` (the workbench MCP
tools), `owner` (the Desktop's `TargetQueries`/`DayPlanQueries` status
writers) or `system` (the rollup triggers, the daemon's unsnooze, the Jira status sync) — and `owner` when nothing was
claimed (every automated writer of a workbench target claims its actor, so an
unclaimed write comes from an owner-facing surface such as the CLI). A claim
never outlives its own write: the history trigger clears it, and
`targets_status_actor_reset_au` clears a claim that produced no row. A
personal target gets no history rows; a status write that does not change
the status adds none; the rows go with their target (`ON DELETE CASCADE`).
None of these triggers touches `updated_at`, so the next-step attempt budget
sees no extra churn. Existing workbench targets were seeded with one `system`
row dated by their `updated_at`. Readers: `get_target` in a workbench session
(`status_history`, newest 50, oldest first), `workbench_board`/`workbench
board`/`workbench brief` (the time a target has held its status, from its
latest row). A target that joins a workbench later has no history until its
next status change (the board then shows its bare status).

**Why locked:** Owner decision (board target #119): the owner wants to see
where each piece of work is — including what is under review — and how long
each stage took. A history that one writer skips (a Desktop edit, a rollup)
would silently misreport the time spent, so it lives in triggers with no
dual path.

**Test guards:**
- `internal/db/proj06_status_history_test.go::TestProj06_EveryProjectStatusTransitionIsRecorded`
  (and the other `TestProj06_*`: no-change writes, personal targets, the
  `in_review` CHECK, the cascade, `recursive_triggers` on)
- `internal/db/target_in_review_migration_test.go::TestMigration00086_RebuildKeepsRowsChildrenIndexesAndRollup`
- `internal/tools/workbenches_test.go::TestUpdateTarget_InReviewIsRecordedAsTheAgentsAndShown`
- `WatchtowerDesktop/Tests/Core/TargetStatusHistoryTests.swift::testDesktopStatusWritesAreRecordedAsTheOwners`

**Locked since:** 2026-09-30

## PROJ-07 — board drift is surfaced, and the Stop hook never traps a turn

**Status:** Enforced (Go; the Desktop shows the same check)

**Observable:** A workbench target may carry a git `branch` and a pull request
`pr` (migration `00089`; set by `create_targets`/`update_target`; one token,
never starting with `-`; a branch is the plain local name — no `origin/` or
`refs/` prefix, no revision syntax). `watchtower workbench check --workbench N
[--json] [--stale-days D] [--no-network]` (`internal/workbenchcheck`,
mechanical, no AI) reads the board and the workbench folder's git state and
never writes — no DB row, no ref, no object, only read-only git subcommands,
and no git process at all outside a repository (`gitbin.InsideRepository`).
git is the binary `internal/gitbin` locates (PROJ-10's lookup) — never a PATH
lookup on darwin, never the `/usr/bin/git` xcrun shim — and runs with the
inherited repository variables dropped (`gitbin.Exec`). With no git found the
check runs no git, reports `git:false` with the note "git is not available
(no Command Line Tools); branch checks skipped" and gives no branch finding;
it runs no gh either (gh reads the repository through the git on its own
PATH — the shim), noting "git is not available; pull request states not
checked" — never an install dialog. Kinds:
- `merged_but_open` — an open target's branch is in `origin/<default>` or
  `<default>`: a merge commit; a fast-forward (a local branch counts only if
  its reflog shows its tip committed on the branch, so a branch just cut,
  rebased or reset — even onto merged work — is not "merged"; a merge commit
  counts for a local branch only once a commit was ever made on it); every commit already there by patch id
  (`git cherry`: a rebase merge); or its whole diff matching one commit the
  default branch gained since the fork (a squash, newest 200). With gh, a
  merged PR. A parent's fix points at its sub-targets (PROJ-05).
- `done_but_unmerged` — a target done in the last 14 days whose branch has
  commits the default branch lacks (or whose PR is open), unless an open
  target still carries the same branch or PR (a finished plan task of
  unfinished work).
- `branch_missing` — an in-progress/in-review target's branch is found
  neither locally nor on origin.
- `pr_closed_unmerged` (gh only), and `stale` — an in-progress leaf with no
  status change, edit or branch commit for D days (default 3).

A git call that fails (anything but "no such ref") gives no finding, and a
check cut short by its deadline reports `incomplete` and never a finding from
a cut-short target. The `Stop` hook (`workbench check --workbench N
--stop-hook`, installed next to the `SessionStart` hook) reads Claude Code's
input, runs offline (no gh) with an 8 s budget for its git work (the
database open is never cut off by that budget — it may be applying a
migration; only Claude Code's own 15 s hook timeout bounds it), and prints
`{"decision":"block","reason":…}` listing only the certain kinds —
`merged_but_open`, `branch_missing`, `pr_closed_unmerged`; never `stale` or
the offline guess `done_but_unmerged` — and only when `stop_hook_active` is
false, so it blocks at most once per stop and a turn can never loop on it. It
always exits 0, a panic included; stdout stays empty on every failure, and a
real failure (bad id, no config, a missing folder, time ran out) is one
stderr line, while a deleted workbench's leftover hook says nothing at all.
`workbench brief` shows every finding (offline, 4 s budget), and so does the
Desktop board: `WorkbenchesViewModel.refreshDrift` runs `workbench check --json
--no-network` when the Board pane appears, on the owner's Refresh, and every
30 s while the pane polls, and `WorkbenchDriftBanner` lists the findings (a
failed or partial check is shown as such, never as "in step") — the Desktop decodes, never
re-derives them (`WorkbenchDriftReport`). `integrate status --json` reports
`stop_hook`, and a workbench without it is offered Repair.

**Note (2026-10-03, PROJ-11):** when `WATCHTOWER_TERMINAL_SESSION_ID` is set
and the workbench's folder has the session state hooks, the Stop hook also
records the session's agent state (`waiting`) after its drift decision —
never when it blocks the stop, and also on the `stop_hook_active` path. A
folder without them (or with a malformed settings file) gets no write and
no stderr line: nothing there records `working`, so a `waiting` would stick.
The gate reads the settings file at each Stop, not the hook set the running
session loaded. The write runs after the drift output is encoded, under its
own 1 s busy timeout, and its failure is one stderr line; stdout
(the block JSON or nothing) and exit 0 are unchanged in every case. Without
the variable the hook does exactly what it did before (no DB open on the
`stop_hook_active` path). The three guards below run unchanged.

**Why locked:** Owner request (board target #131). The agent finished and
merged work but never moved its targets, so a board that looks alive lied
about what was done; the product, not the agent's memory, must catch that.
A hook that could loop a turn, fail a turn, or cry drift on a guess or a
timeout would be worse than none.

**Test guards:**
- `cmd/workbench_check_test.go::TestProj07_StopHookBlocksOnceWithTheDrift`
- `cmd/workbench_check_test.go::TestProj07_StopHookIsSilentWithoutGitDrift`
- `cmd/workbench_check_test.go::TestProj07_StopHookFailuresAreSilent`
- `WatchtowerDesktop/Tests/WorkbenchesViewModelDriftTests.swift`, `WatchtowerDesktop/Tests/Core/WorkbenchDriftReportTests.swift`, `WatchtowerDesktop/Tests/WorkbenchCLITests.swift::testMissingStopHookNeedsRepair`
- `cmd/workbench_brief_test.go::TestProj07_BriefSaysWhenTheDriftCheckWasPartial`
- `internal/workbenchcheck/check_test.go` — `TestProj07_UnresolvableDefaultBranchIsANote`, `TestProj07_GitRules`, `TestProj07_SharedBranchAndParents`, `TestProj07_GitErrorsAreNeverFindings`, `TestProj07_NoGitCallOutsideARepository`, `TestProj07_ReadsNothingButGit`, `TestProj07_DeadlineReportsIncompleteNeverFalseFindings`, `TestProj07_MidWalkDeadlineKeepsEarlierFindingsOnly`, `TestProj07_GitUnavailableIsANote`

**Locked since:** 2026-10-01

## PROJ-08 — a workbench's documents are searchable only from its own sessions

**Status:** Enforced (amended 2026-10-03 — the folder's text files instead of attached documents)

**Observable:** Every `.md`/`.markdown`/`.txt` file of the workbench folder
that git does not ignore (or, outside a git repository, that the walk keeps),
at most 2000 per workbench, is indexed into the knowledge index as source
`project_doc` (`internal/kb/source_workbench.go` over the shared file-set
mechanism `internal/kb/fileset.go`; key `wbdoc:<project_id>:<rel_path>`,
anchor `project_id`, `rel_path`; sections split at `#`–`###` headings, the
heading as `chunk_anchor`). The listing is `workbenchdocs.ListTextFiles`:
inside a repository `git ls-files -z --cached --others --exclude-standard`
(through `internal/workbenchgit`'s environment rules, 5 s budget), otherwise
a walk that never follows a symlink; both skip the Files tree's hidden names
(`.git`, `.build`, `node_modules`, `.claude/worktrees`, …) and the installed
skill directories (`.claude/skills/watchtower-workbench`,
`.claude/skills/watchtower-project`), list only regular files, and keep the
2000 newest by mtime (the cut is logged). A failed git run is an error for
that pass — logged, the workbench's existing entries kept — never an empty
set. They are visible only to a search or an open made in
that workbench's own session — `watchtower mcp --workbench N`, whose
`tools.Binding.WorkbenchID` is N. `kb.Search` (`Request.WorkbenchID`),
`kb.GetDocument` (`DocOptions.WorkbenchID`) and `kb.Recent` apply one SQL
condition (`workbenchDocVisible`, `internal/kb/search.go`) on every call, so
the default — WorkbenchID 0, i.e. the main AI Chat, every Discuss chat, `kb
search`, the Confluence title lookup, `get_task_context` and any other
caller — sees no workbench file at all; `search_knowledge` asked for
`sources: ["project_doc"]` outside a workbench session is refused (not an
empty result), and another workbench's session sees only its own. An open of
a hidden document reads as "not found", the same as a missing one. Deleting
the workbench deletes its index entries in the same transaction (PROJ-02).

Indexing is mechanical (no AI, KB-02): the daemon's knowledge phase lists
each workbench folder and re-renders a file whose mtime differs from the
indexed one (any direction), hash-gated; a file that left the listing
(deleted, or now ignored) loses its entry. It never reads a folder under
`~/Documents`, `~/Desktop`, `~/Downloads`, `~/Library/CloudStorage`,
`~/Library/Mobile Documents` or `/Volumes` (case-insensitive; a background
read there could raise a macOS privacy prompt attributed to Watchtower, and
a dead network mount could block it) — it neither lists such a folder nor
drops its entries — and it never follows a symlink out of
a workbench folder (`resolveInside` refuses each step before touching it).
Those workbenches are indexed only by an explicit trigger —
`kb.IndexWorkbenchDocs`, run by `kb reindex` (owner-started; it re-indexes
every workbench so a rebuild loses nothing, one failing folder never stopping
the others) and, when `knowledge.enabled` is on, by `workbench resync`
(Re-run Setup) and the owner's `workbench create` — best-effort: a failure
there is a stderr warning (`create`) or the `index_ok`/`index_error` report
(`resync`), the workbench stands — and the agent's `ask_owner` with a
`doc_path` indexes that one file (`kb.IndexFileSet`, best-effort, a failure
is the result's `index_warning`). An explicit trigger renders every listed
file, gated only by its content hash (an edit in the same second as the last
index is never missed), and drops the entries of files that left the
listing; only the daemon pass is mtime-gated. A file that is not a regular
file (never opened blocking) or no longer resolves inside the folder
(symlinks followed inside it only) is indexed by its title only, its
anchor's `unreadable` saying why; a file over 2 MiB is indexed up to that,
its anchor's `truncated` saying so.

**Why locked:** Owner decision (board target #89): workbench files are
working material of one workbench and its coding agent; they must not leak
into the owner's general assistant or another workbench — the PROJ-01 spirit
applied to search.

**Test guards:**
- `internal/kb/source_workbench_test.go::TestProj08_FolderFilesOnlyInTheirOwnWorkbenchSession`
- `internal/tools/workbench_knowledge_test.go::TestProj08_KnowledgeToolsShowFolderFilesOnlyToTheirWorkbench`
- `internal/db/workbenches_test.go::TestProj02_DeleteProjectLeavesNoRows` (the index entries go with the workbench)
- `cmd/workbench_test.go::TestProj08_ResyncAndCreateIndexTheFolderAtOnce` (renamed in place from `TestProj08_OwnerAttachPathsIndexTheDocumentsAtOnce`: create and resync index unattached files at once, visible only in the workbench's session; a daemon pass never reads the `~/Documents` fixture folder and keeps what create indexed)
- `cmd/workbench_test.go::TestProj08_IndexFailureIsAWarningNotAnError`
- supporting: `TestWorkbenchDoc_GitIgnoredFilesAreNotIndexed`, `TestWorkbenchDoc_IndexesTheNewest2000`, `TestWorkbenchDoc_FailingGitKeepsTheEntries`, `TestWorkbenchDoc_DaemonSkipsProtectedFoldersExplicitIndexDoesNot` (`internal/kb`); `TestListTextFiles_GitListsTrackedAndUntrackedButNotIgnored`, `TestListTextFiles_GitSkipsTheHiddenNamesTooEvenWhenNotIgnored`, `TestListTextFiles_FailingGitIsAnError` (`internal/workbenchdocs`)

**Locked since:** 2026-10-01

## PROJ-09 — a target moves only within its own workbench, never into a cycle

**Status:** Enforced (Go and Desktop — a dual path)

**Observable:** A workbench target can be moved under another target of the
same workbench, or to the top level: the agent's `update_target` with
`parent_id` (`0` = top level), and the Desktop board's drag of a list row
onto another row or its card menu's **Move to** / **Move to Top Level**. A
move is refused — and writes nothing — when the new parent is the target
itself or one of its sub-targets at any depth (`db.ErrParentCycle` / Swift
`TargetParentCycleError`), and when the target or the new parent is
on another workbench, on the personal board or missing
(`db.ErrNotInWorkbench` / `.wrongWorkbench`); `update_target` refuses both in
its Scope, before any write, and the write re-checks them in its
transaction. A move to the parent the target already has writes nothing. A
move re-derives the status of both the old and the new parent chain through
the PROJ-05 triggers (recorded as `system` in the status history, PROJ-06) and
recomputes both parents' progress. The generic reparent — `watchtower targets
update --parent` (`db.UpdateTarget`) and the Desktop's Suggest Links
(`TargetQueries.updateParent`) — refuses a cycle too, checked only when the
parent changes (in Go before the write, outside a transaction, so a
concurrent move is not serialised against it). The rule lives in Go `db.MoveWorkbenchTargetTx` and Swift
`WorkbenchQueries.moveTarget`, which are kept in step by name.

**Why locked:** Owner request (board target #186): related tickets must be
groupable on the board after they were filed. A cycle would hide a subtree
from every board reader, and a cross-workbench parent would break PROJ-01's
separation of boards.

**Test guards:**
- `internal/db/proj09_move_test.go` — `TestProj09_MoveReRollsBothParentsStatusAndProgress`,
  `TestProj09_MoveToTheTopLevel`, `TestProj09_MoveRefusesACycle`,
  `TestProj09_MoveRefusesAnotherBoard`, `TestProj09_UnchangedParentWritesNothing`,
  `TestProj09_UpdateTargetRefusesACycle`, `TestProj09_CycleCheckEndsOnAnExistingCycle`
- `internal/tools/workbench_targets_move_test.go` — `TestProj09_UpdateTargetMovesUnderAParentAndToTheTopLevel`,
  `TestProj09_UpdateTargetRefusesACycleAndOtherBoards`
- `WatchtowerDesktop/Tests/Core/WorkbenchMoveTargetTests.swift` — the `testProj09_*` Desktop twins (`testProj09_UpdateParentRefusesACycle` for Suggest Links)
- `WatchtowerDesktop/Tests/WorkbenchBoardViewModelTests.swift::testMoveReportsBothRolledUpParentsAndExpandsTheNewOne`
  (both rolled-up parents count as the owner's writes)

**Locked since:** 2026-10-02

## PROJ-10 — a branch switch from the header never loses work, never runs unconfirmed, never pops the install dialog

**Status:** Enforced (Go and Desktop; the rule lives in Go; owner approved 2026-10-03)

**Observable:** Branch switching from the Workbench header never loses work,
never switches without the owner's confirmation, and never runs git where it
could pop the developer-tools install dialog. The branch button and popover
never run git in the Desktop: every branch read and write is `watchtower
workbench git status|branches|switch|create --workbench N --json`
(`cmd/workbench_git.go`, `internal/workbenchgit`). Known exception outside the
branch UI: the code viewer's FILES git marks (`CodeFilesCenter.refreshGit` →
`GitStatusSnapshot.read`, WatchtowerCore) run `git status` from the Desktop.
That reader never runs the `/usr/bin/git` shim either (`MemoryVaultGit.gitPath`:
the active developer directory's git, the Command Line Tools', Homebrew's), but
it spawns `xcode-select -p` to find the developer directory and has no
outside-a-repository pre-check, so the "no stray process" bullet below is Go's
rule, not the marks reader's.
- **The code viewer's edits are on disk first.** Before every `switch` (the
  first try and a confirmed resend; not `create`, which swaps no files) the
  Desktop pulls the editor page's unsent edits and saves every dirty buffer of
  the workbench or of any workbench inside the repository's work tree, so Go's
  dirty check sees them and a stash takes them. A buffer whose edits cannot be
  written (a conflict, a deleted or unreadable file, a write error) holds the
  switch in the Desktop — "Save or discard the edits in <file> first — they
  are not on disk yet." — and nothing is sent to Go. Unlike a close or a
  rename, an editor page that fails to hand over its unsent edits, or does
  not answer within 2 s, holds the switch too ("The editor did not hand over
  its latest edits — try again."; nothing sent); edits it hands over later
  still reach their buffers.
- **No shim, no stray process.** git is located by `internal/gitbin` without
  spawning anything (`$DEVELOPER_DIR`, the `xcode_select_link` target, the
  Command Line Tools, Xcode.app, Homebrew) and is never `/usr/bin/git` — the
  xcrun shim — nor a PATH lookup on darwin, nor a candidate symlinked to the
  shim. No git found → `git_available:false`, no git process, and the header
  shows no branch button (no install dialog, ever). No git process runs in a
  folder outside a repository (`gitbin.InsideRepository` first).
- **Guards before any write, in order:** status readable → an exact local
  branch name (option-like names never match) → not already on it → not
  checked out in another worktree → no merge/rebase/cherry-pick/revert/bisect
  in progress and no unmerged paths → the owner's confirmations. A refusal is
  final (no flag overrides it); a missing confirmation returns
  `needs_confirmation` (`uncommitted_changes` without `--stash`,
  `agent_running` without `--confirm-agent`) and writes nothing.
- **Confirmation comes from the owner.** The Desktop's first `switch` carries
  no confirmation flag; it resends `--stash`/`--confirm-agent` only after the
  owner chose the dialog's primary button, with exactly the flags that dialog
  named; Cancel sends nothing. `--agent-running` is the Desktop's fact (a
  live embedded Claude Code session of the workbench, or one whose folder is
  in the repository's work tree), re-read on every resend, so a session
  started after the owner confirmed a stash is asked about again; a
  confirmation the app does not understand is never sent back as confirmed.
- **Work is never lost.** Uncommitted changes (untracked included) are only
  ever moved into a stash entry with a nonce-tagged message
  (`watchtower: switching from <cur> to <B> [<nonce>]`), found afterwards by
  that exact message — never the stack's tip, which another worktree or
  session may own — and applied back by its sha (`stash apply --index`) when
  the switch fails without moving HEAD. The entry is never popped or dropped,
  and the switch is `git switch --no-guess --no-overwrite-ignore`: no force,
  discard, reset, clean or checkout ever runs, and an ignored file the target
  branch tracks is never overwritten. A switch that failed after HEAD moved
  (a failing hook) counts as switched and leaves the stash alone. The
  envelope names the entry and its sha, and the Desktop shows the
  `git stash apply <sha>` that brings it back.

**Why locked:** Owner request (board target #233). Switching branches swaps
every file in the folder: done silently it can bury the owner's edits or pull
the files out from under a working agent, and the shared stash stack makes a
naive `stash pop` take another session's work. On a Mac without the
developer tools, a single `/usr/bin/git` call raises a system install dialog
attributed to Watchtower.

**Test guards:**
- `internal/workbenchgit/switch_test.go` — `TestProj10_RefusesDirtyWithoutStash`,
  `TestProj10_RefusesAgentRunningWithoutConfirm`, `TestProj10_ListsBothConfirmations`,
  `TestProj10_StashAndSwitch`, `TestProj10_ConfirmedAgentSwitches`,
  `TestProj10_CheckedOutElsewhereIsRefusedWithAllFlags`, `TestProj10_UnknownOrOptionLikeBranchIsRefused`,
  `TestProj10_OperationInProgressIsRefused`, `TestProj10_FailedSwitchRestoresTheStash`,
  `TestProj10_AlreadyOnBranchIsANoOp`, `TestProj10_DetachedSwitchesAwayWithTheDirtyGuard`,
  `TestProj10_NoGitIsRefused`, `TestProj10_NeverForcesOrDiscards`, `TestProj10_CreateCarriesTheChanges`,
  `TestProj10_CreateRefusesAnExistingBranch`, `TestProj10_CreateRefusesAnInvalidName`,
  `TestProj10_FailedSwitchLeavesAForeignStashAlone`, `TestProj10_FailedSwitchRestoresOursPastAConcurrentStash`,
  `TestProj10_FailedStashPushReportsTheStashItMade`, `TestProj10_FailingHookAfterTheSwitchCountsAsSwitched`,
  `TestProj10_SwitchNeverOverwritesAnIgnoredFile`, `TestProj10_GitFailureIsRefusedAsGitFailed`,
  `TestProj10_CanceledSwitchStillReadsTheStatusAfter`, `TestProj10_CheckRefFormatFailureIsNotAnInvalidName`
- `internal/gitbin/gitbin_test.go` — `TestLocate_DarwinOrder`, `TestLocate_NeverTheShim`,
  `TestLocate_NoneFound`, `TestInsideRepository`
- `internal/workbenchgit/status_test.go` — `TestReadStatus_NoGitOutsideARepository`,
  `TestReadStatus_GitUnavailableRunsNothing`, `TestReadStatus_RunsTheLocatedBinary`,
  `TestReadStatus_IgnoresInheritedRepositoryEnvironment`
- `WatchtowerDesktop/Tests/WorkbenchesViewModelGitTests.swift` — `testProj10_ADirtyRefusalWaitsForTheOwnerWithNoSecondCall`,
  `testProj10_ConfirmResendsWithStash`, `testProj10_CancelClearsThePendingSwitchWithNoCall`,
  `testProj10_TheShownConfirmationGoesThroughAfterTheDialogClearedIt`, `testProj10_ALiveSessionIsReportedAndItsConfirmationResent`,
  `testProj10_ASessionStartedAfterAStashConfirmationIsAskedAbout`, `testProj10_ASessionThatExitedBeforeTheConfirmationIsNotReported`,
  `testProj10_ASessionAtTheRepositoryRootOfASubfolderWorkbenchIsReported`, `testProj10_APendingConfirmationIsDroppedWhenTheBranchMoved`,
  `testProj10_APendingConfirmationIsDroppedOnceTheFolderIsOnItsBranch`, `testProj10_NoGitHidesTheButton`,
  `testProj10_TheStashNoteStaysUntilDismissedOrReplaced`, `testProj10_ASwitchFirstSavesTheCodeViewersEdits`,
  `testProj10_AnEditThatCannotBeSavedHoldsTheSwitch`, `testProj10_NoUnsavedEditsInTheWorkTreeLeaveTheSwitchAsItWas`,
  `testProj10_AnEditorThatDoesNotAnswerHoldsTheSwitch`, `testProj10_AnEditorThatTimesOutHoldsTheSwitch`
- `WatchtowerDesktop/Tests/Core/WorkbenchGitDecodingTests.swift::testProj10_UnknownConfirmationsAreKeptApart`

**Locked since:** 2026-10-03 (proposed 2026-10-02)

## PROJ-11 — session state hooks never steer Claude Code and never show a stale state (v1 limits below)

**Status:** Enforced (Go and Desktop; owner approved 2026-10-03; amended 2026-10-03 to the session report's state set, owner-approved in the states brainstorm, and 2026-10-04 to the turn order of board #368, see the changelog)

**Observable:** `workbench session-state --workbench N` (installed async,
`"timeout": 5`, under `UserPromptSubmit`, `Notification`, `PostToolUse` and
`StopFailure`) and the Stop hook's state write (PROJ-07 note) never print to
stdout, never exit non-zero, never block or delay a prompt (async entries),
and do nothing without `WATCHTOWER_TERMINAL_SESSION_ID` (stdin unread). They
write only workbench N's `claude` row whose stored `claude_session_id` equals
the payload's `session_id` (a nested `claude -p` that inherited the variable
never moves the row), never replace a newer state with an older one (an
event time not later than the stored `agent_state_at` writes nothing), and
never rewrite an unchanged state. Since 2026-10-04 (board #368) a turn's
Stop and its main-thread tool results are ordered by the turn, not by when
their hook processes started: the Stop hook records the transcript's size
(`agent_turn_end`) before its drift check and again with its `waiting` (also
over a stored `waiting`), and a conversation switch drops it with the old
transcript; a main-thread `PostToolUse` whose `tool_use_id`
the transcript places before it writes nothing, and its write lands only
while the turn end it checked still holds; the Stop's `waiting` replaces a
`working` a main-thread `PostToolUse` wrote (`agent_tool_run`) even when
stamped later, keeping the later `agent_state_at`. A prompt's, a
notification's or a subagent's state keeps the time order (owner decision,
ask #20: a granted subagent shows working), and a tool call the transcript
cannot place falls back to it. The Desktop shows a stored hook state only
for the process run it was written in (the row is live and `agent_state_at`
is not earlier than that run's start, `SessionAgentStatus.effective`).

Since 2026-10-03 (the session report's state set, spec
`2026-10-03-workbench-session-report-design.md` Part 4b): the stored
`waiting` means the turn is over and shows **Stopped** (grey), never
"waiting for you". "Waiting for you" (orange) comes only from an open ask of
the session (`owner_asks.session_id`, `status = 'open'`) or a permission
dialog (`approval`, **Needs approval**). A StopFailure stores `waiting` with
`agent_failed_at` (= that write's `agent_state_at`) and `agent_error` (the
payload's top-level `error`, one line, ≤ 60 runes; `''` when missing) and
shows **Error** (red). `finish_session` stores `finished_at`/`finish_summary`
and shows **Finished** (blue, orange while the session has open asks)
whether or not the session runs. A write that changes the state into
`working` (a UserPromptSubmit, or a PostToolUse out of waiting or approval:
a turn the agent started itself is a new turn) clears `finished_at` and the
error in the same statement (`finish_summary` is kept); a `working` over a
stored `working` clears `finished_at` only for a UserPromptSubmit, never for
a PostToolUse (that is `finish_session`'s own turn); an
`approval` write and the SessionStart clear of a new run also clear the
error, while a plain `waiting` (the `idle_prompt` notice, the Stop hook)
over a failed one writes nothing, so the error stays until the owner acts;
a StopFailure with another error replaces the stored one and its time.
The order is: approval > error > working > finished > open ask > stopped >
running > not started, the first match winning. The hook states (approval,
error, working, stopped) stay run-scoped; finished and the open asks are
not, so a session that is not live shows them as a ring in their colour.
`SessionAgentNoticePolicy` announces each transition of a live session into
needs approval, error, stopped or finished at most once, only while the app
is inactive; waiting on an ask, or working with asks, gets no state notice
(the ask's own notice announced it).

**Why locked:** Owner decisions of board #312 (2026-10-03), and the states
brainstorm of the session report (1a, 2a, 3a, 4: all). A status hook that
injected text into the agent, blocked a prompt, or showed a state for a dead
session would be worse than none; and "waiting for you" on every turn end
cried wolf — the owner must be able to trust that orange means their move.

**Test guards:**
- `cmd/workbench_session_state_test.go::TestProj11_HookNeverWritesStdoutAndExitsZero`
- `cmd/workbench_session_state_test.go::TestProj11_NestedSessionNeverMovesTheRow`
- `internal/db/terminal_sessions_test.go::TestProj11_OlderEventNeverOverwritesANewerState`
- `WatchtowerDesktop/Tests/Core/SessionAgentStatusTests.swift::testProj11_StateFromAnEarlierRunIsIgnored`
- `WatchtowerDesktop/Tests/Core/SessionAgentNoticePolicyTests.swift::testProj11_OneNoticePerTransition` (a turn end is announced as "stopped")
- `WatchtowerDesktop/Tests/Core/SessionAgentStatusTests.swift::testProj11_StateOrder` (a table over the eight kinds in the order above, live and not live)
- `WatchtowerDesktop/Tests/Core/SessionAgentStatusTests.swift::testProj11_TurnEndWithoutAskIsStoppedNotWaiting`
- `internal/db/session_report_test.go::TestProj11_WorkingClearsFinishedAndError`
- `internal/db/session_report_test.go::TestProj11_WorkingOverWorkingClearsFinished` and `cmd/workbench_session_state_test.go::TestProj11_WorkingOverWorkingClearsFinished` (finish, an Esc interrupt and a new prompt: the UserPromptSubmit's `working` over `working` clears `finished_at`; a plain `working` repeat stays a no-op)
- `internal/db/session_report_test.go::TestProj11_ToolRunWorkingOverWorkingKeepsFinished` and `cmd/workbench_session_state_test.go::TestProj11_PostToolUseOverWorkingKeepsFinished` (finish, then a PostToolUse `working` over `working`: still finished)
- `internal/db/session_report_test.go::TestProj11_ToolRunOutOfWaitingClearsFinished` and `cmd/workbench_session_state_test.go::TestProj11_PostToolUseIntoWorkingClearsFinished` (finish, then Stop (`waiting`) or a permission prompt (`approval`), then a main-thread PostToolUse `working`: cleared; the hook half also pins that a subagent's PostToolUse over `waiting` writes nothing and keeps `finished_at`)
- `internal/db/session_report_test.go::TestProj11_StopFailureRecordsErrorOtherWritesClearIt` (db half: a later plain `waiting` keeps the error, a StopFailure with another error replaces it at its own time, `working`/`approval` clear it)
- `cmd/workbench_session_state_test.go::TestProj11_StopFailureRecordsErrorOtherWritesClearIt` (hook half: the payload's `error` field, a repeated StopFailure keeps its time and another error replaces it, a missing or non-string one stored as `''`, clipped to 60 runes on one line)
- `cmd/workbench_session_state_test.go::TestProj11_EndedTurnsToolResultNeverOverwritesTheStop` (board #368: the ended turn's tool result whose hook starts after the Stop's leaves `waiting`; a later self-started turn's first tool result still records `working`)
- `cmd/workbench_session_state_test.go::TestProj11_StopReplacesItsTurnsLateToolResult` (board #368: the ended turn's tool result landing first with a later stamp is replaced by the Stop's `waiting`, the stored time never goes back; a subagent's `working` keeps the time order)

**Locked since:** 2026-10-03

## PROJ-12 — an ask's answer is submitted only into a session whose hooks reported this run, never into a permission prompt they reported nor over the owner's half-typed text

**Status:** Enforced (Go and Desktop; owner approved 2026-10-03 as the spec's "PROJ-11", renumbered because PROJ-11 was taken by the session state hooks; amended 2026-10-04 with the owner's approval, board #379 — the owner asked for the answer to go to the agent by itself after answering an ask instead of having to press Enter, see the changelog)

**Observable:** When the owner answers an ask in the Desktop, the answer is
stored first — one guarded `UPDATE owner_asks SET status='answered', answer,
answered_at … WHERE status='open'` (`OwnerAskQueries.answer`; zero rows means
the agent withdrew or superseded it meanwhile: nothing is written or typed,
the draft is kept) — and only then is anything typed. The typed text is
exactly the fixed line `Ask #<id> answered (<kind>: <short>) — read it with
get_ask <id> using the watchtower-workbench skill.` (Swift `OwnerAskPrompt`, a
dual path with Go `asks.DeliveryLine` pinned by `internal/asks/testdata/lines`;
every control character and newline becomes a space), sent to the ask's own
running session through `TerminalCenter.submitPrompt` as one bracketed paste
with no line break or control character inside it, followed after
`answerSubmitDelay` (500 ms) by one Return written on its own — so Claude
Code submits it (while the agent works, Claude Code queues it). The Return
follows only when, both before the pause and after it (the states re-read):
both reads succeeded (`SessionAgentStateCenter.poll` returns whether it
did; after a failed read the last good state vouches for nothing — a
failed read before the paste holds the line, see below), the
session's hooks wrote a state during its current run
(`SessionAgentStatus.at`; no hooks, or none written yet, means the app
cannot tell a permission prompt is on screen), that state is not
`needsApproval`, and the session's Claude Code prompt held no text not
submitted (`TerminalCenter.promptDrafts`): nothing the owner typed since
their last submitting Return — only input ending in a plain CR not right
after ESC, whose last printable input before it (escape sequences and paste
brackets skipped) is not `\`, submits; Claude Code's line-break keys (`\`
then Return, Option+Return as ESC CR, Ctrl+J as LF, Shift+Return as an
escape sequence) and anything else leave a draft — and no earlier line the app pasted there without its Return (an
answer or a hand-off left typed). Keys sent while the session shows
`needsApproval` answer the dialog and change nothing. Otherwise the line is
only pasted, the session's prompt counts as holding a draft until the
owner's submitting Return (or the process's start or close), and a bar over
the terminal says to press Return. Nothing is typed while the session's
agent waits on a permission prompt (`needsApproval`, PROJ-11, re-read right
before the paste), or while that re-read fails (the last good state may
miss a prompt shown since): the line is held in memory and goes on the
first read of the states that succeeds and shows no prompt
(`SessionAgentStateCenter.onChange`/`onRead` →
`OwnerAsksViewModel.deliverHeldAnswers`), under the same Return rules;
it is never sent on a timer — after a minute held (`stillHeldAfter`) its
bar says it is still waiting and that Dismiss sends it through the
session's brief instead. Nor is anything typed while another answer's line
is going to that session (paste, pause, Return): that line is queued, with
its own note, and goes right after. Deliveries to one session run one at a
time and a line left without its Return keeps the next from submitting, so
two answers never share a prompt. A held or queued line whose session
stopped or started a new run meanwhile goes nowhere, and the held bar's
Dismiss cancels it — the brief lists those answers. Without bracketed paste
the line is copied, not typed, and no Return is sent. An ask with no session, or whose
session is not running, gets nothing typed: the session's next `workbench
brief` lists it under "Answered asks for you" (its own session's,
session-less and gone-session asks; the section keeps at least its first row
at the 4000-rune cap and never marks anything delivered). `delivered` is set
only by `get_ask` reading the answer (guarded `WHERE status='answered'`); a
line Claude Code never acted on (held when the app quit or dismissed,
copied and never pasted, typed and never submitted) leaves the ask
`answered`, so the next brief still lists it.

**Why locked:** Owner decisions (spec 2026-10-03, decision 3; board #379,
2026-10-04). An automatic Return could confirm whatever Claude Code's TUI
shows at that moment without the owner seeing it: a permission dialog's
default — hence the hold, the re-read before the paste and after the pause,
a Return only where the hooks vouch for the state this run, and no
keystrokes without bracketed paste — or a half-typed prompt, which it would
submit together with the answer — hence no Return over the owner's draft.
Two lines pasted into one prompt would be submitted as one message — hence
one delivery per session at a time. A line with a line break of its own
could submit early or split; and a line typed before the answer is stored
would send the agent to read an answer that is not there — the
`WorkbenchCommentPrompt` rule carried over to asks.

**Test guards:**
- `WatchtowerDesktop/Tests/OwnerAsksViewModelTests.swift::testProj12_TheAnswerIsStoredBeforeTheLineIsTypedThenSubmitted` (a probed process reads the DB at input time; one bracketed paste with no control byte inside, then Return alone), `testProj12_ASessionAtAPermissionPromptGetsTheLineOnlyAfterTheAnswer` (nothing typed or copied while held, delivered once after), `testProj12_OverTheOwnersHalfTypedTextTheLineIsOnlyPasted` (at once and after a hold; a dialog key is no draft), `testProj12_WithoutAHookStateThisRunTheLineIsOnlyPasted`, `testAPermissionPromptDuringThePauseLeavesTheLineTyped` (a line left typed keeps the next answer from submitting it, through a dialog key), `testAHandOffLeftWithoutItsReturnKeepsTheAnswerFromSubmittingIt`, `testAFailedStateReadAfterThePauseLeavesTheLineTyped`, `testAFailedStateReadBeforeThePasteHoldsTheLine`, `testALongHeldAnswerSaysItStillWaitsAndIsNeverSentOnATimer`
- `internal/asks/line_test.go::TestDeliveryLineFixtures`, `internal/asks/line_test.go::TestDeliveryLineIsOneLine`
- `WatchtowerDesktop/Tests/Core/OwnerAskPromptTests.swift` (`testTheLineMatchesEveryGoFixture`, `testTheLineIsOneLineWithNoControlCharacters`)
- `WatchtowerDesktop/Tests/TerminalCenterTests.swift` (`testAnAnswerLineIsPastedAsOneLineThenSubmittedWithItsOwnReturn` — the Return strictly after the pause, `testOverTheOwnersDraftSubmitPromptOnlyPastes`, `testTheOwnerTypingDuringThePauseStopsTheReturn`, `testALineLeftWithoutItsReturnKeepsTheNextFromSubmittingIt`, `testClaudeCodeLineBreakKeysLeaveTheDraft`, `testAFailedRefreshAfterThePauseStopsTheReturn`, `testWithoutBracketedPasteTheLineIsCopiedNotTyped`, `testAHandOffWithoutBracketedPasteIsCopiedAndNotSubmitted`)
- `WatchtowerDesktop/Tests/CodeNav/CodeHandoffCenterTests.swift` (`testAFailedStateReadAfterTheAnswersPauseLeavesTheLineTyped`, `testAnAnswerIntoASessionWithOnlyAnEarlierRunsStateIsOnlyPasted` — the wiring through a real `SessionAgentStateCenter`)
- `WatchtowerDesktop/Tests/Core/OwnerAskQueriesTests.swift` (`testAnsweringAnAskWithdrawnMeanwhileThrowsNotOpenAndWritesNothing`)
- `cmd/workbench_brief_test.go::TestProj12_AnsweredAskSurvivesAFullBoard`
- supporting: `OwnerAsksViewModelTests` (`testCopiedShowsTheCopiedAnswerHint` — no keystroke and no Return without bracketed paste; `testAPermissionPromptDuringThePauseLeavesTheLineTyped`; `testAHeldAnswerGoesNowhereOnceItsSessionStops`, `testAHeldAnswerNeverReachesALaterRunOfItsSession`, `testTwoHeldAnswersToOneSessionGoOneAfterTheOther`, `testAnAnswerDuringAnotherAnswersPauseIsQueuedThenGoesNext`, `testDismissingAHeldAnswerCancelsItsDelivery`, `testAfterTheOwnersReturnOrADialogKeyTheLineIsSubmitted`, `testAHoldThatEndedBeforeTheWaitIsNotMarkedStillWaiting`); `TerminalCenterTests::testATypedAnswerHintStaysThroughKeysIntoAPermissionDialog`; `CodeHandoffCenterTests::testAnAnswerIntoASessionWaitingThisRunIsSubmitted`; `TerminalOwnerInputTests::testOnlyTheOwnersInputIsReported` (the owner's bytes, never the app's paste); `SessionAgentStateCenterTests::testAnAnswerHeldAtAPermissionPromptGoesOnTheReadThatShowsItAnswered` (the wiring through the stored states); `cmd/workbench_brief_test.go::TestProjectBrief_AnsweredAsksForItsSession` (own and session-less listed, another session's counted, nothing delivered by the brief); `internal/tools/workbench_asks_test.go::TestGetAsk_OpenAnsweredAndAnotherWorkbench` (only `get_ask` delivers)

**Locked since:** 2026-10-03

## PROJ-13 — the ask guard never traps a turn

**Status:** Enforced (Go; owner approved 2026-10-03 as the spec's "PROJ-12", renumbered; the pass clause reworded during implementation; amended 2026-10-03 with the `finish_session` reminder (prompt v2), see the changelog)

**Observable:** The `Stop` prompt hook (`type: prompt`, `timeout: 30`,
`internal/devpack/askguard_prompt.md`, pinned by a golden) tells the model to
return `{"ok": true}` when `stop_hook_active` is true, or when
`last_assistant_message` says it filed an ask (for example names
`ask #<number>` — Claude Code's Stop input has no `tool_calls`, and the skill
has the agent name every ask it filed in its final text), or when the message
asks the owner for nothing; it blocks only a message that clearly waits on
the owner, and passes when unsure. Since 2026-10-03 the prompt is v2 (spec
`2026-10-03-workbench-session-report-design.md` Part 5): after the request
check it also blocks, once, a message that reports the session's work
complete and does not say it called `finish_session` (for example "session
finished"); a progress report, a pause for an answer or a partial result is
not complete, and the first failure is the one returned. The pass rules —
`stop_hook_active`, when unsure — are unchanged. `integrate`/`resync` set
every prompt entry carrying our marker, the v1 text or an edit of it, to v2
(the PROJ-04 rule for our edited prompt; another workbench's marker is left
as it is). The intent is one nudge per stop: the
prompt tells the model to pass when `stop_hook_active` is set (pinned by the
golden; the model's compliance is not something a test can check). The
`PreToolUse` command hook (`workbench ask-guard --workbench N
--pre-tool-use`, matcher `AskUserQuestion`, `timeout: 5`) prints the deny
decision only when workbench N exists and its stdin (read for at most 0.5 s)
names `tool_name` `AskUserQuestion`; on any failure — another tool,
unreadable, empty or never-closed input, a bad or unknown id, a deleted
workbench, a broken config, a missing or locked database, a panic — it
prints nothing on stdout or stderr and exits 0, so the tool runs. It opens
the database with `db.OpenExisting` (never creates it, never migrates,
`query_only`, a 500 ms busy timeout), so it finishes in under 2 s.

**Why locked:** Owner decision (spec 2026-10-03, decision 3) and the PROJ-07
precedent: a guard that could loop a turn, fail a turn, or block a tool
because Watchtower is broken would be worse than none.

**Test guards:**
- `internal/devpack/workbench_ask_guard_test.go::TestProj13_AskGuardPromptPassesAContinuedTurnAndAFiledAsk` (the golden — the v2 text since 2026-10-03 — carries both pass clauses)
- `internal/devpack/workbench_ask_guard_test.go::TestProj13_V1PromptIsUpgradedToV2` (the v1 text and an edit of it both become v2; another workbench's v1 prompt stays; a second resync changes nothing)
- `cmd/workbench_askguard_test.go::TestProj13_AskGuardFailurePrintsNothingAndExitsZero`
- `cmd/workbench_askguard_test.go::TestProj13_AskGuardFinishesFastOnALockedDatabase`
- `cmd/workbench_askguard_test.go::TestProj13_AskGuardWithNoDatabaseCreatesNothing`
- `cmd/workbench_askguard_test.go::TestProj13_AskGuardNeverRunsAMigration`
- supporting: `cmd/workbench_askguard_test.go::TestAskGuard_DeniesAskUserQuestionInALiveWorkbench`, `cmd/integrate_workbench_test.go::TestIntegrateWorkbenchStatusJSON_AskGuardKeys`

**Locked since:** 2026-10-03

## PROJ-14 — a session report shows only that session's work, and only the session itself says it finished

**Status:** Enforced (Go; owner approved 2026-10-03, spec `docs/superpowers/specs/2026-10-03-workbench-session-report-design.md` Part 8)

**Observable:** A `terminal_session_targets` link row comes only from that
session's own workbench tools: `update_target`, `create_targets`,
`add_comment` (a reply links its root's target), `ask_owner` and
`finish_session` (its `target_id`) link after their own write succeeded, and
only for the session `tools.terminalSessionOf` resolves from
`WATCHTOWER_TERMINAL_SESSION_ID` — a row of the same workbench; no variable,
an unknown id or another workbench's id links nothing. Read tools never
link. A failed link is one stderr line plus `session_link_warning` in the
result and never fails or undoes the tool. `finished_at` is written only by
`finish_session` (refused with `finish_session needs a Watchtower terminal
session`, before any row or audit row, when no session of the workbench
resolves) and cleared only by a `working` state write (PROJ-11). The report
(`internal/sessionreport` `Build`/`Summaries`, `workbench session-report`)
reads the DB and the PR cache; its refresh writes only `workbench_pr_states`.
It never writes a target, a status or a comment, so PROJ-07's drift check
stays the only place that flags `merged_but_open`.

**Why locked:** Owner decision (spec 2026-10-03, decision 4). A report that
listed another session's work, or a session marked finished by anything but
its own agent, would make the owner trust a summary that is not this
session's; a report that wrote the board would move statuses behind the
owner's and the agent's backs.

**Test guards:**
- `internal/tools/workbench_finish_test.go::TestProj14_OnlyOwnSessionWritesLink` (no variable, an unknown id, garbage, a negative id and another workbench's session: no link from any write tool)
- `internal/tools/workbench_finish_test.go::TestProj14_FinishNeedsATerminalSession` (another workbench's session is never marked; no audit row, no link)
- `internal/sessionreport/report_test.go::TestProj14_ReportNeverWritesTheBoard`
- supporting: `internal/tools/workbench_finish_test.go` (`TestSessionLinks_EachWriteToolLinksItsTargets`, `TestSessionLinks_ReadToolsLinkNothing`, `TestSessionLinks_AFailedLinkKeepsTheWriteAndWarns`, `TestSessionLinks_LegacyBindingLinksTheSame`)

**Locked since:** 2026-10-03

## PROJ-15 — an archived workbench target is hidden, never lost

**Status:** Enforced (Go and Desktop; owner approved 2026-10-04, ask #33, spec `docs/superpowers/specs/2026-10-04-workbench-board-archive-design.md` §3)

**Observable:** A workbench target is archived iff its workbench's
`projects.archive_after_days` (migration `00103`, default 14, `CHECK` 0..365,
0 = never) is above 0, it and every descendant on the same board are `done`
or `dismissed`, and the newest close time among them (a target's latest
`target_status_history.changed_at`, else its `updated_at`) is more than
`archive_after_days` days old. The rule lives only in the SQLite view
`workbench_target_archive`, read by Go (`GetWorkbenchBoard`,
`IsWorkbenchTargetArchived`, `GetTargets` in a workbench session) and the
Desktop (`WorkbenchQueries.board`) alike. Archiving writes nothing — no
target, status, `updated_at` or history row, on any read. Every archived
target is still found by id (`get_target`, which answers `archived: true`)
and by search (the Desktop board search always matches archived targets;
`include_archived` on `workbench_board` and `list_targets`, `workbench board
--archived`). Reopening restores it: any open status write (the Desktop, or
`update_target`), an open sub-target created under an archived group, or
open work re-parented under one (PROJ-09) takes it out of the archive on the
next read, with the status change recorded like any other (PROJ-06). A group
is archived only whole: a target with an open descendant, or whose subtree
closed last less than `archive_after_days` days ago, is never archived, and an
archived target's whole subtree is archived. The drift check never skips an
archived target: `workbench check`, the brief's drift section and the Desktop
banner read the full board, so a `done_but_unmerged` finding on an archived
target is reported exactly as on a visible one (PROJ-07 unchanged in
wording).

**Why locked:** Owner request (board target #301, ask #33). A long board
must get short without losing anything: work that vanished, could not be
looked up again, came back only through a special action, broke a group
apart or hid a branch that never merged would make the board lie in the
other direction.

**Test guards:**
- `internal/db/proj15_board_archive_test.go` — `TestProj15_ClosedLeafArchivedAfterNDays`, `TestProj15_OpenStatusesAreNeverArchived`, `TestProj15_UmbrellaArchivedOnlyWhole`, `TestProj15_GroupWaitsForItsLastClose`, `TestProj15_HandSetDoneParentWithOpenChildIsNotArchived`, `TestProj15_ReopenRestores`, `TestProj15_ReparentOpenWorkUnderArchivedGroupRestoresIt`, `TestProj15_OpenSubTargetUnderArchivedGroupRestoresIt`, `TestProj15_ArchiveWritesNothing`, `TestProj15_PerWorkbenchSettingAndNever`, `TestProj15_ArchiveDaysOutOfRangeAreRefused`, `TestProj15_CloseTimeFallsBackToUpdatedAt`, `TestProj15_UnparseableCloseTimeKeepsTheChain`, `TestProj15_ReopenAndRecloseStartsThePeriodOver`, `TestProj15_LargeBoardReadIsFast`
- `cmd/workbench_archive_test.go::TestProj15_DriftStillSeesArchivedUnmergedWork`
- `internal/tools/workbench_board_archive_test.go` — `TestGetTarget_FindsAnArchivedTargetAndSaysSo`, `TestUpdateTarget_ReopeningRestoresAnArchivedTarget`, `TestCreateTargets_UnderAnArchivedParentBringsItBack`, `TestListTargets_ArchivedOnlyWithIncludeArchived`, `TestListTargets_IncludeArchivedWithoutStatusListsArchivedTargets`, `TestWorkbenchBoard_ArchivedSubtreesOnlyOnRequest`
- `WatchtowerDesktop/Tests/Core/WorkbenchQueriesTests.swift::testBoardMarksArchivedTargetsFromTheViewAndKeepsThemInTheTree`, `WatchtowerDesktop/Tests/Core/WorkbenchBoardOutlineTests.swift::testSearchAlwaysMatchesArchivedTargets`, `WatchtowerDesktop/Tests/Core/WorkbenchBoardKanbanTests.swift::testSearchShowsArchivedLeaves`, `WatchtowerDesktop/Tests/WorkbenchBoardViewModelTests.swift::testArchivedTargetsShowOnlyWithTheToggleAndReopeningRestoresOne`
- supporting: `internal/db/proj15_board_archive_test.go` (`TestWithoutArchived_CountsArchivedChildren`, `TestWithoutArchived_EmptyAndAllArchived`, `TestGetTargets_WorkbenchLeavesArchivedOut`, `TestMigration00103_DefaultsToFourteen`), `internal/tools/workbench_board_archive_test.go` (`TestBuildBoardView_*`, `TestWorkbenchInfo_CountsTheWholeBoardAndTheArchived`, `TestWorkbenchBoard_LongMostlyClosedBoardStaysSmall`), `cmd/workbench_archive_test.go` (`TestRenderProjectBrief_ArchivedLeaveTheCountsAndAreCounted`, `TestWorkbenchBoardCmd_ArchivedOnlyWithTheFlag`, `TestWorkbenchBoardCmd_AllArchivedRootsAreCounted`, `TestWorkbenchShowCmd_PrintsTheArchiveSetting`), `internal/sessionreport/report_test.go::TestBuild_KeepsArchivedTargetsTheSessionClosed`, `WatchtowerDesktop/Tests/Core/WorkbenchBoardKanbanTests.swift` (`testArchivedCardCountIsTheArchivedLeavesUnderTheFilter`), `WatchtowerDesktop/Tests/WorkbenchBoardViewModelTests.swift` (`testTheArchiveCountFollowsTheMode`)

**Locked since:** 2026-10-04

## v1 limits and notes (accepted)

- **Status rollup bounds (PROJ-05).** The ancestor walk stops after 256
  levels, and a `parent_id` cycle (no writer creates one, nothing forbids
  it) is skipped by the one-time recompute and, when a member changes, ends
  with its members sharing whatever status the walk reached. A full-row write
  of a parent loaded before a child changed (`db.UpdateTarget` with a stale
  struct) puts the old status back as if set explicitly; the next child
  change re-derives it. A `snoozed` child counts as not started, and the live
  rule re-derives a snoozed parent (leaving `snooze_until` set; nothing
  snoozes a workbench target today). A parent the rollup dismissed (all its
  children dismissed) stays dismissed even if a child is reopened later —
  dismissed is terminal for the rollup (owner decision 2026-09-30); set it
  back by hand. A parent status the rollup replaces gets no board marker;
  #119's status history records rollup changes with actor `system`.

- **TCC attribution (owner decision 2026-09-30).** A workbench folder under a
  TCC-protected location (`~/Documents`, `~/Desktop`, `~/Downloads`, cloud
  drives under `~/Library/CloudStorage`) can make macOS show a privacy prompt
  attributed to Watchtower, because the Desktop reads the folder (the FILES
  tree, the Files pane) and launches `claude` from its own process. Accepted for the POC — the Desktop
  warns at create; the real fix (read and launch outside the app process) is a
  follow-up before any non-dogfood use.
- **Full read tool set in a workbench session.** `watchtower mcp --workbench N`
  mounts every read tool plain `watchtower mcp` does, and
  `get_today_briefing` includes the WORKBENCHES block of every workbench. DEV-06's
  scoping is a guardrail on Watchtower's own tools only — the agent runs as the
  owner with a shell, so Claude Code's own permission prompt is the real
  boundary.
- **Target images (board target #117).** (a) *TCC:* the agent may name an
  image anywhere on disk; when its Claude Code session runs in the Desktop's
  embedded terminal, reading a file under `~/Desktop`, `~/Documents` or
  `~/Downloads` (where macOS saves screenshots) is attributed to Watchtower
  and may show a privacy prompt — the same class as the TCC note above, now
  reachable from an image path rather than only the workbench folder. A denied
  read is refused with the OS cause and a hint to copy the file elsewhere.
  Accepted by the owner 2026-10-01 as a known v1 limit: on a denied read
  the agent asks the owner to copy the file elsewhere. (b) *Concurrent sessions:* a failed write discards only
  the copies it created, but a detach in one session — or a failed write
  whose fresh copy another session reused for the same content in the
  meantime — can remove a copy the other session has not yet committed a row
  for (no multi-agent locking); that row then names a missing file, which the
  Desktop shows as "Missing". (c) Stored paths are absolute: after the data
  directory moves, cleanup leaves the old copies behind (it never touches a
  path outside the current store). (d) A session still connected during
  `workbench delete` can re-create an empty `project_files/<id>/`.
- **Audit rows outlive their workbench.** `agent_actions` rows with
  `context_type='project'` are kept after a workbench delete as audit history
  and are never shown on the Inbox action strip.
- **An owner reply reopens a closed thread.** New-for-agent reads only open
  threads, so an owner reply under a `resolved` or `outdated` root reopens
  that root in the same write (Go `AddWorkbenchCommentTx` ↔ Swift
  `WorkbenchQueries.reply`); otherwise the reply would silently never reach
  the agent. An agent reply never reopens a thread. (Comments are on targets
  only since 2026-10-03; the document re-anchoring that could mark a root
  `outdated` is gone with attached documents.)

- **Board language is advisory.** It is an instruction to the agent (brief, `workbench_info`, skill) — always the session's language — never enforced on a write: a target written in another language is accepted, and nothing already on the board is translated.

- **Owner asks (2026-10-03, PROJ-12/13).** (a) The `Stop` prompt hook costs
  one fast-model call per agent stop of a workbench session (about 1–2 s);
  it may miss a plain-text request (told to pass when unsure), and an agent
  that filed an ask without naming it gets one extra nudge (then
  the prompt tells it to pass on `stop_hook_active`). (b) After a stop the ask guard blocks, the
  session's PROJ-11 state reads Stopped (and may post its "stopped" notice
  while the app is inactive) until the nudged turn's first tool result — or
  Waiting for you once the nudged agent files the ask, Finished once it calls
  `finish_session`: the drift `Stop` hook runs in parallel and records
  `waiting` whenever it lets the turn end, and the next main-thread
  `PostToolUse` records `working` (board #367). (Until 2026-10-03 this read
  "waiting for you"; the session report's state set answered the owner's
  #323 question.) (c) A `claude` in an
  external terminal files session-less asks, delivered by the brief only;
  a nested `claude -p` that inherited `WATCHTOWER_TERMINAL_SESSION_ID` files
  as its session. (d) Codex-run sessions get the ask tools but no hooks.
  (e) Margin comments anchor on the ask's snapshot, never on the live file; a
  later round is a new ask. (f) The delivery line always names the
  `watchtower-workbench` skill, so a pre-rename folder reads a skill name it
  lacks until Re-run Setup. (g) Without git installed, a folder inside a
  repository is listed by the walk, which knows no ignore rules; the daemon's
  mtime gate is whole seconds, so an edit in the same second as its last
  render waits for the next change or an explicit trigger. (h) Since
  2026-10-04 (board #379) the answer's Return trusts the hook state of the
  current run: a session with none (a folder without the session state
  hooks, or no hook written yet this run) only gets the paste. Not seen, so
  the Return goes there: a permission prompt whose async hook write has not
  landed by the re-read after the 500 ms pause, and a TUI dialog the hooks
  do not report (not a permission prompt). A permission prompt declined or
  dismissed with Esc writes no hook, so `approval` stays until the next one
  (the owner's next prompt, or Claude Code's idle notice about a minute
  later): a held answer waits that long — never sent on a timer; after a
  minute its bar says it is still waiting and that Dismiss sends it through
  the session's brief instead. The prompt's draft is tracked from the
  owner's keystrokes and the app's own pastes only, and errs toward a draft.
  The rule: input submits only when it ends in a CR that does not directly
  follow ESC and the last printable byte the owner typed or pasted before
  that CR (escape sequences — cursor keys, paste brackets — skipped, across
  earlier inputs) is not `\`; every other input leaves a draft. So a draft
  cleared with Ctrl-C or Esc still counts and the next line is then only
  pasted. Keys typed while
  the app still shows `needsApproval` (the 1 s poll and the hook's latency
  after the dialog closes) count as the dialog's, so text typed in that
  second may be submitted with the answer. The 500 ms pause is a timing
  choice, checked by hand against Claude Code, not by a test.

- **Session agent state ordering and subagents (PROJ-11, board #367).**
  (a) Closed 2026-10-04 by board #368 (events of a turn are ordered by the
  turn, see PROJ-11). What still orders by hook-process start time: a tool
  call the transcript cannot place (no `tool_use_id`, an unreadable
  transcript, more than 16 MiB from the turn end on either side), and a
  turn that ended on a `StopFailure` (async, so it records no turn end); and
  an ended turn's tool result that lands before the Stop hook's first
  turn-end write (the Stop's database open) over `waiting` or `approval`
  clears `finished_at`, which the Stop's `waiting` does not restore.
  (b) A subagent's permission prompt (`Notification`) moves the
  row from `waiting` to `approval`, and after the grant the subagent's
  `PostToolUse` records `working` while the main turn is still stopped.
  (c) A turn started without a prompt whose first tool fails stays
  Stopped until a later tool succeeds: `PostToolUseFailure` is
  not hooked. (d) Subagent detection relies solely on the `agent_id` field
  of the hook input; an input without it is treated as the main thread's.

- **Board archive (PROJ-15).** SQLite cannot push a `project_id` filter
  into the recursive, grouped view, so every board read, `get_target` and
  session `list_targets` computes the archive over all workbench targets in
  the database, every workbench's (about 3 µs per target — fine at today's
  sizes; a 2000-target board is pinned by `TestProj15_LargeBoardReadIsFast`). Nothing is stored, so the Desktop
  board notices a target ageing into the archive only at its next reload
  (any board change, Refresh, reopening the pane), not at the exact minute.
  Restore is reopening: there is no Unarchive action (owner decision D),
  since a target taken out of the archive but still closed for longer than
  the setting would be archived again on the next read. The setting is the
  owner's (Desktop menu); the agent cannot change it. A close time that does
  not parse as a date (every writer stores ISO-8601 UTC, so none is known)
  keeps its target and every ancestor out of the archive, so an archived
  target's whole subtree stays archived (guard
  `TestProj15_UnparseableCloseTimeKeepsTheChain`).

## Changelog

- 2026-10-04 (board #380, PR #165, owner-approved in ask #41): **PROJ-12 tightened**; heading, wording and guards unchanged. An answer's Return is also withheld while another line into the same session is still in its pause before its own Return (`TerminalCenter.pendingReturns`): when a second line (an answer or a code hand-off) arrives during that pause, both lines are only pasted and neither is submitted, so one line never submits the other. While such shared text sits in the prompt (`sharedPrompts`, cleared with `promptDrafts` by the owner's submitting Return, the process's start or close) the bars say Return sends both lines together.
- 2026-10-04 (board #361, code navigation tails, owner-approved in ask #42): **PROJ-02 strengthened** — the delete also removes the workbench's code questions (they quote the folder's code and no surface listed them once the workbench was gone); `TestProj02_DeleteProjectLeavesNoRows` extended, none relaxed. Migration `00104` removes the ones earlier deletes left behind (ids are never reused, so a missing workbench id is a deleted one).
- 2026-10-04 (board #301, spec `docs/superpowers/specs/2026-10-04-workbench-board-archive-design.md`): **PROJ-15 added** — approved by the owner on 2026-10-04 (ask #33, owner decision C, the spec §3 wording): an archived workbench target is hidden, never lost. Migration `00103` adds `projects.archive_after_days` and the view `workbench_target_archive`; display readers prune archived subtrees (`db.WithoutArchived`), while the drift check, `workbench_info`'s status counts, the session report and the briefing keep the full board. Owner decision A: `workbench_board` by default lists open work and the closed targets above it, counting the rest (`closed_children`/`closed`, `archived_children`/`archived`), with `include_closed`/`include_archived` to list them. **PROJ-07** unchanged in wording and guards; its "the brief and the Desktop show every finding" now explicitly includes findings on archived targets (new guard `TestProj15_DriftStillSeesArchivedUnmergedWork`). PROJ-05, PROJ-06 (archiving writes no status and no history row; a restore is an ordinary status write), PROJ-01 and PROJ-09 unchanged; every existing guard runs unchanged. v1 note "Board archive" added.
- 2026-10-04 (PR #163 review round, controller decisions): **PROJ-12 tightened** to hold as written; heading and the "two answers never share a prompt" wording unchanged, no guard relaxed. A line the app pasted without its Return (an answer left typed, a hand-off left pasted) now counts as a draft in the session's prompt (`TerminalCenter.ownerDrafts` → `promptDrafts`), cleared by the owner's submitting Return or the process's start or close, never by keys into a permission dialog — before this, the next answer was submitted with it. A submitting Return is input ending in a plain CR not after `\` or ESC (`TerminalCenter.isSubmit`): Claude Code's line-break keys (`\` then Return, Option+Return, Ctrl+J, Shift+Return sequences) leave the draft. A Return needs both state reads to have succeeded (`SessionAgentStateCenter.poll` returns `Bool`; `refreshStates` and `submitPrompt`'s `refresh` too), and a failed read before the paste holds the answer until a read succeeds (`SessionAgentStateCenter.onRead`); a hand-off reads no state before its paste, so only its read after the pause gates its Return. The `\` rule skips escape sequences and paste brackets (`TerminalCenter.endsAfterBackslash`). A queued answer later held by a permission prompt is told by its own notice, so it gets the held bar and its minute's wait even when the earlier answer ended typed. A held answer is never sent on a timer; after `stillHeldAfter` (60 s) its bar reads "Still waiting for the permission prompt — Dismiss to send the answer through the session's brief instead". A line held only behind another answer to the same session is `queued`, with the note "Answer saved — sending after the previous answer". A key into a permission dialog no longer clears a typed answer's "press Return" bar. Limit (h) rewritten. New guards listed under PROJ-12; `testAPermissionPromptDuringThePauseLeavesTheLineTyped` strengthened (it now asserts the bar stays through a dialog key and a second answer is only pasted).
- 2026-10-04 (board #379, owner-approved): **PROJ-12 amended** — the owner asked for the answer to an ask to go to the agent by itself after answering, instead of having to press Enter. The answer's line (still stored first, still one line) is now pasted and submitted: `TerminalCenter.submitPrompt` (`keepingLineBreaks: false`) writes the bracketed paste, then one Return on its own after `answerSubmitDelay` (500 ms). The "Why locked" risk — a Return confirming a permission dialog's default — is met by the session agent state (PROJ-11): while the ask's session is `needsApproval` nothing is typed and the line is held in memory until a read of the states shows the prompt answered (a stopped or restarted session gets nothing; a quit leaves the ask `answered` for the brief); the state is re-read before the paste and after the pause, and a prompt that appears during the pause stops the Return. Without bracketed paste the line is still copied, never typed. The pane hint "press Return to send" (board #364) remains only for that pause race and the copied case; a held answer shows "Answer saved — it goes to Claude once the permission prompt is resolved", a submitted one "Answer sent to Claude". Guards renamed in place: `testProj12_TheAnswerIsStoredBeforeTheLineIsTypedAndNeverSubmitted` → `testProj12_TheAnswerIsStoredBeforeTheLineIsTypedThenSubmitted` (stored-before-typed and the one-line, no-control-byte paste kept, Return now asserted as a write of its own), `TerminalCenterTests::testARunningSessionGetsOneBracketedPasteWithNoEnter` leaves the PROJ-12 list (it now pins only `sendPrompt`, the paste step of `submitPrompt`, which has no other caller) for `testAnAnswerLineIsPastedAsOneLineThenSubmittedWithItsOwnReturn`; new `testProj12_ASessionAtAPermissionPromptGetsTheLineOnlyAfterTheAnswer`. Review round (same day, controller decisions): no Return over the owner's half-typed text (`TerminalCenter.ownerDrafts`, fed by `onOwnerInput` now carrying the bytes; the "half-typed prompt" risk is back in "Why locked"; this also covers a hand-off's Return), a Return only into a session whose hooks wrote a state this run, one delivery per session at a time, a 500 ms pause for answers (`answerSubmitDelay`; hand-offs keep 150 ms), and the held bar's Dismiss cancels the delivery (the brief lists the answer); new guards `testProj12_OverTheOwnersHalfTypedTextTheLineIsOnlyPasted`, `testProj12_WithoutAHookStateThisRunTheLineIsOnlyPasted`; limit (h) rewritten.
- 2026-10-04 (polish wave, owner-approved default): PROJ-11's heading gains "(v1 limits below)" — "never show a stale state" holds outside the time-ordered leftovers listed under "Session agent state ordering and subagents" in "v1 limits and notes". Wording only; no contract semantics or guard tests changed.
- 2026-10-04 (board #368, owner-approved target): **PROJ-11 amended** (strengthened) — a turn's Stop and its main-thread tool results are ordered by the turn, not by hook-process start time, closing v1 note (a) of "Session agent state ordering and subagents". Migration `00102` adds `terminal_sessions.agent_turn_end` (the transcript's size at the run's last Stop hook) and `agent_tool_run` (the stored state came from a main-thread `PostToolUse`), both Go-only. The Stop hook records the turn end before its drift check and with its `waiting`; a main-thread `PostToolUse` whose `tool_use_id` the transcript places before it writes nothing (`cmd/workbench_turn_order.go`, `toolCallTurn`); the Stop's `waiting` replaces a tool result's `working` stamped after it. Owner decision ask #20 unchanged: a subagent's tool result after a granted permission still records `working`, time-ordered. New guards `TestProj11_EndedTurnsToolResultNeverOverwritesTheStop` and `TestProj11_StopReplacesItsTurnsLateToolResult`; every existing guard runs unchanged (`TestProj11_OlderEventNeverOverwritesANewerState` holds for every write but the Stop's over a tool result's `working`). The note's narrower leftovers (unplaceable calls, StopFailure, `finished_at` in the Stop's first milliseconds) stay listed. PROJ-11's "never show a stale state" now holds outside those listed leftovers.
- 2026-10-03 (workbench session report, spec `docs/superpowers/specs/2026-10-03-workbench-session-report-design.md`, plan `docs/superpowers/plans/2026-10-03-workbench-session-report.md`). **Approved by the owner (the states brainstorm, asks #2 and #4):** migration `00101` adds `terminal_sessions.finished_at`/`finish_summary`/`agent_failed_at`/`agent_error`, `terminal_session_targets` and `workbench_pr_states`. **PROJ-11 amended** — the stored `waiting` now shows Stopped (grey), "waiting for you" comes only from an open ask or a permission dialog, a StopFailure records an error (red), `finish_session` marks Finished (blue; orange with open asks), any `working` write clears both; the state order is pinned. The existing guards that asserted `waiting` → "waiting for you" (orange) were rewritten to Stopped (grey) — the intended change, not a relaxation; the "a dead run's state never shows" assertions are unchanged (`testProj11_StateFromAnEarlierRunIsIgnored` gained an earlier run's error). New guards `testProj11_StateOrder`, `testProj11_TurnEndWithoutAskIsStoppedNotWaiting`, `TestProj11_WorkingClearsFinishedAndError` and `TestProj11_StopFailureRecordsErrorOtherWritesClearIt` (db and hook halves). **PROJ-13 amended** — the ask guard prompt is v2 with the `finish_session` reminder; its pass rules are unchanged; new guard `TestProj13_V1PromptIsUpgradedToV2`. **PROJ-14 added** — a session report shows only that session's work, and only the session itself says it finished. **PROJ-02 strengthened** — the delete also removes the session link rows and the PR cache (`TestProj02_DeleteProjectLeavesNoRows` extended). **Implementation rulings (spec Revision 3):** (1) a plain `waiting` over a failed one is a no-op, so the error clears only on `working`, `approval` or the SessionStart clear (spec Part 4 said "every other write clears"); (2) the spec's "an owner-edited prompt is kept and reported `drifted`" would have contradicted PROJ-04, which sets our edited prompt back — every marker prompt, v1 or edited, becomes v2 and PROJ-04 is unchanged (the planned guard name `TestProj13_V1PromptIsUpgradedEditedIsKept` became `TestProj13_V1PromptIsUpgradedToV2`). The owner-asks v1 note (b) now reads Stopped. PROJ-01, 03–10 and 12 unchanged; DEV-06 lists `finish_session` (`dev-surface.md`).
- 2026-10-03 (workbench owner asks, spec `docs/superpowers/specs/2026-10-03-workbench-owner-asks-design.md`, plan `docs/superpowers/plans/2026-10-03-workbench-owner-asks.md`). **Approved by the owner (§9, 2026-10-03):** attached documents, document comments and the Desktop Documents pane are replaced by **owner asks** (`owner_asks`, migration `00100`, which also drops `project_documents` and the document columns of `project_comments`). **PROJ-03 amended** — the document view and its comment re-anchoring are gone (the guard `testProj03DesktopNeverWritesTheDocument` went with `WorkbenchDocumentViewModelTests.swift`); the contract is the Files pane rule plus "no workbench tool writes the folder" (`ask_owner` only reads `doc_path`), new guard `TestProj03_AskOwnerNeverWritesTheFolder`; the Files pane guards are unchanged. **PROJ-08 amended** — "attached documents" becomes every `.md`/`.markdown`/`.txt` file of the folder git does not ignore (or the walk keeps outside git), ≤ 2000 per workbench; visibility, privacy, symlink, caps and PROJ-02 deletion unchanged. (Beyond §9, see the rulings below: explicit triggers render every file gated by content hash (only the daemon is mtime-gated), a file that left the listing loses its entry, the installed skill directories are skipped, and a privacy-protected folder is indexed only by an explicit trigger (`resync`, `create`, `kb reindex`, `ask_owner`'s one file.) Guards renamed in place, assertions kept: `TestProj08_ProjectDocsOnlyInTheirOwnProjectSession` → `TestProj08_FolderFilesOnlyInTheirOwnWorkbenchSession`, `TestProj08_KnowledgeToolsShowProjectDocsOnlyToTheirProject` → `TestProj08_KnowledgeToolsShowFolderFilesOnlyToTheirWorkbench`, `TestProj08_OwnerAttachPathsIndexTheDocumentsAtOnce` → `TestProj08_ResyncAndCreateIndexTheFolderAtOnce` (its "a dry run indexes nothing" step went with `import-docs` and became "a daemon pass never reads a protected folder"). **PROJ-12 added** (the spec's "PROJ-11", renumbered — PROJ-11 is the session state hooks): an ask reaches its session as typed text, never submitted. **PROJ-13 added** (the spec's "PROJ-12"): the ask guard never traps a turn. **PROJ-02** — asks join the cascaded rows and both ask guard hooks the removal (its guards extended, none relaxed); `TestProj02_DeletedProjectDocumentAndCommentIDsAreNeverReused` lost its document half with the table and is now `TestProj02_DeletedProjectAndCommentIDsAreNeverReused`. **Implementation rulings, pending owner confirmation:** (1) the PROJ-13 pass clause "tool_calls contains a call whose name ends with ask_owner" became "last_assistant_message says it filed an ask, e.g. names ask #<number>", since Claude Code's Stop input has no `tool_calls`; (2) the PROJ-08 extras in parentheses above; (3) **PROJ-04 reworded** (widened, no guard relaxed) — `Stop` now holds two entries of ours (the drift command and the ask guard prompt, recognised by its marker line) and `PreToolUse` is a newly owned event (matcher `AskUserQuestion`; malformed counts as a malformed file); new guards `TestProj04_AskGuardReplacesOurEditedPromptAndKeepsOwnerHooks`, `TestProj04_MalformedPreToolUseLeavesTheFileByteIdentical`; (4) `get_ask`'s unaudited `delivered` write, the AGENT-06 scope exception and DEV-06's ask session binding (`dev-surface.md`, `agent-actions.md`). The v1 note "Re-anchor hides an owner root" is retired with re-anchoring; owner-asks limits are added. PROJ-01, 05–07, 09–11 unchanged.
- 2026-10-03 (code navigation phase C, Task 11, ruling R47): **PROJ-03 amendment (owner-approved 2026-10-03)** — the Files pane's editor may also write text the owner explicitly applies from a code-question suggestion (Apply), through the same base-revision and conflict path as the owner's typed edits (spec §9.2). Apply is refused while the buffer has a `CodeFileBuffer.Problem` or when the selected text changed since the question (`CodeQuestionCenterTests.testApplyRefusedWhileTheBufferIsInConflict`, `testApplyRefusedWhenTheSelectedTextChanged`; the editor bridge harness's `applyEdit` checks). No guard test changed.
- 2026-10-03 (board #248, plan `docs/superpowers/plans/2026-10-02-workbench-git-branch.md` Task G1): **PROJ-07 amended** and **PROJ-10 approved**, both by the owner on 2026-10-03. `workbench check` now runs the git `internal/gitbin` locates (`ExecRunner` resolves `"git"` through `gitbin.Locate`; `insideRepository` is `gitbin.InsideRepository`) — never a PATH lookup on darwin, never the `/usr/bin/git` shim, closing the check's install-dialog hole; with no git found it runs no git and no gh (gh would run the shim itself), reports `git:false` and notes "git is not available (no Command Line Tools); branch checks skipped" (new guard `TestProj07_GitUnavailableIsANote`, offline and with network). The process runner of `internal/workbenchcheck` and `internal/workbenchgit` is consolidated into `gitbin.Exec`, so the check now also drops the inherited repository variables (`GIT_DIR`, `GIT_WORK_TREE`, …) and sets `GIT_EDITOR=true`, and `workbench git` now also sets `GH_PROMPT_DISABLED=1` (it runs no gh; harmless). This supersedes the 2026-10-02 (#233) entry's "PROJ-07 is unchanged: `workbench check` still runs `git` through PATH". PROJ-10 is now Enforced, locked 2026-10-03, wording unchanged. Every existing `TestProj07_*` and `TestProj10_*` guard runs unchanged.
- 2026-10-03 (board #340): Stop state write gated on the state hooks — the Stop hook records `waiting` only when the workbench's folder has the session state hooks (`devpack.HasStateHooks`), so a folder not yet repaired no longer shows "waiting for you" after its first turn. The PROJ-07 note's state write is narrowed to those folders (it writes in fewer cases, never more); PROJ-07's stdout/exit contract, PROJ-11 and every guard are unchanged.
- 2026-10-03 (board #367, owner approved): a main-thread `PostToolUse` records `working` from any state, not only from `approval` (a subagent's one, `agent_id` set, keeps the `approval`-only rule, so a subagent's tool result alone never ends the main turn's `waiting`; a subagent's permission prompt still can — see the v1 notes) — a turn started without a prompt (a teammate or background-task message, a wakeup) fires no `UserPromptSubmit`, so the stop's `waiting` stayed on screen while the agent worked. The older-event guard is unchanged: events are ordered by hook-process start time (`hookNow` at process start, in both the async `PostToolUse` hook and the sync `Stop` hook), so a `PostToolUse` whose process started before the `Stop` hook's writes nothing, but an async `PostToolUse` whose process starts after the `Stop` hook's can still overwrite `waiting` with `working` until the next stop (v1 note added); the owner-asks v1 note (b) is narrowed to "until the nudged turn's first tool result". PROJ-11's observable and every guard are unchanged.
- 2026-10-03 (board #312, plan `docs/superpowers/plans/2026-10-03-session-agent-state.md`): **PROJ-11** added and **PROJ-04** reworded, both approved by the owner on 2026-10-03 — Claude Code sessions in the Desktop's workbench terminal show working / waiting for you / needs approval from new async `workbench session-state` hook entries (`UserPromptSubmit`, `Notification`, `PostToolUse`, `StopFailure`; migration `00098`) and the extended Stop hook, with a macOS notice while the app is inactive. PROJ-04 now says one entry of ours per event we own, with a malformed state event counting as a malformed file (widened, no guard relaxed; two new guards). **PROJ-02** strengthened — remove/delete also take the state entries away (its hook guards extended). **PROJ-07** gains a note on the Stop hook's state write; its stdout/exit contract and guards are unchanged.
- 2026-10-02 (board #234, code viewer): **PROJ-03 amended** with the owner's approval — the Files pane may write the owner's own edits to any file of the folder, attached documents included, but never over a version it has not seen (a changed, deleted or unreadable disk version blocks the save until the owner picks Reload from disk or Keep mine; an edit typed on a stale disk revision is a conflict). New guards `testProj03FilesEditorNeverWritesOverANewerDiskVersion`, `testProj03AnEditTypedBeforeAReloadIsAConflictNotASave`, `testProj03ADeletionUnderEditsIsNeverUndoneByTheAutosave` and `testProj03AnUnreadableDiskVersionIsNeverWrittenOver`; the existing `testProj03DesktopNeverWritesTheDocument` (the document view writes nothing) is unchanged. PROJ-01/02/04..09 unchanged.
- 2026-10-02 (board target #233): **PROJ-10** proposed — pending owner approval — the Workbench header's git branch button and popover switch and create local branches through `watchtower workbench git status|branches|switch|create` (`internal/workbenchgit`, git located by `internal/gitbin`, never the `/usr/bin/git` shim); a switch never loses work (nonce-named stash found by its message and applied back by sha, never popped or dropped; no force/discard/reset/clean), never runs without the owner's confirmation of uncommitted changes or a live Claude Code session in the work tree, and no git runs without the developer tools or outside a repository. Guards listed under PROJ-10. PROJ-07 is unchanged: `workbench check` still runs `git` through PATH (moving it onto `gitbin` is a separate, owner-gated target). PROJ-01..09 unchanged.
- 2026-10-02 (board target #186): **PROJ-09** added — a workbench target can be re-parented within its workbench (`update_target`'s `parent_id`, the Desktop board's drag onto a row and **Move to…**), never into a cycle or across boards; `db.UpdateTarget` (`targets update --parent`) and Swift `TargetQueries.updateParent` refuse a cycle too. PROJ-05's rollup already covered a `parent_id` change; its wording and guards are unchanged. The `watchtower-workbench` skill now has the agent nest a new target under a topical group (creating the group if needed). PROJ-01..08 unchanged.
- 2026-10-02 (board target #207): the Desktop board shows each target's `#id` on list rows, kanban cards and the detail card (copy from the card menu or the detail chip) and gains a search field (`WorkbenchBoardSearch`: `#N` = that id only, a bare number = the id or a title/intent containing it, other text = title/intent; matches keep their ancestors and subtrees, include closed targets and ignore collapse). Read-only UI over existing rows; no contract semantics or guard tests changed.
- 2026-10-02 (Workbench rename, spec `docs/superpowers/specs/2026-10-02-workbench-rename-design.md`, owner decisions O1–O8): the feature is renamed from Projects to **Workbench** and this file moves from `docs/inventory/projects.md` to `docs/inventory/workbench.md`. PROJ-01..08 are reworded to the new names with the **same ids and the same meaning** (rewording approved by the owner, O2); every guard keeps its test function name (`TestProjNN_…`/`testProjNN_…`, A4) and only its file path changed (`project*`/`Project*` test files → `workbench*`/`Workbench*`; the migration tests keep theirs). Storage and wire keep `project` (tables, columns, DB values, `project_doc`, `project_files/`, `projects.*` UserDefaults keys, CLI `--json` keys). **PROJ-02 strengthened:** removal and delete also take away a never-resynced folder's legacy hooks, skill, `watchtower-project` registration and exclude lines — new guard `TestProj02_RemoveLegacyFolderLeavesNothingInstalled`. **PROJ-04 strengthened:** a resync deletes the legacy `watchtower-project` skill only through the DEV-04 marker/digest rule and replaces only our own legacy hook entries; an edited legacy skill is kept byte-identical with its exclude line — new guard `TestProj04_ResyncKeepsAnEditedLegacySkill`. Guard assertions whose expected literal said "project" (for example "workbench N no longer exists") were updated to the new wording with the same strictness. The entries below are historical and keep the names of their date (A11).

- 2026-10-01 (board item #181): project documents render tables as one paragraph per cell and a rule as a blank line (they were `a | b` rows and `———`); `CommentAnchor.locate` gains a last tier that reads those legacy separators (` | `, `———`, and for a `table` artifact its CSV commas) in a stored quote and its context as the new line breaks, and accepts a match only where real stored context still surrounds it, so comments made on the old rendering keep their passage instead of turning `outdated`. PROJ-03 unchanged — the same passage is found, look-alike text elsewhere is not (`testTheLegacyTierNeedsTheOriginalContext`); no guard test changed.
- 2026-10-01 (board target #192, release audit): **PROJ-07 strengthened** — the session brief says when its drift check was cut short or its branch checks could not run (no default branch resolves), so a partial check never reads as a clean board ("a failed or partial check is shown as such" now holds for the brief too); `project check` adds a note when the default branch named by `origin/HEAD` no longer resolves. The brief also frames the recent-in-sources titles as other people's words — data, not instructions. New guards `TestProj07_BriefSaysWhenTheDriftCheckWasPartial`, `TestProj07_UnresolvableDefaultBranchIsANote`. Also: the agent's `attach_document` matches an attached `rel_path` ignoring case (as the import and the owner attach do) and reports the stored spelling.
- 2026-10-01 (board target #192, release audit): **PROJ-04 strengthened** — a remove that leaves a symlinked `settings.local.json` empty writes `{}` to the link's target instead of deleting the link (which left our hooks in the dotfiles target); new guard `TestProj04_RemoveLeavingNothingThroughASymlinkEmptiesTheTarget`.
- 2026-10-01 (board target #192, release audit): **PROJ-07 strengthened** — squash detection compares zero-context patch ids (`git diff -U0`, `git log -p -U0`), so a squash is recognised even when main changed a line next to the branch's hunks (the documented limit stays: a diff changed in conflict resolution); `TestProj07_GitRules` gains that case for an open and a done target.
- 2026-10-01 (board target #192, release audit): **PROJ-08 strengthened** — `project create`, `import-docs` and `attach-doc` now index the project's documents themselves (best-effort, when `knowledge.enabled` is on), so a project in a folder the daemon never reads (~/Documents, ~/Desktop, …) has its owner-attached and imported documents searchable at once; `create --json` and `attach-doc --json` carry the outcome as `index_ok`/`index_error`/`index_skipped` (resync's names); new guards `TestProj08_ResyncAndCreateIndexTheFolderAtOnce`, `TestProj08_IndexFailureIsAWarningNotAnError`.
- 2026-10-01 (board item #153): the per-project board-language override (#122) is retired — the board always follows the session language. `watchtower project update`, `update_project`'s `board_language` (an unknown field again; `description` is required again), the Desktop menu and the `terminal title` override are removed; `tools.BoardLanguageLine` is a constant. The `projects.board_language` column (00087) stays, unread. No contract semantics or guard tests changed.
- 2026-10-01 (board item #105): specs, plans and designs are review documents in the project's Documents pane (not chat artifacts). The `watchtower-project` skill requires attaching every one the agent writes and setting its review target `in_review` (the feature target for a spec on a feature without sub-targets, else a `Review: <title>` sub-target — always for a plan) until the owner approves. The Desktop marks an agent document whose target is `in_review` **In review** (`ProjectDocumentListItem.awaitingReview`) and the existing "ready for review" notification also fires when such a target enters review, titled "awaits your review" and keyed by the revision so attaching and marking never notify twice; an owner's own move to `in_review` (the latest `target_status_history` row is theirs) is not announced back, and a snapshot persisted before this change reads as "review unknown" so an upgrade never re-announces a running review. Known limit: the marker keys on the target's status, so an agent document on a leaf target put `in_review` for a code review is marked too — the skill routes plan and sub-targeted reviews through a dedicated review sub-target to keep that rare. No schema change; no contract semantics or guard tests changed.
- 2026-10-01 (board target #89): **PROJ-08** added — attached project documents are indexed into kb (`project_doc`) and searchable only from their own project's session. `project resync` re-indexes the project right after its import (`index_ok`/`index_error`/`indexed`/`index_skipped`, skipped when `knowledge.enabled` is off) and the Desktop's Re-run Setup summary says so; `attach_document` re-indexes too. **PROJ-02 amended (strengthened):** `db.DeleteProject` also deletes the project's index entries in its transaction, and `TestProj02_DeleteProjectLeavesNoRows` asserts it (plus that another project's entries stay).

- 2026-10-01 (board item #81): the Desktop Documents pane groups its list by kind (Specs, Plans, Docs, Imported — `ProjectDocumentGrouping`, pure), filters it by a title/path search, marks open comments and "changed since last viewed", and offers a Contents menu built from the open document's headings. Read-only UI over existing rows; no contract semantics or guard tests changed.
- 2026-10-01 (board target #91): `watchtower project resync <id>` and the Desktop's **Re-run Setup** re-run the document import and the folder install additively — PROJ-04's never-overwrite rule and the PROJ-03 "Desktop never writes a document" rule hold unchanged (the CLI writes import rows only; the files are never written); nothing is deleted, so PROJ-02 is unaffected. Pinned by `TestProjectResync_IsAdditive` (every project row byte-identical apart from the new document). No contract semantics or guard tests changed.

- 2026-10-01 (board targets #77/#114/#87/#115, spec `docs/superpowers/specs/2026-09-30-project-workspace-sessions-design.md`): projects hold several named terminal sessions (`terminal_sessions`, migration 00084), shown single-pane, split or expanded (per-project layout in UserDefaults), with "Work on it" per board target and standalone terminals (`project_id IS NULL`, no project MCP/hook, nothing in project tables). **PROJ-02**'s delete also removes the project's session rows (`ON DELETE CASCADE`, pinned by `TestProj02_DeleteProjectLeavesNoRows`) after the Desktop closes their processes; Claude Code's own transcripts are left alone. A standalone terminal is no project row and reaches no project reader (PROJ-01). No contract semantics or guard tests changed.

- 2026-10-01 (board target #160): an embedded project terminal follows `/clear` — the Desktop passes the row id to `claude` as `WATCHTOWER_TERMINAL_SESSION_ID`, and the existing `SessionStart` hook (`project brief`) stores the payload's `session_id` on that project's `claude` row for `source` `clear`/`compact`/`resume`/`fork` (`db.SetTerminalClaudeSessionID`; tests `cmd/project_brief_session_test.go`, `testOpenResumesTheSessionIDTheHookStored`). The installed hook command is unchanged, so **PROJ-04** needs no reinstall; the brief's output and its always-exit-0 rule are unchanged. Standalone terminals (no hook) keep relaunching their launch id — recorded as a v1 limit in `docs/features/projects.md`. No PROJ contract semantics or guard tests changed; DEV-05's "the brief only reads" sentence is amended (see `dev-surface.md`; approved by the owner 2026-10-01).

- 2026-10-01 (board target #90): project sources now matter — `search_knowledge` in a project session ranks the project's Slack channel / Jira project / Confluence space documents first (`project_scope` boost|only|off), and `project brief` adds a budgeted "Recent in project sources" section after the comments that never cuts the open targets (the brief's in-progress-first ordering is unchanged). `person`/`link` sources stay informational. No contract semantics or guard tests changed.

- 2026-10-01 (board item #84): document comments are drafted at the selection (a floating Comment button or the context menu) and kept as in-memory drafts until **Send N comments to Claude**, which writes them as ordinary owner `project_comments` rows in one transaction before typing the unchanged one-line prompt (never submitted, control scalars removed). No draft state reaches the DB, so the agent's channels (`list_comments`, the brief, the board counters) are unchanged; PROJ-03 unchanged. No contract semantics or guard tests changed.

- 2026-10-01 (board target #131, Desktop half): the Board pane shows the PROJ-07 drift (`ProjectDriftBanner`, `ProjectsViewModel.refreshDrift` over `project check --json --no-network`), and `ProjectInstallStatus` decodes `stop_hook` so a project without the Stop hook is offered Repair. PROJ-07's Status and guards updated; no contract semantics changed.
- 2026-10-01 (board target #122): board language — `projects.board_language` (migration `00087`; empty = follow the session language, else a language name or tag validated by `db.NormalizeBoardLanguage`: letters of any script, spaces and hyphens with at least one letter, at most 3 words / 40 runes), set by `watchtower project update <id> --board-language`, the Desktop project page (through that command) and the project-session `update_project` (`board_language`; `description` becomes optional, one of the two is required). The brief and `project_info` carry one `Board language:` line (`tools.BoardLanguageLine`) and the `watchtower-project` skill's Board language section tells every session to write targets, intents and comments in it (code identifiers, paths and plan references unchanged). `terminal title` appends the override to its prompt at run time; imported document titles are the files' own and are not translated. No contract semantics or guard tests changed.

- 2026-10-01 (board item #80): the Desktop Documents pane's **Add Document…** attaches a `.md`/`.txt` file inside the folder as `origin='owner'` through the new `watchtower project attach-doc <id> <path> [--kind --title --target --json]` (the same folder/symlink/extension checks as `attach_document`, shared via `tools.ResolveProjectDocumentPath`; an already attached path — compared ignoring case — is left untouched). The Desktop process itself still writes only `project_comments` rows: the document row is the CLI's write, and no one writes the file (PROJ-03 unchanged); the badge, revised dot and "ready for review" notification now count `origin='agent'` documents only. No contract semantics or guard tests changed.

- 2026-10-01 (board target #117): project targets carry image attachments — `project_target_images` (migration `00088`), files copied by `create_targets` (`images`) / `update_target` (`add_images`, `remove_image_ids`) into `<workspace>/project_files/<project_id>/<sha256>.<ext>` (0700/0600, PNG/JPEG/GIF/WebP sniffed by content, ≤ 5 MB, ≤ 20 per target, one copy per content per project), listed by `get_target` and shown read-only in the Desktop board's detail pane. **PROJ-02** strengthened: a project delete also removes the stored copies, a target delete the ones nothing else names (new guards in `cmd/project_images_test.go`; `TestProj02_DeleteProjectLeavesNoRows` also counts image rows). **PROJ-03**'s "no project tool writes a file" narrowed to "in the project folder" — the image copies land in Watchtower's workspace, the document guarantee is unchanged; the wording was confirmed by the owner 2026-10-01. PROJ-01: the table has no non-board reader.

- 2026-10-01 (board target #131): **PROJ-07** added — project targets carry `branch`/`pr` (migration `00089`), `watchtower project check` finds board drift, a `Stop` hook installed by `integrate claude-code --project N` hands certain git drift back to the agent once per stop, and the brief shows it. **PROJ-02** and **PROJ-04** widened, not weakened: the install owns one `Stop` entry next to the `SessionStart` one under the same rules, and delete/remove take both away (new guards listed above). A project installed before this change gets the `Stop` hook when `integrate claude-code --project N` runs again. Known limits: the check never fetches, so `origin/<default>` is only as fresh as the last `git fetch` (a merge made on GitHub shows once fetched — hence `done_but_unmerged` is advisory); a squash older than 200 commits after the fork, or one whose diff changed in conflict resolution, is not recognised (and since 2026-10-01 squash patch ids are zero-context, so a branch whose whole diff is a small change main also made by itself in the same file reads as squashed); a local branch created at an already-merged tip by `git checkout -b x origin/x` has no commit in its reflog and is not called merged; a commit-less branch that exists only on origin, pushed from a `--no-ff`-merged feature's tip, reads as merged; `git cherry` is skipped once the default branch gained more than 200 commits since the fork.

- 2026-09-30 (board target #119): **PROJ-06** added — project targets gain `in_review` and a trigger-written status history with time and actor (migration `00086`). **PROJ-05** amended with owner approval (the same request): an `in_review` child counts as started, like `in_progress`; the rollup's other rules are unchanged, and its writes are recorded as `system`. The migration rebuilds `targets` and recreates 00085's triggers.

- 2026-09-30 (board items #104, #79): board targets carry a priority (`create_targets`/`update_target`; siblings sort by priority, then status, in `project_board`, `project board` and the brief). `project create` and the new `project import-docs <id>` mechanically attach the folder's README and `docs/**/{specs,plans}` files as `origin='import'` documents (`internal/projectdocs`, migration 00083) — read-only over the folder, so PROJ-03 is unchanged (no project code writes a document file). No contract semantics or guard tests changed.
- 2026-09-30 (follow-up to #34): the Desktop badge, revised dot and "ready for review" notification skip `origin='import'` documents; the brief lists subtrees holding in-progress, then blocked targets first (priority order within a rank); an unreadable path below `docs/` is skipped and reported instead of failing the import, and the Desktop's project page shows a failed import, unreadable paths and files past the cap. No contract semantics or guard tests changed.

- 2026-09-30 (fix wave 4 of PR #30): the Desktop re-anchor keeps a lost root `open` while its thread has an unanswered owner reply, so an owner reply that reopened an `outdated` root is not hidden again on the next load (`testLostThreadWithAnUnansweredOwnerReplyStaysOpen`). PROJ-03's Observable sentence amended to name the exception (owner-approved 2026-09-30); guard test unchanged.
- 2026-09-30 (fix wave 3 of PR #30): an owner reply under a resolved or outdated root reopens it (Go `AddProjectCommentTx`, Swift `ProjectQueries.reply`; tests `TestAddProjectComment_OwnerReplyReopensAClosedThread`, `testOwnerReplyReopensAResolvedOrOutdatedThread`), so wave 2's open-thread new-for-agent rule no longer drops such a reply. Recorded under "v1 limits and notes"; no guard test changed.
- 2026-09-30 (fix wave 2 of PR #30): "v1 limits and notes" section added — TCC attribution accepted for the POC (owner decision), a project session's full read tool set with DEV-06 as a Watchtower-tools guardrail only, project audit rows kept after a delete and never on the action strip, and a re-anchored `outdated` owner root leaving the agent's new-for-agent channels. No contract semantics or guard tests changed.
- 2026-09-29 (Phase 5 of the Projects POC, spec `docs/superpowers/specs/2026-09-29-project-board-poc-design.md`): **PROJ-01** gains its Desktop guards — `testProj01_FetchAllNeverReturnsAProjectTarget`, `testProj01_FetchAllTagFilterNeverReturnsAProjectTarget`, `testProj01_FetchCountsIgnoreProjectTargets`, `testProj01_DueTodayIgnoresProjectTargets`, `testProj01_DistinctTagsNeverListAProjectTargetsTag`, `testProj01_MentionPickerNeverOffersAProjectTarget` (`Tests/Core/ProjectTargetExclusionTests.swift`) and `testProj01_TargetsBadgeIgnoresProjectTargets` (`Tests/SidebarCountsViewModelTests.swift`); the Observable now lists the Swift readers (`TargetQueries.fetchAll/fetchCounts/fetchDistinctTags`, `ChatEntitySearch.targets`). **PROJ-02** is strengthened on the Desktop side: "Wipe LLM data" (`DatabaseManager.wipeLLMData`) no longer deletes project targets, which are `source_type='chat'` (guard `testWipeLLMDataPreservesProjectTargets`) — only a project delete removes a board; the Desktop delete (`ProjectsViewModel.deleteProject`) closes the project's terminal before running `watchtower project delete`, keeps the project listed on a CLI failure, and closes the terminal of a project deleted from outside (`ProjectsViewModelDeleteTests`). The daily briefing reads project boards through `gatherProjects` into its own PROJECTS block (`briefing.daily` v8) — a board reader by design, not a PROJ-01 leak: project targets still never enter the briefing's YOUR TARGETS input (`GetTargetsForBriefing`) nor `target_id`. This also completes the folder-removal half of **PROJ-02** (Task 12) and **PROJ-04** (Tasks 11–12); both now hold the `Enforced` status recorded above in full — the creation entry below's "pending"/"Planned" phrasing described only that day's state.
- 2026-09-29: file created with PROJ-01..04 by the Projects POC (spec `docs/superpowers/specs/2026-09-29-project-board-poc-design.md` §7, plan `docs/superpowers/plans/2026-09-29-projects-poc.md`). PROJ-01 Enforced on the Go side (Task 3's reader exclusions + the registry's session-scoped `list_targets`/`get_target`, Task 7); PROJ-02 Enforced for the database (Task 4) with the folder half pending Task 12; PROJ-03 Planned (Task 16); PROJ-04 Planned (Tasks 11–12). The write path into these tables from Claude Code is contract DEV-06 in `dev-surface.md`.
