# Workchat

Workchat shows a workbench session's dialog as a chat, with markdown rendered, and lets you drive the session from it. This page is for anyone who would rather read and answer an agent than watch its terminal.

## Why use it

A long agent turn scrolls past in the terminal as raw text. In Workchat you read the dialog as messages, write the next line, stop the agent or allow a command, all without the terminal.

## How it works

Workchat is a session's second mode. It shows the same session in the same place as its terminal, and the terminal keeps running while hidden. It is available for Claude Code and Codex sessions in a workbench.

Each session opens in the mode you last showed it in. A new session always opens in the terminal, because a fresh agent may stop at a trust or login prompt only the terminal shows.

Claude Code's own notices, such as a background task finishing or a message from another session, show as one grey line instead of as your messages. Click one for the details.

## Using it

### Switch between Terminal and Workchat

- **Terminal | Workchat** in the page header swaps the session on screen between the two. The ▾ beside it picks the session or starts a new one.
- ⌃` does the same, as does View → **Show Terminal** / **Show Workchat**.
- With the split on, both show side by side: the terminal on the left, the Workchat on the right.
- A small glyph on each session row shows the mode it opens in. Right-click a row for **Open in Terminal** or **Open in Workchat**.

### Write to the agent

- Return in the field at the bottom sends your line. Shift-Return adds a line break in the field; the message is sent as one line.
- A line starting with `/` is typed as written, so `/clear` works.
- While the agent works, your line waits as **Queued · sends when the agent stops**. **Cancel** drops it; quitting drops it too.
- **Stop** (■), or Esc in the empty field, interrupts the agent.

### Answer a permission prompt

When the agent asks for a permission, a card shows what it wants to do, with **Allow**, **Deny** and **Show in Terminal**. Codex sessions get no card: answer them in the terminal.

### Read a subagent

A subagent's card opens it in the same pane, with **‹ Back** and a path bar that starts at **Workchat**. Subagents are read-only: write to the agent in the main Workchat.

## When it's empty or wrong

- **⌃` does nothing.** No session is on screen: pick one in the sessions panel first.
- **Stop does nothing.** A permission prompt is open, and Esc would answer it. Use the card or the terminal.
- **No permission card, but the session says Needs approval.** Only prompts the agent's hooks report get a card. Answer in the terminal.
- **The session opened in the terminal.** It is new, or you last showed it there.

## Related

- [Sessions](sessions.md), [Asks](asks.md)

For developers: [docs/features/session-chat-feed.md](../../../features/session-chat-feed.md)
