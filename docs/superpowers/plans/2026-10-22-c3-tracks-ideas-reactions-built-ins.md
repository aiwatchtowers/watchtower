# C3 — Tracks, Ideas, Reactions as Built-ins; Watch for Something — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move auto-track extraction, the ideas consolidator and reaction dispatch onto C2's built-in engine as **Track my threads**, **Idea finder** and **Reactions**, and turn every custom track into an ordinary Personal automation made from the **Watch for something** tile, with today's behaviour kept through a one-time upgrade.

**Architecture:** Three new `builtin.Entry`s plug into C2's registry at the slots C2 reserved (`tracks`, `ideas`, `reactions`). Their primitives (`tracks.extract`, `ideas.consolidate`, `reaction.compose`) are Go functions over narrow seams in `internal/tracks`, `internal/ideas` and `internal/reactioncmd`. Those seams take the recipe's prompt text. Dedup, floors, the ledger, locks, budgets and `pipeline_runs` stay where they are. A custom track becomes a Personal recipe with `trigger: {sync: custom_tracks}` and the capability `track:scan`. Its `track.scan` primitive wraps `internal/customtracks`, and the recipe is bound to its `tracks` row by `tracks.automation_id`. Those recipes run at the `custom_tracks` slot, before auto tracks, on C2's dedicated slot executor. The Reactions built-in runs once per claimed ledger row, inside the existing Go reaction pass.

**Tech Stack:** Go 1.26 (goose SQL migration, goja sandbox, cobra), SQLite, SwiftUI (WatchtowerCore + Desktop app, GRDB, DesignKit).

