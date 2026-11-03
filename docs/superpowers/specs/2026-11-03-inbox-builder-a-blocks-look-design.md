# Inbox builder A — blocks and the Look step (design)

**Umbrella:** [2026-11-02-inbox-builder-design.md](2026-11-02-inbox-builder-design.md) (board #1400, approved). **Plan:** [2026-11-03-inbox-builder-a-blocks-look.md](../plans/2026-11-03-inbox-builder-a-blocks-look.md). **Status:** design for owner review. The umbrella's owner decisions hold; this spec refines only what the umbrella marks as the agent's call. Its two open questions were answered in ask #445 (owner Dry run button; a `target` action kind) and are recorded under **Decisions**.

**Mockups** (sample data only; the native DesignShotCatalog shots of the same states are plan Task 1 and are what the owner checks before the rest is built):

| State | Mockup |
|---|---|
| Every block, one artifact | [`a-01-blocks.html`](../../design/mockups/inbox-builder/a-01-blocks.html) |
| Look step — never dry-run | [`a-02-look-empty.html`](../../design/mockups/inbox-builder/a-02-look-empty.html) |
| Look step — dry run running | [`a-03-look-running.html`](../../design/mockups/inbox-builder/a-03-look-running.html) |
| Look step — dry run failed | [`a-04-look-failed.html`](../../design/mockups/inbox-builder/a-04-look-failed.html) |
| Look step — preview (living, output picker) | [`a-05-look-preview.html`](../../design/mockups/inbox-builder/a-05-look-preview.html) |
| Look step — preview stale | [`a-06-look-stale.html`](../../design/mockups/inbox-builder/a-06-look-stale.html) |
| Look step — save with the AI-step warning | [`a-07-look-save-llm.html`](../../design/mockups/inbox-builder/a-07-look-save-llm.html) |
| Look step — no Inbox output / dry run made no card | [`a-08-look-no-card.html`](../../design/mockups/inbox-builder/a-08-look-no-card.html) |
| Look step — dry run stopped at a Quick Connection | [`a-10-look-stopped.html`](../../design/mockups/inbox-builder/a-10-look-stopped.html) |
| Target button — idle, waiting for approval, creating, stuck (Try again), task created, failed, propose error | [`a-11-target-button.html`](../../design/mockups/inbox-builder/a-11-target-button.html) |
| Inbox card — living, markdown fallback, unsupported version, unreadable layout | [`a-09-inbox-card.html`](../../design/mockups/inbox-builder/a-09-inbox-card.html) |

## Intent

An automation's Inbox card today is a title, a markdown body, a link and up to four buttons. Sub-project A gives it a **look**: a tree of native **blocks** the script emits, validated in Go, drawn by DesignKit on the Mac (and later by the phone from the same JSON). It also gives an automation a second lifecycle, **living** artifacts that are replaced in place by key, and gives the automation editor a **Look** step: the owner says in the editor chat how the card should look and sees it drawn from a dry run on real data, then saves it like any other edit.

## Goals

1. A versioned block document, the v1 block set, closed field lists and caps, validated in Go with readable errors; an unknown block refuses the output.
2. `output.inbox({title, blocks, key?, folder?, priority?, link?, actions?})`: A owns `blocks` and `key`; `folder` is a reserved seam that sub-project B fills. Actions gain a `target` kind whose press proposes a task (ask #445).
3. Living artifacts: `artifacts: living` in the recipe, one artifact per `(automation, key)`, upserted in the run's commit transaction; read state survives an identical rewrite; `output.remove({key})` deletes one; the validator requires `concurrency: 1`.
4. A Swift model in the Kit's `WatchtowerDesign` and a renderer in DesignKit; today's Inbox reading pane draws blocks; a card without blocks keeps its markdown body as one text block.
5. The Look step in the automation editor: a preview pane rendering a dry run's cards, re-rendered after each turn that dry-runs the draft, stale when the text moved on, an owner **Dry run** button, **Save Look** through the normal save and confirmation, and a warning before saving when the change adds an `llm()` step.

## Non-goals

- Folders, the Inbox menu, Needs approval, Waiting for me and the native row actions behind a `ref` — sub-project B (see **Contract with sub-project B**). A defines the `ref` field, validates it and gives B the renderer hooks; A draws no native action.
- Moving built-ins (Morning brief, Track my threads, Idea finder) to blocks — sub-project C. People and Catch Up — D.
- The phone renderer — F; A only puts the model where the phone can read it.
- A chart block, nested blocks, a template language, hand-editing in the preview (umbrella non-goals).
- Version history of a living artifact (umbrella).

## The block document

### Envelope

The script passes `blocks` as an array. Go stores the **document**:

```json
{"v": 1, "blocks": [ … ]}
```

- `v` is the schema version. Go writes only `1`. A reader that meets a higher `v` shows the card's plain text and the line "This card needs a newer Watchtower" (Swift decode state `unsupported`); it never guesses.
- The stored document is Go's canonical form: every key the script omitted that has a default is written out (a list's `rows` is `[]`, never absent), keys in a fixed order, no unknown key. Swift decodes only canonical documents.
- Blocks are flat in v1: a block never contains another block.

### Tone

`tone` is one of `neutral`, `info`, `success`, `warning`, `danger`, `accent`. Colours come only from this name: Swift maps it through `Tone` (`neutral` → `.secondary`, `info` → `Tone.status("blue")`, `success` → `Tone.success`, `warning` → `Tone.warning`, `danger` → `Tone.error`, `accent` → `Color.accentColor`). "Tone by condition" is the script's job: it computes the tone per row (`tone: hours > 24 ? "danger" : "neutral"`); the JSON has no condition language *(agent's call)*.

### Actions

A block action has exactly the grammar of a card action (`internal/automations/sdk_output_card.go`), which A extends by one kind: `{label, open | chat | agent: {task, workbench?} | reply | target: {title, intent?, parent?}, data?, primary?}`; `reply` needs `inbox:reply` and `target` needs `outputs: [target]` (`PermissionDenied` otherwise). The grammar moves into `internal/automations/blocks` (`blocks.ValidateAction`) so the card's `actions` and the block actions share one validator; the permission checks reach it through a callback (`Options.AllowKind`), so the leaf package never imports `automations`. The new kind is specified under **The `target` action** below.

**Press address.** Every action of a card has one index in the card's **flattened action list**: the card's own `actions` first (0…3), then each block action in document order (a list row's actions in row order, an `actions` block's actions in order). `automations reply --output <id> --action <index>` and the Desktop use that index. Go `blocks.FlattenActions` and Swift `ArtifactDocument.flattenedActions(cardActions:)` are pinned to the same order by the shared fixture. The card stays **one press per card** (`pressed_at`), as today.

### Blocks (v1)

Every string is trimmed; a required string must be non-empty after trimming. Limits are in characters (runes) unless marked bytes. Every block has `type`.

