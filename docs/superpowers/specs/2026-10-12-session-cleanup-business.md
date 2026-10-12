# The agent cleans up after its session (board #535) — business spec

**For:** the owner. One page. The tech spec is `2026-10-12-session-cleanup-design.md`; the plan is
`docs/superpowers/plans/2026-10-12-session-cleanup.md`. Builds on board #565 (the session knows its worktree).

## The problem

Sessions leave their worktrees and local branches behind. After the mobile POC: 6 worktrees (~38 GB — a worktree
with a warm Desktop build weighs 5–11 GB) and 22 local branches, all committed and pushed, simply forgotten. The
agent could not remove them itself: auto mode blocks `git worktree remove` and `git branch -D`.

## What you will see

- **The agent cleans up before it finishes.** Its last step before "session finished" is one Watchtower command:
  first it lists what it would remove, then it removes it. Its finish summary gains one line, e.g.
  `Cleanup: 2 worktrees, 4 branches removed (~14 GB); kept 1 worktree — uncommitted changes.`
- **The session report shows the same** — what was removed, the space freed, and what was kept and why — even if
  the agent forgot to mention it.
- **Deleting a session offers the cleanup:** "Also clean up: 2 worktrees, 3 branches (~12 GB). Kept: 1 — unpushed
  commits." Buttons: **Delete and Clean Up** / **Delete Only** / Cancel.
- **Clean Up…** in a session's menu does the same without deleting the session: a list with sizes, everything safe
  ticked, kept items greyed out with the reason.
- **Clean Up Old Worktrees…** in the workbench header menu: the one-time sweep of what older sessions left —
  worktrees and branches of sessions finished or idle for 7+ days, deleted, or from before this change. Nothing is
  pre-selected there; you tick what goes.

## What is removed — only what this session (or its subagents) created

- its worktrees (the build folders inside them go with them);
- its local branches that are merged into main or sit whole on GitHub;
- leftover processes it started in its worktrees that nobody owns any more (test stubs, dev servers);
- the macOS "app registrations" of Watchtower builds made inside those worktrees (the duplicate-app problem).

"Created by this session" means: an agent of the session worked in it, **and** it appeared after the session
started. A worktree or branch that existed before (yours, or another session's) is never touched by the agent.

## What is never touched

Claude's history (`~/.claude/projects/…`); the session itself, its report and asks; branches on GitHub; the main
folder and its build; any workbench's own folder; anything another session is working in; anything not created by
this session (outside the sweep, where you choose by hand).

## Safety catches (each one has its own test)

A worktree stays — reported as "kept: why" — if it has uncommitted or untracked changes, if its commits are not in
main or on GitHub, if a program still runs in it, if another live session is working in it, or if it is locked. A
branch stays if any commit on it is only on this Mac, if it is checked out anywhere, or if it is main. The command
looks again right before each removal, and git's own refusal is the last catch. It never fetches from GitHub: the
agent fetches first, so merged work is recognised.

## What you need to do once

**Re-run Setup** (or Repair) on each workbench folder: it adds the one permission that lets the agent run the
cleanup command in auto mode — this command only, not `git branch -D` in general.

## Not in this version (later, if wanted)

Xcode DerivedData of the phone app, scratch files in `/tmp`, branches squash-merged on GitHub whose remote branch
was already deleted (kept and reported — "delete by hand"), app registrations of builds outside the workbench
folder, an automatic cleanup prompt when a session turns Finished.

## Contract changes (need your approval)

New **PROJ-16** (cleanup never removes unsaved, unpushed, in-use or someone else's work); **PROJ-11** (the hooks
also note which worktree and branch each agent of the session worked in, only when new); **PROJ-04/PROJ-02** (Setup
adds the cleanup permission and removing the workbench takes it away); DEV-04 changelog only (skill pack v7).

## Open questions

1. Should **Delete and Clean Up** be the default button of the delete dialog? *Recommended: yes.*
2. Should the workbench show a one-time hint ("Old worktrees use ~38 GB — Clean Up…") when the sweep finds over
   1 GB, or only the menu item? *Recommended: the one-time hint.*
