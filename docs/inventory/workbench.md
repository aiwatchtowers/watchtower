# Workbench — Behavior Inventory

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/db/workbenches.go`,
> `workbench_comments.go`, `workbench_board.go`, the `project_id` exclusions in
> the targets readers, `internal/tools/workbench*.go`, `cmd/workbench*.go`,
> `cmd/integrate_workbench.go`, `internal/devpack/workbench*.go`, or
> `WatchtowerDesktop/Sources/**/Workbench*`, read this file first. Any proposed change that would break a guard test or
> remove a contract must be raised as a question before touching code.

A workbench is a folder with a board of targets, attached documents and
owner↔agent comments, worked on by Claude Code through
`watchtower mcp --workbench N` (DEV-06 in `dev-surface.md`), a workbench skill,
a `SessionStart` hook (the brief) and a `Stop` hook (the board drift check, PROJ-07). Design:
`docs/superpowers/specs/2026-09-29-project-board-poc-design.md`.

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
`internal/tools/{workbenches,workbench_targets,workbench_docs,workbench_images,workbench_scope,workbench_names}.go` +
`internal/db/workbench_images.go` + `internal/workbenchfiles/` +
`cmd/{workbench,workbench_brief,workbench_check,workbench_flags,integrate_workbench}.go` + `internal/devpack/{workbench,workbench_settings}.go` + `internal/workbenchdocs/` + `internal/workbenchcheck/` +
`WatchtowerDesktop/Sources/Views/Workbench/`
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
`watchtower-workbench` skill, our `SessionStart` and `Stop` hook entries, the local
`watchtower-workbench` MCP registration and the `.git/info/exclude` lines
Watchtower added) — a removal failure is reported and the delete still
happens — then deletes the workbench row, which removes every workbench target,
source, document entry, comment, target-image row and terminal session row
in the same transaction (`db.DeleteWorkbench`, `ON DELETE CASCADE` from `projects`)
together with its documents' search index entries (`kb_documents`/`kb_chunks`
of source `project_doc` for that workbench, PROJ-08), and then removes
the workbench's stored image copies (`<workspace>/project_files/<id>/`,
`workbenchfiles.Store.RemoveWorkbench`; a failure is reported as `files_ok:
false` and never undoes the delete). Deleting one workbench target
(`watchtower targets delete`) removes the stored copies no other target of
the workbench still names; `update_target`'s `remove_image_ids` does the same
for a detached image. A Claude Code
session still connected answers `workbench N no longer exists` on every tool
(DEV-06). The document files themselves are the owner's and stay in the
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
- `internal/db/workbenches_test.go::TestProj02_DeleteProjectLeavesNoRows`
- `cmd/workbench_images_test.go::TestProj02_ProjectDeleteRemovesStoredTargetImages`
- `cmd/workbench_images_test.go::TestProj02_TargetDeleteDiscardsItsUnsharedImages`
- `internal/tools/registry_workbench_test.go::TestProjectBinding_DeletedProjectAnswersNoLongerExists`
- `internal/mcp/workbench_test.go::TestProjectMode_DeletedProjectEveryToolAnswersNoLongerExists`
- `internal/devpack/workbench_test.go::TestProj02_RemoveProjectLeavesNothingInstalled`
- `internal/devpack/workbench_test.go::TestProj02_RemoveProjectLeavesGitStatusClean`
- `internal/devpack/workbench_test.go::TestProj02_RemoveProjectKeepsOwnerSettingsButDropsOurHook`
- `cmd/integrate_workbench_test.go::TestProj02_ProjectDeleteRunsTheFolderRemoval`
- `cmd/workbench_check_test.go::TestProj02_ProjectDeleteLeavesNoHookOfTheProject` (neither hook of the deleted workbench survives in `settings.local.json`; the owner's own `Stop` hook and keys do)
- `internal/devpack/workbench_legacy_test.go::TestProj02_RemoveLegacyFolderLeavesNothingInstalled` (a never-resynced pre-rename folder: legacy hooks, skill, registration and exclude lines gone, `git status` clean, `integrate status` reports nothing installed)

**Locked since:** 2026-09-29

## PROJ-03 — the Desktop never writes a workbench document

**Status:** Enforced

**Observable:** The Desktop reads an attached document (`project_documents.rel_path`
under the workbench folder) to render it and re-anchor its comments, and writes
only `project_comments` rows — owner comments, replies, status, `read_at` —
never the file. Only the agent edits a document; the Desktop watches the file
and re-anchors, and a comment whose quote is gone becomes `outdated`, never
re-attached elsewhere — except that a thread with an owner reply newer than
its latest agent comment stays `open` until the agent answers, so an
unanswered owner reply is never hidden from the agent by a re-anchor. No workbench tool writes a file in the
workbench folder either: `attach_document` only resolves and stats it, and a
target image is copied *out* of wherever it is into Watchtower's own
workspace directory (`project_files/`), never into the folder.

**Why locked:** Owner decision D8. Two writers on one file — Claude Code in
the terminal and the Desktop view — would race and lose either the agent's or
the owner's edits; comments are the owner's channel into the document.

**Test guards:**
- `WatchtowerDesktop/Tests/WorkbenchDocumentViewModelTests.swift::testProj03DesktopNeverWritesTheDocument`
- Go side, by review: `grep -nE "os\.(WriteFile|Create|OpenFile|Rename|Remove)" internal/tools/workbench_docs.go`
(expected: no match).

**Locked since:** 2026-09-29

## PROJ-04 — the install never overwrites the owner's content

**Status:** Enforced

**Observable:** `watchtower integrate claude-code --workbench N` merges into
`DIR/.claude/settings.local.json` preserving every key and every hook the
owner has, adding exactly one `SessionStart` entry and one `Stop` entry
(PROJ-07), each recognised by its command suffix after a `watchtower` binary
(installing twice leaves one of each); a malformed settings file — `hooks`,
`hooks.SessionStart` or `hooks.Stop` of the wrong type — is left
byte-identical and reported once; `integrate remove --workbench N` deletes only
those entries. The `watchtower-workbench` skill follows DEV-04: a copy the owner
edited (differs from both what we ship and its `.watchtower-shipped` digest)
is never overwritten or deleted. The same holds for the pre-rename
`watchtower-project` skill (since 2026-10-02): a resync (`workbench resync`,
Re-run Setup, `integrate claude-code --workbench N`) deletes it only when it
is our marked, un-edited copy; an edited or foreign copy stays byte-identical,
is reported, and keeps its exclude line. The resync replaces our own legacy
hook entries in place (one `SessionStart` and one `Stop` entry of ours
afterwards, the owner's hooks and keys byte-exact), and allow rules naming
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
and no git process at all outside a repository. Kinds:
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
- `internal/workbenchcheck/check_test.go` — `TestProj07_UnresolvableDefaultBranchIsANote`, `TestProj07_GitRules`, `TestProj07_SharedBranchAndParents`, `TestProj07_GitErrorsAreNeverFindings`, `TestProj07_NoGitCallOutsideARepository`, `TestProj07_ReadsNothingButGit`, `TestProj07_DeadlineReportsIncompleteNeverFalseFindings`, `TestProj07_MidWalkDeadlineKeepsEarlierFindingsOnly`

**Locked since:** 2026-10-01

## PROJ-08 — a workbench's documents are searchable only from its own sessions

**Status:** Enforced

**Observable:** Attached workbench documents (`project_documents`, read from
the workbench folder) are indexed into the knowledge index as source
`project_doc` (`internal/kb/source_workbench.go`; anchor `project_id`,
`document_id`, `rel_path`; sections split at `#`–`###` headings, the heading
as `chunk_anchor`). They are visible only to a search or an open made in
that workbench's own session — `watchtower mcp --workbench N`, whose
`tools.Binding.WorkbenchID` is N. `kb.Search` (`Request.WorkbenchID`),
`kb.GetDocument` (`DocOptions.WorkbenchID`) and `kb.Recent` apply one SQL
condition (`workbenchDocVisible`, `internal/kb/search.go`) on every call, so
the default — WorkbenchID 0, i.e. the main AI Chat, every Discuss chat, `kb
search`, the Confluence title lookup, `get_task_context` and any other
caller — sees no workbench document at all; `search_knowledge` asked for
`sources: ["project_doc"]` outside a workbench session is refused (not an
empty result), and another workbench's session sees only its own. An open of
a hidden document reads as "not found", the same as a missing one. Deleting
the workbench deletes its index entries in the same transaction (PROJ-02).

