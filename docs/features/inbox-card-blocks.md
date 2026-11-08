# Inbox cards with a layout — blocks, living cards, the Look step and Task buttons (Inbox builder A, 2026-11-08)

Board #939 under the inbox builder umbrella (#1400). Spec `docs/superpowers/specs/2026-11-03-inbox-builder-a-blocks-look-design.md`, plan `docs/superpowers/plans/2026-11-03-inbox-builder-a-blocks-look.md`, umbrella `docs/superpowers/specs/2026-11-02-inbox-builder-design.md`; mockups `docs/design/mockups/inbox-builder/a-*.html`. Owner decisions: asks #961 (the AUTO-* changes), #445 (owner Dry run, `target` action kind), #451 (STRIP-01 narrowing, landed by sub-project B), #486 (the step picker's Changed row). User guide: `docs/guide/features/automations-card-look.md` and the Task button in `docs/guide/features/automations-inbox-buttons.md`. Sub-project B (folders, the Inbox menu, Needs approval, Waiting for me) gets its own note, `docs/features/inbox-folders.md`, in its docs task.

## The block document

- Go leaf package `internal/automations/blocks`: `Validate` + canonical form, `PlainText`, `ContentHash`, `FlattenActions`, `ActionHash`, `ValidateAction` (the one action grammar for card and block actions; permission checks through `Options.AllowKind`, so the leaf never imports `automations`). Limits in `limits.go`.
- Stored form `{"v": 1, "blocks": [...]}`, Go's canonical bytes (defaults written out, fixed key order, no unknown key). Go writes only `v: 1`; a reader meeting a higher `v` shows the plain text and "This card needs a newer Watchtower".
- v1 blocks: `heading`, `text`, `list`, `table`, `person`, `metrics`, `link`, `actions`. Flat (no nesting). `tone` is `neutral|info|success|warning|danger|accent`, mapped only through `Tone.artifact` (Kit `Tone.swift`); the script computes tone per row, there is no condition language.
- Caps: 40 blocks, 500 list + table rows in all (200 per list, 100 per table), 50 actions in the flattened list (card actions included), `MaxBlocksBytes` 128 KB canonical, 16 KB per `text` block. Every refusal is a `ValidationError` naming the path (`output.inbox(): blocks[2].rows[0] has 4 cells; the table has 3 columns`); messages pinned by the shared fixture.
- Row `ref {kind, id}`: kinds `inbox_item`, `track`, `idea`, `reminder`, `action`; `action` and `reminder` only from a built-in (`origin = 'builtin'`). A checks the shape only; what a ref does is B's.
- Shared fixture `internal/automations/blocks/testdata/blocks_cases.json` (one writer: Go; `go test ./internal/automations/blocks -update` rewrites its computed fields): valid cases (canonical form, plain text, flattened count, content hash), invalid cases (exact message), unsupported documents. Read by the Go tests, the Kit's `ArtifactBlocksTests` and the Desktop's `ArtifactFixtureParityTests`. Swift-only hand samples for shots and decoder tests: `WatchtowerKit/Tests/Fixtures/artifact_samples.json`.

## SDK and recipe

- `output.inbox({title, body? | blocks?, key?, folder?, priority?, link?, actions?})` (`sdk_output.go`, `sdk_output_card.go`, `sdk_output_living.go`): `body` and `blocks` are exclusive; with blocks, `body` = `blocks.PlainText` (capped at `MaxOutputBodyBytes`, 64 KB), so every body reader (Home, search, notification text, copy) works without knowing blocks.
- `folder` is a field hook, not A's: `RegisterInboxField(name, InboxFieldFunc)`; B registers `folder` through `DefaultModules`. Without a hook it is refused.
- `artifacts: feed | living` (frontmatter, default `feed`): in `approval_hash` only when `living`, so every existing hash is byte-identical. `living` needs `outputs: [inbox]` and `concurrency: 1` — the one rule function `serialRunReasons` (AUTO-05). With `living`, every `output.inbox` needs `key` (1–200 chars, no control characters); without it `key` is refused. `validate --json` `fields.artifacts`.
- `output.remove({key})`: living only, buffered and committed only with `succeeded` (AUTO-04); within a run the later write of a key wins; removing a missing key is a no-op; a dry run journals it `dry_run`.
- `MaxOutputsPerRun` (50) is unchanged.
- The `create-automation` skill (`internal/skills/shipped/create-automation.md`) carries "Cards with a layout", "Living cards" and "Designing the look" (never name blocks to the owner; call `draft_automation` after every look change; prefer a look the script computes).

