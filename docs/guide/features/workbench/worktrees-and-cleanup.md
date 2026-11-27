# Worktrees and cleanup

Watchtower can give each agent session its own git worktree, so parallel agents never overwrite each other, and it can tidy up the worktrees and branches a finished session leaves behind. This page is for anyone running more than one agent in a repository.

## Why use it

Two agents in one folder edit the same files. A worktree is a second checkout on its own branch, so each session has its own copy.

The price is disk: a worktree with a warm build can take several GB. Cleanup removes both, safely.

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

The new-session and **Work on It** menus offer **In This Folder** and **In Its Own Worktree**. If git cannot make a worktree, the session starts in the folder and says why.

`.worktreeinclude` at the repository root lists ignored files, such as `.env`, to copy into new worktrees.

**Worktree Setup Command…** in the title row's **…** menu sets one shell command, such as a dependency install, that runs in each new worktree before the agent starts. A failure prints a line; the agent starts anyway. It does not run on resume.

**Show Worktree in Finder** opens a session's worktree. Resuming a session whose worktree was deleted re-creates it from its branch; with the branch gone too, or on a branch its agent never used there, the row says to start a new session.

### What the session line shows
<!-- learn
id: worktrees-session-line-branch
title: See a session's branch and lanes
text: The line under a session names the task's branch, such as **⎇ feature/login · 3 lanes**; hover for the folders.
area: development
level: next
kind: tip
since: 0.27.0
action: nav:projects
-->

The line under a session shows where its agent works: **main folder · main**, **⑂ name · branch** in a git worktree, or **worktree removed**.

