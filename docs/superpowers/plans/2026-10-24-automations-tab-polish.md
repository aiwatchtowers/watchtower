# Automations Tab Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship six changes to the Automations tab:

- a list panel shaped like the Chats panel, with collapsible groups and three-line rows;
- a `summary` short description in recipes;
- plain-language cards for the built-in automations;
- a draft save that removes the draft row and carries the draft's chat over;
- a toggle that hides the draft column;
- a smoother editor chat, plus more read tools for the editor chat.

**Architecture:** Go adds the `summary` recipe key and the built-in card fields `does` and `result_filter`. It also adds five new read tools and widens the surfaces of fourteen existing reads, which leaves `automation_editor` with one write. Swift does three things:

- computes each row's summary and compact state in WatchtowerCore;
- rebuilds the list on the shared panel modifiers (`panelSurface`, `panelTab`, `sidebarSectionLabel`);
- moves the draft's conversation to the saved automation on save.

**Tech Stack:** Go 1.26 (goose-free: no migration), SwiftUI macOS 14, GRDB, WatchtowerCore tests.

**Spec:** `docs/superpowers/specs/2026-10-24-automations-tab-polish-design.md` (approved, ask #529; decisions in ask #527, ask #528)

## Global Constraints

- **`summary` key:**
  - optional;
  - one line, at most **60 runes**;
  - **not** part of `approvalCanonical`.
- **Summary fallback:** the description's first sentence, cut to 60 runes on a word boundary, plus "…". The Go and Swift rules must agree.
- **`automation_editor` writes:** `save_automation` stays the only write tool. Every new tool is `tools.AccessRead`.
- **New tools are not visible on `automation`:**
  - `list_automation_runs`, `get_automation_run`, `list_automations`, `get_automation`;
  - `list_slack_channels` is on `main` and `automation_editor` only.
- **No Quick Connections on `automation_editor`.** D11 stands.
- **No scope filter on the new tools.** They read any of the owner's automations and runs, except removed ones.
- **App copy is English.** The Russian in the mockup is sample text only.
- **UserDefaults keys:**
  - `automations.collapsedSections` (an array of section ids);
  - `automations.draftColumnHidden` (Bool).
- **Shortcut:** ⌥⌘0 toggles the draft column. It is active only on the Automations tab.
- **Checks:**
  - Go tasks run `go test ./<touched pkg>` and `make lint-diff`.
  - Swift tasks run `make test-swift FILTER=…` and `make lint-swift`. `lint-diff` is Go-only.
  - Swift UI tasks run `make desktop-shots DESKTOP_SHOTS=<dir>` before review.
- **Repo hygiene:** sample names only (`acme`, `example.com`). No live data.
- **Review rules:** `docs/review/review-rules.md`, Swift / Desktop conventions.

## Review Focus

- **A recipe saved through the Form or Script editor keeps its `summary`.** Expected: `RecipeFrontmatter` round-trips it untouched. Pinned in Task 6.
- **The selected automation sits in a collapsed group** (opened from the Inbox, a notification or auto-select). Expected: the group opens and the row shows selected. Pinned in Task 7.
- **A `save_automation` approval lands while the draft's turn is still streaming.** Expected: no second engine on the conversation, the reply finishes, then the chat moves. Pinned in Task 9.
- **Search hides every row of a collapsed group, or matches only inside one.** Expected: groups with a match show expanded during the search, and the stored collapse set is unchanged afterwards. Pinned in Task 7.
- **`get_automation_run` on a run with a huge step result or an output with external text.** Expected: capped fields, returned as data, never a panic or an unbounded payload. Pinned in Task 3.

---

## Lanes

The tasks run in these lanes:

- **Lane Go:** T1 → T2 → T3 → T4 → T5, in order. They are in the same packages and share the registry test.
- **Lane Swift-A:** T6 → T7 (list).
- **Lane Swift-B:** T8. It depends on T2's JSON keys, so it starts once T2 is merged into the branch.
- **Lane Swift-C:** T9 → T10.
- **Lane Swift-D:** T11 (scroll).

T12 (docs) runs last. Lanes run in their own worktrees and the controller merges them.

---

### Task 1: `summary` recipe key (Go) + built-in summaries + authoring guidance

**Files:**
- Modify: `internal/automations/recipe.go`. Add `Summary` to the `Recipe` struct (lines 123–137), add it to `topLevelKeys` (line ~287), and add an `applySummary` call in `applyFields`. Add the `maxSummaryRunes = 60` constant beside `maxNameRunes`.
- Create: `internal/automations/summary.go`, which holds `FallbackSummary(description string) string`.
- Modify: the four files in `internal/automations/builtin/recipes/*.md`. Add a `summary:` line after `name:`.
- Modify: `internal/skills/shipped/create-automation.md`, and the editor rules block in `WatchtowerDesktop/Sources/Services/ChatSurfaces/AutomationEditorChatSurface.swift` (`rulesBlock`). The new instruction is: "Always write `summary:` — a few words on what it does, not when, at most 60 characters."
- Test: `internal/automations/recipe_test.go`, `internal/automations/hash_test.go` and `internal/automations/builtin/registry_test.go`.

**Interfaces:**
- Produces: `Recipe.Summary string`, `automations.MaxSummaryRunes = 60` (exported) and `automations.FallbackSummary(desc string) string`.

- [ ] **Step 1: Write the failing tests.**
  - `TestParseRecipe_Summary`: `summary: Your brief and day plan` parses into `Summary`.
  - `TestParseRecipe_SummaryTooLong`: 61 runes → `*ParseError` with the key's line and a message containing `summary` and `60`.
  - `TestParseRecipe_SummaryMultiline`: a block scalar with two lines → `*ParseError`.
  - `TestApprovalHash_IgnoresSummary`: two recipes that differ only in summary → equal `ApprovalHash`.
  - `TestFallbackSummary`: `"Every morning, writes your brief. Then plans."` → `"Every morning, writes your brief."`; a 100-rune first sentence → at most 61 runes, ending in "…", cut at a space; `""` → `""`.
  - `TestBuiltinRecipes_HaveSummary`: every registry entry's parsed recipe has a non-empty `Summary` of 60 runes or fewer.
- [ ] **Step 2: Run** `go test ./internal/automations/ ./internal/automations/builtin/`. Expected: FAIL (undefined `Summary`).
- [ ] **Step 3: Implement.**
  - The key is a string; trim the whitespace; reject `\n`; reject more than `MaxSummaryRunes` runes.
  - The first sentence ends at the first `. `, `! ` or `? `, or at the end of the text.
  - Built-in summaries:
    - morning-brief: "Your brief and day plan"
    - track-my-threads: "Slack threads waiting on you"
    - idea-finder: "Ideas and decisions from your talk"
    - reactions: "A Slack emoji turns into an action"
- [ ] **Step 4: Run** the same packages, then `go test ./cmd/ -run 'Builtin|Automation'`. The shipped hash changes, so update any pinned shipped-hash fixture with `-update` where the test offers it, and check that `upgrade-builtins` and `TestUpgrade…` stay green. Expected: PASS.
- [ ] **Step 5: Commit** `feat(automations): optional summary key, not in the approval hash; built-ins ship one`.

### Task 2: Built-in card `does` + `result_filter` + copy rewrite (Go)

**Files:**
- Modify: `internal/automations/builtin/registry.go`. Add `Entry` fields `Does []string` and `ResultFilter string`. Rewrite the `Reads` / `Sends` copy for all four entries.
- Modify: `internal/automations/builtin/card.go`. Add `CardInfo` fields `Does []string \`json:"does"\`` and `ResultFilter string \`json:"result_filter"\``.
- Modify: `internal/automations/builtin/testdata/show_morning_brief.json`, which the Desktop reads too.
- Test: `internal/automations/builtin/card_test.go`, or the existing card test file.

**Interfaces:**
- Produces: the JSON keys `does` (array, never null) and `result_filter`, one of `day|tracks|ideas|automations`.

- [ ] **Step 1: Write the failing tests.**
  - `TestCard_DoesAndResultFilter`: for every registry entry, `Card(...)` has `len(Does) >= 1` and `ResultFilter` is in `{"day","tracks","ideas","automations"}`.
  - Morning brief's `ResultFilter == "day"`, Track my threads → `"tracks"`, Idea finder → `"ideas"`, Reactions → `"automations"`.
  - The golden test for `show_morning_brief.json` fails until it is regenerated.
- [ ] **Step 2: Run** `go test ./internal/automations/builtin/`. Expected: FAIL.
- [ ] **Step 3: Implement.** Use plain copy: Reads is a short list of sources, Does is the steps in order, Sends is where the result lands. Example for Morning brief: Does = `["Writes your brief: what changed, what is urgent, who waits on you", "Plans your day around your meetings from that brief"]`.
- [ ] **Step 4: Run** with `-update` once for the golden file, then without it, plus `go test ./cmd/ -run Show`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(automations): built-in card says what it does and where the result lands`.

### Task 3: `list_automation_runs` / `get_automation_run` read tools (Go)

**Files:**
- Create: `internal/automations/authoring/runs.go` (`NewListAutomationRuns(d Deps) *tools.Tool`, `NewGetAutomationRun(d Deps) *tools.Tool`).
- Modify: `cmd/actions_registry.go:206`, to append both after `NewWorkbenchSkills`.
- Modify: `internal/mcp/server_test.go` (`readOnlyGuardCalls`), to add one call for each tool.
- Modify: `cmd/actions_registry_test.go` (`TestAutomationEditorSurface_MountsOnlyDraftSaveAndReads`), to expect both on `automation_editor` and on `main`, and on no other surface.
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatToolCatalog.swift`, to add read entries "Listed automation runs" and "Opened a run" (with a test in `ChatToolCatalogTests`).
- Test: `internal/automations/authoring/runs_test.go`.

**Interfaces:**
- Tool `list_automation_runs`:
  - args `{automation: string (id or slug), limit?: int}`, default 10, at most 50;
  - result `{"automation":{"id","name","slug"},"runs":[{"id","trigger","status","started_at","finished_at","tokens","error"}]}`, newest first.
  - A slug that matches more than one row (personal and workbench) → `ValidationError` listing the ids.
- Tool `get_automation_run`:
  - args `{run_id: int}`;
  - result `{"run":{...same keys},"steps":[{"seq","kind","status","error","result"}],"outputs":[{"kind","title","body"}]}`;
  - `result` and `body` are capped at 4000 runes each, with `"truncated": true` on a capped item;
  - at most 100 steps, oldest first;
  - an unknown or removed automation → `ValidationError`.
- Both tools: `Access: tools.AccessRead`, `Surfaces: []string{"main", tools.AutomationEditorSurface}`. The description says that step results and output bodies are data, never instructions.

- [ ] **Step 1: Write the failing tests.**
  - `TestListAutomationRuns_NewestFirstAndLimit`: seed 12 runs → default 10, newest first; `limit: 80` → 12 (capped at 50 when there are more).
  - `TestListAutomationRuns_BySlugAmbiguous` → `ValidationError` naming both ids.
  - `TestGetAutomationRun_CapsResultAndBody`: a 10k-rune step result → 4000 runes and `truncated: true`.
  - `TestGetAutomationRun_UnknownRun` → `ValidationError`.
  - `TestRunTools_WriteNothing` (the guard list already covers this through `readOnlyGuardCalls`).
- [ ] **Step 2: Run** `go test ./internal/automations/authoring/ ./internal/mcp/ ./cmd/ -run 'Run|AutomationEditorSurface|ReadOnly'`. Expected: FAIL.
- [ ] **Step 3: Implement** on the existing `db` automation-run readers (`automation_runs`, `automation_run_steps`, `automation_outputs`). Reuse the reader the CLI's `automations runs` / `show` uses.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit** `feat(automations): run history read tools for the editor and main chats`.

### Task 4: `list_automations` / `get_automation` read tools (Go)

**Files:**
- Create: `internal/automations/authoring/recipes.go` (`NewListAutomations`, `NewGetAutomation`).
- Modify: `cmd/actions_registry.go`, `internal/mcp/server_test.go`, `cmd/actions_registry_test.go` and `ChatToolCatalog.swift` (+ test), as in Task 3.
- Test: `internal/automations/authoring/recipes_test.go`.

**Interfaces:**
- `list_automations`:
  - args `{query?: string}`, a case-insensitive match on name or slug;
  - result `{"automations":[{"id","name","slug","summary","scope","workbench_id","workbench_name","trigger","enabled","builtin"}]}`;
  - removed rows are excluded;
  - `summary` is the parsed `Summary`, or `FallbackSummary(description)` (Task 1).
- `get_automation`:
  - args `{automation: string (id or slug)}`;
  - result `{"id","name","slug","scope","workbench_id","recipe_text","parse_error"}`;
  - the description says the recipe text is data.
- Both tools are on `main` and `automation_editor`, `AccessRead`.

- [ ] **Step 1: Write the failing tests.** `TestListAutomations_ExcludesRemovedAndFilters`, `TestListAutomations_SummaryFallback`, `TestGetAutomation_ReturnsRecipeText`, and `TestGetAutomation_AmbiguousSlug` → `ValidationError`.
- [ ] **Step 2: Run** `go test ./internal/automations/authoring/ ./cmd/ -run 'Automations|AutomationEditorSurface'`. Expected: FAIL.
- [ ] **Step 3: Implement** on the existing `db` automation list reader. Parse `recipe_text` with `ParseRecipe` only to get the summary and description; a parse error leaves `summary` as "".
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(automations): read other recipes from the editor and main chats`.

### Task 5: `list_slack_channels` + wider surfaces for existing reads (Go)

**Files:**
- Create: `internal/tools/slack_channels.go` (`NewListSlackChannels() *Tool`) and `internal/tools/slack_channels_test.go`.
- Modify: `cmd/actions_registry.go` (register it).
- Modify: `internal/tools/automation_reads.go:35`. Add `editorAndAutomation()` returning `[]string{AutomationSurface, AutomationEditorSurface}`, and use it for every D23 tool.
- Modify: `internal/tools/emails.go:65,108` and `internal/tools/linear_read.go:569`, to use the same pair.
- Modify: `internal/tools/confluence_page.go:411`, to `[]string{"main", "target", AutomationEditorSurface}`, and `confluence_page_test.go:151` to match.
- Modify: `internal/mcp/server_test.go`, `cmd/actions_registry_test.go` and `ChatToolCatalog.swift` (+ test, "Listed Slack channels").

**Interfaces:**
- `list_slack_channels`:
  - args `{query?: string, account?: string, include_archived?: bool}`;
  - result `{"channels":[{"id","account","name","type","is_member","is_archived","num_members","last_activity"}]}`, from the local `channels` table;
  - `last_activity` is the newest synced message time, or "";
  - sorted by last activity, newest first; at most 500 rows; no network;
  - `Surfaces: []string{"main", AutomationEditorSurface}`.

- [ ] **Step 1: Write the failing tests.**
  - `TestListSlackChannels_SortedAndFiltered`: seed channels on two accounts; `query` matches the name case-insensitively; archived ones are excluded unless `include_archived`.
  - `TestListSlackChannels_NotOnAutomationSurface`: `Surfaces` does not contain `AutomationSurface`.
  - `TestAutomationEditorSurface_MountsOnlyDraftSaveAndReads` now expects the 13 D23/email/cycle reads, `get_confluence_page`, `list_slack_channels` and Tasks 3–4's four tools. It still asserts that `save_automation` is the only write and that no Quick Connection is mounted.
  - The `main` surface does not gain the 13 automation-only reads (assert one of them, `list_inbox`, is absent on `main`).
- [ ] **Step 2: Run** `go test ./internal/tools/ ./internal/mcp/ ./cmd/ -run 'Slack|AutomationEditorSurface|Confluence|ReadOnly|Manifest'`. Expected: FAIL.
- [ ] **Step 3: Implement.** Check that the automation manifest gate (`TestManifest_*`) is untouched: it keys on the `automation` surface only.
- [ ] **Step 4: Run** the same command, plus `go test ./internal/automations/`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(automations): editor chat reads what a recipe reads, Slack channels and Confluence`.

### Task 6: Row presentation in WatchtowerCore (summary, compact state, collapse model)

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/AutomationRowSummary.swift`.
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/AutomationListSections.swift`. Add `AutomationRowPresentation.state(_:now:)` and `.summary(_:)`, and the `attention` suffix on `AutomationListSection`.
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/AutomationListCollapse.swift`.
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/RecipeFrontmatter.swift`, to read `summary` and write it back unchanged.
- Test: `WatchtowerDesktop/Tests/Core/AutomationRowSummaryTests.swift`, `AutomationListCollapseTests.swift`, and the existing `RecipeFrontmatterTests`.

**Interfaces:**
- `package enum AutomationRowSummary { static let maxRunes = 60; static func summary(recipeText: String) -> String?; static func fallback(description: String) -> String }`. It returns the `summary:` value, else the fallback of the body description, else nil. The fallback rule is Go's `FallbackSummary`, copied exactly (Task 1).
- `package enum AutomationRowState: Equatable { case chip(AutomationRowChip), failed, off, lastRun(ok: Bool, ago: String), next(String), none }` and `AutomationRowPresentation.state(_ item: AutomationListItem, now: Date) -> AutomationRowState`. The precedence is: chip > failed > off > last run > next run > none.
- `AutomationListSection.attention: String?`: "1 failed" / "1 draft" / "1 needs confirmation", joined by " · ", or nil.
- `package struct AutomationListCollapse: Equatable { var collapsed: Set<String>; func isExpanded(_ id: String, searching: Bool, hasMatch: Bool) -> Bool; mutating func toggle(_ id: String); mutating func reveal(_ id: String) }`. `reveal` removes the id from `collapsed`. `isExpanded` is true when searching and the section has a match, otherwise `!collapsed.contains(id)`.

- [ ] **Step 1: Write the failing tests.**
  - `testSummaryFromFrontmatter`.
  - `testFallbackMatchesGoCases`: the same three inputs and outputs as Go's `TestFallbackSummary`.
  - `testNoDescriptionIsNil`.
  - `testStatePrecedence`: a Draft chip beats failed; failed beats off; off beats last run.
  - `testAttentionSuffix`.
  - `testCollapseSearchExpandsWithoutChangingStore`.
  - `testRevealOpensCollapsedGroup`.
  - `RecipeFrontmatterTests.testRoundTripKeepsSummary`.
- [ ] **Step 2: Run** `make test-swift FILTER='AutomationRowSummaryTests|AutomationListCollapseTests|RecipeFrontmatterTests'`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same command. Expected: PASS. Then run `make lint-swift`.
- [ ] **Step 5: Commit** `feat(desktop): automation row summary, compact state and group collapse model`.

### Task 7: List panel like Chats (Swift view)

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Automations/AutomationsView.swift` (`listColumn`, lines ~112–180).
- Modify: `WatchtowerDesktop/Sources/Views/Automations/AutomationListRow.swift`, to the three-line rows on `panelTab(isSelected:)`.
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/AutomationsViewModel.swift`. Add a `collapse: AutomationListCollapse` property, persisted to `automations.collapsedSections`, and call `reveal` from `select` / `showEditor` when the target's section is collapsed.
- Test: `WatchtowerDesktop/Tests/Core/AutomationsViewModelTests.swift`.

**Interfaces:**
- Consumes: Task 6's types.
- `AutomationsViewModel.toggleSection(_ id: String)`, `AutomationsViewModel.collapse`, and `AutomationsViewModel.sectionID(forAutomation:) -> String?`.

**Layout:**
- The left column gets `panelSurface()`. The selected row uses `.panelTab(isSelected:)`.
- Section headers use `sidebarSectionLabel()`, upper case, with the chevron, the count and the `attention` suffix.
- The list is a plain `List` with `.clearPlainList()`, with no List selection, as in `ChatSidebarView`.
- The "New automation" row is removed; the header's **+** stays.
- Row lines:
  1. The dot, the name, then a trailing chip or the state text: `failed` in `Tone.warning`, otherwise secondary.
  2. The summary, secondary, `lineLimit(1)`, omitted when nil.
  3. `AutomationRowPresentation.line`, caption, `lineLimit(1)`, in `Tone.warning` when the state is `.failed`.

- [ ] **Step 1: Write the failing tests.**
  - `testSelectingInCollapsedSectionRevealsIt`.
  - `testCollapsePersistsAcrossInit`: through an injected `UserDefaults(suiteName:)`.
  - `testSearchDoesNotWriteCollapse`.
- [ ] **Step 2: Run** `make test-swift FILTER=AutomationsViewModelTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the view model, then the view.
- [ ] **Step 4: Run** the tests, `make lint-swift` and `make desktop-shots DESKTOP_SHOTS=<scratch dir>`. Compare against the mockup's board 1 and board 3. Expected: PASS, and the screenshots match.
- [ ] **Step 5: Commit** `feat(desktop): automations list shaped like Chats with collapsible groups`.

### Task 8: Built-in card description (Swift)

**Depends on:** Task 2 (`does`, `result_filter` in the shared testdata).

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/AutomationsCLI.swift:760–800`. Decode `does` (default `[]`) and `resultFilter` (`result_filter`, default `""`).
- Modify: `WatchtowerDesktop/Sources/Views/Automations/BuiltinAutomationCard.swift`. Put the lede (the recipe description, parsed from `shippedText` or the owner's copy) under the header, then a three-column grid of **Reads** / **Does** / **Result**. Result has a "Show in Inbox" link calling the new `BuiltinCardActions.openInbox(InboxFilter)` → `AppState.openInbox(InboxRoute(filter:selection: nil))`.
- Test: the existing decode test over `show_morning_brief.json` (`AutomationsCLITests` or `BuiltinAutomationCardModelTests`).

**Interfaces:**
- `BuiltinCardInfo.does: [String]` and `BuiltinCardInfo.resultFilter: InboxFilter?`. An unknown string maps to nil and the link is hidden.

- [ ] **Step 1: Write the failing test.** `testDecodesDoesAndResultFilter`: from the shared testdata, `does.count >= 1` and `resultFilter == .day`.
- [ ] **Step 2: Run** `make test-swift FILTER='AutomationsCLITests|BuiltinAutomationCardModelTests'`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the tests, `make lint-swift` and `make desktop-shots`. Compare against the mockup's board 2. Expected: PASS.
- [ ] **Step 5: Commit** `feat(desktop): built-in card says what it reads, does and where the result lands`.

### Task 9: Draft save removes the row and carries the chat over (Swift)

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/Embedded/EmbeddedChatStore.swift`. Add `rekeyConversation(dbPool:conversationID:toContextType:contextID:) async throws -> Bool`.
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/AutomationsViewModel.swift`. Add `draftSaved(contextID: String, conversationID: Int64, automationID: Int64) async`.
- Modify: `WatchtowerDesktop/Sources/Views/Automations/AutomationEditorPanel.swift` (`finish`, lines ~570–574, and `settleUnwatched`'s path in `AutomationEditorCenter`), so that every save path of a `.newDraft` calls `draftSaved`.
- Modify: `EmbeddedChatCenter`. Add `release(key:) async`, which waits for the engine to go idle and then drops it.
- Test: `WatchtowerDesktop/Tests/Core/AutomationDraftSaveTests.swift`.

**Interfaces:**
- `rekeyConversation` runs one `UPDATE chat_conversations SET context_type=?, context_id=?, updated_at=? WHERE id=? AND context_type='automation_draft'`. It runs **only** when no `('automation', <id>)` conversation with messages exists. An empty one is deleted first, in the same write transaction. It returns `true` when the row moved.
- `draftSaved` does the following, in this order:
  1. await `EmbeddedChatCenter.release(key:)` for the draft's key;
  2. call `rekeyConversation`;
  3. remove the cache file (`AutomationDraftEntry.cacheURL`), treating a missing file as fine;
  4. drop the row from `draftRows`;
  5. never call `select(nil)`.

  The panel then calls `onSaved(id)` as today. `AutomationEditorChatSurface.conversationID(for:)` then finds the moved conversation.

- [ ] **Step 1: Write the failing tests.**
  - `testSavedDraftRowLeavesTheList`: this reproduces the bug. A draft row exists and the save lands → `draftRows` is empty and the cache file is gone.
  - `testSavedDraftConversationBecomesAutomationChat`: after `draftSaved`, `conversationID(contextType:"automation", contextID:"<id>")` equals the draft's conversation id, and its messages are intact.
  - `testRekeyKeepsExistingNonEmptyAutomationChat`: it returns `false`, and the draft is only unlisted.
  - `testReleaseWaitsForStreamingTurn`: a fake engine is busy; `release` returns only after it goes idle.
  - `testFailedSaveKeepsDraft`: no `draftSaved` call, and the row stays.
- [ ] **Step 2: Run** `make test-swift FILTER=AutomationDraftSaveTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Keep the write transaction short, with no file I/O inside it.
- [ ] **Step 4: Run** the tests plus `make test-swift FILTER='AutomationEditorCenterTests|EmbeddedChatCenterTests'` and `make lint-swift`. Expected: PASS.
- [ ] **Step 5: Commit** `fix(desktop): a saved draft leaves the list and its chat becomes the automation's chat`.

### Task 10: Draft column toggle (Swift)

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Automations/AutomationEditorPanel.swift`. Add `@AppStorage("automations.draftColumnHidden") private var draftHidden = false` and a header icon button (`sidebar.right`, `.kitIcon(isOn: !draftHidden)`, help "Hide Draft" / "Show Draft", `.keyboardShortcut("0", modifiers: [.option, .command])`). When the column is hidden and `editor.canSave(key)`, a `.kitPrimary` "Save…" button appears and sets `draftHidden = false`.
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/AutomationDraftFooter.swift`. Add a pure `showsCompactSave(hidden: Bool, canSave: Bool) -> Bool`.
- Test: `WatchtowerDesktop/Tests/Core/AutomationDraftFooterTests.swift`.

- [ ] **Step 1: Write the failing test.** `testCompactSaveOnlyWhenHiddenAndSavable`, covering all four combinations.
- [ ] **Step 2: Run** `make test-swift FILTER=AutomationDraftFooterTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** The shortcut lives in the panel, so it is active only while the editor shows.
- [ ] **Step 4: Run** the tests, `make lint-swift` and `make desktop-shots`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(desktop): hide and show the automation draft column`.

### Task 11: Editor chat scroll (measure, then fix)

**Files:**
- Read and profile: `WatchtowerDesktop/Sources/Views/Chat/ChatFeedView.swift`, `MarkdownView.swift`, `Embedded/EmbeddedChatView.swift` and `Views/Automations/AutomationEditorPanel.swift` (`chatPane`, `chatFooter`, `proposals`).
- Expected modify (adjust to what the profile shows): `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/MarkdownDocument.swift`, to memoise inline `AttributedString` per block and per table cell, keyed by the block's text, beside the existing parse memo. Also `EmbeddedChatView.swift`, to replace the per-row `messages.map` / `firstIndex` with one index map built per pass.
- Test: `WatchtowerDesktop/Tests/Core/MarkdownDocumentTests.swift` (memo hit, and the same output as unmemoised, including `AllowedURLSchemes` stripping).

- [ ] **Step 1: Profile.** Use a 100-message editor thread with long markdown answers (a debug seed or an existing conversation copied into a scratch DB; never the live DB). Run Instruments with SwiftUI + Time Profiler, scrolling a static thread and scrolling while a turn streams, and compare with the main chat at the same length. Save both traces' top frames to a scratch note.
- [ ] **Step 2: Write the failing tests** for the chosen fix. For the memo: `testInlineAttributedMemoHitsAndMatches`, and `testDisallowedLinksStillStrippedFromMemo`.
- [ ] **Step 3: Run** `make test-swift FILTER=MarkdownDocumentTests`. Expected: FAIL.
- [ ] **Step 4: Implement** the fix the profile justifies. If (d) dominates (the panel re-evaluation), give `EmbeddedChatView` stable accessory and footer inputs: `Equatable` value inputs instead of closures.
- [ ] **Step 5: Re-profile and run** the tests, plus `make test-swift FILTER='ChatFeed|ChatMessageRow|Markdown'` and `make lint-swift`. Expected: PASS, with the before and after numbers in the commit body.
- [ ] **Step 6: Commit** `perf(chat): <what the profile showed>` (in the main chat and embedded chats).

### Task 13: Native text for finished chat messages (owner, ask #539)

**Depends on:** Task 11 (lane-swd: memo, index, `ChatScrollBenchmarkTests`).

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Chat/MarkdownTextRun.swift` — `NSViewRepresentable` around a non-editable, selectable TextKit 2 `NSTextView`, sized with `sizeThatFits(_:nsView:context:)`.
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/MarkdownRunBuilder.swift` — a pure function from the parsed blocks to `[MarkdownSegment]` (`.textRun(NSAttributedString)` or `.block(MarkdownBlock)`). It applies the same fonts, colours and paragraph styles as `MarkdownView` today, plus the `AllowedURLSchemes`-gated links. It is memoised the same way as the Task 11 inline memo.
- Modify: `Views/Chat/MarkdownView.swift` (finished messages use the segments; a streaming message keeps the current path), `Views/Chat/ChatMessageRow.swift` (pass `isComplete`), and the tables view (a horizontal scroll view only when the table is wider than the column).
- Modify: `Views/Chat/ChatSelectionQuote.swift`, to read the selection from a run's `NSTextView` (its `selectedRange()` / `firstRect(forCharacterRange:)`).
- Test: `Tests/Core/MarkdownRunBuilderTests.swift` covers segmenting, styles, the link gate and the memo. The app-target tests cover `MarkdownTextRun` link clicks routing (`openNavLink`, allowed schemes) and selection quoting.

**Interfaces:**
- `package enum MarkdownSegment: Equatable { case textRun(NSAttributedString, id: Int), block(MarkdownBlock) }`.
- `package enum MarkdownRunBuilder { static func segments(_ doc: MarkdownDocument, style: MarkdownRunStyle, links: InlineLinkContext) -> [MarkdownSegment] }`.

- [ ] **Step 1:** Capture before screenshots (main chat and the editor chat, light and dark) and the benchmark baseline (`WT_BENCH=1`, p50/p90 step, selectable-text share).
- [ ] **Step 2: Write the failing tests:**
  - `testProseBetweenCodeBlocksIsOneRun`;
  - `testHeadingAndListStylesMatchCurrent`;
  - `testDisallowedLinkNotClickableInRun`;
  - `testNavLinkRoutesToOpenNavLink`;
  - `testSelectionQuoteReadsRunSelection`;
  - `testTableFitsWidthHasNoScrollView`.
- [ ] **Step 3: Run** `make test-swift FILTER='MarkdownRunBuilderTests|MarkdownTextRunTests|ChatSelectionQuote'`. Expected: FAIL.
- [ ] **Step 4: Implement.** Streaming messages keep the old path, and switch on completion without a visible jump.
- [ ] **Step 5: Run** the tests, plus `make test-swift FILTER='ChatFeed|ChatMessageRow|Markdown|ChatQuestion|AllowedURLSchemes|EmbeddedChat|ChatThread|ChatSelection'`, `make lint-swift`, the benchmark and the after screenshots. Expected: PASS. The selectable-text share drops clearly, and the before/after numbers and screenshots go in the report.
- [ ] **Step 6: Commit** `perf(chat): finished answers draw prose with one native text view per run`.

### Task 14: Finished tables as one native text view (owner, ask #541)

**Depends on:** Task 13 (merged: `MarkdownTextRun`, `NativeMarkdownView`, `MarkdownSegmentsView`, the gated link Coordinator, the run sizing rules, `ChatScrollBenchmarkTests` with the timed run-loop pass).

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Chat/MarkdownTableText.swift`, which draws a table block as one read-only, selectable `NSTextView`. It uses `NSTextTable`/`NSTextTableBlock` (TextKit 1 is allowed for this view if TextKit 2 cannot draw table blocks; say which and why). It reuses the run view's link Coordinator, sizing and menu rules.
- Modify: `MarkdownSegmentsView` (a finished answer's `.block(.table)` uses the new view) and `ChatSelectionQuote.swift` (a table selection quotes).
- Test: `MarkdownTableTextTests`. It covers:
  - copy as TSV;
  - selection across cells;
  - the link gate in a cell;
  - a fitting table has no scroll view and a wide one has one;
  - the probe-width rule;
  - height parity with today's table at 760 and 320 pt.

- [ ] **Step 1:** Capture the before benchmark (timed run-loop pass) and light/dark screenshots of a table answer.
- [ ] **Step 2: Write the failing tests** listed above.
- [ ] **Step 3: Run** `make test-swift FILTER='MarkdownTableTextTests'`. Expected: FAIL.
- [ ] **Step 4: Implement.**
- [ ] **Step 5: Run** the tests, plus `make test-swift FILTER='TextRenderingBenchmarkTests|MarkdownTextRunTests|MarkdownRunBuilderTests|Markdown|ChatSelection|ChatFeed|ChatMessageRow'` (the streamed-delta guard 3×), `make lint-swift`, the benchmark and the after screenshots. Expected: PASS, with the numbers in the report.
- [ ] **Step 6: Commit** `perf(chat): a finished answer's table is one native text view`.

### Task 12: Docs, inventory note, guide

**Files:**
- Modify: `docs/features/automations.md`, covering:
  - the list panel and groups;
  - `summary`;
  - the built-in card fields;
  - the draft carry-over;
  - the column toggle;
  - the editor's new reads.
- Modify: `docs/features/built-in-automations.md` (`does` / `result_filter`).
- Modify: `docs/inventory/agent-actions.md`. Add a dated AGENT-04 note: more reads were added on `automation_editor`, `save_automation` is still the only write, there are no Quick Connections, and no guard was relaxed.
- Modify: `docs/guide/features/automations-recipes.md`. Add what the editor chat can look at, the short description, the hidden draft column (⌥⌘0), and collapsible groups. Respect the 8 KB cap and `docs/guide/WRITING.md`.

- [ ] **Step 1: Edit** the files above.
- [ ] **Step 2: Run** `go test ./docs/guide/`. Expected: PASS.
- [ ] **Step 3: Commit** `docs(automations): tab polish — list, summary, built-in cards, editor reads`.

---

**Phase gate (controller, once, after all lanes merge):** `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`, then the PR into `main`.
