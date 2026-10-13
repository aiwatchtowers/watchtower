# Parallel workbench sessions in their own git worktrees — design

**Date:** 2026-10-14 · **Board:** #229 · **Owner decisions:** asks #108–#114

## 1. Problem and goal

A workbench is bound to one folder. Today every agent session (Claude Code or
Codex) of a workbench runs in that one folder, so two agents working at the
same time edit the same files, run builds over each other's half-done changes,
and a branch switch by one (or by the owner from the header) swaps the files
under the other. PROJ-10's agent-running guard exists because of this.

**Goal (ask #108):** parallel agents of one workbench never step on each other,
without the user having to know what a git worktree is. This is a product
feature for every Watchtower user, not a setting for this repository.

**Non-goals for v1:** accepting or discarding a session's work from Watchtower
(merge buttons), the code viewer following a session's worktree, worktrees for
shell sessions or standalone terminals.

## 2. Behaviour in one paragraph

When a new agent session starts in a workbench whose folder is inside a git
repository, and the folder already has a **live agent session working in it**,
the new session gets its own worktree: Watchtower creates a branch off the
folder's current `HEAD`, checks it out under `<repo>/.claude/worktrees/<name>`,
clones the paths listed in `.worktreeinclude` into it, runs the workbench's
optional setup command, installs the workbench integration there, and starts
the agent in it. The session row shows a branch badge. When the session is
finished and its agent has exited, a clean worktree is removed; the branch
stays, and merging it is the user's or the agent's job (PR, git). A worktree
with uncommitted changes is kept and marked. The owner can override the
automatic choice from the new-session menu.

## 3. Decisions

| # | Decision | Source |
|---|----------|--------|
| D1 | The pain to solve first is parallel agents. | ask #108 |
| D2 | A session gets a worktree only when the folder already has a live agent session in it; a lone session works in the folder as today. | ask #110 |
| D3 | After the session: remove a clean worktree automatically, keep the branch; merging is done the usual way. | ask #111 |
| D4 | Preparation: `.worktreeinclude` paths cloned (APFS copy-on-write) + an optional per-workbench setup command. | ask #112 |
| D5 | UI v1: a badge on the session row plus Finder / terminal menu items; the code viewer stays on the main folder. | ask #113 |
| D6 | Go creates and removes worktrees (`watchtower workbench worktree …`), one path for Claude and Codex. | ask #114 |
| D7 | The branch starts from the folder's current `HEAD`. | ask #114 |
| D8 | The new-session menu offers "In this folder" / "In its own worktree" over the automatic choice. | ask #114 |

## 4. Placement rule (Desktop, pure)

`SessionPlacement.decide` (WatchtowerCore, pure, unit-tested) returns
`.folder` or `.worktree` from:

- `override`: `.auto` (default), `.folder`, `.worktree` (D8);
- `gitStatus` of the workbench folder: the existing `workbench git status`
  envelope (`git_available`, `git`, `unborn`);
- `occupied`: whether a **live** agent row (`TerminalCenter.liveIDs`, kind
  `claude`/`codex`) has a `folder_path` that resolves (symlinks) to the
  workbench folder itself. A live session in a worktree does not occupy the
  folder, so once the folder's own session ends, the next one takes the folder
  again.

Rules, in order:
1. Not a git repository, git unavailable, or an unborn `HEAD` → `.folder`
   (the "In its own worktree" item is hidden or disabled with the reason).
2. `override == .folder` → `.folder`; `override == .worktree` → `.worktree`.
3. `occupied` → `.worktree`, else `.folder`.

Every start path uses it: **Work on It** (`startTarget` when it creates a new
row), **New session** (`newSession`/`startNewSession`), the setup session, the
code handoff (`CodeHandoffCenter`) and the phone's session start
(`startForTarget`). Reopening an existing row never re-decides: it runs where
the row lives (§7).

## 5. Creating a worktree (Go)

`watchtower workbench worktree create --workbench N --name <slug> [--json]`
in a new file of `internal/workbenchgit` (`worktree.go`), reusing `open`,
`locatePaths` and the environment rules of `run.go` (no inherited `GIT_*`,
`GIT_OPTIONAL_LOCKS=0`, `LC_ALL=C`, `gitbin`-located git, never the shim).
Write budget 60 s, like `switch`. Every git outcome is an exit-0 envelope;
non-zero only when the workbench or its folder does not resolve (as
`workbench git`).

Steps:
1. Resolve `top_level` and `common_dir`. Refuse (`refused`) on: git missing,
   not a repository, unborn `HEAD`.
2. **Name.** Branch `wt/<slug>`, path `<top_level>/.claude/worktrees/<slug>`.
   The Desktop passes the slug: `<target id>-<target words>` for a target
   session, `session-<n>` otherwise, ASCII-folded, ≤ 40 characters. When the
   branch or the path exists, append `-2`, `-3`, … (never reuse either).
3. **Exclude.** Make sure `/.claude/worktrees/` is in `<common_dir>/info/exclude`
   (append once, PROJ-04 style: never rewrite the owner's lines), so the main
   folder never shows the worktrees as untracked in a repository that does not
   ignore `.claude/`.
4. `git worktree add -b wt/<slug> <path> HEAD`. The base is the commit, so a
   detached `HEAD` works too. Uncommitted changes of the main folder are not
   carried over (the envelope says `base_dirty: true` so the Desktop can say so).
5. **Include files** (§6).
6. **Integration** (§8).
7. The session's working directory is `<path>/<prefix>`, where `prefix` is the
   workbench folder's path inside the repository (`rev-parse --show-prefix`),
   so a workbench bound to a subfolder of a repository keeps working in that
   subfolder.

Envelope: `workbench_id`, `created`, `path`, `cwd`, `branch`, `base` (sha),
`base_branch`, `base_dirty`, `included[]`, `include_warnings[]`,
`refused` (`git_unavailable|not_git|unborn|git_failed`) + `refused_detail`,
`error`, `warning`.

If a step after 4 fails, the worktree is kept and returned with `warning`: the
session still starts and the user sees what went wrong. A failure at step 4
leaves nothing behind (`git worktree add` is atomic enough; a half-made
directory is removed only when git reports it did not register it).

## 6. `.worktreeinclude`

The de-facto convention also read by Claude Code, Conductor and PostHog Code:
a file at the repository root, `.gitignore` syntax; a path is copied only when
it matches a pattern **and** git ignores it, so tracked files are never
duplicated. No file → nothing is copied.

- List: `git ls-files -z --others --ignored --directory --exclude-from=<top>/.worktreeinclude`
  run in the main folder, intersected with
  `git ls-files -z --others --ignored --directory --exclude-standard`.
  `--directory` keeps a large ignored tree (`node_modules/`, `.build/`) one entry.
- Copy each entry with `clonefile(2)` (APFS copy-on-write; a directory clones
  recursively in one call): instant and close to free on disk, which is what
  makes an 8 GB build cache usable.
- When the volume cannot clone (not APFS, cross-volume), copy normally only
  while the running total stays under 1 GiB; entries past that are skipped and
  listed in `include_warnings` ("not copied: node_modules/ (2.3 GB, the volume
  does not support clones)").
- A symlink is copied as a symlink, never followed out of the repository.
- An entry that already exists in the worktree (it cannot, since it is ignored
  and the worktree is new, but a re-run might) is left alone.

Repository-specific cleanup (for this repo: drop the path-bound Swift
`ModuleCache` after cloning `.build`) belongs in the setup command, not in Go.

## 7. Session row, start and resume

**Migration `00110_terminal_session_worktrees.sql`:**
- `terminal_sessions.worktree_branch TEXT` — non-NULL = this row owns the
  worktree at `folder_path`'s repository root (`wt/<slug>`); NULL = a folder
  session (all existing rows).
- `terminal_sessions.worktree_state TEXT CHECK (worktree_state IN ('kept'))`,
  NULL = live or removed-clean; `'kept'` = the agent ended but the worktree had
  uncommitted changes (§9). Plus `worktree_removed_at TEXT`.
- `projects.worktree_setup TEXT NOT NULL DEFAULT ''` — the setup command.
Mirrored into `schema.sql`, golden snapshot and the Swift test schema.

**Start.** For `.worktree` the Desktop calls `worktree create` first, then
inserts the row with `folder_path = cwd` and `worktree_branch = branch`. When
`create` refuses or errors, the session starts in the folder and the panel
says why ("Started in the folder: <reason>"), never silently.

**Setup command.** On the row's first launch only, the terminal runs
`<worktree_setup>` in the worktree before the agent, visibly, through the same
login shell (`TerminalLaunch.make`); a non-zero exit prints one line and the
agent still starts. Resumes never re-run it. Empty = nothing.

**Resume.** `folder_path` is already every launch's cwd, and Claude Code
resolves its transcript by cwd, so a resume must land at the same path. When
the worktree directory is gone (auto-removed clean, or deleted by hand) and
the branch still exists, `watchtower workbench worktree ensure --workbench N
--path P --branch B` re-adds it at the same path from the branch (and redoes
§6 and §8, not the setup command). When the branch is gone too, the row is
`.unavailable("The worktree and its branch wt/… no longer exist.")`.

## 8. Workbench integration inside a worktree

Claude Code keys its project configuration by the working directory: the
hooks in `.claude/settings.local.json`, the skill in `.claude/skills/`, and
the `watchtower-workbench` MCP server registered with `--scope local` (stored
per path in `~/.claude.json`). All three are gitignored or local, so a fresh
worktree has none of them, and without them the state hooks, the Stop drift
check, the ask guard and the board tools would not work.

`create`/`ensure` therefore run the same installer as `integrate claude-code`
for the worktree path (`devpack`, same files, same `--workbench N`, PROJ-04's
never-overwrite rules), and register the MCP server for that path.
Codex already gets its MCP server and hooks on the command line
(`workbench launch-args`), so only its skill (`.agents/skills/…`) is
installed. Removal (§9) unregisters the local MCP entry of that path, so
`~/.claude.json` does not grow one stale entry per session.

Open item for the plan: check whether Claude Code shows its folder-trust
prompt on the first launch in a new worktree path, and if so whether the
installer can pre-accept it the way the main folder is set up today.

## 9. End of a session and cleanup

`watchtower workbench worktree remove --workbench N --path P [--json]`:
1. Read `git status --porcelain` in the worktree. Ignored files do not count
   (the cloned include paths are ignored).
2. Any change (modified, staged, untracked not ignored, an operation in
   progress) → nothing is written; envelope `kept: true`, `changes: n`.
3. Clean → unregister the local MCP entry, `git worktree remove <path>`
   (no `--force`, ever), then `git worktree prune` for that entry only.
4. The branch is kept (D3). One exception: a branch Watchtower created that
   has no commit beyond its base (`rev-list --count base..branch == 0`) is
   deleted with `git branch -d` (never `-D`), so sessions that changed nothing
   leave no branch behind (`branch_deleted: true`).

**When it runs (Desktop):**
- the agent process of a worktree row exits while the row is finished
  (`finished_at` set) — the normal end;
- the owner removes the session row from the panel;
- the owner picks **Remove Worktree** in the row's menu (offered only while no
  agent runs in it).
A `kept` result sets `worktree_state = 'kept'`; the row shows "changes left in
the worktree" until a later `remove` succeeds (re-tried on the next finish or
by the menu item). A session that resumes after removal goes through `ensure`
(§7).

