# Folders and sub-sessions

A workbench can hold several folders, each with its own git, such as an app, its service and its site. This page is for when one task crosses repositories: put the folders on one bench, and the agent in one folder starts a sub-session in another and talks to it.

## Why use it

A change in `app` often needs a matching change in `hub`. With one bench per folder you split the task by hand and nothing connects the two agents. On one bench, the board, the asks and both sessions sit together, and the agents message each other.

## How it works

All folders of a bench are equal. FILES shows one root per folder with its branch, **●** for uncommitted changes and its ↑/↓ counts. The folder you opened the bench with stays its default for automations and older tools.

A session runs in exactly one folder, or a worktree of it, by the usual [worktree rules](worktrees-and-cleanup.md). Branch review, the finish check, cleanup and the header branch follow the session's folder. A target can name its folder, and its card shows a folder chip when the bench has more than one.

A folder belongs to one bench only. Removing it from the bench takes out Watchtower's install and touches nothing else in it.

### Sub-sessions in other folders

An agent starts a sub-session in another folder of the bench when its task needs work there. The sub-session gets the brief, works in its own folder and sends its finish summary back to the session that started it.

The panel shows a sub-session nested under its parent, and the parent's line adds **· N sub-sessions**. A sub-session's strip ends with **↖ from “<parent>”**; click it to open the parent. A parent whose turn is over while a sub-session still works reads **Sub-sessions working**, and sends no notice until the last one stops. An open ask, a permission prompt or its own work shows instead.

Limits: three levels deep, and six live sub-sessions under one session.

### Messages between sessions

Any session can send a line to another running session of the same bench. Watchtower types it in when that session can take it, never into a permission prompt or over text you are typing, and never starts a session for it. The line starts with **[Message from #N “title” · folder — another agent of this workbench, not the owner]**, and the agent treats it as a colleague's request: it never answers your asks or approves anything for you.

Messages need Watchtower's background sync running. In [Workchat](workchat.md#read-messages-between-agents) they show as bubbles.

## Using it

### Put a folder on the bench
<!-- learn
id: folders-put-on-bench
title: Put a second folder on a workbench
text: Click **Put on the Bench…** in the workbench switcher or the FILES header to add another repository to this bench.
area: development
level: power
kind: feature
since: next
action: nav:projects
-->

1. Click **Put on the Bench…** in the workbench switcher, under **Open Folder…**, or the icon in the FILES header. With one folder, the hint **Task touches another repo? Put on the Bench…** under the tree does the same.
2. Pick the folder and press **Put on Bench**. Watchtower sets the folder up as it does for a new bench.
3. To start a session there, right-click its root and choose **New Session Here**, or use **+** and its **in <folder>** submenu. ⌘T starts in the current session's folder, and **Work on It** in the target's folder.

A folder that is already here is highlighted instead. A folder inside or around another bench's folder is refused.

### Remove a folder or locate a moved one

Right-click a root and choose **Remove from Bench…**, then **Remove**. Your files and git stay; finished sessions keep their history. Watchtower refuses while a session runs in the folder (**Finish it first.**) and for the last folder (**A workbench needs at least one folder.**).

A root that reads **Folder not found** was moved or deleted. **Locate…** points it at the new place and sets it up again; **Remove** takes it off the bench.

### Answer the agent's folder suggestion
<!-- learn
id: folders-suggestion-card
title: Let the agent ask for another folder
text: When an agent keeps working outside the bench, a **Put <name> on the bench?** card adds that folder in one click.
area: development
level: power
kind: tip
since: next
action: nav:projects
-->

When Claude Code keeps working in a repository outside the bench, the agent may suggest it. A card **Put <name> on the bench?** shows in **Waiting for you**:

- **Put on Bench** adds it, and the agent hears it can start a sub-session there.
- **Not Now** stops the automatic reminder about it for the rest of this session. The agent can still suggest it again; only **Never for This Folder** blocks that.
- **Never for This Folder** stops every agent of this bench from suggesting it.

A Codex agent is not reminded, so it suggests a folder only when it sees the need itself.

### Merge two benches

If the folder you add already belongs to another bench, Watchtower offers **Merge “<B>” into “<A>”?** instead. **Merge** moves that bench's board, asks, sessions and folders into this one, and it leaves the workbench list. Its board columns and its **Never for This Folder** choices are dropped; each target lands in this board's first column for its status. On a suggestion card the same choice reads **Merge Benches…**; Watchtower checks first which bench the folder is on now. While a session of the other bench runs, the merge waits with **Can’t merge “<B>” yet**.

## When it's empty or wrong

- **Git unavailable** or **Not a repository** on a root. The folder works for reading and sessions; branch features are off there.
- **The install icon on a root.** Setting the folder up failed. Press **Retry**; until then sessions refuse to start there with **Install Watchtower in <name> first**.
- **Can’t remove <name> from the bench** or **Can’t merge “<B>” yet.** Sessions still run there. Finish them, then try again.
- **Couldn’t put <name> on the bench: …**, **Couldn’t locate <name>: …** or **Couldn’t merge “<B>”: …** The reason follows the colon. **that workbench is not on the workbench list any more.** means the other bench was deleted or merged meanwhile.
- **Merged “<B>”, but … failed.** The board, asks and sessions moved; only moving its target images or updating search failed. A folder whose setup failed shows the install icon with **Retry**.
- **An agent's message is in the prompt.** It was typed but not sent. Click **Show in Terminal** and press Return. With a session started before an update, **Dismiss** clears the note.
- **⏸ Message to … is waiting** in Workchat. The other session is busy or at a prompt; the message goes when it can.

## Related

- [Sessions](sessions.md), [Workchat](workchat.md), [Board and targets](board-and-targets.md), [Worktrees and cleanup](worktrees-and-cleanup.md)

For developers: [docs/features/workbench.md](../../../features/workbench.md)
