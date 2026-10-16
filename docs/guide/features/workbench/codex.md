# Codex

A workbench session can run Codex instead of Claude Code. The board, asks, comments, session states, reports and resume work the same way. You use this page to choose which agent starts and to fix a Codex install.

## Why use it

You may prefer Codex for some tasks, or run both on one board. A session's agent is its own choice: the same workbench can hold a Claude Code session and a Codex session side by side.

## How it works

**Settings → System → Workbench → Default Agent** picks the agent for a plain new session, **Work on It** and a session started from the iPhone. The new-session menus list each agent and can start the other one. An agent that is not installed shows "(not installed)" and is disabled. Codex rows carry a **Codex** tag.

When Watchtower sets up a workbench and finds Codex, it also sets up the Codex part: the same skill in `.agents/skills`, and trust for Watchtower's hooks, asked from Codex itself.

Hook trust is a one-time setting for all folders. A workbench created before you installed Codex shows "Codex: not set up", and **Set up Codex** does it on demand. The notice is orange only after a setup failed.

Differences from Claude Code you may notice:

- Resume works only when Codex left a rollout file for the session. Without one, the session starts again.
- Session titles come from Codex's own history.
- Watchtower types answers and comments the way Codex expects: Return submits, Ctrl+J starts a new line.
- **Hand to Session** (⌥⌘↩ from a code question) works with either agent.

## Using it

1. Install Codex. Set **Default Agent** to Codex if you want it by default.
2. In a workbench that predates Codex, click **Set up Codex** in the header notice or the **…** menu. Use **Repair install** only if Codex hooks are not trusted.
3. Start a session with **+**, or **Work on It**, and pick Codex from the menu if it is not the default.

## When it's empty or wrong

- **"(not installed)" next to Codex.** Watchtower cannot find the `codex` command. **Settings → System → Workbench** shows a path field for it when Codex is the default.
- **"Codex: not set up".** Click **Set up Codex**.
- **A Codex session shows no state.** The hooks may not be trusted yet. Try **Repair install** (it is available only when something is broken), then start a new session.
- **Sessions only report from Watchtower's terminal.** A Codex run elsewhere has no board tools.

## Related

- [Sessions](sessions.md)
- [Workbench](README.md)

For developers: [docs/features/workbench.md](../../../features/workbench.md)