**Workbench deletion (PROJ-02):** every clean session worktree of the
workbench is removed as above; a kept one is left on disk, its MCP entry is
unregistered, and the delete confirmation lists it by path.

## 10. Desktop UI (D5)

- Session row: a `⎇ wt/<slug>` badge (branch, middle-truncated) and, when
  `worktree_state = 'kept'`, a warning dot with "Uncommitted changes left in
  the worktree".
- Row menu: **Show Worktree in Finder**, **Open Terminal in Worktree** (a shell
  session in that folder), **Remove Worktree** (§9).
- New-session menu and **Work on It**'s split button: **In This Folder** /
  **In Its Own Worktree** (D8), disabled with the reason when §4 rule 1 holds.
- Workbench settings: a **Worktree setup command** field (`projects.worktree_setup`),
  with a one-line hint pointing at `.worktreeinclude`.
- Header branch, FILES and the editor keep showing the main folder.

## 11. Changes to existing contracts

- **PROJ-10 (branch switch guard):** `hasLiveAgentSession` stops counting
  every live row of the workbench (`projectID == workbenchID`); only rows whose
  folder resolves inside the main folder's work tree count. An agent in its own
  worktree no longer blocks the owner's branch switch, which is the point.
- **PROJ-14 (session report):** `internal/sessionreport` reads branch and PRs
  in the session's own folder (`terminal_sessions.folder_path`), not
  `projects.folder_path`, so a worktree session reports its `wt/…` branch and
  its PR.
