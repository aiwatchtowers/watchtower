# Projects — Behavior Inventory

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/db/projects.go`,
> `project_comments.go`, `project_board.go`, the `project_id` exclusions in
> the targets readers, `internal/tools/project*.go`, `cmd/project*.go`,
> `internal/devpack/project*.go`, or `WatchtowerDesktop/Sources/**/Project*`,
> read this file first. Any proposed change that would break a guard test or
> remove a contract must be raised as a question before touching code.

A project is a folder with a board of targets, attached documents and
owner↔agent comments, worked on by Claude Code through
`watchtower mcp --project N` (DEV-06 in `dev-surface.md`), a project skill and
a `SessionStart` hook. Design:
`docs/superpowers/specs/2026-09-29-project-board-poc-design.md`.

**Module:** `internal/db/{projects,project_comments,project_board}.go` +
`internal/tools/{projects,project_targets,project_docs,project_scope}.go` +
`cmd/{project,project_brief}.go` + `internal/devpack/{project,project_settings}.go` +
`WatchtowerDesktop/Sources/Views/Projects/`
**Last full audit:** 2026-09-29

## PROJ-01 — project targets never reach a non-board reader

**Status:** Enforced (Go); the Desktop half lands with Task 20

**Observable:** A target with `project_id` set lives only on its project's
board. Every non-board Go reader filters `project_id IS NULL`: `GetTargets` by
default (`TargetFilter.ProjectID == 0`), `GetTargetsNeedingNextStep`,
`GetTargetsForBriefing`, `GetTargetCounts`, `NotifyDueTargets`,
`ListCatchupTargets`, `ListTargetsForMirror`, `internal/dayplan/gather.go`,
`internal/db/channel_stats.go`, and the extract/dedup snapshots in
`internal/targets/pipeline.go`; `nextstep.go`'s single-target path skips a
project target. The registry's `list_targets`/`get_target` return a project
target only inside that project's own session (`watchtower mcp --project N`);
any other session is told `no target with id N`.

**Why locked:** Owner decision D4. An agent decomposes a plan into dozens of
sub-targets; letting them into the Targets tab, the day plan, next-step,
Catch-Up, memory mirrors or the inbox overdue notification would flood every
personal surface with the agent's own bookkeeping — and spend next-step AI
calls on it.

**Test guards:**
- `internal/db` — `TestProj01_ProjectTargetsNeverReachNonBoardReaders` (Task 3)
- `internal/tools/projects_test.go::TestProj01_TargetReadsFollowTheSessionScope`

**Locked since:** 2026-09-29

## PROJ-02 — delete leaves nothing

**Status:** Enforced

**Observable:** `watchtower project delete N` first runs the folder removal
(`projectRemoveInstall`, wired to `devpack.RemoveProject`: the
`watchtower-project` skill, our `SessionStart` hook entry, the local
`watchtower-project` MCP registration and the `.git/info/exclude` lines
Watchtower added) — a removal failure is reported and the delete still
happens — then deletes the project row, which removes every project target,
source, document entry and comment in the same transaction
(`db.DeleteProject`, `ON DELETE CASCADE` from `projects`). A Claude Code
session still connected answers `project N no longer exists` on every tool
(DEV-06). The document files themselves are the owner's and stay in the
folder. An exclude line is removed only when its path is gone — a skill the
owner edited (kept, PROJ-04) or a settings file holding the owner's own keys
keeps its line, so removal never surfaces an owner file in `git status`.

**Why locked:** Owner decision D7. A half-deleted project — orphan targets, a
hook that briefs about a project that no longer exists, an MCP server
registered against a dead id — is worse than no project at all, and the owner
must be able to undo the whole feature for a folder in one step.

**Test guards:**
- `internal/db/projects_test.go::TestProj02_DeleteProjectLeavesNoRows`
- `internal/tools/registry_project_test.go::TestProjectBinding_DeletedProjectAnswersNoLongerExists`
- `internal/mcp/project_test.go::TestProjectMode_DeletedProjectEveryToolAnswersNoLongerExists`
- `internal/devpack/project_test.go::TestProj02_RemoveProjectLeavesNothingInstalled`
- `internal/devpack/project_test.go::TestProj02_RemoveProjectLeavesGitStatusClean`
- `internal/devpack/project_test.go::TestProj02_RemoveProjectKeepsOwnerSettingsButDropsOurHook`
- `cmd/integrate_project_test.go::TestProj02_ProjectDeleteRunsTheFolderRemoval`

**Locked since:** 2026-09-29

## PROJ-03 — the Desktop never writes a project document

**Status:** Planned (the Desktop document view lands with Task 16)

**Observable:** The Desktop reads an attached document (`project_documents.rel_path`
under the project folder) to render it and re-anchor its comments, and writes
only `project_comments` rows — owner comments, replies, status, `read_at` —
never the file. Only the agent edits a document; the Desktop watches the file
and re-anchors, and a comment whose quote is gone becomes `outdated`, never
re-attached elsewhere. No project tool writes a file either:
`attach_document` only resolves and stats it.

**Why locked:** Owner decision D8. Two writers on one file — Claude Code in
the terminal and the Desktop view — would race and lose either the agent's or
the owner's edits; comments are the owner's channel into the document.

**Test guards:** the Desktop guards (`testProj03_…`) land with Task 16. Go
side, by review: `grep -nE "os\.(WriteFile|Create|OpenFile|Rename|Remove)" internal/tools/project_docs.go`
(expected: no match).

**Locked since:** 2026-09-29

## PROJ-04 — the install never overwrites the owner's content

**Status:** Enforced

**Observable:** `watchtower integrate claude-code --project N` merges into
`DIR/.claude/settings.local.json` preserving every key and every hook the
owner has, adding exactly one `SessionStart` entry recognised by its exact
command string (installing twice leaves one); a malformed settings file is
left byte-identical and reported; `integrate remove --project N` deletes only
that entry. The `watchtower-project` skill follows DEV-04: a copy the owner
edited (differs from both what we ship and its `.watchtower-shipped` digest)
is never overwritten or deleted.

**Why locked:** The project folder is the owner's repository. An installer
that dropped one of the owner's settings keys or hooks, or clobbered an edited
skill, would make every later `integrate` a risk to the owner's own setup.

**Test guards:**
- `internal/devpack/project_settings_test.go::TestProj04_InstallKeepsOwnerSettingsKeysAndHooks`
- `internal/devpack/project_settings_test.go::TestProj04_MalformedSettingsLeftByteIdentical`
- `internal/devpack/project_settings_test.go::TestProj04_RemoveDeletesOnlyOurHook`
- `internal/devpack/project_test.go::TestProj04_EditedProjectSkillIsNeverClobbered`

**Locked since:** 2026-09-29

## Changelog

- 2026-09-29: file created with PROJ-01..04 by the Projects POC (spec `docs/superpowers/specs/2026-09-29-project-board-poc-design.md` §7, plan `docs/superpowers/plans/2026-09-29-projects-poc.md`). PROJ-01 Enforced on the Go side (Task 3's reader exclusions + the registry's session-scoped `list_targets`/`get_target`, Task 7); PROJ-02 Enforced for the database (Task 4) with the folder half pending Task 12; PROJ-03 Planned (Task 16); PROJ-04 Planned (Tasks 11–12). The write path into these tables from Claude Code is contract DEV-06 in `dev-surface.md`.
