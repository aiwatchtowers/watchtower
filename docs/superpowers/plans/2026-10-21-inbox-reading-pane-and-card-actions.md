# Inbox Reading Pane and Card Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Inbox Actions tab reads like mail (list + reading pane with rendered markdown), automation cards carry their own buttons of four kinds (Link, Chat, Agent, Reply), and a Reply press queues a new run of the recipe under its confirmed manifest.

**Architecture:** Go first: migration 00146 adds `link`, `actions_json`, `done_at` and the press columns to `automation_outputs` and the `reply` trigger to `automation_runs`. `output.inbox` validates and stores `link`/`actions`. A manifest capability `inbox:reply` gates Reply actions. A new owner-only CLI verb `automations reply` records the press and queues one `trigger='reply'` run in one transaction, then wakes the daemon. The executor hands the script `trigger.reply` read from the stored output. On the Desktop, WatchtowerCore gains the card model, the list builder and the Read/Done/Dismiss writes. The app target replaces the strip's `List` with a `PanelSplit` list + reading pane built from the design kit.

**Tech Stack:** Go 1.26 (`internal/db`, `internal/automations`, `cmd`), goose SQL migrations, goja; SwiftUI + GRDB (WatchtowerCore + app target), Desktop design kit.

**Spec:** `docs/superpowers/specs/2026-10-21-automations-panel-and-inbox-design.md`. This plan covers **part B only** (B1–B4, the B-side contract changes). Part A (the Automations screen) has its own plan; the one cross-plan seam is **Open Draft** (Task 8).

## Global Constraints

