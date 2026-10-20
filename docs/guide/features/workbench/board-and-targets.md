# Board and targets

The board is the workbench's plan: a tree of targets that you and the agent both edit. It is for anyone who wants a long piece of agent work to stay organised across sessions.

## Why use it

A plan kept in a chat disappears with the session. On the board it stays, with status, comments and history, and every new session starts from it. You also get one place to see what is in progress, blocked or waiting for review.

## How it works

A **target** is one unit of work with a number such as `#163`, the number the agent uses in chat and the terminal. A target with sub-targets is a **feature** (the panel tags it **GROUP**). Its status is not set by hand: it follows its tasks.

With the default methodology (the `watchtower-flow` preset), a written plan becomes one sub-target per task.

Statuses are To Do, In Progress, In Review, Blocked, Done and Dismissed. The agent files targets itself. With the default methodology it first looks for targets on the same topic and files the new one in their group, creating the group if there is none.

You can also talk to the agent on a target: write in its comment thread. Agents use comments for a blocker or a short summary when a task is done, and what they need from you arrives as an [ask](asks.md).

**Archive.** A done or dismissed target leaves the board once it has been closed longer than the workbench's setting, 14 days by default. A feature leaves only when everything under it is closed and the last of it closed that long ago. Nothing is deleted, and a feature's task counter keeps counting archived tasks.

**Board drift.** The check compares each target with the folder's git branches and pull requests. It reads local git state only and never fetches, so a merge made on GitHub appears once the folder has fetched it.

It reports, for example, a target still in progress whose branch is merged, a done target whose branch is not merged, a branch that no longer exists, and in-progress work that has not moved for three days. The agent sees the same list at the end of each turn and is asked to bring the board in step with git.

## Using it

### Read and filter the board

Cards show the status, title, number, priority and badges: a blue bubble for unread agent comments, an orange count of open comment threads. A feature's card shows done sub-tasks with a small progress bar. Click the left strip of a feature to fold its sub-tasks. **Show done** reveals finished work.

The search field in the Board header matches title or intent. `#163` finds target 163 only; a bare `163` also finds titles containing it.

### Add a task

**New Task** in the Board header opens a panel; right-click a card for **New Sub-task…** to add one under it. Inside a group, the new task goes under that group.

1. The chip at the top shows where the task goes, such as **acme › #249 Billing export** or **acme › Top level**. Click it to search the board's open targets and pick another parent.
2. Type the title. Return moves to the description.
3. Set the priority chip (High, Medium, Low) and the column chip. The column chip lists the board's To Do and In Progress columns and starts on the first To Do column.
4. Press **Create Task** or ⌘↩. Esc closes the panel without creating anything.

The new task opens in the side panel. Turn on **Create more** to add several in a row: the panel stays open with the same parent and chips, and only the text clears.

### Switch to Kanban

The **List | Kanban** switch lays tasks out as columns. By default each top-level feature is a lane. The **Lanes** menu switches between **By group** and **None** (flat columns).

Drag a card to another column to change its status. In lanes a card moves only between the columns of its own lane; use **Move to…** to change its feature.

### Name your Kanban columns

You edit columns right on the Kanban's header row; each change saves at once. Right-click a column header, or click the **…** that appears on hover:

1. **Rename** turns the title into a field. Return saves, Esc cancels.
2. **Description…** sets the header's tooltip, which agents also read as guidance.
3. **Add Column Right** / **Add Column Left** adds a column in the same status, ready to rename. **Move Left** / **Move Right** reorder within the status.
4. **Delete Column** asks first when cards are in it and says where they go: the status's first column.
5. **Hide In Review** / **Hide Blocked** removes an empty status from the board.

A status without columns shows one column under its own name. Renaming it names the status's column. **Add Column** on it makes two: one under the status's name that keeps the cards, and the new one. Deleting the last column brings the status's own back.

The **+** at the end of the row adds a column to any status, and brings back a hidden one with **Show In Review** / **Show Blocked**. A refused change, such as a duplicate title or more than 6 columns in a status, shows its reason under the row and the board stays as it was. From the List, the workbench's **⋯** menu has **Edit Columns on the Kanban**.

### Open a target

Click a card to open it in the panel on the right. The board stays live behind it.

You can rename the title, change status and priority from the chips, edit the description, and read **Comments | History**. Its **Asks** section lists every ask about this target.

Drag the panel's edge to resize it (360 to 720 points).

### Start work

**Work on It** (the play button on a card, or in the panel) starts a session of the default agent named after the target. A target in To Do moves to In Progress once the session runs. If the target already has a session, the button opens it instead.

On a feature, the agent works its sub-tasks one after another. With the default methodology it skips blocked ones, ones waiting for you, and ones already in progress or in review.

### Group and move targets

Drag a target onto another to put it under that target, or right-click a card for **Move to** and **Move to Top Level**. A target can never go under itself or its own sub-tasks.

To look at one feature alone, click **Open group** in its panel, double-click its Kanban lane header, or right-click it in the list for **Open Group**. A path bar reads **Board › #249 Title › #252 Title**; **Leave group** goes up one level.

### Control the archive

In the page header's **…** menu:

- **Archive Closed Targets After** takes Never, 3, 7, 14, 30 or 90 days.
- **Archive Closed Targets Now** archives every closed target at once. One with an open sub-task stays.
- **Undo Archive Now** brings back what Archive Now archived.

**Archive (K)** next to **Show done** shows the K archived targets, dimmed and tagged **Archived**. To restore one for good, set its status back to an open one.

### Read the drift line

When something disagrees, a line under the Board header reads **Board drift: N out of step with git**, with findings that are only worth a look listed as "to review". Click it for the list and click an entry to open that target. The refresh button checks again; while the Board is open it re-checks by itself, at most every 30 seconds.

Press **Fix** in the list to start an agent session that runs the check and puts the board right for every finding; hover an entry and press its **Fix** to fix just that one. While such a session runs the button reads **Fixing…** and opens that session instead of starting another.

### Get notified

Watchtower notifies you when an agent asks something in a target comment, finishes a target, or proposes something only you can approve. Several at once in one workbench arrive as one summary.

## When it's empty or wrong

- **A closed target is missing.** It was archived. Turn on **Archive (K)**, or reopen it.
- **The drift line says Drift check incomplete, Drift check skipped or Drift check failed.** The check could not cover the board: the folder is not a git repository, it ran out of time, or git failed. Hover the line for the reason.
- **No drift line on an old workbench.** A workbench set up before the check existed shows an orange install icon once. **Repair install** in the **…** menu adds it.
- **The description edit did not save.** The message names the target and keeps your text. If the agent changed the description while you typed, nothing is overwritten.

## Related

- [Sessions](sessions.md) and [Asks](asks.md)
- [Workbench overview](README.md)

For developers: [docs/features/workbench.md](../../../features/workbench.md)