**Spec:** `docs/superpowers/specs/2026-10-22-inbox-built-in-automations-design.md` (owner-approved, ask #500). This plan is part **C3** of §10. Read §4, §5.1–§5.4, §6.2 (track card), §6.3, §7, §8, §9 before any task. Sibling plans this one consumes: C1 (`docs/superpowers/plans/2026-10-22-c1-one-inbox.md`) and C2 (`…-c2-built-in-engine-morning-brief.md`). Both are merged before C3 starts.

## Global Constraints

- Branch off `main` after C1 and C2 have merged; PR into `main`.
- Migration number: **00151** is the next free number once C2's `00150_builtin_automations.sql` has merged. Re-check `ls internal/db/migrations | tail -1` immediately before writing the file and take the next free number.
- Mirror every schema change into `internal/db/schema.sql`, then regenerate the goldens and the Swift test schema: `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`. Any later rebuild of `automations` or `tracks` must recreate this plan's two triggers.
- Go tasks verify with `go test ./internal/<pkg>` for the touched packages, then `make lint-diff`. Tasks touching `cmd/` run `go test ./cmd -run '<Names>' -timeout 30m`.
- Swift tasks verify with `make lint-swift` and `make test-swift FILTER='<Classes>'` (put core tests in `Tests/Core` where possible). `make lint-diff` does not check Swift.
- UI copy is English and built from `WatchtowerDesktop/Sources/DesignKit/` only. These flows use no sheets, popovers or modal confirmations; use inline rows instead. Add affordances use the `+` icon (`Image(systemName: "plus")`, `.kitIcon(isOn: false)`, `.help` carries the word). Read `docs/design/desktop-style-guide.md` and the "Swift / Desktop conventions" section of `docs/review/review-rules.md` first.
- Never weaken an inventory guard (`docs/inventory/`). A guard that moves with its code keeps its name and every assertion. A guard that would have to relax is a stop-and-ask to the owner. This covers TRACKS-01..07, IDEA-01..05, REACT-01..05, STRIP-01..03, FEAT-01..04, AUTO-*, OWNER-01/02 and CATCHUP-01.
- Public repo hygiene: no real ids, names, domains or local paths in fixtures, docs or tests (`acme`, `example.com`, `<owner-slack-id>`).
- Each task declares `Depends on:`. Independent Go tasks may run in parallel worktree lanes. Tasks that edit `internal/daemon/daemon.go` run one at a time, and Swift tasks run one lane at a time.
- Use the fixed strings verbatim.
  - Built-in ids: `track-my-threads`, `idea-finder`, `reactions`.
  - Slots: `tracks`, `ideas`, `reactions`, `custom_tracks` (C2's `SyncSlots`).
  - Primitive names: `tracks.extract`, `ideas.consolidate`, `reaction.compose`, `track.scan`.
  - Capabilities: `builtin:tracks.extract`, `builtin:ideas.consolidate`, `builtin:reaction.compose`, and `track:scan` (Personal only).
  - Upgrade migration ids in `builtin_migrations`: the three built-in ids plus `custom-tracks`.
  - Watch template name: `watch-for-something`. Reaction template name: `on-reaction`.
- Config keys stay the on/off truth: `tracks.enabled`, `ideas.enabled`, `reaction_commands.enabled` (feature ids `tracks`, `ideas`, `reaction-commands`). `ideas.mine_interval_hours` is the Idea finder's **Every** parameter. The dictionary `reaction_command_map` is the Reactions card's parameter. Neither is part of a recipe or its hash.
- Exact UI copy:
  - Built-in names: **Track my threads**, **Idea finder**, **Reactions**.
  - Start tile: **Watch for something**, with the line "Opens the chat; tell it what to watch for, and each new event lands on the track's card in your Inbox."
  - Track card, unbound track: the line "Not watched yet." with **Start Watching**.
  - Track card, bound track: instruction **Save** shows "Saved"; an edited recipe shows "This watch was changed in the chat — change it there." with **Edit in Chat**.
  - Run Now with a date: label **Scan from**, and the note "Runs at the next sync".
  - Reactions card: **+ New reaction automation**.
  - Inbox notices: "Couldn't move Track my threads to Automations", "Couldn't move Idea finder to Automations", "Couldn't move Reactions to Automations", "Couldn't move your watched tracks to Automations". Each has **Retry** (C2's notice).

## Review Focus

1. **A custom track whose recipe was edited by hand or by an agent** (one byte off, a parse error, or the file deleted while its track remains). The track must stop being scanned until the owner confirms. The card then says why, and nothing falls back to scanning with the old instruction. Deleting the file leaves the track readable with "Not watched yet." Tests: Task 8 `TestWatchSlot_HandEditedRecipeStopsTheScan` and `TestWatchSlot_DeletedRecipeLeavesTrackUnbound`.
2. **A reaction burst while the Reactions built-in cannot run** (an unconfirmed owner copy, a script that throws before `reaction.compose`, or a token budget hit). The pass must never re-dispatch or loop, and REACT-03's one side effect at most must hold. An unconfirmed copy claims nothing, and its reactions dispatch once after confirmation, capped at 25. A script that ends without a compose finalizes the row `failed`. Tests: Task 10 `TestReactionsBuiltin_UnconfirmedCopyClaimsNothing`, `TestReactionsBuiltin_ScriptWithoutComposeFinalizesFailed` and `TestReactionsBuiltin_BurstRespectsTheCap`.
3. **The upgrade on an install with many custom tracks.** Cover dismissed tracks, paused tracks, tracks with an empty instruction, tracks linked to a target, and two tracks with the same title. Each live track gets exactly one confirmed recipe, and Collecting/Paused and the history are kept. Dismissed tracks stay unbound. A failure part-way leaves the bound tracks on recipes, the rest on the legacy scan, and nothing scanned twice. Tests: Task 12 `TestCustomTracksUpgrade_*`.
4. **A quiet cycle.** With no new digests, activity or reactions, and the ideas throttle not due, the cycle writes no `automation_runs` rows for these producers. The owner's run history and Costs then stay readable, and the Track my threads gate never hides real material. Tests: Task 9 `TestTrackMyThreads_QuietCycleWritesNoRun`, `TestTrackMyThreads_RetryDigestsMakeItDue` and `TestWatchSlot_NoActivityWritesNoRun`.
5. **The CLI racing the daemon.** `ideas mine --from` can run while the daemon's ideas slot holds `ideas_backfill.lock`. `tracks scan <id> --since` can run while the slot scans that track, and `tracks instruction` can run while a scan is in flight. The outcomes must be: one consolidation at a time (the lock), one scan of a track at a time (per-automation concurrency), and no lost instruction. Tests: Task 11 `TestIdeasMineFrom_RefusedWhileSlotHoldsLock`, `TestTracksScan_RefusedWhileSlotScans` and `TestTracksInstruction_SavedWhileScanning`.

---

## File Structure

| Path | Responsibility |
|---|---|
| `internal/db/migrations/00151_watch_tracks.sql` (create) | `tracks.automation_id`, its unique index, the enabled-mirror and unbind triggers |
| `internal/db/watch_tracks.go` (create) | bind/unbind, ensure, lookups, slot listing, activity probe |
| `internal/db/custom_tracks.go` (modify) | legacy due list leaves bound tracks out |
| `internal/automations/manifest.go`, `recipe.go`, `capabilities.go` (modify) | `track:scan`, the Personal `custom_tracks` slot, primitive → capability map |
| `internal/automations/sdk_builtin.go`, `executor.go`, `dryrun_memory.go` (modify) | slot-run predicate, `track` namespace, `since` input, prompt capture |
| `internal/tracks/pipeline.go`, `internal/ideas/{pipeline,consolidate,backfill}.go`, `internal/prompts/resolve.go` (modify) | prompt override seams, `HasMaterial`, `MovedToBuiltin` |
| `internal/reactioncmd/dispatch.go` (create), `pipeline.go` (modify) | the dispatcher seam |
| `internal/customtracks/bound.go` (create) | the bound scan with an instruction override and extra material |
| `internal/automations/watch/` (create) | watch template, render, start, set-instruction |
| `internal/automations/builtin/recipes/{track-my-threads,idea-finder,reactions}.md`, `registry.go`, `threads.go`, `ideafinder.go`, `reactions.go`, `watchslot.go`, `capture.go` (create/modify) | entries, shipped recipes, primitive bodies, watch slot, prompt capture |
| `internal/daemon/builtin_slots.go` (create), `daemon.go` (modify) | the three slot phases, the reaction dispatcher, gates |
| `cmd/builtins.go`, `cmd/builtin_upgrade.go`, `cmd/tracks.go`, `cmd/ideas.go`, `cmd/reaction_commands.go`, `cmd/automations*.go` (modify) | wiring, upgrade, CLI paths |
| `internal/automations/templates/on-reaction.md`, `index.json`, `internal/skills/shipped/create-automation.md` (create/modify) | the reaction template and the watch authoring guide |
| `WatchtowerDesktop/Sources/WatchtowerCore/...` (modify) | `Track.automationID`, texts, `AutomationStart.watch`, watch controls model, notice names, the section enum removed |
| `WatchtowerDesktop/Sources/Views/...` (modify/delete) | the three built-in cards' parameters, the + tile, track card controls, the Automations sections removed, the Settings rows |
| docs | feature notes, guide pages, CLI reference, inventory |

---

### Task 1: Migration and database layer for watched tracks

**Depends on:** none

**Files:**
- Create: `internal/db/migrations/00151_watch_tracks.sql` (re-check the number), `internal/db/watch_tracks.go`, `internal/db/watch_tracks_test.go`
- Modify: `internal/db/tracks.go` (`trackSelectCols`, scan), `internal/db/custom_tracks.go` (`GetCustomTracksDueForScan`), `internal/db/schema.sql`, the goldens, `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`

**Interfaces:**
- Produces:
  - Column `tracks.automation_id INTEGER` (NULL = unbound). It has no SQL foreign key, so a later down migration can `DROP COLUMN` it. Also produces `CREATE UNIQUE INDEX idx_tracks_automation_id ON tracks(automation_id) WHERE automation_id IS NOT NULL`.
  - Trigger `trg_automations_enabled_watch_track`: `AFTER UPDATE OF enabled ON automations WHEN NEW.enabled <> OLD.enabled BEGIN UPDATE tracks SET enabled = NEW.enabled WHERE automation_id = NEW.id; END`. This mirrors Collecting/Paused for every reader of `tracks.enabled`.
  - Trigger `trg_automations_delete_watch_track`: `AFTER DELETE ON automations BEGIN UPDATE tracks SET automation_id = NULL, enabled = 0 WHERE automation_id = OLD.id; END`.
  - Down: drop both triggers and the index, then `ALTER TABLE tracks DROP COLUMN automation_id`.
  - `db.Track.AutomationID int64` (0 = unbound).
  - `func (db *DB) BindWatchTrack(trackID int, automationID int64) error`. It refuses a track that is not `origin='custom'`, and returns `ErrWatchAlreadyBound` when either side is bound elsewhere.
  - `func (db *DB) GetWatchTrack(automationID int64) (*Track, error)` returns nil when none.
  - `func (db *DB) EnsureWatchTrack(automationID int64, ownerID, name, instruction string) (int, error)`. It returns the bound track, or creates a custom track (`enabled` = the automation's `enabled`) and binds it in one transaction.
  - `func (db *DB) SetWatchInstruction(trackID int, instruction string) error` writes only when the value differs.
  - `func (db *DB) ListSlotRecipes(slot string) ([]Automation, error)`: `origin='owner' AND scope='personal' AND trigger_kind='sync' AND json_extract(trigger_spec,'$.sync') = ? AND removed_at IS NULL`, in id order.
  - `func (db *DB) HasScanActivity(since, until string) (bool, error)` is `GetScanActivity`'s predicate as one `EXISTS` per source, with no rows loaded.
  - `func (db *DB) ListUnboundCustomTracks() ([]Track, error)` returns `origin='custom' AND automation_id IS NULL AND dismissed_at = ''`, in created order.
  - `GetCustomTracksDueForScan` gains `AND automation_id IS NULL` (the legacy scan touches only unbound tracks).

- [ ] **Step 1: Write the failing tests** in `watch_tracks_test.go`:
  - `TestBindWatchTrack_RefusesAutoTrackAndDoubleBinding`.
  - `TestEnsureWatchTrack_CreatesOnceAndInheritsEnabled`. Two calls return the same id, and a disabled automation gives `enabled = 0`.
  - `TestWatchTrack_EnabledMirrorsAutomation`. `UPDATE automations SET enabled = 0` flips the bound track only, and an unbound track is untouched.
  - `TestWatchTrack_AutomationDeleteUnbindsAndPauses`.
  - `TestListSlotRecipes_OnlyPersonalSyncOfThatSlot`. It covers a built-in row, a cron recipe, a removed recipe and a recipe at another slot, all absent.
  - `TestHasScanActivity_MatchesGetScanActivity`. Take a table of windows, and the probe must equal `len(act.Digests)+len(act.Tracks)+len(act.Inbox) > 0`.
  - `TestGetCustomTracksDueForScan_LeavesBoundTracksOut`.
  - `TestMigration00151_UpAndDown`. It seeds tracks, events and states at 00150; after up every row and id is kept; after down the column, index and triggers are gone and the rows are kept.
  - The TRACKS-04/06/07 guards in `internal/db/tracks_test.go` stay untouched and must pass.
- [ ] **Step 2: Run** `go test ./internal/db -run 'WatchTrack|SlotRecipes|ScanActivity|DueForScan|Migration00151'`. Expected: FAIL.
- [ ] **Step 3: Write the migration and the functions.** Mirror `schema.sql`, regenerate the goldens and the Swift test schema.
- [ ] **Step 4: Run** `go test ./internal/db` and `make lint-diff`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(db): bind custom tracks to watch recipes (00151)`.

---

### Task 2: Recipe grammar — C3 primitives, `track:scan`, the Personal `custom_tracks` slot

**Depends on:** none

**Files:**
- Modify: `internal/automations/manifest.go`, `recipe.go`, `capabilities.go`
- Test: `internal/automations/manifest_test.go`, `recipe_test.go`

**Interfaces:**
- Consumes: C2's `BuiltinPrimitiveNames`, `SyncSlots`, `Scope.IsBuiltin`, `Manifest.AllowPrimitive`, `PrimitiveCapability`, `CapabilityForPrimitive`, `syncTriggerAllowed(scope Scope, slot string, m *Manifest) error`, and the `builtinOnly` spec flag.
- Produces:
  - `BuiltinPrimitiveNames` gains `"tracks.extract", "ideas.consolidate", "reaction.compose"`.
  - New capability `track` with verb `scan`, carrying a new spec flag `personalOnly bool`. It is refused in a workbench recipe and in a built-in scope, each with `"%q is allowed only in a personal automation"`.
  - C2's `PrimitiveCapability` map gains `"track.scan": "track:scan"`. C2's `CapabilityForPrimitive` and `AllowPrimitive` are unchanged code (they already read the map).
  - C2's `syncTriggerAllowed(scope Scope, slot string, m *Manifest) error` is widened (its body only; no other sync-trigger check exists):
    - A built-in scope may use any slot in `SyncSlots`.
    - A Personal scope may use only `custom_tracks`, and only with `track:scan` in its manifest.
    - Any other combination keeps C2's message "a sync trigger is only for built-in automations".
    - A `track:scan` recipe without `trigger: {sync: custom_tracks}` is refused with `"track:scan needs trigger: {sync: custom_tracks}"`.
    - A Personal `custom_tracks` recipe without `track:scan` is refused with C2's message.
- [ ] **Step 1: Write the failing tests:**
  - `TestParseRecipe_PersonalWatchRecipeParses`: a personal `{sync: custom_tracks}` recipe with `permissions: [track:scan]`.
  - `TestParseRecipe_WatchShapeRefusals`. Refused: `track:scan` with a cron trigger, `custom_tracks` without `track:scan`, the same recipe in a workbench scope, the same recipe in a built-in scope, and a personal recipe at slot `tracks`.
  - `TestApprovalHash_TrackScanIsHashed`.
  - `TestCapabilityForPrimitive_TrackScanIsPersonal`: `CapabilityForPrimitive("track.scan") == "track:scan"`; C2's `TestCapabilityForPrimitive_DefaultsToBuiltinPrefix` stays unchanged and passes.
  - C2's `TestParseRecipe_SyncTriggerBuiltinOnly`, `TestAuto06_PersonalRecipeCannotDeclareSyncOrBuiltinCapability`, `TestApprovalHash_GoldenCanonicalBytes` and `TestApprovalHash_ButtonLabelIsCosmetic` stay unchanged and pass. They use the `morning_brief` slot and `builtin:` capabilities (C2's fixture rule), which stay refused for Personal recipes, so no assertion of theirs is touched.
- [ ] **Step 2: Run** `go test ./internal/automations -run 'Watch|TrackScan|CapabilityForPrimitive|SyncTrigger|PersonalRecipeCannot|GoldenCanonical'`. Expected: the new tests FAIL and the guards PASS.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `go test ./internal/automations` and `make lint-diff`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(automations): track:scan and the personal custom_tracks slot`.

---

### Task 3: SDK and executor — slot recipes, the `track` namespace, `since`, prompt capture

**Depends on:** Task 1, Task 2

**Files:**
- Modify: `internal/db/automations.go` (C2's `RunsAtSlot` body), `internal/automations/sdk_builtin.go`, `executor.go` (`ExecuteBuiltinInline`'s enabled rule), `dryrun_memory.go`, `backends.go`
- Test: `internal/automations/sdk_builtin_test.go`, `executor_test.go`, `dryrun_memory_test.go`

**Interfaces:**
- Consumes: C2's `Automation.RunsAtSlot()`, `BuiltinInput`, `PrimitiveCall`/`PrimitiveResult`/`PrimitiveFunc`, `Backends.Primitives`, `ExecuteBuiltinInline` and `BuiltinModule` (namespaces per declared capability). Also C2's `CapabilityForPrimitive` with Task 2's `track.scan` entry.
- Produces:
  - C2's `func (a Automation) RunsAtSlot() bool` body widens from `IsBuiltin()` to `IsBuiltin() || (Scope == "personal" && TriggerKind == TriggerKindSync)`. C2's `poll.consider`, `ExecuteBuiltinInline` and `builtin.input` decode already use this predicate, so `poll.consider` and the decode need no code change; `ExecuteBuiltinInline` only gains the enabled rule below.
  - `ExecuteBuiltinInline` accepts `a.RunsAtSlot() && a.Confirmed()`. For a non-built-in it also requires `a.Enabled`, and otherwise cancels the run `not_runnable` with `ErrNotRunnable`. Built-ins keep C2's rule: enabled is the caller's gate.
  - `BuiltinInput` gains `Since string \`json:"since,omitempty"\`` (an RFC 3339 UTC instant: Run Now's **Scan from**). C2 already decodes the run's `event_json` `"builtin"` input for every `RunsAtSlot()` run, so watch runs get it through the widened predicate.
  - JS namespaces follow C2's per-declared-capability rule. `tracks`, `ideas` and `reaction` are installed for their `builtin:` capabilities, so (being `builtinOnly`) only in a built-in scope. `track` is installed when the manifest holds `track:scan`. Calls take this form:
    - `track.scan({instruction, extra?})` returns `{status, events}`.
    - `tracks.extract({prompt})` returns `{status, created, updated}`.
    - `ideas.consolidate({prompt})` returns `{status, proposed}`.
    - `reaction.compose({prompt})` returns `{status, action_id}`.
  - `track.scan` takes `extra`, an array of at most 40 objects `{source_type, source_id, text, at}` (`text` ≤ 4 KiB). `source_type` is one of `slack`, `email`, `jira`, `linear`. A bigger array is a `ValidationError`. The script never passes `since`: Go takes it from `call.Input.Since`.
  - The step permission is `CapabilityForPrimitive(name)` (C2's rule), so `track:scan` for `track.scan`.
  - `DryRunOptions` gains `CapturePrompts func(primitive, prompt string)` and `StopAtModelCalls bool`. In a capture dry run, each primitive call reports its `prompt` and returns `{status: "dry_run"}`. With `StopAtModelCalls` set, an `llm`, `agent`, `mcp`, `shell`, `session` or `ask` call stops the dry run with status `stopped` and the error `"this recipe calls the model before its primitive"`.
- [ ] **Step 1: Write the failing tests:**
  - `TestExecutor_PollNeverClaimsWatchRecipeRuns`: a queued manual run of a confirmed personal `custom_tracks` recipe stays `queued`.
  - `TestExecutor_InlineRunsWatchRecipeOnlyWhenEnabled`.
  - `TestAuto06_InlineRefusesUnconfirmedWatchRecipe`.
  - `TestTrackSDK_InstalledOnlyWithCapability`: `typeof track` is `"undefined"` without `track:scan`, and `typeof tracks` is `"undefined"` in a personal recipe.
  - `TestTrackSDK_SinceComesFromInputOnly`: a script passing `since` gets a `ValidationError`, and `call.Input.Since` reaches the fake primitive.
  - `TestTrackSDK_ExtraIsCapped`: 41 items is a `ValidationError`, and an unknown `source_type` too.
  - `TestTrackSDK_StepPermissionIsTrackScan`.
  - `TestDryRunCapture_ReportsPromptsAndWritesNothing`.
  - `TestDryRunCapture_StopsAtModelCall`.
  - C2's `TestExecutor_PollNeverClaimsBuiltinRuns`, `TestAuto06_BuiltinInlineRefusesUnconfirmed`, `TestExecutor_BuiltinInlineRunsWhenDisabled` and `TestAuto12_BuiltinPrimitiveDryRunCallsNothing` stay unchanged and pass.
- [ ] **Step 2: Run** `go test ./internal/automations -run 'WatchRecipe|TrackSDK|DryRunCapture|Builtin'`. Expected: FAIL (new).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `go test ./internal/automations/... ./internal/db` and `make lint-diff`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(automations): slot recipes, the track namespace and prompt capture`.

---

### Task 4: Prompt override seams in tracks and ideas

**Depends on:** none

**Files:**
- Modify: `internal/tracks/pipeline.go`, `internal/ideas/pipeline.go`, `consolidate.go`, `backfill.go`, `internal/prompts/resolve.go` (`MovedToBuiltin`)
- Test: `internal/tracks/pipeline_test.go` (new tests only), `internal/ideas/pipeline_test.go`, `backfill_test.go`, `internal/prompts/resolve_test.go`

**Interfaces:**
- Consumes: C2's `prompts.DefaultForRole` and `MovedToBuiltin`, plus C2's placeholder-check rule (`countVerbs` against `prompts.Defaults[id]`, where a mismatch uses the default and leaves a note).
- Produces:
  - `tracks.RunOptions{Prompt string}`. `func (p *Pipeline) RunWith(ctx context.Context, opts RunOptions) (created, updated int, err error)`, and `Run` = `RunWith(ctx, RunOptions{})`. A non-empty `Prompt` replaces the store-resolved `tracks.extract_batch` template inside `getPrompt`, with the role instruction still prepended. Everything downstream is unchanged: windows, retry digests, `scoreChannel`, `shouldDropTrack`, fingerprint/Jaccard dedup, the owner check, `TrackContext`. `func (p *Pipeline) LastPromptNote() string`.
  - `func (p *Pipeline) HasMaterial() (bool, error)`. It is true when any digest was created after `lastTracksStartedAt()`. With no prior tracks run, or no tracks for the owner yet, it is true when any digest exists. Owed retry digests also make it true. It makes no AI call and writes nothing.
  - `ideas.RunOptions{Prompt string}`. `func (p *Pipeline) RunWith(ctx context.Context, opts RunOptions) (int, error)` and `func (p *Pipeline) BackfillWith(ctx context.Context, from, to time.Time, progress func(int), opts RunOptions) (BackfillResult, error)`. `Run`/`Backfill` delegate with the zero options. The prompt reaches `consolidate` as a parameter, never a field (the pipeline is shared with `phaseStreamDigests`). `func (p *Pipeline) LastPromptNote() string`.
  - `prompts.MovedToBuiltin` gains `TracksExtractBatch: "track-my-threads"`, `IdeasConsolidate: "idea-finder"` and `ReactionCommand: "reactions"`. The tuner skips them, and `prompts show` prints C2's "Used by the … built-in" line with the built-in's name.
- [ ] **Step 1: Write the failing tests:**
  - `TestTracksRunWith_PromptOverrideReachesGenerator`: stored row "A", override "B…" with the default's verb count. The generator sees "B" with the role prefix.
  - `TestTracksRunWith_PlaceholderMismatchUsesDefault`.
  - `TestTracksHasMaterial_Cases`: a table covering a fresh install with digests, no new digest since the last run, a new digest, and an owed retry digest only.
  - `TestIdeasRunWith_PromptOverride`.
  - `TestIdeasBackfillWith_UsesPromptEveryCycle`.
  - `TestIdeasRunWith_PlaceholderMismatchUsesDefault`.
  - `TestMovedToBuiltin_CThreeIDs`.
  - Every TRACKS-0x and IDEA-0x guard in these packages stays unchanged and passes. Run the packages whole.
- [ ] **Step 2: Run** `go test ./internal/tracks ./internal/ideas ./internal/prompts`. Expected: FAIL (new).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same packages, `go test ./cmd -run 'Prompts' -timeout 30m` and `make lint-diff`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(tracks,ideas): prompt override seams for the built-ins`.

---

### Task 5: The reaction dispatcher seam

**Depends on:** none

**Files:**
- Create: `internal/reactioncmd/dispatch.go`, `internal/reactioncmd/dispatch_test.go`
- Modify: `internal/reactioncmd/pipeline.go` (`dispatchOne` calls the dispatcher; `compose` takes the system prompt)

**Interfaces:**
- Produces:
  ```go
  // Dispatch is one claimed command handed to a dispatcher.
  type Dispatch struct {
      AccountID int64
      ChannelID, MessageTS, ThreadTS, Emoji string
      Tool string // the routed tool name (after routeIssue)
      c    candidate; tool *tools.Tool; prefixes *prefixCache // unexported
  }
  type Step int // StepFinalize | StepRelease | StepStrand (the existing ledgerStep, exported)
  type Outcome struct { Status string; ActionID int64; Detail string; Step Step }
  type Dispatcher func(ctx context.Context, d Dispatch) Outcome
  func (p *Pipeline) SetDispatcher(fn Dispatcher)                          // nil = the built-in Go dispatcher (today)
  func (p *Pipeline) DispatchWith(ctx context.Context, d Dispatch, prompt string) Outcome // today's dispatch body with `prompt` as the system prompt ("" = prompt store)
  func (p *Pipeline) SetDispatchPaused(paused bool) // true: poll, seed and publish events, but claim nothing (no ledger row, no budget spent)
  ```
  `dispatchOne` keeps its order: resolve the tool (free skips), take the budget, claim, then build a `Dispatch` with tracker routing done. It calls the dispatcher, defaulting to `DispatchWith(ctx, d, "")`, and maps the `Outcome` to release, strand or finalize exactly as today. The 25-per-run cap, the claim and finalize, and the one-hour strand stay here. `ContextID = ChannelID + "@" + MessageTS` on the `reaction` surface is built only inside `DispatchWith` (REACT-02).
- [ ] **Step 1: Write the failing tests:**
  - `TestReactionCmd_CustomDispatcherSeesRoutedTool`: a Linear-keyed channel shows `Tool == "create_linear_issue"`.
  - `TestReactionCmd_DispatcherOutcomeDrivesLedger`: a table where `StepRelease` deletes the row, `StepStrand` leaves it provisional, and `StepFinalize` with `failed` and with `dispatched` sets the status.
  - `TestReactionCmd_DispatchWithPromptReachesGenerator`.
  - `TestReactionCmd_DispatcherNotCalledPastTheCap`.
  - `TestReactionCmd_PausedClaimsNothingButPublishes`.
  - Every REACT-0x guard in `pipeline_test.go`, `seed_test.go` and `route_test.go` stays unchanged and passes on the default dispatcher.
- [ ] **Step 2: Run** `go test ./internal/reactioncmd`. Expected: FAIL (new).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `go test ./internal/reactioncmd` and `make lint-diff`. Expected: PASS.
- [ ] **Step 5: Commit** `refactor(reactioncmd): a dispatcher seam for the Reactions built-in`.

---

### Task 6: Bound custom-track scan and the watch package

**Depends on:** Task 1

**Files:**
- Create: `internal/customtracks/bound.go`, `bound_test.go`
- Create: `internal/automations/watch/watch.go`, `template.md`, `watch_test.go`, `testmain_test.go`

**Interfaces:**
- Consumes: Task 1's DB functions, `automations.Indexer.WriteRecipe`, `automations.PersonalDir` and `db.ConfirmAutomation`.
- Produces:
  ```go
  // internal/customtracks
  type ExtraItem struct { SourceType, SourceID, Text string; At time.Time }
  type ScanOptions struct {
      Instruction string      // the recipe's text; replaces the row's for this scan (and is mirrored by the caller)
      Since       string      // "" = forward from the watermark; set = backfill (two-stage shortlist)
      Extra       []ExtraItem // recipe-gathered material; only items with At after the track's watermark are used (forward runs only)
  }
  func (p *Pipeline) ScanBound(ctx context.Context, t db.Track, opts ScanOptions) ([]db.TrackEvent, error)
  func (p *Pipeline) Due(t db.Track, now time.Time) bool // enabled, not dismissed, under today's failure budget (maxDailyScanAttempts)
  func (p *Pipeline) RecordFailure(trackID int, now time.Time, err error) // today's recordScanFailure
  ```
  `ScanBound` is `runOne` with the instruction override. The `Extra` items are rendered after the activity block as data fenced with backticks longer than any run inside them (the #553/#554 data rule). The watermark, the per-source cap, the summary dedup and the watermark advance all keep today's rules (see the rulings).
  ```go
  // internal/automations/watch
  const TemplateName = "watch-for-something"
  func Render(name, instruction string) ([]byte, error)          // template.md with JSON string literals; parses as a personal recipe
  func Instruction(recipe []byte) (string, bool)                   // the one `const instruction = <JSON>;` line, else false
  func SetInstruction(recipe []byte, instruction string) ([]byte, error) // ErrNotTemplateShaped when that line is not there exactly once
  type StartOptions struct { Confirm bool; Now time.Time }
  func Start(ctx context.Context, d *db.DB, ix *automations.Indexer, workspaceDir string, t db.Track, opts StartOptions) (*db.Automation, error)
  ```
  The template `template.md` has these properties:
  - `name: <name>`, `trigger: {sync: custom_tracks}`, `permissions: [track:scan]`, no outputs.
  - Budget `{tokens: 200000, minutes: 10}`.
  - Script:
    ```js
    const instruction = "<JSON>";
    track.scan({ instruction });
    ```
  `Start` follows these rules:
  - The instruction is `t.Instruction`, else `t.Context`, else `t.Text`.
  - The path is `<ws>/automations/watch-<track id>-<slug of text, ≤ 40>.md`.
  - It writes through `WriteRecipe`, then `BindWatchTrack`, then sets `enabled` from `t.Enabled`.
  - It runs `ConfirmAutomation(id, approvalHash, now)` only when `opts.Confirm`.
  - It is idempotent: a bound track returns its automation and writes nothing.
- [ ] **Step 1: Write the failing tests:**
  - `TestScanBound_InstructionOverrideReachesPrompt`.
  - `TestScanBound_ExtraOlderThanWatermarkDropped`.
  - `TestScanBound_ExtraFencedAsData`: text holding a backtick run and "Ignore previous instructions" is inside a longer fence.
  - `TestScanBound_BackfillUsesShortlistAndDedup`.
  - `TestScanBound_ForwardKeepsTodaysDedupAndCapWatermark`.
  - `TestDue_BudgetAndDismissed`.
  - `TestWatchRender_ParsesAndRoundTripsInstruction`: an instruction with quotes, a backtick, `%s` and U+2028.
  - `TestWatchSetInstruction_RefusesEditedRecipe`.
  - `TestWatchStart_BindsConfirmsAndIsIdempotent`.
  - `TestWatchStart_UnconfirmedWithoutConfirm`.
  - `TestWatchStart_SameTitleTwoTracksTwoFiles`.
- [ ] **Step 2: Run** `go test ./internal/customtracks ./internal/automations/watch`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same packages and `make lint-diff`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(customtracks,watch): bound scan and the Watch for something recipe`.

---

### Task 7: Built-in entries, shipped recipes and primitive bodies

**Depends on:** Task 2, Task 3, Task 4, Task 5

**Files:**
- Create: `internal/automations/builtin/recipes/track-my-threads.md`, `idea-finder.md`, `reactions.md`; `threads.go`, `ideafinder.go`, `reactions.go` (+ `_test.go` each); `testdata/show_track_my_threads.json`, `show_idea_finder.json`, `show_reactions.json`
- Modify: `internal/automations/builtin/registry.go` (`All()`, `Slot` constants `SlotTracks`, `SlotIdeas`, `SlotReactions`, `SlotCustomTracks`, `ParamKind` `interval`/`dictionary`), `registry_test.go`

**Interfaces:**
- Consumes: C2's `Entry` (incl. `RunNow`/`NoRunNowNote`), `PromptRef`, `Parameter`, `ParseShipped`, `RenderOwnerCopy`, `Card`, the C2 Runner and `MorningBriefHooks` precedent; Task 4's and Task 5's seams.
- Produces the entries:

  | Id | Name | Slot | FeatureIDs | Primitives | Prompts | Parameters | Pipelines | RunNow |
  |---|---|---|---|---|---|---|---|---|
  | `track-my-threads` | Track my threads | `tracks` | `["tracks"]` | `["tracks.extract"]` | `[{extract, TracksExtractBatch}]` | none | `["tracks"]` | `true` |
  | `idea-finder` | Idea finder | `ideas` | `["ideas"]` | `["ideas.consolidate"]` | `[{consolidate, IdeasConsolidate}]` | `[{ideas.mine_interval_hours, interval, "Every"}]` | `["ideas"]` | `true` |
  | `reactions` | Reactions | `reactions` | `["reaction-commands"]` | `["reaction.compose"]` | `[{compose, ReactionCommand}]` | `[{reaction_command_map, dictionary, "Reactions"}]` | `["reaction-commands"]` | `false`, `NoRunNowNote: "Reactions run for each reaction you place"` |

  - When lines:
    - `track-my-threads`: "After every sync, while Slack Digests are on".
    - `idea-finder`: "Every %d hours" (from `ideas.mine_interval_hours`, default 6).
    - `reactions`: "When you react to a Slack message".
  - Reads:
    - `track-my-threads`: "Slack channel digests, your profile and your tracks".
    - `idea-finder`: "Slack digest topics, mail and tracker digests, meeting recaps".
    - `reactions`: "The message you reacted to and its thread".
  - Sends:
    - `track-my-threads`: "Track cards in your Inbox".
    - `idea-finder`: "Idea cards in your Inbox; decisions to your brief".
    - `reactions`: "Proposals in your Inbox (ideas, reminders and brief notes apply at once)".
  - A `dictionary` parameter's `Key` is the table name; `CardInfo.parameters[].value` for it is `[]` (the Desktop reads the table). An `interval` value is the integer hours.
  - Each shipped recipe has `trigger: {sync: <slot>}` and `permissions: [builtin:<primitive>]`, no outputs. Its script is `<ns>.<fn>({ prompt: builtin.defaultPrompt("<name>") });`.
  - Budgets:

    | Recipe | Budget |
    |---|---|
    | `track-my-threads` | `{tokens: 600000, minutes: 15}` |
    | `idea-finder` | `{tokens: 400000, minutes: 15}` |
    | `reactions` | `{tokens: 20000, minutes: 2}` (one command per run) |
  ```go
  type TracksRunner interface { RunWith(ctx context.Context, o tracks.RunOptions) (int, int, error); AccumulatedUsage() (int, int, float64, int); LastPromptNote() string }
  type ThreadsHooks struct { Track func(run func() (int, int, error)) (int, int, error) } // daemon: trackedPipelineRun("tracks") with LastFrom/LastTo; CLI: today's cli pipeline_runs row
  func TrackMyThreadsPrimitives(p TracksRunner, h ThreadsHooks) map[string]automations.PrimitiveFunc

  type IdeasRunner interface { RunWith(ctx context.Context, o ideas.RunOptions) (int, error); AccumulatedUsage() (int, int, float64, int); LastPromptNote() string }
  type IdeaHooks struct {
      Lock  func() (release func(), err error)        // ideas.AcquireBackfillLock(ws, "daemon"|"cli")
      Track func(run func() (int, error)) (int, error) // daemon: trackedPipelineRun("ideas") + lastIdeas stamp; CLI: direct
  }
  func IdeaFinderPrimitives(p IdeasRunner, h IdeaHooks) map[string]automations.PrimitiveFunc

  // ReactionSlot carries the one claimed command a Reactions run handles.
  type ReactionSlot struct{ /* mu; pending map[int64]*reactionCall keyed by run id */ }
  func NewReactionSlot() *ReactionSlot
  func (s *ReactionSlot) Begin(runID int64, d reactioncmd.Dispatch)
  func (s *ReactionSlot) End(runID int64) (reactioncmd.Outcome, bool) // false = the script never called reaction.compose
  func ReactionPrimitives(p interface{ DispatchWith(context.Context, reactioncmd.Dispatch, string) reactioncmd.Outcome }, s *ReactionSlot) map[string]automations.PrimitiveFunc
  ```
  - Primitive rules:
    - Usage is the delta of `AccumulatedUsage()` around the call (C2's rule). `reaction.compose` reports zero usage: `reactioncmd` does not meter, and the run row stays the history.
    - `tracks.extract` returns `{status: "done", created, updated}`.
    - `ideas.consolidate` takes `Lock` first; a held lock returns `{status: "skipped"}` with Note "another ideas run holds the lock". It returns `proposed`.
    - `reaction.compose` finds the run's pending `Dispatch`; none is a `ValidationError`, and a second call in one run is a `ValidationError`. It calls `DispatchWith(ctx, d, prompt)`, stores the `Outcome`, and returns `{status: outcome.Status, action_id}`.
- [ ] **Step 1: Write the failing tests:**
  - `TestRegistry_ShippedRecipesParse` and `TestRegistry_FeatureIDsHaveConfigKeys` (C2's tests, now over four entries, unchanged code).
  - `TestRegistry_ShowJSONGolden` with the three new goldens (`run_now`: `true`, `true`, `false`).
  - C2's `TestRegistry_RunNowNoteOnlyWhenNoRunNow`, now over four entries, unchanged code.
  - `TestTrackMyThreads_PrimitivePassesPromptAndTracks`.
  - `TestIdeaFinder_LockHeldIsSkipped`.
  - `TestIdeaFinder_UsageIsTheDelta`.
  - `TestReactions_ComposeUsesPendingDispatch`.
  - `TestReactions_SecondComposeInOneRunRefused`.
  - `TestReactions_EndWithoutComposeReportsFalse`.
  - `TestRenderOwnerCopy_ForEachC3Entry`: the owner copy parses, and the fake primitive receives the exact text.
- [ ] **Step 2: Run** `go test ./internal/automations/builtin`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `go test ./internal/automations/...` and `make lint-diff`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(builtin): Track my threads, Idea finder and Reactions entries`.

---

### Task 8: Runner extensions — sync inline runs, the watch slot, prompt capture

**Depends on:** Task 3, Task 6, Task 7

**Files:**
- Create: `internal/automations/builtin/watchslot.go`, `capture.go` (+ tests)
- Modify: `internal/automations/builtin/runner.go`, `docs/inventory/automations.md` (AUTO-06 text, guards, changelog)

**Interfaces:**
- Consumes: C2's `Runner`, `TakeQueuedBuiltinRun`, `ExecuteBuiltinInline` and `DryRunInMemory`; Task 1's `ListSlotRecipes`, `EnsureWatchTrack`, `GetWatchTrack` and `HasScanActivity`; Task 6's `ScanBound`/`Due`/`RecordFailure`.
- Produces:
  ```go
  func (r *Runner) RunSyncInline(ctx context.Context, id string, in automations.BuiltinInput) (*db.AutomationRun, error)
  // = EnqueueSync + ExecuteRun; requires e.Enabled(cfg) and Confirmed(), else ErrNotRunnable (no row)
  func (r *Runner) EnqueueSync(id string, in automations.BuiltinInput) (*db.AutomationRun, error) // TriggerSync row, event_json {"builtin": in}
  func (r *Runner) ExecuteRun(ctx context.Context, runID int64) (*db.AutomationRun, error)        // ExecuteBuiltinInline

  type WatchScanner interface {
      ScanBound(ctx context.Context, t db.Track, o customtracks.ScanOptions) ([]db.TrackEvent, error)
      Due(t db.Track, now time.Time) bool
      RecordFailure(trackID int, now time.Time, err error)
  }
  func WatchPrimitives(d *db.DB, s WatchScanner, owner func() (db.Owner, error)) map[string]automations.PrimitiveFunc
  type WatchGate interface { Due(ctx context.Context, a db.Automation, t db.Track, now time.Time) bool }
  func NewWatchGate(d *db.DB, s WatchScanner) WatchGate // s.Due(t) && HasScanActivity(watermark or now-7d, now-1s)
  func (r *Runner) RunWatchSlot(ctx context.Context, g WatchGate) []SlotOutcome

  func CapturePrompts(ctx context.Context, b automations.Backends, a *db.Automation) (map[string]string, error)
  // DryRunInMemory over the row's current text with CapturePrompts + StopAtModelCalls; requires a.Confirmed()
  ```
  - `track.scan` primitive:
    1. Load the run's bound track. `EnsureWatchTrack` runs with the recipe's name, the call's instruction, and the owner from `ResolveOwner` (no owner gives `{status: "skipped"}`, OWNER-02).
    2. Mirror the instruction with `SetWatchInstruction`.
    3. On a sync run, return `{status: "skipped"}` when `!s.Due(t)`.
    4. Call `ScanBound` with `Since = call.Input.Since` and the `extra` items.
    5. On error, call `RecordFailure` (sync runs only) and return the error.
    6. Return `events` (the count).
  - `RunWatchSlot`: for each recipe from `ListSlotRecipes("custom_tracks")`:
    - An unconfirmed recipe gets its queued manual runs cancelled `not_runnable`, with `Skipped "not_confirmed"`.
    - A disabled recipe gives `Skipped "off"`.
    - Otherwise run `EnsureWatchTrack`. A queued manual run executes without the gate. Else `g.Due` false gives `Skipped "not_due"` and no row. Else enqueue `TriggerSync`, then `ExecuteBuiltinInline`.
  - Recipes run one after another. A watch's failure never stops the next.
- [ ] **Step 1: Write the failing tests:**
  - `TestRunSyncInline_OneRowSyncTrigger`.
  - `TestRunSyncInline_OffOrUnconfirmedWritesNothing`.
  - `TestWatchSlot_RunsConfirmedEnabledRecipes`.
  - `TestWatchSlot_NoActivityWritesNoRun`.
  - `TestWatchSlot_BudgetSpentWritesNoRun`.
  - `TestWatchSlot_HandEditedRecipeStopsTheScan`.
  - `TestWatchSlot_DeletedRecipeLeavesTrackUnbound`: removed from disk, `removed_at` set, no run, the track keeps its events.
  - `TestWatchSlot_QueuedScanFromRunsBackfill`: `Since` reaches `ScanBound`.
  - `TestWatchSlot_FailureChargesBudgetAndNextRecipeRuns`.
  - `TestWatchSlot_InstructionMirroredToTrack`.
  - `TestCapturePrompts_ShippedAndOwnerCopy`.
  - `TestCapturePrompts_RefusesUnconfirmed`.
- [ ] **Step 2: Run** `go test ./internal/automations/builtin`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Amend `docs/inventory/automations.md`.**
  - AUTO-06 Observable gains this sentence: "A Personal recipe with `track:scan` (Watch for something) runs only after the owner confirms it, like any Personal recipe; it runs at the `custom_tracks` slot of the sync cycle on the slot executor, never in the executor's queue. The owner-only commands `tracks create|watch|start|instruction` (Task 11) confirm only the recipe they render from the template, and the one-time upgrade confirms only the watch recipes it renders for custom tracks that were already scanning (Task 12)."
  - Add the Task 3, 8, 11 and 12 guards to its list.
  - Add a changelog line naming board #801, spec §6.3/§8, and "no guard relaxed".
- [ ] **Step 5: Run** `go test ./internal/automations/... ./internal/db` and `make lint-diff`. Expected: PASS.
- [ ] **Step 6: Commit** `feat(builtin): watch slot, sync inline runs and prompt capture`.

---

### Task 9: Daemon — Track my threads, the watch slot and Idea finder

**Depends on:** Task 7, Task 8

**Files:**
- Create: `internal/daemon/builtin_slots.go`, `internal/daemon/builtin_slots_test.go`
- Modify: `internal/daemon/daemon.go` (`runSync`: `phaseCustomTrackScan` → `phaseWatchSlot`, the tracks half of `phaseTracksAndRollups` → `phaseTrackMyThreads`, `phaseIdeas` → `phaseIdeaFinder`), `daemon_gates_test.go`, `daemon_customtracks_test.go`, `daemon_ideas_test.go`, `daemon_streams_test.go`, `cmd/builtins.go` (`wireBuiltins`), `docs/inventory/features.md`, `docs/inventory/tracks.md`, `docs/inventory/ideas.md`

**Interfaces:**
- Consumes: C2's `SetBuiltins(r, active)` / the `active[id]` legacy switch, `Daemon.BuiltinPrimitives()`, `trackedPipelineRun` and `wireBuiltins` (its slot executor is already built from `automationBackends`); Tasks 7–8.
- Produces:
  ```go
  func (d *Daemon) BuiltinPrimitives() map[string]automations.PrimitiveFunc // C2's, signature unchanged; body extends from MorningBriefPrimitives() to that ∪ TrackMyThreadsPrimitives ∪ IdeaFinderPrimitives ∪ ReactionPrimitives ∪ WatchPrimitives
  func (d *Daemon) TrackMyThreadsGate() builtin.Gate // tracks.enabled && digest.enabled && tracksPipe != nil && HasMaterial()
  func (d *Daemon) IdeaFinderGate() builtin.Gate     // ideas.enabled && ideasPipe != nil && interval elapsed (lastIdeas) && !ideas.BackfillLockFresh(ws)
  func (d *Daemon) phaseWatchSlot(ctx context.Context)
  func (d *Daemon) phaseTrackMyThreads(ctx context.Context, now time.Time)
  func (d *Daemon) phaseIdeaFinder(ctx context.Context)
  ```
  - `phaseWatchSlot` returns first unless `tracks.enabled && digest.enabled` (FEAT-01 holds; see the rulings). With `active["custom-tracks"]` false (the migration not done), it runs today's `phaseCustomTrackScan`, which now touches only unbound tracks. In every case it then calls `d.builtins.RunWatchSlot(ctx, gate)`.
  - `phaseTrackMyThreads`:
    - `active["track-my-threads"]` false: today's tracks half.
    - Else: `RunSlot(SlotTracks)`.
    - Then, whenever `tracks.enabled && digest.enabled`: today's `TrackContext` injection.
    - Then: `runRollupPhase` unchanged.
    It keeps its place in group A, beside people cards.
  - `phaseIdeaFinder`: `active["idea-finder"]` false runs today's `phaseIdeas`. Else it runs `RunSlot(SlotIdeas)`, whose `IdeaHooks.Track` stamps `lastIdeas` (`saveLastIdeas`) whenever the pipeline ran, error or not (today's rule).
  - `pipeline_runs` names `tracks`, `custom_tracks` and `ideas` are unchanged. `custom_tracks` rows come only from the legacy path. A watch run's history is its `automation_runs` row.
  - `wireBuiltins` is unchanged: C2 already builds the slot executor from `automationBackends(cfg, database, gen)` with `Primitives = d.BuiltinPrimitives()` and `DefaultPrompt`, so watch recipes have the read tools. It only adds the three new gates to the Runner's `gates` map.
- [ ] **Step 1: Write the failing tests** (real DB, fake generator):
  - `TestBuiltinPrimitives_HoldsC3Primitives`: `d.BuiltinPrimitives()` holds `tracks.extract`, `ideas.consolidate`, `reaction.compose` and `track.scan`; C2's `TestBuiltinPrimitives_HoldsMorningBriefPrimitives` stays unchanged and passes.
  - `TestTrackMyThreads_DueRunMakesTracksAndOneRun`: one `automation_runs` row `sync`/`succeeded`, one `pipeline_runs` `tracks` row with `period_from`/`period_to`, tracks created.
  - `TestTrackMyThreads_QuietCycleWritesNoRun`: no `automation_runs` row and no `pipeline_runs` row.
  - `TestTrackMyThreads_RetryDigestsMakeItDue`.
  - `TestTrackMyThreads_TrackContextInjectedEvenWhenNotDue`.
  - `TestTrackMyThreads_UnconfirmedCopyStopsExtractionNotRollups`.
  - `TestTrackMyThreads_LegacyPathWhenNotActive`.
  - `TestWatchSlot_RunsBeforeTrackMyThreads`: run-order recorder.
  - `TestWatchSlot_LegacyScansOnlyUnboundTracks`.
  - `TestIdeaFinder_ThrottleAndLockAsToday`.
  - `TestIdeaFinder_ErrorStillStampsThrottle`.
  - Move, keeping names and assertions:
    - `TestFeatureGates_DisabledPhaseWritesNoPipelineRun` cases `tracks`, `tracks_starved_without_digest` and `ideas` drive `phaseWatchSlot` + `phaseTrackMyThreads` and `phaseIdeaFinder`, in both the active and the legacy modes. Each additionally asserts zero `automation_runs` rows. The ideas case keeps its no-lock-file assertion.
    - `TestDaemon_CustomTracks_AllBudgetsSpentWritesNoRun`, `…_NoTracksWritesNoRun` and `…_DueTrackIsTracked` drive `phaseWatchSlot` in legacy mode as today, and gain a bound-recipe twin each, with the suffix `_Recipe`.
    - `TestDaemon_PhaseIdeas_SkipsWhileBackfillLockFresh`, `…_ThrottlesLockSkipLog` and `…_RunsWhenLockAbsent` drive `phaseIdeaFinder`.
    - `TestDaemon_PhaseStreamDigestsThenPhaseIdeas_UsageDeltaNotDoubleCounted` asserts the same delta on the Idea finder run's usage.
- [ ] **Step 2: Run** `go test ./internal/daemon -run 'TrackMyThreads|WatchSlot|IdeaFinder|BuiltinPrimitives|FeatureGates|CustomTracks|PhaseIdeas|StreamDigests'`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Amend the inventory.**
  - `features.md` FEAT-01's phase list: replace `phaseCustomTrackScan` with "the custom-track slot (`phaseWatchSlot`)". Replace `phaseTracksAndRollups` (tracks arm) with "the Track my threads built-in's slot (`phaseTrackMyThreads`)". Replace `phaseIdeas` with "the Idea finder built-in's slot (`phaseIdeaFinder`)". Each writes no `automation_runs` row while its key is off.
  - FEAT-02/03 wording: the switch for Tracks/Ideas/Reaction commands is its built-in's Turn On/Off, through the feature-toggle path.
  - Changelog: "FEAT-01..03 amended in wording, owner approved in ask #500; guard cases kept, `automation_runs` assertion added; no guard relaxed."
  - `tracks.md` and `ideas.md`: **Module** gains the primitive files, and a changelog line says "contracts unchanged; enforced by the `tracks.extract` / `ideas.consolidate` primitives over the same Go pipeline; guards unchanged".
- [ ] **Step 5: Run** `go test ./internal/daemon ./internal/automations/builtin` and `go test ./cmd -run 'Sync|Daemon|Builtin' -timeout 30m`, then `make lint-diff`. Expected: PASS.
- [ ] **Step 6: Commit** `feat(daemon): Track my threads, Idea finder and watch recipes at their slots`.

---

### Task 10: Daemon — the Reactions built-in inside the reaction pass

**Depends on:** Task 9

**Files:**
- Modify: `internal/daemon/builtin_slots.go` (`reactionDispatcher`), `internal/daemon/daemon.go` (`phaseReactionCommands` sets the dispatcher), `cmd/builtins.go`, `internal/daemon/daemon_reactioncmd_test.go` (new tests only), `docs/inventory/reaction-commands.md`

**Interfaces:**
- Consumes: Task 5's `SetDispatcher`/`Dispatch`/`Outcome`; Task 7's `ReactionSlot`; Task 8's `RunSyncInline`.
- Produces: `func (d *Daemon) reactionDispatcher() reactioncmd.Dispatcher`. The pass sets it at the start of `phaseReactionCommands` when `active["reactions"]` is true and the Reactions row is `Confirmed()`. While the row is not confirmed, the pass still polls, seeds and publishes `slack.reaction_added`, but `dispatchOne` claims nothing (Task 5's `SetDispatchPaused(true)`). Per claimed row, the dispatcher runs:
  1. `EnqueueSync("reactions", {})`, so the run id is known before execution.
  2. `ReactionSlot.Begin(runID, d)`.
  3. `ExecuteRun(ctx, runID)`.
  4. `End(runID)`. A stored `Outcome` is returned as is. No outcome (the script threw or never called compose, the budget was hit, or the run was interrupted) gives `Outcome{Status: "failed", Detail: "the Reactions automation did not compose: <run error or 'no compose call'>", Step: StepFinalize}`. Nothing was proposed, so the row is terminal and never retried.
  A run that could not even be created (`ErrNotRunnable` raced in) gives `StepRelease`.
- [ ] **Step 1: Write the failing tests:**
  - `TestReactionsBuiltin_DispatchesThroughRecipe`: one `automation_runs` row per claimed reaction, an `agent_actions` row with `surface='reaction'` and `context_id='<channel>@<ts>'` (REACT-02), the ledger `dispatched`.
  - `TestReactionsBuiltin_InstantToolsStayInstant`: `create_idea` applies at once on the `reaction` surface.
  - `TestReactionsBuiltin_ExternalStaysPending` (REACT-04).
  - `TestReactionsBuiltin_UnconfirmedCopyClaimsNothing`. No ledger rows are written while unconfirmed. After confirmation the next poll dispatches each reaction once.
  - `TestReactionsBuiltin_ScriptWithoutComposeFinalizesFailed`.
  - `TestReactionsBuiltin_BurstRespectsTheCap`: 30 reactions give 25 runs, and the rest follow next poll.
  - `TestReactionsBuiltin_TransientComposeReleases` (REACT-03).
  - `TestReactionsBuiltin_EventsStillPublished`.
  - `TestReactionsBuiltin_LegacyWhenNotActive`.
  - Every existing `TestDaemon_PhaseReactionCommands_*`, `TestDaemon_ReactionCommandsDefaultOn` and `TestDaemon_RunSync_PollsReactionsBeforeAIPipelines` stays unchanged and passes.
- [ ] **Step 2: Run** `go test ./internal/daemon -run 'ReactionsBuiltin|ReactionCommands'` and `go test ./internal/reactioncmd`. Expected: FAIL (new).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Amend `reaction-commands.md`.** Add a REACT-03 note: "Since C3 the compose step runs inside the Reactions built-in's recipe (one `automation_runs` row per claimed row); claim, finalize, release, strand and the cap stay in the Go pass; a run without a compose finalizes `failed`". Add the new guards under REACT-01..04. The changelog line says "REACT-01..05 unchanged; no guard relaxed".
- [ ] **Step 5: Run** the same packages and `make lint-diff`. Expected: PASS.
- [ ] **Step 6: Commit** `feat(daemon): reaction commands composed by the Reactions built-in`.

---

### Task 11: CLI paths

**Depends on:** Task 8, Task 9, Task 10

**Files:**
- Modify: `cmd/tracks.go`, `cmd/ideas.go`, `cmd/reaction_commands.go`, `cmd/automations_run.go`, `cmd/automations.go` (show/list), `cmd/builtins.go` (`newCLIBuiltinRunner` gains C3 primitives)
- Test: `cmd/tracks_test.go`, `cmd/ideas_test.go`, `cmd/builtins_test.go`, `cmd/automations_test.go`

**Interfaces:**
- Consumes: C2's `newCLIBuiltinRunner`, `RunNow` and `signalSyncNow`; Tasks 6–8.
- Produces:
  - `tracks generate [--progress-json]` runs `RunNow("track-my-threads", {})` inline. The output and progress lines are as today, and the CLI `pipeline_runs` row comes through `ThreadsHooks`. The command uses C2's refusal texts: an unconfirmed copy gives "Track my threads: your edited copy is not confirmed yet — confirm it in Automations → Built in", and a busy run gives "Track my threads is running now — try again in a minute".
  - `tracks scan <id> [--since]` on a bound track runs the recipe inline as a manual run with `Input.Since` and prints the events JSON as today. Another active run of it gives "this watch is scanning now — try again in a minute". On an unbound custom track it gives "track #N is not watched — run `watchtower tracks start N`". `tracks scan` with no id runs each enabled, confirmed watch recipe inline, one after another.
  - `tracks create --text|--text-file [--target]` and `tracks watch <target-id>` keep the compose call and their JSON. They then call `watch.Start(Confirm: true)`. Under agent markers (`refuseUnderAgent`'s markers) they use `Confirm: false` and the JSON gains `"confirmed": false` with `"note": "Confirm it in Automations."`.
  - `tracks start <id> [--json]` is new and owner-only (`refuseUnderAgent`). It calls `watch.Start(Confirm: true)` and returns JSON `{"track_id", "automation_id"}`.
  - `tracks instruction <id> --text|--text-file` is new and owner-only. It requires the bound row `Confirmed()`. It applies `watch.SetInstruction` and saves through the indexer. It runs `ConfirmAutomation` with the new hash and `SetWatchInstruction`. Refusal texts: `ErrNotTemplateShaped` gives "This watch was changed in the chat — change it there." An unconfirmed row gives "confirm this watch in Automations first".
  - `tracks enable|disable <id>` on a bound track sets the recipe's `enabled` (the trigger mirrors it). On an unbound track it works as today. `tracks restore <id>` of an unbound custom track adds the line "Run `watchtower tracks start <id>` to watch it again."
  - `ideas mine` (no `--from`) keeps the stage-1 passes as today, then runs `RunNow("idea-finder", {})` inline (CLI `IdeaHooks.Lock` = `AcquireBackfillLock(ws, "cli")`). `ideas mine --from [--to]` resolves the prompt with `builtin.CapturePrompts` on the Idea finder row (an unconfirmed copy gives C2's refusal), then runs `BackfillWith(…, RunOptions{Prompt})` under the lock as today. It writes no `automation_runs` row (see the rulings).
  - `reaction-commands poll` sets the CLI dispatcher (Task 10's shape over the CLI runner) when the Reactions row is confirmed. Otherwise it reports "Reactions: your edited copy is not confirmed yet" and polls without claiming.
  - `automations run <id> [--since <RFC3339>]`:
    - On a watch recipe it enqueues a manual run with `{"builtin": {"since": …}}`, sends `signalSyncNow`, and the JSON adds `"at_next_sync": true`.
    - `--since` on any other automation gives "--since is only for a watch".
    - On `reactions` it gives "Reactions run for each reaction you place" — C2's `!e.RunNow` refusal with the entry's `NoRunNowNote`; no new CLI code.
  - `automations show <id> --json` adds `"watch": {"track_id", "instruction", "template_shaped"}` for a watch recipe, and `null` otherwise. `list --json` rows add `"track_id"` (0 when none).
- [ ] **Step 1: Write the failing tests:**
  - `TestTracksGenerate_UsesOwnerCopyPrompt`.
  - `TestTracksGenerate_RefusedForUnconfirmedCopy`.
  - `TestTracksScan_BoundRunsRecipeWithSince`.
  - `TestTracksScan_RefusedWhileSlotScans`.
  - `TestTracksScan_UnboundPointsToStart`.
  - `TestTracksCreate_WritesConfirmedWatch`.
  - `TestTracksCreate_UnderAgentLeavesUnconfirmed`.
  - `TestTracksStart_RefusedUnderAgentMarkers`.
  - `TestTracksInstruction_RewritesAndConfirms`.
  - `TestTracksInstruction_RefusesEditedRecipe`.
  - `TestTracksInstruction_SavedWhileScanning`: the next scan uses the new text.
  - `TestTracksEnableDisable_BoundTogglesRecipe`.
  - `TestIdeasMine_RunsIdeaFinderRecipe`.
  - `TestIdeasMineFrom_UsesCapturedPrompt`.
  - `TestIdeasMineFrom_RefusedWhileSlotHoldsLock`.
  - `TestReactionCommandsPoll_UsesRecipe`.
  - `TestAutomationsRun_WatchSinceQueues`.
  - `TestAutomationsRun_ReactionsRefused`.
  - `TestAutomationsShow_WatchBlock`.
  - Unchanged guards: `TestOwner02_UserTriggeredCommandsFailWithoutOwner`, `cmd/features_test.go` (FEAT-02/03/04) and every `cmd/ideas_test.go` test.
- [ ] **Step 2: Run** `go test ./cmd -run 'Tracks|IdeasMine|ReactionCommandsPoll|AutomationsRun|AutomationsShow|Owner02|Features' -timeout 30m`. Expected: FAIL (new).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same and `make lint-diff`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(cmd): tracks, ideas and reaction CLI paths through the recipes`.

---

### Task 12: The rest of the one-time upgrade step

**Depends on:** Task 6, Task 9, Task 10, Task 11

**Files:**
- Modify: `cmd/builtin_upgrade.go`, `cmd/builtin_upgrade_test.go`, `cmd/builtins.go`, `docs/inventory/automations.md` (the guard list)

**Interfaces:**
- Consumes: C2's `upgradeBuiltins`, which handles every `builtin.All()` entry generically, so the three new entries need no new code there. Its prompt carry follows `PromptRef`. Also consumes `watch.Start` and `db.ListUnboundCustomTracks`.
- Produces:
  - `upgradeBuiltins` also handles the migration id `custom-tracks` with no `done` record. For each unbound, non-dismissed custom track (in created order) it calls `watch.Start(Confirm: true, Now: now)` (the owner's content already running; Collecting/Paused carried through `t.Enabled`). It then records `done`. The first error records `failed` with the error and sets `active["custom-tracks"] = false`. The tracks already bound stay bound, so a Retry continues where it stopped.
  - `automations upgrade-builtins` (C2's Retry command) retries `custom-tracks` too.
  - For each of the three C3 built-ins, a customised prompt-store row for its `PromptID` (role variant first, C2's rule) becomes a confirmed owner copy.
- [ ] **Step 1: Write the failing tests:**
  - `TestCustomTracksUpgrade_EachLiveTrackGetsOneConfirmedRecipe`.
  - `TestCustomTracksUpgrade_PausedStaysPaused`.
  - `TestCustomTracksUpgrade_DismissedStaysUnbound`.
  - `TestCustomTracksUpgrade_EmptyInstructionUsesContextThenTitle`.
  - `TestCustomTracksUpgrade_LinkedTargetKept`.
  - `TestCustomTracksUpgrade_PartialFailureResumesOnRetry`: the third write fails; two are bound, `failed` is recorded, the legacy scan covers the rest, and Retry binds them.
  - `TestCustomTracksUpgrade_IsIdempotent`.
  - `TestBuiltinUpgrade_CustomisedTracksPromptBecomesCopy`.
  - `TestBuiltinUpgrade_CustomisedReactionPromptBecomesCopy`.
  - `TestAuto06_UpgradeConfirmsOnlyRenderedWatchRecipes`: the confirmed hash equals the hash of exactly `watch.Render`'s bytes.
- [ ] **Step 2: Run** `go test ./cmd -run 'CustomTracksUpgrade|BuiltinUpgrade|UpgradeConfirms' -timeout 30m`. Expected: FAIL (new).
- [ ] **Step 3: Implement.** Add the AUTO-06 guard names.
- [ ] **Step 4: Run** the same and `make lint-diff`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(cmd): upgrade custom tracks into watch recipes and the C3 built-ins`.

---

### Task 13: Templates and authoring — `on-reaction`, the watch guide, drafts

**Depends on:** Task 2, Task 6

**Files:**
- Create: `internal/automations/templates/on-reaction.md`
- Modify: `internal/automations/templates/index.json`, `internal/automations/templates_test.go`, `templates_e2e_test.go`, `internal/skills/shipped/create-automation.md` (bump the pack version where the pack requires it), `internal/automations/authoring/draft.go` (+ test)

**Interfaces:**
- Produces:
  - Template `on-reaction`: title "When I react with an emoji", personal scope, `trigger_text` "When you react with :<EMOJI>:", params `[{key: "EMOJI", label: "Emoji short name", example: "eyes"}]`, files `["on-reaction"]`. The recipe uses `trigger: {event: slack.reaction_added, where: {emoji: "<EMOJI>"}}`. Its script lists the message with `tool('list_messages', …)` and puts an Inbox card with the message link. Copy the event field names from `eventsrc_reaction.go`.
  - `create-automation.md` gains a "Watch for something" section:
    - The exact recipe shape: `trigger: {sync: custom_tracks}`, `permissions: [track:scan]`, the `const instruction = …;` line, `track.scan({ instruction })`.
    - How to widen sources: read tools since the watch's last scan, passed as `extra`, at most 40 items.
    - That one recipe watches one thing.
    - That the owner confirms it.
  - `draft_automation` dry-runs a watch recipe with `track.scan` reporting `{"would": "track.scan"}` (AUTO-12, Task 3), and refuses a watch recipe in a workbench scope with Task 2's message.
- [ ] **Step 1: Write the failing tests:**
  - `TestTemplates_OnReactionRendersAndParses`: `EMOJI=eyes` renders and parses; `EMOJI="a b"` is refused by the value allowlist.
  - `TestTemplates_IndexListsEveryFile` (existing, now six templates).
  - `TestDraftAutomation_WatchRecipeDryRuns`.
  - `TestShippedSkills_CreateAutomationHasWatchSection`.
- [ ] **Step 2: Run** `go test ./internal/automations ./internal/automations/authoring ./internal/skills/...`. Expected: FAIL (new).
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same and `make lint-diff`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(automations): on-reaction template and the Watch for something guide`.

---

### Task 14: Swift Core — models, texts, watch controls, notices, sections

**Depends on:** Task 1, Task 11

**Files:**
- Modify: `WatchtowerCore/Models/Track.swift` (`automationID`), `Services/Automations/AutomationTriggerText.swift`, `AutomationCardPresentation.swift`, `AutomationsCLI.swift`, `AutomationNewChoice.swift`, `BuiltinUpgradeNotice.swift` (C2), `BuiltinAutomationCardModel.swift` (C2, parameter kinds)
- Create: `Services/Inbox/WatchTrackControls.swift`, `Services/Inbox/RecipeCustomTrackControls.swift`
- Delete: `Services/Automations/AutomationsSection.swift`, `Tests/Core/AutomationsSectionTests.swift`; this changes no behaviour, and the tests go with the type
- Test: `Tests/Core/WatchTrackControlsTests.swift`, `Tests/Core/CustomTrackControllingTests.swift` (C1, extended), `AutomationTriggerTextTests.swift`, `BuiltinAutomationDetailDecodingTests.swift`, `BuiltinUpgradeNoticeTests.swift`, `AutomationNewChoiceTests.swift`, `TrackQueriesTests.swift`

**Interfaces:**
- Consumes: Task 11's CLI verbs and JSON, Task 7's show goldens, C1's `CustomTrackControlling` / `DirectCustomTrackControls`, and C2's `BuiltinUpgradeNotice.name(for:)` and `BuiltinAutomationDetail.runNow`.
- Produces (Go↔Swift dual paths, each with a doc comment naming its Go twin):
  1. `Track.automationID: Int64?` (twin: `db.Track.AutomationID`), decoded from `tracks.automation_id`.
  2. `AutomationTriggerText`, for each sync slot:
     - `{"sync":"tracks"}`: "After every sync".
     - `{"sync":"ideas"}`: "Every few hours"; the card's `when` line carries the number.
     - `{"sync":"reactions"}`: "When you react in Slack".
     - `{"sync":"custom_tracks"}`: "After every sync".
  3. Permission lines, twin of `CapabilityForPrimitive` and `BuiltinPrimitiveNames`:
     - `builtin:tracks.extract`: "Update your tracks from Slack digests".
     - `builtin:ideas.consolidate`: "Find ideas and decisions in your messages".
     - `builtin:reaction.compose`: "Turn your reactions into proposals".
     - `track:scan`: "Add events to this watch's track".
  4. `BuiltinAutomationDetail.Parameter.Kind` gains `.interval` and `.dictionary` (twin: `builtin.ParamKind`). It decodes C3's three goldens through `#filePath`.
  5. C2's `BuiltinUpgradeNotice.name(for:)` gains these rows (C2's fallback unchanged):
     - `track-my-threads`: "Track my threads".
     - `idea-finder`: "Idea finder".
     - `reactions`: "Reactions".
     - `custom-tracks`: "your watched tracks".
     Any unknown id gives the id itself.
  6. `AutomationStart.watch`. `AutomationNewChoice.starts` returns `[.words, .watch] + templates` for the Personal scope only.
  7. `AutomationsCLI.Op` gains:
     - `.runSince(id, since: Date)` (`automations run <id> --since <iso> --json`).
     - `.trackStart(trackID)` (`tracks start <id> --json`).
     - `.trackInstruction(trackID, text)` (`tracks instruction <id> --text-file <tmp>`).
     - `.showWatch(id)`, which decodes the `watch` block.
  8. `@Observable @MainActor final class WatchTrackControls`: `init(track: Track, cli: AutomationsCLI)`.
     - State: `instructionDraft: String`, `templateShaped: Bool`, `collecting: Bool`, `scanFrom: Date?`, `note: String?` ("Saved", "Runs at the next sync"), `error: String?`, `isWorking: Bool`, `var isBound: Bool`.
     - `init(track: Track, cli: AutomationsCLI, controls: any CustomTrackControlling)`; methods: `func load() async` (`showWatch`), `func saveInstruction() async`, `func setCollecting(_ on: Bool) async`, `func scan() async`, `func startWatching() async` (`trackStart`). `saveInstruction`/`setCollecting`/`scan` call `controls` (C1's seam), never the CLI directly, and it never writes `tracks` columns itself.
  8a. `@MainActor package final class RecipeCustomTrackControls: CustomTrackControlling` — C3's implementation of C1's seam: `init(cli: AutomationsCLI, direct: DirectCustomTrackControls)`. For a bound track (`automationID != nil`): `saveInstruction` → `.trackInstruction(trackID, text)`; `setCollecting` → `.setEnabled(automationID, on)` (`automations enable|disable`); `scan(_:from:)` → `.runSince(automationID, since: from)`; `stopWatching` → `TrackQueries.dismiss` + `.setEnabled(automationID, false)` (never `TrackQueries.setEnabled`; the SQL trigger mirrors it). For an unbound track: `stopWatching` → `direct.stopWatching`; the other three throw (the card shows **Start Watching** instead of the controls).
  9. `TrackScanService` (the `tracks scan` CLI) stays: C1's `DirectCustomTrackControls.scan` uses it, and `RecipeCustomTrackControls` keeps `direct` for unbound tracks. No change to it in C3.
  - Delete `AutomationsSection`. `AppState.navigateToAutomations(section:)` becomes `navigateToAutomations(select: Int64? = nil)` (Task 15 updates the callers).
- [ ] **Step 1: Write the failing tests:**
  - `testSyncSlotTexts`.
  - `testC3PermissionLines`.
  - `testDecodesC3ShowGoldens`.
  - `testNoticeNamesForC3Ids`.
  - `testWatchTileOnlyForPersonal`.
  - `testWatchControlsCallTheCLI`: a fake runner records the exact args for each op.
  - `testSaveInstructionShowsRefusalText`: "This watch was changed in the chat — change it there." is shown, and the draft is kept.
  - `testScanShowsNextSyncNote`.
  - `testUnboundTrackOffersStart`.
  - `testTrackDecodesAutomationID`.
  - `CustomTrackControllingTests.testRecipeControlsDriveTheRecipe`: bound track → the exact CLI args per method, and neither `tracks.enabled` nor `tracks.instruction` written from Swift; unbound `stopWatching` → `DirectCustomTrackControls`. C1's `testDirectControlsWriteTheTrackRow` stays unchanged and passes.
- [ ] **Step 2: Run** `make test-swift FILTER='WatchTrackControlsTests|CustomTrackControllingTests|AutomationTriggerTextTests|BuiltinAutomationDetailDecodingTests|BuiltinUpgradeNoticeTests|AutomationNewChoiceTests|TrackQueriesTests'`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same and `make lint-swift`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(desktop-core): watch controls, C3 built-in texts and notices`.

---

### Task 15: Desktop views — built-in cards, + tile, track card, Automations sections, Settings

**Depends on:** Task 13, Task 14

**Files:**
- Modify: `Views/Automations/BuiltinAutomationCard.swift` (C2: the `interval` and `dictionary` parameter rows), `ReactionDictionaryEditor.swift` (kept, now embedded in the card), `AutomationsView.swift` (no section picker), `AutomationNewPanel.swift` (the `.watch` tile opens the chat with the prefill "Watch for "), `Views/Inbox/InboxTrackPane.swift` and `Views/Tracks/TrackDetailView.swift` / `CustomTrackTimelineView.swift` (C1's custom-track controls now use `WatchTrackControls` when bound), `Views/Inbox/AgentActionCardView.swift` (an approved `create_track` then runs `trackStart`), `Views/Inbox/ReactionCheatSheetView.swift` and `Views/Settings/SlackConnectionDetail.swift` (pointer → the Reactions built-in), `Views/Settings/FeaturesSettings.swift` + `FeatureManagerSection.swift` (Ideas section removed; `tracks`, `ideas`, `reaction-commands` rows hidden), `App/AppState+Home.swift`, `App/AppState+Automations.swift`, `App/AppState.swift` (callers of `navigateToAutomations`; `customTrackControls` becomes `RecipeCustomTrackControls`), `AutomationsView.swift` also drops C1's `tracksVisible` (the one place C1 computes it)
- Delete: `Views/Automations/ReactionsSectionView.swift`, `TracksSectionView.swift`, and the custom-track creation sheet they alone use (`CustomTrackManagementSheet` with `TrackComposeService`, if `rg` shows no other user)
- Test: `Tests/InboxTrackPaneTests.swift` (C1, extended), `Tests/BuiltinAutomationCardViewTests.swift` (C2, extended), `Tests/AutomationNewPanelTests.swift`, `Tests/SidebarAutomationsVisibilityTests.swift`, `Tests/FeatureManagerServiceTests.swift`

**Interfaces:**
- Consumes: C2's built-in card (Run Now hidden on `detail.runNow == false`) and `FeatureManagerService.enableNow/disableNow`; Task 14's types; C1's `InboxTrackPane`, `CustomTrackControlling` seam and `ActionStripViewModel.stopWatching`.
- Produces:
  - Built-in card parameters. An `interval` row is a stepper "Every N hours" (1–24) that writes `config.ideasMineIntervalHours` through `ConfigService`, using C2's parameter Save + daemon restart. A `dictionary` row embeds `ReactionDictionaryEditor` (rows editable, its `+` adds a row) under **When**.
  - The Reactions card has no **Run Now** (C2 hides it: its golden has `run_now: false`). It shows **+ New reaction automation**, which opens the template panel on `on-reaction`.
  - The Automations tab shows one list (Built in, Personal, workbenches). The segmented section picker is gone. `navigateToAutomations(select:)` selects a row, and the Slack pointer and the cheat sheet select the Reactions built-in.
  - Track card, bound custom track:
    - The C1 labels stay: **Collecting**/**Paused**, the instruction editor, **Scan from**.
    - Their actions use `WatchTrackControls` over `RecipeCustomTrackControls` (the C1 seam's swapped implementation, injected by AppState; the pane's control code is unchanged). A not-template-shaped recipe shows the instruction read-only with "This watch was changed in the chat — change it there." and **Edit in Chat** (opens the editor on the recipe).
    - ⋯ **Delete** runs `automations delete <id>` and then C1's track delete.
  - Track card, unbound custom track: the line "Not watched yet." with **Start Watching**.
  - `ActionStripViewModel.stopWatching` is unchanged code: on a custom track it calls the seam, and `RecipeCustomTrackControls.stopWatching` on a bound track dismisses it and runs `automations disable <id>` (no `TrackQueries.setEnabled`).
  - Approving a `create_track` proposal in the Inbox runs `trackStart(result.track_id)` after a successful apply. A failure shows on the card, and the track keeps **Start Watching**.
  - Settings → Features: the `tracks`, `ideas` and `reaction-commands` rows are hidden, and the Ideas tuning section is removed. C2's pointer row covers them.
- [ ] **Step 1: Write the failing tests:**
  - `testIntervalParameterSavesThroughConfig`.
  - `testReactionsCardEmbedsDictionaryAndHasNoRunNow`.
  - `testNewReactionAutomationOpensTemplate`.
  - `testWatchTileOpensChatWithPrefill`.
  - `testBoundTrackControlsUseRecipe`: Collecting flips `automations disable`, and nothing writes `tracks.enabled` from Swift.
  - `testEditedWatchShowsEditInChat`.
  - `testUnboundTrackShowsStartWatching`.
  - `testStopWatchingBoundDisablesRecipe`.
  - `testApprovedCreateTrackStartsWatching`.
  - `testAutomationsHasNoSectionPicker`.
  - `testSettingsHidesC3FeatureRows`.
  - C1's `testCustomTrackControlsOnTheCard` and `testNoSheetOrPopoverModifiers` stay unchanged and pass.
- [ ] **Step 2: Run** `make test-swift FILTER='InboxTrackPaneTests|BuiltinAutomationCardViewTests|AutomationNewPanelTests|SidebarAutomationsVisibilityTests|FeatureManagerServiceTests|ActionStripAllKindsTests'`. Expected: FAIL.
- [ ] **Step 3: Implement** from DesignKit components only. Delete the two section views and their now-unused files after `rg` shows no user.
- [ ] **Step 4: Run** the same filter and `make lint-swift`. Then run `bash scripts/dev-health.sh` and `make desktop-shots DESKTOP_SHOTS=<scratch dir>`. Look at these in light and dark: the three built-in cards (Reactions with the dictionary), the + screen with the Watch tile, a bound and an unbound track card, an edited watch, and Settings → Features. Register the shots `automations-builtin-reactions`, `automations-new-watch`, `inbox-track-card-watch` and `inbox-track-card-unbound` in `DesignShotCatalog.swift` with `acme` fixtures.
- [ ] **Step 5: Commit** `feat(desktop): C3 built-in cards, Watch for something, track card through its recipe`.

---

### Task 16: Docs — feature notes, guide, CLI reference, inventory sweep

**Depends on:** Task 11, Task 12, Task 15

**Files:**
- Modify:
  - `docs/features/built-in-automations.md` (C2's note: append a "C3" section after C2's "How C3 plugs in", following its steps in order; C2's sections are not rewritten).
  - `docs/features/automations.md` (the Reactions/Tracks sections gone; watch recipes).
  - `docs/features/reaction-commands.md`, `docs/features/ideas-decisions-registry.md`.
  - The tracks part of `docs/features/attention-detection.md`, if it names `phaseCustomTrackScan`.
  - `CLAUDE.md` Feature Notes (the Automations and built-in entries: one line each, naming C3).
  - The guide: `docs/guide/features/tracks.md`, `ideas-and-decisions.md`, `reaction-commands.md` (or the page that covers reactions), `automations.md`, `reference/cli.md` (`tracks start|instruction`, `automations run --since`), `reference/settings.md`, `concepts/features-on-and-off.md`.
  - `docs/inventory/README.md` (module paths for deleted files).
- Test: `go test ./docs/guide ./internal/kb ./internal/chat`

- [ ] **Step 1: Write the feature-note section.** Cover:
  - The three entries and their slots.
  - Primitive contracts and seams.
  - Gates (`HasMaterial`, throttle + lock probe, the per-row Reactions run).
  - The watch recipe shape, binding, triggers and slot.
  - CLI paths and the capture rule.
  - Upgrade (`custom-tracks`).
  - Dual paths: Task 14's list plus the two SQL triggers.
  - v1 limits: legacy phases kept until the release after C3; dismissed custom tracks unbound; `ideas mine --from` writes no run row.
- [ ] **Step 2: Update the guide pages** per `docs/guide/WRITING.md`. Use user words and check every label against the Swift source. Each page must stay under 8 192 bytes (`wc -c`). The pages must cover:
  - Creating a watch from Automations → **+** → **Watch for something**.
  - Collecting/Paused, **Scan from** and "Runs at the next sync".
  - The Reactions card with its dictionary.
  - **+ New reaction automation**.
  - Where the switches went.
  - C1's text "New track still in Automations → Tracks" is replaced.
- [ ] **Step 3: Run** `go test ./docs/guide ./internal/kb ./internal/chat`. Expected: PASS. Then run `rg -n 'Automations → (Reactions|Tracks)' docs WatchtowerDesktop/Sources`, which must return only changelog history.
- [ ] **Step 4: Commit** `docs: tracks, ideas and reactions as built-ins; Watch for something`.

---

### Task 17: Phase gate and owner review

**Depends on:** Task 1–Task 16

- [ ] **Step 1:** Run `bash scripts/dev-health.sh`. Expected: not `HEALTH: overloaded`.
- [ ] **Step 2:** Run `make test` (including `go test ./cmd/... -timeout 30m`), `make test-swift` and `make lint-all`. All must be green. Then run `go test -race ./internal/automations/... ./internal/daemon ./internal/reactioncmd -run 'Builtin|WatchSlot|TrackMyThreads|IdeaFinder|ReactionsBuiltin'`.
- [ ] **Step 3:** Re-read `docs/inventory/{tracks,ideas,reaction-commands,features,automations}.md`. Every guard listed must exist by name and pass. `git diff origin/main -- '*_test.go'` must show no deleted or relaxed assertion in a `TestTracks*`, `TestIdeas*`, `TestReactionCmd*`, `TestFeatureGates*`, `TestFastForward*`, `TestAuto*`, `TestOwner02*` or `test_TRACKS_*` test.
- [ ] **Step 4:** Run a manual check on a scratch workspace, never the live DB. Start from a pre-C3 copy of a workspace with two custom tracks (one paused, one dismissed) and a customised `reactioncmd.command` prompt row, then upgrade. Expected after the upgrade:
  - One confirmed watch recipe exists and the paused track is still paused.
  - The dismissed track is unbound.
  - The Reactions built-in has a confirmed owner copy, and a 👀 reaction proposes `create_track`. Approving it binds a watch.
  - **Scan from** a week ago runs at the next sync.
  - Editing the watch recipe by hand stops it.
  - A Reset of Idea finder works.
  - Turning off Track my threads stops watches too (the FEAT-01 ruling).
  - A failed upgrade (read-only `automations/`) shows the Inbox notice, and **Retry** recovers.
- [ ] **Step 5:** Run the `local-review` skill on the branch and fix the accepted findings. Then open the PR and send the owner an `ask_owner` (in Russian) with the shots from Task 15. Ask for a decision on the rulings marked **(owner check)** below and the inventory wording changes (AUTO-06 sentence, FEAT-01 list, REACT-03 note). Merge only after the owner's answer.

---

## Rulings on spec ambiguities

- **Instruction is recipe text.** A watch's instruction is the literal on the recipe's `const instruction = "<JSON>";` line. The track row's `instruction` column mirrors it on every scan. The card's inline **Save** rewrites only that line (`tracks instruction`), and the owner's press is the confirmation. A watch edited into another shape is changed only in the chat.
- **`since` comes from Go.** Spec §6.3 writes `track.scan({instruction, since})`. `since` comes only from Run Now's **Scan from** (the run input), never from the script. This is C2's date ruling: a recipe cannot aim a backfill at every cycle.
- **Forward dedup is kept.** The spec says the summary dedup is "only for a backfill". Today's code also dedups forward runs, so that a cap-hit window overlap does not duplicate events. `ScanBound` keeps today's behaviour; only the two-stage shortlist is backfill-only.
- **"Made from the tile" is a recipe shape.** It means a Personal recipe with `track:scan` and `trigger: {sync: custom_tracks}`, the two required together. A hand-written recipe of that shape is equivalent, and it is owner-confirmed like any Personal recipe.
- **Watches stop with Track my threads (owner check).** The watch slot keeps today's gate `tracks.enabled && digest.enabled` (FEAT-01: the Tracks feature off means zero AI calls). Turning off Track my threads therefore also stops the watches.
- **Collecting/Paused is the recipe's `enabled`.** `tracks.enabled` is mirrored by a SQL trigger, so the briefing, MCP and Swift readers stay honest. Auto-disable after repeated failures pauses the track too.
- **A reaction-made track is watched after approval (owner check).** `create_track` (👀, chat, automations) still creates only the track row; the tools layer cannot confirm a recipe. The owner's approve press in the Inbox then runs `tracks start`. A track applied with no press (trust `execute`, or a CLI approve) shows "Not watched yet." with **Start Watching**.
- **The binding lives on the track.** It is `tracks.automation_id`, with no SQL foreign key so the down migration stays a `DROP COLUMN`. An `AFTER DELETE` trigger unbinds and pauses the track.
- **Track my threads is due only with material.** That means new digests since the last tracks run, or owed retry digests, so a quiet cycle writes neither an `automation_runs` nor a `pipeline_runs` row (today it writes an empty `tracks` row). `TrackContext` injection for rollups stays in the phase and runs even when extraction is not due.
- **The ideas gate probes the lock.** It is ideas on, plus the throttle, plus the `BackfillLockFresh` probe. The primitive itself takes the lock, and losing that race makes the run `skipped`. The throttle stamp keeps today's "advance whenever it ran" rule.
- **Reactions: one run per claimed row.** Each claimed row gets its own `sync` run. The `Outcome` returns to the Go pass through `ReactionSlot`. An unconfirmed owner copy pauses claiming (polling and events continue), and those reactions fire once after confirmation, capped at 25. A run that never composed finalizes `failed`. The Reactions card has no Run Now.
- **`ideas mine --from` captures the prompt, then drains in Go.** It takes the prompt from the current recipe by an in-memory dry-run capture and runs today's multi-cycle drain. It writes no `automation_runs` row, so a long backfill is never cut by a per-run token budget.
- **Custom-track system prompts stay in Go.** `customtrack.run`, `customtrack.shortlist` and `customtrack.compose` stay Go prompts (prompt store). A watch's owner-editable text is its instruction.
- **`tracks enable|disable <id>` toggles that track's watch recipe.** The spec's "toggle the built-in" is read as the track's own recipe. The Track my threads built-in is toggled with `features enable|disable tracks` or its card.
- **Dismissed custom tracks are not migrated.** They scan nothing today. `tracks restore` of one prints the `tracks start` hint.
- **Partial custom-track migration falls back per track.** While `custom-tracks` is not `done`, the legacy `phaseCustomTrackScan` scans only unbound tracks, and bound ones run as recipes. Nothing is scanned twice.
- **"New reaction automation" is a gallery template.** It is `on-reaction`, with an `EMOJI` param that passes the existing value allowlist.
- **The slot executor gets the main executor's Backends.** C2 already builds it from `automationBackends(...)` plus `BuiltinPrimitives()`, so watch recipes can widen their sources through existing read tools; C3 only extends `BuiltinPrimitives()`.
- **Inbox notice names.** "your watched tracks" names the `custom-tracks` migration in C2's notice.
