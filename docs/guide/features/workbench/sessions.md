# Sessions

A session is one Claude Code or Codex conversation running in an embedded terminal in the workbench folder. You use this page to read a session's state at a glance, and to start, resume and clear sessions.

## Why use it

With several sessions running, the terminals say nothing until you open each one. Watchtower reads each session's state from the agent's own hooks, so the panel shows which session works, which needs a permission and which is waiting for you.

## How it works

A session runs the agent exactly as your own terminal does: the same login, permissions and project memory. Click a workbench in the left panel to see its sessions; a filled dot means running. Sessions keep running while you switch sessions, workbenches or tabs.

Copying from inside the terminal works as in your own terminal: when Claude Code, vim or tmux copies text, it lands on your clipboard. The terminal does not answer clipboard-read requests hidden in program output, so a file or tool output cannot pull in what you copied. Programs you run can still read it (for example `pbpaste`). Paste with ⌘V.

Updating Watchtower never stops your sessions, and quitting asks you. See [Updates and quitting](updates-and-quitting.md).

### Session states
<!-- learn
id: sessions-states-idle
title: Read a session's state at a glance
text: The caption says whether a session works, runs a background task, waits for you, has finished or is **Idle**.
area: development
level: basics
kind: tip
since: next
action: nav:projects
replaces: [sessions-states]
changed: A background command keeps a session working, and a turn that ended reads **Idle** instead of Stopped.
-->

A caption under the session name says what the agent is doing. When several apply, the first row wins.

| State | Colour | Meaning |
|---|---|---|
| **Needs approval** | orange | The agent asks for a permission. It returns to working once you allow it. |
| **Error: …** | red | The turn stopped on an error. The caption names it, for example "Error: rate limit". |
| **Working** | green | The agent works on your prompt. |
| **Agents working** (or **N agents working**) | green, pulsing | Its turn is over but helpers it started (or their own helpers) still work; wins over a background task. |
| **Background task running** (or **N …**) | green, pulsing | The turn is over but a background command runs, such as a CI wait; then the agent resumes. Up to 2 hours. |
| **Ready to check · ask #N** | purple | Its open asks are only checks or reviews for you (**Ready for review** when all are reviews). |
| **Finished** | blue | The agent said it is done. Orange while an ask is still open, such as the one that tells you what it left of its target and why. |
| **Waiting for you · ask #N** | orange | A question of the agent waits for your answer. |
| **Idle** | grey | The turn is over; the agent waits for you. |
| **Running** / **Not running** | green / grey | No state reported yet, or not started. |

A ring instead of a filled dot means the session is not running. A blue ring is finished, orange still has a question, purple still has checks or reviews for you. A state from before an exit, a Restart or a Watchtower restart is never shown.

Two limits: interrupting the agent with Esc or Ctrl+C reports nothing, so it keeps saying "Working" until your next prompt; and only sessions started in a workbench's terminal in Watchtower report a state.

After 30 minutes without news from a helper, Watchtower asks Claude Code whether the session still works, then every 30 minutes, and shows **Idle** on a no or after two failed checks.

### Where the agent works

