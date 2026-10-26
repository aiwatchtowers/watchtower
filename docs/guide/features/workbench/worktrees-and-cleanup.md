# Worktrees and cleanup

Watchtower can give each agent session its own git worktree, so parallel agents never overwrite each other, and it can tidy up the worktrees and branches a finished session leaves behind. This page is for anyone running more than one agent in a repository.

## Why use it

Two agents in one folder edit the same files. A worktree is a second checkout of the same repository on its own branch, so each session has its own copy.

The price is disk: one worktree with a warm build can take several GB, and each leaves a branch behind. Cleanup removes both, safely.

## How it works

### Where a new session starts
<!-- learn
id: worktrees-parallel-agents
title: Run agents side by side in worktrees
text: Start a second session while an agent works and it gets its own git worktree, so they never clash.
area: development
level: next
kind: feature
since: 0.24.0
action: nav:projects
-->
<!-- learn
id: worktrees-starting-at-once
title: A new session shows up at once
text: A new session appears in the list right away and reads **Starting…** while its worktree is made.
area: development
level: next
kind: tip
since: 0.25.0
action: nav:projects
-->
<!-- learn
id: worktrees-setup-command
title: Prepare each new worktree
text: Set **Worktree Setup Command…** in the **…** menu, such as a dependency install, to run before the agent starts.
area: development
level: power
kind: feature
since: 0.24.0
action: nav:projects
-->

A plain new session, or **Work on It** on a card, starts in the folder. If a live agent already works in the folder, it starts in a new worktree instead. A worktree is a branch named `wt/<name>`, created under `.claude/worktrees/` in the repository from the folder's current commit. Uncommitted changes of the folder are not carried over. The session appears at once and reads **Starting…** while its worktree is made.

Two overrides sit in the new-session menus and the card's **Work on It** menu: **In This Folder** and **In Its Own Worktree**. If git cannot make a worktree (no repository, no commits yet), the session starts in the folder and says why in **Started in the folder: …**.

A file named `.worktreeinclude` at the repository root lists ignored files, such as `.env`, to copy into each new worktree. Only files that match it and that git ignores are copied, as cheap copy-on-write clones.

In the title row's **…** menu, **Worktree Setup Command…** sets one shell command that runs in each new worktree before the agent starts, for example a dependency install. A failure prints a line and the agent starts anyway. It does not run on resume.

A session row shows where the agent works, and **Show Worktree in Finder** opens it. Resuming a session whose worktree was deleted re-creates it from its branch. If the branch is gone too, the row says to start a new session.

### What cleanup removes

Cleanup is Watchtower's own command, because an agent in auto mode is blocked from `git worktree remove` and `git branch -D`. It removes only what the session created, never a worktree or branch that holds work:

- A worktree is kept when it has uncommitted or untracked changes, is locked, is in use by a process or another session, or its HEAD is in neither the default branch nor any remote ref.
- A branch is kept when it is the default branch, is checked out anywhere, or has commits not pushed.

Each item is either ticked for removal or greyed out with the reason it is kept. Nothing is forced.

## Using it
<!-- learn
id: worktrees-clean-up
title: Free disk from old worktrees
text: Choose **Clean Up Old Worktrees…** in the **…** menu; anything that still holds work is kept.
area: development
level: next
kind: feature
since: 0.24.0
action: nav:projects
-->

- **Delete…** on a session row (just **Delete Session** when there is nothing to clean) asks "Checking what this session left…" first. **Delete and Clean Up** removes the session and the worktrees and branches that can go; **Delete Only** leaves them. The quick ✕ and ⌘⌫ never clean up.
- **Clean Up…** in the row menu, or **Clean Up Old Worktrees…** in the title row's **…** menu, opens the **Clean Up** screen. It covers the workspace and is not a dialog: you can leave it, and a cleanup keeps working. From a row it shows that session's worktrees and branches, with a "Session: …" chip; click the ✕ on the chip to see the whole repository. From the menu it lists every worktree and branch of the repository, with an owner hint.
- Nothing is ticked at first. Tick rows, **⇧-click** for a range, or choose **Select All That Can Go** (⌘A, except while the search box is focused); Esc clears the ticks. Narrow the list with search, **All / Worktrees / Branches**, an age (7, 30 or 90 days), an owner (a session, Subagent, Session deleted, Made by hand) and **Merged only**. A worktree's row includes its branch when that can go too.
- Rows appear while Watchtower is still checking and measuring a big repository. **Clean Up…** asks once, then removes in the background; rows leave the list as they are removed, and a bar reports "Freed ~X · removed …". Anything kept is folded away with its reason.
- Close the screen with the tab's ✕, or by picking a session. Switching to another workbench and back keeps it. One cleanup runs per workbench at a time.
- A banner "Old worktrees use ~N GB." appears when removable worktrees exceed 1 GB. It appears once, after the page has been open for 30 seconds, and never again for that workbench after you open the sweep. Its **Clean Up…** opens the Clean Up screen.
- When a session that Watchtower put in a worktree exits on its own, the same cleanup runs automatically for that worktree.

## When it's empty or wrong

- **Something is "kept".** Read the reason next to it: uncommitted changes, unpushed commits and a running process are the common ones. Fix that and run cleanup again.
- **"Cleanup failed, so … was kept".** The session stays so you can retry.
- **A deleted workbench says "Kept n worktree(s) with work in them".** Those worktrees had work and are left on disk.

## Related

- [Sessions](sessions.md): the place label and the session report's **Cleanup** line.
- [Code viewer](code-viewer.md): follows the session's worktree.

For developers: [docs/features/workbench.md](../../../features/workbench.md)
