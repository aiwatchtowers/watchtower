# Inbox builder B — folders and the Inbox menu (design)

**Umbrella:** [2026-11-02-inbox-builder-design.md](2026-11-02-inbox-builder-design.md) (board #1400). **Sibling:** sub-project A, blocks and the Look step (`2026-11-03-inbox-builder-a-blocks-look-design.md`), specced in parallel — see **Contract with sub-project A**. **Plan:** [2026-11-03-inbox-builder-b-folders-menu.md](../plans/2026-11-03-inbox-builder-b-folders-menu.md).

**Mockups** (HTML, sample data only; the native DesignShotCatalog shots are the plan's Task 1 and replace them as the reference once the owner has looked at them):

- [`b-01-inbox-menu.html`](../../design/mockups/inbox-builder/b-01-inbox-menu.html) — the folder menu, the root selected, the artifact ⋯ menu, the folder ⋯ menu, the root ⋯ menu, the Idea finder entry's ⋯ and a failed ⋯ entry on the artifact header.
- [`b-02-needs-approval.html`](../../design/mockups/inbox-builder/b-02-needs-approval.html) — Needs approval: recipe card, native fallback card, failed action with Retry / Dismiss, reminder, recipe cards only, built-in upgrade notice, recipe off, built-in stopped (its own Turn On), last run failed, off-note and stopped-note Turn On failed, turned on but not restarted (daemon banner over the Inbox and over the Automations tab's built-in card), empty.
- [`b-03-waiting-for-me.html`](../../design/mockups/inbox-builder/b-03-waiting-for-me.html) — Waiting for me rows with native actions: idle, busy, write failed, Reply composer / refused / waiting, not yet run, empty; `track` and `idea` ref rows.
- [`b-04-folder-states.html`](../../design/mockups/inbox-builder/b-04-folder-states.html) — empty root, empty folder, new folder, drag, move in progress, the menu changed (reload), a refused write, a failed read, delete, hidden folders shown, CLI unavailable, Move to folder ▸, the editor's Changed row with the new-folder and existing-folder lines, and the "folder was not created" line.

`02-inbox-menu.html` from the brainstorm predates ask #947 (its entries are automations); the B mockups draw folders that many automations write into.

## Intent

The Inbox stops being a list shaped by our filters and becomes a menu of folders the owner arranges. Automations write their artifacts into folders; the root folder is the Inbox itself, where everything lands unless its automation names another folder. Approvals get one pinned place, **Needs approval**, that never waits on a run and never loses an open approval. Messages aimed at the owner become one living artifact, **Waiting for me**, whose rows the owner closes one by one with exactly today's buttons. Each artifact is managed where it is read: its ⋯ menu runs the existing automation verbs.

## Goals

1. Folder config: a tree of folders kept in the database, written only by the Go CLI with a per-tree `revision` compare-and-set; the Desktop edits it through the CLI.
2. Root folder first and undeletable; **Needs approval** pinned under it; owner folders with title, icon, parent, position and hidden; nesting, drag to reorder and re-parent; an unread count per folder.
3. `folder` on `output.inbox` (the field A reserves) and a per-automation folder (its **route**); creating a folder from the editor on save; deleting a folder moves its contents to the parent.
4. Needs approval: the built-in recipe `needs-approval` (no `llm()`), the `approval` trigger fired on every state change of a row that is or was an open approval and on reminder created / due, Desktop-added actions, the native card fallback, the render-time state check.
5. Waiting for me: a built-in over the attention detector, one living artifact, on the `sync` trigger after the detector.
6. Native row actions for a list row `ref`, at parity with today's per-kind card actions, plus **Reply…** on Slack, Jira and Linear items that proposes a reply into Needs approval (ask #445).
7. The ⋯ menu on artifacts and folders, **+ New artifact…**, the root's ⋯ with Learned Rules and Assistant Profile, the header's **?**.
8. The five filters (and the **All** mix) go; existing content shows in folders per the umbrella's mapping.

## Non-goals

- The block schema, its renderer, `blocks`/`key` on `output.inbox`, living upsert and removal by key, the Look step — sub-project A.
- Rebuilding Morning brief, Track my threads and Idea finder on blocks — sub-project C. B shows their current content in the root until then (ask #445).
- People and Catch Up — sub-project D. B's `DefaultFolder` field is what D uses to put People in its own folder.
- The phone's Inbox (#1170). A folder is a Mac concept in v1; the phone keeps its current Inbox slice.
- Dragging an artifact onto a folder. **Move to folder ▸** moves the automation; dragging single artifacts is v2 *(agent's call)*.
- Sharing a folder's look: a folder has no look of its own (umbrella).

## The model

### Folders

A folder row: `id`, `kind` (`root` | `approvals` | `owner`), `parent_id`, `slug`, `title`, `icon`, `position`, `hidden`.

- **Root** (`kind='root'`, title "Inbox", slug `inbox`): exactly one, `parent_id NULL`, always first, cannot be renamed, moved, hidden or deleted. Every other folder descends from it.
- **Needs approval** (`kind='approvals'`, slug `needs-approval`): exactly one, a child of the root pinned at position 0; cannot be moved, hidden, deleted or renamed; its icon is fixed. No owner folder can be its child *(agent's call: an approval must be one click from the root and never sit inside a hidden branch)*.
- **Owner folders** (`kind='owner'`): title 1–60 characters after trimming, no control characters, unique among siblings (case-insensitive); icon from a fixed allowlist of SF Symbol names (`InboxFolderIcons`, about 24, e.g. `folder`, `tray`, `flag`, `bolt`, `person.2`, `doc.text`, `calendar`, `shippingbox`, `lightbulb`, `bell`) or empty (= `folder`); `hidden` 0/1. Depth at most 3 below the root; at most 100 owner folders *(agent's call: limits keep the menu readable and the CLI's validation finite)*.
- **Slug**: derived once from the title at creation (lowercase ASCII, `-` for anything else, a `-2`, `-3` suffix on a clash), unique across the tree, never changed by a rename. Recipes name a folder by slug (`output.inbox({folder: "release"})`), so renaming a folder never breaks a recipe *(agent's call)*.
- **Hidden**: a hidden folder and everything below it leave the menu (the root's ⋯ **Show Hidden Folders** brings them back, dimmed). Their artifacts still arrive and stay; their counts leave the sidebar badge.
- **Position**: an integer per sibling list, rewritten densely (0…n−1) by every move.

### Routes: which folder an automation writes into

- `inbox_folder_routes(automation_id, folder_id)`: the folder an automation's artifacts go to. No row = the root. A route is configuration of the owner's menu, **not** part of the recipe: moving an automation never changes its `approval_hash` and never asks for a confirmation *(agent's call: a folder is placement, not a permission; D26 binds schedule and budget, which change what a run does — a folder does not)*.
- A recipe may name a folder per artifact: `output.inbox({…, folder: "<slug>"})`. That artifact goes to the named folder when it exists, otherwise to the automation's route, and the run journal gets the line `folder "<slug>" not found — shown in <route title>` *(agent's call: a script never creates a folder — writing the owner's menu is not a recipe capability; a missing folder never fails a run)*.
- **The slug is resolved inside the commit transaction, not at the call.** `output.inbox` only checks the value's shape and buffers the slug (`db.AutomationOutput.FolderSlug`); `commitRunTx` looks it up in the same `BEGIN IMMEDIATE` transaction that writes the output and stores the id, or NULL (= follow the route) with the journal line when the folder is gone. A folder write is also a `BEGIN IMMEDIATE` transaction, so a delete either commits before the run's commit (the lookup misses → route) or after it (the delete moves the artifact up) — never between lookup and insert, so the `folder_id` foreign key can never fail a run's commit *(agent's call)*. `ON DELETE SET NULL` on the column stays as the net for any other delete. A dry run resolves the slug at the call for its preview only and writes nothing.
- Effective folder of an artifact = its explicit folder (`automation_outputs.folder_id`) ?? its automation's route ?? the root. One SQL view, `inbox_artifact_folders(output_id, folder_id)`, computes it; the Go CLI and the Desktop both read the view, so there is no dual path.
- **Move to folder ▸** rewrites the route: every artifact that follows the route moves with it at once; artifacts with an explicit `folder` stay where the recipe put them.
- Built-ins: `builtin.Entry` gains `DefaultFolder` (`inbox` or `needs-approval` in B; D adds `people`). The built-in indexer seeds a route row for a built-in whose default is not the root, only when it has none, so the owner's later move is kept. `needs-approval`'s route is fixed: the CLI refuses to route it elsewhere and its ⋯ has no **Move to folder** *(agent's call)*.

### Writes: CLI only, compare-and-set on `revision`

- `inbox_folder_state` is a one-row table holding the tree's `revision` (starts at 1). Every folder or route write runs in one `BEGIN IMMEDIATE` transaction that checks `revision = <expected>`, writes, and sets `revision = revision + 1`. A mismatch writes nothing and returns `inboxfolders.ErrRevisionConflict`: the CLI exits 1 with the message `the Inbox menu changed — reload it and try again (revision <now>, you had <given>)`. The Desktop recognises the phrase `the Inbox menu changed`, re-reads the tree and shows the reload line; it never retries the write by itself *(agent's call: a drop computed against a stale tree could land in the wrong place)*.
- `--expect-revision` is required on every write; a write without it is refused before anything is read.
- Folder writes are owner verbs: refused under an AI agent's markers with `refuseUnderAgent` (AGENT-07's pattern) *(agent's call: the menu is the owner's arrangement; an agent proposing a folder goes through the editor's save, which the owner presses)*. `list` is free.
- The Desktop writes none of the folder tables (`inbox_folders`, `inbox_folder_state`, `inbox_folder_routes`) and none of `automation_outputs.folder_id`.

### Deleting a folder

One transaction: child folders move to the deleted folder's parent (appended after its siblings, keeping their order), routes pointing at it move to the parent, artifacts with it as explicit folder move to the parent (`folder_id = parent`), then the row goes. Nothing else is deleted *(umbrella, agent's call)*. The CLI reports the counts moved. A moved child whose title equals, ignoring case, a title among its new siblings is renamed " (2)", " (3)"… (cut to fit 60 characters; the slug stays), so sibling titles stay unique and the delete is never refused; the renames are reported with the counts *(controller default)*. Deleting a hidden folder brings its children that are not hidden themselves back into the menu and the badge (hidden belongs to the deleted folder only). Root and Needs approval are refused. `automation_outputs.folder_id` also carries `ON DELETE SET NULL` as a safety net (an artifact then follows its route).

### Creating a folder from the editor

When the owner tells the editor chat "put this into a Release folder", the agent proposes the folder name in its turn; the editor's pinned **Changed** row above the footer (sub-project A's row from ask #486; there is no save sheet since ask #475) lists it as its last line, "New folder: Release, in Inbox" ("Folder: Release" for an existing folder). The line is placement, not a hashed field: it never changes what the press confirms (AUTO-06), and it is shown only when the press saves. On **Save** (or **Save and Turn On**) the Desktop first saves the recipe as today (`automations save … --expect-content-hash`), then runs `inbox folders route <automation-id> --new-title Release --parent <id> --expect-revision <r>`, which creates the folder and the route in one transaction. A route failure after a saved recipe leaves the recipe saved and shows `Saved. The folder was not created: <reason>` with **Try Again** *(agent's call: the recipe is the owner's real work; a folder is redone with one press)*. No separate approval for the folder (umbrella).

How the agent proposes it: the editor chat's draft carries a `folder` suggestion (`{title, parent_slug}`) in the draft cache next to the recipe text; it is not part of the recipe. If A's editor stores drafts differently, the suggestion lives in the same place A keeps the Look step's state. The agent sees existing folders through a read tool `list_inbox_folders` on the `automation_editor` surface (title, slug, parent) so it reuses a folder instead of proposing a duplicate.

### Unread counts and the sidebar badge

Per artifact *(umbrella, agent's call)*: an artifact whose document has no row `ref` counts 1 when unread (`read_at` NULL, not done, not dismissed); an artifact with row refs counts the number of its rows that **wait on the owner** (table below), whatever its read state. A folder's count is the sum over its own artifacts (not its children's; the menu shows each folder's own number). Needs approval counts the approvals it shows. Legacy entries (ask #445) count as today's filter rows did.

The sidebar's Inbox badge becomes the sum of the counts of every folder that is not hidden *(agent's call: one rule the owner can check by adding the menu's numbers)*. Today's badge (`ActionStripViewModel.badgeCount`, read by `SidebarCountsViewModel`) counts proposals, due reminders, ideas to judge, unread messages, the latest unread briefing and built-in notices; the new sum keeps all of these (they sit in Needs approval and the root) and adds unread automation artifacts.

### What "open" means for a `ref` (render-time check)

The Desktop draws a row with a `ref` only while its record is **shown**, and counts it only while it **waits on the owner**. It reads both from the record at render time, in the same read as the folder, so a run that read its data before a Done and wrote after it cannot bring the row back (umbrella).

| `ref.kind` | Record | Shown while | Waits on the owner while |
|---|---|---|---|
| `inbox_item` | `inbox_items` | it matches `HomeFeedQueries.openMessageClause` (pending, actionable, not archived, a feed trigger, not snoozed past now, its Jira issue not deleted) | same |
| `track` | `tracks` | `dismissed_at = ''` and unread (`read_at IS NULL`) — Done is TRACKS-04's read | same |
| `idea` | `ideas` | `status` not in `merged`, `superseded` and not snoozed past now | `Idea.awaitsVerdict` |
| `reminder` | `reminders` | `status='pending' AND remind_at <= now` (REMIND-01) | same |
| `action` | `agent_actions` | `status='pending'`, or `status='failed'` with `dismissed_at=''` and not a settled session call (`AgentActionQueries.awaitingOwnerCount`'s predicate) | same |

A missing record (deleted) is not shown. The predicates live in one Swift type, `InboxRefState`, built from the existing queries' clauses (no new SQL text for `inbox_item`, `reminder` and `action`); the Go primitives of the two built-ins use the Go twins and a shared fixture pins that the two sides agree (see Test strategy).

## Needs approval

### The recipe

`needs-approval` is a built-in (`internal/automations/builtin`, recipe `recipes/needs-approval.md`):

- `trigger: {event: approval}` — a new event type, built-in only (below); `concurrency: 1`; `artifacts: living` (A); `outputs: [inbox]`; capability `builtin:approvals.list`.
- Script: one call `builtin.approvals.list()` (a read primitive, no AI) returns the open approvals — actions (id, tool, a one-line summary the registry already composes for cards, status, error, run label, `changed_at` = the latest of `created_at`, `decided_at`, `applied_at`) and due reminders (id, note, remind_at, Slack link). For each it writes one living artifact, key `action:<id>` or `reminder:<id>` (ask #964), with a heading (the tool's human name or "Reminder"), a text block (summary, or note), a list block with one row carrying the `ref` (`{kind: action|reminder, id}`), and the link. It calls `output.remove({key})` for every key it wrote before (read from `state`) that is no longer open. The shipped recipe has no `llm()` call (an `LLMCallSites` test pins it).
- Cost: zero AI tokens per run; a run is one indexed read and at most 50 writes (`MaxOutputsPerRun`). More than 50 open approvals: the run writes the 50 oldest and the native fallback shows the rest (below) *(agent's call)*.
- On/off: a new feature id `approval-cards` (default on) in `internal/features`, the built-in's `FeatureIDs`; ⋯ **Turn off** runs `features disable approval-cards`, as for every built-in (`refuseBuiltinOnOff`). It cannot be deleted. **Edit the look…** makes the owner copy (`.builtin/needs-approval.md`) through the existing built-in customisation; a look that adds AI text adds an `llm()` step and A's Look step says so before saving.

### The `approval` trigger

- **Shape.** `approval` is an entry of `automations.EventTypes` with no `where` fields (`EventFields["approval"] = {}`), accepted only when `Scope.IsBuiltin()` (the `syncTriggerAllowed` pattern, a new `approvalTriggerAllowed`) *(agent's call: an event type, not a new trigger kind, so neither `automations.trigger_kind` nor `automation_runs.trigger` needs a CHECK change and no table rebuild — the runs are `trigger='event'` with the standard event payload `event_json {"cycles":[<ref>…],"events":[{"type":"approval","ref":"action:7"}…],"count":N,"truncated":bool}` — one event per ref (`action:<id>`, `reminder:<id>` or `sweep`), at most 100 events and 100 cycles, `count` every fire merged, `truncated` once anything was dropped; the script sees `trigger.events[i].ref`; the recipe reads every open approval itself and does not depend on the refs)*. AUTO-* change approved in ask #961.
- **Where it fires.** Every write of an approval's state goes through one of seven `internal/db` functions: `InsertAgentAction`, `TransitionAgentAction`, `ApproveAgentActionWithArgs`, `DismissAgentAction` (`internal/db/agent_actions.go`; called by `tools.Registry` — `propose`, `approveWithArgs`, `apply`'s claim, `finishTransition`, `recordFailure`, `registry_session.go`'s expire / reject / dismiss — and by `cmd/actions.go`'s reject and stuck-claim release) and `InsertReminder`, `MarkReminderDone`, `SnoozeReminder` (`internal/db/reminders.go`). `MarkReminderDone` and `SnoozeReminder` today return only `error` and do not look at `RowsAffected`, so they change to `(changed bool, err error)`: Done updates only `WHERE id = ? AND status != 'done'` (a second Done changes nothing and fires nothing), Snooze reports `RowsAffected > 0` (an unknown id changes nothing). Their only Go callers today are `internal/db/reminders_test.go` (REMIND-01's guard `TestReminders_InsertListDueSnoozeDone`, updated for the new return without relaxing an assertion); the Desktop's Done/Snooze are GRDB writes and are unaffected. Each, after its statement succeeded and changed a row that is or was an open approval, calls the database's approval hook with the ref (`action:<id>` / `reminder:<id>`): an action inserted `pending`, a transition from or to `pending`/`failed` (Apply's `approved → executing` claim and `executing → applied` never call it), a dismiss, an approve with edits, every reminder write. `approvals.Fire` then skips, with one indexed read, an action whose row can never be an approval (`db.ActionCanBeApproval`: a workbench's direct-apply audit row unless External, the inbox surface's one-press `apply_track_action` row — a card's target button and a Reply wait for Approve and are approvals, per the STRIP-01 narrowing) — attributes that never change over a row's life; the per-cycle sweep catches anything this misses. *(Review of Task 7: a DirectApply or execute-trust write and an Inbox one-press `apply_track_action` would otherwise queue two or three runs each.)* The eighth writer, `InsertInboxButtonProposal` (`internal/db/agent_actions_button.go`), writes inside its own transaction and calls the hook after `Commit`. The hook is a field on `*db.DB` set once per process by `db.(*DB).SetApprovalHook(func(ref string))`; nil = no-op (tests, tools that never touch approvals) *(agent's call: the db layer is the one choke point every writer passes, including `cmd/actions.go`'s direct transitions; the hook does no I/O inside a transaction because these writers are autocommit)*. A guard test lists every `INSERT`/`UPDATE` of `agent_actions` and `reminders` in `internal/db` and fails when one does not call the hook.
- **What the hook does.** `approvals.Fire(d, ref, wake)` (new, `internal/automations/builtin/approvals.go`): when `needs-approval` is runnable, `db.EnqueueAutomationRun` with `Trigger: db.TriggerEvent` and the ref as the event; a run already queued takes the ref through `db.MergeQueuedAutomationRunEvents` (≤ 100 refs + `truncated`), so a burst of changes is one run (AUTO-09: a trigger only queues). Then `wake()`: in the daemon its in-process executor wake, elsewhere `wakeAutomations` (`cmd/automations_wake.go`, SIGUSR2). A failed enqueue or wake is logged (`approval hook: …`, ids only, FILES-01) and never fails the state change.
- **Desktop reminder writes.** Reminder Done / Snooze stay direct GRDB writes (STRIP-03). After one succeeds the Desktop runs `watchtower inbox approvals changed --ref reminder:<id>` (new, hidden), which calls `approvals.Fire`. A failure is not shown: the render-time check already hides the closed reminder, and the daemon sweep below redraws.
- **Reminder comes due.** REMIND-01 has no flip to "due". The daemon's new `phaseApprovalSweep` (each cycle, after `phaseUnsnooze`) compares the open approvals with the recipe's artifacts: an open approval without an artifact written at or after its `changed_at`, a reminder that came due, or an artifact whose record is closed → one `approvals.Fire(…, "sweep")`. It reads only; it never changes a reminder or an action.
- **Who runs it.** Built-ins run only at their sync slot today (`db.Automation.RunsAtSlot`, mirrored by `slotAutomationSQL`/`slotRunSQL` in `internal/db/automation_runs.go`). B narrows the predicate to "its trigger is `sync`" (a built-in or a Personal watch recipe), so an event-triggered built-in runs on the executor's poll right after the wake. `TestAutomation_RunsAtSlotMatchesSlotSQL` keeps the two forms equal.

### What the Desktop shows

The Needs approval folder lists, for every open approval (the table above) plus the built-in upgrade notices (`BuiltinUpgradeNotice`, today's "Needs your decision" first rows):

1. **The recipe's card**, when all hold: `approval-cards` is on, the latest `needs-approval` run did not fail, the artifact `action:<id>` / `reminder:<id>` exists, and its `written_at` (A) is at or after the approval's `changed_at`.
2. Otherwise **the native card**: today's `AgentActionCardView` for an action (`SaveAutomationProposalPane` for a `save_automation` proposal), today's reminder card for a reminder, today's notice card with **Retry** for a notice.

So an approval never waits on a run, a failed run never hides one, and a closed one leaves at the next read even before the run deletes its artifact (umbrella). Artifacts of closed approvals are never drawn, whatever the run did.

Actions on a recipe card are added by the Desktop through the `ref` hook (below) and cannot be removed by the look: an `action` row gets **Approve**, **Reject**, **Edit…** (opens the native card's argument editor in the reading pane) while pending, **Retry** and **Dismiss** after a failed apply; a `reminder` row gets **Done** and **Snooze 1h**. Each goes through today's function (`approve`, `reject`, `retry`, `dismiss` via `AgentActionFeed` → `watchtower actions …`; `markReminderDone`, `snoozeReminder`). The row shows the action's own summary text next to **Approve** whatever the look wrote (A's contract item 3).

States: recipe cards; native cards; mixed (a new action drawn natively above recipe cards until the run catches up); recipe off (a one-line note at the top: "Showing approvals in the standard card — Needs approval is off. **Turn On**", which enables the `approval-cards` feature); built-in stopped by the daemon under AUTO-08 while the feature is on ("…Needs approval was stopped after a run that would not end. **Turn On**", which resumes the stopped built-in — `features enable` of an enabled feature); last run failed (the same note with "the last run failed" and **Run History**); empty ("Nothing waits for your approval").

## Waiting for me

- A built-in `waiting-for-me` (`recipes/waiting-for-me.md`): `trigger: {sync: waiting_for_me}` — a new slot in `automations.SyncSlots` and `builtin.Slot` — run by a new daemon `phaseWaitingForMe` right after `phaseInbox` (`internal/daemon/daemon.go`); `concurrency: 1`; `artifacts: living`; `outputs: [inbox]`; capability `builtin:attention.waiting`; `FeatureIDs: ["secretary-inbox"]` (attention detection off = nothing to wait on); `DefaultFolder: inbox`; `RunNow: true`.
- `builtin.attention.waiting()` (no AI) returns the open items of `inbox_items` by the Go twin of `HomeFeedQueries.openMessageClause`, newest first, at most 200 (`InboxQueries.openMessageLimit`): id, who, where, the text (plain, ≤ 300 characters), trigger, permalink, age, folded channel messages count (INBOX-09).
- The script writes one living artifact, key `waiting`: title "Waiting for me", a list block with one row per item (title "<who> in <where>" for Slack (`#channel`, or "a DM") and "<who> — <where>" for a ticket ("<key> — assigned to you" / "— mentioned you") and mail ("<address> — <subject>"), subtitle the text as plain text, badge the age in hours or days, never minutes ("< 1 h", "3 h", "26 h", "2 days"; none for an unreadable time), tone `warning` past 24 hours, link the permalink, `ref {kind: inbox_item, id}`), `empty` "Nobody is waiting on you". No `llm()` (pinned).
- When it runs: after every sync cycle's detector. A native row action does not queue a run: the render-time check hides the closed row at once and the folder count drops with it; the next cycle rewrites the artifact without it *(agent's call, refining the umbrella's "after each native row action": an extra run would change nothing the owner sees)*. A snoozed row comes back at the first cycle after its snooze ends.
- Before its first successful run, and after a failed one, the root shows the **Messages** legacy entry (today's open-message list) in its place, so a ping never waits on a run *(agent's call, the Needs approval rule applied)*. While it is turned off nothing is shown: the owner turned attention detection off.

## Native row actions for a `ref`

For a row with a `ref` the Desktop draws, at the row's trailing edge, exactly the actions that kind's Inbox card has today (ask #959), through A's `ArtifactRefHooks.nativeActions` — with one addition, **Reply…** on `inbox_item` rows (asks #445 and #451):

| `ref.kind` | Actions (today's source) | Path |
|---|---|---|
| `inbox_item` | **Open in Slack/Mail/Jira/Linear** (with a permalink), **Discuss in Chat**, **Hand to Agent…**, **Done**, **Hide**, **Snooze ▾** (Tomorrow, In 3 days, Next week) — `InboxMessagePane`; plus **Reply…** for a Slack, Jira or Linear item (ask #445, below) | `messageDone`, `hideMessage`, `snoozeMessage` (`watchtower inbox resolve|dismiss|snooze`), `InboxCardCommand` for open/chat/agent; Reply: `watchtower actions propose` (below) |
| `track` | **Done**, ⋯ **Stop watching**, **Make a Task** (extracted track), **Go to Target** (linked custom track), **Delete…** (custom track) — `TrackCardActions` | `markTrackDone`, `stopWatching`, Make a Task as today, `CustomTrackControlling` |
| `idea` | the verdict buttons of `IdeaDetailPane` for the idea's state (**Approve**/**Reject**/**Not now ▾**, or **Activate**/**Drop**); pressing the row opens the full `IdeaDetailPane` in the reading pane with **Merge…**, **Make a Task**, **Delete…** | `IdeasViewModel` as today (IDEA-04) |
| `reminder` | **Done**, **Snooze 1h**, the Slack message link | `markReminderDone`, `snoozeReminder` |
| `action` | **Approve**, **Reject**, **Edit…**; after a failed apply **Retry**, **Dismiss** | `approve`, `reject`, `retry`, `dismiss` (`AgentActionFeed`, STRIP-03) |

- **Restore** for a stopped track is not a row action in B: a stopped track is not shown (table above). The legacy Track my threads entry keeps today's Stopped fold with **Restore** (ask #445); how C's block version shows stopped tracks is C's.
- **Busy:** while a press on a row runs, that row's buttons are disabled with a small progress indicator (`ActionStripViewModel.isWriting(_:)`, keyed by the row's `InboxSelection`: `inbox_item` → `.message`, `track` → `.track`, `idea` → `.idea`, `reminder` → `.reminder`, `action` → `.proposal`).
- **Success:** the refresh after the write reads the record closed; the row leaves; the count drops.
- **Failure:** the row stays, with the error line under it and **Retry**, which repeats the same press. `ActionStripViewModel` gains `rowErrors: [InboxSelection: RowFailure]` (message + the press to repeat); today's strip-wide `lastError` stays for read failures only *(agent's call: a failed Done must be visible on the row it belongs to)*. `AgentActionFeed`'s own per-row errors (`rowErrors`) are shown the same way.
- **Duplicates:** on a row with a `ref` the native action wins; the recipe's row actions of the same kind are not drawn (`nativeKinds`), so a ping has one **Open** and one **Reply**. Per kind: `inbox_item` suppresses the recipe's `open`, `chat`, `agent`, and `reply` when the item has a native Reply (Slack, Jira, Linear; a mail item keeps the recipe's `reply`, which queues an automation run as today); `track` and `idea` suppress the recipe's `target` (A's new kind) because **Make a Task** is native; `reminder` suppresses `open`; `action` suppresses nothing (A refuses recipe actions next to an action ref's Approve only by built-in origin).
- **Preview:** in A's `.preview` mode native actions are drawn disabled.
- Native actions never grant a permission. All but **Reply…** are buttons that already exist on today's card; **Reply…** adds one proposal path (below), which never sends anything by itself.

### Reply from a row (asks #445, #451)

The owner chose Reply in ask #445 and approved the contract changes it needs (AGENT-03/AGENT-07, the STRIP-01 narrowing) in ask #451. **v1:** Reply is a native action on every `inbox_item` ref row — Waiting for me's rows and `inbox_item` rows in any other artifact (the matrix's first row) — and the message card of the **Messages** legacy entry whenever it stands in for Waiting for me (before its first run, after a failed run), so the approved Reply never disappears with a failed run *(agent's call, ask #457 review)*.


- **Reply matrix — historical** (ask #451 was approved in full, so only the first row applies; the rest records the fallbacks the owner asked about, including the mixed case). Reply needed two of ask #451's items: the AGENT-03/AGENT-07 amendment (G) and the STRIP-01 Reply narrowing (N). Whether Waiting for me exists (the STRIP-01 built-in wording, B) decides only where Reply is drawn. APPROVAL-01 does not change whether Reply exists: a Reply proposal is a pending action like any other and Needs approval shows it — as the recipe's card or, if APPROVAL-01 or STRIP-01's built-in wording is refused, as today's native card.

  | G (AGENT-03/07) | N (Reply narrowing) | B (STRIP-01 built-ins) | Reply exists? | On which rows | Plan |
  |---|---|---|---|---|---|
  | approved | approved | approved | yes | every `inbox_item` ref row: Waiting for me's rows, and `inbox_item` rows in any other artifact | Tasks 9, 13, 18 run |
  | approved | approved | refused | yes | `inbox_item` ref rows in other artifacts only (an owner recipe that lists pings; A allows `inbox_item` refs from any recipe). Waiting for me does not exist, and the Messages legacy entry keeps today's message card unchanged, without Reply — a legacy entry is today's pane, not a native-row host *(agent's call: Reply is a native action of the `inbox_item` kind, not of Waiting for me; it is not grafted onto a legacy pane)*. With no such recipe, Reply is not visible anywhere | Task 9 dropped; Task 18 runs without the Waiting for me fixtures; Task 13 runs |
  | approved | refused | any | no | — (a Reply proposal would be hidden from Needs approval by the `surface='inbox'` exclusion) | Task 18 dropped |
  | refused | approved | any | no | — (the Reply tools are not on the `inbox` surface) | Task 18 dropped |
  | refused | refused | any | no | — | Task 18 dropped |

  Where Reply does not exist, every `inbox_item` row has exactly today's message-card set (Open, Discuss in Chat, Hand to Agent…, Done, Hide, Snooze ▾) and a recipe's own `reply` action stays drawn on it (no native Reply to win over it).
- **Which items.** By `inbox_items.trigger_type`: Slack (`mention`, `dm`, `thread_reply`, `reaction`) → `send_slack_message`; Jira (`jira_assigned`, `jira_comment_mention`) → `add_jira_comment`; Linear (`linear_assigned`, `linear_comment_mention`) → `add_linear_comment`. Mail (`email_received`) has no write path in Watchtower, so its row has no **Reply…** (it keeps **Open in Mail**). A Slack item without a permalink, or a Jira/Linear item without an issue key, has no **Reply…** either *(the owner's rule in ask #445: no Reply unless a write path exists)*.
- **The press.** **Reply…** opens a one-line composer under the row (plain text, ⌘↩ to propose, Esc to cancel; the owner types it — no AI draft in v1 *(agent's call)*). **Propose Reply** runs `watchtower actions propose --tool <tool> --surface inbox --context inbox_item:<id> --args <json>` without `--approve`. Args are bound to the item's own place: Slack `{"channel": <the item's permalink>, "account_id": <its account>, "text", "reason": "Reply from <host title>"}` (the title of the artifact the row is on, or "Messages" for the legacy entry — e.g. "Reply from Waiting for me") — a message link replies in its thread, a reply's link in the parent thread, and `send_slack_message`'s Normalize pins the recipient at propose time exactly as `docs/features/slack-send.md` says (no re-resolution at Execute); Jira `{"key": <issue key>, "account_id", "body", "reason"}`; Linear `{"key", "account_id", "body", "reason"}`.
- **Where it lands.** The proposal is a pending `agent_actions` row; the approval hook draws it in **Needs approval** like any proposal, with the item's label ("Reply to colleague A in #acme-release"). Nothing is sent until the owner presses **Approve** there (`actions approve`, the owner's Confirm and AGENT-05's claim as today). **Edit…** there edits the text (`send_slack_message` allows `text` and `candidate`). Rejecting it leaves the item open.
- **The row afterwards.** The row stays (the item is still open) with the caption "Reply waiting for approval" and **Reply…** disabled while that proposal is pending (read from `agent_actions` by `context_type='inbox_item'`). Once the reply is posted, INBOX-02 resolves the item at the next sync (the owner's own reply in the thread / comment on the issue) and the row leaves.
- **Failure.** A refused proposal (validation, unknown channel, a deleted issue) keeps the composer open with the CLI's message under it; nothing is written.
- **Code changes it needs.** `send_slack_message`, `add_jira_comment` and `add_linear_comment` gain `tools.InboxSurface` in `Surfaces`. `actions propose` gains `--context <type>:<id>` and refuses `--approve` for the three Reply tools only — a new list `tools.InboxReplyTools` = `send_slack_message`, `add_jira_comment`, `add_linear_comment` ("a reply is approved in Needs approval"); `apply_track_action`'s one-press `--approve` is unchanged *(narrowest refusal: it covers exactly the tools this spec adds to the surface)* so a Reply can never be proposed and applied in one press. The strip/badge rule that leaves out `surface='inbox'` rows (`AgentActionQueries.fetchStrip` / `awaitingOwnerCount`, C1) narrows to the one-press tool `apply_track_action`, so a Reply proposal shows in Needs approval and counts in the badge.

## The Inbox screen

Three columns *(agent's call: the existing `InboxSplitView` list + reading pane, with the folder menu as a new first column)*:

1. **Folder menu** (`InboxFolderMenu`, ~220 pt, resizable): the root "Inbox" with its count, Needs approval with its count, the owner folders as a disclosure tree with icons and counts; **+ New Folder** and **+ New Artifact…** at the bottom. Hidden folders are absent (or dimmed under **Show Hidden Folders**). The header keeps the **?** (`ReactionCheatSheetView`, `InboxAuxPane.reactionCommands`).
2. **Artifact list** of the selected folder, newest change first (A's `changed_at`), with unread dots; in the root, Waiting for me is pinned first while it has open rows *(agent's call)*; legacy entries (ask #445) interleave by their own time.
3. **Reading pane**: the selected artifact through A's `ArtifactView` (with B's ref hooks), or a legacy entry's existing pane, or a native card. The artifact header carries **⋯**.

**Menus:**

- **Artifact ⋯** (from the artifact header and the list row's context menu): **Run Now**, **Edit What It Collects…**, **Edit the Look…**, **Schedule…**, **Move to Folder ▸** (the tree, current folder checked), **Turn Off**, **Run History**, **Delete…**. Each calls the same view-model verb the Automations tab calls, so both share one per-automation busy guard and Delete's cleanup: `AutomationsViewModel.runNow` (built-ins: their `BuiltinAutomationCardModel.runNow`, from `builtinCard(_:)`), A's `AppState.openAutomationEditor(_:step:)` with `.collects` / `.look` / `.schedule`, `inbox folders route`, `AutomationsViewModel.setEnabled` (built-ins: the card's `setEnabled` through `AppState.setBuiltinEnabled`, i.e. `features disable`), the Automations tab's run history for the automation (`AutomationsViewModel.open(automationID:runID:)`), `AutomationsViewModel.delete` behind today's confirmation. Those verbs return a result (`done` / `busy` / `failed(message)`) so the failure shows on the artifact header as this press's own *(agent's call: today they report only into the tab-wide `lastError`, and `runNow`'s `false` also means busy)*. A built-in has no **Delete…**; `needs-approval` has no **Move to Folder**; a built-in without Run Now (`Entry.RunNow` false) has none. Done / Dismiss stay on the card as today.
- **Folder ⋯** (owner folder; also its context menu): **Rename…**, **Icon ▸**, **New Folder Inside**, **Hide** / **Show**, **Delete…** (inline confirmation: "Delete “Release”? Its 2 folders, 3 automations and 5 artifacts move to Inbox.").
- **Root ⋯**: **Learned Rules**, **Assistant Profile** (both open in the reading pane, as `InboxAuxPane.learnedRules` / `.profile` do today), **Show Hidden Folders**, **New Folder**. **Find Ideas in Past Messages…** moves to the Idea finder entry's ⋯ (today it sits in the Ideas filter's menu).
- **Needs approval ⋯**: **Edit the Look…**, **Turn Off** / **Turn On**, **Run History**.
- **+ New Artifact…** opens the Automations editor's new flow (`AutomationsViewModel.showNew`) at "what should it collect", with the current folder preselected as its route; saving routes it there (the Changed row's "Folder: <title>" line above).

**Drag** (owner folders only): drop between siblings reorders (`inbox folders move <id> --parent <same> --position <n>`); drop onto a folder makes it the last child. Root and Needs approval cannot be dragged, and nothing can be dropped above Needs approval or into it; a drop deeper than the depth limit is refused before the call (the drop indicator does not appear). While the call runs the menu is read-only and shows the dragged row in its new place dimmed; on success the tree re-reads; on a revision conflict the tree re-reads and a line under the menu says "The menu changed — reloaded. Drag again if needed." (5 seconds, or until the next drag).

**States** (each is a DesignShotCatalog shot, plan Task 1):

| State | What the owner sees |
|---|---|
| Root, empty | "Your Inbox is empty" + one line: "Automations put what they make here. **New Artifact…**" (`EmptyStateCopyTable` key `inbox`) |
| Owner folder, empty | "Nothing in Release yet" + "Move an automation here from its ⋯ menu, or make a new one. **New Artifact…**" (key `inboxFolder`) |
| Needs approval, empty | "Nothing waits for your approval" (key `inboxApprovals`) |
| Needs approval, native fallback | native cards; the off / stopped / failed note when that is the cause |
| Needs approval, recipe cards | every approval drawn by the recipe, actions added by the Desktop |
| Needs approval, mixed | native card(s) above recipe cards |
| Needs approval, upgrade notice | today's built-in notice card with **Retry**, first |
| Needs approval, off | "Showing approvals in the standard card — Needs approval is off." + **Turn On** |
| Needs approval, built-in stopped | "Showing approvals in the standard card — Needs approval was stopped after a run that would not end." + its own **Turn On** (resumes the stopped built-in) |
| Needs approval, last run failed | "Showing approvals in the standard card — the last run failed." + **Run History** |
| Needs approval, off note's Turn On failed | the reason under the off note (both buttons call `AppState.setBuiltinEnabled(["approval-cards"], on: true)`, the built-in card's Turn On: the `features enable` error, or "Feature changes are being applied in Settings — try again"); the note stays. Never read from `FeatureManagerService.loadError`, which other screens share |
| Needs approval, stopped note's Turn On failed | the reason `resumeStoppedBuiltin` returned, under the stopped note; the note stays |
| Needs approval, turned on but not restarted | the note leaves once the feature reads on; the app-wide daemon banner keeps "The background sync did not restart: …" with **Retry** until a start or restart succeeds (`setBuiltinEnabled` sets `daemonStartFailure` from the restart's own error; the same banner after a built-in card's Turn On in the Automations tab; Decisions, ask #503) |
| Row busy | the row's buttons disabled, progress at its trailing edge |
| Row write failed | the row stays, red error line, **Retry** |
| Reply composer open | one-line field under the row, **Propose Reply** / **Cancel**, the line "Goes to Needs approval — nothing is sent until you approve it" |
| Reply refused | the composer stays open with the CLI's message under it |
| Messages stand-in with Reply | the Messages legacy entry's message card shows **Reply…** like a Waiting for me row |
| Reply waiting for approval | the row stays with the caption "Reply waiting for approval", **Reply…** disabled |
| Waiting for me, not yet run | the Messages legacy entry in its place |
| Waiting for me, empty | "Nobody is waiting on you" |
| Menu changed (CAS) | the reload line under the menu |
| Drag in progress | drop indicator; refused drop has none |
| Move in progress | the menu read-only, the moved folder dimmed in its new place |
| Folder delete confirmation | inline under the folder row |
| Hidden folders shown | dimmed rows with a "Hidden" caption |
| Menu write refused | the inline field or row stays with the CLI's message under it (e.g. a duplicate title); the tree unchanged |
| Folder read failed | the previous tree and list stay; today's strip error line |
| CLI unavailable | menu edits disabled with "The watchtower CLI isn't available" (`CLIRunnerError.binaryNotFound`), reading still works |
| Artifact ⋯ entry failed | the CLI's text on the artifact header |
| Changed row, new folder | the editor's pinned Changed row ends with "New folder: Release, in Inbox" (or "Folder: Release" for an existing folder) |
| Automations tab, built-in Turn On not restarted | the app-wide daemon banner "The background sync did not restart: …" with **Retry** above the built-in card |
| Folder not created after save | "Saved. The folder was not created: <reason>" + **Try Again** |

## Moving today's Inbox into folders

Nothing is copied or rewritten in the database: content shows where the mapping says because of the routes and the reading rules *(agent's call)*.

| Today | After B |
|---|---|
| Automations filter: automation outputs | their automation's route — root unless moved; markdown shown as a text block (A) |
| Automations filter: proposals, due reminders; All: built-in notices | Needs approval |
| Messages filter (`inbox_items`) | Waiting for me in the root (legacy Messages entry until its first run) |
| Day filter (briefings, day plans) | root: legacy **Morning brief** entries, one per date, today's `InboxDayPane` (ask #445) |
| Tracks filter | root: legacy **Track my threads** entry, today's track list with its Stopped fold and `InboxTrackPane` (ask #445) |
| Ideas filter | root: legacy **Idea finder** entry, today's idea list, New idea row and `InboxIdeaPane`, with **Find Ideas in Past Messages…** in its ⋯ (ask #445) |
| All | gone: the root is not a mix of every folder |
| `inbox.filter` default | replaced by `inbox.folder` (the selected folder id); an old value opens the root |
| `InboxRoute` (nav hosts `briefings`, `dayPlan`, `tracks`, `ideas`; Home's Getting ready links) | a folder plus a selection: the root with the day / Track my threads / Idea finder legacy entry selected |

Legacy entries are Desktop-only wrappers over today's queries and panes (`InboxFeedQueries.read` keeps feeding them); sub-project C retires each when its built-in writes blocks.

## Data model and migration

One migration, number = next free at implementation time (the plan calls it `00NNN_inbox_folders.sql`; in-flight branches may take 00172+). No table rebuild.

```sql
CREATE TABLE inbox_folders (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    kind       TEXT NOT NULL CHECK (kind IN ('root','approvals','owner')),
    parent_id  INTEGER REFERENCES inbox_folders(id),   -- NULL only for the root
    slug       TEXT NOT NULL UNIQUE,
    title      TEXT NOT NULL,
    icon       TEXT NOT NULL DEFAULT '',
    position   INTEGER NOT NULL DEFAULT 0,
    hidden     INTEGER NOT NULL DEFAULT 0 CHECK (hidden IN (0,1)),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    CHECK ((kind = 'root') = (parent_id IS NULL))
);
CREATE UNIQUE INDEX idx_inbox_folders_one_root ON inbox_folders(kind) WHERE kind IN ('root','approvals');
CREATE INDEX idx_inbox_folders_parent ON inbox_folders(parent_id, position);

CREATE TABLE inbox_folder_state (
    id       INTEGER PRIMARY KEY CHECK (id = 1),
    revision INTEGER NOT NULL
);

CREATE TABLE inbox_folder_routes (
    automation_id INTEGER PRIMARY KEY REFERENCES automations(id) ON DELETE CASCADE,
    folder_id     INTEGER NOT NULL REFERENCES inbox_folders(id)
);

ALTER TABLE automation_outputs ADD COLUMN folder_id INTEGER REFERENCES inbox_folders(id) ON DELETE SET NULL;

CREATE VIEW inbox_artifact_folders AS
SELECT o.id AS output_id,
       COALESCE(o.folder_id, r.folder_id, (SELECT id FROM inbox_folders WHERE kind = 'root')) AS folder_id
FROM automation_outputs o LEFT JOIN inbox_folder_routes r ON r.automation_id = o.automation_id
WHERE o.kind = 'inbox';
```

Seeds: the root (`inbox`, "Inbox", position 0), Needs approval (`needs-approval`, "Needs approval", parent = root, position 0), `inbox_folder_state(1, 1)`. The `needs-approval` route is seeded by the built-in indexer when the built-in's row first exists. Mirrored into `internal/db/schema.sql`; new tables in `TestAllTablesExist`; golden snapshot and `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` regenerated. Purge (`db.PurgeSteps`) and source deletions are untouched: folders hold no source data. Down migration drops the view, the tables and the column.

## CLI

All under the existing `watchtower inbox` group (`cmd/inbox.go`), new file `cmd/inbox_folders.go`. Writes require `--expect-revision`, are refused under an agent marker, and with `--json` print one JSON object as the last stdout line.

| Command | Does |
|---|---|
| `inbox folders list [--json]` | the tree |
| `inbox folders create --title T [--icon I] [--parent ID] [--position N] --expect-revision R [--json]` | a new owner folder (parent default root, position default last) |
| `inbox folders update <id> [--title T] [--icon I] [--hidden=true\|false] --expect-revision R [--json]` | rename, icon, hide |
| `inbox folders move <id> --parent ID --position N --expect-revision R [--json]` | reorder / re-parent |
| `inbox folders delete <id> --expect-revision R [--json]` | delete, contents move up |
| `inbox folders route <automation-id> (--folder ID \| --new-title T [--new-icon I] [--parent ID]) --expect-revision R [--json]` | set an automation's folder, creating it with `--new-title` |
| `inbox approvals changed --ref <kind>:<id>` (hidden) | `approvals.Fire` for a Desktop reminder write; prints nothing |

Pinned `--json` keys (each with a `TestInboxFoldersCLI_<Verb>JSONKeys` test, the `automationJSONKeys` pattern in `cmd/automations_test.go`):

- folder object: `id`, `kind`, `slug`, `title`, `icon`, `parent_id` (null for the root), `position`, `hidden`, `automation_ids` (routed automations, ascending).
- `list`: `revision`, `folders` (pre-order: root, then each folder followed by its children by position).
- `create` / `update` / `move`: `revision` (the new one), `folder`.
- `delete`: `revision`, `moved` → `folders`, `automations`, `artifacts`, `renamed` (`id`, `from`, `to` of each moved folder renamed to keep sibling titles unique; an empty array when nothing was renamed).
- `route`: `revision`, `automation_id`, `folder`, `created` (bool).

Errors (exit 1, message on stderr, nothing written): `the Inbox menu changed — reload it and try again (revision N, you had M)`; `--expect-revision is required`; `the Inbox folder can't be changed` (root); `Needs approval can't be moved, renamed, hidden or deleted`; `a folder named "T" already exists here`; `folders nest at most 3 deep`; `unknown icon "x"`; `no folder N`; `no automation N`; `Needs approval's automation stays in Needs approval`; and the agent refusal.

## Failure paths

| Failure | Result |
|---|---|
| A recipe names a folder that does not exist, or was deleted after the call and before the run's commit | the artifact follows the route (root by default), the journal says so, the run's status is unaffected (resolved in the commit transaction) |
| A folder write loses the revision race | nothing written; the Desktop re-reads and shows "The menu changed — reloaded"; no automatic retry |
| The route call after an editor save fails | the recipe stays saved; "Saved. The folder was not created: <reason>" with **Try Again** |
| The approval hook cannot enqueue or wake | logged (ids only); the state change stands; the per-cycle sweep redraws; the native card shows the approval meanwhile |
| A Desktop reminder write's `inbox approvals changed` fails | not shown; render-time check hides the closed reminder; the sweep redraws |
| The `needs-approval` run fails, is off, is behind or capped at 50 | native cards for every approval it did not draw currently |
| The `waiting-for-me` run fails or never ran | the Messages legacy entry stands in |
| A native row write fails | the row stays with its error and **Retry** |
| A Reply proposal is refused | the composer stays open with the CLI's message; no row written |
| The CLI is missing | menu and row writes disabled with the message; reading works |
| A folder write is refused (validation, database busy) or its answer does not decode | the CLI's message under the field or row; nothing assumed written (an undecodable answer re-reads the tree) |
| Turn On on the Needs approval note fails | the reason under that note (off or stopped); the note stays |
| Turn On enabled the feature but the daemon restart failed | the app-wide daemon banner with **Retry** after the note leaves |
| An artifact ⋯ press races the Automations tab on the same automation | `busy`: no second call, "Another change to this automation is running — try again" on the header |
| An artifact ⋯ entry fails | the error on the artifact header; the artifact unchanged |
| The approval hook's wake fails | logged (ids only); the queued run starts at the next wake or cycle |
| The Desktop's folder read fails | the previous tree and list stay with today's strip error line |
| An older database without the folder tables | the Desktop reads a root-only tree; nothing crashes |

## Inventory contracts touched

Approved already:


- **AUTO-*** (ask #961): the `approval` trigger (an event type, built-in only), `folder` on `output.inbox`, `concurrency: 1` for living outputs. AUTO-09 holds: `approvals.Fire` only queues (`db.EnqueueAutomationRun` / merge) and wakes. AUTO-05 holds (concurrency 1). AUTO-06 holds: both built-ins are shipped bytes confirmed by `ConfirmShippedBuiltin`; their owner copies need the owner. Changelog lines in `docs/inventory/automations.md` in the commits that land the code; the built-in note's "built-ins run only at their slot" sentence is amended with the `RunsAtSlot` narrowing (covered by ask #961's approval trigger, which cannot work otherwise).
- **INBOX-02, INBOX-09** (ask #952): guarantees unchanged — the detector, its auto-resolve and watermark are not touched. A changelog line notes that open items are now shown by Waiting for me (and the Messages legacy entry), and that an auto-resolved item leaves the artifact at the next read through the render-time check. No Observable change, no guard change.

Approved in ask #451 (the owner approved every item):

- **AGENT-03, AGENT-07** (amend, Reply from a row; the feature from ask #445, the contract change approved in ask #451): AGENT-03 — `send_slack_message`, `add_jira_comment` and `add_linear_comment` join the owner-only `inbox` surface; they stay External, the `inbox` surface is still no trust place (`trustSurfaceErr`), so every Reply waits for the owner's Approve; `actions propose --approve` is refused for the three Reply tools (`tools.InboxReplyTools`) only. AGENT-07 — `actions propose` without `--approve` stays refused under every agent marker and needs no Confirm (nothing is applied); the Approve in Needs approval keeps `actions approve`'s marker refusal and Confirm. AGENT-01 and AGENT-05 unchanged (one press = one pending row; apply once). The C1 changelog note in `docs/inventory/agent-actions.md` ("its one tool `apply_track_action`") gets the new tools and the narrowed strip exclusion. Guards added: `TestActionsPropose_RefusesApproveForReplyTools`, `TestActionsPropose_ReplyRecordsOnePendingRow`, `cmd/actions_registry_test.go` registry pin of the three tools' surfaces, `AgentActionQueriesTests.testStripShowsInboxReplyProposals`; `testStripAndBadgeLeaveOutInboxPressRows` keeps its name and still holds for `apply_track_action`.

- **STRIP-01** (amend; ask #451): the Inbox's gesture-gated tables keep their rule; its C1 sentence "`surface='inbox'` rows are left out of the strip and badge" narrows to `apply_track_action` rows (a Reply proposal from a row is gesture-gated — the owner typed and pressed it — and shows in Needs approval); but two built-ins now write `automation_outputs` rows the owner did not make by a gesture of their own: `needs-approval` (one per gesture-gated approval — a view of them) and `waiting-for-me` (from the attention detector's ambient findings). Wording to propose: the two built-in artifacts are views of their records (approvals; `inbox_items`), their rows act only on those records, and no other built-in may write a `ref` of kind `action` or `reminder` (A's rule). The "Automations filter" and "All mix" wording goes.
- **STRIP-02** (amend wording): `refresh()` stays one pure read; the Desktop's writes are unchanged (plus nothing for folders — the folder tables are CLI-written configuration, not an item store); "There is no strip-local table" gains "the folder tables hold the menu's arrangement only, never an item".
- **STRIP-03** (amend wording): native row actions call the same functions; the Desktop's reminder writes additionally run `inbox approvals changed`, which only queues. No new decision path.
- **INBOX-05** (amend Observable): the Learned Rules pane is reached from the root folder's ⋯ instead of the strip's ⋯; the store, its readers and writers are unchanged. Guards unchanged.
- **New entries** (each a new principle, so its own number; approved in ask #451): **FOLDER-01 — Deleting a folder never deletes content** (children, routes and artifacts move to the parent; guard `TestFolder01_DeleteMovesContentsUp`); **APPROVAL-01 — An open approval is always on screen, a closed one never** (native fallback when the recipe is off, failed, behind or capped; render-time check; guards `test_APPROVAL_01_native_card_when_recipe_off`, `…_when_behind`, `…_closed_never_drawn`).

**Summary by entry** (the plan's **Contracts touched** table carries the task and the guard names for each):

- New: FOLDER-01, APPROVAL-01.
- Amended: STRIP-01 (built-in wording, filter wording, Reply narrowing), STRIP-02, STRIP-03, INBOX-05, AGENT-03, AGENT-07, AGENT-04 (note), AUTO-09 (changelog line), INBOX-02/09 (changelog note).
- Enforced, guards must stay green: REMIND-01 (guard note on the new `changed` return), AUTO-01, AUTO-04, AUTO-05, AUTO-06, AUTO-08 (read only), AUTO-11, AUTO-12, AGENT-05, IDEA-04, TRACKS-04/07, FEAT-01, FEAT-03, FEAT-04.
- Unaffected: PROJ-01..22 and every other inventory file.

### If an item of ask #451 had been refused (historical)

Ask #451 was approved in full, so this table no longer applies; it records the fallbacks considered before the answer. Each row is one amendment in ask #451, refused on its own. Before the answer, a refusal of the STRIP-01 built-in wording or of APPROVAL-01 would have blocked Needs approval and Waiting for me — B's core — and the plan tasks that build them were gated on ask #451 until it was approved; those gates are cleared.

| Item refused | What B does instead | Plan tasks |
|---|---|---|
| **STRIP-01, the two built-ins' wording** (`needs-approval` and `waiting-for-me` write `automation_outputs` rows) | **Blocks B's core.** No built-in may write those rows: Needs approval shows only today's native cards (no recipe, no `approval` trigger, its look cannot be changed); Waiting for me does not exist and the root keeps the Messages legacy entry for good (today's card, no Reply — Reply then follows the Reply matrix's second row); native row actions apply only to `ref` rows of other built-ins (C's). The umbrella's goals 5 and "every Inbox item can be customised" for approvals are not met; the owner decides how to proceed | Tasks 7, 8, 9 dropped; Task 12 keeps only the native Needs approval and the Messages entry; Task 13 keeps the hooks without Waiting for me fixtures |
| **STRIP-01, the Reply narrowing**, **AGENT-03 / AGENT-07** (Reply), in every combination with each other and with the STRIP-01 built-in wording | see the **Reply matrix** under "Reply from a row": Reply exists only when both Reply items are approved; with the built-in wording refused it lives only on `inbox_item` rows of other artifacts | Task 18 per the matrix; Task 9 per the STRIP-01 built-in row above |
| **STRIP-02** (the folder tables are the menu's arrangement, not an item store) | Folders do not live in the database: the tree and its `revision` move to a CLI-written file `<workspace>/inbox-folders.json` (0600, atomic replace under a `fsutil.LockFile`, same CAS and error text); routes go with it; `automation_outputs.folder_id` stays (the automation's own table). The `inbox_artifact_folders` view is replaced by a resolver in Go and in Swift, pinned by a shared fixture (a dual path) | Task 2's tables and view replaced by the file store; Tasks 3, 10 adapted; others unchanged |
| **STRIP-03** (native row actions call today's functions; reminder writes also run `inbox approvals changed`) | Native row actions stay (they are today's paths); the Desktop's reminder Done/Snooze no longer run `inbox approvals changed`: Needs approval's recipe card for a reminder is redrawn by the per-cycle sweep; the render-time check still hides the closed reminder at once | Task 7 drops the hidden CLI; Task 13 drops the call |
| **INBOX-05** (Learned Rules reached from the root's ⋯) | Learned Rules (and Assistant Profile) get a header button beside **?** instead of the root's ⋯ | Task 11 adjusted |
| **FOLDER-01** (new entry: deleting a folder never deletes content) | The behaviour stays (an umbrella decision); it is just not a locked contract: no inventory entry, the guard keeps an ordinary test name. If the owner instead refuses the behaviour, the delete semantics reopen as a spec question | Task 3 unchanged (or reopened) and drops the entry it would have added |
| **APPROVAL-01** (new entry: an open approval is always on screen, a closed one never) | **Blocks B's core.** Needs approval's design rests on this guarantee (native fallback + render-time check). Refused as a contract, the recipe-drawn Needs approval is not built: approvals stay in today's native cards only, as in the STRIP-01 row | Tasks 7, 8 dropped; Task 12 keeps the native Needs approval only |

Unchanged and re-checked: REMIND-01 (the sweep reads only; nothing flips a reminder), REMIND-02, AGENT-05 (every decision still through `Registry`/`watchtower actions`), AGENT-07 (folder writes refused under an agent), TRACKS-04/07 and IDEA-04 (row actions are today's writes), OWNER-02 (the empty root still says why when the owner is unknown — the legacy day entry's placeholder rule moves with it).

## Test strategy

Go (inner loop per package):

- `internal/inboxfolders` (new): create / update / move / delete / route happy paths; CAS — a stale revision writes nothing, a missing `--expect-revision` is refused, two writers racing (two goroutines, one DB file) → exactly one wins; delete moves children (order kept), routes and explicit artifacts up and reports counts; refusals for root and Needs approval on every verb; depth limit at 3 and one past; 100 folders and one past; title of 60 runes and 61; empty and whitespace-only title; control characters; duplicate sibling title in another case; same title under another parent (allowed); slug clash suffixes; rename keeps the slug; unknown icon; moving a folder under its own descendant (refused); position past the end (clamped to last); position negative (refused).
- `internal/db`: the migration on an empty DB and on a DB with outputs (view puts them in the root); the view's three-way `COALESCE`; `ON DELETE SET NULL`; the approval hook called by each of the seven writers, and not called when the statement changed no row; the guard test that every `agent_actions`/`reminders` write in the package calls it; `TestAllTablesExist`, schema golden.
- `internal/automations` / `internal/db` folder race: a folder deleted after `output.inbox` and before `commitRunTx` → the run succeeds, the artifact follows its route, the journal line is written, no foreign-key error; a folder created between the call and the commit with the named slug → used.
- `internal/db` reminders: `MarkReminderDone` twice → `changed` true then false (one hook call); `SnoozeReminder` on an unknown id → false, no hook call.
- `internal/automations`: `approval` accepted for a built-in and refused for a Personal and a workbench recipe with a readable error; `where` on `approval` refused; `RunsAtSlot` narrowing with `TestAutomation_RunsAtSlotMatchesSlotSQL`; the `folder` field hook — an existing slug sets `folder_id`, an unknown slug leaves NULL and journals the line, a non-string refused, dry run records the slug without writing.
- `internal/automations/builtin`: `approvals.Fire` enqueues one run, a second fire merges into the queued run, 101 refs → 100 + `truncated`, not runnable (off / unconfirmed) → nothing queued and no error, enqueue error logged and returned to no caller; `needs-approval` and `waiting-for-me` recipes parse as built-ins, have no `llm()` call site, write the expected keys on a fixture, remove closed keys, cap at 50 with the oldest first; the primitives on degenerate input (no approvals, only reminders not yet due, an action whose args are not valid JSON, 0 and 200 and 201 open items, an item with empty text).
- `internal/daemon`: `phaseWaitingForMe` runs after `phaseInbox` in `runSync`'s order; `phaseApprovalSweep` fires for a newly due reminder, for an open approval with no or an older artifact, for an artifact of a closed record, and does not fire when everything matches.
- `cmd`: `actions propose` for each Reply tool records exactly one pending row with `surface='inbox'` and the `inbox_item` context, refuses `--approve` for the three Reply tools while `apply_track_action --approve` still works, refuses under agent markers, refuses a Slack reply whose channel link does not resolve (no row); pinned JSON keys for every `inbox folders` verb; agent-marker refusal; `inbox approvals changed` with a malformed ref (refused) and with the daemon not running (queued, exit 0).
- Dual-path fixture: `internal/inbox/testdata/open_items.json` (rows + expected open ids at a fixed now) read by the Go `attention.waiting` test and by Swift `InboxRefStateTests`, so the two open predicates cannot drift; the same pattern for actions (`awaitingOwnerCount`) and reminders.

Swift (`make test-swift FILTER=…`, Core where possible):

- `InboxFolderQueriesTests`: tree order, hidden subtree, artifacts per folder through the view, counts (unread artifact = 1, ref artifact = waiting rows, closed rows not counted, hidden folders out of the badge, a folder's count excludes its children).
- `InboxRefStateTests`: each kind shown / waits, a deleted record, a snoozed item at the snooze instant, a reminder at `remind_at == now`.
- `NeedsApprovalSelectionTests`: recipe card vs native per the four conditions; mixed; recipe off; last run failed; artifact older than the approval's change; more than 50.
- `InboxFoldersCLITests`: argument contract per verb, decoding the pinned keys, the conflict phrase mapped to `.menuChanged`.
- `InboxFolderMenuModelTests`: drag → move arguments; drop refused past depth; conflict → re-read + reload line, no retry; CLI missing → edits disabled.
- `InboxReplyTests`: `testReplyShownOnMessagesStandInBeforeFirstRun`, `testReplyShownOnMessagesStandInAfterFailedRun`, `testReplyGoneFromStandInOnceWaitingForMeSucceeds` (the stand-in leaves; Reply is then on Waiting for me's rows); `testReplyReasonNamesHost` — "Reply from Waiting for me", "Reply from Messages", and an owner artifact's own title; Reply shown per trigger type (four Slack, two Jira, two Linear → yes; `email_received`, missing permalink, missing key → no); the args per tool bound to the item's permalink / key and account; one propose call per press, none on Esc or empty text; pending proposal → caption and Reply disabled; refusal keeps the composer with the message; the recipe's `reply` suppressed exactly when the native Reply exists.
- `InboxRowActionsTests`: ref → `InboxSelection` mapping, the per-kind action set equals today's card's set (one test per kind against the card's own action list), busy, failure keeps the row with its error and Retry repeats the press, native kinds suppress the recipe's duplicates.
- `ActionStripViewModelTests` stays green, and its STRIP guards keep their names.
- DesignShotCatalog: every state in the table above, plus the Needs approval and Waiting for me states, rendered by `make desktop-shots`.

## Decisions

- Waiting for me rows get **Reply…**: a `send_slack_message` proposal bound to the item's own thread or channel (recipient pinned at propose), landing in Needs approval, never sent directly; Jira and Linear items reply through `add_jira_comment` / `add_linear_comment` the same way; mail has no write path and no Reply — ask #445; the AGENT-03/AGENT-07 amendments and the STRIP-01 narrowing it needs — ask #451.
- Day cards, tracks and ideas stay visible in the root as legacy entries over today's panes (Morning brief per date, Track my threads, Idea finder) until sub-project C retires each — ask #445.
- Every inventory amendment B relies on — STRIP-01 (built-in wording and Reply narrowing), STRIP-02, STRIP-03, INBOX-05, AGENT-03/AGENT-07, new FOLDER-01 and APPROVAL-01 — approved in full — ask #451.
- Sources: asks #947, #952, #959, #961 and #964 are the owner's decisions on the umbrella (board #1400), recorded in `docs/superpowers/specs/2026-11-02-inbox-builder-design.md`; ask #445 answered this spec's open questions.
- Folders, root first and undeletable, Needs approval pinned, many automations per folder — ask #947.
- Filters replaced by folders with the umbrella's content mapping; the detector becomes Waiting for me in the root — ask #952.
- Waiting for me is one living artifact listing everything that waits; native row actions per `ref` kind — ask #959.
- AUTO-* changes (folder, approval trigger, concurrency 1) — ask #961.
- Kind-prefixed keys `action:<id>` / `reminder:<id>` in Needs approval — ask #964.
- Folder writes CLI-only with per-tree `revision` CAS; the Desktop re-reads on conflict and never retries a write by itself — agent's call.
- Folder addressed by an immutable slug; renames never break a recipe — agent's call.
- An automation's folder is a route row outside the recipe and its `approval_hash`; moving needs no confirmation — agent's call: a folder is placement, not a permission, and changes nothing a run does.
- A recipe's `folder` names an existing folder only; a missing one falls back to the route with a journal line, never fails the run — agent's call.
- Effective folder computed by one SQL view read by Go and Swift — agent's call.
- Needs approval cannot be moved, hidden, renamed or deleted, and holds no child folders — agent's call.
- Depth ≤ 3 below the root, ≤ 100 owner folders, titles 1–60, icons from an allowlist — agent's call.
- Folder writes refused under an agent marker; the editor's folder comes through the owner's Save — agent's call.
- Creating a folder from the editor: recipe saved first, then one `route --new-title` call; a route failure keeps the recipe and offers Try Again — agent's call.
- `approval` is an event type restricted to built-ins (no CHECK change, no rebuild) — agent's call.
- The approval hook sits on the seven `internal/db` writers; a hook failure never fails the state change — agent's call.
- `RunsAtSlot` narrowed to sync-triggered automations — agent's call: an event-triggered built-in must run on the executor poll right after its wake, not wait for the next sync slot.
- A per-cycle read-only sweep fires the approval run for due reminders and drift — agent's call.
- Recipe card used only when it is current (`written_at` ≥ the approval's change), else the native card; more than 50 approvals fall back natively — agent's call.
- Needs approval turns on/off with a new feature `approval-cards`; Waiting for me with `secretary-inbox` — agent's call: built-ins turn on and off only through their features (`refuseBuiltinOnOff`), and no existing feature fits approvals.
- Waiting for me reruns only at the sync slot; a native row action relies on the render-time check, not an extra run — agent's call (refines the umbrella's): the check already hides the closed row and lowers the count, so an extra run would change nothing the owner sees.
- The Messages legacy entry stands in for Waiting for me before its first run and after a failure — agent's call.
- Per-row errors with Retry (`rowErrors`), strip-wide `lastError` for read failures only — agent's call.
- Shown vs waits-on-owner predicates per `ref` kind (table) — agent's call.
- Sidebar badge = sum of visible folders' counts — agent's call: one rule the owner can check against the menu's numbers.
- Three columns: folder menu, artifact list, reading pane; Waiting for me pinned first in the root — agent's call.
- No artifact drag in v1; Move to folder moves the automation — agent's call.
- Learned Rules / Assistant Profile in the root's ⋯; the ? stays in the header; Find Ideas in Past Messages moves to the Idea finder entry — agent's call (umbrella).
- HTML mockups now, DesignShotCatalog shots as plan Task 1 for the owner's check before the rest is built — agent's call.
- Reply covers Jira and Linear items too (`add_jira_comment` / `add_linear_comment`) — agent's call: ask #445's rule is "Reply where a write path exists", and these two exist; mail has none.
- Reply text is typed by the owner in a one-line composer, no AI draft in v1 — agent's call: no model call or extra spend on a press, and the owner's own words go out; Edit… in Needs approval still allows changes.
- A pending Reply disables the row's Reply — agent's call: one reply proposal per item at a time, no duplicates in Needs approval.
- Reply is a native action of the `inbox_item` kind wherever such a ref row is drawn, and also on the Messages legacy entry's card while it stands in for Waiting for me — agent's call (ask #457 review): the approved Reply must not vanish before Waiting for me's first run or after a failed one; the legacy card otherwise stays today's pane.
- Native wins over a recipe action of the same kind per `ref` kind, incl. A's `target` on track and idea rows — agent's call.
- Daemon banner after a failed restart on any built-in Turn On — **owner's decision, ask #503**: when a built-in's Turn On enables its feature but the daemon restart fails, `AppState.setBuiltinEnabled` sets the app-wide daemon banner ("The background sync did not restart: …" with **Retry**) from the restart's own error. It lives in `setBuiltinEnabled`, so it shows in the Automations tab too — every built-in card's Turn On, not only the Inbox's Needs approval note (today that failure is only the card's line). **Retry** on the banner restarts the daemon (`AppState.startDaemonFromBanner()`); a successful start or restart clears it. Why: the Needs approval note leaves once the feature reads on, and the failure must stay visible until a restart succeeds.

## Contract with sub-project A

B builds on these seams as A's spec names them; anything else here is B's.

1. **Row `ref`.** A list row's `ref` is `{kind: inbox_item | track | idea | reminder | action, id: integer > 0}`, validated by A, stored in the canonical document, decoded to `ArtifactRef` (`kind: ArtifactRefKind`, `id: Int64`). `action` and `reminder` refs are accepted only from built-in automations; B relies on that and does not widen it.
2. **Ref hooks.** `ArtifactRefHooks` in `ArtifactEnvironment`: `isOpen(ArtifactRef) -> Bool` (B: the "shown" column), `nativeActions(ArtifactRef, ArtifactRenderMode) -> AnyView?` (B: the native row actions incl. the Reply composer, which must fit under the row — B draws it inside the returned view; disabled in `.preview`), `nativeKinds(ArtifactRef) -> Set<ArtifactActionKind>` (B: the per-kind sets under "Duplicates", which include `reply` and A's new `target` kind). A hidden row is left out of the list's own count; all rows hidden → the list's `empty` text.
3. **Counting.** `ArtifactDocument.refs` (every row ref in document order); B applies the "waits" column to them.
4. **Living outputs.** `artifacts: living`, upsert on `(automation_id, key)` in the run's commit, `output.remove({key})` committed only on success, `written_at` (last write) and `changed_at` (last content change). B's Needs approval rule compares `written_at` with the approval's change; B's lists order by `changed_at`.
5. **`folder` field.** A's `(*automations.OutputMod).RegisterInboxField("folder", fn)`; B registers it, owns its semantics (slug lookup, fallback, journal line), the `automation_outputs.folder_id` column and migration, its write in `commitRunTx` (a living upsert rewrites `folder_id` too — the last run's choice wins), the dry-run `DraftOutput` field and the Swift reads. Until B's hook lands, A refuses `folder` with `output.inbox(): folder is not available yet`.
6. **Editor entry.** `AppState.openAutomationEditor(_:step:)` with `AutomationEditorStep.collects | .look | .schedule` for the ⋯ entries. B's menu task waits for it (plan Task 14 depends on A Task 12); no stepless fallback is built.
7. **Today's Inbox.** A draws blocks in today's `InboxReadingPane` until B replaces the screen; B's reading pane hosts the same `ArtifactView` and keeps A's `.unsupported` / `.unreadable` lines.
8. **Action kinds.** A's `output.inbox` action kinds are `open`, `chat`, `agent`, `reply` and the new `target` (owner press → `create_target` proposal, ask #445). B suppresses `target` on track and idea rows (native **Make a Task**) and otherwise leaves it to A; a `target` press on an artifact proposes through the registry and therefore appears in Needs approval like any proposal — B needs nothing more from A for it.

What B needs from A before its own tasks can run: items 1–4 for the two built-ins and the native row actions (plan Tasks 9, 10, 13), item 5 for the `folder` hook (Task 6), item 6 for the ⋯ edit entries (Task 14). Folder config, CLI, menu, the `approval` trigger plumbing, the Needs approval native cards and the legacy entries do not wait on A.

## Open questions for the owner

None. Q1 (Reply) and Q2 (legacy entries) were answered in ask #445 and are under Decisions.