A line under the caption shows where the agent works, such as **main folder · main** or **⑂ name · branch**. On a task with a branch it shows that branch: **⎇ feature/login** ([details](worktrees-and-cleanup.md#what-the-session-line-shows)).

### Sessions an automation opens

A workbench automation can start an agent session, such as for a review round. It shows in SESSIONS titled "⚙ <name> · run #N" and starts in the background, without taking the page from you. You can watch it, type into it, stop it or resume it.

The run waits until the session finishes. If you stop it or it exits, the run goes on, knowing it stopped. If Watchtower was not open when the automation asked, the session starts the next time it is.

## Using it

### Start, resume and restart
<!-- learn
id: sessions-new-session
title: Start a session with ⌘T
text: Press ⌘T on a workbench page, or **+** in the sessions panel, to start the default agent in the folder.
area: development
level: basics
kind: shortcut
since: 0.24.0
action: hotkey:new-session
-->
<!-- learn
id: sessions-resume
title: Resume a stopped session
text: Press **Resume** on a stopped session to continue the conversation where it left off.
area: development
level: next
kind: feature
since: 0.24.0
action: nav:projects
-->

- **+** in the sessions panel starts a session of the default agent (hold it to pick one; ⌘T on a workbench page). It is on screen at once and reads **Starting…** while it is set up (and its [worktree](worktrees-and-cleanup.md) made, when it gets one).
- **Work on It** on a board card starts a session for that target. See [Board and targets](board-and-targets.md).
- **Resume** continues a stopped session where it left off. **Restart** appears when one exits and **Start fresh** when it cannot be resumed.
- **Settings → System → Workbench → Default Agent** picks the agent for new sessions. Codex differs in a few ways; see [Codex](codex.md).

### Find a session
<!-- learn
id: sessions-go-to
title: Jump to any session with ⌘K
text: Press ⌘K on the Workbench tab and type a session name, or `#` and a target number.
area: development
level: next
kind: shortcut
since: 0.24.0
action: hotkey:go-to
-->

- ⌘1…⌘9 open the first nine sessions of the list.
- **Go to…** (⌘K on the Workbench tab) searches names across every workbench and its sessions. Type `#` and a target number to find the session on that target.
- The workbench name at the top of the panel is a switcher with **Find workbench**. Each row shows the new agent comments on open targets, the blocked targets and how many sessions are working now; with none working, how long ago a session was last active. ⌘[ goes back to the workbench list.
- ⌥⌘S hides and shows the sessions panel.

### Tidy up the list
<!-- learn
id: sessions-quick-delete
title: Clear finished sessions in one click
text: Hover a finished or idle session and click **✕**; **Undo** in the bar brings it back.
area: development
level: next
kind: tip
since: 0.24.0
action: nav:projects
-->

- A session that is finished with no open ask moves into **▸ N finished** at the bottom, most recent first. The group remembers whether it is open. A session you are looking at never jumps.
- Drag a session to reorder it. Right-click for **Rename…** and **Delete…**.
- Right-click an agent session, then **Session Target**, to pick the target its progress counts; **None — Count What It Touched** resets it.
- Hover a **Ready to check** session for **Review Branch**, which opens its [Branch review](diff-review.md); the right-click menu has it for every session.
- Hover a session that is finished, idle, failed or not running to get a **✕**. One click deletes it without a dialog. Any other session needs **Delete…**.
- After a delete, **Undo** in the bar brings it back with its report, target links and asks for about five seconds. Then its merged or pushed worktrees and branches go in the background; one left **Not fully cleaned** stays listed ([details](worktrees-and-cleanup.md#what-a-delete-cleans-up)).
- Quitting before the bar goes away deletes at the next launch; a busy database can hold the quit a few seconds ("Finishing session deletes…").

### Read a session's report and analytics

The progress line under the caption, the **Report** view and the **Analytics** view have their own page: [Session report and analytics](session-report.md).

### Drive a session from its Workchat

Workchat is a session's second mode: its dialog as a chat that you can write to, in the same place as its terminal. The toggle on the session's strip or ⌃` switches between them, and each session opens in the mode you last used. See [Workchat](workchat.md).

### Get notified

While Watchtower is in the background, a running session that turns idle, needs approval, hits an error or finishes sends one notice, background command or not; asks and busy helpers send none. **Settings → Features → Notifications → Workbench notifications** turns this on and off; it is on by default.

## When it's empty or wrong

- **Only a green dot.** The workbench needs **Repair install** or **Re-run Setup**; see [Workbench](README.md).
- **"state hooks missing" on the install icon.** The same fix. Without them the agent count drops only at the agent's next turn.
- **"Pick a session" in the Report view.** No Claude Code session is selected, or it is a plain shell, or it was deleted.
- **A session says Working but nothing happens.** You may have interrupted it with Esc; send a prompt.

Session not reporting a state? See [A Workbench session or ask is stuck](../../troubleshooting/workbench-session-or-ask-stuck.md).

## Related

- [Asks](asks.md), [Board and targets](board-and-targets.md)
- [Workchat](workchat.md), [Session report and analytics](session-report.md), [Updates and quitting](updates-and-quitting.md)

For developers: [docs/features/workbench.md](../../../features/workbench.md)
