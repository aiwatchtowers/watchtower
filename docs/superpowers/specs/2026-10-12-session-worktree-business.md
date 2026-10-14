# The session knows its worktree (board #565) — business spec

**For:** the owner. One page. The tech spec is `2026-10-12-session-worktree-design.md`; the plan is
`docs/superpowers/plans/2026-10-12-session-worktree.md`.

## The problem

An agent in a workbench session often moves into a git worktree (`.claude/worktrees/<name>`) and works there on
its own branch. The Desktop does not notice. When you switch to that session, the header shows the branch of the
main folder, FILES and the Files pane show the main folder's files, and the branch menu would switch the main
folder. You cannot tell where the session is working, and the files you look at are not the ones it edits.

## What you will see

- **Every session row says where it works:** `⑂ mobile-a · feature/x` for a worktree, `main folder · main` for
  the workbench folder. The page header shows the same for the session on screen, next to the folder path.
- **The label follows the agent.** When the agent goes into a worktree (or comes back), the label changes with its
  next step — the next tool it runs, the end of its turn, your next prompt. Nothing to set up; no Re-run Setup.
- **The session on screen sets the page's folder.** The FILES tree, the Files pane and its tabs, the git marks,
  Open Quickly, go to definition / usages and the branch menu all work on that session's worktree. With no session
  on the page (just the board), they work on the main folder.
- **Each worktree keeps its own Files tabs.** Switch from a session in worktree A to one in B: you see B's tabs.
  Switch back: A's tabs are there as you left them, unsaved edits included. An edit made in A's file is only ever
  saved into A's file — never into the same-named file of B or of the main folder.
- **The branch menu works on that worktree.** Switching or creating a branch changes that worktree only. "Is an
  agent working here?" asks about the sessions in that worktree, so a session busy in another worktree no longer
  makes you confirm. A session whose place is not known yet still counts, so the confirmation is never skipped
  when it might matter.
- **"+" always starts the new session in the main folder**, even while a worktree session is on screen.

## Edge cases, in plain words

- **The worktree was deleted** (by the agent, or by cleanup on close, board #535): the row says
  `worktree removed`, and the page falls back to the main folder without an error. Files that had unsaved edits in
  that worktree are not written anywhere; a banner lists them so you can copy or discard them.
- **The agent wandered outside the repository** (`cd /tmp`): treated as the main folder.
- **A session that is not running** keeps showing the place it last worked in, so you can look at its files.
  When it starts again, its first report says where it really is.
- **A sub-agent working in its own worktree** does not move the session's label: only the main agent's place
  counts.
- **Search in the assistant** (workbench files in knowledge search) stays on the main folder only — worktree
  copies of the same files are not indexed twice.

## Contract changes (approved by you 2026-10-12, ask #188)

- **PROJ-11** (session state hooks): the hooks also record the main agent's folder, in the same write as the
  state, and write nothing when it did not change. They still never print anything, never block, never steer.
- **PROJ-10** (branch switch): the branch menu reads and switches the worktree of the session on screen; every
  guard (unsaved edits saved first, branch checked out elsewhere, merge in progress, your confirmations) applies to
  that worktree, and the agent question is asked about the sessions in it.
- **PROJ-03** (the Desktop never writes behind anyone's back): the code viewer also writes files of the session's
  worktree, under the same rules, and an edit is only ever saved into the worktree it was made in.

Guard tests are not weakened; new guards are added for each change.

## Decisions taken (no answer needed)

1. Files tabs: one set per worktree, kept when you switch away (your answer in ask #188).
2. A session not yet reported (or from before this change) counts as the main folder for display, and as
   "maybe working here" for the branch-switch confirmation.
3. Knowledge search keeps indexing the main folder only (PROJ-08 unchanged).