| `type` | Fields (required **bold**) | Rules |
|---|---|---|
| `heading` | **`text`** ≤ 200; `level` 1 \| 2 (default 1) | |
| `text` | **`markdown`** ≤ 16 KB (bytes) | Rendered under the chat's link rules (http, https, `watchtower-nav://`); images are not loaded |
| `list` | `title` ≤ 200; **`rows`** (0…200); `empty` ≤ 200 (shown when no row is drawn; default "Nothing here") | A row: **`title`** ≤ 300; `subtitle` ≤ 500; `badge` `{**text** ≤ 40, tone?}`; `tone` (the row's leading dot; absent = no dot); `link` (card URL rules); `actions` (0…3, the action grammar); `ref` `{**kind**, **id**}` |
| `table` | `title` ≤ 200; **`columns`** (1…6) `{**title** ≤ 60, align: leading \| trailing (default leading)}`; **`rows`** (0…100), each exactly `columns.length` cells | A cell is a string ≤ 200, or `{**text** ≤ 200, tone?, link?}` |
| `person` | **`name`** ≤ 120; `role` ≤ 120; `avatar` `{slack_user: "<account>:<user id>"}`; `lines` (0…10) of strings ≤ 300 or `{**text**, tone?}`; `link` | No image URL: the avatar is resolved from the local `users` table, else initials — a card never makes a network request *(agent's call)* |
| `metrics` | **`items`** (1…6) `{**label** ≤ 40, **value** ≤ 24, tone?, hint ≤ 120}` | One row of figures; `value` is text, so the script formats numbers |
| `link` | **`title`** ≤ 200; **`url`** (card URL rules); `subtitle` ≤ 300 | A tappable row, not a button |
| `actions` | **`actions`** (1…4, the action grammar) | A button row inside the body |

Row `ref` *(umbrella: agent's call on the mechanism; A owns the field)*: `kind` is one of `inbox_item`, `track`, `idea`, `reminder`, `action`; `id` is an integer > 0. `action` and `reminder` refs are accepted **only from a built-in automation** (`origin = 'builtin'`): an owner or chat-written recipe could otherwise put "Approve" next to a row whose text describes something else *(agent's call)*. A checks the shape only; whether the record exists or is open is read by B at render time.

**Document caps:** at most 40 blocks; at most 500 list and table rows in all; at most 50 actions in the flattened list (card actions included); the canonical document at most 128 KB (bytes, `MaxBlocksBytes`). Separators are never drawn and cannot be asked for.

### `body` and plain text

`blocks` and `body` are mutually exclusive in one call (`output.inbox(): pass body or blocks, not both`); `title` stays required. With `blocks`, Go stores `body` = `blocks.PlainText(doc)`: headings, text (markdown kept), list rows as `- title — subtitle [badge]`, tables as `a | b` lines, person name/role/lines, metrics as `label: value`, links as `title (url)`; action labels are left out. It is capped at `MaxOutputBodyBytes` (64 KB, clipped on a rune boundary with `…`). So every existing reader of `body` — Home's feed line, the notification text, search over outputs, the reading pane's copy action — keeps working without knowing blocks *(agent's call)*. An output without blocks is unchanged: `blocks_json = ''`, its markdown body drawn as one text block.

### Validation errors

Each refusal is a `ValidationError` thrown into the script (uncaught → the run fails with `error_kind = 'script'`, exactly like a bad `output.inbox` today), naming the path and the rule. The messages are pinned by the shared fixture. Examples:

- `output.inbox(): blocks[3]: unknown block type "chart"; the blocks are heading, text, list, table, person, metrics, link, actions`
- `output.inbox(): blocks[1].rows[5].badge.tone must be one of neutral, info, success, warning, danger, accent`
- `output.inbox(): blocks[2].rows[0] has 4 cells; the table has 3 columns`
- `output.inbox(): blocks[0]: unknown field "colour"`
- `output.inbox(): blocks[4].rows[2].ref: an action ref is only for built-in automations`
- `output.inbox(): the card has 61 actions; the limit is 50`
- `output.inbox(): blocks is 140213 bytes; the limit is 131072`
- `output.inbox(): blocks must be an array of blocks`

## SDK changes

`output.inbox({title, body?, blocks?, key?, folder?, priority?, link?, actions?})` (`internal/automations/sdk_output.go`):

- `blocks` — validated and canonicalised by the new package `internal/automations/blocks`; the call stores the document in the buffered `db.AutomationOutput.BlocksJSON` and the derived plain text in `Body`.
- `key` — a living artifact's key: a string 1…200 characters without control characters. It is required when the recipe says `artifacts: living` (`output.inbox(): key is required — this automation keeps living artifacts`) and refused otherwise (`output.inbox(): key is only for living artifacts; add "artifacts: living" to the recipe`).
- `folder` — reserved for sub-project B through a field hook (below). Until B registers it: `output.inbox(): folder is not available yet`.
- `output.remove({key})` — new, gated by `outputs: [inbox]` and `artifacts: living`; buffered like any output and committed only with `succeeded` (AUTO-04). Two writes of one key in a run: the later one wins in the buffer (an `inbox` after a `remove` re-creates, a `remove` after an `inbox` deletes) *(agent's call)*. Removing a key that does not exist is a no-op at commit. A dry run journals it `dry_run` and removes nothing (AUTO-12).
- `actions` (the card's own, at most 4) and every block action may use the `target` kind (below). Its failure paths after a press: the propose call fails (banner, button idle); the apply fails (`failed`, pressable with the error); the proposal is rejected (idle); the proposal is stuck in `approved`/`executing` because a process died (**stuck**, Try again on the same row, no duplicate task) — each specified under **The `target` action**.
- `output.report` is unchanged: no blocks, no key. `output.briefing` is unchanged.
- The content hash of an output is `blocks.ContentHash` = SHA-256 over the canonical JSON of `{title, body, blocks, priority, link, actions}` (blocks as the stored document, `null` when none). It is computed for every inbox output, feed ones too.

`MaxOutputsPerRun` (50) is unchanged. A living automation with more than 50 keys per run (People, sub-project D) is D's to raise; A does not move the cap.

### Recipe: `artifacts`

A new optional frontmatter key `artifacts: feed | living` (default `feed`) *(umbrella: lifecycle per automation, agent's call; the key is A's)*:

- It is in `approval_hash`, written only when `living`, so every existing recipe's hash is byte-identical (`TestApprovalHash_GoldenCanonicalBytes` unchanged).
- `artifacts: living` requires `outputs` to contain `inbox` and `concurrency: 1`. The parser refuses otherwise: `concurrency: an automation with living artifacts runs one at a time; set concurrency: 1` and `artifacts: living needs outputs: [inbox]`.
- The rule lives in one function, `automations.serialRunReasons(r *Recipe) []string`, so sub-project C adds the raw-window reader to the same check.
- `validate --json` `fields` gains `artifacts` (`"feed"` or `"living"`), so the draft column shows it with the other hashed fields and the confirmation sheet lists a change of it (D26).

### The `target` action (ask #445)

A button that turns a card or a row into a task, through the same approval path as every other proposal *(owner, ask #445)*.

**Recipe side.** `{label, target: {title, intent?, parent?}}`:

| Field | Rule | Message on refusal |
|---|---|---|
| `title` | required string, 1–200 characters after trimming (`create_target`'s `text` limit) | `output.inbox(): actions[1].target.title must be a non-empty string of at most 200 characters` |
| `intent` | optional string, at most 1000 characters | `… target.intent is 1204 characters; the limit is 1000` |
| `parent` | optional integer > 0, a target id | `… target.parent must be a target id` |
| other keys | refused | `… target: unknown field "due"` |
| manifest | `outputs` must contain `target` (it is already in `approval_hash`) | `PermissionDenied`: `output.inbox(): a target action needs outputs: [target]` |

`data` is refused on a target action, as on every kind but `reply`. Go stores it as `db.InboxAction{Kind: "target", Target: &db.InboxTargetAction{Title, Intent, Parent}}` (new constant `db.InboxActionTarget`); the shared fixture pins it. Nothing is checked against the database when the run writes the card: the parent can be closed or deleted by the time the owner presses, so the check is at propose and again at apply.

**The press.** The press does not create anything. The Desktop runs:

```
watchtower actions propose --tool create_target --surface inbox \
  --context-type automation_output --context-id <output id>:<flattened index>:<action hash> \
  --args '{"text": <title>, "intent": <intent>, "parent_id": <parent>, "reason": "From the Inbox card “<card title>” of <automation name>"}' --json
```

with no `--approve`: one pending `agent_actions` row, which the owner approves or rejects in the approval card like any other proposal (today in the Inbox; after sub-project B in **Needs approval**). `<action hash>` is `blocks.ActionHash(action)`: the first 16 hex characters of SHA-256 over the action's canonical JSON (Go and Swift, pinned by the shared fixture).

**Depends on STRIP-01, approved in ask #451.** The row has `surface = 'inbox'`, and today the action strip and the badge leave out every inbox-surface row (STRIP-01: an inbox proposal is approved by the same press, so it never needs a card). Sub-project B narrows that exclusion to `apply_track_action`, so other inbox proposals, this one included, show up as approval cards; the owner approved that change in ask #451 (with the AGENT-03/AGENT-07 lines it carries). The fallback this spec used to carry — dropping the `target` kind from v1 if #451 were refused — no longer applies.

**Registry changes** (`internal/tools/targets.go`, `cmd/actions_registry.go`):

- `create_target` gains the `inbox` surface. The inbox surface stays no trust place (`trustSurfaceErr`, `TrustSurfaces`): an inbox `create_target` is never auto-executed, it always waits for Approve.
- `create_target` gains an optional `parent_id` (integer > 0). It is accepted **only on the `inbox` surface**, through a new binding-aware check on the tool (`Tool.ValidateBinding func(b Binding, raw json.RawMessage) error`, called by `Registry.Propose` after `Validate`): on `main`, `reaction` and `automation` a `parent_id` is refused with `parent_id is only for an Inbox card's button`, so the main chat's "top-level task only" contract (TGT-BRIEF-01 note in `docs/inventory/targets.md`) does not widen. At propose and again in `Execute`, the parent must exist, be a personal target (`project_id IS NULL`) and not be `done` or `dismissed` (`parent_id: task #N is closed` / `… does not exist`); the new task is created as its child with the parent's level and period, `source_type = 'chat'`, `source_id = 'action:<id>'` as today.
- The proposal's context (`automation_output`, `<output id>:<index>:<action hash>`) is stored on the row; it is how the Desktop finds the button's state.

**The Desktop button** (`InboxCardAction`, the renderer's `onAction`): a target button draws `.kitSecondary` with an SF Symbol `checklist` and its label. Its state is read at render time from the newest `agent_actions` row whose `context_type = 'automation_output'` and `context_id` equals `<output id>:<index>:<hash of the drawn action>`. The `agent_actions.status` CHECK is `pending, approved, rejected, applied, failed, executing`, plus `dismissed_at` on a failed row; every one is mapped ([a-11](../../design/mockups/inbox-builder/a-11-target-button.html)):

| Newest proposal for this button | Button |
|---|---|
| none | **idle** — pressable |
| `pending` | **waiting** — disabled, "Waiting for approval"; a click opens the approval card |
| `approved` or `executing`, and in flight (this Desktop's own approve/apply process for the row is running, or `decided_at` is less than `TargetButtonStuckAfter` = 2 minutes old) | **creating** — disabled, "Creating task…" with a small progress mark |
| `approved` or `executing`, not in flight (no live process of ours and `decided_at` 2 minutes old or more) | **stuck** — "Didn't finish" with **Try again** (see "A proposal stuck in approved or executing") |
| `applied`, and its task still exists (a target with `source_id = 'action:<row id>'`) | **created** — "Task created"; a click opens that target |
| `applied`, its task since deleted by the owner | **idle** — pressable; a new press makes a new proposal (allowed, see "Exactly one task per proposal") |
| `rejected` | **idle** — pressable (the owner said no to that proposal, not to the button) |
| `failed`, `dismissed_at = ''` | **failed** — the apply error line and **Try again**, which retries the same row (`actions apply <id>`), never a new proposal |
| `failed`, `dismissed_at` set | **idle** — pressable |
| the propose call itself failed (non-zero exit, no row) | **idle** plus a `WriteErrorBanner` with the stderr reason; nothing is cleared before a write succeeded |

**A proposal stuck in `approved` or `executing`.** Nothing moves such a row today: `Registry.ExpireSessionCalls` expires only session-applied `claude_ai_connector_call` rows, and the one way out of `executing` is the owner's `actions apply --force <id>` (`prepareApply` in `cmd/actions.go`), which marks the row `failed` and retries. A `create_target` apply takes milliseconds, so a row still `approved` or `executing` two minutes after its approval (`decided_at`; `executing` stamps no time of its own) belongs to a process that died, and no live process of this Desktop is working on it. The button then shows **stuck** with **Try again**, an owner press:
- `approved` — `actions apply <id> --json`. The row never reached `executing`, so the tool provably never ran; this is the ordinary apply.
- `executing` — `actions apply <id> --force --json`: the existing reclaim (`executing → failed`, then the ordinary `failed → executing` claim). Re-running `create_target` on a guess is safe because its `Execute` creates **at most one task per action id**, enforced by the database, not by a look-up (see "Exactly one task per proposal" below). The retry therefore ends `applied` with the one task, never a second one.
Both commands already refuse under every agent marker (AGENT-07); the Desktop runs them only on the owner's press and keeps the press in the Inbox center (it survives navigation). The same rule and **Try again** apply in the approval card of such a row. No sweep is added and no row is moved without the owner's press *(agent's call: the smallest mechanism; a daemon sweep that marks rows `failed` would race a slow apply and needs its own exactly-once argument)*. A failed **Try again** lands in **failed** or the propose-error banner like any apply.

**Exactly one task per proposal.** What the code does today: `create_target`'s `Execute` (`internal/tools/targets.go`) is the only writer of a `source_id` starting with `action:` (`source_type = 'chat'`, `source_id = 'action:<agent_actions.id>'`); the Desktop's own `chat` writer uses `target:<id>`. `targets` has only a plain index on `(source_type, source_id)`. `Registry.Apply` claims a row with a compare-and-set (`approved|failed → executing`, `TransitionAgentAction`), and its finish is a compare-and-set from `executing`. The claim keeps two applies of one row apart only while the row is in `executing`. The owner's `--force` reclaim deliberately takes that away (`executing → failed → executing`), so a find-then-insert in `Execute` alone would not be race-proof. A takes option (a):

- **A partial unique index**, `CREATE UNIQUE INDEX idx_targets_action_source ON targets(source_id) WHERE source_type = 'chat' AND source_id LIKE 'action:%' AND source_id != 'action:0'` (new migration, mirrored into `schema.sql`, the golden and the Swift test schema). **Rebuild note:** a later table rebuild of `targets` or `agent_actions` must recreate both partial unique indexes with their `WHERE` clauses (the add-migration skill's "Recreate every index" step gains a line naming them); `TestAgent05_ButtonIndexesPresent` reads `sqlite_master` of a freshly migrated database and fails if either index is missing, is not `UNIQUE`, or has another `WHERE` clause.
- **Insert-or-return** in a new `db.CreateTargetForAction(t Target, actionID int64) (id int64, created bool, err error)`: `INSERT … ON CONFLICT DO NOTHING RETURNING id`; when no row comes back, it reads the existing id by `source_id`. Both statements run in one write transaction, so the read sees the row that won. `create_target`'s `Execute` calls it and returns that id as its result either way — **only when `call.ActionID > 0`**. A call with `ActionID == 0` (no registry row: direct `Execute` in tests, such as the `agentloop` tests that run `create_target` through a fake registry) keeps today's plain `CreateTarget` with `source_id = 'action:0'`, which the index's `source_id != 'action:0'` leaves out, so those calls never conflict. The existing `TestCreateTarget_ExecuteMatchesRemindShape`, `TestCreateTarget_ExecuteConvertsOwnerLocalDueToUTC` and `TestCreateTarget_ExecuteLeavesDateOnlyDueUnconverted` (ActionID 42/1/1, each on its own database) and the `agentloop` loop tests are unaffected.
- **Existing data.** One apply per row is the norm, so duplicates should not exist. They can exist only if a `--force` retry ever ran after a dead apply had already inserted. The migration does not assume none exist. Before creating the index it renames every duplicate but the oldest (`source_id = source_id || ':dup' || id` for every row of a duplicated `action:` source other than `action:0`, except `MIN(id)`). No owner task is deleted or changed except that key, and the index then builds on any database.

The overlap cases, each ending with one task:

| Overlap | What happens |
|---|---|
| A "dead" apply is in fact still running (slow) when the owner's **Try again** runs `apply --force` | The reclaim moves the row `executing → failed → executing`, and both processes reach `Execute`. The second insert hits the unique index and returns the first one's id. Each finish is a compare-and-set from `executing`: the first lands `applied`, and the other is refused by the CAS and reports the row as already decided. One task, row `applied`. |
| Two **Try again** presses (two windows, or a double click) on an `approved` row | Both run `actions apply`; the claim's compare-and-set lets one move `approved → executing`, and the other gets `ErrBadTransition` before `Execute`. A double press of `apply --force` on an `executing` row behaves like the row above. |
| Two presses of the button itself (two windows) before either propose returns | Two `actions propose` calls would make two proposals with two action ids, and the targets index cannot catch that. So the same migration adds `CREATE UNIQUE INDEX idx_agent_actions_open_context ON agent_actions(context_type, context_id) WHERE context_type = 'automation_output' AND status IN ('pending','approved','executing')`. The second insert is refused, and the Desktop shows the first one's state. The context carries the action hash, so a changed button is a new context. The Inbox center also runs one press per context at a time, so the refusal is a backstop. |
| A press after the button's task was created | `applied` is **not** in the index, so a deleted task never locks the button. Instead, `Registry.Propose` for an `automation_output` context runs, in the same write transaction as its insert (`db.InsertInboxButtonProposal`, `BEGIN IMMEDIATE`), a check: if an `applied` row for this context exists **and** its task still exists (`targets.source_id = 'action:<that row id>'`), the propose is refused as a duplicate; if the task was deleted, the new proposal is accepted. |
| A retry of an older `failed` row while a newer open row exists for the same button | The retry's claim (`failed → executing`) would violate the open-context index. **Try again** is offered only on the newest row for a context, so the Desktop never asks for it. `actions apply` (`--force` included) on a row whose context already has a newer `pending`/`approved`/`executing` row is refused before any state change ("A newer proposal for this button is open (#N)"), checked in `prepareApply`. A stray unique-index violation raised by the claim's `UPDATE` is mapped to the same error; the failed `UPDATE` changes nothing. |

**Where the refusal surfaces.** `internal/db` maps a unique-constraint error naming `idx_agent_actions_open_context`, and the propose-time applied check, to typed errors `db.ErrButtonHasOpenProposal{ID}` and `db.ErrButtonTaskExists{ID, TargetID}`. `tools.Registry` returns them wrapped. `actions propose` and `actions apply` exit with code **3** (other refusals stay code 1), and stderr reads "This button already has a proposal (#N)", "This button's task already exists (task #T)" or "A newer proposal for this button is open (#N)". The Desktop treats exit 3 as "state moved": it re-reads the button's proposals and draws their state — waiting, creating, created — with no error banner. Any other non-zero exit is the propose-error banner as before.

**The action hash in the context, for every state.** A living card keeps its output id across rewrites, so `<output id>:<index>` alone could point at a proposal made from another button: the action at that index may now be a different task, or a reply button. Because the context also names the action's hash, every state above — `applied` as much as `pending` — is looked up for exactly the action drawn: a rewrite that changes the button's title, intent or parent, or moves another action to that index, finds no row and draws **idle**; "Task created" never shows on a different button. A rewrite that leaves the button's action identical keeps its state *(agent's call)*: it is the same task, and drawing it pressable again would invite a duplicate; whether the rest of the card changed does not matter to the task. A press while a proposal for the same button is `pending`, `approved` or `executing` is not offered; **Try again** on a stuck row reuses that row, it never proposes a second one. In `.preview` mode the button is drawn disabled like every other one.

## Storage

One migration, number = the next free at implementation time (in-flight branches may take 00172 and up); the plan calls it `00NNN_automation_output_blocks.sql`. Columns on `automation_outputs`, not a new table *(agent's call: an artifact is an output — read/done/dismiss, the press, the run link, purge and the cascade from `automations` already work on this row; a second table would duplicate all of them)*. Plain `ALTER TABLE … ADD COLUMN`, no CHECK change, so no table rebuild:

| Column | Meaning |
|---|---|
| `blocks_json TEXT NOT NULL DEFAULT ''` | the canonical document; `''` = none (markdown body) |
| `output_key TEXT` | a living artifact's key; `NULL` = feed |
| `content_hash TEXT NOT NULL DEFAULT ''` | `blocks.ContentHash`; `''` on rows from before the migration |
| `written_at TEXT` | the last run that wrote this row; backfilled to `created_at`; never NULL after the migration |
| `changed_at TEXT` | the last write that changed `content_hash`; backfilled to `created_at`; the Inbox order |

Indexes: `CREATE UNIQUE INDEX idx_automation_outputs_key ON automation_outputs(automation_id, output_key) WHERE output_key IS NOT NULL` and `CREATE INDEX idx_automation_outputs_changed ON automation_outputs(kind, changed_at)`. Mirrored into `internal/db/schema.sql`, the schema golden and `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`.

### Living upsert and read state

In `commitRunTx` (`internal/db/automation_runs.go`), still inside the run's one finish transaction:

- A feed output inserts as today, now with `blocks_json`, `content_hash`, `written_at = changed_at = created_at = stamp`.
- A living output upserts on `(automation_id, output_key)`: a new key inserts; an existing key keeps `id` and `created_at`, takes the new `run_id`, title, body, blocks, priority, link, actions, `content_hash` and `written_at = stamp`. **Only when `content_hash` differs** it also sets `changed_at = stamp` and clears `read_at`, `done_at`, `dismissed_at`, `pressed_action`, `pressed_run_id` and `pressed_at` — a changed artifact is new to the owner, and its one press belongs to the new content *(agent's call: Done and Dismiss mean "this version"; the umbrella's "unread again only when its content hash changed")*. A same-hash rewrite changes none of them.
- A removal deletes the row with that `(automation_id, output_key)`.
- Order within one commit is the buffer's order; the buffer already collapsed repeats of one key.
- Every other terminal status leaves all of it byte-identical (AUTO-04).

### The Desktop's read-state writers

The only writers of `read_at`, `done_at` and `dismissed_at` are the Desktop's `AutomationQueries.markOutputOpened`, `markOutputDone` and `dismissOutput` (`WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/AutomationQueries.swift`, called from `ActionStripViewModel` and `HomeFeedActions`); Go writes none of them except through the upsert above. Today they mark by id alone, so a living rewrite that lands between the render and the press would mark a version the owner never saw — read, done or dismissed. They gain the drawn version: `markOutputOpened(db, id:, contentHash:, now:)` and the same for the other two, with `WHERE id = ? AND content_hash = ? AND …` on top of their existing conditions. A row from before the migration has `content_hash = ''` and the card read it as `''`, so they still match. A mismatch changes nothing and returns `false` (`db.changesCount == 0`); the caller then re-reads the card and leaves its UI state as the database says — it never clears a row optimistically before the write succeeded (review rules, error handling). The unread dot on a newly changed card is therefore exactly as reliable as the upsert.

### Notifications

No notice is posted for an Inbox card today: the run notices (`AutomationRunNotifier`) are per run — a palette or tray run's finish, failures, disabling — and do not change. The rule for any card-level notice (sub-project B's folders, or later) is fixed here: a card may be announced only when its row is new or its `content_hash` changed, which is exactly when `changed_at` moves and `read_at` is cleared. A same-hash rewrite moves only `written_at` and never counts as new — not in a notice, not in the unread badge (`AutomationQueries.inboxOutputCount`), not in Home's feed. A notice is also capped per automation: at most one per run, naming the count ("Threads waiting for me: 3 cards changed"), so a living automation that rewrites 50 cards never posts 50 notices. Tests pin it on both sides (Test strategy).

Readers: the Inbox and Home order automation cards by `changed_at` (not `created_at`), so a living artifact moves up only when it changed. The card's source line reads "Updated 10 min ago" from `written_at` for a living artifact, "Run #N" as today otherwise.

### Reply presses on a card with blocks

`db.PressInboxOutputAction` resolves the index in the flattened list. `automations reply` gains `--content-hash <hash>`: the Desktop always passes the hash of the card it drew; when the row's `content_hash` differs the press is refused with `ErrOutputChanged` ("This card changed — look again") and nothing is queued, so a living artifact rewritten between drawing and pressing never queues a press of a different button. Without the flag (an older Desktop, the CLI by hand) the press works as today.

**A queued reply run after a rewrite.** A press that passed the check queues a `trigger='reply'` run, and a later run of the same automation may rewrite the card before the queued one starts (the reply run waits for the automation's one slot, `concurrency: 1`). The run would then act on a button whose content is gone. So `db.ReplyTrigger` gains `content_hash` — the hash the press was checked against, written into `event_json` by `PressInboxOutputAction` — and the executor, before the script starts (beside today's `inbox:reply` check in `executor_run.go`, on every start, a resumed one too), compares it with the row's current `content_hash`. A different hash, or a row deleted by `output.remove`, ends the run `cancelled` with `error_kind = 'cancelled'` and the error "The card changed after the button was pressed; nothing ran. Press the button on the updated card." The script never runs, nothing is committed, and the press stays recorded on the old version only (the rewrite already cleared it). *Why not a new `skipped` status:* `automation_runs.status` has a CHECK, so a new value needs a table rebuild of a hot table for a label `cancelled` with a reason already gives. A press recorded before this release has no `content_hash` in its payload and runs as today. A `target` button needs no such check: its proposal carries its own args and the owner approves exactly those.

## The Swift side

### Model — `WatchtowerKit/Sources/WatchtowerDesign/ArtifactBlocks.swift`

The model lives in the Kit's `WatchtowerDesign`, the one module both DesignKit and the iPhone app already link; it is Foundation-only value types plus the tone mapping *(agent's call: F renders the same JSON with the same decoder; WatchtowerCore stays Kit-free)*.

- `ArtifactDocument` (`version`, `blocks: [ArtifactBlock]`), `ArtifactBlock` (one case per block type), `ArtifactListRow`, `ArtifactTableCell`, `ArtifactMetric`, `ArtifactPersonLine`, `ArtifactBadge`, `ArtifactTone`, `ArtifactAction` (the card action shape), `ArtifactRef` (`kind: ArtifactRefKind`, `id: Int64`).
- `ArtifactDocument.decode(_ json: String) -> ArtifactDecodeResult` with four states: `.none` (empty string), `.document(ArtifactDocument)`, `.unsupported(version: Int)`, `.unreadable` — present-but-undecodable is never folded into none (review rules, error handling).
- `flattenedActions(cardActions:)`, `refs` (every row ref in order — B's folder count), `Tone.artifact(_:)` in `Tone.swift`.

### Renderer — `WatchtowerDesktop/Sources/DesignKit/Artifacts/`

`ArtifactView(document:cardActions:mode:)` draws the blocks top to bottom at the width its host gives it (the host keeps one readable column, `ReadableColumn.maxLineWidth`, which lives in WatchtowerCore), from kit parts only: headings as `.headline`/`.subheadline`, list rows as `.kitRow` without separators, table on a `.card()` fill, metrics as a row of `.card()` tiles, person as a `.card()` with avatar/initials, badges as `Chip`, actions as `.kitSecondary` buttons (the first primary action `.kitPrimary` only at card level, keeping one prominent action), section spacing from `Spacing`. Colours only through `Tone.artifact`.

DesignKit cannot see the app, so the app injects what it owns through one environment value, `ArtifactEnvironment`:

- `markdown: (String) -> AnyView` — the app passes `MarkdownView` (chat link rules); the default draws `Text(AttributedString(markdown:))` inline-only.
- `avatar: (String) -> AnyView?` — the app resolves a `slack_user` from the local `users` table; nil draws initials.
- `onAction: (Int) -> Void` — the flattened index; the app routes it through the existing `InboxCardAction` handling (open with the link rules, chat, agent, reply via `automations reply --content-hash`).
- `refHooks: ArtifactRefHooks` — B's seam (below); the default draws every row and no native action.

`mode` is `.inbox` or `.preview`. In `.preview` every button is drawn but disabled, with the help text "Buttons work in the Inbox"; links still open.

### Today's Inbox

Until B replaces the Inbox screen, `InboxReadingPane` draws an automation card's blocks with `ArtifactView` when `blocks_json` decodes; the markdown body otherwise; on `.unsupported` or `.unreadable` the plain-text body with the line "This card needs a newer Watchtower" (unsupported) or "This card's layout can't be read" (unreadable). The list row keeps title, unread dot and time; a living card shows "Updated …" from `written_at`. `AutomationOutputCard` gains `blocksJSON`, `outputKey`, `contentHash`, `writtenAt`, `changedAt`; `AutomationQueries` and `HomeFeedQueries` order by `changed_at`.

## The Look step

### Where it sits

The editor panel (`WatchtowerDesktop/Sources/Views/Automations/AutomationEditorPanel.swift`) keeps its left side (Chat | Form | Script) and its right draft column. The draft column gets a step picker (`KitSegmentedPicker`): **What it collects · Look · When it runs** *(agent's call on the exact split, matching the umbrella's mockup tabs)*:

- **What it collects** — the column's existing boxes It may, Sends, Changed, the dry-run lines and errors;
- **Look** — the preview pane;
- **When it runs** — When, Each run, Missed and concurrency, and Artifacts (feed / living).

The footer (Save, the shell warning, the #559 warning and the new AI-step warning) is the same under every step; under **Look** its primary button reads **Save Look**. `AutomationDraftColumnModel` is unchanged in what it decides — AUTO-06's "every hashed field is shown before a save" still holds, because the save confirmation sheet shows every hashed field regardless of the step the owner is on. The chosen step is per editor key in `AutomationEditorCenter` (survives navigation). `AppState.openAutomationEditor(_ target:, step:)` opens the panel at a step; B's "Edit the look…" calls it with `.look`.

### Where the preview comes from

The preview is a dry run in memory of the exact text on screen (the umbrella: "the preview is a dry run, not a second renderer"). Two producers write the same `DraftResult` shape:

1. **The editor chat.** `draft_automation` on the `automation_editor` surface already caches each result per conversation (`automation_draft_cache`). The `create-automation` skill is told: after any change to the look, call `draft_automation` before answering. `DraftOutput` gains `blocks` (the document, or `null`), `key` (`""` for feed) and `content_hash`. So "re-render after each look-changing turn" = the newest cache entry whose `recipe_text` equals the text on screen.
2. **The owner's Dry run button** — `watchtower automations preview --stdin --json [--slug S] [--workbench N] [--builtin ID]`: the same evaluation as `draft_automation` (validate, then `DryRunInMemory` with the draft bounds), result on stdout, nothing written, refused under every agent marker (owner-only, like the dry run of an unconfirmed recipe, ask #271). Its tokens are the owner's spend on the owner's press. This new dry-run path is approved in ask #445 (AUTO-06/AUTO-12 amendment). The result is kept in `AutomationEditorCenter` per editor key.

The pane shows whichever of the two is newer for the text on screen.

### States

`AutomationLookPreviewModel` (WatchtowerCore, pure, tested) turns (text on screen, the recipe's `outputs`, the newest chat entry, the newest owner result, the press in flight) into one state:

| State | When | What the pane shows |
|---|---|---|
| `noInboxOutput` | the recipe has no `outputs: [inbox]` | "This automation doesn't make an Inbox card." and a hint to ask the chat for one ([a-08](../../design/mockups/inbox-builder/a-08-look-no-card.html)) |
| `empty` | no dry run of any text yet | "Dry-run the recipe to see its card on your data." + **Dry run** ([a-02](../../design/mockups/inbox-builder/a-02-look-empty.html)) |
| `running` | the owner's press is in flight | a progress line "Dry run — reading your data…" and **Stop** (cancels the CLI process) over the last preview, dimmed, or over the empty state ([a-03](../../design/mockups/inbox-builder/a-03-look-running.html)) |
| `failed` | the newest dry run of this text ended other than `succeeded`/`stopped`, or did not parse | the error line (`WriteErrorBanner`), the last steps of the journal, **Dry run** again; a validation error in `output.inbox` is shown with its path ([a-04](../../design/mockups/inbox-builder/a-04-look-failed.html)) |
| `noCard` | the dry run succeeded and made no inbox output | "This dry run made no card — it found nothing to show." + tokens ([a-08](../../design/mockups/inbox-builder/a-08-look-no-card.html)) |
| `preview` | the newest dry run of this text made ≥ 1 inbox output | the first card through `ArtifactView(mode: .preview)`, title and priority above it, "Dry run · 3 100 tokens · just now"; with more than one card a picker "Card 1 of 12 ▾" listing each card's title (and key for living) ([a-05](../../design/mockups/inbox-builder/a-05-look-preview.html)) |
| `stale` | the newest dry run is of other bytes than the text on screen | the last preview dimmed, with "The recipe changed since this preview." + **Dry run** ([a-06](../../design/mockups/inbox-builder/a-06-look-stale.html)) |
| `stopped` | a draft stopped at `mcp()` (ask #326) ([a-10](../../design/mockups/inbox-builder/a-10-look-stopped.html)) | the cards made before the stop, if any, with "The dry run stopped at a Quick Connection; dry-run the saved recipe from its card to see the rest." |

### The AI-step warning

`validate --json` gains `adds_llm` (bool): true when the text has more `llm(` call sites than the confirmed text, or gains an `llm:` permission the confirmed text does not have; for a new recipe, true when it has any. Call sites are counted lexically by `automations.LLMCallSites(script)` over the existing `jsScan` (comments and strings skipped; `x.llm(` is not a call site). When `adds_llm` holds, the footer shows, above Save, on every step: **"This change adds an AI step: every run will use the model."** plus "This dry run used N tokens." when a dry run of this text exists ([a-07](../../design/mockups/inbox-builder/a-07-look-save-llm.html)). It is a line, not an extra click *(agent's call)*: the confirmation sheet that follows lists the `llm:` permission as today.

### Built-ins and primitives

A built-in's primitive (`brief.compose`, `plan.compose`) does nothing in any dry run (AUTO-12), so a built-in whose card text comes from a primitive previews the parts the script computes and a placeholder line for the primitive's part. That is sub-project C's to design when it moves the built-ins to blocks; A only shows it honestly.

## Phone compatibility

The phone does not show automation cards today (no reader in `WatchtowerMobile` or `WatchtowerKit`). The model is in `WatchtowerDesign` so F decodes the same canonical JSON with the same decoder and fixture; F writes its own SwiftUI renderer. A puts no `blocks_json` into any mobile slice.

## Inventory contracts touched

The AUTO-* changes for `blocks`/`folder`/`key`, removal by key, the row `ref` and `concurrency: 1` for living outputs are approved (ask #961); the owner preview path (AUTO-06/AUTO-12) and the `target` action kind (AUTO-02) are approved in ask #445. STRIP-01 is approved in ask #451, and AGENT-05 is approved by the owner's approval of this spec. Exactly these entries change, each in the same commit as its code — AUTO-02, AUTO-04, AUTO-05, AUTO-06, AUTO-12 in `automations.md`; AGENT-05 in `agent-actions.md`; STRIP-01 in `reaction-commands.md` (landed by B); and Changelog lines in `agent-actions.md` and `targets.md`:

- **AGENT-05** (`docs/inventory/agent-actions.md`) — approval source: approved by the owner's approval of this spec. `create_target` creates at most one task per action id, enforced by the partial unique index `idx_targets_action_source` with insert-or-return. An open proposal per Inbox button context is unique (`idx_agent_actions_open_context`). So neither the owner's reclaim of a stuck `executing` row (`actions apply --force`), nor a slow apply overlapping it, nor a double press can create a second task. A strengthening; the claim and its guards are unchanged. New guards: `TestAgent05_CreateTargetReclaimDoesNotDuplicate`, `TestAgent05_CreateTargetConcurrentApplyOneTarget`, `TestAgent05_InboxButtonOneOpenProposal`, `TestAgent05_DeletedTaskUnlocksButton`, `TestAgent05_OlderRowRetryRefused`, `TestAgent05_ButtonIndexesPresent`, `TestMigration_TargetsActionSourceDuplicatesRenamed`.
- **STRIP-01** (`docs/inventory/reaction-commands.md`) — **approved in ask #451**: B narrows the strip's and the badge's exclusion of inbox-surface rows to `apply_track_action`, so a target proposal shows as an approval card. B lands that change; A depends on it and does not edit STRIP-01 itself.
- **AUTO-02** — an Inbox card may carry a `target` button; its press proposes `create_target` through `Registry.Propose` on the `inbox` surface and nothing is written until the owner's Approve; a target action needs `outputs: [target]`. New guards: `TestOutput_TargetActionNeedsTargetOutput`, `TestAuto02_TargetButtonOnlyProposes` (`cmd`: a press records one pending row, no target), `TestCreateTarget_ParentIDOnlyOnInbox`.

- **AUTO-04** — the commit also upserts living outputs by `(automation_id, output_key)` and applies `output.remove`; every other terminal status leaves living rows byte-identical too. New guards: `TestAuto04_LivingUpsertCommittedOnlyOnSuccess`, `TestAuto04_RemoveCommittedOnlyOnSuccess`.
- **AUTO-05** — `artifacts: living` requires `concurrency: 1` (parse error otherwise). New guard: `TestAuto05_LivingArtifactsNeedConcurrencyOne`.
- **AUTO-06** — `artifacts` is in `approval_hash` (absent for feed, so existing hashes are unchanged); a reply press with a stale `--content-hash` is refused, and a queued reply run whose card changed before it started is cancelled before its script runs; the owner preview CLI refuses under every agent marker (approved in ask #445). New guards: `TestExecutor_ReplyRunOnChangedCardCancelled`, `TestApprovalHash_ArtifactsIsHashed`, `TestApprovalHash_GoldenCanonicalBytes` unchanged, `TestAutomationsCLI_PreviewRefusedUnderAgentMarkers`, `TestAutomationsCLI_ReplyRefusedWhenCardChanged`.
- **AUTO-12** — approved in ask #445: the owner preview (`automations preview`) is a dry run in memory like `draft_automation`: no row of any table, `output.remove` journals `dry_run`. New guards: `TestAutomationsCLI_PreviewWritesNoRows`, `TestOutput_RemoveDryRun`.

Outside `automations.md`: `docs/inventory/agent-actions.md` and `docs/inventory/targets.md` get a Changelog line each (ask #445) — `create_target` is on the `inbox` surface (never trusted, AGENT-01/AGENT-07 hold) and takes `parent_id` there only; the TGT-BRIEF-01 sentence that lists `create_target`'s surfaces is updated, its contract (the main chat creates top-level tasks only) unchanged, and `TestBuildToolRegistry_PinsWriteToolsReadToolsAndSurfaces` pins the new surface. The `ref` kinds' native actions and their contracts are B's.

## Test strategy

- **Shared fixture** `internal/automations/blocks/testdata/blocks_cases.json`: `valid` cases (script input → canonical document, plain text, flattened action count, content hash) and `invalid` cases (input → exact error message), plus `unsupported` documents (`v: 2`). Go `blocks` tests and Swift `ArtifactBlocksTests` (Kit) both read it; adding a block or field without a case fails the coverage test that every block type and every optional field appears in at least one valid case.
- **Go** `internal/automations/blocks`: every rule and cap at the limit and one past it; degenerate inputs — `blocks: []` (valid, an empty document draws nothing but the title), a list with zero rows (valid, `empty` text), a table with zero rows, `null` where an object is expected, a number where a string is expected, NaN/Infinity in a value, a 200-row list with a ref on each, a document at exactly `MaxBlocksBytes`; canonical output stable under key order; plain text clipped on a rune boundary.
- **Go** `internal/db`: after a changed-hash upsert the Desktop's guarded mark statement (the same SQL text, `WHERE id = ? AND content_hash = ?` with the old hash) changes 0 rows, after a same-hash upsert it changes 1; a same-hash upsert leaves `changed_at` and `read_at` as they were (the notification rule); a reply payload carries `content_hash`; upsert keeps `id`/`created_at`; same hash keeps read/done/dismissed/press; changed hash clears them and moves `changed_at`; removal of a missing key; feed rows untouched; a failed run commits nothing (AUTO-04); the partial unique index refuses a second row per key on a raw insert; migration on a database with existing outputs backfills `written_at`/`changed_at`.
- **Go** `internal/automations`: `output.inbox` with blocks/key in feed/living recipes; `body`+`blocks` refused; `folder` refused without a hook and passed to a registered hook; `output.remove` ordering in the buffer; dry run journals `dry_run`; `artifacts` parse and hash rules; `LLMCallSites` over comments, strings, template text and `x.llm(`.
- **Go** concurrency: `TestAgent05_CreateTargetConcurrentApplyOneTarget` — on a file database, two goroutines run `Execute` of one action id at once (the slow-apply-vs-`--force` overlap, the reclaim in between), and the result is one target row, both get the same id, and the row ends `applied` once; `TestAgent05_InboxButtonOneOpenProposal` — two concurrent `actions propose` with one context leave one pending row, the second is refused, and after `rejected` a new propose is accepted; `TestMigration_TargetsActionSourceDuplicatesRenamed` — a database with two `action:7` targets migrates, the newer one gets `action:7:dup<id>`, no row is deleted, and the index exists.
- **Go** button refusals and the ActionID-0 path: `TestCreateTarget_ActionIDZeroPlainInsert` — two `Execute` calls with ActionID 0 create two targets, no conflict; `TestActionsPropose_ButtonRefusalExit3` — a second propose for a context with an open row, and a propose while the context's applied task still exists, exit with code 3 and the spec's stderr text, writing no row; `TestActionsApply_OlderRowExit3` — `actions apply` and `--force` on an older row while a newer open row exists exit 3, the older row unchanged; any other refusal stays exit 1.
- **Go** stuck proposals: `TestAgent05_CreateTargetReclaimDoesNotDuplicate` — `create_target` applied once, the row forced back to `executing` (a process died after the insert), `actions apply --force` ends `applied` with the same target id and one target row; a row left `executing` before the insert ends `applied` with one new target; an `approved` row applies normally.
- **Go** `target` kind: every field rule and message; `outputs: [target]` missing → `PermissionDenied`; `data` on a target refused; `create_target` with `parent_id` on `main`/`reaction`/`automation` refused, on `inbox` accepted; parent missing, done, dismissed or on a workbench board refused at propose and, when it closed meanwhile, at apply (the row lands `failed`, no target); applied child has the parent's level and period; an inbox `create_target` is never auto-executed whatever trust `main` has.
- **Go** executor: a reply run whose card was rewritten (changed hash) or removed after the press ends `cancelled` with the reason and runs no step; a same-hash rewrite does not stop it; a payload without `content_hash` runs as before.
- **Go** `cmd`: `actions propose --tool create_target --surface inbox` without `--approve` records one pending row with the context and creates no target; `preview --stdin --json` pinned keys, refusal under every marker, no rows written; `reply --content-hash` match / mismatch / absent; `validate --json` `adds_llm` and `fields.artifacts`.
- **Swift** target button: `TestTargetButton_Exit3RereadsWithoutBanner` — a propose or Try again ending with exit 3 re-reads the button's proposals and draws their state (waiting, creating or created) with no `WriteErrorBanner`; an exit 1 shows the banner and leaves the button idle.
- **Swift**: Kit decoder over the fixture (four decode states); `AutomationLookPreviewModel` every state and transitions (empty → running → preview; preview → stale after an edit; stale → preview after the chat's next draft; running → navigate away → back keeps the run — review rules lifecycle); `AutomationEditorCenter` step memory and preview result per key; the reading pane's choice of blocks / markdown / unsupported / unreadable; `InboxCardAction` passes the flattened index and the content hash; `markOutputOpened`/`markOutputDone`/`dismissOutput` with a stale hash change nothing and return false, and the view model re-reads instead of clearing; a same-hash rewrite does not change `inboxOutputCount` or Home's feed, a changed one adds one unread; the target button's states from `agent_actions` rows (every CHECK status plus `dismissed_at`); `TestTargetButton_StuckOffersTryAgain` — `approved`/`executing` with `decided_at` 2 minutes old and no live process → stuck, under 2 minutes or with our process running → creating, Try again runs `apply` for approved and `apply --force` for executing on the same row id, and the state follows the result; a living rewrite that changes the button's action, or puts another action at its index, draws idle whatever the old proposal's status, `applied` included; an identical action keeps its state; its args built from the drawn action, a failed propose keeping the button pressable with the error.
- **Shots**: every state in the table above plus the blocks gallery and the Inbox card states, in light and dark, registered in `DesignShotCatalog` (plan Task 1).

## Decisions

- Blocks are flat in v1 (no nesting) — agent's call.
- Tone is a closed set of six names mapped through `Tone`; the script computes tone per row, no condition language — agent's call.
- No image URLs anywhere in a card; avatars from the local `users` table — agent's call.
- Block actions reuse the card action grammar; one flattened press index per card; one press per card as today — agent's call.
- `action` and `reminder` refs only from built-in automations — agent's call. Reason: their native buttons approve sends and close reminders, so a chat-written recipe must not be able to put them next to text of its choosing; only Needs approval (a built-in) needs them.
- `blocks` and `body` exclusive; Go derives `body` as plain text so existing body readers keep working — agent's call.
- Lifecycle declared per recipe as `artifacts: feed | living`, in the approval hash only when living — agent's call.
- Storage as columns on `automation_outputs`, not a new table; no table rebuild — agent's call.
- A changed living artifact clears read, done, dismiss and the press; a same-hash rewrite keeps them — agent's call (umbrella read-state rule). Reason: Done and Dismiss were said about the content the owner saw; new content is a new thing to look at, and an identical rewrite is not.
- Inbox order by `changed_at`; "Updated …" from `written_at` — agent's call. Reason: a living card moves up only when it has something new, so a run every 10 minutes does not reshuffle the list, while the label still says how fresh it is.
- Reply press carries the drawn content hash; a changed card refuses the press — agent's call.
- A press without `--content-hash` still works — agent's call. Reason: this release's Desktop always sends it; the flag is optional only for the CLI by hand, which is the owner's own action on a card they name by id.
- The read-state writers mark only the drawn version (`content_hash` in their `WHERE`); a mismatch is a no-op and a re-read — agent's call (review ask #447).
- A queued reply run whose card changed before it started ends `cancelled` with a reason, the script never runs; no new run status — agent's call (review ask #447). Reason: the button it was pressed for no longer exists, and `automation_runs.status` has a CHECK, so a `skipped` status would mean rebuilding a hot table for a label that `cancelled` plus a reason already gives.
- A card is announced (notice, badge, Home) only when new or its hash changed, at most one notice per automation per run — agent's call (review ask #447). Reason: a living rewrite with nothing new is not news, and a run that rewrites many cards is one event to the owner.
- `folder` is a hook-registered field; A adds no folder column — agent's call (with sub-project B).
- The block model in the Kit's `WatchtowerDesign`, the renderer in DesignKit with app-injected markdown, avatars, actions and ref hooks — agent's call.
- The Look step is a step picker on the draft column (What it collects · Look · When it runs); footer shared; **Save Look** = the normal save — agent's call within the umbrella.
- Preview from the newest of the chat's cached draft and the owner's own Dry run, matched to the exact text on screen — agent's call.
- The AI-step warning is a footer line driven by a Go `adds_llm` flag, lexical call-site count — agent's call.
- HTML mockups now, native DesignShotCatalog shots as plan Task 1 for the owner to check before the rest is built — agent's call; the owner confirms it by approving this spec.
- Duplicate `action:<id>` task sources found by the migration are renamed `action:<id>:dup<row id>` (all but the oldest) instead of deleted or merged — agent's call. Reason: it changes only a service key the owner never sees, deletes nothing, and lets the unique index build on any database.
- One open proposal per Inbox button context (unique index over `pending`/`approved`/`executing`), plus a propose-time "task already exists" check instead of indexing `applied` — agent's call. Reason: two windows or a double click cannot make two proposals, and a task the owner deleted never locks its button.
- **Try again** acts on the newest row for a button only; `apply` of an older row while a newer one is open is refused before any change; these refusals exit with code 3, which the Desktop reads as "re-read the state" — agent's call. Reason: the claim's `UPDATE` would otherwise hit the unique index, and a state change done elsewhere is not an error to show the owner.
- The Look step has an owner **Dry run** button over `watchtower automations preview --stdin` (owner-only in-memory dry run, refused under every agent marker); AUTO-06/AUTO-12 amended — ask #445.
- A `target` action kind `{title, intent?, parent?}`: the press proposes `create_target` on the `inbox` surface and waits for Approve like any proposal; AUTO-02 amended — ask #445. Visible as an approval card through B's narrowed STRIP-01 — ask #451 (approved).
- `parent_id` on `create_target` is accepted only on the `inbox` surface, through a new `Tool.ValidateBinding` — agent's call. Reason: the main, reaction and automation surfaces keep their top-level-only contract (TGT-BRIEF-01), and `Validate` sees no binding, so a binding-aware check is the narrowest way to allow it in one place only.
- A `create_target` proposal stuck in `approved`/`executing` (2 minutes after `decided_at`, no live process) shows **Didn't finish — Try again**, which runs `actions apply` (approved) or `actions apply --force` (executing) on the same row; the reclaim never duplicates because the database allows one task per action id (partial unique index, insert-or-return) and one open proposal per button context; no sweep — agent's call (owner review, asks #453 and #456). Reason: the smallest exit with exactly-once kept; a daemon sweep would race a slow apply.
- The button's context names the action's hash (`<output>:<index>:<action hash>`) and every state is looked up through it — agent's call (review ask #450). Reason: a living card keeps its output id across rewrites, so the index alone would put "Task created" on another button.
- A target button's state comes from its proposal (`context_type = 'automation_output'`), nothing is stored on the output row — agent's call.
- The v1 block set, script emits blocks directly, living upsert and read-state rule, `concurrency: 1` for living — umbrella (agent's calls approved with it); AUTO-* changes — ask #961.

## Contract with sub-project B

A ships these seams; B builds on them and changes none of A's semantics without a joint amendment.

1. **`folder` field.** `(*automations.OutputMod).RegisterInboxField(name string, fn InboxFieldFunc)` with `type InboxFieldFunc func(env *Env, fn string, v any, o *db.AutomationOutput) error`. `output.inbox` passes a field it does not own to a registered hook; without one, `folder` is refused (`output.inbox(): folder is not available yet`) and any other unknown field stays `unknown field`. B adds the folder column(s) and migration, the `db.AutomationOutput` field (the hook only buffers `FolderSlug`; B resolves it to a folder inside `commitRunTx`, so a folder deleted mid-run cannot fail the commit), its write in `commitRunTx` (on a living upsert `folder_id` is overwritten — the last run's choice wins), the dry-run/`DraftOutput` field and the Swift reads. A adds no folder column.
2. **Row `ref`.** A validates `{kind, id}` (kinds above; `action`/`reminder` built-in only), stores it in the canonical document and decodes it to `ArtifactRef`. B owns everything a ref does.
3. **Ref hooks** in DesignKit, `ArtifactRefHooks` (in `ArtifactEnvironment`): `isOpen: (ArtifactRef) -> Bool` — false hides the row (default true); `nativeActions: (ArtifactRef, ArtifactRenderMode) -> AnyView?` — drawn at the row's trailing edge, disabled by B in `.preview` (default nil); `nativeKinds: (ArtifactRef) -> Set<ArtifactActionKind>` — the recipe's row actions of these kinds are not drawn (default empty). The rule is by kind, so it covers both cases the umbrella names: B's Waiting for me rows have a native Reply (ask #445, B's b1), so B returns `.reply` for an `inbox_item` ref and the recipe's `reply` action (which triggers the automation's own reply run, a different thing) is not drawn on that row; `track` and `idea` refs have a native Make a Task, so B returns `.target` for them (confirmed by spec-b). A row hidden by `isOpen` is left out of the list's count and, when every row is hidden, the list shows its `empty` text. A list row with a `ref` of kind `action` must be drawn by B with the record's own text next to Approve (A forbids such refs from non-built-in recipes; B must not widen that).
4. **Counting.** `ArtifactDocument.refs` returns every row ref in document order, for B's folder count of open rows.
5. **Removal by key.** `output.remove({key})` and its commit semantics are A's; B's `needs-approval` recipe uses them (`action:<id>`, `reminder:<id>` keys).
6. **Editor entry.** `AppState.openAutomationEditor(_:step:)` with `AutomationEditorStep.look` for B's "Edit the look…", `.collects` for "Edit what it collects…", `.schedule` for "Schedule…".
7. **Order and freshness.** B's folder lists order by `changed_at` and label living cards from `written_at`, as A's Inbox does.

## Open questions for the owner

None. Q1 (owner Dry run button) and Q2 (`target` action kind) were answered in ask #445; see **Decisions**.
