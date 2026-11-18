# Multi-folder workbench — design

**Board:** #2003 (FILES polish split off as #2017). **Status:** draft for the owner's review.
**Mockups:** brainstorm HTML (approved in ask #1541) → DesignShotCatalog shots in
`docs/design/mockups/multi-folder/` (§9).

## 1. Why

The owner works on tasks that cross repositories: a change in app A needs a matching change in
service B, sometimes in a site C. Today a workbench is one folder, so such a task is split
across workbenches by hand, and nothing connects the agents doing the halves.

The owner's model (asks #1532, #1534) is IntelliJ IDEA's: a workbench holds **several equal
folders**, each with its own git; you open one and put more on the bench as you need them.
Work stays one-folder-per-session: an agent in A that finds the task touches B **starts a
sub-session in B**, isolated in its own worktree by the usual rules, and the agents **talk to
each other**, for Claude Code and Codex alike.

## 2. Goals, non-goals, anti-goals

**Goals**
- G1. A workbench has 1..N folders, anywhere on disk, each a root in FILES with its own branch
  and status. Today's workbenches are the N = 1 case and look exactly as today.
- G2. **Put on the Bench…** adds a folder — from the workbench switcher (next to Open Folder…)
  and from the FILES header. No drag-and-drop (owner, 2026-11-18).
- G3. An agent that keeps working in a folder outside the bench **suggests** putting it on the
  bench; the owner answers with one tap (Put on Bench / Not Now / Never for This Folder).
- G4. A session runs in exactly one folder of its workbench; every git feature (branch crumb,
  worktree placement, drift, merged progress, branch review, finish gate, cleanup) works per
  folder.
- G5. An agent can start a **sub-session** in any folder of its workbench; it shows nested under
  its parent.
- G6. Any session can **message** any other live session of the same workbench (ask #1541); a
  sub-session's finish summary reaches its parent by itself.
- G7. A target names its folder, so its branch and PR are checked in the right repository.

**Non-goals (v1)**
- A session spanning several folders (`--add-dir`, composite worktrees) — rejected in ask #1534.
- An umbrella folder that discovers nested repositories — rejected in ask #1532.
- Nesting on the iPhone: the phone shows a flat list with folder labels (§6.14).
- Messages between workbenches.

**Anti-goals** (failure even if it technically works)
- A one-folder workbench that behaves differently from today (its only visible changes: the
  FILES root row from #2017, the Put on the Bench… icon and the hint, §6.2).
- A folder silently shared by two workbenches (hooks would report to the wrong board).
- Removing a folder from the bench deleting anything in it except Watchtower's own install.
- An agent message typed into a permission prompt or over the owner's draft.

## 3. Model

```
workbench (projects)
 ├─ folders (workbench_folders)        app ─ hub ─ site        all equal
 ├─ board (targets)                    a target may name its folder
 ├─ asks (owner_asks)                  + kind 'folder' (a suggestion)
 └─ sessions (terminal_sessions)       each in ONE folder; parent_session_id for sub-sessions
        └─ messages (session_messages) any live session → any live session of the workbench
```

- **Folder of a session** = the workbench folder it was started for. Its cwd is that folder or
  a worktree of it (existing placement rules, decided per folder).
- **Home folder** = the folder the workbench was opened with; kept in `projects.folder_path` for
  compatibility (automations' default, briefing, older clients). It is not shown as special.
  If it is removed, the next folder by position becomes the home folder (§6.3).

## 4. Data

One migration (next free number at implementation time; SQL, goose):

1. `workbench_folders`
   `id`, `workbench_id` (FK `projects` ON DELETE CASCADE), `folder_path` TEXT NOT NULL
   (symlink-resolved, as `projects.folder_path`), `position` INTEGER, `added_at`, `added_by`
   CHECK IN (`owner`,`agent_suggestion`), `removed_at` (NULL while on the bench), `name` (unique
   per bench among live rows, NOCASE; §6.2). Partial unique
   index on `folder_path COLLATE NOCASE WHERE removed_at IS NULL` — one folder, one workbench,
   globally. Removing a folder sets `removed_at` (the row stays, so targets and sessions keep
   pointing at it and can say "folder removed"); putting the same path back on the same bench
   clears it. Backfill: one row per workbench from `projects.folder_path`,
   position 0.
2. `terminal_sessions.workbench_folder_id` (FK ON DELETE SET NULL; NULL for standalone terminals)
   and `parent_session_id` (FK `terminal_sessions` ON DELETE SET NULL). Backfill: the workbench's
   only folder.
3. `targets.workbench_folder_id` (FK ON DELETE SET NULL). NULL = the home folder (today's
   behaviour); a removed folder is told apart by its row's `removed_at`. Set by `create_targets`/`update_target` (§6.10).
4. `owner_asks.kind` gains `folder` (table rebuild per the `add-migration` skill and
   `00150_builtin_automations.sql`, one transaction). Payload: `{"path", "repo_root", "touches", "why", "other_bench"?: {"id", "name"}}` (the
   last only when the folder is on another bench).
5. `workbench_folder_declines` (`workbench_id`, `folder_path` NOCASE, `declined_at`; PK both) —
   "Never for This Folder".
6. `session_messages` (`id`, `workbench_id`, `from_session_id`, `to_session_id` — both FK SET
   NULL, `kind` CHECK IN (`message`,`finished`,`failure`), `text`, `created_at`, `state` CHECK
   IN (`queued`,`delivering`,`delivered`,`failed`), `reason`, `delivered_at`, `prompt_cleared_at`
   — §6.6 "typed"). Persisted so a
   daemon restart resumes delivery. Text is not indexed and never leaves the Mac.
7. Docs index key (PROJ-08) gains the folder: `wbdoc:<project_id>:<folder_id>:<rel_path>`; the
   2 000-document cap becomes per folder. The migration drops the old `wbdoc:` rows; the next
   index pass rebuilds them (the index is derived data).
8. `session_outside_touches` (`session_id` FK CASCADE, `repo_root`, `touches`, `nudged_at`,
   `quiet` — set by Not Now; PK `session_id, repo_root`): the §6.7 hook's counter. One autocommit
   upsert per counted tool call, inside the hook's existing budget; rows go with the session.
9. `review_reviewer_threads` and `workbench_pr_states` gain `workbench_folder_id` (backfilled with
   the home folder) as part of their keys, so two folders with the same branch never share a
   thread or a PR state; `owner_asks` (rebuilt in item 4) gains `doc_folder_id` (NULL = home) and
   `doc_path` stays relative to that folder.

Mirrors: `schema.sql`, `TestAllTablesExist`, golden snapshot, `TestDatabase+Schema.swift`,
Kit's schema floor if it reads these tables.

## 5. Surfaces (CLI / MCP)

| Surface | New / changed |
|---|---|
| CLI | `workbench folder add|remove|locate|list --workbench N [--folder P] --json`; `workbench session start … --folder F --parent S`; `workbench message send --to S` (agents use MCP; CLI for tests and the Desktop) |
| MCP (workbench server) | `start_session(folder, brief, title?, target_id?, agent?)`, `send_to_session(session_id, text)`, `list_sessions()` (live sessions with folder, title, state, parent), `suggest_workbench_folder(path, why)`; `workbench_info` lists folders; `create_targets`/`update_target` take `folder` |
| Hooks | PostToolUse (Claude) counts outside-bench touches (§6.7) |
| Session host | new read-only request `PromptState {launch}` → `{holds_text}` (no write, no paste). `ProtocolVersion` stays 2 — the client treats any host below its own version as v1
(`client.go` `hello`: `h.Version < ProtocolVersion` → `ErrHostV1`), so a bump would send every
adopted v2 host into the one-time v1 restart. Instead `HelloMsg` gains an optional
`features` list; a host that serves the request answers `HelloOK` with `"prompt_state"` in it,
and the client sends `PromptState` only to such a host, with a 2 s deadline per call (a timeout
counts as "unknown", never as "empty"). A host without the feature (an adopted older host — it
would drop an unknown frame silently and never answer) is never asked; the deliverer then falls back to `UserPromptSubmit` and the run's end, and the pane notice gets a `Dismiss` that sets `prompt_cleared_at` by hand. Hosts are adopted across updates (PROJ-20), so the fallback is needed until the old host restarts. |
| Daemon | delivers `session_messages` (§6.6) |
| Added in implementation | `workbench folder quiet --session S --root R` (Not Now) and `workbench folder decline --workbench N --folder P` (Never), the Desktop's writers of §7; `workbench message dismiss --id N` (the pane's `Dismiss`); `workbench merge --from B --into A` (§6.13); `workbench session ensure-install --session S` (the §6.13 launch backstop: the Desktop runs it before every agent launch); `workbench git … --workbench-folder F` (id, name or path) picks the folder whose repository a git verb uses (without it `--folder`'s own folder, else the home folder); `workbench outside-touch --workbench N` (the §6.7 hook entry) |

The pack version (DEV-06 tool count) goes up by four tools.

## 6. Behaviour

### 6.1 Put on the Bench (owner)
Entry points: the switcher popover item **Put on the Bench…** (subtitle `Add a folder to
“<bench>”`) under **Open Folder…**; the FILES header icon button (`plus.rectangle.on.folder` — `folder.badge.plus` stays Open
Folder…'s; tooltip
`Put on the Bench…`). Both run the existing folder panel (`runFolderPanel`, title
`Put on the Bench`, prompt `Put on Bench`) and then `workbench folder add`.

Go validates, in one `BEGIN IMMEDIATE`: the path resolves to a directory; it is not already a
folder of this bench (→ `already_here`, the Desktop highlights that root); not a folder of
another bench (→ `other_bench` with that bench's name; the Desktop then offers the merge, §6.13); not inside or containing a folder of any
bench (→ `nested`, naming the folder). Benches that are already nested today are grandfathered:
the rule applies to new adds only.

**Path → workbench lookups.** Every lookup by folder (`WorkbenchByFolder`, `CreateWorkbench`'s
duplicate check, `--read-folder`, the Desktop's `openFolder` match) goes through
`workbench_folders` instead of `projects.folder_path`. **Open Folder…** on a folder that is on a
bench but not its home opens that bench. The sensitive-location confirmation of Open Folder…
(TCC) applies unchanged. Then, outside the transaction: the devpack install into the folder
with the same workbench id (PROJ-04 rules), docs indexing (PROJ-08), git watching.

Failure: an install that fails leaves the folder on the bench with the existing install-status
icon and its Retry; nothing is rolled back (the folder is usable for reading; sessions refuse to
start there until installed, `Install Watchtower in <name> first`).

### 6.2 FILES
FILES shows one root per folder, in position order (`CodeRoot` gains the folder id). A root row:
folder icon, name (the folder's stored `name`, unique per bench — the last path component, or
`<parent>-<last>` when taken; it is what `start_session(folder)`, doc paths and recipe prefixes
use, so a name never resolves to two folders),
right-aligned `⎇ branch ● ↑N ↓N` from that folder's git status (the root row lands first in
#2017 for the one-folder case). With an open session, its
folder's root is expanded and shows the session's worktree when placed in one
(`FILES — ⑂ name` caption stays). With one folder FILES shows its single root row, the Put on the Bench… header icon and the
quiet hint `Task touches another repo? Put on the Bench…` under the tree.

Root states: normal; `Folder not found` (`<path> was moved or deleted.` + `Locate…` ·
`Remove`); `Git unavailable`; `Not a repository` (no branch on the right); install missing
(existing icon). Context menu on a root: `Show in Finder`, `New Session Here`,
`Remove from Bench…`.

### 6.3 Remove from Bench / Locate
Remove is refused while a live session runs in the folder (title `Can’t remove <name> from the
bench`, text `1 session is running in <name>. Finish it first.` /
`<n> sessions are running in <name>. Finish them first.`, button `OK`) and for the last folder
(same title, `A workbench needs at least one folder.`, `OK`). Otherwise a confirmation (title
`Remove <name> from the bench?`, text `Watchtower's install in this folder is removed. Your files
and git are not touched.`, buttons `Cancel` · `Remove` (destructive)), then in one transaction:
set the row's `removed_at`,
move `projects.folder_path` if it was the home folder; then uninstall the devpack from the folder
(PROJ-02's "leaves nothing", for that folder) and drop its docs from the index. Finished
sessions of the folder keep their history; their worktrees go through the existing cleanup
(PROJ-18). Targets keep their `workbench_folder_id`; the drift check reports `folder removed` for a
branch it can no longer check, and the card shows `· folder removed` (Tone warning) instead of
the folder chip.

Locate… re-points a missing folder to a new path (same validation as add) and reinstalls.

### 6.4 Session start
`session start --folder F` (id or path; default the home folder, so every existing caller is
unchanged). The Desktop passes the folder of the context: the FILES root the owner chose, the
current session's folder for ⌘T, the target's folder for Work on It. The New Session (+) menu
keeps its top items for the context folder and, when there is more than one folder, adds an
`in <folder> ▸` submenu per other folder, each with the same agent items
(`New Claude Code session`, `New Codex session`); the existing `In This Folder ▸` and
`In Its Own Worktree ▸` placement submenus list the folders.

Placement is unchanged but **per folder**: `occupied` counts only live agent rows of the same
folder, and the worktree is made in that folder's repository. `unavailableReason` reads that
folder's git.

### 6.5 Sub-sessions
`start_session(folder, brief, …)` (MCP) runs `session start --folder F --parent <caller row>`.
Caller check as today (`checkSessionCaller`: same workbench). The agent kind defaults to the
caller's. The brief the child receives starts with a fixed header
`You are a sub-session of #<id> “<title>” (folder <name>). Message it with
send_to_session(<id>, …). When done, call finish_session — your summary is sent to #<id>.`
followed by the caller's brief.

Limits: nesting depth ≤ 3; at most 6 live sub-sessions under one root session (`limit` error
with the count). A folder not installed → `not_installed`. Result: `{session_id, folder, place,
worktree}`.

The panel nests children under their parent (one level of indent per depth); a child of a
deleted parent shows at top level. The parent row's state line adds `· <n> sub-sessions`. The
session strip of a child shows `📁 <folder> › ⑂ <worktree> › ⎇ <branch> ●` and, at its
trailing edge, `↖ from “<parent title>”` (click opens the parent).

### 6.6 Messages
`send_to_session(session_id, text)`: the target must be a live session of the same workbench
(ask #1541), not the caller. Text: control characters stripped, ≤ 4 000 characters
(`too_long`); any line of the text that starts with one of the fixed prefixes below
(`[Message from`, `[Sub-session`, `[Message to`, `(Reply with`) is prefixed with `> ` so a
sender cannot forge a header. Inserted into `session_messages` as `queued`; the tool returns `{message_id,
state}` at once and never waits.

**Who delivers.** The daemon (`watchtower daemon`, single instance — its existing lock is the
"exactly one deliverer" guarantee), not the Go hub: the hub runs only with Mobile on, and
messages must work without a phone. A `MessageDeliverer` goroutine wakes on a 2 s tick (and at
once when the MCP tool signals the daemon's existing wake) and delivers each `queued` row
through session-host `Deliver` (`sessionstart.Port.Deliver`, the same client the hub uses).

**At most once.** Before calling `Deliver` the deliverer moves the row `queued → delivering`
(one autocommit `UPDATE … WHERE state='queued'`, so two ticks never both take it); `submitted` → `delivered`; `held` or a gate hold (nothing was pasted) → back to `queued`;
`typed` (pasted, Return withheld because the hooks did not vouch for the run) is final: the row
becomes `delivered` with reason `typed_not_submitted`, is never pasted again, and the sender
gets `[Message to #<id> was typed into the session but not submitted; it waits in its prompt.]`
— the text sits in the receiver's prompt for its next submit, and a later message to that
session is held by the prompt-text check until then. The owner sees it: such a row carries `prompt_cleared_at` (NULL while the text may still sit
there). The deliverer sets it, on each tick for every row still NULL, when the session host's new read-only `PromptState` request (§5; it returns
`sess.prompt.holdsText()` — the state `Deliver`'s `HoldIfPromptText` already tracks — under the
session's lock, writing nothing; no hooks needed) reports an empty prompt, when a `UserPromptSubmit` is recorded after the row, or when the session's run ends.
While any row of the session has `prompt_cleared_at` NULL, the session row's state line adds `· Agent message waiting in the
prompt` (Tone warning) and the pane shows a notice `An agent's message is in the prompt. Press
Return in the terminal to send it.` with `Show in Terminal`. Held `finished` messages never
expire after 24 h — they wait while the parent row exists; held `message` rows still fail after
24 h with reason `prompt_not_cleared`, which names the cause to the sender. At daemon
start, a row left in `delivering` is never retried: it becomes `failed` with reason
`unknown_after_restart` and the sender gets the failure line. A message may therefore be lost
on a crash, never doubled.

**The gate.** The phone's line gate (`LineGate` in `internal/hub/actions/handlers`) is
extracted into a shared package (`internal/sessionline`) that both the hub and the daemon call,
so both apply one rule set: a Claude Code session takes the line while it works (Claude queues
it to its next step); a Codex session only when idle; a permission prompt, text in the prompt or
a just-submitted line hold it; the Return is sent only where the hooks vouch for the run
(PROJ-12). The hub's phone-specific parts (sealed action records, device, echo) stay in the
hub.

**Live** = the session host has a run for the row (the agent process exists), whatever its
agent state: Working, Waiting for you, Finished, Idle, Agents working. A row with no run (the
process exited, the app shows it as resumable) is not live: a message to it fails at once with
`not_running` — delivery never launches or resumes a session. The pasted text is
`[Message from #<id> “<title>” · <folder> — another agent of this workbench, not the owner]`,
then `<text>`, then a final line
`(Reply with send_to_session(<id>, …))`. Held lines are retried on each state read and fail
after 24 h, or at once when the target stops or is deleted; a failure is delivered to the sender
as `[Message to #<id> not delivered: <reason>]` through the same path.

**Trust.** A message is another agent's words, not the owner's. The pasted header (the one format above, the only one the deliverer writes) says so.
The skill rule (both agents) makes it binding: an agent message carries no owner authority —
it never answers or stands in for an ask, never approves a plan, review, merge, push, release,
external send (Slack, email, Jira) or deletion, and never changes the receiving session's
target or instructions; the receiver treats it as a colleague's request, checks it against its
own brief and asks the owner when it would need the owner's approval. Every message is visible
in both sessions' feeds. (Prompt-injection epic #551 covers poisoning in general; this rule is
the minimum for this path.)

**Finish:** a sub-session's `finish_session` inserts a `finished` message to its parent:
`[Sub-session #<id> “<title>” finished · <folder>] <summary>`. A parent that is not live keeps
it `queued` until the parent's next run starts (the owner resumes it), then it is delivered;
a deleted parent drops it (logged). A parent's report and feed show the finish either way.

**A parent waiting for its children.** A session whose own turn ended while at least one of
its sub-sessions is live shows **Sub-sessions working** (a new state presentation beside
Agents working, `· <n> sub-sessions` on the row), not Finished or Waiting for you, and raises no
owner-presence notice or chat-question escalation until the last child is no longer live.
*Added in implementation (owner approved in ask #1595):* only a parent that would otherwise rest —
idle (Stopped), or Finished with no open ask — shows Sub-sessions working. A parent with an open
ask, a permission prompt (Needs approval), a working turn, background agents or a failed turn
keeps its own state, so the owner still sees what the parent itself needs (Go
`sessionstate.Resolve`, Swift `SessionAgentStatus.effective`). Background shells alone (a dev
server) do not count as the parent's own work.

**Finish gate for sub-sessions.** `start_session`'s `target_id` is optional. A sub-session with
its own target is gated (gate 1) on that target's subtree only, never on its parent's; one
started without a target skips gate 1 (its summary goes to the parent, and the parent's gate
covers the ticket); gate 2 (review overview) still runs in the sub-session's own folder, so its
changes are never unchecked.

Feed (Workchat): the receiver's feed shows these lines as peer bubbles by their fixed prefix —
`↘ From “<title>” · <folder>` and `✓ Sub-session “<title>” finished · <folder>`. The sender's
feed shows its tool calls as outgoing peer bubbles — `↗ Sub-session “<title>” started ·
<folder> · ⑂ <worktree>` (`start_session`) and `↗ To “<title>” · <folder>` (`send_to_session`)
— and a queued message as `⏸ Message to “<title>” is waiting` with a reason line and `Open`.
Reasons: `The session is at a permission prompt; the message goes once it is answered.`,
`The session is busy; the message goes when it is idle.` (Codex), `The owner is typing in this
session; the message goes after that.`

### 6.7 The agent suggests a folder
**Detection (Claude Code):** the PostToolUse hook reads the tool's path arguments
(`Read/Edit/Write/MultiEdit/NotebookEdit` `file_path`, `Glob/Grep` `path`) — never Bash
commands. A path outside every folder of the bench, its worktrees, `~/.claude`, the temp and
scratchpad dirs is mapped to its repository root by walking up for `.git` (no git process). The
hook counts touches per (session, repo root); on the **third**, once per session and root, it
adds a context line: `You keep working in <root>, which is not on this workbench. If the task
needs it, call suggest_workbench_folder(<root>, why).` Declined roots and roots on another bench
are skipped. **Codex:** no detection in v1; the skill rule asks the agent to call the tool
itself.

**Tool:** `suggest_workbench_folder(path, why)` creates an ask of kind `folder` (one open per
bench and path; a second call returns the open one; `declined` for a declined path;
`other_bench` for a folder on another bench). The card in Waiting for you: title
`Put <name> on the bench?`, subtitle `From “<session>” · the agent worked in <path> <n> times`,
buttons `Put on Bench` (primary) · `Not Now` on one line and `Never for This Folder` (quiet)
under them (the panel is too narrow for three).
- Put on Bench → the Desktop runs §6.1 as the owner's action (TCC confirm if needed); the answer
  line to the agent: `<name> is on the bench now. Start a sub-session there with
  start_session("<name>", …).` A failed add shows the reason on the card (`Couldn’t put <name> on the bench: <reason>`, button
`OK`) and answers the agent with it; a folder of another bench shows the merge variant (§6.13).
- Not Now → answer line `The owner said not now.`; the hook stays quiet for that root for the
  rest of the session.
- Never → a `workbench_folder_declines` row; answer line `The owner does not want <name> on this
  bench.`

### 6.8 Git per folder
Header branch crumb, branch switch (PROJ-10), fetch, refs watcher and the 15 s poll follow the
active session's folder (or the selected FILES root); each FILES root polls its own status at
the existing cadence. `workbench git … --folder` resolves against the folder that contains the
path (`ResolveFolder` gets the folder list).

### 6.9 Review, finish gate, cleanup
Branch review, the diff reviewer, the finish gate's `leftItsWorktree`, the review lock path and
the spec-review document reads use the session's folder as the main repository. Session cleanup
(PROJ-18) plans per folder: a session's worktrees live in its folder's repository;
`WorkbenchFolders` covers every folder; the owner's sweep runs over all folders.

### 6.10 Board
`create_targets`/`update_target` accept `folder` (name or path of a bench folder); when a branch
or PR is set without it, the caller session's folder is stored. Drift (PROJ-07) runs git/`gh` in the target's folder (NULL → home folder). The merged progress
share belongs to the session report (`internal/sessionreport`), so it runs in the session's
folder (§6.9). Cards show a folder chip after the status chip when the bench has more than one folder (the
card has no branch chip).

### 6.11 Documents, search, automations
Docs indexing (PROJ-08) and the search scope cover every folder (key and per-folder cap in
§4 item 7); a document's path in search and asks is shown as `<folder>/<rel>` when the bench has more than
one folder, and as `<rel>` otherwise. `ask_owner` review `doc_path`: a relative path resolves
against the caller session's folder; an absolute one must lie in a bench folder. Automations are
read from every folder's `.watchtower/automations`; a duplicate recipe name is shown as
`<folder>/<name>`.

### 6.13 Merging benches (ask #1545)
Putting on the bench a folder that belongs to another bench B (from Put on the Bench… or a
suggestion card) offers to **merge B into this bench A** instead of refusing.

Confirmation: title `Merge “<B>” into “<A>”?`, text `<B>'s board (<n> targets), asks and
sessions move to <A>, and <B> leaves the workbench list. Folders that move: <list>.`, buttons
`Cancel` · `Merge` (primary). Refused while B has a live session (title `Can’t merge “<B>” yet`,
text `<n> sessions are running in <B>. Finish them first.` / singular, `OK`) — a running agent's
MCP server and hooks carry B's id. A merge into itself cannot happen (the folder is already
here).

Go (`workbench merge --from B --into A --json`): one `BEGIN IMMEDIATE` re-checks the live
sessions and moves every row that belongs to B — B's `workbench_folders` (positions after A's),
targets, comments, owner asks, sessions and their child tables, review rows, automations rows,
images, PR states, sources (deduplicated against A's) and every other table keyed by the
workbench id (the plan enumerates them from `schema.sql`; a test fails when a table keyed by
`project_id` is not covered) — then deletes B's `projects` row. B's board columns are dropped;
its targets keep their status and land in A's first column for that status (PROJ-19). B's
`workbench_folder_declines` are dropped. After the commit: reinstall the devpack in the moved
folders with A's id (PROJ-04; B's install is replaced, the owner's content kept) and re-index
their documents under A. The reinstall also covers every still-existing worktree of B's moved
sessions (`terminal_session_worktrees` and each row's `folder_path`), so a resumed session finds
A's id. As a backstop, every agent launch (new, resume, Start fresh) compares the workbench id
installed in its cwd with its row's `project_id` and reinstalls before launching when they
differ (`install_mismatch` is logged). A failed reinstall leaves the install icon with Retry;
the data move is already whole.

Suggestion card: when the suggested folder is on bench B, the card reads
`<name> is on the “<B>” bench`, buttons `Merge Benches…` (opens the confirmation) · `Not Now`.

### 6.14 Elsewhere
- Delete workbench (PROJ-02): uninstalls from every folder and cleans up sessions across folders.
- Re-run setup (`workbench resync`): every folder.
- Phone: session rows gain the folder label; sub-sessions show flat with `from #<id>`. Kit model
  gains `folder` and `parentSessionID` (optional, old Macs send none).
- `workbench_info` lists folders (`name`, `path`, `home`, `installed`).
- Workbench switcher: a multi-folder bench's row shows its folders after the name
  (`acme · app, hub, site`, truncated at the tail).
- Briefing WORKBENCHES block: unchanged.

### 6.15 Strings and behaviour added in implementation
The tasks named these where the spec gave no text; each lives in a presentation model with a test.
- **FILES and Put on the Bench (§6.1–§6.3).** A refusal without words from the CLI reads
  `the command gave no reason.` A failed Remove: `Couldn’t remove <name> from the bench: <reason>`;
  a refusal Go sends after the confirmation (a session started meanwhile) keeps the title
  `Can’t remove <name> from the bench` with Go's sentence and `OK`. Locate…'s folder panel: title
  `Locate <name>`, button `Choose`; a failed Locate: `Couldn’t locate <name>: <reason>`. A root whose
  install is missing shows `Retry`, its icon's tooltip `Watchtower is not installed in <name>.
  Sessions can’t start there until it is — Retry sets it up again.` Two roots with the same last
  path component show their parent directory as a caption. Locate… goes through the same
  sensitive-location (TCC) warning as Put on the Bench…. Re-run Setup's summary adds
  `Setting up <name> failed: <error>` per folder and `The other folders were not set up: <error>`.
- **Suggestion card (§6.7).** The subtitle drops `From “<session>” · ` when the session is gone
  (the line then starts `The agent worked in …`) and drops the count when no touches were counted
  (a Codex session asks by itself): `… the agent worked in <path>`; one touch reads `1 time`. When
  Put on Bench meets the sensitive-location warning, its cancel button on a card is `Cancel`. A
  failure whose answer could not be saved shows `Retry` (sends the answer again) instead of `OK`.
  The ask kind's label is `Folder`.
- **Work on It (§6.4).** A target whose folder left the bench starts in the home folder with the
  notice `Started in <home>: the target's folder <folder> left the bench.`
- **Merge (§6.13).** A merge that fails after the confirmation: `Couldn’t merge “<B>”: <reason>`.
  The launch backstop is `workbench session ensure-install --session S` (it reinstalls only when
  the installed workbench id differs from the row's, logging `install_mismatch`).
- **Feed (§6.6).** A refused or failed tool call is no success bubble: `↗ To “<title>” — not sent:
  <error>`, `↗ Sub-session “<title>” not started: <error>`; a start whose result is not read yet:
  `↗ Sub-session “<title>” starting · <folder>`; a started one's body `Brief sent.` A waiting
  message whose hold the Desktop cannot tell reads `The message goes when the session can take
  it.`; with the daemon stopped, `Watchtower's background sync is stopped; the message goes when
  it runs.` (D44).
- **Board (§6.10).** The folder chip's tooltip is `Folder`; the target panel's folder menu reads
  `Folder removed` for a removed folder.

## 7. Failures and races

| Path | Failure | Behaviour | Test |
|---|---|---|---|
| folder add | path vanishes between panel and add | `not_found`, nothing written | Go: add of a missing path |
| folder add | install fails half-way | folder stays, install icon + Retry; start refused `not_installed` | Go + Swift |
| folder add | two adds of the same path race | UNIQUE index: one wins, the other gets `already_here`/`other_bench` | Go: concurrent add |
| folder remove vs session start | start in the folder while remove commits | both in `BEGIN IMMEDIATE`; remove re-counts live rows inside its tx; start re-checks the folder row inside the row insert; first commit wins, the other gets `folder_removed` / `sessions_running` | Go race test |
| folder missing at launch | moved/deleted | root `Folder not found`; start refused `folder_missing` | Swift presentation + Go |
| sub-session start | host down before the row | refused before any row; the tool result carries the error | Go |
| sub-session start | launch fails after the host answered | the child row stays as a failed start (today's start-failure behaviour, `TestPortStartFailuresAreNeverStarted`); a `failure` message tells the parent (Tasks 10–11) | Go |
| message | target stops, is deleted, or 24 h pass | `failed` + failure line to the sender | Go daemon deliverer test with fake clock |
| message flag | `PromptState` times out or the connection drops | treated as unknown: flag stays, next tick retries; never blocks the tick past 2 s | Go client test with a silent fake host |
| message flag | host's HelloOK has no `prompt_state` feature | `PromptState` never sent; fallback + Dismiss; no `ErrHostV1`, no host restart | Go client test on a featureless v2 hello |
| message flag | session has no hooks (the reason it was typed) | cleared by the host's prompt-text read or the run's end, never waits on a hook | Go deliverer test with a fake host |
| message | Deliver returns `typed` (Return withheld) | row final `delivered`/`typed_not_submitted`, never re-pasted; sender told; later lines held by the prompt-text check | Go deliverer test with a fake host |
| message | daemon restarts with queued lines | resumed from `session_messages` | Go |
| message | target not running | `failed` `not_running` at once; never launches it | Go |
| finish → parent | parent not running | stays `queued` until the parent's next run; delivered then | Go |
| message | target at a permission prompt / owner draft | held, retried on state read; never typed into either | Go gate test (reuses PROJ-16 cases) |
| message | Mac quits mid-delivery | host keeps the run (PROJ-20); a row still `queued` resumes; a row in `delivering` becomes `failed` `unknown_after_restart` (never doubled) | Go |
| finish → parent | parent deleted | dropped, logged | Go |
| parent waits | last child stops | parent leaves Sub-sessions working; its stored state shows | Swift presentation test |
| suggestion | owner clicks Put on Bench while the folder became another bench's | card switches to the merge variant; agent told | Swift + Go |
| merge | a session of B starts between the dialog and the merge | re-checked inside the merge transaction → `sessions_running`, nothing moved | Go race test |
| merge | crash mid-move | one transaction: all of B or nothing | Go (tx failure injection) |
| merge | reinstall in a moved folder fails | data already in A; install icon + Retry | Go + Swift |
| hook | repo-root walk on a slow network path | walk capped at 64 levels and skips paths on non-local mounts (no `MNT_LOCAL`); hook budget unchanged | Go |

**Writers and who wins**
- `workbench_folders`: only the Go CLI (Desktop and MCP never write it directly). Races resolved
  by the unique index and `BEGIN IMMEDIATE`.
- `terminal_sessions.workbench_folder_id`/`parent_session_id`: only `session start` (insert).
- `targets.workbench_folder_id`: MCP `create_targets`/`update_target` and the owner's board edit;
  last write wins, as for `branch`.
- `session_messages`: MCP inserts; the daemon alone moves `state`. Exactly one daemon runs (its
  existing single-instance lock).
- `owner_asks` kind `folder`: MCP inserts; the Desktop answers (existing ask writers).
- `workbench_folder_declines`: the Desktop's answer handler only, through `workbench folder
  decline` (the write itself is Go).
- `session_outside_touches`: the PostToolUse hook (counts) and the ask answer handler (`quiet` on
  Not Now); upserts, last write wins — a lost count only delays the nudge by one touch.

## 8. Contracts

Approved by the owner (asks #1545, #1548):
- **PROJ-02** (delete leaves nothing): extends to every folder; removing one folder leaves nothing
  of Watchtower in that folder.
- **PROJ-04** (install never overwrites): the install runs in every folder, same rules.
- **PROJ-07** (drift): checks run in the target's folder; a target whose folder was removed
  reports `folder removed` instead of a git verdict.
- **PROJ-08** (documents searchable only from own sessions): the workbench's documents are the
  union of its folders; the key gains the folder id and the 2 000 cap is per folder.
- **PROJ-10** (header branch switch): per folder of the active session.
- **PROJ-11** (session states): new presentation **Sub-sessions working** for a parent whose
  turn ended while its sub-sessions are live; no owner-presence notice meanwhile. A parent with
  an open ask, an approval or a working turn keeps its own state (ask #1595, §6.6).
- **PROJ-14** (session report, finish gate): a parent's report does not include its
  sub-sessions' work; a sub-session is gated only on its own target, or not at all without one.
- **PROJ-16** (phone lines): unchanged in behaviour; its gate moves into a shared package the
  daemon also uses.
- **PROJ-18** (cleanup): per folder repository; never removes anything in a folder that left the
  bench except worktrees its own sessions created.
- **New PROJ-23 — agent messages:** a message reaches only a live session of the same workbench,
  through the shared line gate, never into a permission prompt or over the owner's draft, at most
  once, never launches a session, is marked as another agent's words (never the owner's), and
  its failure is reported to the sender.
- **PROJ-09** (a target moves only within its own workbench): a merge moves every target of the
  merged bench, with its tree intact, into the bench it merges into (approved, ask #1548).
- **New PROJ-24 — folder membership:** a folder belongs to at most one workbench; removing it
  from the bench touches nothing but Watchtower's install.

## 9. Mockups (DesignShotCatalog)

`workbench-multifolder-*` shots, light and dark, `acme` data, exported to
`docs/design/mockups/multi-folder/`:
1. `panel-nested` — sessions with two sub-sessions, folder labels, FILES with three roots.
2. `panel-single` — one folder: today's look + the hint.
3. `files-root-errors` — Folder not found (+ Locate · Remove), Git unavailable, Not a repository.
4. `switcher` — Put on the Bench… under Open Folder….
5. `new-session-menu` — per-folder items.
6. `suggest-card` — Put on Bench / Not Now / Never; busy (`Putting on the bench…`); error
   (`Couldn’t put billing on the bench: …`); the old `Already on the “tools” bench` shot is
   replaced by `suggest-card-merge`.
7. `remove-confirm` and `remove-refused` (sessions running; last folder).
8. `feed-parent` — started / from / finished / waiting peer bubbles.
8a. `merge-confirm`, `merge-refused`, and `suggest-card-merge` (§6.13).
8b. `message-in-prompt` — row flag and pane notice (§6.6, D40). The `Dismiss` button shows
    only with a pre-`PromptState` host (§5) and sits after `Show in Terminal` as a quiet button.
9. `strip-child` — `📁 hub › ⑂ export-api › ⎇ … ↖ from “…”`.
10. `board-card-folder` — folder chip, drift `folder removed`.

Rendered (light and dark): `docs/design/mockups/multi-folder/*.png`, index in its `README.md`.
`suggest-card` and `remove-refused` are split into their states (`suggest-card-busy`,
`suggest-card-error`, `remove-refused-sessions`, `remove-refused-last`). Also `switcher-folders` (§6.14) and `panel-parent-waiting` (Sub-sessions working, §6.5). The
phone row's folder label is mocked in the mobile task (17) with the phone's own previews; the
Mac catalogue does not render iOS views.

Every string above lives in a presentation model with a test (owner rule).

## 10. Task outline (the plan details it)

1. Migration + schema mirrors + `db` accessors (folders, session columns, target column, ask
   kind, declines, messages).
2. `workbench folder add|remove|locate|list` + devpack install/uninstall per folder.
3. `session start --folder/--parent`; placement per folder.
4. Git per folder (`ResolveFolder`, refresher, header data in the hub source).
5. Drift + merged progress per target folder; `create_targets`/`update_target` `folder`.
6. Review, finish gate, spec review reads per session folder.
7. Cleanup per folder (PROJ-18 amendment).
8. Docs/search/automations over all folders.
9. MCP `start_session`, `list_sessions`, sub-session brief header, limits.
10. Extract the line gate to `internal/sessionline` (today shaped for the phone: its signature
    and the hub's `transporttest` cases move with it; the hub keeps a thin adapter);
    `session_messages` + MCP `send_to_session` + daemon `MessageDeliverer` + finish → parent; session-host `PromptState` request (client,
    server, old-host fallback test).
11. Hook detection + `suggest_workbench_folder` + ask kind `folder`.
12. Desktop: models (`WorkbenchFolder`, session/target columns), `CodeRoot` per folder.
13. Desktop: FILES multi-root + root states + context menu + Put on the Bench (switcher, header).
14. Desktop: sessions panel nesting, labels, strip `from`, New Session per folder.
15. Desktop: suggestion card + answer actions; remove/locate flows.
16. Desktop: Workchat peer bubbles (feed parse of the fixed prefixes).
17. Board card folder chip; phone/Kit folder + parent fields.
18. `workbench merge` (Go, table coverage test) + Desktop confirmation and card variant.
19. Docs: feature note, guide page, inventory amendments, skill rule for Codex.

## Decisions

| # | Decision | Source |
|---|---|---|
| D1 | Full parity across all git features, not an MVP | ask #1529 |
| D2 | Equal folders like IDEA modules, not an umbrella folder | ask #1532 |
| D3 | A session runs in one folder; cross-folder work goes through sub-sessions | ask #1534 |
| D4 | Isolation follows the default flow (worktree when the folder is occupied) | ask #1534 |
| D5 | Agents talk to each other, Claude Code and Codex | ask #1534 |
| D6 | Any session may message any live session of the workbench | ask #1541 |
| D7 | Mockups v3 approved | ask #1541 |
| D8 | Folders live in FILES as roots; no separate section | conversation 2026-11-18 |
| D9 | A visible add button in the switcher and the FILES header; no drag-and-drop | conversation 2026-11-18 |
| D10 | The agent suggests putting a folder on the bench via MCP + a card | conversation 2026-11-18 |
| D11 | The action is called **Put on the Bench…** | conversation 2026-11-18 |
| D12 | All UI text is English; content (titles, briefs, messages) stays as written | conversation 2026-11-18 |
| D13 | A folder belongs to at most one workbench | decided by the agent |
| D14 | `projects.folder_path` stays as the home folder for compatibility | decided by the agent |
| D15 | The suggestion is a new ask kind `folder` | decided by the agent |
| D16 | Messages persisted in `session_messages`; delivered through the PROJ-16 gate | decided by the agent |
| D17 | Detection only from tool path arguments, third touch, Claude only in v1 | decided by the agent |
| D18 | Sub-session limits: depth 3, six live per root | decided by the agent |
| D19 | Phone: flat list with folder labels in v1 | decided by the agent |
| D20 | Last folder cannot be removed; removal refused while sessions run there | decided by the agent |
| D21 | The daemon delivers messages (works without Mobile); the line gate is shared with the hub | decided by the agent |
| D22 | Live = the host has a run; a message never launches a session | decided by the agent |
| D23 | Parent shows Sub-sessions working while children are live | decided by the agent |
| D24 | A sub-session is finish-gated on its own target only, or not at all | decided by the agent |
| D25 | Open Folder… on a non-home bench folder opens that bench; existing nesting grandfathered | decided by the agent |
| D26 | Docs key gains the folder id; 2 000 cap per folder | decided by the agent |
| D27 | Removed folders are soft-removed (`removed_at`) so targets can show "folder removed" | decided by the agent |
| D28 | Put on the Bench… icon `plus.rectangle.on.folder`; Open Folder… keeps `folder.badge.plus` | decided by the agent |
| D29 | Approved as listed in ask #1545: PROJ-02/04/07/08 (key + per-folder cap)/10/11 (Sub-sessions working)/14 (report + finish gate)/18 amended, PROJ-16 unchanged in behaviour (gate shared), new PROJ-23/24 | ask #1545 |
| D30 | A folder of another bench merges that bench into this one | ask #1545 |
| D31 | Merge refused while the other bench has live sessions; B's custom columns and "Never" declines are dropped (columns are per bench and cannot coexist), targets keep status and land in A's first column for it | decided by the agent |
| D32 | Folder icon everywhere a folder is shown | conversation 2026-11-18 |
| D33 | A finish report to a parent that is not running waits for the parent's next run | decided by the agent |
| D34 | Delivery is at most once (`delivering` state; lost on crash, never doubled) | decided by the agent |
| D35 | Agent messages carry no owner authority (header + skill rule); forged headers are quoted | decided by the agent |
| D36 | Hook counter persisted in `session_outside_touches` | decided by the agent |
| D37 | After a merge every launch reinstalls when the installed id differs from the row's | decided by the agent |
| D38 | PROJ-09 amended: a merge moves the merged bench's targets with their trees | ask #1548 |
| D39 | A `typed` delivery is final (never re-pasted); the sender is told it waits in the prompt | decided by the agent |
| D40 | A message left in a prompt is flagged on the row and pane; finish reports never expire while the parent exists | decided by the agent |
| D41 | New read-only session-host request `PromptState` (a `prompt_state` feature in HelloOK, protocol version unchanged, 2 s deadline); older hosts fall back to hook/run end + a manual Dismiss | decided by the agent |
| D42 | MCP errors to agents read `"<code>: <sentence>"` with the codes named in this spec | decided by the agent (plan) |
| D43 | Folders carry a stored unique `name`; review threads, PR states and ask doc paths carry the folder id | owner, plan review ask #1564 |
| D44 | Sending while the daemon is stopped queues the message and warns `daemon_not_running`; the waiting bubble says the background sync is stopped | owner, plan review ask #1564 |

## Left to the builder
Exact migration number; how `CodeRoot` encodes the folder id in its defaults key; the hub's
retry scheduling inside the existing state-read loop; the feed parser's prefix match.
