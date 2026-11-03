# Inbox builder A — blocks and the Look step (design)

**Umbrella:** [2026-11-02-inbox-builder-design.md](2026-11-02-inbox-builder-design.md) (board #1400, approved). **Plan:** [2026-11-03-inbox-builder-a-blocks-look.md](../plans/2026-11-03-inbox-builder-a-blocks-look.md). **Status:** design for owner review. The umbrella's owner decisions hold; this spec refines only what the umbrella marks as the agent's call, and lists anything in the umbrella that the code does not support under **Open questions for the owner**.

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
| Inbox card — living, markdown fallback, unsupported version | [`a-09-inbox-card.html`](../../design/mockups/inbox-builder/a-09-inbox-card.html) |

## Intent

An automation's Inbox card today is a title, a markdown body, a link and up to four buttons. Sub-project A gives it a **look**: a tree of native **blocks** the script emits, validated in Go, drawn by DesignKit on the Mac (and later by the phone from the same JSON). It also gives an automation a second lifecycle, **living** artifacts that are replaced in place by key, and gives the automation editor a **Look** step: the owner says in the editor chat how the card should look and sees it drawn from a dry run on real data, then saves it like any other edit.

## Goals

1. A versioned block document, the v1 block set, closed field lists and caps, validated in Go with readable errors; an unknown block refuses the output.
2. `output.inbox({title, blocks, key?, folder?, priority?, link?, actions?})`: A owns `blocks` and `key`; `folder` is a reserved seam that sub-project B fills.
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

A block action has exactly the grammar of today's card action (`internal/automations/sdk_output_card.go`): `{label, open | chat | agent: {task, workbench?} | reply, data?, primary?}`; `reply` needs `inbox:reply` (`PermissionDenied` otherwise). There is no `create target` kind — see **Open questions**, Q2.

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
- `output.report` is unchanged: no blocks, no key. `output.briefing` is unchanged.
- The content hash of an output is `blocks.ContentHash` = SHA-256 over the canonical JSON of `{title, body, blocks, priority, link, actions}` (blocks as the stored document, `null` when none). It is computed for every inbox output, feed ones too.

`MaxOutputsPerRun` (50) is unchanged. A living automation with more than 50 keys per run (People, sub-project D) is D's to raise; A does not move the cap.

### Recipe: `artifacts`

A new optional frontmatter key `artifacts: feed | living` (default `feed`) *(umbrella: lifecycle per automation, agent's call; the key is A's)*:

- It is in `approval_hash`, written only when `living`, so every existing recipe's hash is byte-identical (`TestApprovalHash_GoldenCanonicalBytes` unchanged).
- `artifacts: living` requires `outputs` to contain `inbox` and `concurrency: 1`. The parser refuses otherwise: `concurrency: an automation with living artifacts runs one at a time; set concurrency: 1` and `artifacts: living needs outputs: [inbox]`.
- The rule lives in one function, `automations.serialRunReasons(r *Recipe) []string`, so sub-project C adds the raw-window reader to the same check.
- `validate --json` `fields` gains `artifacts` (`"feed"` or `"living"`), so the draft column shows it with the other hashed fields and the confirmation sheet lists a change of it (D26).

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

Readers: the Inbox and Home order automation cards by `changed_at` (not `created_at`), so a living artifact moves up only when it changed. The card's source line reads "Updated 10 min ago" from `written_at` for a living artifact, "Run #N" as today otherwise.

### Reply presses on a card with blocks

`db.PressInboxOutputAction` resolves the index in the flattened list. `automations reply` gains `--content-hash <hash>`: the Desktop always passes the hash of the card it drew; when the row's `content_hash` differs the press is refused with `ErrOutputChanged` ("This card changed — look again") and nothing is queued, so a living artifact rewritten between drawing and pressing never queues a press of a different button. Without the flag (an older Desktop, the CLI by hand) the press works as today.

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
2. **The owner's Dry run button** — `watchtower automations preview --stdin --json [--slug S] [--workbench N] [--builtin ID]`: the same evaluation as `draft_automation` (validate, then `DryRunInMemory` with the draft bounds), result on stdout, nothing written, refused under every agent marker (owner-only, like the dry run of an unconfirmed recipe, ask #271). Its tokens are the owner's spend on the owner's press. This is a new dry-run path — **Q1** below. The result is kept in `AutomationEditorCenter` per editor key.

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
| `stopped` | a draft stopped at `mcp()` (ask #326) | the cards made before the stop, if any, with "The dry run stopped at a Quick Connection; dry-run the saved recipe from its card to see the rest." |

### The AI-step warning

`validate --json` gains `adds_llm` (bool): true when the text has more `llm(` call sites than the confirmed text, or gains an `llm:` permission the confirmed text does not have; for a new recipe, true when it has any. Call sites are counted lexically by `automations.LLMCallSites(script)` over the existing `jsScan` (comments and strings skipped; `x.llm(` is not a call site). When `adds_llm` holds, the footer shows, above Save, on every step: **"This change adds an AI step: every run will use the model."** plus "This dry run used N tokens." when a dry run of this text exists ([a-07](../../design/mockups/inbox-builder/a-07-look-save-llm.html)). It is a line, not an extra click *(agent's call)*: the confirmation sheet that follows lists the `llm:` permission as today.

### Built-ins and primitives

A built-in's primitive (`brief.compose`, `plan.compose`) does nothing in any dry run (AUTO-12), so a built-in whose card text comes from a primitive previews the parts the script computes and a placeholder line for the primitive's part. That is sub-project C's to design when it moves the built-ins to blocks; A only shows it honestly.

## Phone compatibility

The phone does not show automation cards today (no reader in `WatchtowerMobile` or `WatchtowerKit`). The model is in `WatchtowerDesign` so F decodes the same canonical JSON with the same decoder and fixture; F writes its own SwiftUI renderer. A puts no `blocks_json` into any mobile slice.

## Inventory contracts touched

The AUTO-* changes for `blocks`/`folder`/`key`, removal by key, the row `ref` and `concurrency: 1` for living outputs are approved (ask #961). Exactly these entries change, each in the same commit as its code:

- **AUTO-04** — the commit also upserts living outputs by `(automation_id, output_key)` and applies `output.remove`; every other terminal status leaves living rows byte-identical too. New guards: `TestAuto04_LivingUpsertCommittedOnlyOnSuccess`, `TestAuto04_RemoveCommittedOnlyOnSuccess`.
- **AUTO-05** — `artifacts: living` requires `concurrency: 1` (parse error otherwise). New guard: `TestAuto05_LivingArtifactsNeedConcurrencyOne`.
- **AUTO-06** — `artifacts` is in `approval_hash` (absent for feed, so existing hashes are unchanged); a reply press with a stale `--content-hash` is refused; the owner preview CLI refuses under every agent marker. New guards: `TestApprovalHash_ArtifactsIsHashed`, `TestApprovalHash_GoldenCanonicalBytes` unchanged, `TestAutomationsCLI_PreviewRefusedUnderAgentMarkers`, `TestAutomationsCLI_ReplyRefusedWhenCardChanged`.
- **AUTO-12** — the owner preview (`automations preview`) is a dry run in memory like `draft_automation`: no row of any table, `output.remove` journals `dry_run`. New guards: `TestAutomationsCLI_PreviewWritesNoRows`, `TestOutput_RemoveDryRun`.

The `automations preview` lines in AUTO-06 and AUTO-12 wait on Q1. No other inventory file changes in A (the `ref` kinds' native actions and their contracts are B's).

## Test strategy

- **Shared fixture** `internal/automations/blocks/testdata/blocks_cases.json`: `valid` cases (script input → canonical document, plain text, flattened action count, content hash) and `invalid` cases (input → exact error message), plus `unsupported` documents (`v: 2`). Go `blocks` tests and Swift `ArtifactBlocksTests` (Kit) both read it; adding a block or field without a case fails the coverage test that every block type and every optional field appears in at least one valid case.
- **Go** `internal/automations/blocks`: every rule and cap at the limit and one past it; degenerate inputs — `blocks: []` (valid, an empty document draws nothing but the title), a list with zero rows (valid, `empty` text), a table with zero rows, `null` where an object is expected, a number where a string is expected, NaN/Infinity in a value, a 200-row list with a ref on each, a document at exactly `MaxBlocksBytes`; canonical output stable under key order; plain text clipped on a rune boundary.
- **Go** `internal/db`: upsert keeps `id`/`created_at`; same hash keeps read/done/dismissed/press; changed hash clears them and moves `changed_at`; removal of a missing key; feed rows untouched; a failed run commits nothing (AUTO-04); the partial unique index refuses a second row per key on a raw insert; migration on a database with existing outputs backfills `written_at`/`changed_at`.
- **Go** `internal/automations`: `output.inbox` with blocks/key in feed/living recipes; `body`+`blocks` refused; `folder` refused without a hook and passed to a registered hook; `output.remove` ordering in the buffer; dry run journals `dry_run`; `artifacts` parse and hash rules; `LLMCallSites` over comments, strings, template text and `x.llm(`.
- **Go** `cmd`: `preview --stdin --json` pinned keys, refusal under every marker, no rows written; `reply --content-hash` match / mismatch / absent; `validate --json` `adds_llm` and `fields.artifacts`.
- **Swift**: Kit decoder over the fixture (four decode states); `AutomationLookPreviewModel` every state and transitions (empty → running → preview; preview → stale after an edit; stale → preview after the chat's next draft; running → navigate away → back keeps the run — review rules lifecycle); `AutomationEditorCenter` step memory and preview result per key; the reading pane's choice of blocks / markdown / unsupported / unreadable; `InboxCardAction` passes the flattened index and the content hash.
- **Shots**: every state in the table above plus the blocks gallery and the Inbox card states, in light and dark, registered in `DesignShotCatalog` (plan Task 1).

## Decisions

- Blocks are flat in v1 (no nesting) — agent's call.
- Tone is a closed set of six names mapped through `Tone`; the script computes tone per row, no condition language — agent's call.
- No image URLs anywhere in a card; avatars from the local `users` table — agent's call.
- Block actions reuse the card action grammar; one flattened press index per card; one press per card as today — agent's call.
- `action` and `reminder` refs only from built-in automations — agent's call.
- `blocks` and `body` exclusive; Go derives `body` as plain text so existing body readers keep working — agent's call.
- Lifecycle declared per recipe as `artifacts: feed | living`, in the approval hash only when living — agent's call.
- Storage as columns on `automation_outputs`, not a new table; no table rebuild — agent's call.
- A changed living artifact clears read, done, dismiss and the press; a same-hash rewrite keeps them — agent's call (umbrella read-state rule).
- Inbox order by `changed_at`; "Updated …" from `written_at` — agent's call.
- Reply press carries the drawn content hash; a changed card refuses the press — agent's call.
- `folder` is a hook-registered field; A adds no folder column — agent's call (with sub-project B).
- The block model in the Kit's `WatchtowerDesign`, the renderer in DesignKit with app-injected markdown, avatars, actions and ref hooks — agent's call.
- The Look step is a step picker on the draft column (What it collects · Look · When it runs); footer shared; **Save Look** = the normal save — agent's call within the umbrella.
- Preview from the newest of the chat's cached draft and the owner's own Dry run, matched to the exact text on screen — agent's call.
- The AI-step warning is a footer line driven by a Go `adds_llm` flag, lexical call-site count — agent's call.
- HTML mockups now, native DesignShotCatalog shots as plan Task 1 for the owner to check before the rest is built — agent's call.
- The v1 block set, script emits blocks directly, living upsert and read-state rule, `concurrency: 1` for living — umbrella (agent's calls approved with it); AUTO-* changes — ask #961.

## Contract with sub-project B

A ships these seams; B builds on them and changes none of A's semantics without a joint amendment.

1. **`folder` field.** `(*automations.OutputMod).RegisterInboxField(name string, fn InboxFieldFunc)` with `type InboxFieldFunc func(env *Env, fn string, v any, o *db.AutomationOutput) error`. `output.inbox` passes a field it does not own to a registered hook; without one, `folder` is refused (`output.inbox(): folder is not available yet`) and any other unknown field stays `unknown field`. B adds the folder column(s) and migration, the `db.AutomationOutput` field, its write in `commitRunTx` (on a living upsert too), the dry-run/`DraftOutput` field and the Swift reads. A adds no folder column.
2. **Row `ref`.** A validates `{kind, id}` (kinds above; `action`/`reminder` built-in only), stores it in the canonical document and decodes it to `ArtifactRef`. B owns everything a ref does.
3. **Ref hooks** in DesignKit, `ArtifactRefHooks` (in `ArtifactEnvironment`): `isOpen: (ArtifactRef) -> Bool` — false hides the row (default true); `nativeActions: (ArtifactRef, ArtifactRenderMode) -> AnyView?` — drawn at the row's trailing edge, disabled by B in `.preview` (default nil); `nativeKinds: (ArtifactRef) -> Set<ArtifactActionKind>` — the recipe's row actions of these kinds are not drawn (default empty). A row hidden by `isOpen` is left out of the list's count and, when every row is hidden, the list shows its `empty` text. A list row with a `ref` of kind `action` must be drawn by B with the record's own text next to Approve (A forbids such refs from non-built-in recipes; B must not widen that).
4. **Counting.** `ArtifactDocument.refs` returns every row ref in document order, for B's folder count of open rows.
5. **Removal by key.** `output.remove({key})` and its commit semantics are A's; B's `needs-approval` recipe uses them (`action:<id>`, `reminder:<id>` keys).
6. **Editor entry.** `AppState.openAutomationEditor(_:step:)` with `AutomationEditorStep.look` for B's "Edit the look…", `.collects` for "Edit what it collects…", `.schedule` for "Schedule…".
7. **Order and freshness.** B's folder lists order by `changed_at` and label living cards from `written_at`, as A's Inbox does.

## Open questions for the owner

**Q1. The Look step's own Dry run button needs a new owner-only dry-run path.** The preview can come only from the chat (`draft_automation`), which costs a chat turn per refresh. A button needs `watchtower automations preview --stdin` — an in-memory dry run of the text on screen, writing nothing, refused under every agent marker, spending real model tokens when the recipe calls `llm()`. That is one more caller in AUTO-06/AUTO-12, not covered by ask #961.
- (a) Add the CLI and the button, with the AUTO-06/AUTO-12 amendment above. **Recommended**: the owner sees the look without typing, and the path is exactly `draft_automation`'s, owner-only.
- (b) No button: the preview comes only from the chat's dry runs; the empty state says "Ask the chat to try it".
- (c) The button sends a fixed message to the editor chat ("Dry-run the draft") — no new path, but a model turn per press.

**Q2. "Create target" is not an existing action kind.** The umbrella lists the actions block's kinds as "open, reply, chat, agent, create target — the existing `output.inbox` action kinds"; the code has only open, chat, agent and reply (`db.InboxActionLink|Chat|Agent|Reply`). A `target` button would be a new write path (a `create_target` proposal on press).
- (a) v1 without it: an `agent` action ("make a task of this") covers the case, and B's native track rows keep **Make a Task**. **Recommended.**
- (b) Add a `target` kind in A that proposes `create_target` through the registry on the owner's press (AUTO-02 amendment, new ask).
