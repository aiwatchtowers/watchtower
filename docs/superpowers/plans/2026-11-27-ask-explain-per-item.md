# "Not clear?" on each ask item — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move **Not clear?** from the whole ask onto each question and each check step, give each item its own explain chat, and pin a compact card of the item above that chat.

**Architecture:** The shipped `owner_ask_explain` surface keeps its engine, center, Go writers and guards; its context id grows an item part (`<wb>:<ask>:q<N>` / `s<N>`, Go accepts it beside the legacy 2-part form). Swift Core gains `AskExplainItem`, the item's card model and per-item copy and prompt; `OwnerAsksViewModel` keeps a per-ask mode holding one item and keys every other explain state by (ask, item); the drawer draws an entry per item and the pane a strip and a pinned card over the existing chat view.

**Tech Stack:** Go (`internal/db`, `internal/chatstore`, `internal/workbenchfolders`), SwiftUI Desktop (`WatchtowerCore`, `Services/ChatSurfaces`, `ViewModels`, `Views/Workbench/Asks`), ChatUI's `ChatQuestionDraft.decorate`, DesignKit, DesignShotCatalog.

**Spec:** `docs/superpowers/specs/2026-11-27-ask-explain-per-item-design.md` (board #2412). Mockups: `docs/design/mockups/ask-explain-per-item/` (approved, ask #1862). Base: `docs/superpowers/specs/2026-11-24-ask-explain-chat-design.md`, `docs/features/ask-explain-chat.md`.

## Global Constraints

- Context type stays `owner_ask_explain`; context id `"\(workbenchID):\(askID):\(item.token)"`, `item.token` = `q<N>` / `s<N>`, N 1-based payload index, canonical. Never the agent's question or step `id`.
- Go keeps accepting `<wb>:<ask>` (legacy); the Mac never makes it again, it only reuses an existing one on a single-item ask (spec D4).
- UI copy exactly as the spec's Texts table (`AskExplainCopy`); every string a view shows comes from it (or from ChatUI/kit components the feature reuses unchanged).
- Colours only through `Tone` and kit components (`Chip`, `.card()`, `KitQuietButtonStyle`, `.kitQuiet`); no `Divider()` between options or steps; the card's fade is a mask.
- Card layout constants: `AskExplainCardLayout.clampHeight = 76`, `expandedMaxHeight = 180`.
- No schema change, no migration, no tower interface change (`make gen-interface-check` must stay clean without regenerating).
- Inner loop only per task (CLAUDE.md "Agent-driven runs"): `go test ./internal/<pkg>` for touched Go packages, `make test-swift FILTER='…'`, `make lint-diff` (Go only), and **`make lint-swift` for every Swift task** (lint-diff never checks Swift). The full gate (`make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`, `scripts/leak-check.sh`, every `.github/workflows/*.yml` job by its own command) runs once by the controller after Task 6, before merging.
- Guard suites each task names below must run in that task, not only at the gate (filtered runs missed them before: memory "Task briefs name guard suites").
- Tests never wait on wall-clock (gates are fakes/continuations, not sleeps); a test that spawns a process reaps it in `t.Cleanup`.
- Public repo: sample data only (`acme`, `example.com`), no live ids.

## Review Focus

1. The legacy lookup (spec D4): only on an ask with exactly one item, in the same read as the workbench, before `chat.new`; a found legacy chat keeps its `<wb>:<ask>` key — Task 4 `testLegacyWholeAskChatIsReusedOnASingleItemAsk`, `testLegacyWholeAskChatIsNotReusedOnAMultiItemAsk`, `testLegacyChatWinsOverAnItemChatOnASingleItemAsk`.
2. Back, then another item's entry before the first open's `chat.new` answered: the first open must write nothing (no engine, no hidden turn, no `explainSpecs` entry) — Task 4 `testBackAndOpenAnotherItemBeforeChatNewOpensOnlyTheSecond`.
3. Every #2383 fix keyed by subject, not by ask: a reopen of q1 while q2's open runs must not be taken as q2's reopen — Task 4 `testReopenOfOneItemIsNotAnotherItemsReopen`.
4. Retry of a stored first turn re-sends the item's own `firstTurn`, not the question text of another item — Task 4 `testRetryAfterRestartResendsTheItemsFirstTurn`.
5. Go's id check: exactly 2 or 3 parts, item `[qs]` + canonical positive; the fake mirrors it byte for byte — Task 2 `TestAskExplainWorkbenchID`, Task 4 `testMalformedItemContextIDIsABadRequest`.
6. The item number in the prompt sits outside the fence and matches the numbering inside it — Task 3 `testSystemPromptNamesTheItemOutsideTheFence`.
7. The question layer is still hidden, never removed, under an item's chat (scroll survives) — Task 6 built shot `back-scrolled`.
8. The payload guard must not be weakened into an allowlist of patterns: it allows exactly the filing `INSERT` and the two `moveAsks` statements — Task 2 `TestAskPayloadItemsAreNeverRewritten`.

---

### Task 1: Mockups — none left

**Depends on:** none.

Done in spec review (ask #1868): `DesignShotFixtures+AskExplainItemsMock.swift` renders every state of the spec's States table (busy, queued, finding, failed open, expanded card and back-scrolled added), the PNGs are in `docs/design/mockups/ask-explain-per-item/`, and `AskExplainItemsMockShotFixtures.shots` is registered in `DesignShotCatalog`. Nothing to implement; Task 6 compares the built views with these shots.

### Task 2: Go — the item id, chat_writes.json cases, delete/merge/draft tests, inventory notes

**Depends on:** none.

**Files:**
- Modify: `internal/db/ask_explain.go` (`AskExplainWorkbenchID`, its doc comment; `AskExplainContextType` doc comment names the item form)
- Modify: `internal/db/workbenches.go` (doc comments of `deleteWorkbenchAskExplainChats` / `AskExplainDraftKeyPrefix` name both shapes; no logic change)
- Modify: `internal/workbenchfolders/merge.go` (comment at the draft re-key: both shapes)
- Modify: `internal/chatstore/testdata/chat_writes.json`
- Test: `internal/db/ask_explain_test.go`, `internal/db/workbenches_test.go`, `internal/workbenchfolders/merge_test.go`
- Create: `internal/db/ask_payload_guard_test.go` (`TestAskPayloadItemsAreNeverRewritten`)
- Modify: `docs/inventory/chat.md`, `docs/inventory/workbench.md` (change-log lines, note only)

**Interfaces:**
- Produces: `db.AskExplainWorkbenchID(contextID string) (int64, bool)` true for `<wb>:<ask>` and `<wb>:<ask>:<item>` (`item` = `q`|`s` + canonical positive id); `chat.new` accepts item ids for live workbenches.

- [ ] **Step 1: Failing tests**
  - `TestAskExplainWorkbenchID` gains rows: `{"4:9:q1", 4, true}`, `{"4:9:s12", 4, true}`, `{"12:345:q4", 12, true}`, and false for `"4:9:"`, `"4:9:q"`, `"4:9:q0"`, `"4:9:q01"`, `"4:9:q+1"`, `"4:9:q-1"`, `"4:9:Q1"`, `"4:9:x1"`, `"4:9:1"`, `"4:9:q1:s1"`, `"04:9:q1"`, `"4:09:q1"`, `"4:9:q1 "`.
  - `TestDeleteWorkbenchDropsAskExplainChats`: also insert `"<wb>:5:q1"`, `"<wb>:5:s3"` (gone after delete) and `"<wb>1:5:q1"` (stays), with drafts `owner_ask_explain.<wb>:5:q1.<id>` (gone) and `owner_ask_explain.<wb>1:5:q1.<id>` (stays); the existing 2-part assertions stay.
  - `TestQueuedDraftOfADeletedAskExplainChatIsNotSaved`: a second sub-case with an item conversation `"<wb>:5:q2"` and key `owner_ask_explain.<wb>:5:q2.<conv>` — saved before the delete it goes, saved after it is not written.
  - `TestMergeReKeysTheChats`: add `explainItem := chat(db.AskExplainContextType, bs+":9:q2")` → `assert.Equal(t, as+":9:q2", key(explainItem))`, and a draft `owner_ask_explain.<from>:9:q2.<id>` → `owner_ask_explain.<into>:9:q2.<id>`; name the case in the doc comment.
  - chat_writes.json cases (all `"swift"` pointers as their 2-part siblings):
    - `new_ask_explain_item_chat_of_a_live_workbench`: seed project 4; `chat.new` `{"type":"owner_ask_explain","id":"4:9:q2","title":"Ask #9 · Question 2","reuse":true}` → `conversation_id` 1; row `["Ask #9 · Question 2","owner_ask_explain","4:9:q2"]`.
    - `items_of_one_ask_get_their_own_chats`: seed project 4 and conversation 1 `'4:9:q1'`; `chat.new` `4:9:q2` reuse → `conversation_id` 2; two rows.
    - `new_ask_explain_item_chat_of_a_deleted_workbench_is_refused`: no seed; `4:9:s1` → refusal `not_found`, `COUNT(*)` 0.
    - `new_ask_explain_chat_with_a_non_canonical_item_is_refused`: `4:9:q02` → `unsupported`, 0 rows.
    - `new_ask_explain_chat_with_an_unknown_item_kind_is_refused`: `4:9:x2` → `unsupported`, 0 rows.
    - `draft_save_of_a_deleted_ask_explain_item_chat_writes_nothing`: `owner_ask_explain.4:9:q2.5`, no conversation → 0 drafts.
    - `draft_save_under_a_merged_ask_explain_item_key_lands_on_the_current_key` and `draft_clear_under_a_merged_ask_explain_item_key_clears_the_current_key`: as their 2-part siblings with `8:9:q2` / `4:9:q2`.
  - `TestAskPayloadItemsAreNeverRewritten` (`internal/db/ask_payload_guard_test.go`, spec D18): walk `../../internal`, `../../cmd` (non-`_test.go` Go files) and `../../WatchtowerDesktop/Sources`, `../../WatchtowerKit/Sources`, `../../WatchtowerMobile` (`.swift`, skipping `.build`); collect every SQL string literal (Go raw strings and Swift `"""` blocks, joined across `+` concatenation) that matches `(?is)\b(UPDATE|REPLACE\s+INTO|INSERT\s+OR\s+REPLACE\s+INTO)\s+owner_asks\b` or `INSERT INTO owner_asks … ON CONFLICT … DO UPDATE`; fail when one names `payload` and is not one of: the filing `INSERT INTO owner_asks` in `internal/db/owner_asks.go` (no `ON CONFLICT`), and the two `moveAsks` statements in `internal/workbenchfolders/merge.go` (each must also contain `kind = 'folder'` and `$.other_bench`). The failure names the file and line and says: "an ask's questions and checklist key its Not clear? item chats by position (spec 2026-11-27 D3/D18); rewriting them needs a re-key of those chats in the same transaction". A self-test feeds the scanner a fake `UPDATE owner_asks SET payload = ?` and asserts it is caught.
  - `TestMergeLeavesQuestionAndCheckPayloadsAsTheyWere` (`internal/workbenchfolders/merge_test.go`): a question ask and a check ask on the merged bench; after the merge `payload` equals the inserted string byte for byte.
- [ ] **Step 2:** `go test ./internal/db -run 'AskExplain|AskPayload'` and `go test ./internal/chatstore -run TestChatWritesCases` and `go test ./internal/workbenchfolders -run 'TestMergeReKeysTheChats|TestMergeLeavesQuestionAndCheckPayloadsAsTheyWere'` → the id and chat.new cases FAIL (delete/merge/draft cases and the payload guard are expected to pass already — the guard pins today's code — they prove the prefix rule; if one fails, the spec's "unchanged" claim is wrong: stop and report).
- [ ] **Step 3: Implement.** `AskExplainWorkbenchID`: `parts := strings.Split(contextID, ":")`; `len(parts)` 2 or 3; `canonicalID(parts[0])`, `canonicalID(parts[1])`; with a third part, `item, ok := strings.CutPrefix(parts[2], "q")` else `"s"`, then `canonicalID(item)`. Doc comment: both forms, why the index (spec D3), legacy form kept (D4).
- [ ] **Step 4:** Same commands → PASS. Guard suites: `go test ./internal/db -run 'Proj02|LIVE01|TestSchemaGolden|TestDesktopTestSchema'`, `go test ./internal/chatstore -run 'LIVE01|ChatWritesCases|RegisteredGuarded'`, `go test ./internal/chatengine -run TestChatengine_PortedProjectWriteCases`, then `go test ./internal/db ./internal/chatstore ./internal/workbenchfolders` whole; `make lint-diff`.
- [ ] **Step 5:** Inventory change-log lines, note only: `docs/inventory/chat.md` (CHAT-01 queued drafts: item keys route the same way) and `docs/inventory/workbench.md` (PROJ-02: item chats and their drafts go with the workbench; no guard relaxed or renamed).
- [ ] **Step 6: Commit** `feat(asks): owner_ask_explain item ids and the payload guard <wb>:<ask>:q<N>/s<N> in chat.new (#2412)`.

### Task 3: Swift Core — item, key, copy, card, layout, prompt

**Depends on:** none.

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/AskExplain/AskExplain.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/AskExplain/AskExplainItem.swift` (`AskExplainItem`, `AskExplainSubject`, `AskExplainCard`, `AskExplainCardLayout`)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/AskExplain/AskExplainPrompt.swift`
- Test: `WatchtowerDesktop/Tests/Core/AskExplainTests.swift`

**Interfaces:**
- Produces:
  - `package enum AskExplainItem: Hashable, Sendable { case question(Int), step(Int); var number: Int; var token: String /* "q2" */; var isStep: Bool; static func items(of ask: OwnerAsk) -> [AskExplainItem] /* [] unless showsEntry(kind:, hasCLI: true) */; static func forQuestion(id: String, in ask: OwnerAsk) -> AskExplainItem? }`
  - `package struct AskExplainSubject: Hashable, Sendable { let askID: Int64; let item: AskExplainItem }`
  - `package enum AskExplainCard: Equatable { struct Option: Equatable { let label: String; let recommended: Bool }; case question(text: String, options: [Option]); case step(number: Int, text: String, hint: String); static func make(ask: OwnerAsk, item: AskExplainItem) -> AskExplainCard? }` — no description field exists in the model.
  - `package enum AskExplainCardLayout { static let clampHeight: CGFloat = 76; static let expandedMaxHeight: CGFloat = 180; enum Mode: Equatable { case whole, clamped, expanded, expandedScrolling }; static func mode(contentHeight: CGFloat, expanded: Bool) -> Mode; static func showsToggle(_ mode: Mode) -> Bool }`
  - `AskExplainKey.contextID(workbenchID:askID:item:) -> String`, `AskExplainKey.title(askID:item:) -> String` ("Ask #41 · Question 2"). The 2-argument forms stay until Task 4 removes them with their last callers, so every commit builds.
  - `AskExplainItem.isOnlyItem(_ item: AskExplainItem, of ask: OwnerAsk) -> Bool` (`items(of:) == [item]`).
  - `AskExplainCopy` gains `entryAccessibilityLabel(_:)` ("Not clear? Question 2" / "Not clear? Step 3"), `stepEntryHelp`, `backToCheck`, `stepPlaceholder`, `showMore`, `showLess`, `recommended`, and `static func itemLabel(_:) -> String`, `back(for:)`, `placeholder(for:)`, `entryHelp(for:)`.
  - `AskExplainPrompt.system(ask:item:target:)`, `AskExplainPrompt.firstTurn(_ item: AskExplainItem) -> String`. The old `system(ask:target:)` and the `firstTurn` constant stay until Task 4 (same reason).

- [ ] **Step 1: Failing tests** (`AskExplainTests`):
  - `testCopyMatchesSpec`: every key of the spec's Texts table, including `itemLabel(.question(2)) == "Question 2"`, `itemLabel(.step(3)) == "Step 3"`, `back(for: .step(1)) == "Back to check"`, `placeholder(for: .step(1)) == "Ask about this step…"`, `entryHelp(for: .step(1)) == "Ask the assistant about this step"`, `entryAccessibilityLabel(.question(2)) == "Not clear? Question 2"`, `entryAccessibilityLabel(.step(3)) == "Not clear? Step 3"`.
  - `testOnlyItem`: a 1-question ask → `isOnlyItem(.question(1))`; a 1-step check → `isOnlyItem(.step(1))`; a check with 1 question and 1 step → false for both; a 3-question ask → false.
  - `testItemTokens`: `.question(2).token == "q2"`, `.step(12).token == "s12"`, `.number`, `.isStep`.
  - `testItemsOfAnAsk`: question ask with 3 questions → `[.question(1), .question(2), .question(3)]`; check ask with 1 question and 4 steps → `[.question(1), .step(1)…(4)]`; review and folder asks → `[]`.
  - `testItemNumberIsNotTheAgentsID`: questions with ids `"pick-db"`, `"a:b"` → `forQuestion(id: "a:b", in:) == .question(2)`; unknown id → nil.
  - `testContextIDAndTitle`: `contextID(workbenchID: 3, askID: 41, item: .question(2)) == "3:41:q2"`, `.step(10)` → `"3:41:s10"`; `title(askID: 41, item: .step(3)) == "Ask #41 · Step 3"`.
  - `testCardOfAQuestion`: question 2 with three options (one recommended, all with descriptions) → `.question(text:, options:)` with labels in order and the recommended flag; `String(describing: card)` contains no description text.
  - `testCardOfAStep`: `.step(number: 2, text:, hint:)`; a step without a hint → `hint == ""`.
  - `testCardOutOfRangeIsNil`: `.question(5)` on a 3-question ask, `.step(1)` on a question ask → nil.
  - `testCardLayout`: `mode(60, false) == .whole`, `mode(76, false) == .whole`, `mode(77, false) == .clamped`, `mode(150, true) == .expanded`, `mode(181, true) == .expandedScrolling`, `mode(60, true) == .whole`; `showsToggle` true only for clamped/expanded/expandedScrolling.
  - `testFirstTurnPerItem`: `firstTurn(.question(2))` and `firstTurn(.step(3))` equal the spec's quoted texts with N filled in.
  - `testSystemPromptNamesTheItemOutsideTheFence`: for `.question(2)` the line "The owner opened this chat from question 2 of the ask below" occurs before the first fence line; for `.step(3)` "step 3 of the check below"; the item's question text occurs after the fence opens; the fenced data numbers it "2.".
  - Keep and adapt `testSystemPromptCarriesAskAndRules`, `testFocusItemsAreInsideTheFence`, `testNoTargetNoTargetLines`, `testFenceOutgrowsBackticksInAsk`, `testCheckAskPromptListsSteps` to the item forms; `testPurposeHasADisplayName`, `testEscRules` unchanged.
- [ ] **Step 2:** `make test-swift FILTER=AskExplainTests` → FAIL (compile).
- [ ] **Step 3: Implement** per Interfaces. `items(of:)`: `guard AskExplainPresentation.showsEntry(kind: ask.kind, hasCLI: true)`, then questions then steps. The prompt's item line is built from `item` only (never payload text), placed after the rules, before "The ask follows.". Existing callers keep compiling on the old forms.
- [ ] **Step 4:** Same filter → PASS; `make lint-swift`.
- [ ] **Step 5: Commit** `feat(asks): ask explain items, card model and per-item prompt (#2412)`.

### Task 4: The surface and the per-item state

**Depends on:** Task 3. (Task 2 only at run time; tests use `FakeChatTower`.)

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/ChatSurfaces/AskExplainSurface.swift`
- Modify: `WatchtowerDesktop/Sources/ViewModels/OwnerAsksViewModel.swift` (the "Not clear?" section)
- Modify: `WatchtowerDesktop/Tests/Support/FakeChatTower.swift` (`askExplainWorkbenchID` mirrors Go's rule)
- Test: `WatchtowerDesktop/Tests/AskExplainSurfaceTests.swift`, `WatchtowerDesktop/Tests/AskExplainModelTests.swift`

**Interfaces:**
- Consumes: Task 3's `AskExplainItem`, `AskExplainSubject`, `AskExplainCard`, `AskExplainKey`, `AskExplainPrompt`.
- Produces:
  - `AskExplainSurface.conversationID(ask:item:dbPool:writes:)` (3-part find-or-create), `nonisolated static func AskExplainSurface.legacyConversationID(_ db: Database, ask: OwnerAsk) throws -> Int64?` (spec D4: newest `owner_ask_explain` row with `context_id = "<wb>:<ask>"`), `AskExplainSurface.spec(ask:item:contextID:conversationID:folder:target:configProvider:catalog:)` (`contextID` = the conversation's own context id; system prompt `AskExplainPrompt.system(ask:item:target:)`).
  - On `OwnerAsksViewModel`: `private(set) var explainOpen: [Int64: AskExplainItem]`; `isExplaining(_ askID: Int64) -> Bool`; `explainItem(_ askID: Int64) -> AskExplainItem?`; `openExplain(_ ask: OwnerAsk, item: AskExplainItem) async`; `closeExplain(_ askID: Int64)`; `explainEngine(for ask: OwnerAsk, item: AskExplainItem) -> EmbeddedChatEngine?`; `ensureExplainEngine(_ ask: OwnerAsk, item: AskExplainItem) -> EmbeddedChatEngine?`; `explainErrors: [AskExplainSubject: String]`; `explainOffersRetry(_ subject: AskExplainSubject) -> Bool`. Private state (`explainSpecs`, `explainFinal`, `explainStarting`, `explainReopened`, `explainBuilds`) keyed by `AskExplainSubject`; `explainProjects` stays by ask.
  - `FakeChatTower.askExplainWorkbenchID(_:)`: 2 or 3 parts, same rule as Go.

- [ ] **Step 1: Failing tests** — convert every existing test of both files to open an item (`.question(1)` unless the test is about steps), keep its name and assertions, and add:
  - `AskExplainSurfaceTests.testSpecShape`: key `contextID == "<wb>:<ask>:q2"` for `.question(2)`, `.draftOnly`, `.database`, purpose, model nil.
  - `testItemsGetTheirOwnConversations`: `conversationID` for `.question(1)` and `.question(2)` of one ask differ; a second call for `.question(1)` returns the first id.
  - `testSameItemSameConversation`: two concurrent calls for `.step(2)` return one id.
  - `testMalformedItemContextIDIsABadRequest`: through `FakeChatTower`, `chat.new` with `4:9:q02`, `4:9:x1`, `4:9:q1:s1` → refusal `unsupported`; `4:9:q2` and `4:9` → a conversation.
  - `testItemTurnOutlivesDrawer`: open `.question(2)`, start a turn, `closeExplain`, the engine finishes in the center; reopening `.question(2)` returns the same engine.
  - `AskExplainModelTests.testModeHoldsOneItemPerAsk`: open `.question(2)` → `explainItem(ask) == .question(2)`, `isExplaining(ask)`; `closeExplain`; open `.question(3)` → `.question(3)`; another ask's mode untouched; `hideDrawer(projectID:)` clears both asks.
  - `testEachItemHasItsOwnChat`: open q1 (hidden turn with `firstTurn(.question(1))`), close, open q2 (hidden turn with `firstTurn(.question(2))`), close, reopen q1 → no third turn; two engines in the center.
  - `testOpenAnItemTwiceStartsOneHiddenTurn`: two `openExplain(ask, item: .step(1))` before the first's `chat.new` returns → one hidden turn.
  - `testBackAndOpenAnotherItemBeforeChatNewOpensOnlyTheSecond`: `chat.new` gated on a continuation; open q1; `closeExplain`; open q2; release both → `explainEngine(for: ask, item: .question(1)) == nil`, no q1 turn, q2 has one hidden turn, `explainItem == .question(2)`.
  - `testReopenOfOneItemIsNotAnotherItemsReopen`: gate; open q1; close; open q2; close; open q1 → q1's running open re-reads for q1 only; q2 has no engine.
  - `testOpeningAnotherItemKeepsTheFirstStreaming`: q1's first turn streaming; close; open q2 → q1's engine still `isBusy` and finishes with its reply; q2 started its own turn.
  - `testBackAndReopenAnItemBeforeChatNewMakesOneChatWithTheLatestRead` (the #2383 test, per item).
  - `testRetryAfterRestartResendsTheItemsFirstTurn`: seed a q2 conversation whose first reply is `partial` (quit); open q2 → `canRetry`; Retry sends `firstTurn(.question(2))` hidden.
  - `testStopInOneItemKeepsRetryInAnother`: q1's reply stopped by the owner, q2's partial by quit; rebuild both → q1 offers no Retry, q2 does.
  - `testStoppedItemFirstTurnOffersNoRetryAfterARebuild`, `testQuotaPartialOffersNoRetry`, `testPartialFirstTurnOffersRetryOnly`, `testErrorRow` (per item).
  - `testEmptyItemChatLeftByACrashStartsTheExplanation`: seed an empty `<wb>:<ask>:q1` conversation → open starts exactly one hidden turn.
  - `testMergeMidStreamMovesTheRunningItemEngine`: q2 streaming; re-key its conversation to `<into>:<ask>:q2` in the database; reopen through the ask under the new bench → the same engine under the new key, still busy.
  - `testWorkbenchDeletedBeforeItemChatNewLeavesNoChat`, `testMissingWorkbenchOpensNoItemChat`, `testOnlyAGoneWorkbenchTakesTheRetryAway` (subject-keyed `explainOffersRetry`).
  - `testSessionInTheUndoWindowIsGoneUntilUndo`, `testDeletingSessionFallsBackToHome`, `testAskFromSecondFolderReadsThatFolder`, `testFolderOffTheBenchFallsBackToHome` (open an item; folder rules unchanged).
  - `testItemOutOfRangeOpensNothing`: `.question(5)` on a 3-question ask → no mode, no `chat.new`.
  - `testLegacyWholeAskChatIsReusedOnASingleItemAsk`: a 1-question ask with a seeded `<wb>:<ask>` conversation holding an explanation; open `.question(1)` → the engine's conversation is the legacy id, its key's context id is `"<wb>:<ask>"`, the history shows, no hidden turn, no `chat.new` sent (the fake tower records none), `chat_conversations` count unchanged. Same for a 1-step check ask with `.step(1)`.
  - `testLegacyWholeAskChatIsNotReusedOnAMultiItemAsk`: a 3-question ask with a seeded legacy conversation; open `.question(1)` → a new 3-part conversation, one hidden turn; the legacy row and its messages untouched.
  - `testSingleItemOpenedTwiceUsesOneChat`: two concurrent opens of a 1-question ask, once with a legacy row (both on it, no `chat.new`) and once without (one `chat.new` row, one hidden turn).
  - `testLegacyChatWinsOverAnItemChatOnASingleItemAsk`: both `<wb>:<ask>` and `<wb>:<ask>:q1` rows exist → the open uses the legacy one, on every open.
  - `testLegacyChatDeletedAfterTheLookupFailsAndTheNextOpenSaysGone`: open a single-item ask (legacy found), then `DeleteWorkbench` through the test writer before a follow-up; the follow-up's save fails into the shared error card; a fresh open shows "This workbench no longer exists." and `explainOffersRetry` false.
  - `testMergeMidStreamMovesARunningLegacyEngine`: a reused legacy chat streaming; re-key it to `<into>:<ask>`; reopen under the new bench → the lookup finds it, the same engine is adopted under `"<into>:<ask>"`, still busy.
  - `testItemChatSurvivesAskClosing`, `testNoCLINoItemChat`, `testReviewAskOpensNoChat` (per item).
  - `testCloseForgetsTheItemsState`: after an open failed for q1, `closeExplain` clears `explainErrors[subject]`, `explainFinal`, the surface; the engine stays in the center.
- [ ] **Step 2:** `make test-swift FILTER='AskExplainSurfaceTests|AskExplainModelTests|AskExplainTests'` → FAIL.
- [ ] **Step 3: Implement.** In `explainSpec`, the existing `dbPool.read` also runs `AskExplainSurface.legacyConversationID` when `AskExplainItem.isOnlyItem(item, of: ask)`; a found id skips `chat.new` and builds the spec with `contextID: AskExplainKey.legacyContextID(workbenchID:askID:)` (`"<wb>:<ask>"`, used only to key a found legacy chat; nothing creates one). Remove Task 3's transitional forms (`contextID(workbenchID:askID:)` becomes `legacyContextID(workbenchID:askID:)`, `title(askID:)`, `system(ask:target:)`, the `firstTurn` constant) with their last callers; `AskExplainTests.testFirstTurnIsSpecText` goes with the constant. Replace the ask-keyed state with subject-keyed state per Interfaces. `openExplain` begins `guard chats != nil, AskExplainCard.make(ask: ask, item: item) != nil else { return }`, sets `explainOpen[ask.id] = item`, and every "still open?" check becomes `explainOpen[ask.id] == item`. `offerExplainRetry(engine, item:)` passes `AskExplainPrompt.firstTurn(item)`. `closeExplain(askID)` reads the shown item first, then clears the mode and that subject's state. `FakeChatTower.askExplainWorkbenchID` splits on every `:` and applies the same rule as Go.
- [ ] **Step 4:** Same filter → PASS. Neighbours and guards: `make test-swift FILTER='OwnerAsksViewModel|EmbeddedChat|ChatTablesWriteGuardTests|SwiftDeletingRowsGuardTests|LiveSlack01GuardTests|WorkbenchesViewModelPendingDeleteTests'`; `make lint-swift`.
- [ ] **Step 5: Commit** `feat(asks): one explain chat per ask item (#2412)`.

### Task 5: The views — entries per item, strip, card, pane

**Depends on:** Task 4.

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/Asks/AskExplainEntry.swift` (per item: a question's labelled entry, a step's `?`)
- Create: `WatchtowerDesktop/Sources/Views/Workbench/Asks/AskExplainItemCard.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/Asks/AskExplainChatView.swift` (`AskExplainChatView`, `AskExplainPane`, `AskExplainStrip` take the item; the card under the strip in every pane state; placeholder per item)
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/Asks/OwnerAskDrawer.swift` (remove the whole-ask `AskExplainEntry`; `questionDraft(…)` gains `explain: ((ChatQuestion) -> Void)?`; `openExplain(_ item:)`; the chat layer passes `asks.explainItem(ask.id)`)
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/Asks/OwnerAskChecklistBody.swift` (`explain: ((AskExplainItem) -> Void)?`)
- Test: `WatchtowerDesktop/Tests/AskExplainViewTests.swift`, `WatchtowerDesktop/Tests/OwnerAskKeyNavigationTests.swift`, `WatchtowerDesktop/Tests/OwnerAskTextTests.swift` (its `questionDraft` helper gains the new argument)

**Interfaces:**
- Consumes: Task 4's `explainItem`, `openExplain(_:item:)`, `closeExplain`, `explainEngine(for:item:)`, `ensureExplainEngine(_:item:)`, `explainErrors[subject]`, `explainOffersRetry(subject)`; Task 3's `AskExplainCard`, `AskExplainCardLayout`, `AskExplainCopy`.
- Produces:
  - `struct AskExplainEntry: View { init(item: AskExplainItem, kind: OwnerAskKind, hasCLI: Bool, action: @escaping () -> Void); static func accessibilityLabel(_ item: AskExplainItem) -> String }` — a question: the labelled quiet button, trailing; a step: the icon-only quiet button with `.help(AskExplainCopy.stepEntryHelp)`; both with `.accessibilityLabel(Self.accessibilityLabel(item))` (= `AskExplainCopy.entryAccessibilityLabel(item)`); nothing when `showsEntry` is false.
  - `struct AskExplainItemCard: View { init(card: AskExplainCard) }`, `@State expanded`, height read with a `GeometryReader` preference into `AskExplainCardLayout.mode`.
  - `AskExplainPane(asks:ask:item:onBack:)`, `AskExplainChatView(ask:item:engine:error:onRetry:onBack:)`; `static func AskExplainChatView.stripLabels(_ item: AskExplainItem) -> (back: String, item: String)`.
  - `OwnerAskDrawer.questionDraft(picks:editable:onKey:fieldFocus:stop:onLeaveField:explain:)` with `explain: ((AskExplainItem) -> Void)?`; `static func OwnerAskDrawer.explainAction(for question: ChatQuestion, in ask: OwnerAsk, open: @escaping (AskExplainItem) -> Void) -> (() -> Void)?` (nil when the question is not in the ask), which the decorate closure uses.
  - `OwnerAskChecklistBody(… explain: ((AskExplainItem) -> Void)?)`, `static func OwnerAskChecklistBody.stepItem(index: Int) -> AskExplainItem` (`.step(index + 1)`).

- [ ] **Step 1: Failing tests**
  - `AskExplainViewTests.testEachQuestionGetsAnEntry`: for a 3-question ask, `AskExplainItem.forQuestion(id:in:)` maps each card question to `.question(1…3)`; a `QuestionPartView` built with `questionDraft(…, explain: { _ in })` is taller (`ViewRenderProbe.fittingHeight`, width 400) than with `explain: nil` by at least three entry heights; `explainAction(for: <2nd question>, in: ask, open:)` called records `.question(2)`; for a question not in the ask it is nil.
  - `testEachStepGetsAnEntry`: `OwnerAskChecklistBody` with `explain` set is not shorter than without and the step entry view `AskExplainEntry(item: .step(2), kind: .check, hasCLI: true)` has height > 0; `stepItem(index: 1) == .step(2)`.
  - `testNoEntriesOnReviewAsk`, `testNoEntriesWithoutACLI` (`AskExplainEntry(item:kind:hasCLI:)` height 0), `testEntriesOnAClosedAsk` (> 0 for a closed question ask and a check ask).
  - `testStripAndPlaceholderFollowTheItem`: `stripLabels(.question(2)) == ("Back to question", "Question 2")`, `stripLabels(.step(2)) == ("Back to check", "Step 2")`; `AskExplainChatView(…item: .step(2)…).composer.placeholder == "Ask about this step…"`.
  - `testCardShowsInEveryPaneState`: the pane's three states (`AskExplainPane.Shown.finding`, `.failure`, `.chat`) each lay out taller with the card than the same state without it (the pane exposes `static func showsCard(_ shown: Shown) -> Bool`, true for all three; asserted, and used by the body).
  - `testEntryAccessibilityLabelsNameTheItem`: `AskExplainEntry.accessibilityLabel(.question(2)) == "Not clear? Question 2"`, `(.step(3)) == "Not clear? Step 3"`; the visible question label stays `AskExplainCopy.entry`.
  - `testRecommendedMatchesTheQuestionCard`: `AskExplainCopy.recommended == QuestionPartView.recommendedLabel`.
  - `testCardClampsALongQuestion`: `AskExplainItemCard` for the mock's long question at width 400 → fitting height ≤ `clampHeight` + the toggle row + padding; for a short question no toggle row (height of a 2-option card < clampHeight + padding).
  - Adapt `testComposerEscapeNeverStops`, `testFirstTurnFailingBeforeStartOffersRetry`, `testItemFirstTurnFailingBeforeStartShowsItsErrorOnce` (renamed from `testFirstTurnFailingBeforeStartShowsItsErrorOnce`), `testChatViewWiresTheComposersHiddenError`, `testPaneOffersNoRetryForAGoneWorkbench`, `testOwnerSendFailingBeforeStartOffersNoRetryRow`, `testPaneShowsASpinnerWhileFindingTheChat`, `testFailureWithAReplyRowKeepsTheFeedCard`, `testQuestionLayerStaysInTree` to items; remove `testEntryHiddenOnReviewAsk` / `testEntryShownOnClosedQuestionAsk` (replaced above).
  - `OwnerAskKeyNavigationTests.testKeysOffWhileAnItemIsExplained` (renamed from `testKeysOffWhileExplaining`): with q2's chat shown, J/K/digits/⌘↩/⌘[ are not taken; after `closeExplain` they are; the existing Back/Esc tests open an item.
- [ ] **Step 2:** `make test-swift FILTER='AskExplainViewTests|OwnerAskKeyNavigationTests|OwnerAskTextTests'` → FAIL.
- [ ] **Step 3: Implement.** In `questionDraft`, `decorate` returns `VStack(alignment: .leading, spacing: Spacing.compact) { body; AskExplainEntry(item:…) }` then the existing cursor outline and id, when `explain` is set and `forQuestion` finds the item. In the checklist body, the step's text `HStack` gets `Spacer(minLength: Spacing.small)` and the step entry when `explain` is set. The drawer passes `explain` only when `AskExplainPresentation.showsEntry(kind: ask.kind, hasCLI: asks.chats != nil)`; opening keeps today's focus handling (`fieldFocus = nil`, `makeFirstResponder(nil)`) then `Task { await asks.openExplain(ask, item: item) }`. The chat layer renders `AskExplainPane(asks:, ask:, item:, onBack:)` when `asks.explainItem(ask.id)` is non-nil. `AskExplainItemCard`: content per the spec's "The chat view" §2; options in a `VStack(spacing: Spacing.tight)`, no dividers; the Recommended chip as `DesignKitChatStyle(look: .ask)` draws it (reuse its chip view if it is reachable, else `Chip(text: AskExplainCopy.recommended, color: Tone.status("blue"))` as the mockup does); the clamp with `.frame(maxHeight: clampHeight, alignment: .top).clipped().mask(LinearGradient(…))`; expanded `.expandedScrolling` wraps the content in `ScrollView` with `.frame(height: expandedMaxHeight)`; `.id(item)` on the card so expansion resets per item. Remove the strip's ask title.
- [ ] **Step 4:** Same filter → PASS; `make test-swift FILTER='OwnerAsk|AskExplain|ChatQuestionPartMacTests'`; `make lint-swift`; `make desktop-shots DESKTOP_SHOTS=<scratch>` for a first look at the drawer (Task 6 does the comparison).
- [ ] **Step 5: Commit** `feat(asks): Not clear? on each question and step, item card over the chat (#2412)`.

### Task 6: Built shots against the mockups, guide, feature note

**Depends on:** Task 5.

**Files:**
- Modify: `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+AskExplain.swift` (states per the spec's States table, per item: `items-entry`, `check-entry`, `finding`, `queued`, `loading`, `explained` (question 2), `step` (step 2), `long`, `expanded`, `busy`, `error`, `error-start`, `error-open`, `narrow`; `backScrolled` scrolls to question 3, opens and closes `.question(3)`)
- Modify: `WatchtowerDesktop/Tests/DesignShots/DesignShotsTests.swift` (doc comments; `testAskExplainBuiltShotsRender` unchanged in shape), `DesignShotCatalog.swift` comment (`#2412`)
- Modify: `docs/guide/features/workbench/asks.md` ("Ask the assistant what a question means" and its learn card text: "under each question or step"; troubleshooting line for "No Not clear?"), within `go test ./docs/guide`'s size cap — replace sentences, do not add a section
- Modify: `docs/features/ask-explain-chat.md` (item ids, legacy chats, the card, per-subject state, the shot comparison), `docs/features/README.md` (its summary line), `CLAUDE.md` (the feature list line names "on each question or step")

- [ ] **Step 1:** Rewrite the built fixtures as listed; the `expanded` state presses **Show more** through the card's state (a test seam `AskExplainItemCard(card:, startsExpanded: true)` used by shots only, or the view's `@State` initial value from an argument with default `false`).
- [ ] **Step 2:** `cd WatchtowerDesktop && DESKTOP_SHOTS_DIR=<scratch> swift test --filter 'DesignShotsTests/testAskExplainBuiltShotsRender'` → PASS, including the `back-scrolled` offset assertion.
- [ ] **Step 3:** Open each built PNG beside its mockup (light and dark) in `docs/design/mockups/ask-explain-per-item/`; fix any difference in layout, copy or colour in the views, or record a justified one in the feature note's "Built views against the mockups" (the drawer's real header and answer bar, ChatUI's bubbles and composer carry over from 2026-11-24). `back-scrolled` must show question 3 where it was.
- [ ] **Step 4:** Guide, learn card, feature note, README summary, CLAUDE.md line; `go test ./docs/guide`; `go test ./internal/learn` (the card validator).
- [ ] **Step 5:** `make test-swift FILTER=DesignShotsTests`; `make lint-swift`.
- [ ] **Step 6: Commit** `docs(asks): per-item Not clear? — built shots, guide, feature note (#2412)`.

---

## Gate (controller, once, after Task 6)

`make test`, `make test-swift`, `make lint-all` (includes `make gen-interface-check`, which must pass with no regeneration), `go test ./cmd/...`, `scripts/leak-check.sh`, and every other job in `.github/workflows/*.yml` by its own command. Guard suites named in this plan are inside these runs; a job that cannot run locally is named in the report.

## Parallel lanes

- **Lane B:** Task 2 (Go only).
- **Lane C:** Task 3, then Task 4, then Task 5 (each needs the one before; Task 3 keeps the old forms so its commit builds).
- Task 6 after Lane C. Lane B can merge any time before the gate. Task 1 has nothing left.

Each lane runs in its own worktree (memory: per-worktree `.build` copy; no phone changes, so no DerivedData concern).
