# Workbench — Behavior Inventory

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/db/workbenches.go`,
> `workbench_comments.go`, `workbench_board.go`, the `project_id` exclusions in
> the targets readers, `internal/tools/workbench*.go`, `cmd/workbench*.go`,
> `cmd/integrate_workbench.go`, `internal/devpack/workbench*.go`,
> `internal/gitbin/`, `internal/workbenchgit/`, `internal/sessionreport/`,
> `internal/sessioncleanup/`, `internal/sessionhost/`, `WatchtowerDesktop/Sources/Services/SessionHost/`, `WatchtowerDesktop/Sources/Services/TerminalCenter.swift`, or
> `WatchtowerDesktop/Sources/**/Workbench*`,
> `WatchtowerDesktop/Sources/WatchtowerCore/Services/{PendingSessionDeletes,SessionDeletePolicy}.swift`,
> `WatchtowerDesktop/Sources/Services/SessionCleanupCenter.swift`,
> `WatchtowerDesktop/Sources/WatchtowerCore/{Models/SessionCleanup,Services/SessionCleanupPresentation,Services/SessionDeleteCleanupChoice}.swift`,
> `WatchtowerDesktop/Sources/Views/Workbench/{SessionCleanupSheet,SessionDeleteConfirmSheet,SessionReportCleanupSection}.swift`, read this file first. Any proposed change that would break a guard test or
> remove a contract must be raised as a question before touching code.

A workbench is a folder with a board of targets, owner↔agent target
comments and the agent's asks to the owner (`owner_asks`, PROJ-12/13),
worked on by Claude Code — or, since 2026-10-12, Codex CLI (board #399, see the
changelog) — through
`watchtower mcp --workbench N` (DEV-06 in `dev-surface.md`), a workbench skill,
a `SessionStart` hook (the brief), a `Stop` hook (the board drift check, PROJ-07),
the session state hooks (PROJ-11) and the ask guard (a `Stop` command hook
that reads whether the owner is in the session — a prompt hook until
2026-10-11 — and a `PreToolUse` block of `AskUserQuestion`, PROJ-13). Each Desktop terminal session
has a report of its own work, and the agent marks it finished with
`finish_session` (PROJ-14); before it finishes, the agent removes the
worktrees and branches its session left with `watchtower workbench cleanup`,
which never removes unsaved, unpushed, in-use or someone else's work
(PROJ-18). Design:
`docs/superpowers/specs/2026-09-29-project-board-poc-design.md`; owner asks:
`docs/superpowers/specs/2026-10-03-workbench-owner-asks-design.md`; session
report and states: `docs/superpowers/specs/2026-10-03-workbench-session-report-design.md`; board
archive: `docs/superpowers/specs/2026-10-04-workbench-board-archive-design.md`; owner
asks v2 (levels, presence, Quick asks, asks for other clients):
`docs/superpowers/specs/2026-10-10-owner-asks-v2-design.md`; Codex as a Workbench agent:
`docs/superpowers/specs/2026-10-12-codex-workbench-agent-design.md` (§15: what shipped); session
cleanup: `docs/superpowers/specs/2026-10-12-session-cleanup-design.md`.

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
`cmd/{workbench,workbench_brief,workbench_brief_session,workbench_check,workbench_askguard,workbench_askguard_stop,workbench_asks_cli,workbench_escalate,workbench_session_state,workbench_flags,integrate_workbench}.go` + `internal/devpack/{workbench,workbench_settings}.go` + `internal/devpack/askguard_classifier.md` + `internal/devpack/testdata/askguard_prompt_v{1,2,3}.md` +
`internal/db/owner_presence.go` + `internal/db/migrations/00107_owner_asks_v2.sql` + `internal/workbenchdocs/` + `internal/workbenchcheck/` +
`internal/db/terminal_sessions.go` + `internal/db/migrations/00098_terminal_session_agent_state.sql` +
`internal/db/session_report.go` + `internal/db/migrations/00101_workbench_session_report.sql` +
`internal/db/workbench_archive_reads.go` + `internal/db/migrations/00103_workbench_board_archive.sql` + `internal/tools/workbench_board.go` +
`internal/sessionreport/` + `cmd/workbench_session_report.go` +
`WatchtowerDesktop/Sources/Views/Workbench/` + `WatchtowerDesktop/Sources/Services/SessionAgentStateCenter.swift` +
`WatchtowerDesktop/Sources/WatchtowerCore/{Models/SessionAgentStatus,Services/SessionAgentNoticePolicy}.swift` +
`WatchtowerDesktop/Sources/WatchtowerCore/{Models/SessionReport,Services/SessionStatePresentation,Services/SessionSwitcherPresentation,Services/SessionReportPresentation}.swift` +
`WatchtowerDesktop/Sources/WatchtowerCore/{Models/OwnerAsk,Database/Queries/OwnerAskQueries,Services/OwnerAsk*}.swift` +
`WatchtowerDesktop/Sources/ViewModels/OwnerAsksViewModel.swift` + `WatchtowerDesktop/Sources/Services/SessionLineDelivery.swift` +
`WatchtowerDesktop/Sources/Services/MobileHub/Handlers/SessionInputHandlers.swift` (PROJ-16) +
`WatchtowerDesktop/Sources/WatchtowerCore/{Services/OwnerPresencePolicy,Services/ChatQuestionEscalationPolicy,Models/ChatQuestionEscalationResult,Database/Queries/OwnerPresenceQueries}.swift` +
`WatchtowerDesktop/Sources/Services/{OwnerPresenceCenter,ChatQuestionEscalator}.swift` +
`internal/agentkind/` + `internal/db/migrations/00109_terminal_sessions_codex.sql` + `internal/codex/appserver.go` +
`internal/devpack/{codex_hooks,codex_install}.go` + `internal/terminal/codex_rollout.go` +
`cmd/{workbench_hook_input,workbench_hook_row,workbench_launch_args}.go` +
`WatchtowerDesktop/Sources/WatchtowerCore/{Models/AgentKind,Services/AgentInputProfile,Services/CodexRollout,Services/AgentChoicePresentation}.swift` +
`internal/workbenchgit/folder.go` + `internal/db/migrations/00110_terminal_session_cwd.sql` +
`WatchtowerDesktop/Sources/WatchtowerCore/{Models/SessionPlace,Models/CodeRoot,Services/SessionPlacePresentation,Services/CodeRootPolicy}.swift` +
`WatchtowerDesktop/Sources/Services/SessionPlaceCenter.swift` +
`internal/sessioncleanup/` + `cmd/workbench_cleanup.go` + `internal/db/terminal_session_worktrees.go` +
`internal/db/migrations/00111_session_cleanup.sql` + `internal/devpack/workbench_cleanup_permission.go` +
`WatchtowerDesktop/Sources/Services/SessionCleanupCenter.swift` +
`WatchtowerDesktop/Sources/WatchtowerCore/{Models/SessionCleanup,Services/SessionCleanupPresentation,Services/SessionDeleteCleanupChoice}.swift` +
`WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel+SessionCleanup.swift`
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

*Note (2026-10-15, no contract change):* the Desktop's Home "My targets" read,
`TargetQueries.homeSummary`, filters `project_id IS NULL` as well, guarded by
`testProj01_HomeSummaryNeverReturnsAProjectTarget`.

**Why locked:** Owner decision D4. An agent decomposes a plan into dozens of
sub-targets; letting them into the Targets tab, the day plan, next-step,
Catch-Up, memory mirrors or the inbox overdue notification would flood every
personal surface with the agent's own bookkeeping — and spend next-step AI
calls on it.

**Test guards:**
- `internal/db` — `TestProj01_ProjectTargetsNeverReachNonBoardReaders` (Task 3)
- `internal/tools/workbenches_test.go::TestProj01_TargetReadsFollowTheSessionScope`
- `WatchtowerDesktop/Tests/Core/WorkbenchTargetExclusionTests.swift::testProj01_HomeSummaryNeverReturnsAProjectTarget` (Home, 2026-10-15)

**Locked since:** 2026-09-29

## PROJ-02 — delete leaves nothing

**Status:** Enforced (amended 2026-10-11 for the owner's presence row, owner approved in ask #148, board #395; amended 2026-10-12 for the Codex part, owner approved with the Codex design spec in ask #189, board #399; amended 2026-10-14 for links leaving the folder, owner approved in ask #118, target 156; amended 2026-10-14 for the session cleanup, owner approved 2026-10-12 in ask #193, board #535; amended 2026-10-15 for agent analytics, owner approved in ask #153, board #297; amended 2026-10-15 for the methodology preset, board #266)

**Observable:** `watchtower workbench delete N` first runs the folder removal
(`workbenchRemoveInstall`, wired to `devpack.RemoveWorkbench`: the
`watchtower-workbench` skill, our hook entries — `SessionStart`, `Stop` and,
since 2026-10-03, the session state entries under `UserPromptSubmit`,
`Notification`, `PostToolUse` and `StopFailure` (PROJ-11) and the two ask
guard entries — the `Stop` command hook (a prompt hook until 2026-10-11;
a leftover marker prompt of the workbench goes too) and the `PreToolUse`
command hook matched to `AskUserQuestion` (PROJ-13) — the local
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
their messages and search rows by cascade); since 2026-10-11 the owner's
presence row (`owner_presence`, migration `00107`) that names one of its
sessions is left in no session (`session_id` NULL by `ON DELETE SET NULL`),
so it never points at a gone row. It then removes
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
lines, exactly as a current folder does. Since 2026-10-12 (board #399) the
removal also takes out the Codex part when the folder exists
(`devpack.RemoveCodex`): our un-edited `.agents/skills/watchtower-workbench/`
copy (`.agents/skills` and `.agents` once empty), its exclude line, and our
entries in a `.codex` hook file codex's import copied (PROJ-04). It never
touches the hook trust entries in `~/.codex/config.toml`: one trust key per
event covers every folder, so they stay (harmless once no workbench uses
them). The codex rows go with the workbench like every terminal session row.
Since 2026-10-14 (board #535, PROJ-18) the folder removal also deletes our
cleanup allow rule (`devpack.RemoveCleanupPermission`: every
`permissions.allow` string of ours, PROJ-04 — the owner's allow and deny
entries stay, and a `permissions` object left empty is dropped), and the
row delete removes each session's worktree ledger
(`terminal_session_worktrees`, migration `00111`) by `ON DELETE CASCADE`
from `terminal_sessions`, with its `cleanup_result`/`cleanup_at` on the row
itself. The worktrees and branches a cleanup removed are not brought back
by anything; a workbench delete runs no sweep of the repository (only the placed sessions' own cleanup below).
Agent analytics rows (`agent_log_sessions`/`agent_log_events`, migration `00116`) are the one exception: they outlive the workbench with `project_id` NULL (and `terminal_session_id` NULL) and are adopted by a workbench later created on the same folder.
*2026-10-14 (board #229, asks #122/#124):* deleting a workbench
first runs the session cleanup (PROJ-18) for every placed session's
worktree and `wt/` branch; a worktree the cleanup keeps stays on disk
and is listed in `kept_worktrees`; every placed session's local MCP entry
is unregistered — a removed worktree's and a kept one's alike (a kept
worktree's files stay).

**Exception (owner approved 2026-10-14, ask #118, target 156):** a file or
directory the removal would write or remove through that is a symlink
leaving the folder (`settings.local.json`, `.claude`, `.claude/skills`, a
`.codex` hook file, `.agents/skills`) is refused (PROJ-04), so what
Watchtower put there stays. The delete still completes, and the CLI
(stderr, and `--json`'s `removal_hints`) and the Desktop's delete warning
(`WorkbenchDeleted.cleanupWarning`) name the exact outside file and what to
remove by hand — "Watchtower's hooks stay in <file> — remove the entries
marked watchtower by hand" (or the skill's directory to remove);
`devpack.OutsideFolderHints`, only for an outside path that exists.
`removal_error` then carries only the other failures
(`devpack.WithoutHinted`), so an unrelated cleanup failure is still shown
beside the hints. `integrate remove --workbench N` and
`integrate codex --remove` print the same lines under their problems.

Since 2026-10-15 (board #266) the folder removal and the Codex removal also take out our un-edited `watchtower-flow` preset and its exclude lines; an edited copy stays with its line (PROJ-04).

**Why locked:** Owner decision D7. A half-deleted workbench — orphan targets, a
hook that briefs about a workbench that no longer exists, an MCP server
registered against a dead id — is worse than no workbench at all, and the owner
must be able to undo the whole feature for a folder in one step.

**Test guards:**
- `internal/db/workbenches_test.go::TestProj02_DeleteProjectLeavesNoRows` (owner asks included — an open one bound to a session and a target, an answered one — while another workbench's ask survives; no `terminal_session_targets` or `workbench_pr_states` row of it is left, another workbench's PR cache row survives; its code questions and their messages and search rows are gone, another workbench's question and a main-chat row with the same `context_id` survive; since 2026-10-11 a presence row on one of its sessions is left with `session_id` NULL; since 2026-10-14, board #535, no `terminal_session_worktrees` row of its sessions is left while another workbench's session's ledger row survives; since 2026-10-15, board #297, an agent analytics session of it survives with `project_id` NULL — assertion added, none relaxed)
- `cmd/workbench_cleanup_test.go::TestWorkbenchDelete_CleansPlacedWorktreesKeepsDirtyOnes` (2026-10-14, board #229)
- `cmd/workbench_cleanup_test.go::TestWorkbenchDelete_KeepsAWorktreeThePlanDoesNotList` (2026-10-14, board #229: a kept worktree stays on disk, is listed in `kept_worktrees`, and its local MCP entry is unregistered)
- `internal/db/workbenches_test.go::TestProj02_DeleteRemovesAutomationRows` (2026-10-16, automations P5: the workbench's automations, their runs, steps, state and outputs, and its owner asks go with it; another workbench's stay; the recipe files in the folder are untouched)
- `cmd/workbench_images_test.go::TestProj02_ProjectDeleteRemovesStoredTargetImages`
- `cmd/workbench_images_test.go::TestProj02_TargetDeleteDiscardsItsUnsharedImages`
- `internal/tools/registry_workbench_test.go::TestProjectBinding_DeletedProjectAnswersNoLongerExists`
- `internal/mcp/workbench_test.go::TestProjectMode_DeletedProjectEveryToolAnswersNoLongerExists`
- `internal/devpack/workbench_test.go::TestProj02_RemoveProjectLeavesNothingInstalled` (the fixture asserts every hook, the state hooks and both ask guard hooks included, is installed before the removal; since 2026-10-14, board #535, the fixture also asserts the cleanup allow rule is installed, and the status reads `CleanupPermission` false after the removal — assertions added, none relaxed)
- `internal/devpack/workbench_test.go::TestProj02_RemoveProjectLeavesGitStatusClean`
- `internal/devpack/workbench_test.go::TestProj02_RemoveProjectKeepsOwnerSettingsButDropsOurHook` (two owner `PreToolUse` groups — an `AskUserQuestion` command and a `Bash` prompt hook — come back exactly the owner's)
- `cmd/integrate_workbench_test.go::TestProj02_ProjectDeleteRunsTheFolderRemoval`
- `cmd/workbench_check_test.go::TestProj02_ProjectDeleteLeavesNoHookOfTheProject` (no hook of the deleted workbench — brief, drift check, session state or ask guard — survives in `settings.local.json`; the owner's own `Stop`, `UserPromptSubmit` and `PreToolUse` hooks and keys do)
- `internal/devpack/workbench_legacy_test.go::TestProj02_RemoveLegacyFolderLeavesNothingInstalled` (a never-resynced pre-rename folder: legacy hooks, skill, registration and exclude lines gone, `git status` clean, `integrate status` reports nothing installed)
- `cmd/workbench_delete_outside_test.go::TestProj02_DeleteWithASettingsLinkOutsideNamesTheLeftoverHooks` (since 2026-10-14, ask #118: the delete completes, `removal_ok` false, `removal_hints` and stderr name the outside file, which stays byte-identical); supporting: `internal/devpack/skill_symlink_test.go::TestOutsideFolderHints_NameTheLeftovers`, Desktop `WorkbenchCLITests.testDeleteWarningNamesTheFileLinkedOutside`
- Session cleanup (2026-10-14, board #535): the ledger half is in `TestProj02_DeleteProjectLeavesNoRows` above; supporting `internal/db/session_cleanup_migration_test.go::TestMigrationSessionCleanup_LedgerCascadesWithTheSession` (a session delete leaves no ledger row), `internal/devpack/workbench_cleanup_permission_test.go::TestCleanupPermission_RemoveLeavesNoFileOrOnlyTheOwners`
- Codex (2026-10-12, board #399): `cmd/integrate_workbench_test.go::TestProj02_WorkbenchDeleteRemovesTheCodexSkill`; supporting: `internal/devpack/codex_install_test.go` (`TestRemoveCodex_RemovesSkillExcludeAndNeverTrust`, `TestRemoveCodex_KeepsAnEditedSkillAndItsExcludeLine`)
- `internal/devpack/workbench_methodology_test.go::TestProj02_RemoveTakesOurPresetAndKeepsAnEditedOne` (2026-10-15)

**Locked since:** 2026-09-29

## PROJ-03 — the Desktop never writes a workbench document behind anyone's back

**Status:** Enforced (amended 2026-10-02 — the code viewer may write the owner's own edits, never over a newer version; amended 2026-10-03 — the document view is gone with attached documents; amended 2026-10-12 to the session's worktree, owner approved in ask #188, board #568; amended 2026-10-16 — Watchtower writes automation recipes in `.watchtower/automations/` only on the owner's Save or Approve, owner approved in ask #272; amended 2026-10-16 — and on the owner's template install, owner approved in ask #188 (2026-10-16, install-template))

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

**Amended 2026-10-12 (board #565/#568, owner approved 2026-10-12, ask #188):**
the code viewer works on the root the page's session is in — the workbench
folder, or a git worktree of its repository (PROJ-10's `--folder` rule; a
worktree root only for a place Go read in that worktree, not stale, whose
folder exists, taken from Go's `folder_root`; anything else is the workbench
folder) — and the FILES tree's operations and the Files pane's saves write
files of that root under the rules above. Each root has its own tabs and
buffers (a root is keyed by its lexically standardized path, never
symlink-resolved; the main folder's tabs key is unchanged); a buffer writes
only to the file it was opened from, so switching sessions never moves an
edit, typed or unsent, into another worktree or the main folder: the page's
unsent edits are handed to the old root's buffers before the new root's tabs
show. An unsaved buffer is never written into a removed worktree: once a
root's worktree is found removed, its buffers never write again (locked for
the app session, their unsaved edits offered to copy or discard) and its tree
operations are refused while the root stays removed — a folder reappearing at
that path does not unlock them. A worktree recreated at that path that the
session's place resolves to shows again with new, writable buffers; the old
ones stay locked.

**Amended 2026-10-16 (Automations P5, board #753; spec
`docs/superpowers/specs/2026-10-14-automations-design.md` §14.6, owner
approved in ask #272):** Watchtower writes one more kind of file in the
workbench folder: automation recipes, only at
`<folder>/.watchtower/automations/<slug>.md`, only on the owner's Save (the
Automations form/Monaco save through `automations save --confirm-hash`) or on
the owner's Approve of a `save_automation` card, each refusing to overwrite a
file whose content changed since the owner saw it (`--expect-content-hash`,
the pinned `existing_content_hash`); `automations delete` removes only such a
file; the write is atomic (`fsutil.WriteFileAtomic`); no other path of the
folder is written, no workbench MCP tool writes a recipe, and the daemon never
writes the folder.

**Amended 2026-10-16 (Automations P5/P6 templates, board #753; owner approved
in ask #188 (2026-10-16, install-template) — not the 2026-10-12 ask #188 of
board #565/#568, a colliding number):** the owner's template install is one
more explicit owner action that writes automation recipes:
`automations install-template <name> --workbench N` (and the Desktop
gallery's install, which calls it) writes recipe files only under
`<folder>/.watchtower/automations/`, refuses a slug that is already taken (a
file in the folder or an index row of the workbench, a removed one included)
before anything is written and so never overwrites a file, writes each file
atomically (`fsutil.WriteFileAtomic`), refuses a recipe folder with a symlink
in its existing path (`automations.RefuseLinkedRecipeDir`), and installs every
recipe unconfirmed and disabled. A failed install removes only the files that
call wrote. No other path of the folder is written.

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
- Board #565, the session's worktree (2026-10-12, ask #188) — in `WatchtowerDesktop/Tests/CodeFilesCenterRootTests.swift`: `testProj03_ABufferNeverWritesIntoAnotherWorktree`, `testProj03_UnsentEditsLandInTheOldWorktreeOnASessionSwitch`, `testProj03_ARemovedWorktreeIsNeverWritten`; supporting (same file): `testARecreatedWorktreeShowsAgainAndTheOldBufferStaysLocked`, `testTreeOperationsRefuseAWorktreeWhoseFolderIsGone`, `testTreeOperationsRefuseARemovedWorktreeWhoseFolderCameBack`, `testOpenInAThenBThenBackKeepsAsTabs`; `WatchtowerDesktop/Tests/Core/CodeRootTests.swift::testExistingAndDeletedFolderShareTheKey`, `WatchtowerDesktop/Tests/Core/CodeRootPolicyTests.swift::testRootTable`; every `testProj03*` in `CodeFileBufferTests.swift` and `TestProj03_AskOwnerNeverWritesTheFolder` unchanged
- Go side, by review: `grep -nE "os\.(WriteFile|Create|OpenFile|Rename|Remove)" internal/tools/workbench_docs.go internal/tools/workbench_asks.go`
(expected: no match).
- Automation recipes (2026-10-16, ask #272): `internal/automations/authoring/save_workbench_test.go::TestSaveAutomation_WorkbenchWritesIntoItsFolder` (an approved save writes only `.watchtower/automations/<slug>.md`, nothing at propose), `cmd/automations_test.go::TestAutomationsCLI_SavePathOutsideWorkbenchAutomationsRefused` (`save --path` anywhere else in the folder is refused, nothing written); supporting: `TestSaveAutomation_WorkbenchUnknownRefused`, `TestSaveAutomation_WorkbenchSymlinkedRecipeDirRefused` (same file as the first), `cmd/automations_test.go::TestAutomationsCLI_SaveRefusesWhenFileChangedSinceLoad`, `internal/automations/authoring/save_test.go::TestSaveAutomation_RefusesWhenFileChangedSincePropose`
- Template install (2026-10-16, ask #188 (2026-10-16, install-template)) — in `cmd/automations_templates_test.go`: `TestInstallTemplate_WorkbenchScopeRules`, `TestInstallTemplate_RefusesExistingSlug`, `TestInstallTemplate_RefusesLinkedWorkbenchDir`, `TestInstallTemplate_InstalledUnconfirmedAndDisabled`, `TestInstallTemplate_FailedWriteRollsBack`, `TestInstallTemplate_FailedRescanRollsBack`

**Locked since:** 2026-09-29

## PROJ-04 — the install never overwrites the owner's content

**Status:** Enforced (install rules amended 2026-10-11 for the ask guard command entry, owner approved in ask #148, board #395; amended 2026-10-12 for `integrate codex`, owner approved with the Codex design spec in ask #189, board #399; amended 2026-10-14 for symlinks leaving the folder, owner approved in ask #109, target 156; amended 2026-10-14 for the cleanup allow rule, owner approved 2026-10-12 in ask #193, board #535; amended 2026-10-15 for the two skills, owner approved in ask #146, board #266)

**Observable:** `watchtower integrate claude-code --workbench N` merges into
`DIR/.claude/settings.local.json` preserving every key and every hook the
owner has, adding a fixed set of entries of ours: one under `SessionStart`
(the brief); under `Stop` the drift check (PROJ-07) and, since 2026-10-03,
the ask guard (PROJ-13) — since 2026-10-11 the command entry `workbench
ask-guard --workbench N --stop` (`timeout: 30`), before that a prompt hook —
two entries of ours on that event; one
each under `UserPromptSubmit`, `Notification`, `PostToolUse`,
`StopFailure`, since 2026-10-10 `SubagentStop` and, since 2026-10-11,
`SubagentStart` (the six session state hooks, PROJ-11); and, since 2026-10-03, one
`PreToolUse` command entry in its own group with matcher `AskUserQuestion`
(the ask tool block, PROJ-13). A command entry is recognised per event by its
command suffix after a `watchtower` binary (installing twice leaves one of
each; the state and ask guard entries have no legacy spelling, so nothing
else is taken for one), and our command entry written from another binary is
updated in place, the owner's keys on it kept. The old ask guard prompt
entry (v1–v3, installed until 2026-10-11) is recognised by its first line
being exactly the marker `[watchtower-workbench ask-guard N]`: an install,
`resync` or Repair replaces every such `Stop` prompt of N — an edited one
too, since it is ours — with the command entry, every key the owner had put
on the prompt other than `type`, `prompt` and `command` carried onto it (a command entry
already there keeps its own keys, as above; a fresh one takes the prompt's,
its `timeout` among them); another workbench's marker prompt and a prompt with
the marker off its first line are the owner's and stay; `integrate remove`
takes out the command entry and any leftover marker prompt of N. Our
`PreToolUse` entry found in another matcher group is taken out of that group
(the owner's hooks there kept) and re-added in its own `AskUserQuestion`
group. A malformed settings file — `hooks`, or the entry list of any event
we own (`PreToolUse` included since 2026-10-03, `SubagentStop` since
2026-10-10, `SubagentStart` since 2026-10-11), of the wrong type — is left
byte-identical and reported once by the install, the removal and the status
(a malformed owner `hooks.SubagentStop` or `hooks.SubagentStart` is refused
there like any other state event, while the
Stop hook's state write, gated on the four core state events only, still
records); `integrate remove --workbench N` deletes
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

Since 2026-10-12 (board #399, Codex): `watchtower integrate codex --workbench
N` writes into the folder only the skill copy
`.agents/skills/watchtower-workbench/` (the same bytes and the same DEV-04
rules as the `.claude` copy: an edited copy is never overwritten or deleted)
and its exclude line. Codex's MCP server and hooks are launch flags and are
never persisted in the folder. It removes only our own command entries (a
`watchtower` binary followed by one of our Claude command tails for workbench
N, current or pre-rename, or one of our Codex tails) from the
`.codex/hooks.json` or `[hooks]` of `.codex/config.toml` that codex's
external-agent import copied from Claude's settings: every other entry, key
and comment stays. `config.toml` is edited in place and the result must decode
to the original minus our entries, or nothing is written
(`ErrCodexHooksNotEditable`); a file is deleted only when our entries were all
it held; a malformed file is never written (`ErrMalformedSettings`) and reads
`imported_duplicates: true` in the status when its text names one of our
commands. In `~/.codex/config.toml` it writes only `hooks.state` entries
(`trusted_hash`) of our own launch-flag hooks (source `sessionFlags`, our exact
command strings), through codex's own app-server `config/batchWrite` (upsert):
never `projects.*`, never any other key, never with
`--dangerously-bypass-hook-trust`. The hashed and the launched hook strings
come from one function (`devpack.CodexHookSet`). `--remove` never touches
`hooks.state` (one trust key covers every folder). `integrate claude-code` and
`integrate remove` are unchanged.

Symlinks (2026-10-14, target 156, owner approved in ask #109): a
`settings.local.json`, or an imported `.codex/hooks.json` /
`.codex/config.toml`, that is a symlink is written through to its target —
the link itself is kept, and a removal that leaves nothing writes `{}` to the
target instead of deleting the link — only while that target resolves inside
the folder. A link whose target lies outside it (e.g. to
`~/.claude/settings.json`, which would make our hooks global) is refused by
the install and the removal alike (`ErrSymlinkOutsideFolder`), before any
write: the error names the link and its target and says to replace the link
with a regular file or point it inside the folder, and nothing is written
anywhere — the target stays byte-identical, the link untouched. The same
refusal holds when a directory between the folder and the file (`.claude`,
`.codex`) is a symlink leaving the folder. For the
settings file the install refuses even when nothing would change and the
removal whenever the file resolves; the `.codex` cleanup refuses only when it
has an entry of ours to take out. The skill directories are held to the
folder the same way: when `.claude`, `.claude/skills`, `.agents`,
`.agents/skills` or a skill directory under them is a symlink leaving the
folder, the install and the removal (the Claude Code and the codex setup
alike) refuse the skill step before writing or removing any skill file — the
new skill is not installed, the legacy one not removed, no emptied directory
dropped — and nothing outside is touched; a link inside the folder is
followed. A dangling link is refused as before. The
git `info/exclude` file is not held to the folder: it lives in the git dir,
often outside the folder anyway, and only our marked block is written there.

Since 2026-10-14 (board #535, session cleanup, PROJ-18): the entries the
install writes gain one `permissions.allow` string,
`Bash(<bin> workbench cleanup:*)` (`devpack.InstallCleanupPermission(dir,
bin)`, run by `integrate claude-code --workbench N`, `workbench resync`,
Re-run Setup and Repair), so the session's agent may run the cleanup command
in auto mode — that command only. `<bin>` is the same absolute binary the
hooks name, quoted the same way: single-quoted only when it holds a
character other than an ASCII letter, a digit or one of `/ . _ + : @ % , = -`
(`devpack.shellQuote`), so the rule matches the brief's
`Cleanup:` command text (`devpack.CleanupCommand`). The rule is added only
when no rule of ours is there; a rule of ours naming another binary (a stale
bin) is replaced in place and a duplicate of ours dropped; an exact match is
a no-op. A rule is ours only when its bin — optionally single-quoted — is an
**absolute** path whose basename is `watchtower`; a bare or relative form
(`Bash(watchtower workbench cleanup:*)`) is never one we write, so it is the
owner's and is never rewritten or removed. The owner's allow and deny
entries and every other key are never touched or reordered, and an entry
added between our read and our write (Claude Code writes the same file) is
kept: the edit is applied to a fresh read right before the atomic write.
The install, the removal and the status take no workbench id for it (one
rule serves the folder). A `permissions` or `permissions.allow` of the wrong
type is refused by every workbench step like a malformed `hooks`
(`ErrMalformedSettings`, the file byte-identical, the status reporting it
once), and the symlink rule above holds for it. `integrate status --json`
reports `cleanup_permission`, and the Desktop's Repair offer counts a
missing rule (`claudeNeedsRepair`), so a folder set up before #535 gets the
rule from one Repair or Re-run Setup; `workbench resync --json` reports
`cleanup_permission_added`.

*2026-10-15 (board #266, spec §4.3):* the install writes two skills into `.claude/skills` and
`.agents/skills`: the core `watchtower-workbench` (pack v12) always, and the `watchtower-flow` preset
unless the effective preset is `none` (`WorkbenchInstallOptions.PresetNone`, resolved like the hooks).
Both follow the DEV-04 rules. Preset `none` removes the preset only when its bytes are ours (shipped,
or matching the sidecar); an edited or foreign copy is kept and reported. An owner-edited core from
before v10 (marker below `v10`) keeps the single-file layout: nothing is written beside it, and
`resync` says "Your edited skill keeps the old single-file layout; delete it to take the v10 core and
preset." A core byte-identical to the shipped v8, v9, v10 or v11 with no sidecar is adopted as ours. A preset change
through `watchtower workbench methodology` runs `devpack.SyncMethodology` (the skills only: each core
copy goes through the install first, so a pre-v10 core of ours becomes v12, then the preset follows; no
hook or registration is touched); a changed `preset:` in `workflow.md` takes effect on the next install
or resync, and the brief names the mismatch. An owner-edited preset copy counts as installed under
`watchtower-flow` (no mismatch line, never rewritten); under `none` it is kept, `methodology --json`
reports it (`install_flow`/`install_codex_flow` `drifted` or `foreign`) and the brief says to delete it
by hand.

**Why locked:** The workbench folder is the owner's repository. An installer
that dropped one of the owner's settings keys or hooks, or clobbered an edited
skill, would make every later `integrate` a risk to the owner's own setup.

**Test guards:**
- `internal/devpack/workbench_settings_test.go::TestProj04_InstallKeepsOwnerSettingsKeysAndHooks`
- `internal/devpack/workbench_settings_test.go::TestProj04_MalformedSettingsLeftByteIdentical`
- `internal/devpack/workbench_settings_test.go::TestProj04_RemoveDeletesOnlyOurHook` (since 2026-10-11 also the Stop command entry and a leftover marker prompt; the owner's prompt and the marker off the first line stay)
- `internal/devpack/workbench_test.go::TestProj04_EditedProjectSkillIsNeverClobbered`
- `internal/devpack/workbench_stop_hook_test.go::TestProj04_StopHookKeepsOwnerStopHooksAndRemovesOnlyOurs`
- `internal/devpack/workbench_stop_hook_test.go::TestProj04_MalformedStopLeavesTheFileByteIdentical`
- `internal/devpack/workbench_settings_test.go::TestProj04_RemoveLeavingNothingThroughASymlinkEmptiesTheTarget` (since 2026-10-14 the link's target lies inside the folder)
- `internal/devpack/workbench_settings_test.go::TestProj04_InstallAndRemoveThroughASymlinkKeepTheLink` (since 2026-10-14 the link's target lies inside the folder)
- `internal/devpack/workbench_settings_test.go::TestProj04_SymlinkOutsideTheFolderIsRefused` (since 2026-10-14: install, the Stop and state installs and both removals refuse a link leaving the folder, with and without our hook in its target; the error names the link, its target and the fix; the target stays byte-identical, the link untouched; its `directory link` subtest: a `.claude` directory link leaving the folder is refused too, nothing created or changed outside) and its `.codex` twin `internal/devpack/codex_install_test.go::TestProj04_DedupeRefusesASymlinkOutsideTheFolder` (a link inside the folder is still written through; its `directory link` subtest covers a `.codex` directory link)
- `internal/devpack/skill_symlink_test.go::TestProj04_SkillDirectoryLinkOutsideTheFolderIsRefused` (since 2026-10-14: a `.claude`, `.claude/skills` or `.agents/skills` link leaving the folder — install and removal refuse, the outside tree stays identical, the link untouched) and `TestProj04_SkillDirectoryLinkInsideTheFolderIsFollowed`
- `internal/devpack/workbench_legacy_test.go::TestProj04_ResyncKeepsAnEditedLegacySkill` (an edited legacy skill and its sidecar stay byte-identical, reported `drifted`, its exclude line kept; a later removal keeps it too)
- `internal/devpack/workbench_state_hooks_test.go::TestProj04_StateHooksKeepOwnerHooksAndKeys` (the owner's own entries under the state events — a matcher, `async`, unknown keys and number literals — stay as they were next to exactly one entry of ours; remove takes only ours)
- `internal/devpack/workbench_state_hooks_test.go::TestProj04_MalformedStateEventLeavesTheFileByteIdentical` (each state event of the wrong type leaves the file byte-identical; since 2026-10-11 `SubagentStart` too, and `TestProj04_StateHooksKeepOwnerHooksAndKeys` keeps an owner `SubagentStart` entry)
- `internal/devpack/workbench_ask_guard_test.go::TestProj04_AskGuardReplacesOurEditedPromptAndKeepsOwnerHooks` (rewritten 2026-10-11 to the command entry: our edited marker prompt is replaced by the command entry, which carries the owner's keys from it — `x-owner` with its number literal kept; the owner's hooks — a marker of another workbench, the marker off the first line — and keys stay as they were; our command entry written from another binary is updated in place with the owner's keys on it kept; the owner's `Stop` and `PreToolUse` hooks stay)
- `internal/devpack/workbench_ask_guard_test.go::TestProj04_AskGuardCommandEntryCarriesTheKeysOfOurReplacedPrompt` (since 2026-10-11: with no command entry of ours yet, the fresh one carries every key of our replaced prompt but `type`, `prompt` and `command`, its `timeout` among them; a `command` key on the prompt never replaces ours (pinned by `TestProj04_AskGuardNeverCarriesACommandKeyOfOurPrompt`); a second resync changes nothing)
- `internal/devpack/workbench_ask_guard_test.go::TestProj04_MalformedPreToolUseLeavesTheFileByteIdentical` and its `Stop` twin `TestProj04_MalformedStopWithOurPromptLeavesTheFileByteIdentical` (since 2026-10-11: a malformed `hooks.Stop` holding our old marker prompt is neither upgraded nor removed, and is reported once by the install, the removal and the status)
- Codex (2026-10-12, board #399) — in `internal/devpack/codex_install_test.go`: `TestProj04_CodexTrustNeverTouchesOtherConfigKeys`, `TestProj04_DedupeKeepsForeignHooks`, `TestProj04_DedupeDeletesAFileThatWasOursAlone`, `TestProj04_DedupeEditsConfigTOMLInPlace`, `TestProj04_DedupeRefusesATOMLShapeItCannotEdit`, `TestProj04_MalformedImportedHooksNeverWritten`, `TestProj04_MalformedForeignFileIsNoDuplicate`; supporting: `TestCodexTrust_HashedStringsAreTheLaunchStrings` (I5), `TestInstallCodex_SkillBytesEqualClaudeCopy`, `TestInstallCodex_Idempotent`, `TestRemoveCodex_KeepsAnEditedSkillAndItsExcludeLine`, `TestRemoveCodex_RemovesSkillExcludeAndNeverTrust`; `internal/codex/appserver_test.go::TestAppServer_TrustSkipsForeignAndAlreadyTrusted`
- Session cleanup (2026-10-14, board #535) — in `internal/devpack/workbench_cleanup_permission_test.go`: `TestProj04_CleanupPermissionKeepsOwnerPermissions` (the owner's allow and deny entries, their order and other keys stay next to exactly one rule of ours), `TestProj04_MalformedPermissionsRefusedByEveryWorkbenchStep`, `TestProj04_CleanupPermissionRefusesASymlinkOutsideTheFolder`; supporting: `TestCleanupAllowRuleAndCommandQuoteTheBinaryTheSameWay`, `TestCleanupPermission_IdempotentAndReplacesStaleBin`, `TestCleanupPermission_MalformedSettingsIsAnErrorNotAnOverwrite`, `TestCleanupPermission_WriteKeepsAnEntryAddedMeanwhile`, `TestCleanupPermission_OwnerBareOrRelativeRuleIsNeverOurs`, `TestCleanupPermission_SymlinkInsideTheFolderIsFollowed`, `TestCleanupPermission_DirectoryLinkOutsideWithNoFile`
- supporting: `internal/devpack/workbench_ask_guard_test.go::TestAskToolBlock_InAnotherMatcherGroupIsRepaired` (our entry under `""`, `"*"`, no matcher or `Bash` counts as missing and moves back to its own group, the owner's hooks there kept), `TestRemoveAskGuardHooksKeepsTheOwnerEntries`, `TestStatusWorkbench_AskGuardFlagsEachMissingHook` (a marker prompt alone is not installed, Repair replaces it)
- `internal/devpack/workbench_methodology_test.go::TestProj04_PresetNoneRemovesOnlyOurFlow` (2026-10-15: ours removed, an edited copy and a foreign file byte-identical)
- `internal/devpack/workbench_methodology_test.go::TestProj04_DriftedV8KeepsSingleFileNoFlow` (Claude Code and Codex copies)

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

*2026-10-16 note (PROJ-19, board #267):* board columns do not change this contract — the rollup reads statuses only; a column move inside one status never moves a parent.

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

*2026-10-16 note (PROJ-19, board #267):* board columns do not change this contract — a move between columns of one status records no transition; a status change still records exactly one, whichever writer made it.

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

*2026-10-16 note (PROJ-19, board #267):* board columns do not change this contract — the drift check reads statuses and never a column.

## PROJ-08 — a workbench's documents are searchable only from its own sessions

**Status:** Enforced (amended 2026-10-03 — the folder's text files instead of attached documents; amended 2026-10-15 for the installed preset directories, board #266, listing only)

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
`.claude/skills/watchtower-project`, and since 2026-10-15 the installed
`watchtower-flow` preset in `.claude/skills` and `.agents/skills`, skipped
like the core), list only regular files, and keep the
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

**Status:** Enforced (Go and Desktop; the rule lives in Go; owner approved 2026-10-03; amended 2026-10-12 to the session's worktree, owner approved in ask #188, board #569)

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

Since 2026-10-12 (board #565/#569, owner approved 2026-10-12, ask #188): the
branch button and popover work on the worktree of the session the page shows
— the workbench folder when the page holds no session or the session's place
is the main folder, unknown, stale, outside the repository or removed.
`workbench git status|branches|switch|create` take `--folder F` (the Desktop
passes it for a worktree root only, so the main folder's argv is unchanged;
the `fetch` of board #563 takes the same rule when it lands). Go first lists
the repository's worktrees with git run in the workbench folder and accepts F
only when it is the workbench folder, inside it, or inside a listed worktree
(the longest match wins; paths compare case-insensitively on macOS); anything
else is refused (`folder_not_a_worktree`, `refused_detail` `outside` or
`missing`) — or, for `status`, reported as `folder_scope` `outside`/`missing`
with the main folder's status — before any git runs in F. An F that cannot be
read (any realpath failure but "does not exist") is never `outside`: `status`
answers `folder_scope: ""` with `status_ok: false` ("reading the folder: …")
and `branches`/`switch`/`create` refuse it as `folder_unreadable`; a failed
worktree listing is likewise scope `""` (status) or `git_failed`. The Desktop
lets a worktree root's branch menu write only with a status Go read in that
very worktree (`folder_scope: worktree`, `folder_root` that root): any other
answer is not stored as that root's status, the popover says the branch menu
is unavailable, and switch and create send nothing. Every rule above applies
to that worktree: the code viewer's edits saved first are those of its root
(and of any workbench's main root inside its work tree, never another
worktree's), the guards and confirmations are checked there, and
`--agent-running` is a live embedded agent session whose place is that work
tree, whose place is unknown, stale or removed (it may be anywhere), or —
another workbench's or a standalone row — whose folder is in that work tree.
A session of this workbench known to work in another worktree no longer
counts.

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
- Board #565, the session's worktree (2026-10-12, ask #188): `internal/workbenchgit/folder_test.go::TestProj10_FolderOutsideTheWorktreesIsRefusedBeforeGit`; `internal/workbenchgit/switch_test.go::TestProj10_GuardsRunInTheSessionsWorktree` (two worktrees of one repo: a dirty worktree refuses without `--stash` while the main folder is clean; a branch checked out in the main folder is refused there); `cmd/workbench_git_test.go::TestProj10_FolderFlagEnvelopeAndRefusal`; `WatchtowerDesktop/Tests/WorkbenchesViewModelGitTests.swift` — `testProj10_TheBranchMenuFollowsTheSessionsWorktree`, `testProj10_ASessionInAnotherWorktreeIsNotReportedAnUnknownOneIs`, `testProj10_ASwitchInAWorktreeSavesThatWorktreesEdits`; supporting: `internal/workbenchgit/folder_test.go` (`TestResolveFolderScopes`, `TestResolveFolderUnreadableRequestedIsUnresolved`, `TestResolveFolderGitFailureIsAnError`, `TestResolveFolderIgnoresCaseOnMacOS`), `cmd/workbench_git_test.go` (`TestWorkbenchGitStatusWithoutFolderIsUnchanged`, `TestWorkbenchGit_FolderUnreadable`, `TestWorkbenchGit_FolderListingFailure`); every existing `TestProj10_*`/`testProj10_*` above unchanged

**Locked since:** 2026-10-03 (proposed 2026-10-02)

## PROJ-11 — session state hooks never steer the session's agent and never show a stale state (v1 limits below)

**Status:** Enforced (Go and Desktop; owner approved 2026-10-03; amended 2026-10-03 to the session report's state set, owner-approved in the states brainstorm, and 2026-10-04 to the turn order of board #368, see the changelog; amended 2026-10-10 with the owner's approval, board #411, ask #139; amended 2026-10-11 for the chat question columns, owner approved in ask #148, board #395; amended 2026-10-11 for teammates in their turn, owner approved in ask #167, board #543; amended 2026-10-12 for Codex sessions — the heading said "never steer Claude Code" —, owner approved with the Codex design spec in ask #189, board #399; amended 2026-10-12 for Ready to check, owner approved 2026-10-12, ask #195, board #534; amended 2026-10-12 for the session's working directory, owner approved in ask #188, board #566; amended 2026-10-14 for the worktree ledger of the session cleanup, owner approved 2026-10-12 in ask #193, board #535)

**Observable:** `workbench session-state --workbench N` (installed async,
`"timeout": 5`, under `UserPromptSubmit`, `Notification`, `PostToolUse`,
`StopFailure`, since 2026-10-10 `SubagentStop` and, since 2026-10-11,
`SubagentStart` — six state hooks; the
first four are the core ones, and only they gate the Stop hook's state write
and the run mark, so a folder installed before `SubagentStop` or
`SubagentStart` keeps recording until Repair, while `integrate status`
reports `state_hooks` only with all six) and the Stop hook's state write (PROJ-07 note) never print to
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
dialog (`approval`, **Needs approval**); since 2026-10-12 (below) only an open
`question` ask keeps it — open asks that are all checks or reviews show
**Ready to check** instead. A StopFailure stores `waiting` with
`agent_failed_at` (= that write's `agent_state_at`) and `agent_error` (the
payload's top-level `error`, one line, ≤ 60 runes; `''` when missing) and
shows **Error** (red). `finish_session` stores `finished_at`/`finish_summary`
and shows **Finished** (blue; orange while the session has an open `question` ask; Ready to check below while
every open ask is a check or a review)
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
The order is: approval > error > working > agents working (since 2026-10-10, below) > ready to check (since
2026-10-12, below) > finished > open ask > stopped > running > not started,
the first match winning. The hook states (approval,
error, working, stopped) stay run-scoped; finished and the open asks are
not, so a session that is not live shows them as a ring in their colour.
`SessionAgentNoticePolicy` announces each transition of a live session into
needs approval, error, stopped or finished at most once, only while the app
is inactive; waiting on an ask, ready to check, or working with asks, gets no state notice (the ask's own notice announced
it).

Since 2026-10-10 (board #411, owner approved, ask #139): the Stop hook also
stores the count of in-flight background subagents its input reports
(`background_tasks` entries of type `subagent` or `workflow`;
`agent_background`, `agent_background_at`; NULL when none or the field is
absent). Only the Stop's write sets a count; a UserPromptSubmit, a
main-thread PostToolUse, a subagent's tool result over Needs approval
(Working, ask #20), a StopFailure, the `idle_prompt` notice, a new run and a
conversation switch clear it; a Stop repeating the same count only refreshes
`agent_background_at`; a subagent's PostToolUse over `waiting` only
refreshes `agent_background_at`, and a `SubagentStop` (async state hook)
only lowers the count, never below its own snapshot, ignoring an empty
`agent_type`. Neither touches `agent_state`, `agent_state_at`, `finished_at`
or the turn order. The Desktop shows a trusted `waiting` with a count > 0
(ended only by the probe below), or lowered to 0 in the last 120 s, as
**Agents working** (green, the count in the caption, `?` and the ask count
with open asks). The order becomes approval > error > working > agents
working > finished > open ask > stopped > running > not started. Agents
working is never announced; it counts as at the prompt (`isAtPrompt`) and
gets an ask answer's Return like Stopped.

Since 2026-10-11 (board #543, owner approved, ask #167: "only while they
work"): a named teammate counts while it is inside its own turn. The
`SubagentStart` and `SubagentStop` hooks of an agent with an `agent_id` and
a non-empty `agent_type` record that agent's turn in `agent_turns` (Go only;
the last start and stop stamps per `agent_id`, each only moving forward;
open while the start is later), whatever the row's state — a teammate works
across the main agent's turns — and nothing else: `SubagentStart` never
writes a state, its time, `finished_at`, the turn order or the count. The
count the Stop stores and a `SubagentStop` lowers to is: the `subagent` and
`workflow` entries whose id is not a closed turn (a finished subagent the
list still carries no longer counts), plus the open turns no entry lists, at
most one per `teammate` entry (an idle teammate, or one whose stop never
came once no teammate is listed, does not count). Only the Stop's write
still sets a count; a teammate starting a turn over Stopped shows from the
main agent's next Stop. A new run and a conversation switch clear
`agent_turns`; a main turn does not.

Since 2026-10-12 (board #534, owner approved 2026-10-12, ask #195): a session with open asks none of which is a
`question` — every one a `check` or a `review` — shows **Ready to check · ask #N** (**Ready for review** when
every one is a review; "· M asks" with more than one), purple with a checklist glyph, instead of Finished or
Waiting for you; one open `question` keeps Waiting for you, or Finished in orange. Like the open asks it is not
run-scoped: a session that is not live shows it as a ring. Working and Agents working keep their kind with only
checks or reviews open and show the ask count beside a checklist glyph instead of `?`. Ready to check counts as
at the prompt (`isAtPrompt`) like Waiting for you, and an ask answer's Return into it follows PROJ-12 unchanged.
An ask notice of a check or review reads "Ready to check: <title>" / "Ready for review: <title>".

A count with no report for 30 minutes is probed, never ended on the clock
alone. The probe (Go, no model turn) reads Claude Code's session registry
entry for the session (`~/.claude/sessions/<pid>.json`, matched by
`sessionId`): `busy` keeps Agents working; `waiting` leaves the row alone;
`idle`, `shell`, a missing or unknown status, no entry or a dead process
ends the count — a compare-and-clear on `agent_background_at` written by Go
only — and the row then reads Stopped (or its ask / finished state) with one
notice. A reading the probe could not take (a `ps` that cannot answer, a
registry with no readable entry file) is a failed probe, never "gone". Two
consecutive failed probes for the same count show it as over without a
write.

Since 2026-10-11 (owner asks v2, board #395, owner approved in ask #148):
the chat question columns (`chat_question`, `chat_question_at`, PROJ-13) are
written by the ask guard, the state hooks' clears and the escalation only,
and never change a state, its time, `finished_at`, the turn order or the
background count; a new run or conversation also clears them. The state
hooks' clears are a `UserPromptSubmit` whose event time is later than
`chat_question_at` (whatever its own state write does — a failed clear never
skips that write) and a main-thread `PostToolUse` whose `working` write ends
a stored `waiting`; a subagent's tool result, a `SubagentStart` or `SubagentStop`, a
notification and a StopFailure keep the question.

Since 2026-10-12 (board #565/#566, owner approved 2026-10-12, ask #188): the
state hooks, the Stop hook's state write and the `SessionStart` run mark also
record the main agent's working directory — the input's `cwd` from an event
without `agent_id` (a subagent's or teammate's event, a `SubagentStart` and a
`SubagentStop` never record one; a relative path, one over 4096 bytes or one
holding a NUL or a line break is ignored) — in `agent_cwd` with its event
time in `agent_cwd_at` (migration `00110`); a `codex` row's hooks record it
the same way. It rides in the state write's own UPDATE when one is made;
otherwise it is written alone only when it differs from the stored cwd, its
event is later than `agent_cwd_at` and not earlier than the run mark, so an
unchanged cwd writes nothing, an older report never replaces a newer one and
a late hook of the previous run never records one. A cwd never changes a
state, its time, `finished_at`, the error, the turn order, the background
count, the agent turns or the chat question, and never turns a repeat into a
state write. The run mark stores the new run's cwd (none when its input has
none), the no-hooks clear removes it, a conversation switch keeps it. The
hooks run no git, and the row readers that predate migration `00110`
(`GetTerminalSession`) read neither column. The Desktop trusts the cwd of a
live row only when `agent_cwd_at` is not earlier than that run's start — the
row's own run mark (`agent_turns`' `since`), never a Desktop launch time; a
live row without a readable run mark or stamp has no trusted cwd, and its
place is unknown. Output and exit code are unchanged.

Since 2026-10-14 (board #535, session cleanup, PROJ-18): the state hooks
also record, for any agent of the session, the worktree root and branch its
event's `cwd` resolves to (`terminal_session_worktrees`, migration `00111`),
only when that pair is new for the session, at most 64 pairs, resolved
without running git; a ledger failure is one stderr line and never fails or
changes the state write. Unlike the session's place above, subagents and
teammates count here (a worktree-isolated subagent's worktree is the one a
cleanup must find), and a codex row records too. The pair comes from the
symlink-resolved `cwd` (or its nearest existing ancestor), a walk up for
`.git` (`internal/gitdir`; an unreadable `.git` stops the walk) and a read
of the worktree's `HEAD` file — `""` for a detached HEAD or an unreadable
one, still recorded. A known pair or a full session is seen by one
read-only read and writes nothing (no write lock); a new pair is written by
`INSERT OR IGNORE` in its own transaction after the event's state write has
committed, never inside it. No `cwd`, an unresolvable one, one outside any
repository or a conversation that is not the row's records nothing. The
"session full" stderr line comes at most once per hook process.

Since 2026-10-12 (board #399, Codex): a `codex` row gets the same guarantees
from codex's own hooks, passed as launch flags (`workbench <verb> --agent
codex`, no `--workbench`): they find their row only through
`WATCHTOWER_TERMINAL_SESSION_ID` and need a row of kind `codex` with a
workbench (no variable, an unparsable id, a deleted row or another kind:
nothing written, nothing printed, exit 0); they write only when
the payload's `session_id` equals the stored id, so a codex row whose id is
still NULL accepts only its SessionStart write. Codex hooks are synchronous
(no hook outlives its turn), so there is no `agent_turn_end` and no
transcript turn-order check for codex rows. The mapping:

| Codex event | Stored write |
|---|---|
| `UserPromptSubmit` | `working` (as Claude) |
| `PermissionRequest` | `approval` (Claude's `Notification` `permission_prompt`) |
| `PostToolUse` | `working` over `approval`/`waiting`, ordered by time only |
| `SubagentStart` / `SubagentStop` | open / close the `agent_id` turn in `agent_turns` (only `agent_id` needed); a stop lowers the count to the open turns |
| `Stop` | the drift check, then `waiting` with the count of open turns (NULL when none); no `HasCoreStateHooks` gate (the whole hook set arrives in one argv and is trusted in one batch) |
| `SessionStart` | a NULL id is set on any source and the run marked; `startup`/`resume` with the same id mark the run; `resume` onto another id moves it and marks; `clear`, `fork` and a `compact` onto another id move it like Claude's switch path (no mark: `agent_state` stays until the next prompt); a same-id `compact` writes nothing but a changed transcript path; `startup` with another stored id writes nothing |

Codex v1 limits: no Error state (codex has no `StopFailure`), no idle notice
(`waiting` comes only from Stop), background agents only through
`SubagentStart`/`SubagentStop`, and no registry probe: `workbench
session-probe` reads `unknown` for a codex row without reading `~/.claude`,
so a stale count ends by the existing path. A Claude SessionStart never
writes into a codex row (a nested `claude` in a codex session's shell), and a
nested `codex exec` gets no launch flags, so it fires no hooks.

**Why locked:** Owner decisions of board #312 (2026-10-03), and the states
brainstorm of the session report (1a, 2a, 3a, 4: all). A status hook that
injected text into the agent, blocked a prompt, or showed a state for a dead
session would be worse than none; and "waiting for you" on every turn end
cried wolf — the owner must be able to trust that orange means their move.
Board #411 (asks #138, #139, #142): a turn end that left background agents
working read Stopped while they worked, so Stopped no longer meant the
session was done. The count enters only at the Stop's own snapshot and
every later event only lowers or clears it, so a late event never starts
it again once it was cleared; only Go writes it.

**Test guards:**
- `cmd/workbench_session_state_test.go::TestProj11_HookNeverWritesStdoutAndExitsZero` (since 2026-10-10 also with a `SubagentStop` input)
- `cmd/workbench_session_state_test.go::TestProj11_NestedSessionNeverMovesTheRow`
- `internal/db/terminal_sessions_test.go::TestProj11_OlderEventNeverOverwritesANewerState`
- `WatchtowerDesktop/Tests/Core/SessionAgentStatusTests.swift::testProj11_StateFromAnEarlierRunIsIgnored` (since 2026-10-10 also an earlier run's background count)
- `WatchtowerDesktop/Tests/Core/SessionAgentNoticePolicyTests.swift::testProj11_OneNoticePerTransition` (a turn end is announced as "stopped"; since 2026-10-10: working → agents working posts nothing, agents working → stopped posts once, agents working withdraws a stopped banner; since 2026-10-12, board #534: ready to check posts nothing and withdraws a stopped banner, a check filed then `finish_session` posts no finished notice, ready to check → stopped posts once)
- `WatchtowerDesktop/Tests/Core/SessionAgentStatusTests.swift::testProj11_StateOrder` (a table over the ten kinds in the order above, live and not live; since 2026-10-12, board #534, the rows before Ready to check keep their expectation because the fixture's asks are questions — the `row` helper's `questions` defaults to `openAsks`, stated in the test)
- `WatchtowerDesktop/Tests/Core/SessionAgentStatusTests.swift::testProj11_TurnEndWithoutAskIsStoppedNotWaiting`
- Board #534, Ready to check (2026-10-12, ask #195) — in `WatchtowerDesktop/Tests/Core/SessionAgentStatusTests.swift`: `testProj11_ReadyToCheckNeedsOnlyCheckOrReviewAsks` (checks only, reviews only, both → ready; no open ask → not), `testProj11_OneQuestionKeepsWaitingForYou` (two checks and a question → Waiting for you, `openQuestionAsks == 1`), `testProj11_ReadyToCheckIsAtPrompt` (live over this run's turn end → at the prompt; not live → a ring, never at the prompt); supporting: `TerminalSessionQueriesTests.testAgentStatesCountQuestionAndReviewAsks`, `SessionStatePresentationTests` (`testReadyToCheckIsPurpleWithChecklist`, `testWorkingWithOnlyChecksShowsChecklistGlyph`), `OwnerAsksViewModelTests.testProj12_AnAnswerIntoAReadyToCheckSessionGetsTheReturn`; the ask notice wording in `WatchtowerDesktop/Tests/Core/WorkbenchNotificationPolicyTests.swift`: `testCheckAskNoticeSaysReadyToCheck` (check → "Ready to check: T", review → "Ready for review: T", question or no kind → "Agent asks: T"), `testCoalescedChecksSayReadyToCheck` (only checks, or checks and reviews → "Ready to check (N)", only reviews → "Ready for review (N)", with a question → "Waiting for you (N)"); every existing PROJ-11 guard above unchanged
- `internal/db/session_report_test.go::TestProj11_WorkingClearsFinishedAndError`
- `internal/db/session_report_test.go::TestProj11_WorkingOverWorkingClearsFinished` and `cmd/workbench_session_state_test.go::TestProj11_WorkingOverWorkingClearsFinished` (finish, an Esc interrupt and a new prompt: the UserPromptSubmit's `working` over `working` clears `finished_at`; a plain `working` repeat stays a no-op)
- `internal/db/session_report_test.go::TestProj11_ToolRunWorkingOverWorkingKeepsFinished` and `cmd/workbench_session_state_test.go::TestProj11_PostToolUseOverWorkingKeepsFinished` (finish, then a PostToolUse `working` over `working`: still finished)
- `internal/db/session_report_test.go::TestProj11_ToolRunOutOfWaitingClearsFinished` and `cmd/workbench_session_state_test.go::TestProj11_PostToolUseIntoWorkingClearsFinished` (finish, then Stop (`waiting`) or a permission prompt (`approval`), then a main-thread PostToolUse `working`: cleared; the hook half also pins that a subagent's PostToolUse over a `waiting` without a background count writes nothing and keeps `finished_at`, and — rewritten 2026-10-10, board #411, same strictness — over a counted `waiting` changes only `agent_background_at`, every other column of the row unchanged, while a main-thread one out of it clears the count)
- `internal/db/session_report_test.go::TestProj11_StopFailureRecordsErrorOtherWritesClearIt` (db half: a later plain `waiting` keeps the error, a StopFailure with another error replaces it at its own time, `working`/`approval` clear it)
- `cmd/workbench_session_state_test.go::TestProj11_StopFailureRecordsErrorOtherWritesClearIt` (hook half: the payload's `error` field, a repeated StopFailure keeps its time and another error replaces it, a missing or non-string one stored as `''`, clipped to 60 runes on one line)
- `cmd/workbench_session_state_test.go::TestProj11_EndedTurnsToolResultNeverOverwritesTheStop` (board #368: the ended turn's tool result whose hook starts after the Stop's leaves `waiting`; a later self-started turn's first tool result still records `working`)
- `cmd/workbench_session_state_test.go::TestProj11_StopReplacesItsTurnsLateToolResult` (board #368: the ended turn's tool result landing first with a later stamp is replaced by the Stop's `waiting`, the stored time never goes back; a subagent's `working` keeps the time order)
- Board #411, background count (2026-10-10) — the hook half in `cmd/workbench_session_state_test.go`: `TestProj11_StopRecordsBackgroundSubagents` (subagents and workflows count, shells and teammates with no open turn do not; none, absent or malformed → NULL), `TestProj11_MalformedBackgroundTasksStillRecordWaiting`, `TestProj11_StopOverWaitingWithAnotherCountWrites` (another count is a transition: it writes and advances `agent_state_at`), `TestProj11_StopWithTheSameCountRefreshesTheReportTime` (only `agent_background_at` moves), `TestProj11_OnlyTheStopStartsBackground` (a late subagent tool result, a `SubagentStop`, the idle notice and a Stop reaching `session-state` leave a NULL count NULL), `TestProj11_SubagentStopOnlyLowersTheCount` (the min rule, its own id left out — since 2026-10-11 through its recorded turn end —, an empty `agent_type`, a missing or non-array list and an older stamp ignored, state, stamp and `finished_at` untouched; since 2026-10-11 over `working` it changes only `agent_turns`), `TestProj11_MainTurnAndIdleNoticeClearTheCount` (a permission prompt keeps it), `TestProj11_StopStateWriteNeedsOnlyTheCoreHooks` (a folder without the `SubagentStop` entry keeps its `waiting` and run mark; the status reports `state_hooks` false), `TestProj11_MalformedSubagentStopKeepsTheStopWaiting` (an owner's malformed `hooks.SubagentStop`: the Stop still records `waiting`, the status refuses the file and reads `state_hooks` false — PROJ-04)
- Board #411, the db half in `internal/db/terminal_sessions_test.go`: `TestProj11_StopWriteStoresTheSnapshot`, `TestProj11_OnlyTheStopStartsBackground`, `TestProj11_LowerTerminalBackgroundOnlyLowers` (never raises, never touches another column), `TestProj11_StopOverWaitingWithAnotherCountWrites` (a failed `waiting` keeps its error through a counted Stop and an idle notice, and `agent_failed_at` moves with `agent_state_at` so the row still reads Error; Desktop twin `SessionAgentStatusTests.testProj11_ErrorOutranksACountedStopOnGosRowShape`), `TestProj11_MainTurnAndIdleNoticeClearTheCount`, `TestProj11_NewRunAndConversationSwitchClearTheCount` (`MarkTerminalAgentRun`, `ClearTerminalAgentState`, `SetTerminalClaudeSessionID`; since 2026-10-11 also the chat question, including a row holding only a question)
- Owner asks v2 (2026-10-11, board #395): `internal/db/terminal_sessions_test.go::TestProj11_ChatQuestionWritesNeverTouchTheState` (every chat question write — set, replace, clear, take — leaves `agent_state`, `agent_state_at`, `finished_at`, `agent_turn_end`, `agent_tool_run` and `agent_background*` byte-identical); supporting: `TestChatQuestionSetReplaceClear`, `TestSetChatQuestionRefusesAStopOlderThanTheRun`, `TestClearChatQuestionBeforeKeepsANewerQuestion`, `TestTakeChatQuestionIsCompareAndTake` (same file); `cmd/workbench_session_state_test.go` (`TestChatQuestionClearedByTheOwnersPrompt`, `TestChatQuestionKeptByAnOlderPrompt`, `TestChatQuestionClearedByASelfStartedTurn`, `TestChatQuestionKeptByOtherHookEvents`, `TestChatQuestionClearedByARefusedPromptTouchesNothingElse`, `TestChatQuestionNewerThanTheSelfStartedTurnIsKept`, `TestChatQuestionFailedClearStillRecordsThePrompt`); `TestProj11_HookNeverWritesStdoutAndExitsZero` and every PROJ-11 hook guard above unchanged
- Board #411, the Desktop in `WatchtowerDesktop/Tests/Core/SessionAgentStatusTests.swift`: `testProj11_BackgroundAgentsAreNotStopped`, `testProj11_BackgroundWithAsksIsNotWaitingOnAsk`, `testProj11_BackgroundEndsOnGrace` (a count lowered to 0 ends after 120 s; a count > 0 never ends on the Desktop's clock), `testProj11_UnreadableOrFutureBackgroundStampIsNotBackground`, `testProj11_BackgroundIsAtPrompt`; `WatchtowerDesktop/Tests/Core/SessionAgentNoticePolicyTests.swift::testProj11_BackgroundIsNeverAnnouncedTheStopAfterOnce`
- Board #411, the staleness probe (2026-10-10, registry only, ask #142) — in `cmd/workbench_session_probe_test.go`: `TestProj11_ProbeNeverStartsBackground` (a `waiting` with no count: nothing written whatever the registry reads), `TestProj11_ProbeNeverEndsOnAFailedReading` (a `ps` that cannot answer for an existing pid, or a registry whose every entry file is unreadable → `ok: false`, the row byte-identical), `TestSessionProbeStageOneTable` (a count stale for 30 min: `busy` and `waiting` write nothing; `idle`, `shell`, a missing or unknown status, no entry, a dead or reused pid end the count and only it; not stale, an unparsable stamp or a row back to `working` → `not_stale`, nothing written), `TestSessionProbeStaleStampWithoutACountIsNotStale` (a NULL or 0 count next to a stale stamp → `not_stale`, nothing written), `TestSessionProbeNeverTouchesStateOrFinished` (whatever the outcome: `agent_state`, its time, `finished_at`, the turn order and the error stay), `TestSessionProbeEnvelopeShape` (one JSON object, exit 0; `ok: false` with an error on a missing row, another workbench, no ids, a broken config), `TestSessionProbeWorkbenchFlags` (the legacy `--project` spelling works; both flags → `ok: false`), `TestSessionProbeHasNoPingFlag` (no ping is built: `--ping` is an unknown flag); in `internal/db/terminal_sessions_test.go`: `TestEndTerminalBackgroundIsCompareAndClear` (clears only the two columns, only on the stamp the probe read; a newer heartbeat or Stop, a row back to `working`, another conversation or workbench → nothing written; a second end is a no-op); supporting in `internal/claudesession/registry_test.go`: `TestFindSessionPrefersTheLiveEntryOfASession`, `TestAliveRejectsAReusedPID` (a `ps` error is unknown, never dead), `TestFindSessionFirstWriteEntryHasNoStatus`, `TestFindSessionUnreadableRegistryIsAnError`, `TestFindSessionPropagatesAnUnreadableProcessTable`, `TestFindSessionTakesTheConfigDirLiterally`
- Board #411, the Desktop half of the staleness probe (2026-10-10, ask #142; the Desktop only decides when to run `workbench session-probe` and never writes) — in `WatchtowerDesktop/Tests/Core/SessionAgentStatusTests.swift`: `testNeedsProbeTable` (a count above zero whose report is at least 30 min old, never one from the future), `testProj11_DisplayOverEndsTheCountWithoutAWrite` (a count shown over reads as finished / ask / stopped); in `WatchtowerDesktop/Tests/Core/SessionProbeResultTests.swift`: `testDecodesEveryOutcomeAndTheFailureEnvelope`; in `WatchtowerDesktop/Tests/SessionBackgroundProberTests.swift`: `testNoProbeBeforeThirtyMinutes`, `testABusyCountIsProbedAgainOnlyAfterAnotherThirtyMinutes`, `testNoProbeOutsideAgentsWorking` (Needs approval, working, not live, standalone, an earlier run, a count of 0 or none), `testOneProbeInFlightPerSession`, `testOneFailedProbeNeverEndsTheCount`, `testTwoFailedProbesShowTheCountOverWithoutAWrite` (cleared by a probe that runs, a new report and a new run), `testAnEndedCountAsksForARead`, `testStopCancelsTheProbe`; in `WatchtowerDesktop/Tests/SessionAgentStateCenterTests.swift`: `testAProbeThatEndsTheCountPostsOneStoppedNotice`, `testTwoFailedProbesShowStoppedOnceWithoutAWrite`
- Codex (2026-10-12, board #399) — in `cmd/workbench_codex_hooks_test.go`: `TestProj11_CodexForeignSessionIDIgnored`, `TestProj11_CodexPermissionRequestIsApproval`, `TestProj11_CodexPostToolUseClearsApproval`, `TestProj11_CodexRowNeverGetsFailure`, `TestProj11_CodexStopGateTrueWithoutSettingsFile`, `TestProj11_CodexStopWritesWaitingAndOpenTurnCount`, `TestProj11_CodexStopWithoutOpenTurnsHasNoCount`, `TestProj11_CodexSubagentStopLowersCount`, `TestProj11_CodexSubagentWithoutAgentIDWritesNothing`; `internal/db/terminal_sessions_codex_test.go::TestProj11_CodexNullIDIgnoresStateWrites` (every hook writer, a real and an empty id: the NULL-id row byte-identical); supporting: `cmd/workbench_codex_hooks_test.go` (`TestCodexSessionStart_PlanTable`, `TestCodexSessionStart_StartupSetsNullID`, `TestCodexSessionStart_ResumeMarksRun`, `TestCodexSessionStart_ClearMovesIDAndClearsState`, `TestCodexSessionStart_CompactKeepsTheLiveTurn`, `TestCodexSessionStart_StartupWithOtherStoredIDWritesNothing`, `TestCodexSessionStart_NestedClaudeNeverTakesTheRow`, `TestSessionProbe_CodexRowIsUnknownWithoutClaudeDir`), `cmd/workbench_hook_row_test.go` (`TestCodexHook_WithoutItsRowWritesNothing`, `TestCodexHook_OnItsRowWithoutAnIDWritesNothing`, `TestResolveHookRow_CodexFromEnv`), `internal/db/terminal_sessions_codex_test.go::TestAgentGuardsAcceptCodex`; every existing PROJ-11 guard above unchanged
- supporting (board #411): `internal/devpack/workbench_state_hooks_test.go` (`TestInstallStateHooksAddsSubagentStopAndStart`, `TestHasStateHooksNeedsAllSixCoreNeedsFour`); `WatchtowerDesktop/Tests/Core/SessionStatePresentationTests.swift::testBackgroundIsGreenWithAgentCount`; `WatchtowerDesktop/Tests/SessionAgentStateCenterTests.swift::testBackgroundEndsOnTheClockWithoutAWrite` (the 120 s grace, one notice, no write); `cmd/workbench_check_test.go::TestBackgroundAgentsCountTable` (was `TestBackgroundSubagentsCountsSubagentsAndWorkflows`; its type and malformed-input cases kept, its `except` cases moved to `TestBackgroundAgentsLeavesOutTheStoppingAgent`), `TestStopHookInputParsesTheCapturedFixtures`
- Board #543, teammates in their turn (2026-10-11, ask #167) — in `cmd/workbench_session_state_test.go`: `TestProj11_TeammateCountsOnlyInItsTurn` (a replay of the captured inputs: two teammates in their turn at the Stop → 2, each `SubagentStop` lowers by one, the next Stop with both idle → NULL, an internal agent's stop changes nothing, a teammate's start over Stopped raises nothing until the next Stop), `TestProj11_FinishedSubagentStillListedIsNotCounted` (the last `SubagentStop` lowers to 0 although the list still carries the subagent that stopped before it), `TestProj11_SubagentStartNeverStartsOrRaisesTheCount` (over a counted `waiting` and over `working`: every column but `agent_turns` byte-identical), `TestProj11_LostTeammateStopIsCappedByTheList`, and in `internal/db/terminal_sessions_test.go` `TestProj11_LateHookOfThePreviousRunWritesNoTurn` (a turn stamped before the run mark writes nothing); `TestProj11_OnlyTheStopStartsBackground`, `TestProj11_HookNeverWritesStdoutAndExitsZero` and `TestProj11_NestedSessionNeverMovesTheRow` extended with `SubagentStart`; in `internal/db/terminal_sessions_test.go`: `TestProj11_AgentTurnStampsOnlyMoveForward`, `TestProj11_AgentTurnsCapDropsOldestClosed`, `TestProj11_AgentTurnWriteNeverTouchesTheState`, and `TestProj11_NewRunAndConversationSwitchClearTheCount` extended (the three resets NULL `agent_turns`; a row holding only turns is cleared)
- Board #565/#566, the session's working directory (2026-10-12, ask #188) — in `cmd/workbench_session_state_test.go`: `TestProj11_CwdNeverChangesTheState`, `TestProj11_UnchangedCwdWritesNothing`, `TestProj11_SubagentCwdIsNeverRecorded`; in `internal/db/terminal_sessions_test.go`: `TestProj11_OlderCwdNeverOverwritesANewerOne`, `TestProj11_CwdWriteNeverTouchesTheState`, `TestProj11_LateHookOfThePreviousRunWritesNoCwd`; `TestProj11_HookNeverWritesStdoutAndExitsZero` (a relative cwd and a recorded one among its inputs) and `TestProj11_NestedSessionNeverMovesTheRow` (the nested run's cwd moves nothing) extended with `cwd`; supporting: `cmd/workbench_session_state_test.go::TestHookCwdTable`, `cmd/workbench_brief_session_test.go` (`TestSessionStartRecordsTheRunsCwd`, `TestSessionStartWithoutCwdKeepsALateHooksCwdOut`), `cmd/workbench_check_test.go::TestStopHookRecordsTheCwd`, `cmd/workbench_codex_hooks_test.go::TestHookCwd_CodexHooksRecordTheMainAgentCwd`, `internal/db/terminal_sessions_test.go` (`TestSetTerminalAgentCwdWritesOnlyAChange`, `TestRunMarkStoresTheRunsCwdClearRemovesIt`, `TestConversationSwitchKeepsTheCwd`, `TestGetTerminalSessionNeedsNoCwdColumns`), `WatchtowerDesktop/Tests/Core/SessionPlaceTests.swift` (`testTrustedCwdTable`, `testResolveTable`); every existing PROJ-11 guard above unchanged
- Board #535, the worktree ledger (2026-10-14, ask #193) — in `cmd/workbench_session_ledger_test.go`: `TestProj11_LedgerRecordsANewWorktreeOnce` (two events in one worktree → one row; a new branch → a second row), `TestProj11_LedgerFailureNeverCostsTheStateWrite` (the ledger table dropped: the state is written, exit 0, one stderr line), `TestProj11_SubagentCwdIsRecordedButNeverMovesTheSessionPlace` (a subagent event in a worktree: a ledger row, the session's place unchanged — `TestProj11_SubagentCwdIsNeverRecorded` keeps pinning the place half); supporting in the same file: `TestSessionStateLedger_Resolver`, `TestSessionStateLedger_ResolvesSymlinks`, `TestSessionStateLedger_ResolvesASymlinkIntoASubdirectory`, `TestSessionStateLedger_OutsideARepositoryRecordsNothing`, `TestSessionStateLedger_NoCwdRecordsNothing`, `TestSessionStateLedger_ForeignConversationRecordsNothing`, `TestSessionStateLedger_StopsAtTheCap`, `TestSessionStateLedger_AFullSessionTakesNoWriteLock`, `TestSessionStateLedger_UsesTheFixture`, `TestCodexSessionStateLedger_RecordsTheCwd`; `internal/db/terminal_session_worktrees_test.go` (`TestRecordSessionWorktree_InsertsOnceAndIgnoresRepeats`, `TestRecordSessionWorktree_StopsAt64`, `TestHasSessionWorktree_UsesAReadOnlyTx`); every existing PROJ-11 guard above unchanged

**Locked since:** 2026-10-03

## PROJ-12 — an ask's answer is submitted only into a session whose hooks reported this run, never into a permission prompt they reported nor over the owner's half-typed text

**Status:** Enforced (Go and Desktop; owner approved 2026-10-03 as the spec's "PROJ-11", renumbered because PROJ-11 was taken by the session state hooks; amended 2026-10-04 with the owner's approval, board #379 — the owner asked for the answer to go to the agent by itself after answering an ask instead of having to press Enter, see the changelog; amended 2026-10-07 with the owner's approval, board #396 (owner directive 2026-10-05: «send it right away»); amended 2026-10-12 for Codex sessions, owner approved with the Codex design spec in ask #189, board #399; amended 2026-10-16 with the owner's approval (spec review ask #179, board #328): the diff reviewer's round line uses the same delivery)

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
session's hooks wrote during its current run
(`SessionAgentStatus.hooksReported`): a state, or — since 2026-10-07
(board #396) — the run's mark, which the SessionStart hook of a launch or
a resume (source `startup`/`resume`) writes only when the workbench's
folder has the session state hooks (`MarkTerminalAgentRun`: `agent_state`
NULL with `agent_state_at` of this run; without them a new run is cleared
with no stamp): the hooks run and the agent has not started a turn, so no
permission dialog can be up. A compaction — `/compact`, or the one Claude
Code runs by itself while idle — continues the run: its SessionStart
(`compact`) keeps the run's state and stamp. No hooks, or only an earlier
run's state or mark (or a stored value this build does not know), means
the app cannot tell a permission prompt is on screen. The state is not
`needsApproval`, and the session's Claude Code prompt held no text not
submitted (`TerminalCenter.promptDrafts`): nothing the owner typed since
their last submitting Return — only input ending in a plain CR not right
after ESC, whose last printable input before it (escape sequences and paste
brackets skipped) is not `\`, submits; Claude Code's line-break keys (`\`
then Return, Option+Return as ESC CR, Ctrl+J as LF, Shift+Return as an
escape sequence) and anything else leave a draft — and no earlier line the app pasted there without its Return (an
answer or a hand-off left typed). Keys sent while the session shows
`needsApproval` answer the dialog and change nothing. The Return goes only
into the process run the line was pasted into (`TerminalCenter.runs`, a
number per run: a relaunch reuses the process object), and an owner's
submitting Return during the pause has sent the line, so none follows and
no bar asks for one — withheld only when the state read after the pause
failed or shows a permission prompt (`inputAnswersDialog`, asked again
after that read: it may have been a second stale when the Return came, so
that Return may have gone into a dialog); then the line counts as still
typed, with its bar. The caller's other conditions (a hand-off's session
no longer idle at its prompt, a cancelled request) do not count against
it: the owner's Return itself starts a turn. Otherwise the line is
only pasted, the session's prompt counts as holding a draft until the
owner's submitting Return (or the process's start or close, which also
drop its bar), and a bar over the terminal says to press Return; the
condition that withheld the Return is logged (`TerminalCenter`/`OwnerAsks`
lines in the app's log). Nothing is typed while the session's
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

Since 2026-10-12 (board #399, Codex): the same gates hold for a `codex`
session, unchanged. The typing follows the session agent's input profile
(`AgentInputProfile`, chosen from the row's kind): Claude Code's bytes and
pauses are as above; Codex's submit is the same CR after the same bracketed
paste and the same pauses, and its Ctrl+J newline leaves a draft like Claude
Code's line-break keys. A codex run's mark is written by its SessionStart
(a NULL id set, or `startup`/`resume`), which codex fires only with the first
submitted prompt, so before that prompt the run is not reported and an
answer is only pasted. `approval` comes from codex's `PermissionRequest`
hook (PROJ-11). The Workbench launch passes `-c
check_for_update_on_startup=false`, so codex's update notice (where Return
means "Update now") cannot take a delivered Return.

The diff reviewer (board #328, 2026-10-16) uses the same delivery for its
rounds: the second fixed line `Review round #<id> sent (<n> comment[s]) — read
it with get_review <id> using the watchtower-workbench skill.` (Swift
`ReviewDeliveryLine`, a dual path with Go `reviewdiff.DeliveryLine` pinned by
`internal/reviewdiff/testdata/lines`) is typed through `SessionLineDelivery`
with `LineKey.review`, under exactly the gates above, and only after `review
send` stored the round as `sent` (REVIEW-04).

**Why locked:** Owner decisions (spec 2026-10-03, decision 3; board #379,
2026-10-04). An automatic Return could confirm whatever Claude Code's TUI
shows at that moment without the owner seeing it: a permission dialog's
default — hence the hold, the re-read before the paste and after the pause,
a Return only where the hooks vouch for the state this run (a run they
marked and the agent has not turned to has no dialog up: one comes only
from a turn, and its hook would write `approval`), and no
keystrokes without bracketed paste — or a half-typed prompt, which it would
submit together with the answer — hence no Return over the owner's draft.
Two lines pasted into one prompt would be submitted as one message — hence
one delivery per session at a time. A line with a line break of its own
could submit early or split; and a line typed before the answer is stored
would send the agent to read an answer that is not there — the
`WorkbenchCommentPrompt` rule carried over to asks.

**Test guards:**
- `WatchtowerDesktop/Tests/OwnerAsksViewModelTests.swift::testProj12_TheAnswerIsStoredBeforeTheLineIsTypedThenSubmitted` (a probed process reads the DB at input time; one bracketed paste with no control byte inside, then Return alone), `testProj12_ASessionAtAPermissionPromptGetsTheLineOnlyAfterTheAnswer` (nothing typed or copied while held, delivered once after), `testProj12_OverTheOwnersHalfTypedTextTheLineIsOnlyPasted` (at once and after a hold; a dialog key is no draft), `testProj12_WithoutTheStateHooksTheLineIsOnlyPasted`, `testAPermissionPromptDuringThePauseLeavesTheLineTyped` (a line left typed keeps the next answer from submitting it, through a dialog key), `testAHandOffLeftWithoutItsReturnKeepsTheAnswerFromSubmittingIt`, `testAFailedStateReadAfterThePauseLeavesTheLineTyped`, `testAFailedStateReadBeforeThePasteHoldsTheLine`, `testALongHeldAnswerSaysItStillWaitsAndIsNeverSentOnATimer`, `testProj12_AnAnswerIntoABackgroundSessionGetsTheReturn` (board #411: Agents working is a turn end, so the answer gets its Return as into a stopped session), `testProj12_ABackgroundSessionAtASubagentPermissionPromptHoldsTheLine` (board #411: a background agent's permission prompt stores `approval`, which outranks Agents working, and the line is held)
- `internal/asks/line_test.go::TestDeliveryLineFixtures`, `internal/asks/line_test.go::TestDeliveryLineIsOneLine`
- `WatchtowerDesktop/Tests/Core/OwnerAskPromptTests.swift` (`testTheLineMatchesEveryGoFixture`, `testTheLineIsOneLineWithNoControlCharacters`)
- `WatchtowerDesktop/Tests/TerminalCenterTests.swift` (`testAnAnswerLineIsPastedAsOneLineThenSubmittedWithItsOwnReturn` — the Return strictly after the pause, `testOverTheOwnersDraftSubmitPromptOnlyPastes`, `testTheOwnerTypingDuringThePauseStopsTheReturn`, `testALineLeftWithoutItsReturnKeepsTheNextFromSubmittingIt`, `testClaudeCodeLineBreakKeysLeaveTheDraft`, `testAFailedRefreshAfterThePauseStopsTheReturn`, `testWithoutBracketedPasteTheLineIsCopiedNotTyped`, `testAHandOffWithoutBracketedPasteIsCopiedAndNotSubmitted`)
- `WatchtowerDesktop/Tests/CodeNav/CodeHandoffCenterTests.swift` (`testAFailedStateReadAfterTheAnswersPauseLeavesTheLineTyped`, `testProj12_WithoutTheStateHooksAnAnswerIsOnlyPasted` — no state row, an earlier run's state or mark, an unknown value: only pasted, the bar asks for Return; `testProj12_AFreshOrResumedRunWithTheStateHooksGetsTheReturn` — the run's mark gets the Return and no bar, a relaunch's leftover state does not; `testProj12_ACompactWhileIdleKeepsTheReturn` — a mark, then a turn's `waiting`, each across a compaction's id move, read through the real stored-row query; all the wiring through a real `SessionAgentStateCenter`)
- `cmd/workbench_brief_session_test.go::TestProj12_ANewRunWithTheStateHooksIsMarked` (startup and resume with the state hooks mark the run; without them, or for a nested `claude -p`, nothing is stamped), `cmd/workbench_brief_session_test.go::TestProj12_CompactWhileIdleKeepsTheRunsState` (a `compact` SessionStart onto the same or a new id keeps a turn's `waiting` or the run's mark and its stamp)
- Codex (2026-10-12, board #399): `WatchtowerDesktop/Tests/TerminalCenterSubmitTests.swift` (`testProj12_CodexAnswerHeldWhileApproval`, `testProj12_CodexAnswerNotSubmittedBeforeHooksReported`); supporting: `TerminalCenterSubmitTests` (`testCodexSubmitIsBracketedPasteThenCR`, `testCodexMultilineAnswerOnePrompt`, `testCodexDraftTrackingUsesCodexNewline`), `WatchtowerDesktop/Tests/Core/AgentInputProfileTests.swift` (`testClaudeProfileBytesUnchanged`, `testCodexProfileIsCRSubmitWithCtrlJNewline`); every existing PROJ-12 guard unchanged
- `WatchtowerDesktop/Tests/Core/OwnerAskQueriesTests.swift` (`testAnsweringAnAskWithdrawnMeanwhileThrowsNotOpenAndWritesNothing`)
- `cmd/workbench_brief_test.go::TestProj12_AnsweredAskSurvivesAFullBoard`
- Quick ask (board #501, 2026-10-11; wording unchanged — a tap or a Reply in the banner or the stack is an answer in the Desktop and goes through the drawer's own call, `OwnerAsksViewModel.answer(_:with:)`, spec 2026-10-10 Part 11.2): `WatchtowerDesktop/Tests/OwnerAsksViewModelTests.swift::testProj12_AQuickAnswerFromTheBannerIsStoredThenDeliveredLikeTheDrawers` (the same stored answer and line bytes as the drawer's, stored before anything is typed; the same paste, pause and Return rules: held at a permission prompt, only pasted over the owner's draft), `testProj12_AReplyIsSentAsOtherOnOneLine` (line breaks and control characters as spaces, trimmed, at most 500 runes; a blank Reply sends nothing); supporting: `testAQuickTapOnAWithdrawnAskTypesNothing` (withdrawn meanwhile: nothing written or typed, the card leaves the banner and the stack)
- supporting: `OwnerAsksViewModelTests` (`testCopiedShowsTheCopiedAnswerHint` — no keystroke and no Return without bracketed paste; `testAPermissionPromptDuringThePauseLeavesTheLineTyped`; `testAHeldAnswerGoesNowhereOnceItsSessionStops`, `testAHeldAnswerNeverReachesALaterRunOfItsSession`, `testTwoHeldAnswersToOneSessionGoOneAfterTheOther`, `testAnAnswerDuringAnotherAnswersPauseIsQueuedThenGoesNext`, `testDismissingAHeldAnswerCancelsItsDelivery`, `testAfterTheOwnersReturnOrADialogKeyTheLineIsSubmitted`, `testAHoldThatEndedBeforeTheWaitIsNotMarkedStillWaiting`); `TerminalCenterTests::testATypedAnswerHintStaysThroughKeysIntoAPermissionDialog`; `CodeHandoffCenterTests::testAnAnswerIntoASessionWaitingThisRunIsSubmitted`, `testAHandOffIntoABackgroundSessionIsAtThePrompt` (board #411, ruling R52); `TerminalOwnerInputTests::testOnlyTheOwnersInputIsReported` (the owner's bytes, never the app's paste); `SessionAgentStateCenterTests::testAnAnswerHeldAtAPermissionPromptGoesOnTheReadThatShowsItAnswered` (the wiring through the stored states); `SessionAgentStatusTests::testTheRunsMarkSaysTheHooksReportThisRun`; `TerminalCenterTests` (`testARelaunchDuringThePauseGetsNoReturn`, `testALineIntoARelaunchedRunDuringAnOldPauseIsSubmitted`, `testTheOwnersReturnDuringThePauseSkipsOurs` — also `\` then Return is no submit, `testTheOwnersReturnDuringThePauseOverADialogOrAFailedReadLeavesTheLineTyped`, `testTheOwnersReturnDuringThePauseCountsWhateverTheCallersOtherCondition`, `testARestartDropsTheLastRunsPasteBar`); `cmd/workbench_brief_session_test.go::TestApplySessionStart_HooksReadErrorStillMovesTheID`; `OwnerAsksViewModelTests` (`testARelaunchDuringThePauseGetsNoReturn`, `testARelaunchDuringTheReadBeforeThePasteTypesNothing`, `testTheOwnersReturnDuringThePauseSendsTheAnswer`); `internal/db/terminal_sessions_test.go` (`TestMarkTerminalAgentRun_NewRunStartsEmpty`, `TestClearTerminalAgentState_LeavesNoStamp`); `cmd/workbench_brief_test.go::TestProjectBrief_AnsweredAsksForItsSession` (own and session-less listed, another session's counted, nothing delivered by the brief); `internal/tools/workbench_asks_test.go::TestGetAsk_OpenAnsweredAndAnotherWorkbench` (only `get_ask` delivers)
- Diff reviewer round line (2026-10-16, board #328): `WatchtowerDesktop/Tests/Core/ReviewDeliveryLineTests.swift::testMatchesGoFixtures`, `WatchtowerDesktop/Tests/SessionLineDeliveryReviewTests.swift`, `internal/reviewdiff/line_test.go::TestDeliveryLine_Fixtures`

**Locked since:** 2026-10-03

## PROJ-13 — the ask guard never traps a turn

**Status:** Enforced (Go; owner approved 2026-10-03 as the spec's "PROJ-12", renumbered; amended 2026-10-03 with the `finish_session` reminder (prompt v2); amended 2026-10-10 for the ask guard v3 (#478); rewritten 2026-10-11 for presence and the three ask levels — owner approved 2026-10-05, ask #66; 2026-10-10, asks #145/#146; the business spec that amends PROJ-13 approved 2026-10-11, ask #148; board #395, see the changelog; amended 2026-10-12 for Codex sessions, owner approved with the Codex design spec in ask #189, board #399; amended 2026-10-15 for the ask guard modes and the finish check — owner approved in ask #141 (modes) and ask #146 (spec), board #266)

**Observable:** The `Stop` ask guard is the command hook `workbench ask-guard
--workbench N --stop` (`timeout: 30`). It never blocks when `stop_hook_active`
is true, and it blocks at most once per Stop, so the Stop after a block always
passes. It classifies `last_assistant_message` with the v4 text
(`internal/devpack/askguard_classifier.md`, pinned by a golden) through
Watchtower's light-tier model (≤ 20 s, its child process group killed and
reaped on the budget or a signal), and decides by a fixed table: in the
request phase a named ask covers only itself: a request for a review, a manual
check or several decisions left as text that is not the named ask is sent back
(`R-full`); a single short question left as text that is not the named ask
passes only when the owner is present in this session (its pane on screen in
the key window of the active app, the screen awake and unlocked:
`owner_presence` names the session with a write at most 90 s old), the folder
has the core state hooks, the finish check passes, and the question is
recorded on the session (`chat_question`, `chat_question_at`); otherwise it is
sent back (`R-away`); a closing summary after `finish_session` is never a
request. Then, as in v2/v3, a message that says all of the session's work is
complete without saying it called `finish_session` is sent back (`R-finish`;
with a short question it would have passed, `R-finish-ask`, nothing recorded).
On `stop_hook_active` a short question is still recorded (raised at once by
the Desktop when the owner is away), never sent back. The reasons are fixed Go
strings. An input or model failure — unreadable, empty or never-closed input,
a model timeout, error or malformed output, a panic — prints nothing on stdout
and exits 0, so the turn ends. A database failure — cannot open, locked,
missing columns, a read or the record failing — counts as the owner being
away, so a short question is sent back once and never passed unrecorded
outside a continued turn (on `stop_hook_active` it passes unrecorded, never
blocked). The
guard opens the database with `db.OpenExistingRW` (never creates, never
migrates), reads under a 500 ms busy timeout, writes only the chat question,
after the model call and under a 1 s busy timeout, and never touches
`agent_state`, its time, `finished_at`, the turn order or the background
count. A recorded chat question is cleared by the guard's next Stop of that
conversation that records none, the owner's next prompt, a turn the agent
starts itself, a new run or conversation, or its escalation; `workbench
escalate-question` raises it to an ask only while it is still the stored one
(compare on `chat_question_at`) and the session still waits on that turn end
(`agent_state = 'waiting'`, stamped at most 30 s after it), never twice.
`integrate`/`resync` replace every `Stop` prompt entry carrying our marker for
N (v1–v3 or an edit) with the command entry; `integrate status` reports
`ask_guard` only for the command entry. The `PreToolUse` command hook
(`workbench ask-guard --workbench N --pre-tool-use`, matcher
`AskUserQuestion`, `timeout: 5`) prints the deny decision only when workbench
N exists and its stdin (read for at most 0.5 s) names `tool_name`
`AskUserQuestion`; when one of those checks fails — another tool, unreadable,
empty or never-closed input, a bad or unknown id, a deleted workbench, a
broken config, a missing or locked database, a panic — it prints nothing on
stdout or stderr and exits 0, so the tool runs. Once both checks pass it
always denies; the reason is the present one only when the presence read
succeeds and names this session, and the away reason otherwise (a failed
presence read never lets the tool run). It opens the database with
`db.OpenExisting` (`query_only`, 500 ms busy timeout), and its reads share a
1.4 s budget counted from the database open (`askGuardReadBudget`: the
workbench read under its busy timeout, then the presence reads; with the 0.5 s
stdin wait that stays under 2 s) — presence reads still running at its end
read as away, so it denies with the away reason — so it finishes in under 2 s.

**Implementation notes (2026-10-11; what the code does where it is more
precise than the wording above):** (1) The model child is an isolated CLI
child (`SetIsolatedChild`: its own process group, killed whole and waited for
on the budget, a SIGINT, a SIGTERM — Claude Code's hook timeout — or a SIGHUP
— its terminal gone; it never inherits `WATCHTOWER_TERMINAL_SESSION_ID`), the
message travels on stdin, and the classifier reads only the message's last 32
KiB (cut on a rune boundary behind a fixed `[earlier text cut]` line). A
signal at any point before the output writes nothing more and prints nothing.
(2) The `--stop` run calls no model at all, and prints nothing, when the
workbench certainly no longer exists (a deleted workbench's leftover hook,
read `query_only`; a database that cannot be read is not "gone"), or on a
`stop_hook_active` turn outside a Desktop terminal row of the payload's
conversation (nothing to record or clear). A bad id or a broken config also
prints nothing. (3) A read failure after the session matched blocks only the
record: the older question is still cleared (4.2 step 6). (4) "Present" for
the `PreToolUse` reason is resolved as the Stop guard does: the presence names
this session's `claude` row of workbench N running the payload's conversation,
**and** the folder has the core state hooks (without them the Stop guard could
not record a plain-text question, so the agent is pointed at `ask_owner`). Any
read failure or a panic after the workbench was found reads as away; the tool
stays denied. The hook's reads share a 1.4 s budget counted from the database
open (`askGuardReadBudget`): the workbench read (under the 500 ms busy
timeout), then the presence reads (the session row, its workbench, the state
hooks, the presence), raced against the budget's end; presence reads still
running then read as away and the hook denies with the away reason (the
database is closed once they end). (5) `workbench escalate-question` opens the
database with `db.Open` (it migrates, as every writer CLI), waits up to 5 s
for the write lock (then `busy`), takes the question only from workbench N's
`claude` row, and answers a flag it cannot parse with a `bad_args` envelope,
exit 0. (6) The classifier call is registered as `workbench.ask_guard` on the
light tier in `digest.TierForSource` (both providers; on codex the message
goes to OpenAI, business D1). Its text is embedded and **not** a prompt-store
entry — a documented exception to the DB-backed prompts rule, since this
contract pins the text.

**Codex (2026-10-12, board #399):** a `codex` session runs the same guard as
`workbench ask-guard --agent codex --stop` (Stop group 1, `timeout: 30`) and
`--pre-tool-use` (a `PreToolUse` group with matcher `request_user_input`,
`timeout: 5`), both passed as launch flags and resolving the row through
`WATCHTOWER_TERMINAL_SESSION_ID` (a codex row with a workbench; otherwise
nothing printed, exit 0). `--stop` classifies the codex Stop's
`last_assistant_message` with the same v4 text and decision table (an empty
message calls no model), honours `stop_hook_active` the same way, and prints
the same block JSON, which codex reads as Claude Code does. `--pre-tool-use`
denies `request_user_input` with the same present or away reason, within the
same read budget; presence names the codex row. The "folder has the core state
hooks" condition is true for a codex row by construction (its hooks arrive and
are trusted as one set). The never-traps rules above hold unchanged.

*2026-10-15 (board #266, spec `docs/superpowers/specs/2026-10-15-workbench-configurable-methodology-design.md` §7):*
the guard runs under the workbench's ask guard mode and finish check, resolved at run time by
`workbenchmethod.ResolveSession` (the owner's setting in `projects.ask_guard_mode`/`finish_check`,
migration `00123`, else the session folder's `.watchtower/workflow.md`, else `strict` and `on`). Any
failure to read them — no database, a schema without the columns, a lock, a present but malformed
terminal-session variable — resolves to `strict` and `on`, silently. `strict` with the finish check on
is the table above, unchanged (`decideStop`). `soft`:
the classifier runs; a request is never sent back — a chat request is recorded whatever the presence,
a full request is recorded with the message's own text (at most 1800 runes counting a leading "…": a
longer message keeps its last 1799 runes after the "…"; `chat_question.level` `full`) and raised as a
Full ask with no options; a failed record passes. Recording needs a Watchtower terminal session (a
Desktop terminal row of this workbench with the state hooks): outside one, soft passes a request and
records nothing. `off`: no request is checked
and nothing is recorded or cleared; the classifier runs only for the finish check. The finish phase
runs only with the finish check on. With `off` and the finish check off the hook returns after
decoding stdin, before any classifier call. `stop_hook_active` never blocks in any mode. PreToolUse
(`AskUserQuestion`, `request_user_input`): `strict` denies as above; `soft` denies only while the owner
is away (the away reason) and lets the tool run while the owner is present in this session; `off` lets
it run. The PreToolUse mode read runs inside the shared `askGuardReadBudget`, and a panic in it
recovers to the strict away denial; the Stop mode read is bounded per read by `askGuardBusyTimeout`.
The classifier text (v4 golden) and the fixed reasons are unchanged. Accepted limits: under `soft` a
recorded question is raised only while the Desktop runs, and only in Watchtower terminal sessions.

**Why locked:** Owner decision (spec 2026-10-03, decision 3), the PROJ-07
precedent, and the three ask levels (asks #66, #145, #146): a guard that could
loop a turn or fail a turn would be worse than none; one that bounced a quick
question while the owner is watching wastes the owner's time; one that let a
question through to an empty room leaves it unseen — so a question passes as
text only where the owner is, and only once it is recorded for raising. A
broken Watchtower may cost at most one send-back of a plain-text question
(what every plain-text question got before v4), never a loop and never a
blocked tool: the owner approved this narrowing of "never block because
Watchtower is broken" with v4 (business D1, ask #148).

**Test guards** (names kept where they exist; none relaxed):
- `internal/devpack/workbench_ask_guard_test.go::TestProj13_AskGuardPromptPassesAContinuedTurnAndAFiledAsk` — now over the v4 classifier golden. Each clause it checked over v3 maps to a v4 golden clause or a named Go guard, so no assertion is dropped:

  | v3 clause checked before | v4 home |
  |---|---|
  | `Return {"ok": true} unless a failure case below clearly applies.` | golden: outline 2 (default unless a case clearly applies) |
  | `Return {"ok": true} when stop_hook_active is true.` | Go row 1: `cmd/workbench_askguard_test.go::TestProj13_ContinuedTurnNeverBlocks` |
  | `These pass, except that failure case 1 takes priority over this list:` | golden: outline 7 (the request check takes priority) |
  | `- Unfinished work is never case 2: …` (with "a question … inside a progress report is still case 1") | golden: outline 8 (unfinished work, incl. a next step the agent takes) and outline 7 (request inside a progress report) |
  | `- A named ask is never a failure: … including step-by-step help …` | golden: outline 3 (`names_ask` incl. step-by-step help, `request_outside_ask`); Go: `TestProj13_StopGuardDecisionTable` rows E7, E7a, E7b |
  | `- A closing summary that says it called finish_session … never affects case 2.` | golden: outline 4; Go: decision table row E9b |
  | `and names no "ask #<number>".` | Go: decision table row 3 (covered) and rows E7/E7b |
  | `does not say it called finish_session (for example "session finished")` | golden: outline 8 |
  | `When unsure, return {"ok": true}.` | golden: outline 2 ("and when unsure") |
- `internal/devpack/workbench_ask_guard_test.go::TestProj13_OlderPromptsAreUpgradedToTheCurrent` (#478's guard, rewritten to the same strictness: v1, v2, v3 and an edited marker prompt of N each become the one command entry; another workbench's marker prompt stays; a second resync changes nothing; the owner's `Stop` hooks and keys byte-exact)
- `cmd/workbench_askguard_test.go::TestProj13_AskGuardFailurePrintsNothingAndExitsZero` (extended to `--stop`: every input failure, a model timeout, a model error, malformed model output, a panic)
- `cmd/workbench_askguard_test.go::TestProj13_AskGuardFinishesFastOnALockedDatabase` (both modes; `--stop` with a stub model: a locked DB reads as away)
- `cmd/workbench_askguard_test.go::TestProj13_AskGuardWithNoDatabaseCreatesNothing`, `TestProj13_AskGuardNeverRunsAMigration` (both modes)
- `cmd/workbench_askguard_test.go::TestProj13_StopGuardDecisionTable` (each row of the table with a stub model and seeded presence)
- `cmd/workbench_askguard_test.go::TestProj13_ChatPassesOnlyWhenPresentAndRecorded` (present → pass and recorded; stale write, another session present, no env, nested session, no core state hooks, read error, write error → `R-away`)
- `cmd/workbench_askguard_test.go::TestProj13_ContinuedTurnNeverBlocks` (every model verdict with `stop_hook_active`: nothing printed; a chat request recorded present or away)
- `cmd/workbench_askguard_test.go::TestProj13_StopGuardNeverTouchesTheStateColumns`
- `cmd/workbench_askguard_test.go::TestProj13_ACancelledModelCallLeavesNoProcess` (SIGTERM mid-call: the stub's process group is gone before the hook exits)
- `cmd/workbench_escalate_test.go::TestProj13_EscalationIsCompareAndTake` (filed once; a cleared or replaced question, a state off `waiting` or stamped later than the tolerance → `gone`, nothing written; a second run → `gone`)
- Codex (2026-10-12, board #399) — in `cmd/workbench_codex_hooks_test.go`: `TestProj13_CodexAskGuardStopUsesLastAssistantMessage`, `TestProj13_CodexAskGuardEmptyMessageNoModelCall`, `TestProj13_CodexPreToolUseDeniesRequestUserInput`, `TestProj13_CodexPreToolUseForeignSessionIsAway`; supporting: `cmd/workbench_hook_row_test.go::TestCodexHook_WithoutItsRowWritesNothing` (each codex hook without its row: no output, exit 0); every existing PROJ-13 guard unchanged
- supporting (escalation): `cmd/workbench_escalate_test.go` (`TestEscalateFilesAQuickAskWithTheSameOptions`, `TestEscalationRaceFilesOneAsk`, `TestEscalateFourOptionsIsFull`, `TestEscalateZeroOptionsIsQuick`, `TestEscalateAtTheOpenCapKeepsTheQuestion`, `TestEscalateEnvelopeShape`); `internal/db/terminal_sessions_test.go::TestTakeChatQuestionIsCompareAndTake`
- supporting: `cmd/workbench_askguard_test.go::TestAskGuard_DeniesAskUserQuestionInALiveWorkbench` (now with both reasons), `TestAskToolDenialReasonsAreTheSpecsText`, `TestAskGuardReasonsAreTheSpecsText`, `TestDecideStopTable`, `TestStopWithoutAQuestionClearsTheOlderOne`, `TestAskGuardModelOutputNormalisation`, `TestAskGuardMessageTail`, `TestAskGuardModelChildIsIsolated`, `TestStopGuardReadFailureStillClearsTheOlderQuestion`, `TestStopGuardDeletedWorkbenchPassesSilently`, `TestStopGuardCancelledDuringTheDatabasePhaseWritesNothing`, `TestStopGuardContinuedTurnWithoutASessionCallsNoModel`, `TestStopGuardUnreadableSessionVariableReadsAsAway`, `TestTierForSourceAskGuardIsLight`; `internal/devpack/workbench_ask_guard_test.go::TestAskGuardClassifier_IsTheV4Golden`; `internal/digest/isolated_child_test.go` (`TestIsolateChildKillsTheGroupAndDropsEnv`, `TestIsolateChildCancelAfterTheWaitKillsNothing`); `internal/db/owner_presence_test.go::TestOwnerPresentInStaleWriteIsAbsent`; `cmd/integrate_workbench_test.go::TestIntegrateWorkbenchStatusJSON_AskGuardKeys` (a prompt-only folder → `ask_guard: false`)
- `cmd/workbench_askguard_modes_test.go::TestProj13_ModeTable` (2026-10-15: every mode × finish check against the table; strict + on is `decideStop`)
- `cmd/workbench_askguard_modes_test.go::TestProj13_SoftNeverSendsBackAndAlwaysRecords` (owner away: a chat and a full request pass and are recorded, the full one with its text and level `full`)
- `cmd/workbench_askguard_modes_test.go::TestProj13_OffWithFinishOffCallsNoModel` (set personally or in the folder file: no model call, the older question kept)
- `cmd/workbench_askguard_modes_test.go::TestProj13_UnreadableModeIsStrict` (a schema without the columns: strict despite `ask_guard: off` in the file; no database: `strictModes`)
- `cmd/workbench_askguard_modes_test.go::TestProj13_UnreadableSessionVariableIsStrict` (a malformed terminal-session variable: strict + on in the Stop and PreToolUse hooks)
- `cmd/workbench_askguard_modes_test.go::TestProj13_PreToolUseFollowsMode` (Claude Code and Codex; an unreadable mode denies)
- supporting: `TestProj13_CodexStopFollowsTheMode`, `internal/workbenchmethod/resolve_test.go::TestResolve_UnreadableDatabaseIsStrict`, `cmd/workbench_escalate_test.go::TestEscalateZeroOptionsFromAFullRequestIsFull`

**Locked since:** 2026-10-03

## PROJ-14 — a session report shows only that session's work, and only the session itself says it finished

**Status:** Enforced (Go; owner approved 2026-10-03, spec `docs/superpowers/specs/2026-10-03-workbench-session-report-design.md` Part 8; amended 2026-10-12 for Codex sessions, owner approved with the Codex design spec in ask #189, board #399)

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
stays the only place that flags `merged_but_open`. Since 2026-10-12 (board
#399) the report's sessions include `codex` rows (`Summaries` filters on
`kind IN ('claude','codex')`, a codex row with a NULL id included; shell rows
never), and the link and finish rules hold for them unchanged: codex passes
`WATCHTOWER_TERMINAL_SESSION_ID` to the `watchtower-workbench` MCP server
only because the launch names it in `mcp_servers.watchtower-workbench.env_vars`.
A comment's `agent_label` comes from the resolved row's kind (`codex-cli` for a
codex row), else the server's `--agent` flag, else `claude-code`.

**Why locked:** Owner decision (spec 2026-10-03, decision 4). A report that
listed another session's work, or a session marked finished by anything but
its own agent, would make the owner trust a summary that is not this
session's; a report that wrote the board would move statuses behind the
owner's and the agent's backs.

**Test guards:**
- `internal/tools/workbench_finish_test.go::TestProj14_OnlyOwnSessionWritesLink` (no variable, an unknown id, garbage, a negative id and another workbench's session: no link from any write tool)
- `internal/tools/workbench_finish_test.go::TestProj14_FinishNeedsATerminalSession` (another workbench's session is never marked; no audit row, no link)
- `internal/sessionreport/report_test.go::TestProj14_ReportNeverWritesTheBoard`
- `internal/sessionreport/refresh_test.go::TestSessionReport_ReportsAWorktreeBranch` (a placed session's `wt/` branch, board #229)
- Codex (2026-10-12, board #399): `internal/sessionreport/summary_test.go::TestSessionReport_IncludesCodexSessions`; supporting: `internal/tools/workbench_docs_test.go::TestAgentLabel_CodexRowIsCodexCLI`, `internal/devpack/codex_hooks_test.go::TestCodexMCPOverrides_IncludeApproveAndAgentFlag` (the `env_vars` entry); every existing PROJ-14 guard unchanged
- supporting: `internal/tools/workbench_finish_test.go` (`TestSessionLinks_EachWriteToolLinksItsTargets`, `TestSessionLinks_ReadToolsLinkNothing`, `TestSessionLinks_AFailedLinkKeepsTheWriteAndWarns`, `TestSessionLinks_LegacyBindingLinksTheSame`)

**Locked since:** 2026-10-03

## PROJ-15 — an archived workbench target is hidden, never lost

**Status:** Enforced (Go and Desktop; owner approved 2026-10-04, ask #33, spec `docs/superpowers/specs/2026-10-04-workbench-board-archive-design.md` §3; amended 2026-10-07 (board #415), approved by the owner in ask #106, spec `docs/superpowers/specs/2026-10-07-workbench-archive-now-design.md` §3)

**Observable:** A workbench target is archived iff it and every descendant
on the same board are `done` or `dismissed`, every close time among them
parses, and either its workbench's `projects.archive_after_days` (migration
`00103`, default 14, `CHECK` 0..365, 0 = never) is above 0 and the newest
close time among them (a target's latest `target_status_history.changed_at`,
else its `updated_at`) is more than `archive_after_days` days old, or the
workbench's `projects.archived_through` (migration `00105`, set by the
Desktop's "Archive Closed Targets Now", cleared by "Undo Archive Now") is
set and that newest close time is not after it. The rule lives only in the SQLite view
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
next read, with the status change recorded like any other (PROJ-06). A
target closed or reopened after `archived_through` is judged by the age rule
alone until the next Archive Now. A group
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
- `internal/db/proj15_archive_now_test.go` — `TestProj15_ArchiveNowArchivesEveryClosedSubtree`, `TestProj15_ArchiveNowGroupsGoWhole`, `TestProj15_ArchiveNowCloseAfterTheStampStays`, `TestProj15_ArchiveNowLaterCloseInAGroupKeepsTheGroup`, `TestProj15_ArchiveNowReopenRestores`, `TestProj15_ArchiveNowSameSecondIsArchived`, `TestProj15_ArchiveNowUnderNever`, `TestProj15_ArchiveNowUnparseableCloseTimeKeepsTheChain`, `TestProj15_ArchivedThroughMustParse`, `TestProj15_UndoArchiveNowRestoresOnlyWhatTheAgeRuleWouldNot`, `TestProj15_ArchiveNowWritesNothingPerTarget`, `TestProj15_ArchiveNowIsPerWorkbench`, `TestProj15_LargeBoardReadIsFastWithAStamp`
- `cmd/workbench_archive_test.go::TestProj15_DriftStillSeesArchivedUnmergedWork` (age rule and stamp-only cases)
- `internal/tools/workbench_board_archive_test.go` — `TestGetTarget_FindsAnArchivedTargetAndSaysSo`, `TestUpdateTarget_ReopeningRestoresAnArchivedTarget`, `TestCreateTargets_UnderAnArchivedParentBringsItBack`, `TestListTargets_ArchivedOnlyWithIncludeArchived`, `TestListTargets_IncludeArchivedWithoutStatusListsArchivedTargets`, `TestWorkbenchBoard_ArchivedSubtreesOnlyOnRequest`
- `WatchtowerDesktop/Tests/Core/WorkbenchQueriesTests.swift::testBoardMarksArchivedTargetsFromTheViewAndKeepsThemInTheTree`, `WatchtowerDesktop/Tests/Core/WorkbenchBoardOutlineTests.swift::testSearchAlwaysMatchesArchivedTargets`, `WatchtowerDesktop/Tests/Core/WorkbenchBoardKanbanTests.swift::testSearchShowsArchivedLeaves`, `WatchtowerDesktop/Tests/WorkbenchBoardViewModelTests.swift::testArchivedTargetsShowOnlyWithTheToggleAndReopeningRestoresOne`
- supporting: `internal/db/proj15_board_archive_test.go` (`TestWithoutArchived_CountsArchivedChildren`, `TestWithoutArchived_EmptyAndAllArchived`, `TestGetTargets_WorkbenchLeavesArchivedOut`, `TestMigration00103_DefaultsToFourteen`), `internal/db/proj15_archive_now_test.go` (`TestMigration00105_ArchivedThroughStartsNull`, `TestArchiveNowWriters_UnknownWorkbench`), `internal/tools/workbench_board_archive_test.go` (`TestBuildBoardView_*`, `TestWorkbenchInfo_CountsTheWholeBoardAndTheArchived`, `TestWorkbenchBoard_LongMostlyClosedBoardStaysSmall`, `TestWorkbenchBoard_ArchiveNowLeavesTheBoardSmall`), `cmd/workbench_archive_test.go` (`TestRenderProjectBrief_ArchivedLeaveTheCountsAndAreCounted`, `TestWorkbenchBoardCmd_ArchivedOnlyWithTheFlag`, `TestWorkbenchBoardCmd_AllArchivedRootsAreCounted`, `TestWorkbenchShowCmd_PrintsTheArchiveSetting`, `TestWorkbenchShowCmd_PrintsArchivedThrough`), `internal/sessionreport/report_test.go::TestBuild_KeepsArchivedTargetsTheSessionClosed`, `WatchtowerDesktop/Tests/Core/WorkbenchBoardKanbanTests.swift` (`testArchivedCardCountIsTheArchivedLeavesUnderTheFilter`), `WatchtowerDesktop/Tests/WorkbenchBoardViewModelTests.swift` (`testTheArchiveCountFollowsTheMode`), Archive Now: `WatchtowerDesktop/Tests/Core/WorkbenchQueriesTests.swift` (`testArchiveClosedTargetsNowStampsTheWorkbenchAndUndoForgetsIt`, `testArchiveNowWritersThrowForAnUnknownWorkbench`), `WatchtowerDesktop/Tests/WorkbenchBoardViewModelTests.swift::testTheArchiveNowStampIsInTheFingerprint`, `WatchtowerDesktop/Tests/WorkbenchesViewModelTests.swift::testArchiveNowAndUndoWriteTheStampReloadAndReportAFailure`, `WatchtowerDesktop/Tests/WorkbenchHeaderControlsTests.swift::testArchiveNowAndUndoArchiveNow`

**Locked since:** 2026-10-04

## PROJ-16 — a line from the owner's phone reaches a Claude Code session only from a device the owner allowed on the Mac, only while the agent is idle, and only through PROJ-12's delivery; nothing from the phone ever answers a permission prompt

**Status:** Enforced (Desktop; owner approved 2026-10-07 as decision OD-1 — a new contract rather than an amendment of PROJ-12 — with OD-2, the one-time Allow on the Mac; spec `docs/superpowers/specs/2026-10-07-mobile-poc-design.md` §6.6, §10, §11, plan `docs/superpowers/plans/2026-10-08-mobile-poc-b-workbench-remote.md` Task 18)

**Observable:** A `session_input` or `session_finish_request` action from
the phone is typed into a workbench session only when (0) the device is
linked by a QR scan (spec §2.3: its `device_id` is in the hub's `devices`
table and, in `shared` scope, the record's creator is that phone's iCloud
user — anything else fails `device_not_linked` in the relay before any
handler runs; *2026-10-13 note (mobile E2E, owner approved, ask #96):* a
record that does not open under a linked phone's key — an unknown or a
removed key — is dropped with no answer, because the Mac cannot seal a
reply to a key it does not know (D9); a record that opens under a linked
phone's key but names another `device_id` still fails
`device_not_linked`; the guarantee is unchanged); (1) the device's `typing_allowed` is set in the hub's
`devices` table, which the owner granted with Allow in Settings → Mobile on
the Mac (the phone's own "Type into sessions" toggle only asks: the Mac
stores `typing_requested`, shows the request on the phone's row and posts
"Allow "<name>" to type into Claude Code sessions?" while the app is in the
background; the toggle turned off revokes the grant) — otherwise
`device_not_allowed`; (2) the session is a live board `claude` session and
its resolved state for the current run is Stopped, Finished, Waiting for
you, Ready to check (a resting form of Finished / Waiting for you since
#534, ask #195), Error, or a marked run with no turn yet — never Working (Agents
working included), Running or Needs approval, and never right after the
app submitted a line into it until a hook reported after that submit (at
most `submitSettle`, 30 s: the agent's Working lands asynchronously); (3) the prompt held no draft
before the paste (`TerminalCenter.promptHoldsText`: the owner's half-typed
text, a line left without its Return, or a line in its pause). Conditions
(1)–(3) are checked again right before every paste, after the delivery's
fresh state read (`SessionLineDelivery`'s per-line gate). It is then
delivered by the shared `SessionLineDelivery` under every PROJ-12 rule, as
one sanitised line (`SessionInputText`, the same rule on the phone: a CRLF
and every other line break or control character one space, format
characters such as an emoji's zero-width joiner kept, trimmed, 1–4000
characters, else `invalid_params`; the finish request is the
fixed line "Please wrap up: update the board, then call finish_session with
a short summary."). Otherwise it is held — echoed `held` with its reason
(`agent_busy`, `needs_approval`, `prompt_has_text`, `state_unknown`),
retried on each successful state read (never on a timer, and never by
the reads its own tries make), echoed again
when the reason changes — and expires 24 h after the phone created it
(`expired`, nothing typed). A held line is kept in the hub's sidecar
(`held_session_lines`): a hub start queues it again, one marked as being
typed when the hub stopped is echoed `outcome_unknown` and never typed
again, and one whose session stopped, started a new run or was deleted
fails `session_not_running`. A held line's retry types only after
claiming its sidecar row (a line cancelled or finished meanwhile is
dropped, never typed) and only while its hub runs (a stopped hub's lines
wait for the next start). Revoke (or Remove) on the Mac, or the phone's
toggle going from on to off, fails the device's held lines
`device_not_allowed` at once; `session_input_cancel` from the phone that
sent the line drops it and echoes it `cancelled` (another phone's cancel is
`device_not_allowed`), and is a no-op once the line went. Outcomes: `submitted` → `applied`; typed and not submitted (PROJ-12
withheld the Return) → `applied` with `delivery: typed`, and the phone says
"Typed into the session — press Return on the Mac"; copied → `failed` /
`cannot_type`. A `session_start` brief edited on the phone is used only from
a device with `typing_allowed`; otherwise the Mac's own work-on prompt goes.
No phone action writes to a session's terminal while its state is
`needsApproval`, and the phone shows "Needs approval on the Mac" with no
send.

**Why locked:** Any device signed into the owner's Apple ID can write relay
records. Without a Mac-side grant, that device could drive a Claude Code
session that holds workbench write tools. A line typed while the agent works
could be read as an answer to a dialog that appears meanwhile.

**Test guards:**
- `WatchtowerDesktop/Tests/MobileHub/SessionInputHandlersTests.swift` — `testProj16_AnUnallowedDeviceTypesNothing`, `testProj16_AWorkingSessionHoldsTheLineUntilItStops`, `testProj16_NeedsApprovalNeverGetsAPhoneLine`, `testProj16_ADraftHoldsTheLineAndNothingIsPasted`, `testProj16_AHeldLineExpiresAfter24h`, `testProj16_AnEditedBriefFromAnUnallowedDeviceIsIgnored`, `testProj16_RevokeFailsHeldLines`, `testProj16_AnUnlinkedDeviceTypesNothing` (condition 0, through the relay)
- The PROJ-12 guards run unchanged against `SessionLineDelivery` (see PROJ-12).
- supporting: `SessionInputHandlersTests` (`testEmptyOrWhitespaceTextIsInvalidParams`, `testLineBreaksAndControlCharactersBecomeOneLine`, `testTextOver4000CharactersIsInvalidParams`, `testTheFinishRequestTypesTheFixedLine`, `testAMarkedRunWithNoTurnYetIsIdle`, `testAFinishedStateFromAnEarlierRunIsNotIdle`, `testAFailedStateReadHoldsTheLineAsStateUnknown`, `testASessionNotRunningOrNotOnABoardFails`, `testCancelAfterDeliveryIsANoOpAndTheOriginalStaysApplied`, `testCancelWhileHeldCancelsTheOriginal`, `testAHeldLineSurvivesAHubRestartAndGoesOnIdle`, `testALineInterruptedMidPasteIsOutcomeUnknownAfterARestart`, `testASessionDeletedWhileALineIsHeldFailsSessionNotRunning`, `testLinesHeldByTheirGateAreNotRetriedInALoop` (wired through `SessionLineDelivery.follow` and a real `SessionAgentStateCenter`), `testOnlyThePhoneThatSentALineCanCancelIt`, `testACancelDuringAnInFlightRetryTypesNothing`, `testAStopDuringAnInFlightRetryTypesNothingAndTheNextStartTypesItOnce`, `testAQuickStopAndStartTypesTheLineOnce`, `testASecondLineWaitsForAHookAfterTheFirstWasSubmitted`, `testWithoutAHookTheSecondLineGoesAfterTheSettleCap`, `testTheRelayEchoesHeldThenTheLaterOutcomeAndKeepsIt`); `RelayProcessorTests::testASidecarWithoutTheTypingRequestColumnGainsIt`; Kit `SessionInputTextTests`; `MobileLinkCenterTests` (`testALinkedPhonesStartSessionsToggleIsMirroredAndATypingRequestIsStoredNotGranted`, `testATypingRequestAsksTheOwnerOnce`, `testAPhoneLinkingWithTypingOnAsks`, `testThePhonesToggleOffRevokesAndRevokeAndRemoveAreReported`, `testAnUnrelatedRewriteKeepsTheTypingGrant`); `SessionStartHandlerTests::testABriefFromADeviceThatMayNotTypeIsIgnoredForTheBasePrompt`; phone `WatchtowerMobile/Tests/SessionInputWiringTests.swift` (`testTheToggleOffHidesTheBarAndFinish`, `testAHeldEchoShowsItsReason`, `testNeedsApprovalShowsTheNoticeAndNoSendButton`)

**Locked since:** 2026-10-12

## PROJ-17 — a deleted session can be undone until it is gone, and then leaves nothing

**Status:** Enforced (Desktop; owner approved 2026-10-12, ask #195, board #480, spec `docs/superpowers/specs/2026-10-12-sessions-panel-design.md` §8.2 — written there as "PROJ-16", renumbered because PROJ-16 was claimed first; the session cleanup of board #535 is PROJ-18)

**Observable:** Deleting a session in the Desktop (✕, ⌘⌫ or Delete…, all
through `WorkbenchesViewModel.delete`) stops its process and hides its row
from the panel, the session switchers, Go to…, ⌘1…⌘9, the target lookup of
Work on It and the phone's start (`open_existing`), the sessions' statuses, and — not at once — the phone's session list
(`TerminalSessionSlice.hiddenIDs`: the row drops out on the hub's next 30 s
full tick, since main's #724 removed the fast nudge for this kind, and after
Undo it comes back on the next tick too); an ask's
"go to session" says "That session no longer exists." — and writes nothing.
Its row is deleted (`TerminalSessionQueries.delete`; its
`terminal_session_targets` by cascade, its asks' `session_id` set NULL) only
when the Undo window (`PendingSessionDeletes.window`, 5 s from the last
delete of the batch, re-armed before the row's process is closed) ends and
no row of the batch is still closing, or when the app quits
(`commitPendingDeletesForQuit`: the same write, waited for together with a
commit already in flight, bounded at 2 s in all); a workbench deleted
meanwhile cascades it and the batch forgets it. Until then **Undo** (`undoPendingDeletes`) brings back every
session of the batch with its row, links and asks byte-identical, not
running (a click or Restart resumes it). A failed delete brings the row back
with an error, never keeps it hidden. A live session that is working, at a
permission prompt, running without a reported state, with agents working,
waiting on an ask or ready to check is deleted only after a confirmation
(`SessionDeletePolicy.isQuick`); a standalone terminal always asks.

**Why locked:** Owner decision (#480, variants 5 + 1 + 2): one-gesture delete
is safe only because Undo is complete; an Undo that lost the report or the
asks would be worse than the dialog it replaces.

**Test guards:**
- `WatchtowerDesktop/Tests/WorkbenchesViewModelPendingDeleteTests.swift` — `testProj17_DeleteHidesAtOnceAndWritesNothingUntilTheWindowEnds`, `testProj17_UndoBringsBackTheRowWithItsLinksAndAsks`, `testProj17_CommitAfterTheWindowDeletesWithCascades`, `testProj17_QuitCommitsPendingDeletes`
- `WatchtowerDesktop/Tests/Core/SessionDeletePolicyTests.swift::testProj17_QuickDeleteTable`
- supporting: `WatchtowerDesktop/Tests/WorkbenchesViewModelPendingDeleteTests.swift` (`testBatchUndoRestoresEverySessionOfTheBatch`, `testFailedCommitBringsTheRowBackWithAnError`, `testPendingRowIsInNoListGoToOrTargetLookup`, `testUndoStateSurvivesLeavingTheWorkbench`, `testAWorkbenchGoneElsewhereDropsItsPendingSessions`, `testADeleteDuringAnotherClosesGraceWaitsForThatClose`, `testUndoWhileTheCloseIsPendingCommitsNothing`, `testAskOfAPendingSessionSaysTheSessionIsGone`, `testQuitWaitsForTheWindowsCommitInFlight`, `testQuitIsBoundedWhenTheWriteHangs`, `testQuitWriteFailureKeepsTheRow`, `testHiddenIDsChangesAreReportedOnDeleteAndUndo`), `WatchtowerDesktop/Tests/MobileHub/TerminalSessionSliceTests.swift::testASessionInTheUndoBatchIsNotPublished`, `WatchtowerDesktop/Tests/WorkbenchesViewModelDeleteTests.swift::testWorkbenchDeleteDropsItsPendingSessions`, `WatchtowerDesktop/Tests/MobileHub/SessionStartHandlerTests.swift::testOpenExistingNeverPicksAPendingDelete`, `WatchtowerDesktop/Tests/Core/PendingSessionDeletesTests.swift`

**Note (2026-10-14, board #535, PROJ-18 — for the owner's sight; the
contract above unchanged):** a row a session cleanup runs on is busy
(`WorkbenchesViewModel.cleaningUpSessions`: from **Delete and Clean Up**
until it ends, or while a **Clean Up…** sheet's apply runs).
`WorkbenchesViewModel.delete` — and so the ✕, ⌘⌫ and **Delete Only** — is a
silent no-op on a busy row (the panel's quick delete reads it as busy and
does nothing), and **Start fresh** is refused on it. While **Delete and
Clean Up** has closed the row's terminal (`closedForCleanup`) every resume
of that row is refused as well (`reopen`: a click, ⌘N, Work on It, the
phone's `open_existing` — dropped silently on the Mac, the phone told "This
session is being cleaned up on the Mac"), so
its worktree is not re-entered while it is removed; a **Clean Up…** apply
does not stop a resume (a live session's terminal stays reachable). Delete
and Clean Up deletes the row through this contract's deferred delete only
after the cleanup succeeded: Undo then brings the row back, never the
removed worktrees and branches (the dialog says so). A failed cleanup
deletes nothing (PROJ-18). Guards: `WatchtowerDesktop/Tests/WorkbenchSessionDeleteTests.swift`
(`testBusyRowRefusesDeleteAndResume`, `testWorkOnDuringTheCleanupDoesNotResume`,
`testSheetApplyMarksTheRowBusy`, `testQuickDeleteNeverCleansUp`); the
PROJ-17 guards above unchanged.

**Locked since:** 2026-10-12

## PROJ-18 — session cleanup never removes unsaved, unpushed, in-use or someone else's work

**Status:** Enforced (Go and Desktop; owner approved 2026-10-12, ask #193, board #535, spec `docs/superpowers/specs/2026-10-12-session-cleanup-design.md` §13; the spec's open questions were answered in ask #193: **Delete and Clean Up** is the default button, and the one-time sweep hint ships; amended 2026-10-14 (placed sessions, board #229, asks #122/#124))

**Observable:** `watchtower workbench cleanup` (`internal/sessioncleanup`) removes only linked worktrees of the workbench
repository and local branches, and only after every catch passes, checked again immediately before the removal:
a worktree with uncommitted or untracked changes, a HEAD not in the default branch nor on a remote, a locked
worktree, an operation in progress, a live process in it that is not an orphan of the session, a session working
in it, or another worktree or repository nested inside it is kept and reported with its reason; a branch whose tip is in neither the default branch nor a remote ref,
the default branch, or a branch checked out anywhere is kept. Outside the owner's sweep it removes only what the
session observed and what was created after the session started. It never removes the main worktree, a workbench
folder, anything under `~/.claude`, a path that is not a linked worktree, or a remote ref; never fetches; never
uses `--force` or an unconditional ref delete; signals only orphan processes (ppid 1, the current user, inside the
session's worktrees, not Watchtower's or Claude Code's) and only with SIGTERM. A plan writes nothing; an apply acts
only on items eligible at that moment and, when items are named, only on those.

*2026-10-14 amendment (board #229, owner approved in asks #122/#124, spec `docs/superpowers/specs/2026-10-14-session-worktrees-design.md` §9):* a session row Watchtower placed in a worktree it created (`terminal_sessions.worktree_branch` set) owns, by record, the linked worktree that is the longest listed root containing its `folder_path`, and its `worktree_branch`, when each was born no later than the row (placement creates them first; `created_at` + 1 s) — although both were born before the row. A later-born item of the same name (a reused `wt/<slug>` of a later session), one whose birth is unknown, or a row whose `folder_path` is not absolute owns nothing by record. Nothing else is owned by record, and every safety catch (W1, W3–W9, B1, B2, B4) still applies. Placement code (`workbench worktree create|ensure|forget`) never removes a worktree or deletes a branch and runs no `--force`, `reset`, `clean`, `checkout` or `stash`.

As shipped (each stricter than, never weaker than, the wording above):
- **Fail closed.** A catch git could not answer keeps the item `check_failed`
  with git's error in `detail`; an unknown default branch (no `origin/HEAD`,
  `main` or `master`, or a `symbolic-ref` failure other than "not a symbolic
  ref") keeps every branch (`default_branch_unknown`); a branch's birth comes
  only from its reflog's creation entry, so no reflog or an expired creation
  entry keeps it (`created_unknown`); an unreadable session start is an
  error (nothing is planned), never read as "no start"; a
  worktree whose directory is gone (`prunable`) still meets the folder,
  ownership and unpushed catches, and one with an unreadable admin `HEAD` is
  kept. A worktree that is, or holds, the user's `~/.claude` is kept
  (`claude_home`; an unknown home is `check_failed`). A process of the
  current user whose cwd the scan could not read keeps every worktree under
  consideration (`process_unknown`); a process with its cwd inside but its
  executable outside (a shell, tmux, `node`-run `claude`/`codex`) is a
  blocker and is never signalled.
- **The other sessions** a worktree is checked against are every terminal
  session of every workbench, standalone ones included (a second workbench
  over the same repository counts).
- **A caller inside a terminal session acts only on that session.** With
  `WATCHTOWER_TERMINAL_SESSION_ID` set (the agent's terminal, where the auto
  mode allow rule of PROJ-04 applies), `--session` must equal it,
  `--workbench` must be its workbench and `--sweep` is refused; an empty
  variable is refused too — each exit 2, nothing done. There is no flag that
  lifts this. The Desktop drops the variable from its own cleanup calls
  (`SessionCleanupCenter.cleanupEnvironment`).
- **Git runs nothing from the folder.** A planted `.git/config` (an
  fsmonitor command, a filter driver) never runs during a plan or an apply.
- **Order.** In an apply, `.app` bundles inside a worktree are unregistered
  (`lsregister -u`) before `git worktree remove` and registered again when
  the worktree stays; a git run that fails (not git's refusal) stops the
  apply and leaves the rest untouched and reported; a branch is deleted with
  `git update-ref -d refs/heads/<name> <checked sha>`, so one that moved is
  kept (`moved`).
- **Desktop.** **Delete and Clean Up** applies exactly the keys the Delete
  dialog showed that are still removable (after the terminal closed, a
  re-plan decides the ones kept only by it); a failed cleanup keeps the
  session row and shows the failure on the page. A **Clean Up…** sheet and
  the sweep sheet apply exactly the ticked keys of a known kind; the sweep
  ticks nothing by itself. An item of a kind this build does not know is
  listed but never offered, ticked or applied. The Desktop never runs git,
  `lsof` or `lsregister` and never writes the database.
- **Result.** An apply stores its JSON in `terminal_sessions.cleanup_result`
  with `cleanup_at` (Go only, best effort: `result_saved`/`result_error`);
  the session report only reads it (PROJ-14 unchanged).

**Why locked:** Owner decision (board #535): sessions left ~38 GB of
forgotten worktrees and 22 branches, and the agent could not remove them in
auto mode. Giving it a removal command is safe only if nothing it removes
could be the owner's or another session's work: one wrong `worktree remove`
loses uncommitted work for good, so every doubt keeps the item.

**Test guards:**
- `internal/sessioncleanup/plan_test.go` — `TestProj18_UncommittedWorktreeIsKept`, `TestProj18_UntrackedFileKeepsTheWorktree`, `TestProj18_UnpushedCommitKeepsWorktreeAndBranch`, `TestProj18_LockedWorktreeIsKept`, `TestProj18_WorktreeOlderThanTheSessionIsKept`, `TestProj18_BranchOlderThanTheSessionIsKept`, `TestProj18_BranchCheckedOutElsewhereIsKept`, `TestProj18_DefaultBranchIsNeverDeleted`, `TestProj18_MainFolderAndWorkbenchFoldersAreNeverCandidates`, `TestProj18_SessionInTheWorktreeKeepsIt`, `TestProj18_LiveProcessKeepsTheWorktree`, `TestProj18_PlanWritesNothing`, `TestProj18_ClaudeHomeIsNeverRemoved`
- `internal/sessioncleanup/apply_test.go` — `TestProj18_MergedAndPushedWorkIsRemoved` (the positive path: business done-criterion 1), `TestProj18_ClaudeHistoryAndMainBuildUntouched`, `TestProj18_ApplyRechecksAndActsOnlyOnNamedItems`, `TestProj18_BranchThatMovedAfterThePlanIsKept`, `TestProj18_NoForceNoFetchAnywhere`, `TestProj18_LsregisterRunsBeforeWorktreeRemove`, `TestProj18_FailureMidwayLeavesTheRestUntouched`
- `internal/sessioncleanup/failclosed_test.go` — `TestProj18_UnknownDefaultBranchKeepsEveryBranch`, `TestProj18_OriginHeadReadFailureKeepsEveryBranch`, `TestProj18_PrunableDetachedWorktreeWithUnpushedCommitIsKept`, `TestProj18_PrunableWorktreeWithUnreadableHeadIsKept`, `TestProj18_SessionOfAnotherWorkbenchInTheWorktreeKeepsIt`, `TestProj18_BranchWhoseCreationEntryExpiredIsKept`, `TestProj18_GitFailureInACatchKeepsTheItem`
- `internal/sessioncleanup/nested_test.go::TestProj18_WorktreeHoldingANestedWorktreeIsKept` (W9)
- `internal/sessioncleanup/placed_test.go` — `TestCleanupPlacedRowOwnsItsWorktreeAndBranch`, `TestCleanupPlacedSubfolderRowOwnsItsWorktree`, `TestCleanupPlacedRowStillKeepsUncommittedWork`, `TestCleanupUnplacedOldWorktreeStillKept`, `TestCleanupPlacedNameBornAfterTheRowIsNotOwned`, `TestCleanupPlacedUnknownBirthIsNotOwned`, `TestCleanupPlacedRelativeCwdIsIgnored`
- `internal/workbenchgit/worktree_ensure_test.go` — `TestProj18_PlacementNeverForcesOrDiscards`
- `internal/sessioncleanup/procs_test.go::TestProj18_OnlyOrphansAreSignalled`
- `internal/sessioncleanup/untrusted_test.go::TestProj18_PlantedGitConfigRunsNoCommand`
- `cmd/workbench_cleanup_test.go` — `TestProj18_CallerSessionCannotCleanAnotherSession`, `TestProj18_CallerSessionCannotSweep`, `TestProj18_CallerSessionCannotNameAnotherWorkbench`, `TestProj18_CallerSessionEmptyVariableIsRefused`
- `WatchtowerDesktop/Tests/WorkbenchSessionDeleteTests.swift` — `testProj18_DeleteAppliesOnlyThePlannedItems`, `testProj18_FailedCleanupKeepsTheSessionRow`
- supporting: the rest of `internal/sessioncleanup/*_test.go` and `cmd/workbench_cleanup_test.go`; `internal/db/terminal_session_worktrees_test.go` (`TestSaveCleanupResult_WritesOnlyItsRow`, `TestTerminalSessionStart_UnreadableIsAnError`, `TestGetTerminalSessionNeedsNoCleanupColumns`); `cmd/workbench_brief_cleanup_test.go` (the brief's `Cleanup:` line); Desktop `WatchtowerDesktop/Tests/WorkbenchSessionDeleteTests.swift` (the other tests: Delete Only, unknown kinds, the closing terminal's re-plan, the sheet, the report line), `WatchtowerDesktop/Tests/SessionCleanupCenterTests.swift`, `WatchtowerDesktop/Tests/Core/{SessionCleanupPlanDecodingTests,SessionCleanupPresentationTests,SessionDeleteCleanupChoiceTests}.swift`; the sweep sheet and its one-time hint in `WatchtowerDesktop/Tests/SessionCleanupSweepTests.swift` (`testSweepPlanPassesAllLiveSessions`, `testSweepTicksNothingByDefault`, `testSweepAppliesOnlyTickedKeys`, `testSweepNeverAppliesUnknownKinds`, `testSweepSurvivesLeavingThePage`, `testSweepFailureAfterTheSheetClosedShowsOnThePage`, `testSweepHintShownOnceAboveOneGigabyte`, `testSweepHintStaysAwayAtOrBelowOneGigabyte`, `testBelowTheLineRechecksAfterSevenDays`, `testUnmeasuredWorktreeIsNotSnoozed`, `testFutureCheckStampIsDue`, `testPageLeftAfterThePlanLandedLetsTheNextVisitHint`, `testHintPlanStopsAtItsTimeLimit`, `testHintWaitsForThePageToStayOnScreen`, `testLeavingThePageStopsARunningHintPlan`, `testOneHintPlanAtATime`, `testSheetOpenedMidHintKeepsTheSheetsPlan`, `testOpeningTheSweepAnswersTheHint`, `testNoHintSweepOnceTheSheetWasOpened`)

**Locked since:** 2026-10-14

## PROJ-19 — board columns never contradict the status

**Status:** Enforced (Go and Desktop — one implementation, in SQLite; owner approved: spec review ask #209, plan ask #211, decisions ask #202; spec `docs/superpowers/specs/2026-10-16-workbench-board-columns-design.md` §8)

**Observable:** A workbench may define board columns (migration `00126`: `workbench_board_columns`, `targets.board_column_id`, `projects.board_hidden_statuses`). A target's column is always one of its own workbench and of its current status: SQLite triggers refuse a column of another workbench or another status (`board column does not match the target`) for every writer, and a status or workbench change clears a column that no longer fits (the target then sits in the first column of its status). A move between two columns of one status writes only the column: progress is kept and no status-history row is written (PROJ-06 is not touched); a move that changes the status writes status and column in one statement. A status cannot be hidden and have columns at once. The agent may move a card with `update_target column` (and, as before, `status`), but a hidden `in_review` or `blocked` is refused on the workbench MCP surface with a text that says what to do instead; the owner's writers (CLI, Desktop) and the system writers are not refused. With no columns defined and nothing hidden, every agent-facing text (the brief, `workbench_board`, `get_target`, `workbench_info`, the skill's behaviour) and the Desktop board are as before: `column`, `columns` and `hidden_statuses` appear only when defined.

**Why locked:** Owner decision (board #267): the owner lays out the board with their own column names, and the agent and the owner both move cards. If a column could disagree with the status, the board would show a card as "Review" while PROJ-05's parent rollup, PROJ-06's history and the drift check (PROJ-07) read it as `todo`. The categories stay the contract; the column is only a name and a place inside one.

**Test guards:**
- `internal/db/proj19_board_columns_test.go` — `TestProj19_ColumnMustMatchStatusAndWorkbench`, `TestProj19_StatusChangeClearsForeignColumn`, `TestProj19_StatusAndColumnInOneStatement`, `TestProj19_ColumnMoveWritesNoHistory`, `TestProj19_SameStatusColumnMoveKeepsProgress`, `TestProj19_DeletedColumnFallsBack`, `TestProj19_SnoozeClearsColumn`
- `internal/tools/workbench_columns_test.go::TestProj19_NoDefinitionAgentOutputsUnchanged` (outputs byte-identical without a definition); the hidden-status refusal texts in the same file
- `cmd/workbench_brief_columns_test.go` — `TestBriefColumns_NoneLeavesBriefUnchanged`, `TestBriefColumns_MaximalRulesStayWithinTheBrief` (the section stays within its 1000-character budget)
- `WatchtowerDesktop/Tests/Core/BoardColumnLayoutTests.swift::testEmptyDefinitionIsTodaysColumns` (an empty definition lays the board out as before), with `testHiddenEmptyStatusIsSkipped`, `testHiddenStatusWithCardsStillShows`
- `WatchtowerDesktop/Tests/Core/WorkbenchBoardColumnWritesTests.swift` — `testMoveToColumnWritesStatusAndColumnOnce`, `testMoveBetweenColumnsOfOneStatusWritesNoHistory`, `testMoveWithinOneStatusKeepsProgress`, `testMismatchedColumnIsRefusedByTheTrigger`
- `WatchtowerDesktop/Tests/Core/BoardColumnsDraftTests.swift::testDraftRejectsHideWithColumns`
- `WatchtowerDesktop/Tests/MobileHub/WorkbenchTargetSliceTests.swift::testColumnOnlyWithDefinition` (the slice carries `column` only with a definition)
- `WatchtowerKit/Tests/WatchtowerKitTests/WorkbenchTargetTests.swift::testDecodesWithAndWithoutColumn`
- `WatchtowerMobile/Tests/BoardModelTests.swift::testRowShowsColumnTitle`

**P5 note (Automations):** any future agent-facing writer of a workbench target's status (an automation tool, a new MCP tool) must call `hiddenStatusRefusal` (`internal/tools/workbench_columns.go`) for a hidden status, exactly as `update_target` does.

**Locked since:** 2026-10-16

## PROJ-20 — a hosted session survives an update and is adopted without a relaunch

**Status:** Enforced (Go and Desktop; board #496, spec `docs/superpowers/specs/2026-10-17-workbench-sessions-survive-restart-design.md`; owner decisions in asks #246 (an update must keep the agent's turn, its subagents and its background processes) and #247 (an update keeps without asking; a plain quit with live sessions asks Keep or Stop))

**Observable:** A workbench terminal session runs in a detached `watchtower session-host` process that owns its PTY (`internal/sessionhost`); the app is a client. Closing the app's connection, an update's quit, **Keep Sessions and Quit** and an app crash signal nothing: the agent, its subagents and its background processes keep running. At the next launch the app lists the host's sessions and, for each running run of this workspace whose row still exists, shows the live terminal in `.running` state with the current screen replayed — without `--resume`, without a new process and without a second run for the row. An update (`UpdateService.relaunch`) and a macOS log-out, restart or shutdown never ask about sessions and detach (a running recording or unsent ask answers still prompt); a plain quit with at least one live hosted session asks **Keep Sessions and Quit** / **Stop Sessions and Quit** / **Cancel**, and Stop (and **Reset All Data**) signals every session's process group SIGHUP, then SIGKILL after 3 s. A run belongs to the workspace whose `scope` (SHA-256 of its database path) it carries: another workspace's runs are never adopted, stopped, forgotten or reported. A run whose row was deleted while the app was away is stopped, never left running; a run that exited while the app was away is attached so its last output shows, then reported once as a natural exit (PROJ-18 cleanup applies). When the host cannot be reached at app launch the session runs in the app as before and says "This session stops when Watchtower quits."; it is never killed silently. A host lost while the app runs is started again by the next launch; if that fails the launch ends with "[Watchtower] the session host is not running" (or "[Watchtower] could not reach the session host: …") in the pane. Every build shares one host (the socket is derived from the literal bundle id `com.watchtower.desktop`): a second app instance (a dev build) on the same workspace contends for the same runs, and the pane that loses one says "Another Watchtower window took this session over." without reattaching or reporting an exit. The host exits 60 s after its last session is forgotten and no connection is attached to one (the app's control connection does not keep it alive), so an update's new host binary takes over then.

**Why locked:** Owner decision (#246/#247): losing a running agent turn, its subagents and its dev servers or builds on every update is the pain this removes. The contract fails in two directions: a detach that signals kills the work; an adoption that relaunches (`--resume`) or stops the wrong run (another workspace's, since row ids are per database) starts a second agent on one transcript or kills someone's work.

**Test guards:**
- `internal/sessionhost/server_test.go::TestSessionHost20_SessionSurvivesClientDisconnect`
- `WatchtowerDesktop/Tests/TerminalCenterReattachTests.swift::testProj20_ReattachAdoptsRunningSessionWithoutRelaunch`
- `WatchtowerDesktop/Tests/TrayAppDelegateTests.swift::testProj20_UpdateQuitDetachesHostedSessions`
- supporting: `internal/sessionhost/server_test.go` (`TestServer_HostedChildKeepsDefaultSighup`, `TestServer_ScopeRoundTrips`, `TestServer_AttachExitedSession`, `TestServer_AttachTakesOver`, `TestServer_IdleExitIgnoresUnboundConnection`, `TestServer_ExitWhileAttachedIsKeptUntilForget`); `WatchtowerDesktop/Tests/TerminalCenterReattachTests.swift` (`testReattachIgnoresAnotherWorkspacesRuns`, `testReattachStopsSessionWhoseRowIsGone`, `testReattachReportsExitOnceAndForgets`, `testReattachIgnoresListFailure`, `testStartHostReattachWaitsForTheConnection`); `WatchtowerDesktop/Tests/TrayAppDelegateTests.swift` (`testSystemLogoutNeverPrompts`, `testStoppingSessionsQuitNeverOffersKeep`, `testQuitPromptNamesUnprotectedSessionsThatStop`); `WatchtowerDesktop/Tests/TerminalCenterTests.swift::testDetachAllNeverSignals`; `WatchtowerDesktop/Tests/HostedTerminalSessionTests.swift` (incl. `testATakenOverRunIsNeitherReattachedNorReported`)

**Limits (accepted):** no survival across a Mac restart or log-out (the existing `--resume` is the path there); while the app is closed there are no state notices and the phone sees no updates (hooks still write to the database); the screen replay is approximate until the agent redraws; a dev build on the same workspace takes runs from the installed app's windows (last attach wins), the losing window's row keeps reading running, and Restart there starts a second run beside the winner's; sessions launched by an older host carry an empty scope and every workspace treats them as its own.

**Locked since:** 2026-10-17

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
  as its session. (d) Codex-run sessions get the ask tools but no hooks (until
  2026-10-12; since board #399 a codex session in a workbench terminal runs the
  same hooks, PROJ-11/13, and only a codex outside one gets none).
  (e) Margin comments anchor on the ask's snapshot, never on the live file; a
  later round is a new ask. (f) The delivery line always names the
  `watchtower-workbench` skill, so a pre-rename folder reads a skill name it
  lacks until Re-run Setup. (g) Without git installed, a folder inside a
  repository is listed by the walk, which knows no ignore rules; the daemon's
  mtime gate is whole seconds, so an edit in the same second as its last
  render waits for the next change or an explicit trigger. (h) Since
  2026-10-04 (board #379) the answer's Return trusts the hook state of the
  current run: a session whose hooks wrote nothing this run (a folder
  without the session state hooks) only gets the paste. Since 2026-10-07
  (board #396) the SessionStart hook marks a launch or a resume with them,
  so a fresh run counts as reported — the mark is written by the CLI
  binary, no Re-run Setup needed, but a session started before the update
  has no mark until its first hook state, and an answer in the second
  between the launch and the app's first read after the mark only gets
  the paste. A turn the agent starts by itself (no `UserPromptSubmit`: a
  teammate message, a wakeup) leaves the mark until its first tool result;
  an answer meanwhile is queued by Claude Code as with `working`, and a
  permission prompt in that turn is reported by its `Notification` hook as
  in any other. The residual risk of the 2026-10-07 extension: a hook
  write that is lost, not only late (an `approval` write failing on
  `SQLITE_BUSY` past its 1 s busy timeout, a hook process killed), leaves
  the mark — like any earlier state — vouching for a prompt with no
  dialog, so the Return may confirm that dialog's default. When the
  owner's own Return during the pause really sent the line and the read
  after the pause failed or a dialog is still shown at that read, the line
  counts as still typed and a (safe)
  false "press Return" bar shows — the same as before the extension. The
  reverse is not caught: a permission prompt that opened during the pause
  and was answered by that same owner Return (the app's state still stale)
  is gone by the read, so the line counts as sent — no bar, no tracked
  draft — though its text may still sit in the input box, and the next
  delivery's Return could send both as one message. It needs a prompt to
  open and be answered within the 500 ms pause; for answers so since the
  #388 fix, for hand-offs since its review round (accepted over the false
  bar). Not seen, so
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

- **Owner asks v2 (2026-10-11, PROJ-13 rewritten, board #395/#501/#503).**
  (a) of the owner-asks note above now reads: one light-tier call per Stop
  through Watchtower's provider registry (also on `stop_hook_active`, none
  on an empty message or a continued turn outside a Desktop terminal row),
  up to the 20 s budget inside the 30 s hook timeout; on codex the final
  message goes to OpenAI (business D1). Until Repair a folder keeps the old
  prompt hook, which bounces every Chat question as before; `integrate
  status` reports `ask_guard: false` for it. (b) Presence knows no idle
  keyboard: an owner idle in front of the session is caught only by the
  10-minute rule. (c) A chat question pending when its session's process
  ends is never raised; the next run's mark clears it. (d) Watchtower never
  withdraws a raised ask by itself; the skill tells the agent to withdraw it
  when the owner answered in the terminal (no mechanical check). (e) A
  Desktop that hangs or crashes leaves the presence row stale; Go trusts it
  for 90 s, so for up to 90 s a question may pass to an owner who is gone —
  the escalation runs on the Desktop and does not run while it is down. (f)
  The level is stored once, when the ask is filed; asks filed before
  migration `00107` stay Full. (g) `workbench asks --json` is read-only: an
  answer from another client is the planned next step (spec Part 10.3) and
  will need a PROJ-12 amendment.

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
  The background count (board #411, 2026-10-10): whether `SubagentStop`
  fires for a killed or crashed subagent is unverified (the count then waits
  for the next main turn, Stop or run, or the staleness probe); once two
  failed probes showed a count as over (display only, nothing written), a
  subagent that reports again revives Agents working, so a later Stop
  announces "stopped" a second time (the known double notice); idle
  teammates and background shells are not counted, so a session running only
  those reads Stopped; a Claude Code without `background_tasks` in its Stop input stores no count and
  shows Stopped as before; and a folder needs Re-run Setup (or Repair) once
  for the `SubagentStop` entry — until then nothing lowers the count before
  the main agent's next turn. Teammates (board #543, 2026-10-11): a
  teammate counts only from a Stop that sees its turn open, so one that
  starts working while the row reads Stopped (a message from another idle
  teammate, its own background shell finishing) shows from the main agent's
  next Stop; a teammate or subagent waiting on its own background shell is
  idle to the hooks and not counted; only in-process teammates fire hooks in
  the lead's session (one in its own terminal pane is another session); a
  teammate killed mid-turn keeps its open turn until no teammate is listed
  or the run ends, and meanwhile can stand in for another listed teammate;
  the async `SubagentStart` must land before the lead's Stop reads the turns
  (never close in the captures, not guaranteed); the async hooks also commit
  in any order, so when one teammate hands work to another the first one's
  `SubagentStop` can land before the second one's `SubagentStart` and lower
  the count to 0 (Stopped until the lead's next Stop), and two
  `SubagentStop`s landing out of their stamp order leave the count at 1
  until the lead wakes (a later report never lowers below an older one's
  view: the older one is refused by the time guard pinned in
  `TestProj11_SubagentStopOnlyLowersTheCount`); a lost `SubagentStop` (a
  failed async hook) keeps that teammate's turn open while any teammate is
  listed; and a folder needs Re-run
  Setup (or Repair) once more for the `SubagentStart` entry — until then no
  teammate counts, as before. The probe reads Claude Code's session registry, an
  undocumented Claude Code internal: a change in it loses the probe and the
  count ends at the first stale probe, as Stopped, never stuck (when no
  entry file decodes at all, or `ps` cannot answer for a live pid, the probe
  fails instead and only the display ends, after two failed probes). The probe
  reads `~/.claude` only, never `CLAUDE_CONFIG_DIR` (the transcript readers'
  rule): a `claude` started with a custom `CLAUDE_CONFIG_DIR` is not found,
  so its count ends at the first stale probe. The row
  follows the registry, so a hung subagent keeps it Agents working for as
  long as Claude Code reports work in flight. Not measured on Claude Code
  2.1.295: a never-ending background shell, workflows, a hung or killed
  subagent. A probe that keeps failing ends only the display (two failed
  probes); the stored count stays until the next main turn, Stop or run.
  The peer-messaging ping is recorded (spec
  `docs/superpowers/specs/2026-10-10-session-background-agents-design.md`,
  Appendix B; board #481) but not built.

- **Board archive (PROJ-15).** SQLite cannot push a `project_id` filter
  into the recursive, grouped view, so every board read, `get_target` and
  session `list_targets` computes the archive over all workbench targets in
  the database, every workbench's (about 3 µs per target — fine at today's
  sizes; a 2000-target board is pinned by `TestProj15_LargeBoardReadIsFast`). Nothing is stored, so the Desktop
  board notices a target ageing into the archive only at its next reload
  (any board change, Refresh, reopening the pane), not at the exact minute.
  Restore is reopening: there is no per-target Unarchive action (owner
  decision D), since a target taken out of the archive but still closed for
  longer than the setting would be archived again on the next read. "Undo
  Archive Now" (board #415) forgets the workbench's `archived_through`
  moment as a whole — one moment per workbench, so it undoes every earlier
  click, and what the age rule archives stays archived; a close in the
  click's own second is archived with the rest (second precision, `<=`). The setting is the
  owner's (Desktop menu); the agent cannot change it. A close time that does
  not parse as a date (every writer stores ISO-8601 UTC, so none is known)
  keeps its target and every ancestor out of the archive, so an archived
  target's whole subtree stays archived (guard
  `TestProj15_UnparseableCloseTimeKeepsTheChain`).

- **Sessions panel (board #480/#534, PROJ-11/17; owner decisions in asks
  #194/#195).** Not contracts — the panel's layout and keys, written down so
  a change is a decision, not a drift. (a) *Finished group:* a session that
  is finished with no open ask (live or not) folds into "▸ N finished" at the
  bottom of SESSIONS, most recently finished first; Ready to check, a
  finished session with an open question and every other state stay in the
  main list in the saved drag order (`SessionPanelSections`). The fold is
  remembered per workbench. The session on screen never jumps: one that
  finishes in front of the owner keeps its main-list slot until another
  session is shown, and one shown from a folded group appears as a pinned
  row under the header without opening the fold; a session resumed from the
  group returns to the main list. (b) *Numbers:* ⌘1…⌘9 follow the main list,
  then the group's rows only while it is open (a pinned row gets no
  number); the session switcher and Go to… list every group row after the
  main rows. (c) *Quick delete:* the ✕ and ⌘⌫ without a dialog only for a
  session whose agent is not working (PROJ-17's list); standalone terminals
  get no ✕ and always confirm, then get the same Undo. (d) *Keyboard (ask
  #195):* a row click keeps sending the keyboard into the session's
  terminal; the panel takes it on a click on its empty space, the SESSIONS
  label, the group header, a ✕ or the Undo button, and then owns ⌘⌫, ↑ ↓,
  Return, Esc (back to the terminal), ⌘Z and Tab — only in the key window
  with no sheet up; elsewhere those keys belong to the terminal or the
  editor. (e) *Undo bar:* "Session deleted — Undo" / "N sessions deleted —
  Undo" in its own bar under the session list (over the page while the
  panel is hidden). (f) *Limits:* a crash or `kill -9` inside the 5 s window
  keeps the row (listed again on the next launch); the phone's session list
  follows the hub's 30 s full tick, so it may still list a hidden row and
  shows an undone one again only on the next tick; a late async hook of the
  killed process may still write the row's state, which Undo then shows.

- **Session cleanup (board #535, PROJ-18; spec
  `docs/superpowers/specs/2026-10-12-session-cleanup-design.md` §1).**
  Deferred, recorded and not built: Xcode DerivedData of `WatchtowerMobile`
  builds made from a worktree; scratch files and binaries in `/tmp` and the
  Claude scratchpad; squash-merged branches whose remote branch is already
  deleted (kept, reported as not on the remote and not in the default
  branch — delete by hand; a later version can match the PR cache once it
  stores the head sha); LaunchServices entries of builds outside the
  workbench folder (sibling `../<repo>-<name>` worktrees removed by hand
  earlier); an automatic prompt when a session turns Finished; a fetch
  inside the command (the skill tells the agent to `git fetch` first, so a
  branch merged on the remote but not fetched is kept as unpushed); cleanup
  of a `kind = 'shell'` session (no hooks, so no ledger — the sweep covers
  it). Also: the ledger keeps at most 64 worktree/branch pairs per session
  (later ones are dropped with one stderr line; declared `--worktree`/
  `--branch` candidates and the sweep still reach them); a worktree made and
  entered by a tool that sent no hook from inside it is found only through a
  target's branch, a declared candidate or the sweep; sizes are allocated
  blocks with a 20 s walk budget per worktree ("size unknown" past it) and
  APFS clones share blocks, so the space actually freed can be less than the
  "~" figure; the sweep never signals processes; the one-time sweep hint plans in the background only after the Workbench page stayed on screen 30 s, one hint plan app-wide at a time, stopped after 5 minutes or when the page is left; when the worktrees take 1 GB or less it is snoozed for 7 days (`projects.cleanupHintCheckedAt.<id>`), and only when every worktree was measured — otherwise it checks again at the next launch; a future stamp counts as due, a failed or timed-out plan waits for the next launch, and once the banner went up or the sweep sheet was opened (`projects.cleanupHintShown.<id>`) it never runs for that workbench again.

## Changelog

- 2026-10-17 (board #496, final review): **PROJ-20 text corrected — no guard changed or relaxed.** Every build shares one host (the "another bundle id lives in its own host" limit was false); a takeover tells the losing pane, which neither reattaches nor reports an exit; an exited-while-away run is attached for its last output before its one exit report; the local fallback applies only when the host is unreachable at app launch; an update and a log-out never ask about sessions (a recording or unsent ask answers still prompt); the idle exit ignores the app's control connection.

- 2026-10-17 (board #496, workbench sessions survive an app restart; spec `docs/superpowers/specs/2026-10-17-workbench-sessions-survive-restart-design.md`; owner asks #246/#247): **PROJ-20 added** — a hosted session survives an update and a Keep Sessions quit and is adopted without a relaunch. Quit path changed: an update and a system log-out/restart/shutdown detach without asking, a plain quit with live hosted sessions offers Keep Sessions and Quit / Stop Sessions and Quit / Cancel, **Reset All Data** always stops sessions. No other contract text or guard changed; the CHAT-03 quit order is unchanged. Guards: `TestSessionHost20_SessionSurvivesClientDisconnect`, `testProj20_ReattachAdoptsRunningSessionWithoutRelaunch`, `testProj20_UpdateQuitDetachesHostedSessions`.
- 2026-10-16 (diff reviewer Plan 3, board #328, **owner approved in ask #214** as a marker bump only; renumbered v11 → v12 because board #267 took v11 on main first): **PROJ-04** — the core workbench skill's pack marker moves `v11 → v12` only; the install rules are unchanged (the shipped v10 and v11 texts join the DEV-04 re-install fixtures as `watchtower-workbench-v10.md` and `watchtower-workbench-v11.md`, so an un-edited v1–v11 copy is updated by resync/Repair and an edited one is kept, with board #267's preset rule for an edited v10 unchanged). v12's "Review rounds" teaches reading `.watchtower/review.md` and calling `annotate_changes` before handing work back, answering every comment with `reply_review_comment` (`resolved: true` once fixed; the owner can reopen), and not redoing hunks `get_review` lists as undone by the owner. **PROJ-12 unchanged**: the round's delivery line is the same; reverts reach the agent through `get_review`. No guard relaxed (`TestWorkbenchSkill_TeachesFinishingASession` asserts v12; `TestWorkbenchSkill_UpgradesAnUneditedPreviousVersionAndKeepsAnEditedOne` gains the v10 and v11 fixtures).
- 2026-10-16 (board #267, workbench board columns; spec `docs/superpowers/specs/2026-10-16-workbench-board-columns-design.md` §8, plan `docs/superpowers/plans/2026-10-16-workbench-board-columns.md`; **PROJ-19 added, owner approved: spec ask #209, plan ask #211, decisions ask #202**): migration `00126` (renumbered from a duplicate 00125 on 2026-10-17) (`workbench_board_columns`, `targets.board_column_id`, `projects.board_hidden_statuses`, the match triggers); `watchtower workbench columns <id> [--json] [--set -]`; `update_target` takes `column`; a hidden `in_review`/`blocked` is refused on the workbench MCP surface; `column` appears in `workbench_board`/`get_target` and `columns`/`hidden_statuses` in `workbench_info` only when defined; the brief gets a Board columns section (at most 1000 characters, else one fallback line) and a Turned off line. **PROJ-04:** the workbench skill is pack **v11** (the column and turned-off rules; an unedited earlier copy upgrades, an edited one is kept, as for every bump). **PROJ-05, PROJ-06, PROJ-07:** note only, columns do not touch them. The Desktop gets the **Board Columns…** sheet, drag between columns and a column picker in the target panel; the phone shows the column title in place of the status label. A column title made only of digits is refused (`validateBoardColumns`, mirrored in the Desktop draft), so a column can be named by id or by title without ambiguity. Guard note: the PROJ-15 supporting test `TestMigration00105_ArchivedThroughStartsNull` now checks only the archive view at its `DownTo(104)` step (the board reader needs 00126's table, a schema state `db.Open` never produces); the full `requireArchived` check after Up is unchanged; acknowledged by the owner in ask #229 (2026-10-16).
- 2026-10-16 (session chat feed, board #477): note only — **no contract, guard test or status changed**. Migration `00127` adds the `terminal_session_agent_sessions` ledger (agent session ids and times, cascade on the tab's delete, written by triggers on `terminal_sessions`); **PROJ-02** still holds (deleting a tab removes its ledger rows through the FK cascade, guard `TestTerminalAgentSessions_CascadeOnDelete`). The chat pane's contracts are FEED-01..04 in `session-feed.md`.
- 2026-10-16 (Automations P5 part 2, board #753; spec `docs/superpowers/specs/2026-10-14-automations-design.md` §13.1, §13.3): **PROJ-12/PROJ-13 strengthened — the Desktop half.** An automation's ask is never typed, held or queued into a terminal, whatever session it names: `OwnerAsksViewModel.answer` skips `SessionLineDelivery` when `automation_run_id` is set and wakes the automations loop instead (`automations wake`, best effort); `deliverHeldAnswers` has no entry for it. Guard `WatchtowerDesktop/Tests/OwnerAsksAutomationTests.swift::testAutomationAskIsNeverDeliveredToATerminal`; every existing PROJ-12/PROJ-13 guard green unmodified. The stack names such an ask "⚙ <automation> · run #N" and its closed ones leave "Outside the app" for a "⚙ Automations" line (`OwnerAskQueries.closedCounts` counts no session-less automation ask; `closedAutomationCount`; `testClosedAutomationAskNamesItsRun`, `testClosedAutomationAsksAreNotOutsideTheApp`). **PROJ-03:** the ask #272 amendment written in Task 8 is present with its guards (entry below); the Desktop's edit form and Change in words reach it only through `automations save` and `save_automation` — no new Desktop write path. **PROJ-11 note, no text changed:** a session `AutomationSessionCenter` launches is an ordinary session started in the background (R-P5-7); its agent launches, Resume included, carry `WATCHTOWER_AUTOMATION_RUN_ID`. No guard relaxed.
- 2026-10-16 (Automations P6 templates, board #753; **PROJ-03 amended, owner approved in ask #188 (2026-10-16, install-template)** — a different ask from the 2026-10-12 ask #188 of board #565/#568): `automations install-template <name> --workbench N`, and the Desktop gallery install that calls it, count as an explicit owner write of automation recipes: only under `<folder>/.watchtower/automations/`, a taken slug refused, never an overwrite, atomic writes, a symlinked path component refused, every recipe installed unconfirmed and disabled. Amendment text in PROJ-03 next to the ask #272 one (kept as it was); the existing `TestInstallTemplate_*` guards are listed under PROJ-03; no code or guard changed.
- 2026-10-16 (Automations P5 Task 8, board #753; spec `docs/superpowers/specs/2026-10-14-automations-design.md` §14.6, D17; **PROJ-03 amended, owner approved in ask #272**): P3's ruling R-P3-5 is lifted — `save_automation` takes `workbench_id`: Normalize resolves the workbench through `Deps.Workbench` (an unknown one, or a recipe folder with a symlink in its existing path, is refused with no row) and pins `path = <folder>/.watchtower/automations/<slug>.md` (canonical) and scope `workbench:<id>`; Execute, in the owner's `actions apply` process after Approve, re-checks the path, the symlink rule and the pinned content hash, writes atomically (creating `.watchtower/automations/` 0755), rescans that folder and confirms. `automations save --path` already wrote only that folder's `<slug>.md` of a known workbench (P1); the shared symlink check moved to `automations.RefuseLinkedRecipeDir`. The amendment text is in PROJ-03; new guards `TestSaveAutomation_WorkbenchWritesIntoItsFolder`, `TestAutomationsCLI_SavePathOutsideWorkbenchAutomationsRefused`; every existing PROJ-03 guard (`TestProj03_AskOwnerNeverWritesTheFolder`, the code viewer's `testProj03*`) unchanged. The Desktop form's workbench rows become editable in Task 12.
- 2026-10-16 (board #411, Desktop New Task): note only — **no contract, guard test or status changed**. The Desktop board creates targets too (header **New Task**, under the current scope; card menu **New Sub-task…**): `WorkbenchBoardViewModel.createTarget` runs `watchtower workbench target add`, the phone's owner writer, so the creation is recorded as `owner` (PROJ-06), Go does the PROJ-09 parent check and the PROJ-05 rollup, and the new target plus every parent whose status moved are reported through `onOwnerWrite` so the owner is never notified about their own change.
- 2026-10-16 (Automations P5 part 1, board #753; spec `docs/superpowers/specs/2026-10-14-automations-design.md` §13): **PROJ-02 strengthened** — deleting a workbench also removes its automation rows (`automations`, `automation_runs`, `automation_run_steps`, `automation_state`, `automation_outputs`) and the owner asks its automations filed; guard `TestProj02_DeleteRemovesAutomationRows`; the recipe files under `.watchtower/automations/` stay (owner's repo files). **PROJ-12/PROJ-13:** an automation's ask never reaches a session (see the entry above; guard `TestAutomationAsks_InvisibleToSessionReaders`); the Desktop-side guard that the terminal delivery excludes it follows in part 2. **PROJ-11 note, no text changed:** a session an automation's `session()` starts is an ordinary workbench session (same hooks, states, report and cleanup); for the run, "stopped" means the process ending, reported by the Desktop through `automations session-ended` (R-P5-3). No guard relaxed.
- 2026-10-16 (Automations P5 Task 6, board #753; spec `docs/superpowers/specs/2026-10-14-automations-design.md` §5, D6/D7): **PROJ-12 and PROJ-13 strengthened — no contract text weakened, no guard changed.** A workbench automation's `ask()` files an `owner_asks` row with `session_id` NULL and `automation_run_id` set (migration `00122`); its run waits for the answer itself and marks it `delivered`. Every session-side reader leaves such a row out (`a.automation_run_id IS NULL`): the brief's "Answered asks for you" and its other-sessions count (`AnsweredAsksForBrief`), `list_asks` (`OwnerAskFilter.ExcludeAutomation`), `get_ask`, `withdraw_ask` and ask_owner's `previous_ask_id` (all through `askInWorkbench`: "no ask with id N"), the series hint (`RecentOpenQuestionAsk`) and the withdrawn-title check (`LastWithdrawnByTitle`) — so PROJ-12's "an ask with no session … the session's next `workbench brief` lists it" never applies to an automation's ask, and no session's `get_ask` can deliver it. The owner-facing readers keep it (the Waiting-for-you stack, `CountOpenOwnerAsks` — the 30-ask cap stays per workbench —, badges, `workbench asks --json`, the daily briefing). **PROJ-13:** the Stop and `PreToolUse` ask guards read no `owner_asks` row (they classify the message and read the session row and presence), so they cannot see an automation's ask; text unchanged. The Desktop's terminal delivery of an automation ask is excluded in the Swift phase (Task 12). Guards: `internal/db/owner_asks_automation_test.go::TestAutomationAsks_InvisibleToSessionReaders`, `internal/tools/workbench_asks_automation_test.go::TestAutomationAsks_InvisibleToSessionReaders`; every existing PROJ-12/PROJ-13 guard green unmodified.
- 2026-10-16 (board #328, diff reviewer Plan 1; **approved by the owner, spec review ask #179**): **PROJ-12 amended** — the delivery also carries the diff reviewer's round line `Review round #<id> sent (<n> comment[s]) — read it with get_review <id> …`, typed through `SessionLineDelivery` (`LineKey.review`) under the same gates and only after `review send` stored the round; no gate relaxed, no guard changed, round guards listed under PROJ-12 and in `review.md` (REVIEW-04).
- 2026-10-15 (first run P2, Home, board #783): note only, no contract text changed and no guard relaxed. **PROJ-01** — the Desktop's Home "My targets" read `TargetQueries.homeSummary` is one more non-board reader filtering `project_id IS NULL`; its guard `testProj01_HomeSummaryNeverReturnsAProjectTarget` is listed under PROJ-01.
- 2026-10-15 (board #266, configurable methodology; spec `docs/superpowers/specs/2026-10-15-workbench-configurable-methodology-design.md` §9, plan `docs/superpowers/plans/2026-10-15-workbench-configurable-methodology.md`; **PROJ-13, PROJ-04 and PROJ-02 amended, owner approved in asks #141 (modes), #146 (spec) and #150 (plan)**): **PROJ-13** gains the ask guard modes (`strict`/`soft`/`off`) and the finish check (`on`/`off`) for the Stop and PreToolUse guards, resolution failure → strict + on, and off with the finish check off → no model call. **PROJ-04** — the install writes the v10 core and the `watchtower-flow` preset, removes the preset only when ours, and keeps a drifted pre-v10 single file without a preset. **PROJ-02** — a delete removes our preset too. **PROJ-08** — listing only: the installed preset directories are skipped from the folder's docs index like the core. **PROJ-14** unchanged, noted: with the finish check off a session the agent does not finish ends as Stopped without a summary; only `finish_session` marks a session finished. **PROJ-03** unchanged: the Desktop's "Create workflow.md" runs the CLI on the owner's click and never overwrites a file; the agent never writes `workflow.md` or its own checks (no MCP tool changes them). PROJ-07 and PROJ-11 unchanged. All existing guards kept, none relaxed.
- 2026-10-15 (Automations P1, board #753): note only, no contract text or guard changed. The owner's `watchtower automations` CLI can write and remove recipe files in a workbench folder's `.watchtower/automations/` (`save --path` atomically through `fsutil.WriteFileAtomic`; `delete` removes only a regular recipe file in that folder); `dry-run --file` and `rescan --workbench N` read it. No Desktop path, workbench MCP tool or daemon code writes the folder in P1, so PROJ-03 (the Desktop's writes) is unchanged; the owner-approved PROJ-03 amendment (ask #272, automations spec §14.6) is written into PROJ-03 with Automations P5, which adds the Desktop save.
- 2026-10-14 (board #535, session cleanup; spec `docs/superpowers/specs/2026-10-12-session-cleanup-design.md` §13, business page `…-business.md`, plan `docs/superpowers/plans/2026-10-12-session-cleanup.md`; **PROJ-18 added, PROJ-11, PROJ-04 and PROJ-02 amended, owner approved 2026-10-12, ask #193**): `watchtower workbench cleanup` (`internal/sessioncleanup`, migration `00111`: `terminal_session_worktrees` + `terminal_sessions.cleanup_result`/`cleanup_at`) plans, then with `--apply` removes, the linked worktrees and local branches a session's agents created — never unsaved, unpushed, in-use or someone else's work (PROJ-18, the approved wording verbatim plus the stricter as-shipped list); the skill pack's finishing step runs it (DEV-04 changelog: pack v8); the Desktop offers it on Delete Session (**Delete and Clean Up**, the default, or **Delete Only**), per session (**Clean Up…**) and as the owner's sweep (**Clean Up Old Worktrees…**, with a one-time hint above 1 GB). **PROJ-11:** the state hooks record each new (worktree root, branch) of any agent of the session, at most 64, without git; a ledger failure never costs the state write. **PROJ-04:** the install adds one `permissions.allow` rule `Bash(<bin> workbench cleanup:*)` (the bin quoted only when unsafe, ours only with an absolute `watchtower` bin, the owner's entries never touched). **PROJ-02:** the folder removal deletes that rule; the ledger goes with the session row by cascade (`TestProj02_RemoveProjectLeavesNothingInstalled` and `TestProj02_DeleteProjectLeavesNoRows` extended, assertions added). **PROJ-17:** note only — `delete` (✕, ⌘⌫, Delete Only) is a no-op and Start fresh refused on a row a cleanup runs on, and every resume of a row whose terminal Delete and Clean Up closed is refused. **PROJ-14** unchanged (the report only reads `cleanup_result`). No guard relaxed.
- 2026-10-14 (merging main into feature/533-sessions; no new principle, no guard changed): **PROJ-16** — Ready to check (#534, ask #195) counts as idle for a phone line: it is a resting form of Finished / Waiting for you. **PROJ-17** — renumbered because PROJ-16 is the phone-typing contract (main); the session cleanup of board #535 is PROJ-18 (its inventory entry follows with #535); its phone-list wording now says the row leaves and comes back on the hub's next 30 s full tick, not at once (main's #724 removed the fast nudge).
- 2026-10-14 (target 156; **approved by the owner 2026-10-14, ask #118**): **PROJ-02 amended — an exception for links leaving the folder.** When the removal refuses a file or directory linked outside the folder (PROJ-04), the delete still completes and names the exact outside file and what to remove by hand: `devpack.OutsideFolderError` (an `ErrSymlinkOutsideFolder` refusal carrying the outside path; the error text is unchanged) and `devpack.OutsideFolderHints`, printed by `workbench delete` (stderr, `--json` `removal_hints`) and `integrate remove --workbench N`, shown by the Desktop's delete warning in place of the raw error. New guard `TestProj02_DeleteWithASettingsLinkOutsideNamesTheLeftoverHooks`; no guard changed.
- 2026-10-14 (target 156, security review group 146; **approved by the owner 2026-10-14, ask #109**, "refuse with an error"): **PROJ-04 amended** — a `settings.local.json` (or imported `.codex` hook file) symlink is followed only while its target stays inside the workbench folder; one leaving it (e.g. to `~/.claude/settings.json`, which made our hooks global) is refused by install and removal before any write, with an error naming the link, its target and the fix (`devpack.ErrSymlinkOutsideFolder`); likewise a `.claude`/`.codex` directory (any directory between the folder and the file) that is a symlink leaving the folder, and a `.claude`/`.claude/skills`/`.agents/skills` (or skill) directory linked outside it: the skill install and removal refuse before writing or removing a skill file (guard `TestProj04_SkillDirectoryLinkOutsideTheFolderIsRefused`, with `TestProj04_SkillDirectoryLinkInsideTheFolderIsFollowed` for a link inside). The two symlink guards `TestProj04_InstallAndRemoveThroughASymlinkKeepTheLink` and `TestProj04_RemoveLeavingNothingThroughASymlinkEmptiesTheTarget` had their link target moved inside the folder — the intended change, their assertions unchanged (a link is kept and written through); new guards `TestProj04_SymlinkOutsideTheFolderIsRefused` and `TestProj04_DedupeRefusesASymlinkOutsideTheFolder`. The git `info/exclude` file keeps following its link (it lives in the git dir). No other guard changed.
- 2026-10-13 (mobile E2E final review, **owner approved, ask #96**): **PROJ-16 condition (0) gains a dated note**, heading, guarantee and guards unchanged. Under E2E every relay record is sealed to a linked phone's key, so a record that opens under no linked phone's key (an unknown or a removed key) is dropped with no answer — the Mac cannot seal a reply to a key it does not know (D9) — instead of being answered `device_not_linked`; a record that opens under a linked phone's key but names another `device_id` still gets `device_not_linked`. Nothing unlinked is typed either way.
- 2026-10-12 (board #565, WT1–WT4 #566–#569; spec `docs/superpowers/specs/2026-10-12-session-worktree-design.md` §8, plan `docs/superpowers/plans/2026-10-12-session-worktree.md`; **PROJ-11, PROJ-10 and PROJ-03 amended, owner approved 2026-10-12, ask #188**): a session knows the folder its agent works in. **PROJ-11** — the main agent's hook events record their `cwd` in `agent_cwd`/`agent_cwd_at` (migration `00110`) without touching any state column. **PROJ-10** — `workbench git status|branches|switch|create --folder F` resolve F against the repository's worktrees before any git runs there (`folder_not_a_worktree`, `folder_unreadable`, `git_failed`; scope `""` = unresolved), and the header's branch menu works on the shown session's worktree, unavailable for a worktree Go did not place; the agent check counts an unknown, stale or removed place. **PROJ-03** — the code viewer works on that root with tabs and buffers per root (lexical key), and a removed worktree is never written again. No guard relaxed, renamed or split; new guards listed under each contract.
- 2026-10-12 (board #480, sessions panel; spec `docs/superpowers/specs/2026-10-12-sessions-panel-design.md` §4.2–§4.3 and §8.2, plan `docs/superpowers/plans/2026-10-12-sessions-panel.md` Task 7; **PROJ-17 added, owner approved 2026-10-12, ask #195**): a session delete is deferred — the row is hidden and its process stopped at once, its DELETE runs when the 5 s Undo window of the batch ends or the app quits, and Undo restores the whole batch untouched. The spec's "PROJ-16" became PROJ-17 (PROJ-16 is the phone typing contract; the session cleanup of board #535 is PROJ-18). **PROJ-02** and **PROJ-14** unchanged: the same DELETE with the same cascades, only later; nothing writes report links. `testQuickDeleteTable` renamed to the guard `testProj17_QuickDeleteTable` (assertions unchanged). Known limits: a crash or `kill -9` inside the window leaves the row (it is listed again on the next launch); the phone's session list drops the row only on the hub's next 30 s full tick (main's #724 removed the fast nudge for this kind) and, after Undo, shows it again only on the next tick; a late async hook of the killed process may still write the row's state, which Undo then shows.
- 2026-10-12 (board #534, sessions panel; spec `docs/superpowers/specs/2026-10-12-sessions-panel-design.md` §8.1, plan `docs/superpowers/plans/2026-10-12-sessions-panel.md` Tasks 1–4; **PROJ-11 amended, owner approved 2026-10-12, ask #195**): a session whose open asks are all `check` or `review` asks (no `question`) shows **Ready to check** (purple, checklist glyph, "Ready for review" when every one is a review) instead of Finished or Waiting for you. It sits between Agents working and Finished in the order (ten kinds), is not run-scoped (a ring when not live), counts as at the prompt (`isAtPrompt`, PROJ-12's Return unchanged) and gets no state notice — the ask's own notice now reads "Ready to check: <title>" / "Ready for review: <title>". One open question keeps Waiting for you. `fetchAgentStates` adds `open_question_asks`/`open_review_asks`; no migration. The phone hub wires the kind `ready_to_check` and the tone `purple` (Kit known values appended, wire order unchanged). Guards extended, none relaxed or renamed: `testProj11_StateOrder` (ten kinds; the `row` helper's `questions` defaults to `openAsks`, so the earlier rows keep their expectation), `testProj11_OneNoticePerTransition`; new guards listed under PROJ-11.
- 2026-10-12 (B18 review round 1, same task; within the OD-1/OD-2 approval): **PROJ-16 tightened**, heading and guards unchanged, supporting tests added. A held line is no longer retried by the state reads its own tries make (`SessionLineDelivery` counts its own reads and `statesRead()` ignores them; the app wires it through `SessionLineDelivery.follow`) — before, a line held by its gate retried itself in a tight read loop while the agent worked. A session counts as busy right after the app submitted a line into it until a hook reports after the submit (30 s cap). A retry types only after claiming its sidecar row and only while its hub runs (`SessionLineDelivery.GateAnswer.drop`), so a cancel or a hub stop during a retry's read types nothing and a quick stop and start types at most once. Only the phone that sent a line may cancel it. The phone's toggle revokes the grant only on its own on→off change. The text rule is `SessionInputText` (Kit), shared with the phone: a CRLF is one space and format characters stay (`TerminalCenter.submitPrompt`/`sendPrompt` and `WorkbenchCommentPrompt.terminalPayload` gain `keepingFormatCharacters`, default false — answers and hand-offs unchanged). **PROJ-12 wording and guards unchanged**: a delivery's own reads no longer set off a retry of the held answers either; a held answer still goes on the next successful read of the state center.
- 2026-10-12 (mobile POC plan B, Task 18, spec `docs/superpowers/specs/2026-10-07-mobile-poc-design.md` §6.6, §10, §11; **owner approved 2026-10-07, OD-1 and OD-2**): **PROJ-16 added** — a line from the owner's phone (`session_input`, `session_finish_request`) reaches a Claude Code session only from a device linked by a QR scan and allowed to type on the Mac, only while the agent is idle and the prompt holds no draft, and only through `SessionLineDelivery` under PROJ-12; held lines are echoed with their reason, retried on state reads, expire after 24 h, survive a hub restart, fail on a revoke and can be cancelled; nothing from the phone answers a permission prompt. Code: `WatchtowerDesktop/Sources/Services/MobileHub/Handlers/SessionInputHandlers.swift`, the sidecar's `held_session_lines` and `devices.typing_requested`, `MobileLinkCenter`'s typing request and revoke hooks. **PROJ-12 unchanged in wording and guards**: `SessionLineDelivery.deliverLine` gains an optional per-line gate asked right before the paste (an ask's answer passes none), and a held line is tried again at the end of another line's delivery only when it was queued behind that line — a line held at a permission prompt or after a failed read still goes on the next successful state read, as PROJ-12 says (the old retry after every delivery could spin while two lines stayed held).
- 2026-10-12 (board #399, Codex as a Workbench agent; spec `docs/superpowers/specs/2026-10-12-codex-workbench-agent-design.md` §13 and §15, business spec `docs/superpowers/specs/2026-10-12-codex-workbench-agent-business.md`, plan `docs/superpowers/plans/2026-10-12-codex-workbench-agent.md`; **owner approved the spec, which carries these amendments, in ask #189**): a workbench terminal session can run Codex CLI. No new PROJ number (no new principle): **PROJ-02** (delete also removes the Codex skill copy, never the shared trust), **PROJ-04** (`integrate codex`: only our skill copy and exclude line in the folder, only our entries removed from imported `.codex` hook files, only our `hooks.state` trust entries in `~/.codex/config.toml` through codex's API — narrower than the spec's §13 wording, since `--remove` never removes trust), **PROJ-11** (heading "never steer Claude Code" → "never steer the session's agent"; the codex mapping table and codex v1 limits), **PROJ-12** (the gates apply to codex rows; the input profile is per agent), **PROJ-13** (the ask guard for codex: `request_user_input`, `last_assistant_message`), **PROJ-14** (the report includes codex rows; the comment `agent_label` follows the row) amended. Migration `00109` rebuilds `terminal_sessions` (`kind` adds `codex`; a codex row may hold a NULL id until its first SessionStart; `agent_transcript_path`). Every existing `TestProj*`/`testProj*` guard is unchanged and green; new guards are listed under each contract. The v1 limits note (d) of "Owner asks" is updated.
- 2026-10-11 (board #543, child of #411; spec `docs/superpowers/specs/2026-10-10-session-background-agents-design.md` §11 and Appendix C, plan `docs/superpowers/plans/2026-10-11-teammates-working.md`): **PROJ-11 amended, approved by the owner in ask #167** ("only while they work") — a named agent-team teammate counts toward Agents working only inside its own turn. Claude Code lists a teammate in `background_tasks` as `running` from spawn to shutdown, idle or not, under an id that is not its hook `agent_id`, so the list cannot say; its `SubagentStart` (every message it handles) and `SubagentStop` (its turn's end) can. Migration `00108` adds the Go-only `terminal_sessions.agent_turns`; the new async `SubagentStart` state hook and `SubagentStop` record turns; the count adds the open unlisted turns, capped by the listed teammates, and drops subagents whose turn closed — which also fixes the #543 tail where the last `SubagentStop` left the count at 1 because the list still carried a subagent that had stopped just before it. **PROJ-04 amended** (same approval): six state hook entries; a malformed owner `hooks.SubagentStart` is refused like the others. Guards: `TestHasStateHooksNeedsAllFiveCoreNeedsFour` became `TestHasStateHooksNeedsAllSixCoreNeedsFour` and `TestInstallStateHooksAddsSubagentStop` became `…AddsSubagentStopAndStart` (supporting, each with the sixth entry, no case dropped); `TestBackgroundSubagentsCountsSubagentsAndWorkflows` became `TestBackgroundAgentsCountTable` plus `TestBackgroundAgentsLeavesOutTheStoppingAgent` (every case kept, the three `except` cases in the second); `TestProj11_SubagentStopOnlyLowersTheCount`'s last step now pins that a `SubagentStop` over `working` changes only `agent_turns` (it wrote nothing at all before) — every other column still byte-identical. No guard relaxed otherwise. Folders need Re-run Setup / Repair once more. Review fixes (same PR): `GetTerminalSession` never reads `agent_turns` (`workbench asks` and the ask guard open a 00107 database unmigrated; `TestGetTerminalSessionNeedsNoAgentTurnsColumn`); `MarkTerminalAgentRun` keeps its stamp as the turns' run mark and an earlier turn stamp writes nothing; a SubagentStop never counts its own agent; a replaced unreadable `agent_turns` is one stderr line.
- 2026-10-11 (owner asks v2, board #395/#501/#503, spec `docs/superpowers/specs/2026-10-10-owner-asks-v2-design.md`, business spec `docs/superpowers/specs/2026-10-10-owner-asks-v2-business.md`, plan `docs/superpowers/plans/2026-10-10-owner-asks-v2.md`; **owner approved the business spec, which amends PROJ-13, in ask #148 on 2026-10-11**, on top of asks #66, #145 and #146): **PROJ-13 rewritten** — the `Stop` ask guard is the command hook `workbench ask-guard --workbench N --stop` (v4 classifier `internal/devpack/askguard_classifier.md`, light tier, fixed Go decision table, presence from `owner_presence`): a short question passes as terminal text only while the owner is in the session and once it is recorded (`chat_question`, `chat_question_at`, migration `00107`), otherwise it is sent back (`R-away`); a review, a check or several decisions left as text get `R-full`; the finish reminder stays (`R-finish`, `R-finish-ask`); a database failure now reads as the owner away (at most one send-back, never a loop — the narrowing of "never block because Watchtower is broken" the owner approved, business D1); the `AskUserQuestion` denial reason follows presence. The v3 golden assertions each map to a v4 golden clause or a named Go guard (table under PROJ-13); `TestProj13_OlderPromptsAreUpgradedToTheCurrent` is rewritten to the command entry at the same strictness; new guards `TestProj13_StopGuardDecisionTable`, `TestProj13_ChatPassesOnlyWhenPresentAndRecorded`, `TestProj13_ContinuedTurnNeverBlocks`, `TestProj13_StopGuardNeverTouchesTheStateColumns`, `TestProj13_ACancelledModelCallLeavesNoProcess`, `TestProj13_EscalationIsCompareAndTake`; the failure, locked-DB, no-DB and no-migration guards are extended to `--stop`. **Implementation rulings:** the PROJ-13 implementation notes (light tier as an isolated child, the message's last 32 KiB, SIGHUP too, a deleted workbench and a continued turn outside a terminal row call no model, a read failure blocks only the record, the `AskUserQuestion` present reason also needs the core state hooks, its reads share a 1.4 s budget from the database open, presence reads cut off at its end reading as away — named in the Observable's under-2 s sentence too —, and `escalate-question`'s open, lock wait and `bad_args` for unparsable flags); the classifier text is a documented exception to the DB-backed prompts rule. **PROJ-11 amended** (one paragraph, meaning unchanged) — the chat question columns are written only by the guard, the state hooks' clears and the escalation, never change a state or its time, and a new run or conversation clears them; new guard `TestProj11_ChatQuestionWritesNeverTouchTheState`, `TestProj11_NewRunAndConversationSwitchClearTheCount` extended. **PROJ-04 amended** — the install replaces every marker prompt of N (an edited one too) with the Stop command entry, carrying the owner's keys on that prompt onto it; `TestProj04_AskGuardReplacesOurEditedPromptAndKeepsOwnerHooks` rewritten to the command entry with its check kept — the owner's key on our edited prompt is now asserted on the command entry, number literal included — as are the owner's keys on our command entry written from another binary (updated in place) and the owner's own hooks and keys; new `TestProj04_AskGuardCommandEntryCarriesTheKeysOfOurReplacedPrompt`, new `Stop` twin `TestProj04_MalformedStopWithOurPromptLeavesTheFileByteIdentical`, `TestProj04_RemoveDeletesOnlyOurHook` extended. **PROJ-02 strengthened** — the delete leaves the owner's presence row in no session (`ON DELETE SET NULL`); `TestProj02_DeleteProjectLeavesNoRows` extended. **PROJ-12** wording unchanged: Quick ask answers from the banner and the stack go through the drawer's call; two supporting guards added. Also (not a contract change): `ask_owner` stores the level and refuses re-filing a withdrawn ask without a revision — the 7-day window runs from the withdrawal, not the filing (`owner_asks.withdrawn_at`, `00107`; asks withdrawn before it carry `''` and never match), and the title refusal matches the ask's kind as well (spec Part 8's text names only the title). None of the guards was relaxed.
- 2026-10-10 (board #478, **owner approved 2026-10-09 (#478)** in chat): **PROJ-13 amended** — the ask guard prompt is v3. v2 failed almost every intermediate report and step-by-step help on an ask already filed, which Claude Code prints as "Stop hook error" and which looped the agent. v3 passes by default, states that unfinished work is never case 2, that a named `ask #<number>` (including step-by-step help on it) is never a failure and that a closing summary after `finish_session` is not case 1 (it never affects case 2), gives failure case 1 priority over that pass list, and enumerates exactly two failure cases (a request left as text, a completed session without `finish_session`; "a PR opened or merged" alone no longer counts as complete). The pass rules (`stop_hook_active`, when unsure) are unchanged. The golden is updated to v3 and `TestProj13_AskGuardPromptPassesAContinuedTurnAndAFiledAsk` pins more pass clauses than before; `TestProj13_V1PromptIsUpgradedToV2` is renamed `TestProj13_OlderPromptsAreUpgradedToTheCurrent` and now also covers a v2 install and an edited v2 (fixture `internal/devpack/testdata/askguard_prompt_v2.md`), its assertions unchanged.
- 2026-10-10 (board #411, spec `docs/superpowers/specs/2026-10-10-session-background-agents-design.md`): **PROJ-11 amended 2026-10-10, approved by the owner in ask #139** (what counts, the 120 s grace and the `SubagentStop` hook in ask #138; the staleness probe in asks #138, #140 and #142: the registry decides, the ping is not built) — a session whose main turn ended while background subagents still run shows **Agents working** instead of Stopped. Migration `00106` adds `terminal_sessions.agent_background` and `agent_background_at` (Go writes, the Desktop reads); the Stop hook stores the count of `subagent`/`workflow` entries of its input's `background_tasks`; a subagent's tool result over a counted `waiting` only refreshes the report time; the new async state hook `SubagentStop` only lowers the count; every main turn, a StopFailure, the idle notice, a new run and a conversation switch clear it. No new `agent_state` value: Agents working is a presentation of the stored `waiting`, so the turn order, repeats, failures, `finished_at`, `isAtPrompt` (ruling R52) and PROJ-12's Return are untouched — PROJ-12 gains two guards pinning that an answer into an Agents working session gets its Return and one into its background agent's permission prompt is held. The state hooks split into the core four (gating the Stop's state write and the run mark) and all five (the status's `state_hooks`), so a folder set up earlier keeps recording until Re-run Setup or Repair adds the `SubagentStop` entry; **PROJ-04** names the fifth event, the malformed-file rule covering it. Guards rewritten to the new rule, none relaxed: `TestProj11_PostToolUseIntoWorkingClearsFinished`'s subagent half (a counted `waiting` changes only `agent_background_at`), `testProj11_StateOrder` (nine kinds), `testProj11_OneNoticePerTransition` (agents working posts nothing, the stop after it once); extended: `TestProj11_HookNeverWritesStdoutAndExitsZero`, `testProj11_StateFromAnEarlierRunIsIgnored`, `TestProj04_MalformedStateEventLeavesTheFileByteIdentical` and `TestProj04_StateHooksKeepOwnerHooksAndKeys` (now over `SubagentStop` too). New guards listed under PROJ-11 and PROJ-12. v1 note "Session agent state ordering and subagents" (d) extended.
- 2026-10-10 (mobile companion POC, spec `docs/superpowers/specs/2026-10-07-mobile-poc-design.md`, notes `docs/features/mobile-companion.md`): note only — **no contract, guard test or status changed**. The Desktop's mobile hub is a new owner-surface writer: a phone's ask answer goes through `OwnerAsksViewModel.answer(_:with:)` (the Desktop's own structured entry, so PROJ-12's delivery rules hold unchanged); its board status, priority, comment and reply writes go through Core's `WorkbenchOwnerWrites`, which `WorkbenchBoardViewModel` now shares (PROJ-05's rollup and PROJ-06's owner-claimed history unchanged); its new targets go through `watchtower workbench target add`. The hub's cloud copy is a board-only mirror: it publishes board targets only (`project_id IS NOT NULL`, PROJ-01) and reads the archive verdict from `workbench_target_archive` (PROJ-15, read only); a different-Apple-ID phone reaches that mirror only through the DataZone zone share, read-only.
- 2026-10-08 (mobile POC plan B, Task 17, spec `docs/superpowers/specs/2026-10-07-mobile-poc-design.md` §6.6): **PROJ-12** — deliver moved into SessionLineDelivery, guards unchanged. `OwnerAsksViewModel.deliver`, its held and queued lines and `deliverHeldAnswers` now live in `WatchtowerDesktop/Sources/Services/SessionLineDelivery.swift` (owned by `AppState`, one queue per session, so the phone's session input of Task 18 takes the same path); `SessionAgentStateCenter.onChange`/`onRead` call `SessionLineDelivery.deliverHeld`, and `OwnerAsksViewModel.deliverHeldAnswers` forwards to it. New supporting tests: `WatchtowerDesktop/Tests/SessionLineDeliveryTests.swift`.
- 2026-10-07 (board #415, spec `docs/superpowers/specs/2026-10-07-workbench-archive-now-design.md`): **PROJ-15 amended 2026-10-07, approved by the owner in ask #106** (the spec §3 wording and all four §1 decisions as recommended) — "Archive Closed Targets Now". Migration `00105` adds `projects.archived_through` (a UTC moment, NULL = never pressed, `CHECK` it parses) and recreates `workbench_target_archive` with a second branch: a closed subtree whose newest close time is not after the moment is archived whatever `archive_after_days` says, including Never (decision 1); both `done` and `dismissed` count (decision 4). The Observable's first sentence is replaced and one sentence added after "Reopening restores it"; "hidden, never lost", groups-go-whole, restore-by-reopening and the drift guarantee are unchanged, and "Why locked" is unchanged — Undo is an extra, not the only way back. Writers: the Desktop's `WorkbenchQueries.archiveClosedTargetsNow`/`clearArchivedThrough` (the header's "Archive Closed Targets Now" / "Undo Archive Now") and the Go twins `db.ArchiveWorkbenchClosedNow`/`db.ClearWorkbenchArchivedThrough`; no CLI writer, no MCP tool. Every existing PROJ-15 guard runs unchanged (`TestProj15_PerWorkbenchSettingAndNever` still asserts that 0 archives nothing with no stamp); new guards in `internal/db/proj15_archive_now_test.go`, a stamp-only case in `TestProj15_DriftStillSeesArchivedUnmergedWork`. PROJ-05/06/07/09 untouched: the button writes only `projects`. v1 note "Board archive" extended.
- 2026-10-07 (board #396, with #387/#388/#389; owner directive 2026-10-05 «send it right away», approved as an amendment of PROJ-12): **PROJ-12 amended** — an answer is also submitted into a session whose hooks have not written a state yet this run, when its SessionStart hook marked the run. Root cause: a relaunch or resume (`startup`/`resume`) cleared the row's state, so `SessionAgentStatus.at` was nil until the agent's next turn and the line was only pasted ("press Return to send") into an idle session; a compaction while idle continues the run and changed nothing. Now the SessionStart hook writes the run's mark (`MarkTerminalAgentRun`: no state, a stamp of this run) when the workbench's folder has the session state hooks (`workbenchHasStateHooks`), even with nothing to clear; without them `ClearTerminalAgentState` clears with no stamp (it used to stamp the clear), so a mark always means the state hooks run. The Desktop reads it as `SessionAgentStatus.runMarked`/`hooksReported`; the dot, `isAtPrompt` (hand-offs, ruling R52) and PROJ-11's states and notices are unchanged. The permission-dialog guard (`needsApproval` before the paste and after the pause, failed reads) and the owner-draft guard are unchanged. Also: the Return goes only into the process run the line was pasted into (`TerminalCenter.runs`; a relaunch reuses the process object, #387 — also for held answers and the read before the paste), the owner's submitting Return during the pause skips ours and leaves no bar (#388), a restart drops the last run's paste bar (#389), and the condition that withheld a Return is logged. Guards rewritten to the new rule, none relaxed: `testProj12_WithoutAHookStateThisRunTheLineIsOnlyPasted` → `testProj12_WithoutTheStateHooksTheLineIsOnlyPasted` (same assertions), `CodeHandoffCenterTests::testAnAnswerIntoASessionWithOnlyAnEarlierRunsStateIsOnlyPasted` → `testProj12_WithoutTheStateHooksAnAnswerIsOnlyPasted` (the earlier run's state kept, plus no row, an earlier run's mark and an unknown value; the bar asserted). New guards `testProj12_AFreshOrResumedRunWithTheStateHooksGetsTheReturn`, `testProj12_ACompactWhileIdleKeepsTheReturn`, `TestProj12_ANewRunWithTheStateHooksIsMarked`, `TestProj12_CompactWhileIdleKeepsTheRunsState`. Limit (h) rewritten. No hook setting changed (the SessionStart entry already ran for every source), so no Re-run Setup. PROJ-11's guards are unchanged; its "the SessionStart clear of a new run" is now the mark or the stampless clear.

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
