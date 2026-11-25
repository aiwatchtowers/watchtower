# Workchat

Workchat shows a workbench session's dialog as a chat, with markdown rendered, and lets you drive the session from it. It's for anyone who would rather read an agent than watch its terminal.

## Why use it

In the terminal a long agent turn scrolls past as raw text. In Workchat you read it as messages, and write, stop the agent or allow a command without the terminal.

## How it works
<!-- learn
id: workchat-chat-mode
title: Read a session as a chat
text: Switch a session to **Workchat** to read its dialog as messages and write, stop or allow from there.
area: development
level: next
kind: feature
since: 0.24.0
action: nav:projects
-->
<!-- learn
id: workchat-agent-finished
title: See how a helper agent finished
text: In Workchat, click a finished agent's line for its result, **Open output** and **Details**.
area: development
level: power
kind: feature
since: 0.29.4
action: nav:projects
-->

Workchat is a session's second mode, in the same place as its terminal, which keeps running while hidden. It is available for Claude Code and Codex sessions in a workbench.

Each session opens in the mode you last showed it in. A new session always opens in the terminal, since a fresh agent may stop at a trust or login prompt only the terminal shows.

Claude Code's own notices show as quiet lines. When a helper agent or a background command finishes, its line shows a green ✓ (worked), a red ✕ (failed) or a grey mark (stopped or unknown), the agent's name and how it went, such as `finished · 9 tools · 43.5k tokens · 1m 29s`. Click it for the result, **Open output** and **Details** (the task's ids). A message from another session is one grey line; click it for details.

Once the session ends, the field gives way to **Session finished. The history stays readable.** Finished subagents still open from the agents button.

## Using it

### Switch between Terminal and Workchat
<!-- learn
id: workchat-toggle
title: Flip Terminal and Workchat with ⌃`
text: Press ⌃` to swap the session on screen between its terminal and its Workchat.
area: development
level: next
kind: shortcut
since: 0.24.0
action: hotkey:workchat
-->

- The toggle button on the session's strip, named for the mode it switches to (**Terminal** or **Workchat**), swaps the session in that pane between the two. It is greyed out when that mode already shows in the other pane. The session name with ▾ at the strip's left picks another session or starts a new one.
- ⌃` does the same, as does View → **Show Terminal** / **Show Workchat**.
- With the split on, the terminal shows on the left and the Workchat on the right.
- A small glyph on each session row shows the mode it opens in. Right-click a row for **Open in Terminal** or **Open in Workchat**.

### Write to the agent
<!-- learn
id: workchat-send-while-busy
title: Send while the agent works
text: Write in Workchat while the agent is busy; your line queues and the agent reads it at its next step.
area: development
level: power
kind: tip
since: 0.24.0
action: nav:projects
-->

- Return in the field sends your line. Shift-Return adds a line break; the message keeps its line breaks.
- A line starting with `/` is typed as written, so `/clear` works.
- You can send while the agent works. With Claude Code the line shows **Queued · the agent reads it at its next step** until the agent picks it up. If it has to wait a moment, it reads **Queued · sends in a moment**, and **Cancel** drops it; quitting drops it too. While a Codex session works, the field says **Codex takes your message when this turn ends.** and your line reads **Queued · sends when the agent stops**.
- The small line above the field shows the current tool, or **Last · …** for the last finished one while the agent keeps working; otherwise **Working…**.
- Paste a screenshot with ⌘V and **[Image #1]** goes into the text at the cursor; a long text paste goes in as **[Pasted text #2 +42 lines]**. Each shows as a tinted pill, and one Backspace removes it whole; the same text typed by hand stays plain. On send, the text goes in full and the image as its file's path. Your message shows a thumbnail; click it to open. If the file is gone by then, **Pasted image #N is gone — paste it again** shows and your draft stays.
- A pasted PDF, files pasted from Finder, dropped files and the paperclip's picks show as chips above the field (✕ removes one). The paperclip opens a menu: **Paste screenshot** (named by what the clipboard holds, such as **Paste 2 files** or **Paste text**; a greyed-out **Paste from clipboard** when nothing fits) and **Attach files…**. Pasted files are kept in Watchtower's folder until the session stops. If a paste can't be saved, or a file's path has a line break, the reason shows under the field.
- The round button is **Stop** (■) only with an empty field while the agent works; it, or Esc in the empty field, interrupts the agent. If it can't, the reason shows above the field.
- A line typed into the terminal but not sent says so, with **Show in Terminal**: press Return there.

### Answer a permission prompt
<!-- learn
id: workchat-permission-card
title: Allow a command from Workchat
text: When the agent asks for a permission, press **Allow** or **Deny** on the card instead of the terminal.
area: development
level: next
kind: tip
since: 0.24.0
action: nav:projects
-->

When the agent asks for a permission, a card such as **Claude wants to run a command** shows the request, with **Allow**, **Deny** and **Show in Terminal**. Your answer counts for this one call. Codex sessions get no card: answer them in the terminal.

A shortened request, or an edit of Watchtower or shell settings, gets **Deny** only, with a note. To allow it, click **Show in Terminal** and answer there, where the whole request shows. **Show in Terminal** also makes the terminal the mode the session opens in.

### Answer the agent's asks

Each open ask of the session shows at the end of the chat as a card with its number and title. **Open Ask** opens it in the ask drawer to answer.

### Open what the agent names
<!-- learn
id: workchat-agent-text-links
title: Click a target, path or hash in Workchat
text: In Workchat, click a coloured **#42** to see it on the Board, a path to open the file, a hash to copy it.
area: development
level: next
kind: tip
since: 0.29.4
action: nav:projects
-->

In the agent's text, a target number (`#42`), a commit hash, a file path and a command in code (`git …`, `make …`, `./scripts/…`) are coloured. Click `#42` to show it on the Board, a path to open the file in **Files**, a hash or command to copy it. A path is coloured only when it is a file in the session's folder.

### Read messages between agents
<!-- learn
id: workchat-peer-bubbles
title: Follow agents talking to each other
text: In Workchat, messages between a session and its sub-sessions show as bubbles with the other session's name and folder.
area: development
level: power
kind: feature
since: 0.29.0
action: nav:projects
-->

When agents of a workbench talk to each other ([sub-sessions](folders.md#sub-sessions-in-other-folders)), Workchat shows their messages as bubbles, not as your lines:

- **↘ From “<title>” · <folder>**: a message another session sent here.
- **✓ Sub-session “<title>” finished · <folder>**: a sub-session's finish summary.
- **↗ Sub-session “<title>” started · <folder> · ⑂ <worktree>** and **↗ To “<title>” · <folder>**: what this session started or sent. A refused one reads **not started: …** or **not sent: …**.
- **⏸ Message to “<title>” is waiting**: the other session can't take it yet; the line under it says why, and **Open** shows that session.

### See agents and the turn's steps
<!-- learn
id: workchat-agents-list
title: See working and finished agents
text: Click the agents button above the field to see who works now and open any finished agent’s report.
area: development
level: power
kind: feature
since: 0.29.0
action: nav:projects
replaces: [workchat-live-agents]
changed: Agents left the conversation; finished ones sit under Done in the list.
-->

Subagents never show in the conversation. The agents button above the field (two people and a count) opens the list: **WORKING** rows show the type, task, latest action and timer, and **Done · N** lists every finished subagent, newest first. Click a row to read that agent's chat in the same pane, with **‹ Back** and a path bar that starts at **Workchat**; subagents are read-only.

The button shows the working count, a dimmed **✓ N** when only finished agents remain, and **?** when the agent state is unavailable, which is not the same as none running. Done is collapsed while agents work and opens by itself when none do; your own choice wins until you quit.

While the agent works, the line reads **This turn · N steps** with the step that runs now and its time. Click the line, or press ⌥↓ in the field, to show the newest six steps above it (older ones as "N earlier steps"); the list starts closed, and Workchat remembers your choice for that pane. The list goes away when the turn ends or a permission card shows.

## When it's empty or wrong

- **Activity unavailable** or **Activity out of date · …**. The live hint could not refresh, or is more than ten seconds old. Timers stop and the agent count becomes unknown; click **Retry**.
- **⌃` does nothing.** No session is on screen, or both its modes show side by side in the split. Pick a session in the sessions panel, or turn the split off.
- **Stop says A permission prompt is open — answer it on the card or in the terminal.** Esc would answer the prompt, so Stop holds back. Use the card or the terminal.
- **Could not read the permission prompt.** Watchtower could not read its database, so no card shows. Answer in the terminal; the next session update tries again.
- **No permission card, but the session says Needs approval.** Only prompts the agent's hooks report get a card. Answer in the terminal.
- **Your line says Waiting: the terminal prompt holds text.** Unsent text in the terminal shows under the caption. Send or erase it and the line goes; **Send together** puts it beside that text; your next Return there sends both.
- **⌘V of files copied in Finder adds nothing.** Drag the files onto the field, or use the paperclip.

## Related

- [Sessions](sessions.md), [Asks](asks.md)

For developers: [docs/features/session-chat-feed.md](../../../features/session-chat-feed.md)
