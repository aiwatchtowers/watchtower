# Inbox builder A — blocks and the Look step: implementation plan

**Spec:** [2026-11-03-inbox-builder-a-blocks-look-design.md](../specs/2026-11-03-inbox-builder-a-blocks-look-design.md)
**Umbrella:** [2026-11-02-inbox-builder-design.md](../specs/2026-11-02-inbox-builder-design.md) (board #1400).
**Status:** for owner review together with the spec. The spec's Q1 and Q2 are answered in ask #445: the owner preview CLI and Dry run button are in (Tasks 6, 11, 12), and the `target` action kind is in (Tasks 2, 14, 15), visible as an approval card only once STRIP-01 is narrowed by B (pending owner ask #451). If #451 is refused, Tasks 14–15 do not run, and Task 2's grammar refuses `target` with "target actions are not available yet".

## Execution rules

- Each task runs in its own worktree and branch, merged by the controller into `feature/inbox-builder-a`; never two implementers in one tree. Tasks whose `Depends on` are all merged may run in parallel lanes: the Go lane (Tasks 2–9, 14) and the Swift lane (Tasks 1, 10–13, 15) are independent until Task 10.
- **Owner checkpoint after Task 1:** the controller files an ask with the Task 1 shots. Tasks 10–13 and 15 (Swift wiring) start only after the owner's answer; Go Tasks 2–9 and 14 do not wait.
- Inner loop only, per CLAUDE.md: `go test ./internal/<pkg>` for the touched package(s), `make test-swift FILTER=<Class>`, `make kit-test FILTER=<Class>`, `make lint-diff`. The full gate (`make test`, `make test-swift`, `make lint-all`) runs once after Tasks 9 and 14 (Go phase), once after Tasks 13 and 15 (Swift phase), and before the PR to main — by the controller, never per task.
- Each implementer self-reviews against `docs/review/review-rules.md` (§§ 6–9 and, for Swift, "Swift / Desktop conventions") before hand-back; the independent review uses the same checklist.
- Inventory: a task that changes an AUTO-* behaviour edits `docs/inventory/automations.md` (Observable, guards, Changelog) in the same commit, exactly as listed in the spec's "Inventory contracts touched". No guard test is weakened or renamed.
- Sample data in tests, fixtures and shots: `acme`, `example.com`, "colleague A". No live data.
- No code bodies in this plan; signatures are the contract, names may be refined in review if the spec's semantics stay.

## Task 1 — Shots first: the block model, the renderer and every state on fixtures

**Depends on:** none. **Lane:** Swift.

Files:
- new `internal/automations/blocks/testdata/blocks_cases.json` — the shared fixture (spec "Test strategy"): `valid[]` `{name, input, canonical, plain_text, actions, content_hash}` (`content_hash` may be `""` here; Task 2 fills it), `invalid[]` `{name, input, built_in, error}` with the spec's exact messages, `unsupported[]` `{name, document, version}`. Every block type and every optional field appears in at least one valid case.
- new `WatchtowerKit/Sources/WatchtowerDesign/ArtifactBlocks.swift` — `ArtifactDocument`, `ArtifactBlock`, `ArtifactListRow`, `ArtifactTableColumn`, `ArtifactTableCell`, `ArtifactMetric`, `ArtifactPersonLine`, `ArtifactBadge`, `ArtifactTone`, `ArtifactAction`, `ArtifactActionKind` (`open`, `chat`, `agent`, `reply`, `target`), `ArtifactTargetAction` (`title`, `intent`, `parent`), `ArtifactRef`, `ArtifactRefKind`; `enum ArtifactDecodeResult { case none, document(ArtifactDocument), unsupported(version: Int), unreadable }`; `static func decode(_ json: String) -> ArtifactDecodeResult`; `func flattenedActions(cardActions: [ArtifactAction]) -> [ArtifactAction]`; `var refs: [ArtifactRef]`.
- `WatchtowerKit/Sources/WatchtowerDesign/Tone.swift` — `static func artifact(_ tone: ArtifactTone) -> Color`.
- new `WatchtowerDesktop/Sources/DesignKit/Artifacts/` — `ArtifactView`, one view per block (`ArtifactHeadingView`, `ArtifactTextView`, `ArtifactListView`, `ArtifactTableView`, `ArtifactPersonView`, `ArtifactMetricsView`, `ArtifactLinkView`, `ArtifactActionsView`), `ArtifactEnvironment` (`markdown`, `avatar`, `onAction`, `refHooks`) as an `EnvironmentValues` entry, `ArtifactRefHooks`, `enum ArtifactRenderMode { case inbox, preview }`.
- new `WatchtowerDesktop/Sources/Views/Automations/AutomationLookPane.swift` — the Look pane as a view over a plain value `AutomationLookPaneContent` (state enum mirroring the spec's table: `noInboxOutput`, `empty`, `running(previous:)`, `failed(message:steps:)`, `noCard(tokens:)`, `preview(cards:selected:tokens:at:)`, `stale(cards:selected:)`, `stopped(cards:)`), plus the footer line view `AutomationLLMStepWarning`. No model, no CLI yet: Task 12 feeds it.
- a catalog page in `WatchtowerDesktop/Sources/DesignKitCatalog/` for the artifact components.
- new `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+InboxBuilderA.swift`; register shots in `DesignShotCatalog.swift`: `artifact-blocks` (every block, from fixture JSON), `artifact-inbox-living`, `artifact-inbox-markdown`, `artifact-inbox-unsupported`, `artifact-inbox-unreadable`, `look-empty`, `look-running`, `look-failed`, `look-preview`, `look-preview-picker`, `look-stale`, `look-stopped` (mockup a-10), `look-no-inbox-output`, `look-no-card`, `look-save-llm-warning`, `artifact-target-button-idle`, `artifact-target-button-waiting`, `artifact-target-button-creating`, `artifact-target-button-created`, `artifact-target-button-failed`, `artifact-target-button-propose-error` (mockup a-11).
- new `WatchtowerKit/Tests/WatchtowerDesignTests/ArtifactBlocksTests.swift`.

Steps: write the fixture from the spec; decoder over it; renderer from kit parts only (no hex, no `Divider()` between rows, colours through `Tone.artifact`); Look pane on fixture content; shots; `make desktop-shots DESKTOP_SHOTS=<dir>` and attach the PNGs to the hand-back.

Tests: every `valid[].canonical` decodes to `.document`; every `unsupported[]` to `.unsupported(version)`; `""` → `.none`; malformed JSON, a known `v` with a missing required field, a block missing `type` → `.unreadable`; `flattenedActions` count equals each case's `actions`; a `target` action decodes with and without `intent`/`parent`; `refs` order; zero-row list and zero-row table decode; `Tone.artifact` covers all six. `DesignShotsTests` renders every new shot (names unique).

Checks: `make kit-test FILTER=ArtifactBlocksTests`, `make test-swift FILTER=DesignShotsTests`, `make lint-diff`.

## Task 2 — Go `blocks` package: validate, canonicalise, plain text, hash, flatten

**Depends on:** none (reads the fixture Task 1 writes; if Task 2 starts first it creates the file and Task 1 extends it — one owner per merge, the controller resolves). **Lane:** Go.

Files: new `internal/automations/blocks/blocks.go`, `validate.go`, `actions.go`, `plaintext.go`, `limits.go`, `blocks_test.go`, `fixture_test.go`; `internal/db/automation_runs.go` (`InboxActionTarget`, `InboxTargetAction{Title, Intent string; Parent int64}` with JSON `title`/`intent,omitempty`/`parent,omitempty`, `InboxAction.Target`).

Interfaces:
- `type Document struct { V int; Blocks []Block }` with canonical JSON marshalling (fixed key order, defaults written).
- `func Validate(fn string, v any, opts Options) (Document, error)` — `v` is the goja-exported value; `type Options struct { BuiltIn bool; AllowKind func(kind string) error }` (`BuiltIn` gates `action`/`reminder` refs; `AllowKind` is the SDK's permission check for `reply` → `inbox:reply` and `target` → `outputs: [target]`).
- `func ActionHash(a db.InboxAction) string` — first 16 hex characters of SHA-256 over the action's canonical JSON; the fixture pins it per valid action, and Swift `ArtifactAction.hash` matches (Task 13).
- `func ValidateAction(fn, field string, i int, v any, opts Options) (db.InboxAction, error)` — the one action grammar (moved from `sdk_output_card.go`'s `inboxAction`, plus the `target` kind with the spec's fields and messages); used for card actions and block actions alike. Errors are `automations` `ValidationError`-shaped through a small `ErrorFunc` the caller passes, or a typed `*blocks.Error{Path, Msg}` the SDK maps — implementer's choice, messages exactly as the fixture.
- `func (Document) Canonical() ([]byte, error)`; `func PlainText(Document, maxBytes int) string`; `func ContentHash(title, body string, doc *Document, priority, link string, actions []db.InboxAction) string`; `func FlattenActions(card []db.InboxAction, doc *Document) []db.InboxAction`; `func Decode(stored string) (*Document, error)` (for the press path).
- Limits as named constants: `MaxBlocks = 40`, `MaxRows = 500`, `MaxActions = 50`, `MaxBlocksBytes = 128 * 1024`, `MaxTextBytes = 16 * 1024`, and the per-field limits of the spec.

Tests: the existing card-action tests (`sdk_output_card_test.go`) pass unchanged against the moved grammar; `target` field rules (title empty/201 chars, intent 1001 chars, parent 0/-1/"x", unknown key, `data` on a target); `AllowKind` refusal surfaces as the caller's error; the whole fixture (valid → canonical/plain text/actions/hash, which this task writes into the fixture's `content_hash`; invalid → exact message); each limit at N and N+1; degenerate inputs from the spec's test strategy; canonical bytes stable across input key orders; `PlainText` clipping on a rune boundary; `ContentHash` changes with each hashed field and not with Go map order; a fixture-coverage test (every block type and optional field present in a valid case).

Checks: `go test ./internal/automations/blocks`, `make lint-diff`.

## Task 3 — Migration and the db layer: columns, living upsert, removal, read state

**Depends on:** none. **Lane:** Go.

Files: new `internal/db/migrations/00NNN_automation_output_blocks.sql` (next free number at implementation time); `internal/db/schema.sql`; schema golden; `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (regenerated: `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`); `internal/db/automation_runs.go`; `internal/db/automation_runs_test.go`. Follow the `add-migration` skill.

Interfaces:
- `db.AutomationOutput` gains `BlocksJSON, OutputKey, ContentHash string; WrittenAt, ChangedAt time.Time` (`OutputKey == ""` = feed).
- `db.RunCommit` gains `Removals []string` (living keys to delete); `Outputs` keep buffer order.
- `commitRunTx`: feed insert with the new columns; living `INSERT … ON CONFLICT(automation_id, output_key) WHERE output_key IS NOT NULL DO UPDATE` with the spec's same-hash/changed-hash rule (read/done/dismissed/press cleared and `changed_at` moved only on a changed hash); removals as `DELETE … WHERE automation_id = ? AND output_key = ?`. Living only for `kind = 'inbox'` (a living report is an error, not silently feed).
- Readers: `ListAutomationOutputs`, `scanAutomationOutput` and `GetAutomationOutput` read the new columns; inbox ordering by `changed_at`.

Migration: the five `ADD COLUMN`s, `UPDATE … SET written_at = created_at, changed_at = created_at`, the two indexes; `-- +goose Down` drops the indexes and columns. No table rebuild (no CHECK change).

Tests: `TestAuto04_LivingUpsertCommittedOnlyOnSuccess`, `TestAuto04_RemoveCommittedOnlyOnSuccess` (failed/timed out/over budget/cancelled leave rows byte-identical); upsert keeps `id`/`created_at`; same hash keeps `read_at`/`done_at`/`dismissed_at`/`pressed_*`; changed hash clears them and moves `changed_at`, while `written_at` moves on both; removal of a missing key is a no-op; a feed row with the same automation is never touched by an upsert; raw second insert of one `(automation_id, output_key)` refused by the index; `TestLivingUpsert_StaleMarkMissesChangedVersion` (the Desktop's guarded mark SQL with the old hash changes 0 rows after a changed upsert, 1 after a same-hash one); `TestLivingUpsert_SameHashIsNotNew` (`changed_at`, `read_at` unchanged — the notification rule); migration over existing rows backfills both times; `TestRunCommit_ForeignOutputStillRefused` stays green. Update the AUTO-04 inventory entry.

Checks: `go test ./internal/db`, `make lint-diff`. Cross-package: `go test ./internal/automations` (it builds `RunCommit`).

## Task 4 — Recipe `artifacts:` key, hash and the serial-run rule

**Depends on:** none. **Lane:** Go.

Files: `internal/automations/recipe.go`, `hash.go`, `recipe_test.go`, `indexer_test.go`; `cmd/automations_edit.go` (`validate --json` `fields.artifacts`), `cmd/automations.go` (`show --json` if it mirrors fields), `cmd/automations_test.go`.

Interfaces: `Recipe.Artifacts ArtifactLifecycle` (`ArtifactsFeed`, `ArtifactsLiving`); `func serialRunReasons(r *Recipe) []string` (the one place C extends); canonical hash form writes `artifacts` only when living; `ApprovalFields` lists it (the confirmation sheet's Changed block).

Tests: `artifacts: living` with `concurrency: 2` → the spec's parse error (`TestAuto05_LivingArtifactsNeedConcurrencyOne`); living without `outputs: [inbox]` refused; unknown value refused; absent = feed; `TestApprovalHash_GoldenCanonicalBytes` unchanged; `TestApprovalHash_ArtifactsIsHashed` (feed → living changes the hash, so it needs confirmation); built-in recipes parse with the key. Update AUTO-05 and AUTO-06 entries.

Checks: `go test ./internal/automations -run 'Recipe|ApprovalHash|Auto05|Rescan'`, targeted `go test ./cmd -run 'TestAutomationsCLI_Validate'`, `make lint-diff`.

## Task 5 — SDK: `output.inbox` blocks/key, the folder hook, `output.remove`

**Depends on:** Tasks 2, 3, 4. **Lane:** Go.

Files: `internal/automations/sdk_output.go`, `sdk_output_card.go` (card actions through `blocks.ValidateAction`; `AllowKind` from the manifest: `AllowInboxReply`, and `AllowOutput("target")` for a target action), `commit.go`, `executor_run.go` (passes removals into `RunCommit`), `limits.go`, new `sdk_output_blocks_test.go`, `sdk_test.go`.

Interfaces:
- `outputOpts` gains `blocks, key bool` (inbox only); `checkOutputFields` admits `blocks`, `key`, and registered hook fields.
- `type InboxFieldFunc func(env *Env, fn string, v any, o *db.AutomationOutput) error`; `func (m *OutputMod) RegisterInboxField(name string, fn InboxFieldFunc)`; `folder` is reserved: refused with the spec's message while no hook is registered.
- `CommitBuffer.AddOutput` collapses a repeat of one living key (later wins); new `CommitBuffer.RemoveOutput(key string) error` and `Removals() []string` with the same later-wins rule against outputs; the outputs cap counts each kept output once.
- `output.remove({key})` registered on the output module, gated by `outputs: [inbox]` and `artifacts: living`; journaled as an output step; `dry_run` in a dry run.
- `blocks` → `blocks.Validate(fn, v, blocks.Options{BuiltIn: env.Automation.Origin == builtin})`, store canonical JSON, `Body = blocks.PlainText(doc, MaxOutputBodyBytes)`, `ContentHash` for every inbox output.

Tests: blocks in feed and living recipes; `body` + `blocks` refused; key required in living / refused in feed with the spec's messages; `folder` refused without a hook, passed to a registered test hook with the raw value; unknown field still `unknown field`; inbox-then-remove and remove-then-inbox of one key in a run; replay of a resumed run rebuilds the same buffer (`TestAuto08_ResumeAtAskWait` stays green); `TestOutput_RemoveDryRun`; `TestAuto12_DryRunWritesNoActionsOutputsOrState` green with blocks; an `action` ref from a personal recipe refused, from a built-in accepted; a Reply action inside a block needs `inbox:reply`; `TestOutput_TargetActionNeedsTargetOutput` (card-level and in a list row, `PermissionDenied` without `outputs: [target]`).

Checks: `go test ./internal/automations`, `make lint-diff`.

## Task 6 — Dry-run results carry blocks; the owner preview CLI

**Depends on:** Task 5. **Lane:** Go. The `preview` CLI is approved in ask #445 (AUTO-06/AUTO-12 amendment).

Files: `internal/automations/authoring/draft.go` (`DraftOutput` gains `Blocks json.RawMessage` — `null` when none, `Key string`, `ContentHash string`; never a nil slice), `draft_test.go`; new `cmd/automations_preview.go`, `cmd/automations_preview_test.go`; `cmd/automations.go` (register); export from `authoring` one function the CLI shares with `draft_automation`, e.g. `func EvaluateDraft(ctx context.Context, d Deps, text string, target DraftTarget) (*DraftResult, error)` — the D16 refusal stays on the chat path only.

`watchtower automations preview --stdin --json [--slug S] [--workbench N] [--builtin ID]`: reads the recipe text from stdin, prints one `DraftResult` JSON (pinned keys = `draft_automation`'s), writes no row of any table and no draft-cache entry, refuses under every agent marker before reading stdin.

Tests: `TestAutomationsCLI_PreviewRefusedUnderAgentMarkers` (every marker incl. `WATCHTOWER_AUTOMATION_RUN_ID`); `TestAutomationsCLI_PreviewWritesNoRows` (row counts of every table unchanged, `llm()` faked); pinned key set incl. `blocks: null` for a markdown output (wire-shape rule); a parse error returns `ok: false` with `dry_run: null`; empty stdin refused with a usage line; `draft_automation` result carries blocks/key; the draft cache stores them. Update AUTO-06 and AUTO-12.

Checks: `go test ./internal/automations/authoring`, `go test ./cmd -run 'TestAutomationsCLI_Preview|TestDraftAutomation'`, `make lint-diff`.

## Task 7 — Reply presses on flattened actions with the content hash

**Depends on:** Tasks 2, 3. **Lane:** Go.

Files: `internal/db/automation_outputs_press.go` (+ test), `cmd/automations_reply.go` (+ test).

Files also: `internal/automations/executor_run.go` (+ `executor_test.go`).

Interfaces: `db.ReplyTrigger.ContentHash string` (JSON `content_hash`, omitempty), written by the press; the executor's start check beside the `inbox:reply` one: payload hash ≠ the row's current hash, or the row gone → `failedEnd`-style end with status `cancelled`, `error_kind = 'cancelled'` and the spec's message, script not started. `db.PressInboxOutputAction(outputID int64, index int, contentHash string, now time.Time)` — `contentHash == ""` skips the check; new `db.ErrOutputChanged`; the index resolves over `blocks.FlattenActions`; `loadReplyTarget` likewise; `automations reply --content-hash`.

Tests: a reply inside a list row pressed by its flattened index queues one `trigger='reply'` run with that action's value/data; an index past the flattened list refused; a non-reply index refused (`ErrNotAReplyAction`); matching hash queues; stale hash refused, nothing queued (`TestAutomationsCLI_ReplyRefusedWhenCardChanged`); no flag on a card without blocks behaves as today (existing reply tests green); second press still `AlreadyPressedError`; a living rewrite with a changed hash makes the card pressable again; `TestExecutor_ReplyRunOnChangedCardCancelled` (queued reply run, then a changed-hash commit of the same key → the reply run ends `cancelled` with the reason, zero steps, nothing committed; a removed key likewise; a same-hash rewrite → runs; a pre-release payload without the hash → runs); a resumed reply run is checked again. Update AUTO-06's `inbox:reply` paragraph.

Checks: `go test ./internal/db -run Press`, `go test ./internal/automations -run 'Reply'`, `go test ./cmd -run TestAutomationsCLI_Reply`, `make lint-diff`.

## Task 8 — `adds_llm`: counting `llm()` call sites

**Depends on:** none. **Lane:** Go.

Files: `internal/automations/preparse.go` (or new `llmsites.go`) + test; `cmd/automations_edit.go` (`validate --json` `adds_llm`), `cmd/automations_test.go`.

Interfaces: `func LLMCallSites(script string) int` over the existing `jsScan`; `adds_llm` = sites(new) > sites(confirmed) or a new `llm:` permission; for a new recipe, sites > 0 or any `llm:` entry.

Tests: comments, strings, template text and regex-free code; `x.llm(` and `{llm: 1}` not counted; `llm (` with a space counted; an edit that only moves an `llm()` call → false; an added call → true; a new recipe with `llm:light` and no call → true; `--against` absent → treated as new. Key pinned in the `validate --json` key set test.

Checks: `go test ./internal/automations -run LLMCallSites`, `go test ./cmd -run TestAutomationsCLI_Validate`, `make lint-diff`.

## Task 9 — The `create-automation` skill: blocks, living artifacts, the Look procedure

**Depends on:** Task 5 (and Task 4 for `artifacts`). **Lane:** Go (docs-in-code).

Files: `internal/skills/shipped/create-automation.md`; its examples test (`internal/automations/authoring/skill_examples_test.go` or the skills package's own); a new template only if it earns its place (no).

Content: the `output.inbox` row of the SDK table with `blocks`/`key`/`folder` (folder: "not available yet" until B), the `target` button (`{label, target: {title, intent?, parent?}}`, needs `outputs: [target]`, the owner approves the task after pressing), a compact block reference (types, required fields, tones, limits), `artifacts: living` with `concurrency: 1` and `output.remove`, "Designing the look": ask what the owner wants to see, never name blocks to the owner, emit blocks from the script, call `draft_automation` after every look change before answering, say when a change adds an `llm()` step. One worked example: a living "threads waiting for me" list with tones and a Reply action (sample data only).

Tests: every js block in the skill parses and dry-runs in the examples test; the example's `output.inbox` passes `blocks.Validate`.

Checks: the examples test package, `make lint-diff`.

## Task 10 — Desktop Core: cards with blocks in today's Inbox and Home

**Depends on:** Tasks 1, 3, 7; owner checkpoint after Task 1. **Lane:** Swift.

Files: `WatchtowerDesktop/Sources/WatchtowerCore/Models/AutomationModels.swift` (`AutomationOutputCard` + `AutomationOutput` record fields), `Database/Queries/AutomationQueries.swift` (order by `changed_at`), `Database/Queries/HomeFeedQueries.swift` (same), `Services/Inbox/InboxCardAction.swift` (flattened index, content hash into the reply CLI args), the three read-state writers in `AutomationQueries` (`markOutputOpened`/`markOutputDone`/`dismissOutput` take `contentHash:` and return `Bool`) and their callers `Services/Actions/ActionStripViewModel.swift` and `Sources/Services/HomeFeedActions.swift` (false → re-read, no optimistic clear), `Services/Automations/AutomationsCLI.swift` (`--content-hash`); `Sources/Views/Inbox/InboxReadingPane.swift` (`ArtifactView` with the app's `ArtifactEnvironment`: `MarkdownView`, avatar resolver over `users`, `onAction` → `InboxCardAction`); `Sources/Views/Inbox/InboxCommonRow.swift` ("Updated …" for living); tests in `Tests/Core/AutomationQueriesTests.swift`, `ActionStripAutomationOutputTests.swift`, new `Tests/Core/ArtifactCardTests.swift`.

Tests: each writer with the drawn hash marks once; with a stale hash (the row rewritten under the view) changes nothing, returns false, and the view model re-reads and still shows the card unread; a pre-migration row (`content_hash = ''`) still marks; a same-hash rewrite leaves `inboxOutputCount` and Home's feed as they were, a changed one adds one unread; the pure helper `InboxCardNotice.cards(changedIn:)` that any later card notice uses returns nothing for a same-hash rewrite and one summary per automation per run for several changed cards; the reading pane picks blocks / markdown / unsupported / unreadable by `ArtifactDocument.decode` (four states, the third-state rule); a living card's changed content shows unread again (rows from the test schema); order by `changed_at` (a same-hash rewrite does not move a card); `InboxCardAction` passes the flattened index and the drawn hash; an avatar for an unknown user falls back to initials; Home's feed line uses the plain-text body unchanged.

Checks: `make test-swift FILTER='AutomationQueriesTests|ActionStripAutomationOutputTests|ArtifactCardTests|HomeFeed'` (`HomeFeedActions` tests included), `make lint-diff`.

## Task 11 — Look preview model and its state in the editor center

**Depends on:** Tasks 1, 6. **Lane:** Swift.

Files: new `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/AutomationLookPreviewModel.swift`; `AutomationDraftPanelModel.swift` (decode `blocks`/`key`/`content_hash` of each output); `AutomationEditorCenter.swift` (per editor key: chosen step, owner preview result, in-flight preview task, cancel); `AutomationsCLI.swift` (`preview --stdin --json`); tests `Tests/Core/AutomationLookPreviewModelTests.swift`, `AutomationEditorCenterTests.swift`.

Interfaces: `AutomationLookPreviewModel.state(text:outputs:chatEntry:ownerResult:running:) -> AutomationLookPaneContent` (pure); `AutomationEditorCenter.runPreview(_ key:)`, `cancelPreview(_ key:)`, `step(for:)`/`setStep(_:for:)`.

Tests: every state of the spec's table from inputs; newest of chat vs owner result wins by time for the same text; an entry for other bytes → `stale`; `stopped` keeps cards made before the stop; a refused draft (D16) shows its refusal line, not a preview; zero outputs → `noCard`; non-inbox outputs only → `noCard`; `running` → navigate away → back keeps the run and its result (lifecycle rule); cancel kills the CLI process and returns to the previous state; a CLI failure (non-zero exit, undecodable JSON) → `failed` with the message, never `empty`.

Checks: `make test-swift FILTER='AutomationLookPreviewModelTests|AutomationEditorCenterTests|AutomationDraftPanelModelTests'`, `make lint-diff`.

## Task 12 — The Look step in the editor panel

**Depends on:** Tasks 8, 11. **Lane:** Swift.

Files: `WatchtowerDesktop/Sources/Views/Automations/AutomationEditorPanel.swift`, `AutomationDraftColumn.swift` (step picker over the existing boxes, the split of the spec), `AutomationLookPane.swift` (from Task 1, now fed by the model, **Dry run** / **Stop** wired), `WatchtowerCore/Services/Automations/AutomationDraftFooter.swift` (AI-step line from `adds_llm`, "Save Look" label on the Look step), `AutomationsPanel.swift` (`AutomationEditorStep`), `Sources/App/AppState+Automations.swift` (`openAutomationEditor(_:step:)`); tests `AutomationDraftFooterTests.swift`, `AutomationEditorModeTests.swift`, `AutomationLLMWarningTests.swift`.

Tests: the footer shows the AI-step line on every step when `adds_llm`, with the token line only when a dry run of this text exists; no line when false; Save stays disabled while checking (`testAuto06_SaveDisabledWhileChecking` green); the confirmation sheet still lists every hashed field whichever step is chosen (`testAuto06_ConfirmSheetShowsHashedFieldChanges` green, plus a case with `artifacts`); `openAutomationEditor(_:step: .look)` opens on Look; the step survives closing and reopening the panel. Shots from Task 1 re-rendered from the live view and compared by eye in the hand-back.

Checks: `make test-swift FILTER='AutomationDraftFooterTests|AutomationEditorModeTests|AutomationLLMWarningTests|AutomationEditorCenterTests|DesignShotsTests'`, `make lint-diff`.

## Task 13 — Swift ↔ Go fixture parity

**Depends on:** Tasks 2, 10. **Lane:** Swift.

Files: `WatchtowerKit/Tests/WatchtowerDesignTests/ArtifactBlocksTests.swift` (extend), new `WatchtowerDesktop/Tests/Core/ArtifactFixtureParityTests.swift`.

Tests: the Kit decoder accepts every Go-canonical document of the final fixture; `ArtifactAction.hash` equals the fixture's Go `ActionHash` for every action; `flattenedActions` order equals Go's per case (the fixture's `actions` list of labels); every `refs` list matches; a document Go would refuse but that decodes structurally (e.g. a 7-column table) still renders (Swift does not re-validate) — documented as intended; the fixture coverage test from Task 2 has a Swift twin listing every `ArtifactBlock` case.

Checks: `make kit-test FILTER=ArtifactBlocksTests`, `make test-swift FILTER=ArtifactFixtureParityTests`, `make lint-diff`.

## Task 14 — `create_target` from an Inbox button: inbox surface and `parent_id`

**Depends on:** Task 2; ask #451 (STRIP-01 narrowed by B). **Lane:** Go. Not started while #451 is open; dropped if it is refused.

Files: `internal/tools/targets.go` (+ test), `internal/tools/registry.go` (`Tool.ValidateBinding`, called by `Propose` after `Validate`), `cmd/actions_registry.go` and its pin test, `cmd/actions_propose_test.go`; `docs/inventory/automations.md` (AUTO-02), `docs/inventory/agent-actions.md` and `docs/inventory/targets.md` (Changelog lines, TGT-BRIEF-01's surface sentence).

Interfaces: `createTargetArgs.ParentID int64` (JSON `parent_id`, omitempty); `create_target.Surfaces` += `tools.InboxSurface`; `Tool.ValidateBinding func(b Binding, raw json.RawMessage) error` — `create_target` refuses `parent_id` unless `b.Surface == InboxSurface`; parent checks (exists, `project_id IS NULL`, not `done`/`dismissed`) in `Validate` and again in `Execute`; the child takes the parent's `level`, `period_start`, `period_end` and `parent_id`.

Tests: `TestCreateTarget_ParentIDOnlyOnInbox` (main, reaction, automation refused with the spec's message, no row); inbox with a valid parent → one pending row, `Execute` after Approve creates the child under it; parent missing / done / dismissed / on a workbench board refused at propose; parent closed between propose and apply → apply `failed`, no target (AGENT-05 claim still once); `TestAuto02_TargetButtonOnlyProposes` (`actions propose --tool create_target --surface inbox --context-type automation_output --context-id 7:2` without `--approve` → one pending row with that context, zero targets); under an agent marker refused (AGENT-07, existing guard extended to this tool); trust `execute` on `main` does not auto-execute an inbox proposal; `TestBuildToolRegistry_PinsWriteToolsReadToolsAndSurfaces` updated for the new surface (pin extended, no assertion relaxed); top-level `create_target` on `main` unchanged (existing tests green).

Checks: `go test ./internal/tools`, `go test ./cmd -run 'TestActionsPropose|TestBuildToolRegistry|TestAuto02'`, `make lint-diff`.

## Task 15 — The target button on the Desktop

**Depends on:** Tasks 10, 14; ask #451 (STRIP-01 narrowed by B). **Lane:** Swift. Not started while #451 is open; dropped if it is refused.

Files: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/InboxCardAction.swift` (target kind: build `actions propose` args from the drawn action — `text`, `intent`, `parent_id`, `reason` naming the card and automation —, context `automation_output` / `<output id>:<index>:<action hash>`), new `WatchtowerCore/Services/Inbox/InboxTargetButtonState.swift` (pure: the newest proposal for `<output>:<index>:<action hash>` → `idle | waiting(actionID) | creating | created(targetID) | failed(message)`, mapping all six `agent_actions` statuses and `dismissed_at` as the spec's table), a query over `agent_actions` by context in `Database/Queries/` (the existing agent-action queries file), `Sources/Views/Inbox/InboxReadingPane.swift` (the state per target action through `ArtifactEnvironment`), `DesignKit/Artifacts/` (a target button's label, symbol and state rendering — states come in as values; DesignKit reads no database); tests `Tests/Core/InboxTargetButtonStateTests.swift`, `Tests/Core/InboxCardActionTests.swift` (or the existing action-strip tests), a shot `artifact-target-button-states` in `DesignShotCatalog`.

Tests: every row of the spec's table from `agent_actions` rows (none, `pending`, `approved`, `executing`, `applied`, `rejected`, `failed`, `failed` with `dismissed_at`); `TestTargetButton_RewriteNeverInheritsState` — for each status, `applied` included, a living rewrite that changes the button's title/intent/parent, or puts a different action at the same index, draws idle; an identical action after a rewrite keeps its state; the args JSON equals the drawn action (title, intent, parent) and the reason names the card; a non-zero propose exit keeps the button pressable and shows the stderr reason (no state cleared before success, review rules error handling); a press in `.preview` mode does nothing; navigating away while a propose runs and coming back shows its result (the press lives in the Inbox center, not the view).

Checks: `make test-swift FILTER='InboxTargetButtonStateTests|InboxCardActionTests|DesignShotsTests|ArtifactFixtureParityTests'`, `make lint-diff`.

## Task 16 — Guide, feature note, CLAUDE.md

**Depends on:** Tasks 1–15. **Lane:** docs.

Files: `docs/guide/` — the automations page that covers the editor and Inbox cards (find it from `docs/guide/README.md`), following `docs/guide/WRITING.md`: the Look step, saying in words how the card should look, the preview and its states, Dry run, the "make a task" button and its approval, living cards ("updated in place"), the AI-step warning; a Learn card only if WRITING.md's rules call for one. New `docs/features/inbox-builder-a.md` (or a section in `docs/features/automations.md`, whichever the umbrella's other sub-projects use — check with the controller): block schema pointer, storage, living rule, press address, the B seams, v1 limits (flat blocks, no image URLs, 50 outputs per run, built-in primitives preview as placeholders). One feature line in `CLAUDE.md`. `docs/inventory/automations.md` Changelog line for the whole sub-project.

Checks: links resolve; `make lint-diff`; the controller then runs the full gate.

## Traceability

| Spec section | Tasks |
|---|---|
| Block document, tone, actions, caps, errors | 1, 2, 13 |
| `body` and plain text | 2, 5, 10 |
| SDK (`blocks`, `key`, `folder` hook, `output.remove`) | 5, 9 |
| `artifacts:` and the serial-run rule | 4 |
| Storage, living upsert, read state | 3, 10 |
| Reply presses | 7, 10 |
| `target` action kind (ask #445) | 2, 5, 14, 15 |
| Swift model and renderer | 1, 10, 13 |
| Look step, preview, states, owner Dry run (ask #445) | 1, 6, 11, 12 |
| AI-step warning | 8, 12 |
| Inventory | 3, 4, 6, 7, 14, 16 |
| Contract with B | 5 (folder hook), 1 (ref hooks, `refs`), 3 (removal), 12 (editor entry) |