- **PROJ-07 (drift check):** unchanged; it runs in the main folder and
  compares target branches with the default branch, which covers `wt/…`
  branches like any other.
- **PROJ-02 / PROJ-04:** amended as in §8–§9.
- **New PROJ-17 — a session worktree never loses work:** Watchtower never
  removes a worktree with uncommitted changes, never runs `worktree remove
  --force`, `branch -D`, `reset`, `clean` or `checkout --` in it, and deletes
  only a branch it created that carries no commit of its own. Guard test
  `TestProj17_NeverForcesOrDiscards` (the `TestProj10_NeverForcesOrDiscards`
  pattern over the runner's argv).

Every inventory change needs the owner's approval before it lands; the spec
review is that approval.

## 12. Testing

- Go, `internal/workbenchgit`: real temp repositories — create (names and
  suffixes, detached base, subfolder prefix, exclude line added once, refusals),
  include (match ∩ ignored, `--directory` collapse, symlink kept, clone fallback
  cap with a fake cloner), remove (clean → removed, dirty/untracked/operation →
  kept, empty branch deleted, branch with commits kept), ensure (re-add from
  branch, branch gone), and the PROJ-17 argv guard.
- Go, `cmd`: envelopes and exit codes, as `workbench_git_test.go`.
- Go, `internal/sessionreport`: a worktree row reports its own branch.
- Swift, WatchtowerCore: `SessionPlacement.decide` table test; envelope decoding.
- Swift, Desktop: start paths pick the placement, a refused create falls back
  with a visible note, cleanup fires on exit-while-finished and on row removal,
  the PROJ-10 guard ignores worktree rows.
- Manual check (ask): two agents on one workbench, setup command, resume after
  auto-removal, a Codex session in a worktree.

## 13. Risks and limits (v1)

- The user's uncommitted changes in the main folder are not in a new worktree;
  the Desktop says so when `base_dirty`.
- Ports, databases and other machine-wide resources are still shared between
  parallel agents; worktrees isolate files only.
- A volume without clones (external disks, some network shares) copies at most
  1 GiB of include paths.
- Worktree branches pile up when sessions commit and nobody merges; the drift
  check and the branch list show them, cleanup of merged `wt/…` branches is a
  follow-up.
- An agent started outside Watchtower (a `claude` in another terminal app) is
  not seen as occupying the folder, as today.
