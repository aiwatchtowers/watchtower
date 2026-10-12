# Codex as a Workbench agent (board #399): business spec

**For:** the owner. One page. The tech spec is `2026-10-12-codex-workbench-agent-design.md`, the plan is
`docs/superpowers/plans/2026-10-12-codex-workbench-agent.md`.

## The problem

Workbench works with Claude Code only. A session always launches `claude`, the hooks and the skill go into `.claude/`,
and state, resume, titles and the report all read `~/.claude`. You can run Codex in a plain shell session and connect
the Watchtower MCP by hand, but then you get no brief, no drift check, no state dot, no resume and no ask guard.

## What you get

A Workbench session can run **Codex CLI** instead of Claude Code, with the same features:

- The session starts in the folder with the workbench brief, the `watchtower-workbench` skill and the board tools
  (MCP), with nothing to set up by hand.
- **Work on It** starts Codex with the same "work on target #N" prompt, and the target moves to In progress.
- The state dot works: Working, Needs approval, Waiting for you, Stopped, Finished, Agents working.
- Owner asks: the agent files them with `ask_owner`. Your answers and comments are typed into the session, as today.
  The ask guard still sends a plain-text question back to `ask_owner` when you are away.
- The drift check runs at the end of every turn.
- AI session titles, the session report, Start fresh, and resume after an app restart.
- Hand-off from code navigation, the session switcher and the phone app all list Codex sessions too.

## What changes in the UI

- **New session** menus (header, pane, sessions panel, ⌘T switcher) get two entries: **New Claude Code session** and
  **New Codex session**. Agents whose CLI is not installed are shown disabled, with a hint.
- **Work on It** uses the default agent. Its menu has "Work on It with Claude Code / with Codex".
- **Settings → Workbench → Default agent**: Claude Code (default) or Codex.
- Session rows and the switcher show which agent runs (a small "Codex" tag on Codex sessions).
- Setup and **Repair** cover both agents. When Codex is not installed, Setup skips it quietly. Repair offers it once
  Codex shows up.
- UI texts that said "Claude Code" now name the session's agent ("Hand to Claude Code" becomes "Hand to session").

## What works the same

Board, asks, comments, `finish_session`, the session report, the Stop drift check, the ask guard, Quick asks, the phone
app, existing Claude Code sessions (nothing changes for them), and shell sessions.

## Known limits vs Claude Code (v1)

1. **No "Error" state for Codex.** Codex has no failure hook, so a turn that dies on an API error shows **Stopped**.
2. **A blank Codex session cannot be resumed until you send its first message.** Codex picks its own session id and
   reports it only when the first prompt arrives. Work on It always has a first prompt, so this affects only empty
   "New Codex session" tabs.
3. **Agents working** depends on Codex reporting its subagents. When it does not (to be confirmed in the first task),
   a Codex session with background agents shows Stopped. There is no 30-minute "is it still busy" check for Codex: a
   silent count ends as Stopped.
4. **Codex sessions run under your Codex settings** (sandbox, approval mode, model). Watchtower does not change them.
5. A Codex update can change how Codex trusts hooks. Watchtower then shows **Repair** on the workbench, and one click
   fixes it.
6. Codex sessions started outside Watchtower (your own terminal) do not get the hooks. They can still use the MCP if
   you add it yourself, as today.

## Your decisions (each has a recommended default)

| # | Decision | Recommended |
|---|---|---|
| D1 | Where the agent choice lives | **A global default in Settings plus a per-launch choice** (New session menu, Work on It menu). No per-workbench setting in v1. |
| D2 | Codex runs a hook only after it has been trusted. May Watchtower record that trust for **its own** hooks in `~/.codex/config.toml`, using Codex's own API, the same way Codex does when you approve a hook? The alternative is a launch flag that turns all hook checks off, which is unsafe. | **Yes**, record trust for our hooks only. Never use the bypass flag. |
| D3 | By default Codex asks your approval for **every** Watchtower board tool call. Should Watchtower's own tools run without a prompt in Workbench Codex sessions? | **Yes**, auto-approve only the `watchtower-workbench` tools. Everything else keeps your Codex approval settings. |
| D4 | Sandbox and approval mode for Codex sessions | **Use your own Codex config.** Watchtower passes no `-s`/`-a` flags. |
| D5 | Setup on a folder when Codex is installed | **Install the Codex part automatically** next to Claude Code's: the skill copy in `.agents/skills/`, kept out of git, plus the hook trust. |
| D6 | Starting a session from the phone | **Use the default agent from D1.** No agent picker on the phone in v1. |
| D7 | Accept the v1 limits above (no Error state, a blank session resumes only after its first message, no 30-min probe) | **Accept**, and file follow-ups if any of them hurts in practice. |

## Out of scope

The website copy that names both agents (after this ships, as a separate change), other agents (Cursor, Gemini, …),
per-workbench defaults, a phone agent picker, Codex's `queue`/daemon features, and moving existing sessions from
one agent to another.
