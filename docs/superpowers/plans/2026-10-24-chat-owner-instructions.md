# Owner Instructions in Every AI Chat — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The owner's instructions reach every AI chat; `запомни:` / `remember:` in a chat keeps a rule verbatim with Undo; the daily miner also learns from chats; everything is edited in Settings → Profile → Instructions.

**Architecture:** One new global text (`owner_instructions` scope `chat`) plus today's global session text form a chat slot rendered by Go (`instructions.ChatSlot`). The main chat gets it in `chat.BuildSystemPrompt`; every Swift-built chat gets it by passing `--owner-instructions` to `ai query`, which appends the slot to the system prompt in Go — no Swift copy of the format. A remember line is detected in Swift on send (parser pinned to Go by a shared fixture) and written through a new `watchtower instructions remember` subcommand that also records a ledger row (`instruction_chat_lines`) for provenance, the in-chat mark and Undo.

**Tech Stack:** Go 1.26 (cobra, goose, SQLCipher `database/sql`), SwiftUI + GRDB (WatchtowerCore / WatchtowerDesktop).

**Spec:** `docs/superpowers/specs/2026-10-23-chat-owner-instructions-design.md` (approved, ask #522, including the PROJ-22 amendment).

## Global Constraints

- `instructions.MaxRunes` = 1000 per text (surrounding space not counted); every append is refused over it — never redirected to another text.
- Text reaches the CLI on stdin only, never argv (PROJ-22 (3), CHAT-04). `--owner-instructions` is a bare flag; it carries no content.
- The model never writes instruction text: only the remember prefix (verbatim owner words) and the owner's Add/Settings write.
- Prefixes, case-insensitive, at the first non-space character: `запомни:`, `remember:`, `remember this:`.
- Workbench additions (`projects.session_instructions`, procedures) never reach a chat.
- Setup assistants (`SetupAssistantChat`, `.memory` persistence) get no slot and no remember.
- Pinned `--json` keys are only added, never renamed.
- Docs and code in English; board and asks in Russian.
- Inner loop only per task (`go test ./internal/<pkg>`, `make test-swift FILTER=…`, `make lint-diff`, `make lint-swift` for Swift); the full gate once at the end (Task 9).

## Review Focus

1. **The same rule remembered twice** (a re-sent or edited message, a new branch of the chat tree) → not appended again, no second ledger row, mark says it is already there with no Undo (else Undo would delete the owner's earlier line). Test in Task 3.
2. **Undo after the owner edited the line in Settings** → nothing removed, `not_found`, mark offers Open in Settings. Test in Task 3.
3. **Settings open with an unsaved draft while a chat remembers a line** → the section reloads its state after a remember (else the next save silently drops the line). Test in Task 8.
4. **Multi-line or whitespace-only rule after the prefix** (`remember:   ` / `запомни:\n- a\n- b`) → empty refused with `empty`; newlines collapse to single spaces, one line. Fixture cases in Task 2.
5. **Cyrillic case folding** (`ЗАПОМНИ:`, `Remember This:`) behaves identically in Go and Swift. Fixture cases in Task 2, asserted by Task 6.

---

### Task 1: Storage — `chat` scope and field, the chat-line ledger

**Depends on:** none

**Files:**
- Create: `internal/db/migrations/00153_chat_owner_instructions.sql`
- Modify: `internal/db/instructions.go`, `internal/db/schema.sql`, `internal/db/db_test.go` (`TestAllTablesExist`), golden + `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (regenerated)
- Test: `internal/db/instructions_test.go`

**Interfaces:**
- Produces: `db.InstructionChat InstructionField = "chat"`; `OwnerInstructions` gains `Chat string`; `GetOwnerInstructions`/`SetOwnerInstruction` accept `InstructionChat`; `SetWorkbenchInstruction` refuses it; `UpsertInstructionSuggestion` accepts field `chat`.
- Produces: `type InstructionChatLine struct { ID int64; Line string; ConversationID, MessageID sql.NullInt64; AddedAt string }`
- Produces: `func (db *DB) RememberChatLine(line string, conversationID, messageID int64, now time.Time, limit int) (InstructionChatLine, RememberOutcome, error)` — in one transaction: reads the chat text, returns `RememberAlreadyPresent` (no write) when a trimmed line of it equals `line`, `RememberTooLong` (no write) when the appended text would have more than `limit` runes (surrounding space not counted), else appends the line and inserts the ledger row (`RememberAdded`). `type RememberOutcome string` with those three values. `limit` is passed in (callers pass `instructions.MaxRunes`) because `internal/instructions` imports `internal/db`.
- Produces: `func (db *DB) ForgetChatLine(id int64, now time.Time) (removed bool, err error)` — one transaction: deletes the ledger row; removes the first trimmed line equal to its `line` from the chat text when present (`removed=true`), else leaves the text (`removed=false`); unknown id → `sql.ErrNoRows` wrapped.
- Produces: `func (db *DB) ListPresentChatLines() ([]InstructionChatLine, error)` — ledger rows whose `line` is still a trimmed line of the chat text, newest first.
- Produces: `func (db *DB) ChatLinesForMessages(ids []int64) ([]InstructionChatLine, error)`.

- [ ] **Step 1: Write the migration** — table-recreation dance (see `00002`/`00003` and the `add-migration` skill) for `owner_instructions` (scope CHECK `'session','procedure','chat'`) and `instruction_suggestions` (field CHECK adds `'chat'`, index recreated); new table `instruction_chat_lines(id INTEGER PRIMARY KEY AUTOINCREMENT, line TEXT NOT NULL, conversation_id INTEGER NULL, message_id INTEGER NULL, added_at TEXT NOT NULL)` with `CREATE INDEX idx_instruction_chat_lines_message ON instruction_chat_lines(message_id)`. No foreign keys (chat rows may be deleted; Settings then shows no link). Down reverses it, dropping `chat` rows first.
- [ ] **Step 2: Write failing tests** in `internal/db/instructions_test.go`:
  - `TestRememberChatLine_AppendsAndRecords`: empty text, remember `"Answer in bullets"` (conv 7, msg 70) → outcome `RememberAdded`, `GetOwnerInstructions().Chat == "Answer in bullets"`, `ChatLinesForMessages([]int64{70})` has one row with that line.
  - `TestRememberChatLine_AlreadyPresent`: chat text `"a\nAnswer in bullets"`, remember `"Answer in bullets"` → `RememberAlreadyPresent`, text unchanged, no ledger row.
  - `TestRememberChatLine_TooLong`: chat text of 995 runes, remember a 10-rune line with limit 1000 → `RememberTooLong`, nothing written.
  - `TestForgetChatLine_RemovesOnlyThatLine`: text `"x\ny\nz"`, ledger row for `"y"` → `removed=true`, text `"x\nz"`, row gone.
  - `TestForgetChatLine_EditedAway`: ledger row for `"y"`, text set to `"x"` → `removed=false`, text `"x"`, row gone.
  - `TestListPresentChatLines_DropsEditedLines`: two rows, one edited away → one returned.
  - `TestSetWorkbenchInstruction_RefusesChat`.
- [ ] **Step 3: Run** `go test ./internal/db -run 'Remember|Forget|PresentChatLines|RefusesChat'` → FAIL (undefined).
- [ ] **Step 4: Implement** the `internal/db/instructions.go` changes above; mirror the schema in `schema.sql`; add `instruction_chat_lines` to `TestAllTablesExist`.
- [ ] **Step 5: Regenerate** `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`, then `go test ./internal/db` → PASS.
- [ ] **Step 6: Commit** `feat(db): chat owner-instruction scope and chat-line ledger (migration 00153)`.

### Task 2: `internal/instructions` — chat slot, remember parser, shared fixture

**Depends on:** Task 1

**Files:**
- Modify: `internal/instructions/instructions.go`
- Create: `internal/instructions/remember.go`, `internal/instructions/testdata/remember_cases.json`
- Test: `internal/instructions/instructions_test.go`, `internal/instructions/remember_test.go`

**Interfaces:**
- Produces: `func ChatSlot(g db.OwnerInstructions) string` — `"Owner's instructions (follow in every turn):"` + trimmed `g.Session`, then `"For the chat:"` + trimmed `g.Chat` (that header only when the chat text is non-empty); joined by `\n`; `""` when both are empty. `const ChatSlotMaxRunes` analogous to `SlotMaxRunes`.
- Produces: `func ParseRemember(text string) (line string, ok bool)` — `ok` when the text, left-trimmed, starts case-insensitively (`strings.ToLower` on the prefix-length head, rune-wise) with `remember this:`, `remember:` or `запомни:` (checked in that order); `line` = the rest with all whitespace runs (newlines included) collapsed to one space and trimmed; `ok=true, line=""` is a valid result (the caller reports `empty`).
- Produces: fixture `remember_cases.json`: `[{"text": "...", "ok": bool, "line": "..."}]` — at least: `"запомни: отвечай короче"`, `"ЗАПОМНИ:  Отвечай коротко"`, `"  Remember This: use bullets"`, `"remember:   "` (ok, empty line), `"запомни:\n- a\n- b"` → `"- a - b"`, `"please remember: x"` (not ok), `"remember that x"` (not ok), `"Remember:x"` → `"x"`.

- [ ] **Step 1: Failing tests** — `TestChatSlot` (both empty → `""`; session only → header + text, no `For the chat:`; chat only → header + `For the chat:` + text; both); `TestParseRemember_Fixture` reads `testdata/remember_cases.json` and asserts every case.
- [ ] **Step 2: Run** `go test ./internal/instructions -run 'ChatSlot|ParseRemember'` → FAIL.
- [ ] **Step 3: Implement** `ChatSlot` (reuse `sessionHeader`; add `chatHeader = "For the chat:"`) and `ParseRemember` in `remember.go`.
- [ ] **Step 4: Run** `go test ./internal/instructions` → PASS.
- [ ] **Step 5: Commit** `feat(instructions): chat slot and remember parser`.

### Task 3: CLI — `--field chat`, `remember`, `forget`, new JSON keys

**Depends on:** Task 1, Task 2

**Files:**
- Modify: `cmd/instructions.go`
- Test: `cmd/instructions_test.go` (and the PROJ-22 guard file `cmd/workbench_brief_instructions_test.go` for the new guards)

**Interfaces:**
- Consumes: Task 1 `RememberChatLine`, `ForgetChatLine`, `ListPresentChatLines`; Task 2 `ParseRemember`, `ChatSlot`.
- Produces (pinned, additive): `instructionsJSON.Global` gains `"chat"`; `instructionsJSON` gains `"chat_lines": [{"id","line","conversation_id","message_id","added_at"}]` (present lines only; ids `null` when absent); `instructionsPreviewJSON` gains `"chat_slot"`; the failure object may carry `"code"` (`"too_long"`, `"empty"`, `"not_found"`, `"not_a_command"`).
- Produces: `watchtower instructions remember --conversation C --message M --stdin [--json]` — stdin = the whole owner message; runs `ParseRemember` itself (Go is the authority); not a command → `code: not_a_command`; empty → `empty`; outcome added → `{"ok":true,"outcome":"added","line_id":N, …show keys}`; already present → `{"ok":true,"outcome":"already_present", …}`; too long → `ok:false, code:too_long`.
- Produces: `watchtower instructions forget <line-id> [--json]` → `{"ok":true,"removed":bool, …show keys}`; unknown id → `ok:false, code:not_found`; `removed:false` is a success the Desktop shows as "not found in your instructions".
- `set --field chat` allowed; `set --field chat --workbench N` refused.

- [ ] **Step 1: Failing tests:** `TestInstructionsRemember_AddsVerbatim` (stdin `"запомни: Отвечай коротко"` → chat text `"Отвечай коротко"`, `outcome:"added"`), `TestInstructionsRemember_AlreadyPresent_NoLedgerRow`, `TestInstructionsRemember_TooLong`, `TestInstructionsRemember_Empty`, `TestInstructionsRemember_NotACommand`, `TestInstructionsForget_Removed`, `TestInstructionsForget_EditedAway` (`removed:false`), `TestInstructionsShow_ChatKeys` (`global.chat`, `chat_lines` present-only), `TestInstructionsPreview_ChatSlot`, `TestInstructionsSet_ChatWithWorkbenchRefused`. New PROJ-22 guards: `TestProj22_RememberWritesOwnerWordsVerbatim` (the stored line equals the stdin text after the prefix, whitespace-collapsed, nothing else written) and `TestProj22_WorkbenchTextsNeverInChatSlot`.
- [ ] **Step 2: Run** `go test ./cmd -run 'Instructions|Proj22'` → FAIL.
- [ ] **Step 3: Implement** in `cmd/instructions.go` (labels: `instructionsFieldLabel(chat)` = `"chat instructions"`; `printInstructions` prints the chat text and slot).
- [ ] **Step 4: Run** `go test ./cmd -run 'Instructions|Proj22'` → PASS.
- [ ] **Step 5: Commit** `feat(cli): instructions remember/forget and the chat text`.

### Task 4: The slot in every chat prompt

**Depends on:** Task 2

**Files:**
- Modify: `internal/chat/prompt.go` (`contextSections`), `cmd/ai.go` (`ai query`)
- Test: `internal/chat/prompt_test.go`, `cmd/ai_test.go`, `docs/inventory/chat.md` guard reference if a CHAT guard file is touched

**Interfaces:**
- Consumes: `instructions.ChatSlot`, `db.GetOwnerInstructions`.
- Produces: `ai query --owner-instructions` (bool flag), implemented through `func withOwnerInstructions(d *db.DB, system string) (string, error)` in `cmd/ai.go`: a non-empty `system` gets `"\n\n" + ChatSlot(...)` appended when the slot is non-empty; an empty `system` (a resumed turn) is returned unchanged.

- [ ] **Step 1: Failing tests:** `TestBuildSystemPrompt_CarriesChatSlotBeforeProject` (slot text present, index before the project block's first line when a project is set; absent when both texts empty); `TestWithOwnerInstructions_AppendsSlot`, `TestWithOwnerInstructions_EmptySystemUnchanged`, `TestWithOwnerInstructions_NoTextsUnchanged` (test DB, no provider process); `TestAIQueryCmd_OwnerInstructionsFlagParses` in the style of `TestAIQueryCmd_SystemPromptStdinFlagParses`.
- [ ] **Step 2: Run** `go test ./internal/chat -run ChatSlot` and `go test ./cmd -run OwnerInstructions` → FAIL.
- [ ] **Step 3: Implement**: in `contextSections`, the slot goes after memory and before `projectBlock` (it reads `d.GetOwnerInstructions()`); in `cmd/ai.go`, the flag and the append after `querySystemPrompt`/stdin decoding.
- [ ] **Step 4: Run** `go test ./internal/chat` and `go test ./cmd -run 'AIQuery|OwnerInstructions|Chat04'` → PASS (CHAT-04 guards unchanged).
- [ ] **Step 5: Commit** `feat(chat): owner instructions in the main and embedded chat prompts`.

### Task 5: The miner learns from chats

**Depends on:** Task 1, Task 2

**Files:**
- Modify: `internal/instructions/suggest.go`, `internal/prompts/defaults.go` (prompt v2, version 1 → 2, description), `internal/db/chat.go` (new query)
- Test: `internal/instructions/suggest_test.go`, `internal/db/chat_test.go`, `internal/prompts/defaults_extra_test.go`

**Interfaces:**
- Produces: `func (db *DB) ListOwnerChatTurnsSince(since time.Time) ([]ChatOwnerTurn, error)` with `type ChatOwnerTurn struct { ConversationID int64; Text string; At time.Time }` — `role='user'` rows of `chat_messages` with `created_at >= since` (REAL unix seconds), all conversations; `nil, nil` when `ChatTablesPresent` is false.
- Changes: `OwnerLine` gains `ChatID int64` (0 = a workbench session line); `parseSuggestions(raw string, sessions map[int64]int64, chats map[int64]bool)`.
- Rules (Go, authoritative): labels `s<id>` (sessions) and `c<id>` (chat conversations); distinct = valid sessions + valid chats, ≥ 3; chats-only → `Field = chat`, global; mixed → the model's field, global; sessions-only → today's logic. `session_count` = distinct sessions + chats; `workbench_count` = distinct workbenches. Chat turns where `ParseRemember` is ok are dropped before `cleanOwnerText`. The 60 000-rune cap applies to sessions and chats together, newest kept.
- `buildUser`: current texts gain `[All chats — chat]`; a new `=== OWNER MESSAGES BY CHAT ===` block with `# chat c<id>` headers and `c<id>: <text>` lines.
- Prompt v2: the owner's lines come from coding-agent sessions (`s12`) and AI chats (`c5`); the field rule stays `session|procedure` for the model (Go maps chats-only to `chat`); the rest unchanged.

- [ ] **Step 1: Failing tests:** `TestParseSuggestions_ChatsOnlyIsChatField`, `TestParseSuggestions_MixedIsGlobal`, `TestParseSuggestions_UnknownChatLabelDropped`, `TestMinerRun_CountsChatsTowardThree` (two sessions + one chat with lines → model called; fake generator), `TestMinerRun_SkipsRememberTurns`, `TestListOwnerChatTurnsSince`; update `TestInstructionSuggestionsPromptRegistered` for version 2.
- [ ] **Step 2: Run** `go test ./internal/instructions ./internal/db ./internal/prompts -run 'Suggest|Miner|OwnerChatTurnsSince|InstructionSuggestionsPrompt'` → FAIL.
- [ ] **Step 3: Implement** (the daemon phase `internal/daemon/instruction_suggestions.go` needs no change unless `Miner` gains a field).
- [ ] **Step 4: Run** the same packages → PASS.
- [ ] **Step 5: Commit** `feat(instructions): suggestions from repeated chat remarks`.

### Task 6: WatchtowerCore — parser twin, state decode, ledger query, the CLI flag

**Depends on:** Task 3 (JSON keys), Task 4 (flag)

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/RememberCommand.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/InstructionChatLineQueries.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/OwnerInstructions.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/WatchtowerAIService.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/Embedded/ChatSurfaceSpec.swift`, `.../Embedded/EmbeddedChatEngine.swift`, every `ChatSurfaceSpec(` call site (`TargetChatViewModel`, `MeetingChatSurface`, `AutomationEditorChatSurface`, `TrackChatSurface`, `CodeQuestionSurface`, `IdeaChatSurface`, `SetupAssistantChat`)
- Test: `WatchtowerDesktop/Tests/Core/RememberCommandFixtureTests.swift`, `OwnerInstructionsStateTests.swift`, `InstructionChatLineQueriesTests.swift`, the existing `WatchtowerAIService` buildArgs tests

**Interfaces:**
- Produces: `package enum RememberCommand { static func parse(_ text: String) -> String? }` — the Swift twin of `ParseRemember` (`nil` = not a command; `""` = empty rule).
- Produces: `OwnerInstructionsState` gains `chat: String`, `chatLines: [OwnerInstructionChatLine]` (`id`, `line`, `conversationID: Int64?`, `messageID: Int64?`, `addedAt`), and an error `code` when decoding a failure object; `InstructionField` gains `.chat`.
- Produces: `InstructionChatLineQueries.forMessages(_ db: Database, ids: [Int64]) throws -> [Int64: OwnerInstructionChatLine]`.
- Produces: `WatchtowerAIService.buildArgs(…, ownerInstructions: Bool)` adds `--owner-instructions` when true; `ChatSurfaceSpec` gains an explicit (no default) `ownerInstructions: Bool` — `true` for every surface above, `false` for `SetupAssistantChat`; `EmbeddedChatEngine.startStream` passes it.

- [ ] **Step 1: Failing tests:** `testRememberFixtureMatchesGo` reads `internal/instructions/testdata/remember_cases.json` (path resolution as in `ArtifactContractFixtureTests`) and asserts every case; decode tests for `chat`, `chat_lines`, `code`; buildArgs with/without the flag; a spec test that `SetupAssistantChat`'s spec has `ownerInstructions == false`.
- [ ] **Step 2: Run** `make test-swift FILTER='RememberCommandFixtureTests|OwnerInstructionsStateTests|InstructionChatLineQueriesTests|WatchtowerAIServiceTests'` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same filter → PASS; `make lint-swift`.
- [ ] **Step 5: Commit** `feat(core): remember parser, chat instruction state and the --owner-instructions flag`.

### Task 7: Remember in place — the center, the send hook, the mark

**Depends on:** Task 3, Task 6

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/RememberCenter.swift`, `WatchtowerDesktop/Sources/Views/Chat/RememberMarkView.swift`
- Modify: `WatchtowerDesktop/Sources/Services/WorkbenchCLI.swift` (`instructionsRemember`, `instructionsForget`), `AppState` (owns `RememberCenter`), `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift` (after `ChatTreeQueries.insertUser`), `EmbeddedChatEngine` (after `store.beginTurn` when `ownerID != nil` and the spec has `ownerInstructions`), `WatchtowerDesktop/Sources/Views/Chat/ChatFeedView.swift` (mark under an owner message)
- Test: `WatchtowerDesktop/Tests/RememberCenterTests.swift`

**Interfaces:**
- Consumes: `RememberCommand.parse`, `InstructionChatLineQueries.forMessages`, the CLI subcommands of Task 3.
- Produces: `@MainActor @Observable final class RememberCenter` — `func ownerMessageSent(text: String, conversationID: Int64, messageID: Int64)` (no-op unless `RememberCommand.parse` is non-nil; the CLI call runs off the send path and never delays the turn); `func undo(messageID: Int64) async`; `func mark(for messageID: Int64) -> RememberMark?`; `func loadMarks(messageIDs: [Int64])` (from the ledger, on feed load); `private(set) var revision: Int` (bumped after every successful remember/undo). `enum RememberMark { case remembered(lineID: Int64), alreadyPresent, full, empty, undone, notFound, failed(String) }`.
- Copy (English UI strings; localized per the style guide): remembered → "Remembered for all chats" + **Undo** + **Open in Settings**; alreadyPresent → "Already in your instructions"; full → "Instructions are full — 1000 characters" + **Open in Settings**; empty → "Nothing to remember after “remember:”"; undone → "Removed from your instructions"; notFound → "That line is no longer in your instructions" + **Open in Settings**.

- [ ] **Step 1: Failing tests** with a fake CLI seam: a remember message produces `.remembered`; an ordinary message never calls the CLI; `already_present` → `.alreadyPresent`; `too_long` → `.full`; undo → `.undone` and `revision` bumped; undo with `removed:false` → `.notFound`; `loadMarks` rebuilds `.remembered` from ledger rows.
- [ ] **Step 2: Run** `make test-swift FILTER=RememberCenterTests` → FAIL.
- [ ] **Step 3: Implement**; the mark view uses DesignKit components (`docs/design/desktop-style-guide.md`); Open in Settings goes to Settings → Profile → Instructions (Task 8's anchor).
- [ ] **Step 4: Run** the filter → PASS; `make lint-swift`; look at it with `make desktop-shots DESKTOP_SHOTS=<scratch dir>`.
- [ ] **Step 5: Commit** `feat(desktop): remember a rule from any chat, with Undo`.

### Task 8: Settings → Profile → Instructions

**Depends on:** Task 3, Task 6

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Settings/InstructionsSettingsSection.swift`, `ProfileSettings.swift` (add the section), `SystemSettings+Workbench.swift` (replace the section with a one-line pointer + button), `InstructionFieldBlock.swift` if the chat block needs the from-chat list, the Preview sheet (shows `chat_slot`)
- Test: `WatchtowerDesktop/Tests/InstructionsSettingsSectionTests.swift` (or the existing test of the section's model)

**Interfaces:**
- Consumes: `OwnerInstructionsState.chat/chatLines`, `WorkbenchCLI.setInstruction(field: .chat, …)`, `RememberCenter.revision`.
- Section layout: "For chats and agents" (global session), "Only in chats" (chat text + "Added from chats" list: each line with an **Open chat** link when `conversationID` exists), "Target procedure" (global), Preview. Per-workbench texts stay in Agent Settings….

- [ ] **Step 1: Failing tests:** the section's state reloads when `RememberCenter.revision` changes (Review Focus 3); a chat line without a conversation id renders no link; saving the chat text calls `set --field chat`.
- [ ] **Step 2: Run** `make test-swift FILTER=InstructionsSettings` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the filter → PASS; `make lint-swift`; screenshot via `make desktop-shots`.
- [ ] **Step 5: Commit** `feat(desktop): instructions move to Settings → Profile, with the chat addition`.

### Task 9: Contract, docs, gate

**Depends on:** Tasks 1–8

**Files:**
- Modify: `docs/inventory/workbench.md` (PROJ-22 amendment entry: shared text reaches chats; `remember` as the second owner write path; `chat` scope/field; new guards), `docs/features/agent-instructions.md`, `docs/guide/features/workbench/instructions.md` (or a new `docs/guide/features/chat-instructions.md` linked from it), `docs/guide/reference/settings.md`, `CLAUDE.md` (the Agent instructions feature line)

- [ ] **Step 1:** Write the PROJ-22 amendment (dated 2026-10-24, ask #522) listing the new guards from Tasks 3–4; no existing guard assertion relaxed.
- [ ] **Step 2:** Update the feature note and the guide (follow `docs/guide/WRITING.md`); run `go test ./docs/guide` (8 KB page cap).
- [ ] **Step 3: Gate:** `make test`, `make test-swift`, `make lint-all` — all green.
- [ ] **Step 4: Commit** `docs: owner instructions in every chat — PROJ-22 amendment, feature note, guide`.