## Storage — migration 00175

Columns on `automation_outputs` (no new table, no rebuild): `blocks_json` (`''` = markdown body), `output_key` (NULL = feed), `content_hash`, `written_at`, `changed_at` (both backfilled to `created_at`). Indexes `idx_automation_outputs_key` (unique, partial on `output_key IS NOT NULL`) and `idx_automation_outputs_changed (kind, changed_at)`.

**Living rule** (`commitRunTx`, in the run's one finish transaction): a new key inserts; an existing key keeps `id`/`created_at` and takes the new content, `run_id` and `written_at`. Only when `content_hash` differs it also moves `changed_at` and clears `read_at`, `done_at`, `dismissed_at` and the press (`pressed_*`). A same-hash rewrite moves only `written_at`, so it is never news: not in the unread count, not in Home, not in any notice. Readers order by `changed_at`; a living card's source line is "Updated … ago" from `written_at` (`InboxCardTexts`).

**Read-state writers** are Desktop-only and mark only the drawn version: `AutomationQueries.markOutputOpened` / `markOutputDone` / `dismissOutput(…, contentHash:, now:)` add `content_hash = ?` to their `WHERE` and return `false` on no change; the caller re-reads, never clears optimistically.

## Press address and Reply on a changed card

- Every action of a card has one index in the **flattened action list**: the card's own `actions` (0…3), then each block action in document order. Go `blocks.FlattenActions` / `db.FlattenStoredInboxActions` and Swift `ArtifactDocument.flattenedActions(cardActions:)` are pinned to the same order by the fixture. Still one press per card (`pressed_at`).
- `automations reply --output <id> --action <index> --content-hash <hash>`: a stale hash is refused with `ErrOutputChanged` ("This card changed — look again"), nothing queued. Without the flag the press works as before.
- The reply run's payload carries the checked `content_hash`; the executor (`executor_run.go`) ends a reply run `cancelled` before its script when the card changed or was removed in between ("The card changed after the button was pressed; nothing ran. …").

## The `target` action — a Task button

- Recipe: `{label, target: {title (≤ 200), intent? (≤ 1000), parent? (target id)}}`; needs `outputs: [target]` (`PermissionDenied` otherwise); `data` refused. Stored as `db.InboxAction{Kind: db.InboxActionTarget}`.
- Press (Desktop): `actions propose --tool create_target --surface inbox --context-type automation_output --context-id <output id>:<flattened index>:<action hash> --args … --json`, never `--approve`. `<action hash>` = `blocks.ActionHash` (16 hex chars), so a living rewrite that changes the button, or moves another action to its index, finds no proposal and draws idle.
- Registry: `create_target` gains the `inbox` surface (never trusted, never auto-executed) and `parent_id`, accepted on `inbox` only through `Tool.ValidateBinding` (`parent_id is only for an Inbox card's button` elsewhere; TGT-BRIEF-01 unchanged). The parent must exist, be personal and open at propose and again at apply.
- Exactly one task per proposal (AGENT-05, migration 00174): partial unique `idx_targets_action_source` + `db.CreateTargetForAction` (insert-or-return), and one open proposal per button `idx_agent_actions_open_context`; a propose while the button's task still exists is refused. Refusals map to `db.ErrButtonHasOpenProposal` / `db.ErrButtonTaskExists` / "A newer proposal for this button is open (#N)" and exit **3**; the Desktop reads exit 3 as "state moved" and re-reads, any other non-zero exit is the propose-error banner.
- Button states (`ArtifactTargetButton`, resolved by `TargetButtonStateResolver` from `InboxTargetButtonFacts`): idle, **Waiting for approval** (opens the approval card, `ActionStripViewModel.openProposal`), **Creating task…**, stuck **Didn't finish** + **Try again** (`approved`/`executing` 2 minutes after `decided_at` with no live process of ours: `actions apply` or `actions apply --force` on the same row), **Task created** (opens the task), failed + **Try again**, propose error. No sweep moves stuck rows. The approval card shows because B narrowed STRIP-01 to leave out only inbox `apply_track_action` rows.

## Desktop

- Model in the Kit's `WatchtowerDesign` (`ArtifactBlocks.swift`, `ArtifactActionHash.swift`): `ArtifactDocument.decode` → `.none | .document | .unsupported(version:) | .unreadable`, `flattenedActions(cardActions:)`, `refs`. Foundation-only so the phone (F) decodes the same JSON.
- Renderer `WatchtowerDesktop/Sources/DesignKit/Artifacts/`: `ArtifactView(document:cardActions:mode:)`, kit parts only; `ArtifactEnvironment` injects `markdown`, `avatar` (local `users` table, else initials — no network), `onAction` (the flattened index), `targetButtonState`, `isActionEnabled` and B's `refHooks` (`isOpen`, `nativeActions`, `nativeKinds`). `.preview` mode draws every button disabled ("Buttons work in the Inbox").
- Inbox: `InboxArtifactCard` / `InboxReadingPane` draw blocks, else the markdown body, else the plain text with the unsupported/unreadable line.
- Look step: the draft column's step picker `AutomationEditorStep` (**What it collects · Look · When it runs**, per editor key in `AutomationEditorCenter`; `AppState.openAutomationEditor(_:step:)` is B's entry). `AutomationLookPreviewModel` (pure) picks the newest of the chat's cached `draft_automation` result and the owner's **Dry run** for the exact text on screen and yields `AutomationLookPaneContent` (`noInboxOutput`, `empty`, `running`, `failed`, `noCard`, `preview`, `stale`, `stopped`); `AutomationLookPane` draws it. The owner's Dry run is `watchtower automations preview --stdin --json [--slug S] [--workbench N] [--builtin ID]` (`AutomationsCLI.preview`, `AutomationEditorCenter.runPreview`; **Stop** terminates it): the `draft_automation` evaluation, nothing written, refused under every agent marker (AUTO-06/AUTO-12). `DraftOutput` carries `blocks`, `key`, `content_hash` and `actions`.
- AI-step warning: `validate --json` `adds_llm` (more `llm(` call sites than the confirmed text by `automations.LLMCallSites`, or a new `llm:` permission; any for a new recipe) → the footer line `AutomationDraftFooter.aiStepLine` on every step. **Save Look** is the ordinary save.

## Contract with sub-project B

A ships, B builds on: the `folder` field hook; the row `ref` and `ArtifactDocument.refs`; `ArtifactRefHooks`; `output.remove` (B's `needs-approval` keys `action:<id>` / `reminder:<id>`); `openAutomationEditor(_:step:)`; ordering by `changed_at` and "Updated …" from `written_at`.

## v1 limits

- Blocks are flat; no chart block, no template language, no hand-editing in the preview.
- No image URLs anywhere in a card; avatars come only from the local `users` table.
- At most 50 outputs per run (`MaxOutputsPerRun`), so a living automation keeps at most 50 keys per run; raising it is sub-project D's.
- No version history of a living card.
- A built-in's primitive (`brief.compose`, `plan.compose`) does nothing in a dry run, so its part previews as a placeholder; the built-ins move to blocks in sub-project C.
- No `blocks_json` in any mobile slice; the phone renderer is sub-project F.

## Inventory

AUTO-02, AUTO-04, AUTO-05, AUTO-06, AUTO-12 in `docs/inventory/automations.md`; AGENT-05 in `docs/inventory/agent-actions.md`; Changelog lines in `docs/inventory/targets.md`; STRIP-01 in `docs/inventory/reaction-commands.md` (B).
