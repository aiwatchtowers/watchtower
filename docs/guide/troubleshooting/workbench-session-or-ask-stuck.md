# A Workbench session or ask is stuck

You answered an ask and the agent did nothing, a session shows only a green dot, or it says **Working** while nothing happens.

## What you see

A highlighted line over the terminal after you answered an ask:

- "Answer saved — it goes to Claude once the permission prompt is resolved" (the agent's name varies), later "Still waiting for the permission prompt — Dismiss to send the answer through the session's brief instead".
- "Answer typed into the terminal — press Return to send".
- "Answer copied — paste it into the terminal and press Return".
- "Answer saved — it goes to the session's brief when it starts".
- "The agent withdrew this ask — your draft is kept".

Or on the session row: only a green dot with no caption, an orange install icon in the page header, or **Working** that never changes.

## Why

Watchtower saves your answer first, then types one line into that session's terminal. It will not type into a permission prompt or over text you have half-typed, and it cannot type into a session that is not running. The state captions come from the agent's own hooks, which exist only for sessions started in Watchtower's terminal and only when the folder install is complete.

## Fix

1. **Waiting for the permission prompt:** answer the prompt in the terminal; the line follows. Or press **Dismiss** on the line, and the agent reads the answer from the session's next brief.
2. **Typed, press Return:** the agent's input already held text, or Watchtower could not tell whether the agent was free to take the line. Click the terminal and press Return.
3. **Copied:** paste with ⌘V in the terminal and press Return.
4. **Session not running:** press **Resume** or **Restart**. The agent reads the answer when it starts.
5. **Green dot only, or an orange install icon:** open the **…** menu in the page header and choose **Repair install**; it only adds what is missing. **Re-run Setup** brings an older folder fully up to date.
6. **Working that never changes:** you may have interrupted the agent with Esc or Ctrl+C. That reports nothing, so send a prompt.
7. **"Claude Code was not found …" or "Codex was not found …":** see [The Claude or Codex tool is not found or not signed in](ai-tool-not-found-or-not-signed-in.md).
8. A Codex session with no state: **Repair install**, then start a new session.

## How to check

The caption changes (**Working**, **Waiting for you**) after the agent reads the answer, and the ask moves to **▸ N closed**.

## If it did not help

A session started in your own terminal app, or in a standalone terminal under **Terminals**, never reports a state and has no board tools; start it from the workbench instead. The ask drawer and the ask guard are on [Asks](../features/workbench/asks.md); states are on [Sessions](../features/workbench/sessions.md).
