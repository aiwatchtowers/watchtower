# Parallel workbench sessions in their own git worktrees — design

**Date:** 2026-10-14 · **Board:** #229 · **Owner decisions:** asks #108–#114, #122
**Revision 2 (2026-10-14, ask #122):** rebuilt on top of what landed on main meanwhile —
board #565 "the session knows its worktree" (`2026-10-12-session-worktree-design.md`: `agent_cwd`,
`SessionPlace`, the place badge, the code viewer and branch menu following the session's worktree)
and board #535 "session cleanup" (`2026-10-12-session-cleanup-design.md`: `workbench cleanup`,
`terminal_session_worktrees`, PROJ-18). This feature no longer has its own cleanup, badge or
contract; it adds what main still lacks — **putting** a session into a worktree.

## 1. Problem and goal

A workbench is bound to one folder. Every agent session (Claude Code or Codex) of a workbench
starts in that folder, so two agents working at the same time edit the same files, run builds over
each other's half-done changes, and a branch switch by one (or by the owner from the header) swaps
the files under the other. #565 shows where a session works and #535 cleans up worktrees a session
made, but a worktree exists only if the agent itself decides to make one.

**Goal (ask #108):** parallel agents of one workbench never step on each other, without the user
having to know what a git worktree is. A product feature for every Watchtower user, not a setting
for this repository.

**Non-goals for v1:** accepting or discarding a session's work from Watchtower (merge buttons);
worktrees for shell sessions or standalone terminals; a cleanup path of our own (#535's is used).

## 2. Behaviour in one paragraph

When a new agent session starts in a workbench whose folder is in a git repository, and the
folder already has a **live agent session working in it**, the new session gets its own worktree:
Watchtower creates a branch off the folder's current `HEAD`, checks it out under
`<repo>/.claude/worktrees/<name>`, clones the paths listed in `.worktreeinclude` into it, installs
the workbench integration there, runs the workbench's optional setup command, and starts the agent
in it. From then on #565 shows the place (`⑂ <name> · wt/<name>`) and the code viewer follows it.
When the session is finished and its agent has exited, Watchtower runs #535's cleanup for that
worktree and its branch: they go when nothing can be lost (clean tree, commits merged or pushed),
otherwise they stay and the cleanup says why. The owner can override the automatic choice from the
new-session menu.

## 3. Decisions

| # | Decision | Source |
|---|----------|--------|
| D1 | The pain to solve first is parallel agents. | ask #108 |
| D2 | A session gets a worktree only when the folder already has a live agent session in it; a lone session works in the folder as today. | ask #110 |
| D3 | After the session the worktree is cleaned up automatically; merging is done the usual way (PR, git). The cleanup is #535's `workbench cleanup`, with all of PROJ-18's catches. | asks #111, #122 |
| D4 | Preparation: `.worktreeinclude` paths cloned (APFS copy-on-write) + an optional per-workbench setup command. | ask #112 |
| D5 | UI: #565's place label and per-worktree code viewer; this feature adds only the start choice and the setup field. | asks #113, #122 |
| D6 | Go creates worktrees (`watchtower workbench worktree create|ensure`), one path for Claude and Codex. | ask #114 |
| D7 | The branch starts from the folder's current `HEAD`. | ask #114 |
| D8 | The new-session menu offers "In This Folder" / "In Its Own Worktree" over the automatic choice. | ask #114 |
| D9 | #565's D8 is amended: a session Watchtower placed in a worktree stores that worktree as its `folder_path`, so every launch and resume runs there; every other session keeps the workbench folder. | ask #122 |

## 4. Placement rule (Desktop, pure)

`SessionStartPlacement.decide` (WatchtowerCore, pure, unit-tested; the name avoids #565's
`SessionPlace`) returns `.folder` or `.worktree` from:

- `override`: `.auto` (default), `.folder`, `.worktree` (D8);
- `gitStatus` of the workbench folder: the existing `workbench git status` envelope
  (`git_available`, `git`, `unborn`);
- `occupied`: whether a **live** agent row of the workbench (`claude`/`codex`) works in the main
  folder. A row works there when its #565 trusted place is `.main`, or when its place is unknown
  and its `folder_path` is the workbench folder (a fresh session before its first hook). A row
  whose place is a worktree, or which was placed in one (`worktree_branch` set) and has not
  reported otherwise, does not occupy the folder — so once the folder's own session ends, the
  next one takes the folder again. An agent that `cd`s back into the main folder occupies it
  again.

Rules, in order:
1. Not a git repository, git unavailable, or an unborn `HEAD` → `.folder` (the "In Its Own
   Worktree" item is disabled with the reason).
2. `override == .folder` → `.folder`; `override == .worktree` → `.worktree`.
3. `occupied` → `.worktree`, else `.folder`.

Every start path uses it: **Work on It** (when it creates a new row), **New Session**, the setup
session, the code handoff and the phone's session start. Decisions are serialised per workbench
(one in flight), so two starts at the same moment do not both see the folder free. Reopening an
existing row never re-decides: it runs where the row lives (§7).

## 5. Creating a worktree (Go)

`watchtower workbench worktree create --workbench N --name <slug> [--json]` in a new file of
`internal/workbenchgit` (`worktree.go`), reusing `open`, `locatePaths` and the environment rules of
`run.go` (no inherited `GIT_*`, `GIT_OPTIONAL_LOCKS=0`, `LC_ALL=C`, `gitbin`-located git, never the
shim). Write budget 60 s, like `switch`. Every git outcome is an exit-0 envelope; non-zero only
when the workbench or its folder does not resolve (as `workbench git`).

Steps:
1. Resolve `top_level` and `common_dir`. Refuse (`refused`) on: git missing, not a repository,
   unborn `HEAD`.
2. **Name.** Branch `wt/<slug>`, path `<top_level>/.claude/worktrees/<slug>` — the same place
   Claude Code's own `EnterWorktree` uses, which #535's nested-worktree catch (W9) already knows.
   The Desktop passes the slug: `<target id>-<target words>` for a target session, `session-<n>`
   otherwise, ASCII-folded, ≤ 40 characters. When the branch or the path exists, append `-2`,
   `-3`, … (never reuse either).
3. **Exclude.** Make sure `/.claude/worktrees/` is in `<common_dir>/info/exclude` (append once,
   PROJ-04 style: never rewrite the owner's lines), so the main folder never shows the worktrees
   as untracked in a repository that does not ignore `.claude/`.
4. `git worktree add -b wt/<slug> <path> HEAD`. The base is the commit, so a detached `HEAD` works
   too. Uncommitted changes of the main folder are not carried over (the envelope says
   `base_dirty: true` so the Desktop can say so).
5. **Include files** (§6).
6. **Integration** (§8).
7. The session's working directory is `<path>/<prefix>`, where `prefix` is the workbench folder's
   path inside the repository, so a workbench bound to a subfolder of a repository keeps working in
   that subfolder (#565's `folder_root` rule, same join).

Envelope: `workbench_id`, `created`, `path`, `cwd`, `branch`, `base` (sha), `base_branch`,
`base_dirty`, `included[]`, `include_warnings[]`, `refused` (`git_unavailable|not_git|unborn|
git_failed`) + `refused_detail`, `error`, `warning`.

If a step after 4 fails, the worktree is kept and returned with `warning`: the session still starts
and the user sees what went wrong. A failure at step 4 leaves nothing behind.

## 6. `.worktreeinclude`

The de-facto convention also read by Claude Code, Conductor and PostHog Code: a file at the
repository root, `.gitignore` syntax; a path is copied only when it matches a pattern **and** git
ignores it, so tracked files are never duplicated. No file → nothing is copied.

- List: `git ls-files -z --others --ignored --directory --exclude-from=<top>/.worktreeinclude` run
  in the main folder, intersected with `git ls-files -z --others --ignored --directory
  --exclude-standard`. `--directory` keeps a large ignored tree (`node_modules/`, `.build/`) one
  entry.
- Copy each entry with `clonefile(2)` (APFS copy-on-write; a directory clones recursively in one
  call): instant and close to free on disk, which is what makes an 8 GB build cache usable.
- When the volume cannot clone (not APFS, cross-volume), copy normally only while the running total
  stays under 1 GiB; entries past that are skipped and listed in `include_warnings`.
- A symlink is copied as a symlink, never followed out of the repository.
- An entry that already exists in the worktree is left alone.

The cloned paths are ignored, so they never count as changes for #535's W4 catch; they go with the
worktree when it is removed. Repository-specific fix-ups (for this repo: drop the path-bound Swift
`ModuleCache` after cloning `.build`) belong in the setup command, not in Go.

## 7. Session row, start and resume

**Migration `<next free>_terminal_session_placement.sql`** (00113 on main today):
- `terminal_sessions.worktree_branch TEXT` — non-NULL = Watchtower created the worktree this row's
  `folder_path` is in, on branch `wt/<slug>`; NULL = every other row (all existing rows).
- `terminal_sessions.worktree_base TEXT` — the commit it was cut from.
- `projects.worktree_setup TEXT NOT NULL DEFAULT ''` — the setup command.

Mirrored into `schema.sql`, the golden snapshot and the Swift test schema. No "kept" or "removed"
column: #535's `cleanup_result` already records what the last cleanup kept and why.

**Start.** For `.worktree` the Desktop calls `worktree create` first, then inserts the row with
`folder_path = cwd`, `worktree_branch` and `worktree_base` (D9). When `create` refuses or errors,
the session starts in the folder and the panel says why ("Started in the folder: <reason>"), never
silently. `base_dirty` shows one line: "The new worktree does not have the folder's uncommitted
changes."

**Setup command.** On the row's first launch only, the terminal runs `<worktree_setup>` in the
worktree before the agent, visibly, through the same login shell; a non-zero exit prints one line
and the agent still starts. Resumes never re-run it. Empty = nothing.

**Resume.** `folder_path` is every launch's cwd, and Claude Code resolves its transcript by cwd,
so a resume must land at the same path. When the worktree directory is gone (cleaned up, or deleted
by hand) and the branch still exists, `watchtower workbench worktree ensure --workbench N --path P
--branch B` re-adds it at the same path from the branch (and redoes §6 and §8, not the setup
command). When the branch is gone too (#535 removes a merged branch), the row is unavailable:
"The worktree and its branch wt/… were cleaned up — start a new session." Never a silent start in
the main folder.

## 8. Workbench integration inside a worktree

Claude Code keys its project configuration by the working directory: the hooks and #535's cleanup
permission in `.claude/settings.local.json`, the skill in `.claude/skills/`, and the
`watchtower-workbench` MCP server registered with `--scope local` (stored per path in
`~/.claude.json`). All are gitignored or local, so a fresh worktree has none of them, and without
them the state hooks (and so #565's place and #535's ledger), the Stop drift check, the ask guard
and the board tools would not work.

`create`/`ensure` therefore run the same installer as `integrate claude-code` for the worktree path
(`devpack`, same files, same `--workbench N`, PROJ-04's never-overwrite rules), and register the
MCP server for that path. Codex gets its MCP server and hooks on the command line
(`workbench launch-args`), so only its skill (`.agents/skills/…`) is installed. Removal never calls
`devpack.RemoveWorkbench` for a worktree (it drops `info/exclude` lines whose paths are gone, and
`info/exclude` is shared by every worktree); the stale local MCP entry of a removed worktree path is
unregistered by the post-cleanup step (§9).

Open item for the plan (spike): whether Claude Code shows its folder-trust prompt on the first
launch in a new worktree path, and if so how the main folder's setup avoids it today. Watchtower
does not write `~/.claude.json` by hand.

## 9. End of a session: #535's cleanup

No cleanup code of our own. The Desktop runs `watchtower workbench cleanup --session N --apply
--item worktree:<root> --item branch:wt/<slug> --json` when the cases below happen. The call
removes `WATCHTOWER_TERMINAL_SESSION_ID` from its environment, as #535 §4 requires of every Desktop
caller. #535 has landed in full (CLI, `SessionCleanupCenter`, the Delete Session dialog,
**Clean Up…**, the sweep, the report line): this feature calls the CLI through
`SessionCleanupCenter` and never builds a second center.

The cases:

- the agent process of a row with `worktree_branch` exits while the row is finished — the normal
  end. The agent itself cannot remove its own placed worktree: its process's cwd is inside it
  (#535's W5/W6 keep it), so this is the Desktop's job, after the exit;
- the owner deletes the row: #535's Delete Session dialog already plans and offers the cleanup;
  with the by-record ownership below, the placed worktree and branch are on its list.

Only those two items are named, so the automatic run never touches anything else the session saw.
Every PROJ-18 catch applies: uncommitted changes, an operation in progress, unpushed commits, a
process in it, another session in it — each keeps the item, and `cleanup_result` says why (#535's
session report line shows it). A kept worktree is removed by a later cleanup (**Clean Up…** on the row, the
next finish, the workbench sweep). After a removed worktree, the Desktop unregisters that
path's local MCP entry (`watchtower workbench worktree forget --workbench N --path P`, which runs
only `claude mcp remove --scope local` for that path and nothing in git).

**Ownership (PROJ-18 amendment).** #535 owns an item only when the session observed it **and** it
was born after the session row (`created_at`, second precision, +1 s fail-closed). A placed worktree
is created before its row, so rule 2 would keep it `existed_before_session`. Amendment: the
worktree at the row's own `folder_path` repository root and the row's own `worktree_branch` are the
session's **by record** — Watchtower made them for that row — and skip rules 1 and 2. Nothing else
changes: every safety catch still runs.

**Workbench deletion (PROJ-02):** for each row with `worktree_branch`, the same cleanup runs before
the rows go; kept worktrees stay on disk and the delete confirmation lists them by path.

## 10. Desktop UI (D5)

- New-session menu and **Work on It**'s split button: **In This Folder** / **In Its Own Worktree**
  (D8), disabled with the reason when §4 rule 1 holds.
- Workbench settings: a **Worktree setup command** field (`projects.worktree_setup`), with a
  one-line hint pointing at `.worktreeinclude`.
- The place label, the code viewer's root, the branch menu, **Clean Up…** and the sweep are #565's
  and #535's, unchanged. A placed session's row additionally gets **Show Worktree in Finder**.

## 11. Changes to existing contracts

- **#565 D8 / PROJ-03 note:** amended as D9 — a placed session's `folder_path` is its worktree.
  The test that pins "new sessions keep `folder_path` = workbench folder" gains the placed case.
- **PROJ-10 (branch switch guard):** no rule change. #565's agent fact already ignores a live row
  whose known place is another worktree and counts an unknown place everywhere (fail closed); a
  placed session before its first hook is counted, after it is not. A test pins it.
- **PROJ-14 (session report):** no change — `branch:`/`pr:` refs resolve repository-wide; a test
  pins that a `wt/…` branch is reported.
- **PROJ-18 (session cleanup):** amended with the by-record ownership of §9; the Desktop's
  automatic run after a placed session ends.
- **PROJ-02 / PROJ-04:** amended as in §8–§9 (integration installed into worktrees; workbench
  deletion cleans placed worktrees; never `RemoveWorkbench` on a worktree).
- **Guard (no new contract id):** `TestProj18_PlacementNeverForcesOrDiscards` — create and ensure
  run no `worktree remove`, `--force`, `branch -D`, `reset`, `clean`, `checkout --` or `stash`
  (the `TestProj10_NeverForcesOrDiscards` pattern over the runner's argv).

Every inventory change needs the owner's approval before it lands; the spec review is that
approval.

## 12. Testing

- Go, `internal/workbenchgit`: real temp repositories — create (names and suffixes, detached base,
  subfolder prefix, exclude line added once, refusals, `base_dirty`), include (match ∩ ignored,
  `--directory` collapse, symlink kept, clone fallback cap with a fake cloner), ensure (re-add from
  branch, branch gone), the argv guard.
- Go, `internal/sessioncleanup`: a placed row's worktree and branch are owned by record although
  born before the row; an unplaced worktree born before the row is still kept.
- Go, `cmd`: envelopes and exit codes; `forget` touches no git.
- Go, `internal/sessionreport`: a `wt/…` branch is reported.
- Swift, WatchtowerCore: `SessionStartPlacement.decide` table test; envelope decoding.
- Swift, Desktop: start paths pick the placement, a refused create falls back with a visible note,
  concurrent starts serialise, cleanup fires on exit-while-finished with exactly the two items,
  resume re-adds the worktree or says it is gone, the PROJ-10 fact for placed rows.
- Manual check (ask): two agents on one workbench, setup command, resume after cleanup, a Codex
  session in a worktree.

## 13. Risks and limits (v1)

- The user's uncommitted changes in the main folder are not in a new worktree; the Desktop says so.
- Ports, databases and other machine-wide resources are still shared between parallel agents;
  worktrees isolate files only.
- A volume without clones copies at most 1 GiB of include paths.
- A worktree whose branch has unpushed commits stays after the session (#535's W7/B4) until it is
  pushed or merged; the session report says so, and **Clean Up…** or the sweep removes it later.
- An agent started outside Watchtower (a `claude` in another terminal app) is not seen as occupying
  the folder, as today.
