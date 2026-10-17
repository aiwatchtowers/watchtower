# Agent Instructions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Owner-written session instructions in every workbench brief, a target procedure returned when a target goes `in_progress`, and daily suggestions mined from what the owner keeps repeating in Claude Code and Codex sessions.

**Architecture:** Four texts (global/workbench × session/procedure) stored in SQLite and rendered by one Go package `internal/instructions`; the brief (`cmd/workbench_brief.go`, shared by Claude and Codex) gets a reserved slot and `update_target` an additive `procedure` key. A daily daemon phase reads owner entries from `internal/sessionfeed` (which gains a Codex rollout reader), asks a light-tier model for repeated directions, validates them in Go and upserts `instruction_suggestions`. Desktop reads and writes everything through a new `watchtower instructions … --json` CLI.

**Tech Stack:** Go 1.26 (`database/sql` + modernc sqlite, goose, cobra), SwiftUI + GRDB (WatchtowerCore), `digest.Generator` light tier.

**Spec:** `docs/superpowers/specs/2026-10-17-agent-instructions-design.md` (board target #614, branch `feature/agent-instructions`).

## Global Constraints

- Each of the four texts: at most **1000 runes**; a suggestion line at most **200 runes**.
- Brief slot header lines, verbatim: `Owner's instructions (follow in every turn):`, `For this workbench:`; procedure-pointer line: `Target procedure: update_target returns it when a target goes in_progress.`
- Procedure text first line, verbatim: `Owner's target procedure — follow it for #<id>:`; workbench part under `For this workbench:`.
- Mining: once a day, last **14 days**, a direction must appear in **≥ 3 distinct sessions**, at most **5 open** suggestions shown per field and scope, Home card only for suggestions first seen in the last **7 days**.
- The model only proposes; only the owner's Add/Dismiss (CLI) changes text or suggestion status. A dismissed suggestion never reopens.
- Owner transcript text goes to the model over stdin, never argv (CHAT-04, `SetStdinOnly(true)`).
- Nothing reaches the phone slice; nothing is written into the workbench folder.
- Public repo hygiene: neutral sample texts in tests and fixtures.
- Inner loop per task (CLAUDE.md "Agent-driven runs"); Swift tasks also run `make lint-swift` (lint-diff is Go-only).

## Review Focus

- **Text at exactly 1000 runes of multi-byte Cyrillic** — the limit counts runes, not bytes; 1000 Cyrillic runes saves, 1001 is refused (Task 2 test).
- **Add when the target text is near its limit** — Add is refused with a clear error and the suggestion stays `open` (Task 5 test).
- **A full board plus maximal instructions** — the slot is never cut and answered asks still survive (`TestProj12_AnsweredAskSurvivesAFullBoard` unchanged + Task 3 test).
- **Model returns a session id it was not given, or fewer than 3 real sessions** — dropped in Go, nothing written (Task 7 test).
- **Re-mined direction that was dismissed (different case/punctuation)** — matches by fingerprint and stays dismissed (Task 1 + Task 7 tests).

---

### Task 1: Schema and DB accessors

**Depends on:** none

**Files:**
- Create: `internal/db/migrations/00131_agent_instructions.sql`, `internal/db/instructions.go`, `internal/db/instructions_test.go`
- Modify: `internal/db/schema.sql`, `internal/db/db_test.go` (`TestAllTablesExist`), schema golden + `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (regenerate: `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`)

Use the `add-migration` skill.

**Interfaces — Produces:**
```go
type InstructionField string // "session" | "procedure"
const (InstructionSession InstructionField = "session"; InstructionProcedure InstructionField = "procedure")
type OwnerInstructions struct{ Session, Procedure string }
func (d *DB) GetOwnerInstructions() (OwnerInstructions, error)               // missing rows → ""
func (d *DB) SetOwnerInstruction(f InstructionField, body string) error      // "" deletes the row
func (d *DB) GetWorkbenchInstructions(id int64) (OwnerInstructions, error)   // projects.session_instructions / target_procedure, NULL → ""
func (d *DB) SetWorkbenchInstruction(id int64, f InstructionField, body string) error // "" → NULL
type InstructionSuggestion struct {
    ID int64; Text string; Field InstructionField; WorkbenchID sql.NullInt64
    SessionCount, WorkbenchCount int; FirstSeenAt, LastSeenAt, Status, Fingerprint string
}
func (d *DB) UpsertInstructionSuggestion(s InstructionSuggestion, now time.Time) error
func (d *DB) ListOpenInstructionSuggestions() ([]InstructionSuggestion, error) // newest first_seen_at first
func (d *DB) ListInstructionSuggestionFingerprints() (map[string]string, error) // fingerprint → status, all statuses
func (d *DB) GetInstructionSuggestion(id int64) (InstructionSuggestion, error)
func (d *DB) DecideInstructionSuggestion(id int64, status string, now time.Time) error // "added" | "dismissed"; only from "open"
func (d *DB) AddInstructionSuggestion(id int64, newBody string, now time.Time) error // one tx: write newBody to the row's field/scope (global or workbench) + mark added; error if not open
```
Schema as in the spec's Storage section (`owner_instructions`, two `projects` columns, `instruction_suggestions` with `fingerprint UNIQUE` and status CHECK). Upsert on conflict(fingerprint): only an `open` row is refreshed (`text`, counts, `last_seen_at`); `added`/`dismissed` rows are untouched.

- [ ] **Step 1: Write failing tests** — `TestOwnerInstructions_RoundTripAndClear`, `TestWorkbenchInstructions_RoundTripNullWhenEmpty`, `TestInstructionSuggestion_UpsertRefreshesOpenOnly` (dismissed row with the same fingerprint keeps `status="dismissed"` and its old counts), `TestInstructionSuggestion_DecideOnlyFromOpen` (deciding an `added` row returns an error), `TestAddInstructionSuggestion_WritesTextAndMarksAtomically` (global and workbench scope).
- [ ] **Step 2: Run** `go test ./internal/db -run 'Instruction'` — FAIL (undefined).
- [ ] **Step 3: Write the migration, schema.sql mirror and accessors.**
- [ ] **Step 4: Regenerate golden/Swift schema, add tables to `TestAllTablesExist`; run** `go test ./internal/db` — PASS.
- [ ] **Step 5: Commit** `feat(db): owner instructions and suggestion tables`.

### Task 2: `internal/instructions` — limits and rendering

**Depends on:** Task 1

**Files:** Create `internal/instructions/instructions.go`, `internal/instructions/instructions_test.go`

**Interfaces — Produces:**
```go
const MaxRunes = 1000
const MaxSuggestionRunes = 200
var ErrTooLong = errors.New("…")                // message names the field and the limit
type Texts struct{ Global, Workbench db.OwnerInstructions }
func Load(d *db.DB, workbenchID int64) (Texts, error)
func Validate(body string) error               // utf8.RuneCountInString(strings.TrimSpace(body)) > MaxRunes → ErrTooLong
func BriefSlot(t Texts) string                 // "" when both session texts and both procedures are empty
const SlotMaxRunes = /* header + 1000 + "\n" + workbench header + 1000 + "\n" + pointer line */
func Procedure(t Texts, targetID int64) string // "" when both procedure texts are empty
func AppendLine(existing, line string) (string, error) // existing + "\n" + line (no leading newline when empty); ErrTooLong when over MaxRunes
func Fingerprint(s string) string              // lower-case, letters/digits only, runs of other chars → one space, trimmed
```
`BriefSlot` = header + global session + (`For this workbench:` + workbench session, only when non-empty), then the pointer line when either procedure text is non-empty; the session block is omitted when both session texts are empty but a procedure exists.

- [ ] **Step 1: Failing tests** — `TestValidate_CountsRunesNotBytes` (1000 × "ж" ok, 1001 → `ErrTooLong`), `TestBriefSlot_Shapes` (table: all empty → ""; global only → no workbench header; workbench only → header + `For this workbench:`; procedure only → pointer line only), `TestBriefSlot_MaxFitsSlotMaxRunes`, `TestProcedure_FirstLineAndWorkbenchPart` (exact strings from Global Constraints), `TestAppendLine_RefusesOverLimit`, `TestFingerprint_IgnoresCaseAndPunctuation` (`"Never build in the background!"` == `"never build, in the background"`).
- [ ] **Step 2: Run** `go test ./internal/instructions` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(instructions): limits, brief slot and procedure rendering`.

### Task 3: Brief slot

**Depends on:** Task 2

**Files:** Modify `cmd/workbench_brief.go` (`briefFromDB` :189, `renderSessionBrief` :344, `renderWorkbenchBrief` :335, `briefMaxChars` :33); Test `cmd/workbench_brief_instructions_test.go`

**Interfaces — Consumes:** `instructions.Load`, `instructions.BriefSlot`, `instructions.SlotMaxRunes`.
- `renderSessionBrief(..., boardRules []string, method, cleanup, owner string) string` — `owner` is appended to `rules` right after `method` (before `cleanup`), so it is reserved before the board is fitted.
- `briefMaxChars = 4000 + instructions.SlotMaxRunes`. A failed `instructions.Load` logs and renders no slot (brief must never fail).
- Update every existing caller (`renderWorkbenchBrief` passes `""`; tests in `workbench_brief_method_test.go` :34/:90).

- [ ] **Step 1: Failing tests** — `TestProj22_BriefCarriesOwnerInstructions` (DB with global + workbench session texts → brief contains the exact header lines and both texts in order), `TestProj22_BriefOmitsSlotWhenEmpty`, `TestProj22_FullBoardKeepsWholeSlot` (300-target board + both texts at 1000 runes → slot present verbatim and total ≤ `briefMaxChars`), `TestProj22_CodexBriefCarriesSlot` (via `runCodexBriefHook`, `cmd/workbench_codex_hooks_test.go:84`).
- [ ] **Step 2: Run** `go test ./cmd -run 'TestProj22_|TestRenderProjectBrief|TestProj12_|TestProj07_'` — new ones FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the same command** — all PASS, existing guards unchanged.
- [ ] **Step 5: Commit** `feat(workbench): owner instructions slot in the session brief`.

### Task 4: `procedure` on `update_target`

**Depends on:** Task 2

**Files:** Modify `internal/tools/workbench_targets.go` (`NewUpdateTarget` Execute :273); Test `internal/tools/workbench_targets_procedure_test.go`

In Execute, after `applyTargetUpdate` succeeds: when `a.Status == "in_progress"`, or `a.Column != nil` and the target's stored status after the update is `in_progress`, set `out["procedure"] = instructions.Procedure(texts, a.TargetID)` if non-empty (`instructions.Load(d, call.Binding.WorkbenchID)`; a load error logs and omits the key — never fails the call).

- [ ] **Step 1: Failing tests** — `TestProj22_UpdateTargetInProgressReturnsProcedure` (exact text), `TestProj22_UpdateTargetAlreadyInProgressStillReturns`, `TestProj22_OtherStatusNoProcedure` (`done`, and a progress-only call), `TestProj22_ColumnIntoInProgressReturnsProcedure` (pattern of `TestUpdateTarget_ColumnSetsStatusAndColumn`), `TestProj22_NoTextsNoKey`.
- [ ] **Step 2: Run** `go test ./internal/tools -run 'TestProj22_|TestUpdateTarget'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(tools): update_target returns the owner's target procedure`.

### Task 5: `watchtower instructions` CLI

**Depends on:** Task 2

**Files:** Create `cmd/instructions.go`, `cmd/instructions_test.go`

Commands (all accept `--json`; errors as `{"ok":false,"error":"…"}` with a non-zero exit):
- `instructions show [--workbench N]`
- `instructions set --field session|procedure [--workbench N] --stdin` (body from stdin; empty clears; `instructions.Validate`)
- `instructions preview [--workbench N]` → `{"ok":true,"brief_slot":"…","procedure":"…"}` (procedure rendered for target id `0` shown as `#N`: use `instructions.Procedure` then replace `#0` with `#N`)
- `instructions suggestion add|dismiss <id>` — add: `AppendLine` onto the current text of the field/scope the suggestion names, then `db.AddInstructionSuggestion(id, newBody, now)` (one transaction); over limit → error, suggestion stays open.

Pinned `show`/`set`/`suggestion` JSON (Swift decodes it; keep keys exactly):
```json
{"ok":true,"limit":1000,
 "global":{"session":"","procedure":""},
 "workbench":{"id":1,"session":"","procedure":""},
 "suggestions":[{"id":3,"text":"","field":"session","workbench_id":null,
   "session_count":4,"workbench_count":1,"first_seen_at":"RFC3339","last_seen_at":"RFC3339"}]}
```
`workbench` is `null` without `--workbench`. `suggestions` = open ones, at most 5 per (field, workbench_id), newest first.

- [ ] **Step 1: Failing tests** — `TestInstructionsShow_PinnedKeys` (unmarshal into `map[string]any`, assert the key sets above), `TestInstructionsSet_StdinAndLimit` (1001 Cyrillic runes → exit error, stored text unchanged), `TestInstructionsSuggestionAdd_AppendsAndMarks`, `TestInstructionsSuggestionAdd_OverLimitKeepsOpen`, `TestInstructionsSuggestion_CapsFivePerScope`, `TestInstructionsPreview_MatchesBriefSlot`.
- [ ] **Step 2: Run** `go test ./cmd -run 'TestInstructions'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(cmd): instructions show/set/preview/suggestion`.

### Task 6: Codex reader in `sessionfeed`

**Depends on:** none

**Files:** Create `internal/sessionfeed/codex.go`, `internal/sessionfeed/codex_test.go` (+ fixtures in `testdata/codex/`); Modify `cmd/workbench_session_feed.go` (`requireClaudeSession` :145-155, `sessionFeedConversations` :190-211), `cmd/workbench_session_feed_test.go:186`; Docs: `docs/features/session-chat-feed.md` (v1 limits), `docs/inventory/session-feed.md` (FEED-01..03 cover Codex; changelog line)

**Interfaces — Produces:**
```go
func ParseCodex(r io.Reader, startOffset int64, conv string) (*Result, error) // same Result/Entry kinds as Parse
func LocateCodex(codexHome, sessionID, storedPath string) (string, bool)        // stored path first, else $CODEX_HOME/sessions/*/*/*/rollout-*-<id>.jsonl
```
Borrow the two owner-message dialects and the zstd skip from `internal/terminal/codex_rollout.go` (`event_msg` paginated `item_completed UserMessage` and legacy `user_message`); classify user text with the existing `classifyUserText` (parse.go:204) so briefs, ask answers and Watchtower lines are told apart exactly as for Claude; agent text from the assistant message events. `requireClaudeSession` goes; `sessionFeedConversations` picks `ParseCodex`/`LocateCodex` (with `defaultTerminalCodexHome()`) for `kind='codex'`.

- [ ] **Step 1: Failing tests** — `TestParseCodex_OwnerAgentBriefAskAnswer` (fixture with each dialect), `TestParseCodex_SkipsZstd`, `TestParseCodex_OffsetResume`, `TestFeed01_CodexReaderLeavesTranscriptUntouched`; change the `:186` refusal test into `TestSessionFeed_CodexSessionReturnsEntries`.
- [ ] **Step 2: Run** `go test ./internal/sessionfeed ./cmd -run 'Codex|TestFeed|TestSessionFeed'` — FAIL.
- [ ] **Step 3: Implement + docs.**
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(sessionfeed): read Codex rollouts`.

### Task 7: Suggestion miner

**Depends on:** Tasks 1, 2, 6

**Files:** Create `internal/instructions/suggest.go`, `internal/instructions/suggest_test.go`, `internal/db/terminal_sessions_recent.go` (+ test); Modify `internal/prompts/store.go` (prompt id `InstructionSuggestions`) + its default prompt file, `internal/digest/models.go` (`TierForSource`: `"instructions.suggest"` → `TierLight`)

Use the `add-ai-prompt` skill (must work on claude and codex providers).

**Interfaces:**
```go
// db
type RecentWorkbenchSession struct{ ID, WorkbenchID int64; Kind, FolderPath, AgentSessionID, TranscriptPath string }
func (d *DB) ListWorkbenchTerminalSessionsSince(since time.Time) ([]RecentWorkbenchSession, error) // project_id NOT NULL AND last_active_at >= since
// instructions
type OwnerLine struct{ SessionID, WorkbenchID int64; Text string }
type FeedReader func(s db.RecentWorkbenchSession) ([]sessionfeed.Entry, error) // test seam; prod uses Parse/ParseCodex + Locate*
type Miner struct{ DB *db.DB; Gen digest.Generator; Read FeedReader; Now func() time.Time }
func (m *Miner) Run(ctx context.Context) (written int, usage *digest.Usage, err error)
```
Run: sessions of the last 14 days → owner entries only (`KindOwner`), each truncated to 500 runes, entries with a fenced code block or more than 15 lines skipped → if fewer than 3 sessions have lines, return 0 without a model call. User message (stdin) = sessions labelled `s<id>` with their lines, the four current texts, and the open + dismissed suggestion texts; `digest.WithSource(ctx, "instructions.suggest")`. Model JSON: `{"suggestions":[{"text":"…","field":"session|procedure","sessions":["s12","s40","s41"]}]}`. Go validation per spec step 3 (unknown session labels dropped, distinct ≥ 3, text ≤ 200 runes, field valid, scope = the single workbench when all sessions share it else NULL, `workbench_count` = distinct workbenches), then `UpsertInstructionSuggestion` with `Fingerprint`. A model or parse error writes nothing and returns the error.

- [ ] **Step 1: Failing tests** (fake `Gen` and `Read`) — `TestMiner_WritesValidatedSuggestion`, `TestMiner_DropsUnknownSessionsAndUnderThree`, `TestMiner_ScopeOneWorkbenchVsGlobal`, `TestMiner_DismissedFingerprintStaysDismissed`, `TestMiner_NoModelCallUnderThreeSessions`, `TestMiner_ModelErrorWritesNothing`, `TestListWorkbenchTerminalSessionsSince`; `TestTierForSource_EveryGenerateCallIsTagged` stays green.
- [ ] **Step 2: Run** `go test ./internal/instructions ./internal/db ./internal/digest -run 'Miner|SessionsSince|TierForSource'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(instructions): mine repeated owner directions`.

### Task 8: Daemon phase

**Depends on:** Task 7

**Files:** Create `internal/daemon/instruction_suggestions.go`, `internal/daemon/instruction_suggestions_test.go`; Modify `internal/daemon/daemon.go` (Daemon field `lastInstructionSuggestions time.Time`, load at startup next to `loadLastIdeas`, call in `runSync` after `phaseHistoryBackfill` :565)

`func (d *Daemon) phaseInstructionSuggestions(ctx context.Context)`: skip when `sameCalendarDay(d.lastInstructionSuggestions, now)`; skip (log) when `planusage.NearLimit(st)` (pattern history_backfill.go:213-221); run inside `d.trackedPipelineRun("instruction-suggestions", …)` with a stdin-only light-tier generator; save the stamp `last_instruction_suggestions.txt` only after a run that returned without error (a failed run retries next cycle-day per spec: stamp written on success and on "nothing to do").

- [ ] **Step 1: Failing tests** — `TestPhaseInstructionSuggestions_OncePerDay`, `TestPhaseInstructionSuggestions_SkipsNearLimit`, `TestPhaseInstructionSuggestions_ErrorDoesNotStamp`, `TestPhaseInstructionSuggestions_GeneratorIsStdinOnly` (owner text never on argv, per the `terminalTitleGeneratorFactory` pattern).
- [ ] **Step 2: Run** `go test ./internal/daemon -run InstructionSuggestions` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(daemon): daily instruction suggestions phase`.

### Task 9: Desktop — model, CLI client, Settings section

**Depends on:** Task 5

**Files:** Create `WatchtowerDesktop/Sources/WatchtowerCore/Models/OwnerInstructions.swift`, `WatchtowerDesktop/Sources/Views/Settings/InstructionsSettingsSection.swift`, `WatchtowerDesktop/Sources/Views/Workbench/InstructionsPreviewSheet.swift`, `WatchtowerDesktop/Tests/Core/OwnerInstructionsStateTests.swift`; Modify `WatchtowerDesktop/Sources/Services/WorkbenchCLI.swift` (beside `methodologyCall` :732), `WatchtowerDesktop/Sources/Views/Settings/SystemSettings.swift` (`workbenchSection` :40)

Use the `add-desktop-feature` skill and the Swift conventions in `docs/review/review-rules.md`.

**Interfaces — Produces:**
```swift
struct OwnerInstructionsState: Decodable, Equatable { let limit: Int; let global: Texts; let workbench: WorkbenchTexts?; let suggestions: [InstructionSuggestion] }
struct InstructionSuggestion: Decodable, Equatable, Identifiable { let id: Int64; let text: String; let field: InstructionField; let workbenchID: Int64?; let sessionCount, workbenchCount: Int; let firstSeenAt, lastSeenAt: Date }
enum InstructionField: String, Decodable { case session, procedure }
// WorkbenchCLI
func instructions(workbenchID: Int64?) async throws -> OwnerInstructionsState
func setInstruction(field: InstructionField, workbenchID: Int64?, body: String) async throws -> OwnerInstructionsState // body over stdin
func decideSuggestion(id: Int64, add: Bool) async throws -> OwnerInstructionsState
func instructionsPreview(workbenchID: Int64?) async throws -> (briefSlot: String, procedure: String)
```
`CLIRunnerProtocol` has no stdin today: add `run(args:stdin:)` with a default that the existing `run(args:)` forwards to (body must not go on argv). Settings section: two `TextEditor`s with rune counters (`n / limit`), a **Save** button per field enabled when dirty, an inline error on refusal, the yellow suggestions block (global-scope suggestions under the matching field; workbench-scope ones labelled "only <workbench> → adds to that workbench"), **Preview what the agent gets…** opening `InstructionsPreviewSheet`.

- [ ] **Step 1: Failing tests** — `testDecodesPinnedShowJSON` (fixture = Task 5's JSON), `testWorkbenchNullDecodes`, `testRuneCounterCountsCharacters` (Cyrillic).
- [ ] **Step 2: Run** `make test-swift FILTER=OwnerInstructionsStateTests` — FAIL.
- [ ] **Step 3: Implement model, CLI methods, views.**
- [ ] **Step 4: Run** the same + `make lint-swift` — PASS.
- [ ] **Step 5: Commit** `feat(desktop): owner instructions in Settings`.

### Task 10: Desktop — Agent Settings section

**Depends on:** Task 9

**Files:** Modify `WatchtowerDesktop/Sources/Views/Workbench/AgentSettingsSheet.swift` (between the pickers and the Divider/`fileRow`), `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel.swift` (beside `loadMethodology` :1076: `instructions: [Int64: OwnerInstructionsState]`, `loadInstructions(_:)`, `saveInstruction(_:field:body:)`, `decideSuggestion(_:id:add:)`); Test `WatchtowerDesktop/Tests/WorkbenchInstructionsViewModelTests.swift`

Section "Your instructions — this workbench": per field the global text in grey (first 2 lines, **Edit in Settings** opens Settings → System), the workbench `TextEditor` + counter + Save, this workbench's suggestions; the `workflow.md` row relabelled "Folder rules: .watchtower/workflow.md (team, committed)". A **Preview what the agent gets…** link opens Task 9's `InstructionsPreviewSheet` with this workbench id. Widen the sheet as needed (currently 460).

- [ ] **Step 1: Failing tests** — `testLoadStoresStatePerWorkbench`, `testSaveRefusalKeepsDraftAndShowsError` (fake runner returning `{"ok":false,…}`).
- [ ] **Step 2: Run** `make test-swift FILTER=WorkbenchInstructionsViewModelTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** + `make lint-swift` — PASS.
- [ ] **Step 5: Commit** `feat(desktop): workbench instructions in Agent Settings`.

### Task 11: Desktop — Home suggestion card

**Depends on:** Task 9

**Files:** Modify `WatchtowerDesktop/Sources/WatchtowerCore/Models/Home.swift` (`TodayCardKind` :87 + `.instructionSuggestion`, `HomeTodayData` :161 field), `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/HomeQueries.swift` (`readCard` of the newest open suggestion with `first_seen_at` within 7 days), `WatchtowerDesktop/Sources/WatchtowerCore/Services/HomeTodayBuilder.swift` (builder + order), `WatchtowerDesktop/Sources/Services/HomeCenter.swift` (observe `instruction_suggestions`), `WatchtowerDesktop/Sources/Views/Home/TodayCardView.swift` (Add / Dismiss / More… → `WorkbenchCLI.decideSuggestion`, More… opens Settings at the field); Tests `Tests/Core/HomeTodayTests.swift`, `Tests/Core/HomeQueriesTests.swift`

Card copy: `You keep telling agents: “<text>” — add to your instructions?`

- [ ] **Step 1: Failing tests** — `testInstructionSuggestionCardShowsNewest`, `testInstructionSuggestionCardHiddenAfterSevenDays`, `testInstructionSuggestionCardHiddenWhenDecided`, and `testFixedOrder` updated for the new kind.
- [ ] **Step 2: Run** `make test-swift FILTER='HomeTodayTests|HomeQueriesTests'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** + `make lint-swift` — PASS.
- [ ] **Step 5: Commit** `feat(desktop): Home card for instruction suggestions`.

### Task 12: Docs, inventory, guide

**Depends on:** Tasks 3–11

**Files:** Create `docs/features/agent-instructions.md`, `docs/guide/features/workbench/instructions.md`; Modify `CLAUDE.md` (Feature Notes link), `docs/inventory/workbench.md` (new `## PROJ-22 — …` after PROJ-21 :1918, guard tests = every `TestProj22_*`), `docs/inventory/dev-surface.md` (DEV-06 :278 amendment: additive `procedure` key), `docs/guide/features/workbench/README.md`, `docs/guide/features/workbench/methodology.md` (Related link; folder rules vs your instructions), `docs/guide/reference/settings.md:42`

Follow `docs/guide/WRITING.md`.

- [ ] **Step 1: Write the docs.**
- [ ] **Step 2: Run** `go test ./internal/userguide` (guide index) — PASS.
- [ ] **Step 3: Commit** `docs: agent instructions feature note, PROJ-22, guide page`.

### Phase gate (controller, once)

- [ ] `bash scripts/dev-health.sh`, then `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...` — all green; then `local-review` before the PR into `main`.