A session on a task with a branch shows the branch the work merges into, such as **⎇ feature/login** (a task without one uses its group's). Different branches show as **⎇ 2 target branches**.

A helper the agent starts in its own worktree is a lane, counted at the end: **⎇ feature/login · 3 lanes**. Only lanes from the current run that still exist count.

### What cleanup removes

Cleanup is Watchtower's own command, since auto mode blocks an agent's `git worktree remove`. A session's own cleanup removes only what that session created, never work:

- A worktree is kept when it has uncommitted or untracked changes, holds ignored files that are not build caches, is locked (unless its branch is merged and untouched for 3 days), is in use by a process or another session, or its HEAD is in neither the default branch nor any remote ref.
- A branch is kept when it is the default branch, is checked out anywhere, or has commits not pushed.

Each item is ticked for removal or greyed out with its reason. Nothing is forced.

### What a delete cleans up

Every session delete cleans up once its **Undo** bar goes away: the worktrees and branches the session and its agents created that are merged or pushed are removed, with no question. The panel reads **Cleaning up 2 sessions…**, then a notice such as **Cleaned up “Fix login flow”: removed 3 worktrees and 12 branches (~2.1 GB).** shows for six seconds.

- Kept on purpose, and named in the notice: uncommitted changes, unsaved ignored files, unpushed commits, a locked worktree (unless merged and idle 3 days), a git operation in progress, and branches while git cannot tell the default branch ("default branch unknown"). The session still goes.
- If Claude Code's subagent records could not be read, the notice says **Could not read the subagent records of “T” — check the Clean Up screen.**
- Never touched and not mentioned: what the session did not create (the main folder, the default branch, an older worktree), a worktree an agent made in a folder of its own, or a branch made in the main folder. Remove those on the Clean Up screen.
- If something could not be removed (a process runs in a worktree, git refused, the cleanup failed), the session comes back in **▸ N finished** with an orange line such as **Not fully cleaned: 1 worktree — a process is running in it.** Click it for its report and **Cleanup** section. Hover it, or use its **⋯** menu in a narrow panel:
  - **Clean Up Again** runs the cleanup again; the row reads **Cleaning up…** and goes once nothing is left.
  - **Delete Anyway** deletes the session now. What was not removed stays on disk, and the Clean Up screen still lists it.
  - **Show in Clean Up** opens the Clean Up screen for this session.

### What a finished session cleans up on its own
<!-- learn
id: worktrees-auto-cleanup-sweep
title: Idle worktrees clean up by themselves
text: Merged or pushed worktrees under .claude/worktrees/ go when a session ends or after 3 idle days; idle builds go too.
area: development
level: next
kind: feature
since: 0.29.6
replaces: [worktrees-auto-cleanup]
changed: Idle worktrees outside any session now clean up too, locked merged ones included.
action: nav:projects
-->

Within an hour after a session finishes, the daemon removes its merged or pushed worktrees and branches; it stops no process. One that ends without **finish_session** counts as finished after 24 hours idle. It retries hourly for 14 days.

Every linked worktree under `.claude/worktrees/`, including one you made by hand, that no session uses and nothing has touched for 3 days is checked every hour and removed only when every cleanup check passes (a workbench folder, or a locked branch with no commits of its own, stays), at most 20 per repository an hour. A merged worktree that is locked goes too; it is unlocked just before it is removed and locked again if the removal fails. Half-removed ones are left to the Clean Up screen.

A kept worktree loses only its build folders (`.build`, `DerivedData` and the like). A locked worktree, or one the sweep above looks at, loses them only after 3 idle days; one kept only for work still loses them at its session's end, unless a process runs in it. A language server such as `gopls` or `clangd` does not keep a worktree; any other running process does.

## Using it
<!-- learn
id: worktrees-clean-up-screen
title: Free disk from old worktrees
text: Choose **Clean Up Old Worktrees…** in the **…** menu; the Clean Up screen keeps anything that holds work.
area: development
level: next
kind: feature
since: 0.26.0
replaces: [worktrees-clean-up]
changed: Clean Up is now a screen you can leave while it removes in the background.
action: nav:projects
-->
- Deleting a session (**Delete…**, the ✕ or ⌘⌫) cleans it up in the background once its **Undo** bar goes away. See [What a delete cleans up](#what-a-delete-cleans-up).
- **Clean Up…** in the row menu, or **Clean Up Old Worktrees…** in the title row's **…** menu, opens the **Clean Up** screen. It covers the workspace and is not a dialog: you can leave it, and a cleanup keeps working. From a row it shows that session's worktrees and branches, with a "Session: …" chip; click the ✕ on the chip to see the whole repository. From the menu it lists every worktree and branch of the repository, with an owner hint.
- Nothing is ticked at first. Tick rows, **⇧-click** for a range, or choose **Select All That Can Go** (⌘A, except in the search box); Esc clears the ticks. Narrow the list with search, **All / Worktrees / Branches**, an age, an owner and **Merged only**. A worktree's row includes its branch when that can go too.
- **Clean Up…** waits until every row is checked, asks once, then removes in the background: rows leave as they go, a bar reports "Freed ~X · removed …", and kept rows fold away with their reason.
- Close it with **Clean Up ✕** or by picking a session. One cleanup runs per workbench at a time.
- A banner "Old worktrees use ~N GB." appears once, after the workbench page has stayed open 30 seconds, when removable worktrees exceed 1 GB, and not while the Clean Up screen is open; its **Clean Up…** opens the Clean Up screen.
- A session Watchtower put in a worktree that exits on its own cleans up that worktree at once.

## When it's empty or wrong

- **Something is "kept".** Its reason is next to it, often uncommitted changes, unpushed commits or a running process. Fix that and run cleanup again.
- **A deleted session reads "Not fully cleaned: …".** Fix what it names, then **Clean Up Again**, or **Delete Anyway** to keep the files ([What a delete cleans up](#what-a-delete-cleans-up)).
- **A deleted workbench says "Kept n worktree(s) with work in them".** They had work and stay on disk.

## Related

- [Sessions](sessions.md): the place label and the session report's **Cleanup** line.
- [Code viewer](code-viewer.md): follows the session's worktree.

For developers: [docs/features/workbench.md](../../../features/workbench.md)
