# iPhone: what the agent is doing

While an agent works, the phone's workchat shows one line above the field: the step it runs now and for how long. It's for anyone who follows a session from the [iPhone workchat](iphone-workbench.md).

## Why use it

A long test run looks the same as a stuck agent when all you see is **Working**. The line tells you the agent has been on `go test ./internal/report` for 0:42, so you know whether to wait or step in.

## How it works

The Mac reads the session's transcript as soon as it changes and sends the line to the open chat; it lands a moment later. Nothing runs on the phone while the chat is closed, and the timer ticks only while the line is on screen.

The line shows a tool's one-line summary (a command, a file, a search pattern), never its output. Passwords, tokens and keys in it become **[secret]** before it leaves the Mac. An older Mac sends no line, and the chat looks as it did before.

## Using it

### Read the line
<!-- learn
id: iphone-workchat-live-line
title: See the agent's current step on iPhone
text: While a session works, the line above the phone's field shows its current step and timer; tap it for the turn's steps.
area: iphone
level: next
kind: feature
since: next
-->

- A symbol, the step's summary and its timer: the step running now.
- **Working…** with the turn's timer: the agent is thinking between tools.
- **Loading activity…**: you just opened the chat and the Mac has not answered yet.
- No line: no turn is running, or a permission prompt or an ask waits above the field.

### See the turn's steps

Tap the line to open this turn's steps above it: each tool's summary and its time, newest at the bottom, six rows tall, scrolling past that. The line then reads **This turn · N steps** with the turn's timer; tap it again to close. The list starts closed and closes by itself when the turn ends, you stop the agent, a prompt shows or a new conversation starts.

### See what each agent does

The agents button in the toolbar counts the subagents at work, **✓ N** once all finish and **?** while their state can't be read. In its sheet, each **Working** row shows the agent's current step and timer; **Done · N** lists the finished ones. A subagent's own chat shows its line too.

## When it's empty or wrong

- **Activity unavailable** with **Retry**, in red: the Mac could not read the session's activity. The dialog still updates; tap **Retry** to ask again at once.
- **Activity out of date · 40m ago** with **Retry**: your tower stopped sending. The red line under the title says when it last did, and no timer runs until it is back.
- No line while the state says **Working**: the Mac's Watchtower is older than the phone's. Update it on the Mac.

## Related

- [iPhone: the workchat](iphone-workbench.md)
- [Workchat](workbench/workchat.md), the same line on the Mac

For developers: [docs/features/session-chat-feed.md](../../features/session-chat-feed.md)