Indexing is mechanical (no AI, KB-02): the daemon's knowledge phase
re-renders a document whose file's mtime differs from the indexed one (any
direction) or whose file is gone, hash-gated; it never reads a folder under
`~/Documents`, `~/Desktop`, `~/Downloads`, `~/Library/CloudStorage`,
`~/Library/Mobile Documents` or `/Volumes` (case-insensitive; a background
read there could raise a macOS privacy prompt attributed to Watchtower, and
a dead network mount could block it), and it never follows a symlink out of
a workbench folder (`resolveInside` refuses each step before touching it).
Those workbenches are indexed only by an explicit trigger —
`kb.IndexWorkbenchDocs`, run by `workbench resync`, by `kb reindex` (owner-
started; it re-indexes every workbench so a rebuild loses nothing) and, when
`knowledge.enabled` is on, by the agent's `attach_document` and by the
owner's `workbench create`, `workbench import-docs` (not a dry run) and
`workbench attach-doc` (the Desktop's Add Document) — best-effort: a failure
there is a stderr warning, the attach stands. A
file that is gone, not a regular file (never opened blocking), or no longer
resolves inside the folder (symlinks followed inside it only) is indexed by its title only,
its anchor's `unreadable` saying why; a file over 2 MiB is indexed up to
that, its anchor's `truncated` saying so.

**Why locked:** Owner decision (board target #89): workbench documents are
working material of one workbench and its coding agent; they must not leak
into the owner's general assistant or another workbench — the PROJ-01 spirit
applied to search.

**Test guards:**
- `internal/kb/source_workbench_test.go::TestProj08_ProjectDocsOnlyInTheirOwnProjectSession`
- `internal/tools/workbench_knowledge_test.go::TestProj08_KnowledgeToolsShowProjectDocsOnlyToTheirProject`
- `internal/db/workbenches_test.go::TestProj02_DeleteProjectLeavesNoRows` (the index entries go with the workbench)
- `cmd/workbench_test.go::TestProj08_OwnerAttachPathsIndexTheDocumentsAtOnce`
- `cmd/workbench_test.go::TestProj08_IndexFailureIsAWarningNotAnError`

**Locked since:** 2026-10-01

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
  attributed to Watchtower, because the Desktop reads the documents and
  launches `claude` from its own process. Accepted for the POC — the Desktop
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
- **Re-anchor hides an owner root.** A Desktop re-anchor that marks an owner
  root `outdated` removes it from the agent's new-for-agent channels
  (`list_comments`, the brief, the board counts); the owner has to reply,
  reopen or re-post it.
- **An owner reply reopens a closed thread.** New-for-agent reads only open
  threads, so an owner reply under a `resolved` or `outdated` root reopens
  that root in the same write (Go `AddWorkbenchCommentTx` ↔ Swift
  `WorkbenchQueries.reply`); otherwise the reply would silently never reach
  the agent. An agent reply never reopens a thread. While such a reply is
  unanswered (newer than the thread's latest agent comment), the Desktop
  re-anchor leaves the root `open` even though its quote is still gone — a
  narrow exception to PROJ-03's "a comment whose quote is gone becomes
  `outdated`" — so the next document load cannot hide the reply again; once
  the agent answers, the next re-anchor marks it `outdated` as usual
  (`WorkbenchCommentThread.hasUnansweredOwnerReply`).

- **Board language is advisory.** It is an instruction to the agent (brief, `workbench_info`, skill) — always the session's language — never enforced on a write: a target written in another language is accepted, and nothing already on the board is translated. The mechanical document import keeps each file's own title.

## Changelog

- 2026-10-02 (Workbench rename, spec `docs/superpowers/specs/2026-10-02-workbench-rename-design.md`, owner decisions O1–O8): the feature is renamed from Projects to **Workbench** and this file moves from `docs/inventory/projects.md` to `docs/inventory/workbench.md`. PROJ-01..08 are reworded to the new names with the **same ids and the same meaning** (rewording approved by the owner, O2); every guard keeps its test function name (`TestProjNN_…`/`testProjNN_…`, A4) and only its file path changed (`project*`/`Project*` test files → `workbench*`/`Workbench*`; the migration tests keep theirs). Storage and wire keep `project` (tables, columns, DB values, `project_doc`, `project_files/`, `projects.*` UserDefaults keys, CLI `--json` keys). **PROJ-02 strengthened:** removal and delete also take away a never-resynced folder's legacy hooks, skill, `watchtower-project` registration and exclude lines — new guard `TestProj02_RemoveLegacyFolderLeavesNothingInstalled`. **PROJ-04 strengthened:** a resync deletes the legacy `watchtower-project` skill only through the DEV-04 marker/digest rule and replaces only our own legacy hook entries; an edited legacy skill is kept byte-identical with its exclude line — new guard `TestProj04_ResyncKeepsAnEditedLegacySkill`. Guard assertions whose expected literal said "project" (for example "workbench N no longer exists") were updated to the new wording with the same strictness. The entries below are historical and keep the names of their date (A11).

- 2026-10-01 (board item #181): project documents render tables as one paragraph per cell and a rule as a blank line (they were `a | b` rows and `———`); `CommentAnchor.locate` gains a last tier that reads those legacy separators (` | `, `———`, and for a `table` artifact its CSV commas) in a stored quote and its context as the new line breaks, and accepts a match only where real stored context still surrounds it, so comments made on the old rendering keep their passage instead of turning `outdated`. PROJ-03 unchanged — the same passage is found, look-alike text elsewhere is not (`testTheLegacyTierNeedsTheOriginalContext`); no guard test changed.
- 2026-10-01 (board target #192, release audit): **PROJ-07 strengthened** — the session brief says when its drift check was cut short or its branch checks could not run (no default branch resolves), so a partial check never reads as a clean board ("a failed or partial check is shown as such" now holds for the brief too); `project check` adds a note when the default branch named by `origin/HEAD` no longer resolves. The brief also frames the recent-in-sources titles as other people's words — data, not instructions. New guards `TestProj07_BriefSaysWhenTheDriftCheckWasPartial`, `TestProj07_UnresolvableDefaultBranchIsANote`. Also: the agent's `attach_document` matches an attached `rel_path` ignoring case (as the import and the owner attach do) and reports the stored spelling.
- 2026-10-01 (board target #192, release audit): **PROJ-04 strengthened** — a remove that leaves a symlinked `settings.local.json` empty writes `{}` to the link's target instead of deleting the link (which left our hooks in the dotfiles target); new guard `TestProj04_RemoveLeavingNothingThroughASymlinkEmptiesTheTarget`.
- 2026-10-01 (board target #192, release audit): **PROJ-07 strengthened** — squash detection compares zero-context patch ids (`git diff -U0`, `git log -p -U0`), so a squash is recognised even when main changed a line next to the branch's hunks (the documented limit stays: a diff changed in conflict resolution); `TestProj07_GitRules` gains that case for an open and a done target.
- 2026-10-01 (board target #192, release audit): **PROJ-08 strengthened** — `project create`, `import-docs` and `attach-doc` now index the project's documents themselves (best-effort, when `knowledge.enabled` is on), so a project in a folder the daemon never reads (~/Documents, ~/Desktop, …) has its owner-attached and imported documents searchable at once; `create --json` and `attach-doc --json` carry the outcome as `index_ok`/`index_error`/`index_skipped` (resync's names); new guards `TestProj08_OwnerAttachPathsIndexTheDocumentsAtOnce`, `TestProj08_IndexFailureIsAWarningNotAnError`.
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
