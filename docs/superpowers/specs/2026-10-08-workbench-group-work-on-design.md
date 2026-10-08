# Work on It for a group — design

Board target #472. Amends one decision of
`docs/superpowers/specs/2026-10-06-workbench-board-hierarchy-design.md` (the group panel's
**Open group** replacing Work on It).

## For the owner (one page)

**Today.** Only a single task can be taken into work. A group's side panel shows
**Open group** where a task shows **Work on It**, the Kanban lane header of a group has no
button at all, and the skill the agent runs has no instructions for "work on this group".
(The List view already shows the play button on group rows, but the agent then gets the
same prompt as for a task and has no rules for walking the sub-tasks.)

**After.**
- A group's side panel shows **Work on It** as its main button, with **Open group** next to
  it as a secondary button. The Kanban lane header of a group, the group row in List and
  the right-click menu of any target get the same action.
- The button behaves like a task's: if the group already has its own session, it opens it
  (**Open Its Session**); otherwise it starts a new Claude Code session named after the
  group.
- The agent in that session works the group's sub-tasks itself: if the group's description
  names a plan, it follows the plan task by task; otherwise it takes open sub-tasks in board
  order (priority, then status, then id). It skips what is blocked, waiting for you, or
  already being worked on (`in_progress` / `in_review`), never sets the group's own status
  (the board derives it), and finishes with one session summary for the whole group.
- The session report already counts progress over the whole group — nothing changes there.

**What you decide.**
1. *Sub-tasks that already have their own sessions.* **Recommended:** the group still gets
   its own new session; the agent skips sub-tasks that are already `in_progress` or
   `in_review` (someone is on them) and takes only `todo` ones. *Alternative:* refuse to
   start a group session while any sub-task has a session — safer against double work, but
   blocks the common case of a group with one task already running.
2. *Button label in a group.* **Recommended:** the same **Work on It** / **Open Its Session**
   as for a task (one button, one meaning). *Alternative:* **Work on Group**.

**Not in scope.** Starting sessions per sub-task automatically; showing a group's child
sessions on the group; changing how a task's session is found.

## Technical design

### Desktop

- **`TerminalLaunch.workOnGroupPrompt(targetID:vocabulary:)`** →
  `Work on group #<id> using the <skill> skill.` A fixed string like
  `workOnTargetPrompt`: the target's text never reaches argv or the prompt; it travels in
  `WATCHTOWER_FIRST_PROMPT` as today.
- **`WorkbenchesViewModel.workOn`** picks the prompt at creation time: group prompt when
  the target has sub-targets (read in `readTargetSessions` alongside the target row — a
  `TargetQueries` child-count read, same workbench), task prompt otherwise. Session lookup
  stays `TerminalSessionPolicy.sessionForTarget` (exact `target_id` match): a group's
  session is found from the group only; sessions of its sub-tasks are not matched, which is
  decision 1's recommended behaviour. A session created for a task that later grew
  sub-tasks is reopened as is (no new prompt).
- The pure choice is the function
  `TerminalLaunch.workOnPrompt(targetID:isGroup:vocabulary:)` so it is unit-tested in `Tests/Core`.
- **Group panel** (`WorkbenchTargetPanel`, `case .group`): `WorkOnTargetButton(compact:
  false)` as the prominent button; **Open group** becomes a bordered secondary button, same
  disabled rule and help text.
- **Kanban lane header** (`WorkbenchBoardKanbanLaneView.header`): a compact
  `WorkOnTargetButton` after the progress, only for a lane that is a target (not the
  "direct tasks" lane of the scope root, not the top-level loose-tasks lane). Its tap must
  not select or enter the lane (button hit-testing over the header gesture).
- **List**: group rows already carry the compact button (`WorkbenchBoardView.tree`); no
  change beyond the prompt.
- **`WorkbenchTargetMenu`**: a first item **Work on It** / **Open Its Session** for any
  target (task or group), calling the same `workOn`.

### Skill pack

`internal/devpack/workbenchskill/watchtower-workbench/SKILL.md` gains:

- **Working a target** (short): the first prompt `Work on target #<id>` → `get_target` +
  `list_comments` and the board; a target with sub-targets is worked as a group, otherwise
  set `in_progress` with `branch` and follow the feature/plan rules.
- **Working a group** — the first prompt `Work on group #<id>`, or a target that has
  sub-targets:
  1. `workbench_board` and `get_target` on the group: read the subtree and the intent.
  2. If the intent names a plan, run it task by task under "Running a plan", following the
     plan's dependencies.
  3. Otherwise take open leaves in board order (priority → status → id). Independent
     leaves may run in parallel only where the folder's own rules allow parallel work.
  4. Skip leaves that are `blocked`, wait on an open ask, or are already `in_progress` /
     `in_review` at session start (another session is on them).
  5. Never set the group's status; set the leaves', the group follows.
  6. One `finish_session` at the end with `target_id` = the group, summarising the group.

The pack marker goes v3 → v4 (`x-watchtower-pack`), the repo's convention: the previous
pack is frozen in `internal/devpack/testdata` for the DEV-04 upgrade test. The installed
copy is still refreshed by its content digest (DEV-04 `planFor`, PROJ-04 keeps
owner-edited copies).

### Go / report

No change. `terminal_sessions.target_id` = the group; `internal/sessionreport` `newScope`
already walks the session target's subtree for progress, phases and Now/Next. A test pins
it: a session on a group with two leaves, one done → progress 1/2.

### Contracts

`docs/inventory/workbench.md` has no entry on the first prompt, the panel or Open group;
no contract changes. The hierarchy spec's panel decision is amended by a dated note.

### Tests

- `TerminalLaunchTests`: the group prompt's exact string, both vocabularies; no quote.
- `TerminalSessionPolicyTests` (or Core): `TerminalLaunch.workOnPrompt` picks group vs task.
- `WorkbenchesViewModelSessionsTests`: Work on It on a group creates a session with
  `target_id` = group, title = group text, group prompt; a second call opens the same
  session; a group with a sub-task session still creates its own.
- `internal/sessionreport`: the group-subtree progress test above.
- `internal/devpack`: the embedded skill names "Working a group" and the group prompt
  (guards the Desktop↔skill string pairing).

### Docs

Hierarchy spec (dated amendment), `docs/features/workbench.md` (Work on it + hierarchy
bullets), `docs/app-guide.md` (Work on it, Entering a group).
