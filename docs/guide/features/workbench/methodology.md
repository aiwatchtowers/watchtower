# Methodology

The methodology is the set of working rules an agent follows in a workbench: how features become targets, whether it must ask you instead of typing questions, and whether it must report when done. You set it once per workbench, or let a file in the repository set it for the whole team.

## Why use it

Different teams want different agents. One wants the full flow of features, specs, plans and reviews. Another wants the agent to follow the repository's own rules and nothing else. The methodology lets you choose, without editing skill files by hand.

## How it works

Three settings apply to every session of a workbench:

| Setting | Values | What it does |
|---|---|---|
| **Methodology** | `watchtower-flow` (default), `none` | `watchtower-flow` installs a second skill: features, specs and plans become targets, and work goes to `in_review` for a reviewer. `none` leaves only the core workbench skill and your folder rules. |
| **Ask guard** | `strict` (default), `soft`, `off` | What happens when the agent ends a turn with a request in plain text. `strict` sends it back until the agent files an [ask](asks.md). `soft` sends nothing back and raises the question as an ask for you; Claude Code's question dialog works while you are in the session. `off` checks nothing and allows the agent's own question tool. |
| **Finish check** | `on` (default), `off` | `on` sends back a turn that reports the work complete without calling `finish_session`. `off` skips the reminder, and an unfinished session ends as **Stopped** with no summary. |

Each setting comes from the first of three places that has it:

1. **Your setting** in **Agent Settings…**. It wins.
2. **The folder file** `.watchtower/workflow.md`, committed with the code, so a team shares it.
3. **The built-in default**.

The file is a short frontmatter of the same three keys, then free text. The text is the team's rules for agents. Every session's brief shows them, up to about 1,200 characters; longer text becomes a pointer to the file. The file is read up to 64 KiB, and a symlink or special file is ignored.

The agent never changes these settings. If anything about them cannot be read, the session runs as strict and on, never weaker.

## Using it

1. Open the page header's **…** menu and choose **Agent Settings…**.
2. Pick a value for **Methodology**, **Ask guard** and **Finish check**. **From folder file** means "do not override", and shows the current value and where it comes from.
3. **Create workflow.md** writes a template with every key commented out. Edit it, and commit it. The button reads **Open workflow.md** once the file exists.
4. Press **Done**.

A methodology change reinstalls the folder's skills. A session worktree takes the change when it is next set up.

## When it's empty or wrong

- **"workflow.md was ignored: …".** The file is malformed or unsafe to read. The built-in defaults apply until you fix it.
- **"workflow.md is longer than 64 KiB".** Only the first 64 KiB is read.
- **"Your edited watchtower-flow skill was kept; delete it yourself to drop the methodology."** With **Methodology** at `none`, a flow skill you edited stays. Delete it to remove it.
- **"The setting was saved, but the folder's skills were not updated".** Use **Re-run Setup** in the **…** menu.
- **Soft raises nothing.** Under `soft`, a question becomes an ask only in Watchtower's own terminals and while Watchtower is running.

## Related

- [Asks](asks.md): what the ask guard protects.
- [Your instructions](instructions.md): your own standing directions; `workflow.md` here is the team's folder rules, committed with the code.
- [Sessions](sessions.md): **Finished** and **Stopped** states.
- [Workbench](README.md)

For developers: [docs/features/workbench.md](../../../features/workbench.md)
