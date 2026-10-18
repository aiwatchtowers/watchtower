# Worktrees and cleanup

Watchtower can give each agent session its own git worktree, so parallel agents never overwrite each other, and it can tidy up the worktrees and branches a finished session leaves behind. This page is for anyone running more than one agent in a repository.

## Why use it

Two agents in one folder edit the same files. A worktree is a second checkout of the same repository on its own branch, so each session has its own copy.

The price is disk: one worktree with a warm build can take several GB, and each leaves a branch behind. Cleanup removes both, safely.

## How it works

### Where a new session starts

A plain new session, or **Work on It** on a card, starts in the folder. If a live agent already works in the folder, it starts in a new worktree instead. A worktree is a branch named `wt/<name>`, created under `.claude/worktrees/` in the repository from the folder's current commit. Uncommitted changes of the folder are not carried over.

Two overrides sit in the new-session menus and the card's **Work on It** menu: **In This Folder** and **In Its Own Worktree**. If git cannot make a worktree (no repository, no commits yet), the session starts in the folder and says why in **Started in the folder: …**.

A file named `.worktreeinclude` at the repository root lists ignored files, such as `.env`, to copy into each new worktree. Only files that match it and that git ignores are copied, as cheap copy-on-write clones.

Under **…** in the page header, **Worktree Setup Command…** sets one shell command that runs in each new worktree before the agent starts, for example a dependency install. A failure prints a line and the agent starts anyway. It does not run on resume.

A session row shows where the agent works, and **Show Worktree in Finder** opens it. Resuming a session whose worktree was deleted re-creates it from its branch. If the branch is gone too, the row says to start a new session.

### What cleanup removes

Cleanup is Watchtower's own command, because an agent in auto mode is blocked from `git worktree remove` and `git branch -D`. It removes only what the session created, never a worktree or branch that holds work:

- A worktree is kept when it has uncommitted or untracked changes, is locked, is in use by a process or another session, or its HEAD is in neither the default branch nor any remote ref.
- A branch is kept when it is the default branch, is checked out anywhere, or has commits not pushed.

Each item is either ticked for removal or greyed out with the reason it is kept. Nothing is forced.

## Using it

- **Delete…** on a session row (just **Delete Session** when there is nothing to clean) asks "Checking what this session left…" first. **Delete and Clean Up** removes the session and the worktrees and branches that can go; **Delete Only** leaves them. The quick ✕ and ⌘⌫ never clean up.
- **Clean Up…** in the row menu cleans up without deleting the session. Untick anything you want to keep.
- **Clean Up Old Worktrees…** under **…** in the page header lists every worktree and branch of the repository, with an owner hint. Nothing is ticked at first. Working out the sizes of a big repository can take a while; you can close the sheet and keep working, and reopening it picks up where it got to.
- A banner "Old worktrees use ~N GB." appears when removable worktrees exceed 1 GB. It appears once, after the page has been open for 30 seconds, and never again for that workbench after you open the sweep. Its **Clean Up…** opens the list it already worked out, without checking again.
- When a session that Watchtower put in a worktree exits on its own, the same cleanup runs automatically for that worktree.

## When it's empty or wrong

- **Something is "kept".** Read the reason next to it: uncommitted changes, unpushed commits and a running process are the common ones. Fix that and run cleanup again.
- **"Cleanup failed, so … was kept".** The session stays so you can retry.
- **A deleted workbench says "Kept n worktree(s) with work in them".** Those worktrees had work and are left on disk.

## Related

- [Sessions](sessions.md): the place label and the session report's **Cleanup** line.
- [Code viewer](code-viewer.md): follows the session's worktree.

For developers: [docs/features/workbench.md](../../../features/workbench.md)
