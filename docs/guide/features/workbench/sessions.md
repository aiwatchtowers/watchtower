# Sessions

A session is one Claude Code or Codex conversation running in an embedded terminal in the workbench folder. You use this page to read a session's state at a glance, and to start, resume and clear sessions.

## Why use it

With several sessions running, the terminals tell you nothing until you open each one. Watchtower reads each session's state from the agent's own hooks, so the panel shows which session works, which needs a permission and which is waiting for you.

## How it works

A session runs the agent exactly as your own terminal does: the same login, permissions and project memory. Click a workbench in the left panel to see its sessions; a filled dot means running. Sessions keep running while you switch sessions, workbenches or tabs.

Copying from inside the terminal works as in your own terminal: when Claude Code, vim or tmux copies text, it lands on your clipboard. The terminal no longer answers clipboard-read requests hidden in program output, so a file or tool output shown there cannot pull in what you copied. Programs you run can still read the clipboard their own way (for example `pbpaste`), as in any terminal. Paste with ⌘V as usual.

Updating Watchtower never stops your sessions, and quitting asks you. See [Updates and quitting](updates-and-quitting.md).

### Session states

A caption under the session name says what the agent is doing. When several apply, the first row wins.

| State | Colour | Meaning |
|---|---|---|
| **Needs approval** | orange | The agent asks for a permission. It returns to working once you allow it. |
| **Error: …** | red | The turn stopped on an error. The caption names it, for example "Error: rate limit". |
| **Working** | green | The agent works on your prompt. |
| **Agents working** (or **N agents working**) | green, pulsing | The agent finished its turn but helper agents or teammates it started are still busy. |
| **Ready to check · ask #N** | purple | Its open asks are only checks or reviews for you (**Ready for review** when all are reviews). |
| **Finished** | blue | The agent said it is done. Orange while an ask is still open. |
| **Waiting for you · ask #N** | orange | A question of the agent waits for your answer. |
| **Stopped** | grey | The agent finished its turn. |
| **Running** / **Not running** | green / grey | No state reported yet, or not started. |

A ring instead of a filled dot means the session is not running. A blue ring is finished, orange still has a question, purple still has checks or reviews for you. A state from before an exit, a Restart or a Watchtower restart is never shown.

Two limits matter. Pressing Esc or Ctrl+C to interrupt the agent reports nothing, so the session keeps saying "Working" until your next prompt. And only sessions started in a workbench's terminal in Watchtower report a state.

When no helper has reported for 30 minutes, Watchtower asks Claude Code whether the session is still at work, then every 30 minutes. It shows **Stopped** once the answer is no, or after the check fails twice in a row.

### Where the agent works

A line under the caption shows the agent's place: **main folder · main**, or **⑂ name · branch** when it moved into a git worktree, or **worktree removed** when that worktree is gone. Until Watchtower knows where a session works, it shows the main folder.

### Sessions an automation opens

A workbench automation can start an agent session to do part of its work, such as a review round. It appears in SESSIONS like any other, titled "⚙ <name> · run #N", and starts in the background so it does not take the page from you. You can watch it, type into it, stop it or resume it.

The run waits until the session finishes. If you stop it or its process ends, the run carries on knowing the session stopped. If Watchtower was not open when the automation asked, the session starts the next time it is.

## Using it

### Start, resume and restart

- **+** in the sessions panel starts a session of the default agent. Hold it to pick the agent. ⌘T does the same on a workbench page.
- **Work on It** on a board card starts a session for that target. See [Board and targets](board-and-targets.md).
- **Resume** continues a stopped session where it left off. **Restart** appears when one exits and **Start fresh** when it cannot be resumed.
- **Settings → System → Workbench → Default Agent** picks the agent for new sessions. Codex differs in a few ways; see [Codex](codex.md).

### Find a session

- ⌘1…⌘9 open the first nine sessions of the list.
- **Go to…** (⌘K on the Workbench tab) searches names across every workbench and its sessions. Type `#` and a target number to find the session on that target.
- The workbench name at the top of the panel is a switcher with **Find workbench**. Each row shows the new agent comments on open targets, the blocked targets and how many sessions are working now; with none working, how long ago a session was last active. ⌘[ goes back to the workbench list.
- ⌥⌘S hides and shows the sessions panel.

### Tidy up the list

- A session that is finished with no open ask moves into **▸ N finished** at the bottom, most recent first. The group remembers whether it is open. A session you are looking at never jumps.
- Drag a session to reorder it. Right-click for **Rename…** and **Delete…**.
- Hover a session that is finished, stopped, failed or not running to get a **✕**. One click deletes it without a dialog. Any other session (working, agents working, ready to check, waiting, asking for a permission, or running with no state yet) needs **Delete…**.
- After a delete, **Undo** in the bar brings it back with its report, target links and asks. It stays for about five seconds.
- If you quit before the bar goes away, the delete still happens. When the database is busy this can hold the quit for a few seconds, with a small "Finishing session deletes…" window.
- When you delete a workbench session the dialog first checks what it left behind and may offer **Delete and Clean Up**. See [Worktrees and cleanup](worktrees-and-cleanup.md).

### Read a session's report and analytics

The progress line under the caption, the **Session** view and the **Analytics** view have their own page: [Session report and analytics](session-report.md).

### Get notified

While Watchtower is in the background, a running session that stops, needs approval, hits an error or finishes sends one notice. A session waiting on an ask sends none of its own, because the ask already did. **Agents working** sends nothing. **Settings → Features → Notifications → Workbench notifications** turns this on and off; it is on by default.

## When it's empty or wrong

- **Only a green dot.** The workbench needs **Repair install** or **Re-run Setup**; see [Workbench](README.md).
- **"state hooks missing" on the install icon.** The same fix. Without them the agent count drops only at the agent's next turn.
- **"Pick a session" in the Session view.** No Claude Code session is selected, or it is a plain shell, or it was deleted.
- **A session says Working but nothing happens.** You may have interrupted it with Esc; send a prompt.

Session not reporting a state? See [A Workbench session or ask is stuck](../../troubleshooting/workbench-session-or-ask-stuck.md).

## Related

- [Asks](asks.md), [Board and targets](board-and-targets.md)
- [Session report and analytics](session-report.md), [Updates and quitting](updates-and-quitting.md)

For developers: [docs/features/workbench.md](../../../features/workbench.md)
