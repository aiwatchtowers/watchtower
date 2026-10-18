# Workbench

A workbench is a folder on your Mac, usually a code repository, that a coding agent works in. It comes with a board of targets that outlives any one agent session. Watchtower keeps the overview: what is being worked on, what is blocked, and what the agent needs from you.

## Why use it

Coding agents are good at a task and bad at remembering the plan. A workbench gives the agent a shared place for the plan, and gives you one screen that answers "where are we, and is anything waiting on me?"

Picture a feature that takes a week and a dozen agent sessions. The board holds the feature and its tasks, and each session picks up a task.

The agent files an ask when it needs your review or a decision. You come back to the Workbench tab and see the state without reading any terminal history.

## How it works

A workbench has four parts:

- **The folder.** Any folder; the workbench takes its name. Watchtower sets the folder up for the agent with a skill, hooks and a local connection to the board. All of it is local to your Mac and excluded from git.
- **The board.** Targets as a tree: a feature, its tasks, their status and comments. The agent reads and writes it through Watchtower's tools, and you edit it on screen. See [Board and targets](board-and-targets.md).
- **Sessions.** Claude Code or Codex running in an embedded terminal in that folder. Each session reports its state, so a dot tells you whether it works, waits or has finished. See [Sessions](sessions.md).
- **Asks.** When the agent needs a review, a check or a decision, it files an ask and keeps working on what doesn't depend on you. See [Asks](asks.md).

Nothing here changes your own terminal workflow. A session started in your own terminal app sees the same board.

## Using it

1. Open the **Workbench** tab and click the folder button next to **Workbenches** (or **Open Folder…** in the workbench switcher). Pick a folder. A folder that already has a workbench opens it; any other becomes a new one.
2. The terminal opens with the agent running. It reads the folder's README and docs, fills in the description and proposes a first board. Nothing is created until you agree; the proposal arrives as an ask in **Waiting for you**.
3. Start work on a target with **Work on It** on its card. The agent takes it from there.
4. Check back on the board and answer asks as they come.

### Run a workbench automation from the header

Each of the workbench's automations that runs **When I press a button** gets a button at the start of the header's right-hand controls, before **Terminal ▾**: up to four, the rest under **More**. A click starts the run; one set to ask first shows "Run <label>?" with **Run** and **Cancel**. While a run is going, the button spins and a click shows the run in Automations.

A dimmed button says why: **Needs your confirmation** opens the confirmation sheet, **Disabled** or **Parse error** opens its card. If the run could not start, "Could not run <label>" says why. With the Automations feature off there are no buttons. See [Recipes and templates](../automations-recipes.md#workbench-recipes).

A folder inside Documents, Desktop, Downloads or a cloud-synced folder shows a warning first, because macOS may ask to allow access. The warning comes before anything is created.

The agent writes board text in the language you use with it. Write to it in another language and the board follows; what is already on the board is not translated.

## When it's empty or wrong

- **"No workbenches yet".** You have not added a folder. Press **Add a folder** and pick one.
- **A session shows only a green dot, no state caption.** The folder was set up by an older Watchtower. In the page header's **…** menu, **Repair install** adds what is missing, or **Re-run Setup** brings it fully up to date. It only adds: the board, comments, asks and description stay as they are.
- **An orange install icon in the header.** Something in the folder install is missing. Hover it for the list, then use **Repair install**.
- **An orange install icon saying "Set up under the old Projects name".** The folder was set up before the rename to Workbench, and that setup no longer runs: its hooks only tell the agent to ask you for Repair, and its `watchtower-project` connection fails to start. Choose **Repair install** (or **Re-run Setup**) in the **…** menu; it migrates the folder, and keeps your own edited copy of the old skill, which you then delete.
- **A state shows only for sessions started in Watchtower's terminal.** A session in your own terminal app, or in a standalone terminal under **Terminals**, reports no state and has no board tools.
- **Workbench targets do not show elsewhere.** They live only on their board, not in Targets, the day plan or Catch Up. The daily briefing mentions workbench activity on its own.
- **Deleting a workbench** (**…** → **Delete…**) removes the board, asks and comments and what Watchtower installed in the folder. Your files stay.

Session or ask stuck? See [A Workbench session or ask is stuck](../../troubleshooting/workbench-session-or-ask-stuck.md).

## More pages

- [Board and targets](board-and-targets.md): the board, Kanban, grouping, archive, drift check.
- [Sessions](sessions.md): states, the sessions panel, reports, starting and resuming.
- [Asks](asks.md): reviews, checks and questions, and how answers reach the agent.
- [Code viewer](code-viewer.md): the Files pane, Open Quickly and go to definition.
- [Branches in the header](branches.md): switch, fetch and check out branches safely.
- [Worktrees and cleanup](worktrees-and-cleanup.md): own worktree per session, cleaning up after a session.
- [Diff review](diff-review.md): guided review of a session's changes.
- [Methodology](methodology.md): the workflow file and **Agent Settings…**.
- [Your instructions](instructions.md): standing directions every agent follows, and suggestions from what you repeat.
- [Codex](codex.md): using Codex as the agent.

For developers: [docs/features/workbench.md](../../../features/workbench.md)
