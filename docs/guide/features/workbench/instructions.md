# Your instructions

Your instructions are standing directions you write once ("answer me in English", "test only what you touched") and every agent in a workbench follows. They work the same for Claude Code and Codex.

## Why use it

You type the same directions into every new session. A workbench can hold them for you, and can also give the agent one procedure for taking any target: read it first, ask when it is unclear, say what "done" means.

## How it works

There are two fields, each with a global text and an addition per workbench:

- **Session instructions** are placed in the brief of every new session. The agent sees the global text, then the workbench's own text.
- **Target procedure** reaches the agent each time it sets a target to In progress, in the answer to that update. It also arrives when it takes a target that is already In progress again.

Each text holds up to 1,000 characters. A change reaches new sessions only: a running or resumed session keeps the instructions it started with. The target procedure is read at the moment of use, so it applies from the next target even in a running session.

The texts are stored in Watchtower, never in your folder, and are not part of the repository. The folder's `workflow.md` is different: it is the team's committed rules, see [Methodology](methodology.md).

### Suggestions

Once a day Watchtower reads what you typed in your recent sessions, from both agents. When you gave the same standing direction in at least three sessions of the last 14 days and your texts don't hold it yet, it offers it as a suggestion. Nothing changes until you press **Add**, and a dismissed suggestion never comes back.

## Using it

1. Open **Settings → System → Workbench**.
2. Type in **Session instructions** or **Target procedure** and press **Save**.
3. To add to one workbench only, open its **…** menu, choose **Agent Settings…** and use **Your instructions — this workbench**.
4. Press **Preview what the agent gets…** to see the exact text.
5. When **You keep saying this** shows suggestions, press **Add** to append a line to the field, or **Dismiss**. Home shows the newest suggestion for a week as a card with the same buttons.

## When it's empty or wrong

- **A new session ignores a change.** The session began before you saved. Start a new one.
- **Add says to make room.** The field would pass 1,000 characters. Shorten the text, then press **Add** again.
- **No suggestions.** The direction has to appear in three sessions within 14 days, and the daemon must be running. The check is skipped when your Claude plan limit is close.
- **A suggestion for one workbench.** When all its sessions were in one workbench, **Add** writes that workbench's text.

## Related

- [Methodology](methodology.md): the folder's rules file and the ask guard.
- [Sessions](sessions.md): starting and resuming sessions.
- [Workbench](README.md)

For developers: [docs/features/agent-instructions.md](../../../features/agent-instructions.md)
