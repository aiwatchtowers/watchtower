# Branches in the header

The branch button in a workbench page's header shows the folder's git branch and opens a menu to switch, create or fetch branches. This page is for anyone who changes branches without leaving Watchtower.

## Why use it

Switching branches swaps every file in the folder. Done blindly, it can bury your uncommitted edits or pull files out from under a working agent. The menu asks before either can happen, and never forces or discards anything.

## How it works

### What the button shows

The branch name, an orange dot for uncommitted changes, and `↑2`/`↓1` when the branch is ahead of or behind its upstream. On a detached HEAD it shows the short commit hash. When the page shows a session that works in its own worktree, the button is that worktree's. There is no button in a folder that is not a git repository, or on a Mac without git; Watchtower never asks you to install anything.

### How a switch keeps your work

A switch first saves what you typed in the code viewer. With uncommitted changes, a dialog offers **Stash and switch**: every change, new files included, goes into a stash entry named `watchtower: switching from <current> to <branch> [<tag>]`. With an agent running in Watchtower's terminal in the repository, the dialog warns its files will be swapped and asks before **Switch anyway**. Nothing is written before you confirm.

The stash is never popped or deleted. The popover names the entry and the command that brings it back, `git stash apply <sha>`. Apply by that id, never `git stash pop`: the stash list is shared by every worktree and session.

### How fetching works

Opening the menu fetches origin in the background when the last fetch attempt for that repository was over five minutes ago. The list shows at once and updates when the fetch is done, so `↓1` and **upstream gone** match what was pushed or deleted elsewhere. A fetch only updates origin's branches: your files, local branches and stash are never touched, and it never pulls.

Watchtower's fetch never asks you for a password or key passphrase, and never touches the Keychain. It uses network remotes only (https, ssh, git), not a folder path, and not a custom `core.sshCommand`. When origin needs a password or an unloaded key, or there is no network, a quiet **Couldn't fetch origin: …** note appears and the list keeps working on what is already there. The automatic fetch also leaves your ssh agent alone, so an agent that approves each use, such as a password manager's, never asks; only the ↻ button uses your agent.

## Using it

1. Click the branch button. Type part of a name in **Find branch** to filter.
2. Click a branch under **Local branches** to switch to it. A branch open in another worktree is greyed out.
3. Under **Remote only**, click a branch you have no local copy of to **Check out**. Watchtower creates a local branch that tracks origin's and switches to it, with the same questions as a switch.
4. **New branch from current…** starts a branch from the current commit and takes your uncommitted changes along.
5. The ↻ button next to **Fetched 2m ago** fetches right away.

## When it's empty or wrong

- **"Couldn't fetch origin: … the automatic fetch uses no ssh agent".** Your ssh key lives in your agent, or origin is reached through a jump host. Press ↻ to fetch with them.
- **"Couldn't fetch origin: … never asks for a key passphrase".** Origin's ssh wants a key that is not in your ssh agent, or a host key confirmation. Add the key with `ssh-add`, or connect once from a terminal to accept the host key.
- **"Couldn't fetch origin: … uses no credential helper".** Origin is https and needs a login, which Watchtower's fetch never asks for. Fetch from a terminal, or switch origin to an ssh URL.
- **"Couldn't fetch origin: … transport 'file' not allowed".** Origin is a folder path. Watchtower fetches network remotes only.
- **"No origin remote".** The repository has no `origin` remote. Watchtower checks again five minutes later, or when you press ↻.
- **"Save or discard the edits in <file> first".** A file open in the code viewer has edits that cannot be saved. Resolve them, then switch.
- **A switch is refused.** The branch is checked out in another worktree, or a merge, rebase or similar is in progress. Finish or abort it first.
- **The menu says it is unavailable.** The session's worktree is gone or outside the repository.
- A `claude` running in your own terminal app is not detected, so check it yourself before switching. There is no pull, push, delete or rename.

## Related

- [Worktrees and cleanup](worktrees-and-cleanup.md): a session's own worktree and branch.
- [Code viewer](code-viewer.md): the edits a switch saves first.

For developers: [docs/features/workbench.md](../../../features/workbench.md)