- English UI copy and repo files. Desktop kit only: `PanelSplit`, `.kitPrimary` once per screen, `.kitSecondary`/`.kitQuiet`, `KitSegmentedPicker`, `.card()`, `.kitRow`, `SectionHeader`, `Chip`, tokens, no literals; soft fills, no row dividers (`docs/design/desktop-style-guide.md`, lint-enforced).
- `output.inbox({title, body, priority?, link?, actions?})`; `actions` at most **4**; `label` at most **40** characters; `chat`/`task` at most **4 KB**; `data` at most **8 KB** of JSON (spec B2).
- Action kinds, exactly one per action: Link `open: "<url>"`, Chat `chat: "<first message>"`, Agent `agent: {task, workbench?}`, Reply `reply: "<value>", data?: {…}`. The first action is primary unless it sets `primary: false`.
- Card links (`link`, `open`): http, https or `watchtower-nav://` only, refused at write time and checked again at press time.
- Reply is the manifest capability `inbox:reply`, never a trigger: a recipe keeps exactly one trigger (`parseTrigger`). One press = one run, never merged with another run, never through the event bus.
- The script sees `trigger.kind === "reply"` and `trigger.reply = {output_id, action, value, data, card: {title, link}}`. `data` is read from the stored output, never taken from the Desktop.
- `watchtower automations reply --output <id> --action <index>` refuses under every AGENT-07 marker and otherwise asks `confirmWithOwner` (the Desktop's own launch is granted with no window).
- Read / Done / Dismiss are three states: opening a card writes `read_at`; Done writes `done_at`; Dismiss writes `dismissed_at`. The badge and the unread dot count `read_at IS NULL` among cards neither done nor dismissed. The migration backfills `done_at = read_at`.
- Copy pinned by the spec: "Reacts to its own Inbox buttons" (It may line), "Sent — run #N", "Needs confirmation", "Off", "Open source", "Discuss in Chat", "Hand to Agent…", "Done", "Dismiss", "Open Draft", "Reject", sections "Needs your decision" / "Today" / "Earlier".
- Public repo: fixtures use `acme` / `example.com` only.
- Inner loop only per task (CLAUDE.md "Agent-driven runs"): `go test ./internal/<pkg>`, `go test ./cmd -run X`, `make test-swift FILTER=<Class>`, `make lint-swift` (Swift is not covered by `make lint-diff`), `make lint-diff`. The full gate runs once, in Task 11.
- Next free goose number at plan time is **00146** (the highest is `00145_db_maintenance.sql`). Re-check it at execution and renumber if main moved.

## Review Focus

1. **Two presses on two cards of one automation while the first reply run is still queued.** `enqueueRunTx` coalesces on `(automation_id, trigger)`, and `idx_automation_runs_queued_trigger` is unique per queued trigger. Both must exempt `reply`, or the second press silently joins the first run. Pinned by `TestRun_ReplyIsNeverCoalesced` (Task 1).
2. **A double click, or a press racing Done/Dismiss.** The press is a compare-and-set in the same transaction as the enqueue. The second attempt gets "Sent — run #N" and no second run. Pinned by `TestPressInboxOutputAction_SecondPressRefused` and `TestPressInboxOutputAction_ClosedCardRefused` (Task 1).
3. **Hostile or odd links.** A body link `file:///…`, `smb://…` or `javascript:` must stay inert. An `open`/`link` written as `HTTPS://` or `WATCHTOWER-NAV://` must compare case-insensitively, and a nav link to a hidden screen must do nothing. Pinned by `TestOutput_CardLinkSchemes` (Task 2) and `InboxCardLinkPolicyTests` (Task 6).
4. **Old cards after the upgrade.** A card the owner marked Done before (only `read_at` set) must not come back. A card read but not done stays listed and drops out of the badge. Pinned by `TestMigration00146_BackfillsDoneAtFromReadAt` (Task 1) and `ActionStripAutomationOutputTests::testStripListsOpenInboxOutputs` (Task 5).
5. **The recipe changed between the card and the press.** If the recipe is now unconfirmed, off, unreadable, or confirmed without `inbox:reply`, the press must be refused before a run row exists. A queued reply run whose claimed snapshot lacks the capability fails `permission`. Stored `actions_json` from a newer build with an unknown kind decodes without crashing and drops that action. Pinned by `TestAutomationsCLI_ReplyRefusedWhenNotRunnableOrNoCapability` (Task 4), `TestExecutor_ReplyRunWithoutCapabilityFails` (Task 3) and `InboxCardActionTests::testUnknownKindIsDropped` (Task 6).

---

## Plan's calls (spec ambiguities decided here)

- **Press record = three columns on `automation_outputs`**: `pressed_action INTEGER`, `pressed_run_id INTEGER REFERENCES automation_runs(id) ON DELETE SET NULL`, `pressed_at TEXT`. There is no new table. "One press per card" is the compare-and-set `pressed_at IS NULL`.
- **`trigger` CHECK gains `reply`** through a table recreation of `automation_runs` (it has CASCADE children). The partial unique index becomes `WHERE status = 'queued' AND trigger <> 'reply'`. `enqueueRunTx` skips its coalescing lookup for `reply`.
- **`inbox:reply` requires `outputs: [inbox]`**: `ParseManifest` refuses it otherwise ("inbox:reply needs outputs: [inbox]"). Without the capability, a `reply` action in `output.inbox` is a catchable `PermissionDenied{needed: "inbox:reply"}`, not a ValidationError.
- **Limits the spec left open:** `link`/`open` at most 2048 bytes; a Reply `value` at most 100 characters, non-empty; `agent.workbench` is an integer id or a non-empty name of at most 200 characters, resolved by the Desktop at press time.
- **`data` absent ⇒ `trigger.reply.data === null`.** `primary` is stored computed: `true` only on index 0, unless that action set `primary: false`.
- **Defence in depth:** the CLI refuses a press when the *confirmed* recipe (`automations.ConfirmedRecipe`) lacks `inbox:reply`. The executor fails a `reply` run whose claimed snapshot lacks it (`error_kind='permission'`).
- **Chat kind:** a new AI Chat conversation opens with the card attached as a pasted markdown file (`ChatViewModel.attachPasted`, name `inbox-card-<id>.md`). The first message goes into `draft` and is not sent.
- **Agent kind:** the target is created through `WorkbenchCLI.addTarget` (title = first line of the task, clipped to `WorkbenchNewTargetRequest.titleLimit`; intent = the whole task). The session starts with `WorkbenchesViewModel.workOn`. A workbench recipe defaults to its own workbench. A personal card without a resolvable `workbench` shows a popover picker anchored to the button.
- **Reminders** sit in Today/Earlier by `remind_at`; there is no separate section.
- **Home** keeps showing unread cards only (`fetchInboxOutputs(includeRead: false)`); the Inbox lists open cards (`includeRead: true`).
- **AGENT-07** lists `automations reply` (a strengthening changelog line, under the same ask #475).

---

### Task 1: Migration 00146 and the db layer (outputs, reply trigger, press)

**Depends on:** none

**Files:**
- Create: `internal/db/migrations/00146_automation_inbox_actions.sql`
- Modify: `internal/db/schema.sql` (`automation_runs` CHECK + index comment, `automation_outputs` columns)
- Modify: `internal/db/automation_runs.go` (trigger const, `AutomationOutput`, `automationOutputCols`, `scanAutomationOutput`, `commitRunTx`, `enqueueRunTx`)
- Create: `internal/db/automation_outputs_press.go`
- Test: `internal/db/automation_inbox_actions_migration_test.go`, `internal/db/automation_outputs_press_test.go`, `internal/db/automation_runs_test.go`
- Regenerate: `internal/db/testdata/*.golden`, `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`

**Interfaces:**
- Produces:
  - `const db.TriggerReply = "reply"`
  - `type db.InboxAction struct { Label, Kind string; Open, Chat string; Agent *db.InboxAgentAction; Reply string; Data json.RawMessage; Primary bool }`. JSON keys: `label`, `kind` (`link|chat|agent|reply`), `open`, `chat`, `agent`, `reply`, `data`, `primary`; empty ones are omitted.
  - `type db.InboxAgentAction struct { Task string `json:"task"`; Workbench json.RawMessage `json:"workbench,omitempty"` }`
  - `db.AutomationOutput` gains `Link string; Actions []db.InboxAction; DoneAt *time.Time; PressedAction *int; PressedRunID int64; PressedAt *time.Time`
  - `type db.ReplyTrigger struct { OutputID int64 `json:"output_id"`; Action int `json:"action"`; Value string `json:"value"`; Data json.RawMessage `json:"data"`; Card db.ReplyCard `json:"card"` }`, `type db.ReplyCard struct { Title, Link string }` (keys `title`, `link`), `type db.ReplyPayload struct { Reply db.ReplyTrigger `json:"reply"` }`. This is the `event_json` of a `reply` run.
  - `func (db *DB) PressInboxOutputAction(outputID int64, actionIndex int, now time.Time) (runID int64, err error)`
  - Errors: `db.ErrOutputNotFound`, `db.ErrOutputClosed` (done or dismissed), `db.ErrNotAReplyAction`, `db.ErrOutputAutomationNotRunnable`, `*db.AlreadyPressedError{RunID int64}` (`Error()` = "Sent — run #N").

- [ ] **Step 1: Write the failing migration test** `TestMigration00146_BackfillsDoneAtFromReadAt`. Migrate to 145 and seed one automation with two runs (one of them with a step and an `owner_asks.automation_run_id` link), one output with `read_at` set, one unread and one dismissed. Then migrate up and assert:
  - the read row has `done_at == read_at`; the other two have `done_at IS NULL`;
  - every output has `link = ''` and `actions_json = '[]'`;
  - the step row, the output rows and the ask link survive (`COUNT(*)` unchanged, `automation_run_id` not NULL);
  - `sqlite_sequence.seq` for `automation_runs` equals its pre-migration value;
  - an insert with `trigger='reply'` succeeds and one with `trigger='bogus'` fails the CHECK.
  - Down, then Up again, is idempotent.
- [ ] **Step 2:** Run `go test ./internal/db/ -run TestMigration00146`. Expected: FAIL (no such column `done_at`).
- [ ] **Step 3: Write the migration.** The file has `-- +goose NO TRANSACTION`, with `PRAGMA foreign_keys = OFF;` / `ON;` around the dance (00144 pattern; the add-migration skill's Gotchas).
  - Up: recreate `automation_runs` with `'reply'` added to the trigger CHECK. Copy every row with its id, carry `sqlite_sequence` the way 00144 does, and recreate all six indexes, with `idx_automation_runs_queued_trigger` now `WHERE status = 'queued' AND trigger <> 'reply'`.
  - Up, continued: `ALTER TABLE automation_outputs ADD COLUMN` `link TEXT NOT NULL DEFAULT ''`, `actions_json TEXT NOT NULL DEFAULT '[]'`, `done_at TEXT`, `pressed_action INTEGER`, `pressed_run_id INTEGER REFERENCES automation_runs(id) ON DELETE SET NULL`, `pressed_at TEXT`; then `UPDATE automation_outputs SET done_at = read_at WHERE read_at IS NOT NULL`.
  - Down: delete the steps, outputs and owner-ask links of `reply` runs, then the runs. Recreate the old table and index. Copy `done_at` into `read_at` where `read_at IS NULL`. Drop the six columns.
- [ ] **Step 4: Mirror into `schema.sql`.** Write the CHECK, the index predicate and the six columns with comments: `done_at` Desktop-written; `pressed_*` CLI-written by `automations reply`; the `event_json` shape of a `reply` run.
- [ ] **Step 5: Write the failing db tests** in `automation_outputs_press_test.go`:
  - `TestPressInboxOutputAction_OnePressOneRun`: a runnable automation whose output has `actions_json` = `[{label:"Backlog",kind:"reply",reply:"backlog",data:{"k":1}}]`. The press returns run id R. The `automation_runs` row is `trigger='reply'`, `status='queued'`, and its `event_json` decodes to `ReplyPayload{Reply:{OutputID, Action:0, Value:"backlog", Data:{"k":1}, Card:{Title, Link}}}`. The output has `pressed_action=0`, `pressed_run_id=R` and `pressed_at=now`.
  - `TestPressInboxOutputAction_SecondPressRefused`: a second press of the same card returns `*AlreadyPressedError{RunID: R}`, and the run count is unchanged.
  - `TestPressInboxOutputAction_ClosedCardRefused`: a done card or a dismissed card → `ErrOutputClosed`, with no run row.
  - `TestPressInboxOutputAction_RefusesNonReplyAndBadIndex`: index 0 of a `link` action, and index 4 → `ErrNotAReplyAction`; a missing output → `ErrOutputNotFound`.
  - `TestPressInboxOutputAction_NotRunnableRefused`: disabled, unconfirmed (`confirmed_hash != approval_hash`), `parse_error != ''` and `removed_at` set each → `ErrOutputAutomationNotRunnable`, with no run and no press.
  - `TestPressInboxOutputAction_DataComesFromTheStoredRow`: a row stored with `data` absent → payload `data` is JSON `null`.
- [ ] **Step 6: Write the failing run tests** in `automation_runs_test.go`:
  - `TestRun_ReplyIsNeverCoalesced`: two presses on two cards of one automation while the first run is queued → two distinct queued `reply` runs, and `coalesced == false` both times.
  - `TestRun_CommitStoresLinkAndActions`: `FinishAutomationRun` with an output carrying `Link` and two `Actions` round-trips through `ListAutomationOutputs`, with `Actions[0].Primary == true` as stored.
  - `TestRun_CoalescesSecondTrigger` stays unchanged and green.
- [ ] **Step 7:** Run `go test ./internal/db/ -run 'TestPressInboxOutputAction|TestRun_'`. Expected: FAIL (undefined `PressInboxOutputAction`).
- [ ] **Step 8: Implement.**
  - `enqueueRunTx`: skip the queued-run lookup when `r.Trigger == TriggerReply`.
  - `commitRunTx`: insert `link` and `actions_json` (marshal `o.Actions`, `[]` when nil).
  - Scan the new columns, decoding `actions_json` (a decode error is an error, not an empty list).
  - `PressInboxOutputAction`: in one `BEGIN IMMEDIATE` tx, read the output (`kind='inbox'`) and its automation's `parse_error`/`enabled`/`removed_at`/`confirmed_hash`/`approval_hash`. Check them in the order of the Step 5 errors. Build `ReplyPayload` from the stored row. Call `enqueueRunTx(tx, EnqueueRequest{Trigger: TriggerReply, EventJSON: …, Now: now})`. Then `UPDATE … SET pressed_action=?, pressed_run_id=?, pressed_at=? WHERE id=? AND pressed_at IS NULL AND done_at IS NULL AND dismissed_at IS NULL`; zero rows affected → roll back and re-read to return the precise error.
- [ ] **Step 9: Regenerate** with `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`, then run `go test ./internal/db/`. Expected: PASS, including `TestMigrationIdempotent`, `TestAllTablesExist` (no new table) and `TestMigration_TableRecreationPreservesCascadeChildren`.
- [ ] **Step 10: Commit**

```bash
git add internal/db/ WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift
git commit -m "feat(db): inbox card links, actions, done_at and the reply trigger (00146)"
```

---

### Task 2: `output.inbox` link/actions and the `inbox:reply` capability

**Depends on:** Task 1

**Files:**
- Modify: `internal/automations/limits.go`, `internal/automations/manifest.go`, `internal/automations/sdk_output.go`, `internal/automations/sdk_output_p2.go` (registration call only)
- Create: `internal/automations/sdk_output_card.go`
- Test: `internal/automations/sdk_output_card_test.go`, `internal/automations/manifest_test.go`, `internal/automations/indexer_test.go`

**Interfaces:**
- Consumes: `db.InboxAction`, `db.InboxAgentAction`, `db.AutomationOutput.Link/Actions` (Task 1).
- Produces:
  - limits `MaxInboxActions = 4`, `MaxInboxActionLabelChars = 40`, `MaxInboxActionTextBytes = 4 * 1024`, `MaxInboxActionDataBytes = 8 * 1024`, `MaxInboxLinkBytes = 2048`, `MaxInboxReplyValueChars = 100`
  - `capabilitySpecs["inbox"] = {verbs: ["reply"]}`; `func (m *Manifest) AllowInboxReply() (string, error)` (entry `"inbox:reply"` or `*PermissionDenied{Needed: "inbox:reply"}`)
  - `func inboxCard(env *Env, fn string, fields map[string]any) (link string, actions []db.InboxAction, err error)`; `func checkCardURL(fn, field, raw string) (string, error)` (schemes `http`, `https`, `watchtower-nav`, case-insensitive, a host required)
  - `bufferedOutput(kind string, opts outputOpts)` with `type outputOpts struct { priority, card bool }`; inbox = `{priority: true, card: true}`, report/briefing = `{}`.

- [ ] **Step 1: Write the failing manifest tests:**
  - `TestManifest_InboxReplyCapability`: `inbox:reply` with `outputs: [inbox]` parses, normalises to `"inbox:reply"`, and `AllowInboxReply()` returns it; without it, `AllowInboxReply()` returns a `*PermissionDenied` with `Needed == "inbox:reply"`.
  - `inbox:reply@x` → error "inbox takes no @scope"; `inbox:read` → "has no verb"; `inbox:reply` without `outputs: [inbox]` → `*ManifestError{Field:"permissions"}` with Msg containing "needs outputs: [inbox]". It parses in both personal and workbench scope.
  - `TestApprovalHash_InboxReplyIsHashed` (indexer_test.go): adding `inbox:reply` to a confirmed recipe changes `approval_hash` and makes the row need confirmation.
- [ ] **Step 2: Write the failing SDK tests** in `sdk_output_card_test.go`, run through the existing sandbox fixture:
  - `TestOutput_InboxCardRoundTrip`: `output.inbox({title, body, link:"https://example.com/x", actions:[{label:"Open",open:"watchtower-nav://automations"},{label:"Ask",chat:"Draft replies"},{label:"Fix",agent:{task:"Fix it",workbench:3}},{label:"Backlog",reply:"backlog",data:{id:"A-1"}}]})` on a manifest with `inbox:reply` buffers an output with `Link` and four actions of kinds `link, chat, agent, reply`, `Primary` `[true,false,false,false]`, `Data == {"id":"A-1"}`.
  - `TestOutput_FirstActionPrimaryFalse`: `primary:false` on index 0 → all four `Primary == false`; `primary:true` on index 2 → ValidationError "primary may only be set to false on the first action".
  - `TestOutput_CardLinkSchemes`: `HTTPS://example.com` and `WATCHTOWER-NAV://home` accepted. `file:///etc`, `smb://x`, `javascript:alert(1)`, `mailto:a@example.com`, `slack://x`, `https://` (no host) and a 2049-byte URL → ValidationError naming the field (`link` or `actions[i].open`).
  - `TestOutput_CardActionLimits`: a 5th action; a 41-character label; an empty label; a `chat` of 4097 bytes; `agent.task` empty or 4097 bytes; `data` serialising to 8193 bytes; a 101-character `reply`; `workbench: ""`, `-1` or `true` → ValidationError each.
  - `TestOutput_CardActionShape`: two kinds on one action; none; an unknown key (`color`); `data` on a non-reply action → ValidationError each.
  - `TestOutput_ReplyActionNeedsInboxReply`: the same call without `inbox:reply` → catchable `PermissionDenied` with `needed: "inbox:reply"`, and nothing buffered.
  - `TestOutput_ReportRefusesCardFields`: `output.report({title, body, link})` → ValidationError "unknown field \"link\"" (and likewise briefing).
  - `TestOutput_GateAndBodyLimit` and `TestOutputs_CapPerRun` stay unchanged and green.
- [ ] **Step 3:** Run `go test ./internal/automations/ -run 'TestManifest_InboxReply|TestApprovalHash_InboxReply|TestOutput_'`. Expected: FAIL.
- [ ] **Step 4: Implement** the capability row, the `ParseManifest` cross-check and `AllowInboxReply` (via `allowUnscoped`). Then `outputOpts`, `inboxCard`/`checkCardURL` in `sdk_output_card.go`, and `checkOutputFields` widened only for `card`. The size of `data` is the length of its canonical JSON (`json.Marshal` of the converted value).
- [ ] **Step 5:** Run `go test ./internal/automations/`. Expected: PASS.
- [ ] **Step 6: Commit** `feat(automations): output.inbox link and actions, inbox:reply capability`.

---

### Task 3: The executor hands `trigger.reply` to the script

**Depends on:** Task 1, Task 2

**Files:**
- Modify: `internal/automations/sandbox.go` (`TriggerInfo`, `jsObject`), `internal/automations/executor_run.go` (`triggerInfo`, the manifest check before the sandbox)
- Test: `internal/automations/executor_test.go`

**Interfaces:**
- Consumes: `db.TriggerReply`, `db.ReplyPayload` (Task 1); `(*Manifest).AllowInboxReply` (Task 2).
- Produces: `TriggerInfo.Reply map[string]any` (nil except on a `reply` run). The JS keys are `trigger.reply.output_id`, `.action`, `.value`, `.data`, `.card.title`, `.card.link`.

- [ ] **Step 1: Write the failing tests:**
  - `TestExecutor_ReplyRunSeesTriggerReply`: a recipe with `inbox:reply` and script `output.report({title: trigger.kind + ":" + trigger.reply.value, body: JSON.stringify(trigger.reply)})`. A queued `reply` run with the Task 1 payload succeeds. The report title is `"reply:backlog"`, and the body decodes to `{output_id, action:0, value:"backlog", data:{"id":"A-1"}, card:{title, link}}`.
  - `TestExecutor_ReplyRunWithoutCapabilityFails`: the same run against a confirmed recipe without `inbox:reply` ends `failed` with `error_kind='permission'`, an error naming `inbox:reply`, and no outputs.
  - `TestExecutor_ReplyRunOfDisabledRecipeIsNotRunnable`: a queued `reply` run of a disabled automation ends `cancelled`/`not_runnable` (the existing gate).
  - `TestExecutor_ScheduleRunHasNoReply`: on a schedule run, `typeof trigger.reply === "undefined"`.
- [ ] **Step 2:** Run `go test ./internal/automations/ -run 'TestExecutor_Reply|TestExecutor_ScheduleRunHasNoReply'`. Expected: FAIL.
- [ ] **Step 3: Implement.** `triggerInfo` decodes `run.EventJSON` as `db.ReplyPayload` when `run.Trigger == db.TriggerReply` (a decode failure is a run error, as for events). The pre-sandbox step ends a `reply` run `failed`/`permission` when the snapshot's manifest refuses `AllowInboxReply`.
- [ ] **Step 4:** Run `go test ./internal/automations/`. Expected: PASS, with AUTO-04/06/11 guards green.
- [ ] **Step 5: Commit** `feat(automations): reply runs see trigger.reply`.

---

### Task 4: CLI `automations reply` and the outputs JSON

**Depends on:** Task 1, Task 2

**Files:**
- Create: `cmd/automations_reply.go`
- Modify: `cmd/automations.go` (flags `Output int64`, `Action int`; registration; `--json`), `cmd/owner_confirm.go` (`inboxReplyConfirmDetail`), `cmd/automations_list.go` (`automationOutputJSON`)
- Test: `cmd/automations_reply_test.go`, `cmd/automations_test.go`

**Interfaces:**
- Consumes: `db.PressInboxOutputAction` and its errors (Task 1); `automations.ConfirmedRecipe`, `(*Manifest).AllowInboxReply` (Task 2); `refuseUnderAgent`, `confirmWithOwner`, `wakeAutomations`, `wakeNote` (existing).
- Produces:
  - `watchtower automations reply --output <id> --action <index> [--json]`; `--json` = `{"run_id": N, "daemon_running": bool}` (pinned keys); text = "Queued run #N." plus the wake note.
  - `outputs --json` rows gain `link` (string), `actions` (array of the Task 1 JSON shape), `done_at` (time|null) and `press` (`null` or `{"action": i, "run_id": N|null, "pressed_at": time}`).
  - `func inboxReplyConfirmDetail(database *db.DB, outputID int64, index int) string`: the automation name, the card title, and the button's label and value.

- [ ] **Step 1: Write the failing tests:**
  - `TestAutomationsCLI_ReplyRefusedUnderAgentMarkers` (loop over `agentEnvMarkers`, like `TestAutomationsCLI_EnableDeleteRefusedUnderAgentMarkers`): non-zero exit, error containing "refusing to press an Inbox button under an AI agent", no run row, `pressed_at IS NULL`, and the owner-confirm stub never called.
  - `TestAuto09_ReplyCommandOnlyQueues`: with the owner-confirm stub confirming, `reply --output O --action 0 --json` prints `{"run_id":R,"daemon_running":…}`. Run R is `queued` and no step rows exist (nothing ran in-process); the wake was attempted once.
  - `TestAutomationsCLI_ReplyRefusedWhenNotRunnableOrNoCapability`: the automation disabled → error "cannot run: it is disabled…" (the `notRunnableReason` wording); confirmed without `inbox:reply` → error "no longer reacts to its Inbox buttons (inbox:reply)". Neither creates a run or a press.
  - `TestAutomationsCLI_ReplySecondPressSaysSent`: a second call exits non-zero with "Sent — run #R".
  - `TestAutomationsCLI_ReplyFlagsRequired`: missing `--output` or `--action`, or `--action -1` → usage error, nothing opened.
  - `TestAutomationsCLI_OutputsJSONCardKeys`: the pinned key set of one row, including `link`, `actions`, `done_at`, `press`.
- [ ] **Step 2:** Run `go test ./cmd -run 'Reply|OutputsJSONCardKeys'`. Expected: FAIL.
- [ ] **Step 3: Implement** `runAutomationsReply` in this order:
  1. `refuseUnderAgent("press an Inbox button")`
  2. open the DB, load the output and its automation
  3. `notRunnableReason`
  4. `ConfirmedRecipe` → `AllowInboxReply`
  5. `confirmWithOwner("press an Inbox button", inboxReplyConfirmDetail(…))`
  6. `PressInboxOutputAction(…, time.Now())`
  7. `wakeAutomations`, printing like `runAutomationsRun`
- [ ] **Step 4:** Run `go test ./cmd -run 'Automations|Auto09'`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(cli): automations reply, card keys in outputs --json`.

---

### Task 5: WatchtowerCore data: open cards, Read/Done/Dismiss, badge

**Depends on:** Task 1 (the regenerated Swift test schema). It runs in parallel with Tasks 2–4.

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/AutomationModels.swift` (`AutomationOutputCard`)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/AutomationQueries.swift` (inbox outputs section)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Actions/ActionStripViewModel.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/HomeFeedQueries.swift` (pass `includeRead: false`)
- Modify: `WatchtowerDesktop/Tests/Support/TestDatabase+Automations.swift` (`insertAutomationOutput` gains `doneAt`, `link`, `actionsJSON`, `pressedAction`, `pressedRunID`, `pressedAt`, all defaulted)
- Test: `WatchtowerDesktop/Tests/Core/ActionStripAutomationOutputTests.swift`

**Interfaces:**
- Produces:
  - `AutomationOutputCard` gains `link: String`, `actionsJSON: String` (decoded in Task 6), `readAt: Date?`, `pressedAction: Int?`, `pressedRunID: Int64?`, `workbenchID: Int64?` (the automation's `project_id`), `recipeState: AutomationHeaderButton.State`. `var isUnread: Bool { readAt == nil }`.
  - `AutomationQueries.fetchInboxOutputs(_ db:, since:, limit:, includeRead: Bool = false)`: open = `kind='inbox' AND done_at IS NULL AND dismissed_at IS NULL`, plus `read_at IS NULL` unless `includeRead`.
  - `AutomationQueries.inboxOutputCount(_:)` counts unread open cards.
  - `AutomationQueries.markOutputOpened(_:id:now:)` (writes `read_at` once), `markOutputDone(_:id:now:)` (writes `done_at` once), `dismissOutput(_:id:now:)` (writes `dismissed_at` once). Each one guards `done_at IS NULL AND dismissed_at IS NULL`. `markOutputRead` is removed.
  - `ActionStripViewModel`: `var selection: InboxSelection?` (`enum InboxSelection: Hashable { case proposal(Int64), reminder(Int64), output(Int64) }`); `func select(_ item: InboxSelection?) async` (an unread output gets `markOutputOpened`, then `refresh()`; the card stays listed); `markOutputDone`/`dismissOutput` clear the selection when it is that card. `refresh()` reads `fetchInboxOutputs(includeRead: true)`.
  - Shared state precedence: extract `AutomationHeaderButton.state(parseError:needsConfirmation:runnable:)` and use it from `state(of:)` and the query.

- [ ] **Step 1: Rewrite the guards.** This is the contract change approved in ask #475 (STRIP-02), with no assertion dropped:
  - `testDoneWritesOnlyReadAt` → **`testDoneWritesOnlyDoneAt`**: same full-row before/after comparison of every column except `done_at`. `done_at` is set; `read_at` and `dismissed_at` are unchanged; the card leaves `outputRows`; `lastError` is nil.
  - `testDismissWritesOnlyDismissedAt`: the comparison now also proves `done_at` unchanged (it is just another column in the loop).
  - New **`testOpeningWritesOnlyReadAt`**: `select(.output(id))` on an unread card sets only `read_at` (full-row comparison). The card stays in `outputRows` with `isUnread == false`; the badge drops by 1. Selecting it again writes nothing (row unchanged).
  - `testStripListsUnreadInboxOutputs` → **`testStripListsOpenInboxOutputs`**: the read-not-done row is listed. Done, dismissed and backfilled-done (`readAt` + `doneAt`) rows are not. Order is newest first.
  - `testInboxBadgeCountsOutputs`: seed an extra read-not-done card; the expected badge stays 4.
  - New `testCardCarriesPressAndRecipeState`: a pressed card has `pressedAction == 0` and `pressedRunID == R`; a disabled automation → `.disabled`; unconfirmed → `.needsConfirmation`.
  - `testRefreshIsAPureRead` and `testFailedWriteKeepsCard` stay unchanged.
- [ ] **Step 2:** Run `make test-swift FILTER=ActionStripAutomationOutputTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the model fields, the queries, the view model selection and writes, and the Home call site.
- [ ] **Step 4:** Run `make test-swift FILTER='ActionStripAutomationOutputTests|ActionStripViewModelTests|HomeFeedQueriesTests'` and `make lint-swift`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(desktop): inbox cards have read, done and dismissed states`.

---

### Task 6: WatchtowerCore presentation: actions, list sections, links, Reply press

**Depends on:** Task 5

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/InboxCardAction.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/InboxListBuilder.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/InboxCardLinkPolicy.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/InboxCardTexts.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/AutomationsCLI.swift` (`Op.reply`, `ReplyResult`)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Actions/ActionStripViewModel.swift` (`pressReply`)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/AutomationCardPresentation.swift` (`runtimeLine` case `("inbox","reply",nil)`, `triggerLabel` case `"reply"`)
- Test: `WatchtowerDesktop/Tests/Core/InboxCardActionTests.swift`, `InboxListBuilderTests.swift`, `InboxCardLinkPolicyTests.swift`, `InboxReplyPressTests.swift`, `AutomationsCLITests.swift`, `AutomationCardPresentationTests.swift`

**Interfaces:**
- Consumes: `AutomationOutputCard` (Task 5); the Go JSON shapes (Tasks 1, 4).
- Produces:
  - `package struct InboxCardAction: Equatable, Sendable { label: String; kind: Kind; primary: Bool }` with `enum Kind: Equatable, Sendable { case link(URL), chat(String), agent(task: String, workbench: WorkbenchRef?), reply(value: String) }` and `enum WorkbenchRef: Equatable, Sendable { case id(Int64), name(String) }`. Data stays in Go and is not decoded.
  - `InboxCardAction.decode(_ actionsJSON: String) -> [InboxCardAction]`: tolerant; an unknown kind, a bad URL or a garbled array drops that action (or all of them), never throws.
  - `package enum InboxReplyState: Equatable { case ready, sent(runID: Int64?), needsConfirmation, off, unreadable }`; `static func replyState(_ card: AutomationOutputCard) -> InboxReplyState` (a press first, then the recipe state).
  - `package enum InboxListBuilder { static func sections(proposals: [AgentAction], reminders: [Reminder], outputs: [AutomationOutputCard], now: Date, calendar: Calendar) -> [InboxSection] }`. `InboxSection { title: String; items: [InboxItem] }`; `enum InboxItem: Identifiable { case proposal(AgentAction), reminder(Reminder), output(AutomationOutputCard) }`, whose `id` is an `InboxSelection`.
  - `package enum InboxCardTexts`: `preview(_ markdown: String) -> String` (plain text, one line, ≤ 140 chars); `sourceLine(_ card:, now:) -> String` ("<automation> · 10:00"); `readingSourceLine(_ card:) -> String` ("ϟ <automation> · run #<n> · <time>"); `discussMessage(_ card:) -> String`; `handToAgentTask(_ card:) -> String`; `attachmentMarkdown(_ card:) -> String`; `targetTitle(fromTask:) -> String`.
  - `package enum InboxCardLinkPolicy { static func permits(_ url: URL, navScreens: Set<String>) -> Bool }`: http/https, or `watchtower-nav` to a screen in `navScreens`; schemes compared case-insensitively.
  - `AutomationsCLI.Op.reply(outputID: Int64, action: Int)` → `["automations","reply","--output",id,"--action",i,"--json"]`; `func reply(outputID:action:) async throws -> ReplyResult` (`runID`, `daemonRunning`).
  - `ActionStripViewModel.pressReply(outputID: Int64, action: Int) async`: one write per card through `PendingWrites` (the CLI wakes the daemon itself), then `refresh()`. A failure sets `lastError` to the CLI's message.

- [ ] **Step 1: Write the failing tests:**
  - `InboxCardActionTests`:
    - `testDecodesFourKinds`: the Task 2 example JSON → four actions, kinds in order, `primary` as stored.
    - `testUnknownKindIsDropped`: `[{"label":"X","kind":"teleport"}, <a valid link>]` → one action.
    - `testGarbledJSONIsEmpty`: `"not json"` and `"{}"` → `[]`.
    - `testWorkbenchRef`: `3` → `.id(3)`, `"acme"` → `.name("acme")`, absent → nil.
    - `testReplyState`: pressed → `.sent(runID: R)`; unpressed and `.runnable` → `.ready`; `.needsConfirmation` → `.needsConfirmation`; `.disabled` → `.off`; `.parseError` → `.unreadable`.
  - `InboxListBuilderTests`:
    - `testSectionsAreProposalsTodayEarlier`: section titles in order `["Needs your decision","Today","Earlier"]`; an empty section is omitted.
    - `testTodayMixesOutputsAndRemindersByTime`: an output at 10:00 and a reminder due 11:00 today → Today `[reminder, output]` (newest first); yesterday's items → Earlier.
    - `testCalendarDayBoundary`: an item at 23:59 yesterday in the given calendar's time zone → Earlier.
  - `InboxCardTextsTests` (in `InboxListBuilderTests.swift`):
    - `testPreviewStripsMarkdown`: `"# Hi\n**bold** [x](https://example.com)"` → `"Hi bold x"`.
    - `testPreviewClipsAt140`.
    - `testTargetTitleIsFirstLineClipped`: clipped to `WorkbenchNewTargetRequest.titleLimit`.
    - `testDiscussMessageHasTitleAndBody`.
  - `InboxCardLinkPolicyTests`:
    - `testAllowsHttpAndHttps`, `testSchemeIsCaseInsensitive` (`HTTPS://…`).
    - `testNavOnlyToVisibleScreens`: `watchtower-nav://home` with `["home"]` → true, with `[]` → false.
    - `testRefusesOtherSchemes`: `file`, `smb`, `javascript`, `mailto`, `slack`, a relative URL → false.
  - `InboxReplyPressTests`:
    - `testAuto09_ReplyPressOnlyQueues`: with `FakeCLIRunner` returning `{"run_id":7,"daemon_running":true}`, `pressReply(outputID: 5, action: 1)` runs exactly `automations reply --output 5 --action 1 --json` once. It writes nothing: full dumps of `automation_outputs`, `automation_runs` and `agent_actions` are unchanged, which is the STRIP-02 guard.
    - `testSecondPressWhileWritingIsDropped`.
    - `testCLIFailureKeepsCardAndSaysWhy`: the runner throws "Sent — run #7" → `lastError` contains it and the card is still listed.
  - `AutomationsCLITests::testReplyArgs`.
  - `AutomationCardPresentationTests`: `permissionLine("inbox:reply") == "Reacts to its own Inbox buttons"`; `triggerLabel` of a `reply` run == "Inbox button".
- [ ] **Step 2:** Run `make test-swift FILTER='InboxCardActionTests|InboxListBuilderTests|InboxCardLinkPolicyTests|InboxReplyPressTests|AutomationsCLITests|AutomationCardPresentationTests'`. Expected: FAIL.
- [ ] **Step 3: Implement.** The preview uses `MarkdownDocument.parse` and joins the inline text, so it does not get a second markdown parser.
- [ ] **Step 4:** Run the same filter and `make lint-swift`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(desktop): inbox card actions, sections and reply press`.

---

### Task 7: The Inbox split view: list, reading pane and common row

**Depends on:** Task 6

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Inbox/InboxSplitView.swift` (`PanelSplit`, the list with `List(selection:)` so arrow keys move as in mail, the "?" cheat-sheet button in the list header)
- Create: `WatchtowerDesktop/Sources/Views/Inbox/InboxListRow.swift` (unread dot, title, high-priority `Chip`, source line, preview)
- Create: `WatchtowerDesktop/Sources/Views/Inbox/InboxReadingPane.swift` (output card: reading source line as a link button to `onOpenAutomationRun`, title, `MarkdownView` body; reminder pane; proposal pane with `AgentActionCardView` for non-`save_automation` kinds)
- Create: `WatchtowerDesktop/Sources/Views/Inbox/InboxCardButtons.swift` (own button row: first action `.kitPrimary` unless `primary == false`, the rest `.kitSecondary`; common row Open source (hidden without a link) / Discuss in Chat / Hand to Agent… then Done and Dismiss trailing, `.kitQuiet`)
- Modify: `WatchtowerDesktop/Sources/Views/Inbox/ActionStripView.swift` (`ActionStripActionsView`'s non-empty branch becomes `InboxSplitView`; it gains `onCardAction: (InboxCardCommand) -> Void`; `ReminderRow`/`AutomationOutputRow` are removed once unused)
- Create: `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+Inbox.swift`; Modify: `WatchtowerDesktop/Tests/DesignShots/DesignShotCatalog.swift`
- Test: `WatchtowerDesktop/Tests/ActionStripActionsViewTests.swift`, `WatchtowerDesktop/Tests/InboxReadingPaneTests.swift` (ViewInspector)

**Interfaces:**
- Consumes: Task 5/6 types; `PanelSplit`, `PanelSplitWidth`; `MarkdownView` (its `AllowedURLSchemes` gate plus `\.markdownNavScreens`).
- Produces: `enum InboxCardCommand { case openLink(URL), chat(card: AutomationOutputCard, message: String), agent(card: AutomationOutputCard, task: String, workbench: InboxCardAction.WorkbenchRef?), reply(outputID: Int64, action: Int), openAutomation(AutomationOutputCard) }`. The view emits it and Task 8 wires it. The `PanelSplitWidth` key is `"inbox.readingPaneWidth"` (range 420...900, ideal 560).

- [ ] **Step 1: Write the failing view tests:**
  - `ActionStripActionsViewTests::testNonEmptyStripHidesTheSheetBehindTheHelpButton` keeps passing against the new list header (update only the lookup if the identifier moved; the identifier `actionStrip.cheatSheetButton` stays).
  - New `InboxReadingPaneTests`:
    - `testOutputPaneRendersMarkdownAndOwnButtons`: two actions → two buttons labelled as stored, then Open source, Discuss in Chat, Hand to Agent…, Done, Dismiss.
    - `testOpenSourceHiddenWithoutLink`.
    - `testReplyButtonStates`: `.sent(7)` → a disabled button whose label reads "Sent — run #7"; `.needsConfirmation` → caption "Needs confirmation", and tapping it emits `.openAutomation`; `.off` → caption "Off", same.
    - `testLinkButtonRefusedByPolicyIsDisabled`: `watchtower-nav://hidden` with an empty `navScreens` → disabled.
    - `testFirstActionPrimaryUnlessFalse`.
- [ ] **Step 2:** Run `make test-swift FILTER='ActionStripActionsViewTests|InboxReadingPaneTests'`. Expected: FAIL.
- [ ] **Step 3: Implement the views.** The selection drives `vm.select(_:)`. When nothing is selected, the pane is empty with a short line ("Select a card"). Escape clears the selection. Done or Dismiss on the selected card selects the next row.
- [ ] **Step 4: Add design shots.** Add `inbox-reading-pane` (1180×720: a list with all three sections, a selected output card with three own buttons and a markdown body) and `inbox-proposal-pane` (1180×560: a selected `save_automation` proposal, using Task 8's pane, so this shot lands with Task 8 if Task 8 is not done yet). Fixtures use `acme`/`example.com` only.
- [ ] **Step 5:** Run the Step 2 filter, `make lint-swift` and `make desktop-shots DESKTOP_SHOTS=build/desktop-shots`. Expected: PASS, with `inbox-reading-pane-light.png` and `-dark.png` written; look at both by eye.
- [ ] **Step 6: Commit** `feat(desktop): inbox list and reading pane`.

---

### Task 8: Card commands in AppState and the save_automation proposal pane

**Depends on:** Task 7. **Open Draft** also needs part A's entry point that opens the A4 editor with given recipe text in a given scope. Use part A's plan's name. If part A has not merged, land everything else and leave Open Draft wired to `AutomationEditorCenter`'s existing open-for-edit path behind a `// part A` note; the controller swaps it when A lands.

**Files:**
- Create: `WatchtowerDesktop/Sources/App/AppState+Inbox.swift`
- Create: `WatchtowerDesktop/Sources/Views/Inbox/SaveAutomationProposalPane.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/SaveAutomationCardModel.swift` (expose `package let whenLine: String` and `package let permissions: [String]` it already computes)
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/SaveAutomationProposalSummary.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/InboxAgentHandoff.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Inbox/ActionStripView.swift` (wires `onCardAction` to `AppState`)
- Test: `WatchtowerDesktop/Tests/Core/SaveAutomationProposalSummaryTests.swift`, `WatchtowerDesktop/Tests/Core/InboxAgentHandoffTests.swift`

**Interfaces:**
- Consumes: `InboxCardCommand` (Task 7); `InboxCardTexts`, `InboxCardLinkPolicy` (Task 6); `ChatViewModel.newConversation`, `.attachPasted(_:name:)`, `.draft`; `WorkbenchCLI.addTarget`; `WorkbenchesViewModel.workOn(targetID:targetText:projectID:)`; `AppState.openNavLink`, `openAutomationRun(automationID:runID:)`, `visibleHelpScreenIDs`.
- Produces:
  - `AppState.perform(_ command: InboxCardCommand) async`
  - `AppState.openChatAboutInboxCard(_ card: AutomationOutputCard, message: String) async`: selects `.chat`, creates a new conversation, attaches `attachmentMarkdown` as `inbox-card-<id>.md`, puts `message` in `draft`, focuses the composer, and sends nothing.
  - `AppState.handInboxCardToAgent(_ card: AutomationOutputCard, task: String, workbenchID: Int64) async`
  - `package enum InboxAgentHandoff { static func workbench(for ref: InboxCardAction.WorkbenchRef?, card: AutomationOutputCard, workbenches: [Workbench]) -> Resolution }`, with `enum Resolution: Equatable { case workbench(Int64), pick }`.
  - `package struct SaveAutomationProposalSummary: Equatable { name, scope, when, mayLine: String; init(model: SaveAutomationCardModel, workbenchName: (Int64) -> String?) }`

- [ ] **Step 1: Write the failing tests:**
  - `InboxAgentHandoffTests`:
    - `testWorkbenchRecipeDefaultsToItsOwn`: ref nil, `card.workbenchID = 3` → `.workbench(3)`.
    - `testIdAndNameResolve`: `.id(3)` when 3 exists → `.workbench(3)`; `.name("acme")` with one case-insensitive match → `.workbench`.
    - `testUnknownOrAmbiguousPicks`: a missing id, an unknown name, a name matching two workbenches, or a personal card with no ref → `.pick`.
  - `SaveAutomationProposalSummaryTests`:
    - `testSummaryLines`: name = the card title, scope "Personal" or the workbench name, `when` = the model's when line.
    - `testMayLineJoinsTwoAndCountsTheRest`: four permissions → "Read mail in work (Gmail), Use the light model and 2 more".
- [ ] **Step 2:** Run `make test-swift FILTER='InboxAgentHandoffTests|SaveAutomationProposalSummaryTests'`. Expected: FAIL.
- [ ] **Step 3: Implement `perform`.**
  - `.openLink(url)`: checked again with `InboxCardLinkPolicy.permits(url, navScreens: visibleHelpScreenIDs)`; nav → `openNavLink`, web → `NSWorkspace.shared.open`; refused → nothing.
  - `.chat` → `openChatAboutInboxCard`.
  - `.agent` → resolve. `.pick` shows the anchored workbench picker (a popover owned by `InboxCardButtons`, which re-emits `.agent` with an id ref). Then `handInboxCardToAgent` creates the target and calls `workOn`, selecting the Workbench destination.
  - `.reply` → `actionStripViewModel.pressReply`.
  - `.openAutomation` → `openAutomationRun(automationID:runID: nil)`.
  - `SaveAutomationProposalPane` shows the summary, **Open Draft** (`.kitPrimary`) and **Reject** (via `vm.reject`, STRIP-03).
- [ ] **Step 4:** Run the Step 2 filter plus `ActionStripViewModelTests`, and `make lint-swift`. Expected: PASS. Add the `inbox-proposal-pane` shot if Task 7 deferred it, and check light and dark by eye.
- [ ] **Step 5: Manual check.** Run the app with a dev DB copy (never the live DB). Seed a recipe with the four kinds and press each. Chat opens a new chat with the attachment and an unsent draft. Agent creates a target and starts a session. Reply shows "Sent — run #N", and the run's History label reads "Inbox button".
- [ ] **Step 6: Commit** `feat(desktop): inbox card commands and the save proposal pane`.

---

### Task 9: SDK reference, the create-automation skill and the feature note

**Depends on:** Task 2, Task 3, Task 4

**Files:**
- Modify: `internal/skills/shipped/create-automation.md` (SDK table row for `output.inbox`; new subsection "Buttons on an Inbox card" with the four kinds, limits, `inbox:reply`, and the `trigger.kind === "reply"` branch; one example recipe with a Reply button; in the editor chat, tell the owner to press **Save** instead of proposing `save_automation` only if part A has not already changed that line)
- Modify: `internal/automations/authoring/skill_examples_test.go` only if the example list is enumerated by name
- Modify: `docs/features/automations.md` ("Sandbox and SDK (P1)": `trigger` gains `reply?`; a new "Inbox cards and Reply (2026-10-21)" section covering migration 00146 columns, `output.inbox` card fields and limits, `inbox:reply`, `automations reply` and its pinned JSON, the no-coalesce rule, the executor's capability check and the Desktop states Read/Done/Dismiss)
- Optional (builder's call per spec): `internal/automations/templates/` New mail summary gains Open source and Chat "Draft replies". If done, the template tests (`templates_test.go`, `templates_e2e_test.go`) must stay green.

- [ ] **Step 1:** Edit the skill. Run `go test ./internal/automations/authoring/ -run TestCreateAutomationSkill_ExamplesParse`. Expected: PASS, with the new example parsing (it declares `outputs: [inbox]` and `inbox:reply`).
- [ ] **Step 2:** Edit the feature note. Its one-line entry in `CLAUDE.md`'s Feature Notes list gains "Inbox card buttons and Reply (2026-10-21)".
- [ ] **Step 3: Commit** `docs(automations): inbox card buttons and reply`.

---

### Task 10: Inventory amendments and the user guide

**Depends on:** Tasks 1–8 (the guard names must exist; `grep` each one before writing it)

**Files:**
- Modify: `docs/inventory/reaction-commands.md` (STRIP-01, STRIP-02, Changelog)
- Modify: `docs/inventory/automations.md` (AUTO-06, AUTO-09, Changelog)
- Modify: `docs/inventory/agent-actions.md` (AGENT-07 list + guard, Changelog)
- Modify: `docs/guide/features/inbox.md` (stays ≤ 8192 bytes), `docs/guide/reference/cli.md` (`automations reply`)
- Create: `docs/guide/features/automations-inbox-buttons.md`; Modify: `docs/guide/README.md` (catalogue line), `docs/guide/features/automations-recipes.md` (one link line; it is at 8180 bytes, so trim a sentence to stay ≤ 8192)

- [ ] **Step 1: STRIP-01.**
  - In the Observable, replace "`automation_outputs` (`kind='inbox'`, unread and not dismissed)" with "`automation_outputs` (`kind='inbox'`, neither done nor dismissed)".
  - Append: "Since 2026-10-21 (ask #475) the Actions tab is a list and a reading pane: a proposal opens in the reading pane — a `save_automation` proposal as a short summary with **Open Draft** and **Reject**, any other kind in `AgentActionCardView` — and an automation card's own buttons are drawn only from the `actions` its confirmed recipe wrote. A button never grants a permission: Link, Chat and Agent only navigate or prepare, and Reply queues a run under the recipe's confirmed manifest (AUTO-06, AUTO-09)."
  - In Test guards, replace `testStripListsUnreadInboxOutputs` with `testStripListsOpenInboxOutputs` and add `WatchtowerDesktop/Tests/Core/InboxListBuilderTests.swift::testSectionsAreProposalsTodayEarlier`.
- [ ] **Step 2: STRIP-02.**
  - Replace "(… and for an automation output Done/Dismiss)" with "(… and for an automation output Read/Done/Dismiss)".
  - Replace "an output's Done writes only `read_at`, Dismiss only `dismissed_at`" with "opening an output card writes only `read_at`, its Done only `done_at`, its Dismiss only `dismissed_at` — the three owner columns the Desktop writes. A Reply press is not a Desktop write: it runs `watchtower automations reply --output <id> --action <index>`, which records the press on the output (`pressed_action`, `pressed_run_id`, `pressed_at`) and queues the run in one Go transaction."
  - In guards, replace `::testDoneWritesOnlyReadAt` with `::testDoneWritesOnlyDoneAt`; add `::testOpeningWritesOnlyReadAt` and `WatchtowerDesktop/Tests/Core/InboxReplyPressTests.swift::testAuto09_ReplyPressOnlyQueues`.
- [ ] **Step 3: AUTO-09.**
  - In the Observable, replace "a second trigger of the same kind while one is queued is coalesced onto it" with "a second trigger of the same kind while one is queued is coalesced onto it, except an Inbox Reply press (`trigger='reply'`), which is never coalesced: one press is one run".
  - Append: "A Reply press (`automations reply`, 2026-10-21, ask #475) inserts exactly one `queued` `trigger='reply'` row, in the transaction that records the press on the output, and wakes the daemon. It does not go through the event bus; its `event_json` is `{"reply": {output_id, action, value, data, card}}` built from the stored output, never from the caller."
  - Guards: add `cmd/automations_reply_test.go — TestAuto09_ReplyCommandOnlyQueues`; `internal/db/automation_runs_test.go — TestRun_ReplyIsNeverCoalesced`; `internal/db/automation_outputs_press_test.go — TestPressInboxOutputAction_OnePressOneRun`; `WatchtowerDesktop/Tests/Core/InboxReplyPressTests.swift — testAuto09_ReplyPressOnlyQueues`.
- [ ] **Step 4: AUTO-06 (the Reply part only; part A's plan writes the draft-column and install-confirm-enable amendments).**
  - Append: "`inbox:reply` is a manifest entry like any other (2026-10-21, ask #475): it is in `approval_hash`, the confirming screen lists it as "Reacts to its own Inbox buttons", and `output.inbox` refuses a `reply` action without it (`PermissionDenied`). `automations reply` refuses a press when the automation is not runnable or its confirmed recipe lacks the capability, and the executor fails a `reply` run whose claimed snapshot lacks it (`error_kind='permission'`). A press runs the currently confirmed text; a button's `value` and `data` only steer code the owner confirmed."
  - Guards: `TestApprovalHash_InboxReplyIsHashed`, `TestOutput_ReplyActionNeedsInboxReply`, `TestAutomationsCLI_ReplyRefusedWhenNotRunnableOrNoCapability`, `TestExecutor_ReplyRunWithoutCapabilityFails`.
- [ ] **Step 5: AGENT-07.** Add `automations reply` to the list of refused gestures that otherwise need the owner's Confirm (granted with no window when the Desktop launched it). Guard: `TestAutomationsCLI_ReplyRefusedUnderAgentMarkers`.
- [ ] **Step 6: Changelog lines** (top of each file's Changelog):
  - reaction-commands.md: "- 2026-10-21 (Inbox reading pane and card actions, spec `docs/superpowers/specs/2026-10-21-automations-panel-and-inbox-design.md` §B, **owner approved in ask #475**): **STRIP-01 amended** — open (neither done nor dismissed) inbox outputs are listed; proposals open in the reading pane; card buttons come only from the confirmed recipe's `actions`. **STRIP-02 amended** — Read/Done/Dismiss are three owner columns (`read_at` on open, `done_at`, `dismissed_at`; migration 00146 backfills `done_at = read_at`), and a Reply press goes through the CLI, not a Desktop write. Guard changes, none weakened: `testDoneWritesOnlyReadAt` is replaced by `testDoneWritesOnlyDoneAt` with the same full-row comparison (every other column, `read_at` included, must be unchanged); `testStripListsUnreadInboxOutputs` is replaced by `testStripListsOpenInboxOutputs`, which also asserts that done and backfilled rows stay hidden; new `testOpeningWritesOnlyReadAt`, `testSectionsAreProposalsTodayEarlier`, `testAuto09_ReplyPressOnlyQueues`. STRIP-03 holds: Reject on the proposal pane goes through `AgentActionFeed`."
  - automations.md: "- 2026-10-21 (Inbox card actions, spec 2026-10-21 §B3–B4, **owner approved in ask #475**): **AUTO-09 amended** — the Reply press is a trigger that only queues, never coalesced (one press, one run), outside the event bus; **AUTO-06 extended** — `inbox:reply` is hashed and checked at write, press and run. Strengthening; no guard relaxed; `TestRun_CoalescesSecondTrigger` and `TestBus_EventsCarryNoContent` unchanged. Guards added: `TestAuto09_ReplyCommandOnlyQueues`, `TestRun_ReplyIsNeverCoalesced`, `TestPressInboxOutputAction_OnePressOneRun`, `testAuto09_ReplyPressOnlyQueues`, `TestApprovalHash_InboxReplyIsHashed`, `TestOutput_ReplyActionNeedsInboxReply`, `TestAutomationsCLI_ReplyRefusedWhenNotRunnableOrNoCapability`, `TestExecutor_ReplyRunWithoutCapabilityFails`."
  - agent-actions.md: "- 2026-10-21 (Inbox card actions, ask #475): strengthening, no guard relaxed. **AGENT-07** gains `automations reply` (refused under every marker; otherwise the owner's Confirm, granted without a window for the Desktop's own launch). Guard: `TestAutomationsCLI_ReplyRefusedUnderAgentMarkers`."
- [ ] **Step 7: Guide.**
  - `inbox.md`: "Handle the Actions list" becomes the list + reading pane: sections, the unread dot, opening marks read, Done vs Dismiss, the common row, arrow keys. Link to the new page.
  - `automations-inbox-buttons.md` (feature page template, `docs/guide/WRITING.md`): the four kinds as a reference table, what a press does, "Sent — run #N", Needs confirmation / Off, `inbox:reply` ("Reacts to its own Inbox buttons"), one Reply example.
  - `cli.md`: one row for `automations reply`.
  - Run `go test ./docs/guide/ ./internal/kb/ ./internal/chat/`, then `go test ./internal/chat -run TestBuildSystemPrompt_Golden -update` (a new page changes the prompt golden), then the first command again. Expected: PASS; `wc -c` of each touched feature page ≤ 8192.
- [ ] **Step 8:** `grep -rn` every guard name written in Steps 1–6 in `internal/`, `cmd/` and `WatchtowerDesktop/Tests/`. Each must hit exactly one test function.
- [ ] **Step 9: Commit** `docs: inbox reading pane and card actions (inventory, guide)`.

---

### Task 11: Gate and the owner's review

**Depends on:** Tasks 1–10

- [ ] **Step 1:** Run `bash scripts/dev-health.sh`. Stop if the last line is `HEALTH: overloaded`.
- [ ] **Step 2: Run the gate,** each command to a log with its exit code (`cmd > log 2>&1; echo "exit=$?"`): `make test`, `go test ./cmd/...`, `make test-swift`, `make lint-all`. Expected: exit 0 each. The known flakes (memory note) are re-run once before being treated as real.
- [ ] **Step 3: Render the shots** with `make desktop-shots DESKTOP_SHOTS=build/desktop-shots`. Expected files: `inbox-reading-pane-light.png`, `inbox-reading-pane-dark.png`, `inbox-proposal-pane-light.png`, `inbox-proposal-pane-dark.png`.
- [ ] **Step 4: Owner review ask** (Russian in the ask text, per the owner's memory; repo files stay English). Use `ask_owner`, kind review, attaching the four PNGs, the list of plan's calls above, and the three inventory amendments with their changelog lines. Questions:
  1. Reading pane and proposal pane look right in light and dark?
  2. Reminders inside Today/Earlier rather than their own section — keep?
  3. Plan's limits (2048-byte links, 100-character Reply value) — keep?

  Merge only after the owner answers.
- [ ] **Step 5:** Address the answer in a fix commit (or none), then hand the branch to `local-review`.
