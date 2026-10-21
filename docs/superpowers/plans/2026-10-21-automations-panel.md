# Automations in the panel — Implementation Plan (spec part A)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every Automations flow — New, template, edit, save and confirm — happens in place in the tab's right panel; the first step is choosing what the automation is for; the chat is the default way to create and edit; **Save and Turn On** is the main action.

**Architecture:** Two additive CLI changes give the Desktop what it must show before confirming (`validate --json` gains `changes`/`changes_known`; `install-template --render` prints the rendered text and its validation without writing, and `install-template --json` gains each installed copy's `approval_hash`). In WatchtowerCore, `AutomationsViewModel` gains a panel route, `AutomationEditorCenter` becomes the in-panel save engine (debounced `validate`, direct `save --confirm-hash` + `enable`, no sheet), and two new models build the draft column and the template panel. The views are rebuilt from the Desktop kit on a `PanelSplit`; every Automations sheet but the delete dialog and the `confirm: true` run prompt is removed.

**Tech Stack:** Go 1.26 (`cmd`, `internal/skills`), SwiftUI + WatchtowerCore (macOS 14), Desktop design kit (`WatchtowerDesktop/Sources/DesignKit/`).

**Spec:** `docs/superpowers/specs/2026-10-21-automations-panel-and-inbox-design.md` — this plan covers **part A only** (A1–A7), the AUTO-06 amendment of B4 that concerns A, the `create-automation` skill change of A4, the user guide and `docs/features/automations.md`. Part B (Inbox) has its own plan; nothing here touches `automation_outputs`, the Inbox views or STRIP-01/02.

## Global Constraints

- **No sheet in the Automations flow.** Remaining modal UI: the Delete… confirmation dialog and `QuickRunConfirmSheet` (the `confirm: true` "Run “<name>”?" prompt — a short blocking flow the style guide allows). Removed: `NewAutomationSheet`, `AutomationTemplateGalleryView`, `AutomationConfirmSheet`, `AutomationSaveSheet`, `AutomationChangeInWordsSheet`, the edit form as a sheet.
- **No moving an automation between Personal and a workbench** (ask #469). The scope is chosen in A2 and never changes afterwards.
- **AUTO-06 is not weakened.** Only the owner's press on a screen that shows every hashed field confirms. The bytes saved are always the bytes whose `approval_hash` was validated and shown. `install-template` itself stays unconfirmed and disabled (`TestInstallTemplate_InstalledUnconfirmedAndDisabled` unchanged). Guard tests keep their names and every assertion; a guard whose call sites change because a sheet is gone keeps each assertion against the new call (listed per task).
- **No data change in part A:** no migration, no `schema.sql` edit.
- **Desktop kit only:** `PanelSplit`, `.kitPrimary` once per screen, `.kitSecondary`/`.kitQuiet`, `.kitIcon(isOn:)`, `KitSegmentedPicker`, `.card()`, `.kitRow(isSelected:)`, `SectionHeader`, `Chip`, `Spacing`/`Radius`/`Fill` tokens, no literals, no row dividers. `make lint-swift` passes (lint-diff is Go-only).
- **Copy (verbatim from the spec where it fixes it):** list title "Automations"; tiles **Personal** — "Your mail, Slack, calendar and trackers. Results go to your Inbox and briefing." — and one per workbench — "Its board, agent sessions and shell in <folder>."; headings "What is it for?" and "How do you want to start?"; option **Describe it in words**; **Continue**; **Save and Turn On**, **Save Turned Off**, **Save and Confirm**, **Confirm and Turn On**, **Confirm**; **Adjust in Chat**; **Show recipe**; hint "Saving confirms exactly what's listed above and turns it on"; "Checking…"; segments **Chat | Form | Script**; card buttons **Run Now**, **Edit**, **⋯** (Turn Off / Turn On, Dry Run, Delete…); banner "Needs your confirmation" with **Review…**; marks "New since you confirmed"; chips Needs confirmation, Paused, Can't read, Draft; an off row's line starts "Off · ".
- **Validation debounce:** 500 ms after the draft bytes stop changing.
- **Plan's-call copy** (the spec leaves it open): scope caption "This decides what it can see and where its recipe lives. It can't be moved later."; edit-hint "Saving confirms exactly what's listed above"; confirm-hint "Confirming approves exactly what's listed above"; no-change hint "No changes to save"; aside line "The assistant's draft replaced your edits." with **Restore**.
- Desktop rules: `docs/review/review-rules.md` "Swift / Desktop conventions" (state that must survive navigation lives in an AppState-owned center; every new `@Observable` ships its own test suite; tests never order a window in). Fixtures use `acme` / `example.com` only.
- Inner loop only per task (CLAUDE.md "Agent-driven runs"): `go test ./cmd -run …`, `go test ./internal/<pkg>`, `make test-swift FILTER=<Class>`, `make lint-swift`, `make lint-diff`. The full gate runs once, in Task 15.

## Review Focus

- **Save pressed inside the debounce** (the last keystroke still in Monaco's 300 ms page debounce or the 500 ms check delay): nothing is saved; the press flushes, sees the bytes differ from the validated ones, re-checks and shows "Checking…" — test `testAuto06_SavePressAfterAnUnflushedEditRechecksInsteadOfSaving` in Task 5.
- **The assistant writes a new draft while the owner has unsaved Form/Script edits:** the draft is adopted, the owner's text is kept aside with **Restore**, never silently lost — test `testChatDraftOverOwnerEditsKeepsThemAside` in Task 5.
- **Edit opened on an automation whose conversation cache still holds an older, already-saved draft:** the panel starts from the indexed file, not the stale cache line — test `testOpenDoesNotAdoptAnOldCachedDraft` in Task 5.
- **The installed template copy hashes differently from what the panel showed** (a param default resolved differently between render and install, e.g. the owner's active Jira projects changed): no confirm, no enable; the copy stops at Needs confirmation — test `testAuto06_TemplateConfirmsOnlyTheShownHash` in Task 7.
- **The save or install succeeded but confirm/enable failed:** the panel says which step failed, the automation stays in the list with its chip (Off or Needs confirmation), nothing is rolled back and a second press does not save again — tests `testEnableFailureAfterSaveSaysSoAndKeepsTheSave` (Task 5) and `testConfirmFailureAfterInstallLeavesTheCopy` (Task 7).

Also pinned (not top five): **Save Turned Off** on an enabled automation turns it off before the save, so the new text is never briefly confirmed and on (`testSaveTurnedOffOnAnEnabledAutomationDisablesBeforeSaving`, Task 5); a draft row whose workbench is gone is not listed (`testDraftOfAGoneWorkbenchIsNotListed`, Task 4).

---

## File structure

**Go**
- `cmd/automations_edit.go` — `validateJSON` gains `changes`/`changes_known`; `validateScope` returns the confirmed recipe.
- `cmd/automations_templates.go` — `--render`; `installedRecipeJSON.ApprovalHash`.
- `internal/skills/shipped/create-automation.md` — the editor chat stops proposing `save_automation`.

**WatchtowerCore** (`WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/`)
- `AutomationsCLI.swift` — new ops and decoded fields.
- `AutomationsPanel.swift` (new) — `AutomationsPanel`, `AutomationScopeChoice`, `AutomationNewFlow`.
- `AutomationListSections.swift` (new) — sections, row line and chips, `AutomationDraftRow` + `AutomationDraftRows.load`.
- `AutomationEditorCenter.swift` — in-panel save engine (debounce, keys for new drafts, turn on/off, chat adoption).
- `AutomationDraftFooter.swift` (new) — footer mode, pure.
- `AutomationDraftColumnModel.swift` (new) — what the draft column shows, pure.
- `AutomationTemplatePanelModel.swift` (new) — A3 model.
- `AutomationsViewModel.swift` — `panel` route; template install moves to the template model.
- `AutomationSavePlan.swift` — `needsSheet` removed.

**App / Views**
- `Sources/Services/ChatSurfaces/AutomationEditorChatSurface.swift`, `Sources/App/AppState.swift`, `Sources/App/AppState+Automations.swift`, `Sources/App/Navigation.swift`.
- `Sources/Views/Automations/`: new `AutomationNewPanel.swift`, `AutomationTemplatePanel.swift`, `AutomationDraftColumn.swift` (replaces `AutomationDraftPanel.swift`), `AutomationEditorPanel.swift` (replaces `AutomationEditorChatView.swift`'s view; the loader stays), `AutomationFormFields.swift` (the form's fields, out of `AutomationFormView.swift`); modified `AutomationsView.swift`, `AutomationListRow.swift`, `AutomationCardView.swift`, `ReactionsSectionView.swift`; deleted `NewAutomationSheet.swift`, `AutomationTemplateGalleryView.swift`, `AutomationConfirmSheet.swift`, `AutomationSaveSheet.swift`, `AutomationFormView.swift`.
- Shots: `WatchtowerDesktop/Tests/DesignShots/DesignShotCatalog.swift`, `DesignShotFixtures+Automations.swift`.

**Docs** — `docs/guide/features/automations.md`, `docs/guide/features/automations-recipes.md`, `docs/guide/features/automations-safety.md`, `docs/features/automations.md`, `docs/inventory/automations.md`.

## Task list and lanes

| # | Task | Depends on |
|---|---|---|
| 1 | `validate --json` reports `changes` since the confirmed text | none |
| 2 | `install-template --render` and installed `approval_hash` | none |
| 3 | `AutomationsCLI` ops and decoders for 1–2 | none (wire shapes pinned in Tasks 1–2) |
| 4 | Panel route, scope choice, list sections, draft rows | none |
| 5 | `AutomationEditorCenter` saves in place | Tasks 3, 4 |
| 6 | Draft column (model + view) | Task 3 |
| 7 | Template panel model | Tasks 3, 4, 6 |
| 8 | Editor chat surface: owner's panel draft, no Save… message | Task 4 |
| 9 | `create-automation` skill: editor chat points to the Save buttons | none |
| 10 | A2 view: "What is it for?" / "How do you want to start?" | Task 4 |
| 11 | A3 view: template panel | Tasks 6, 7 |
| 12 | A4 view: editor panel (Chat / Form / Script + column + footer) | Tasks 5, 6, 8 |
| 13 | A1/A5/A6 wiring: `PanelSplit` tab, list, card, segments; sheets removed | Tasks 4, 10, 11, 12 |
| 14 | Docs: guide, feature note, AUTO-03/AUTO-06 amendment | Tasks 1, 2, 9, 13 |
| 15 | Phase gate and owner review ask with shots | all |

Lanes: Go tasks 1, 2, 9 run in parallel with each other and with Swift Core tasks 3 and 4; 8 follows 4. Swift work that links the app (6, 10–13) stays one lane at a time (CLAUDE.md: heavy Swift work one lane).

---

### Task 1: `validate --json` reports `changes` since the confirmed text

Depends on: none.

**Files:**
- Modify: `cmd/automations_edit.go` (`validateJSON`, `validateRecipe`, `validateScope`, `runAutomationsValidate`)
- Test: `cmd/automations_test.go`

**Interfaces:**
- Consumes: `automations.ConfirmedRecipe(database, a)`, `diffApprovalFields(confirmed, current *automations.Recipe) []automationChangeJSON` (`cmd/automations.go`, already used by `show`).
- Produces: `validate --json` gains `"changes"` (array of `{field, old, new}` exactly like `show --json`'s, never `null`) and `"changes_known"` (bool). With `--against <id>` and a known confirmed text: `diffApprovalFields(confirmed, parsed draft)`, `changes_known: true`. With `--against` and no known confirmed text, without `--against`, or when the text does not parse: `[]`, `false`.
- Signatures: `func validateScope(database *db.DB) (automations.Scope, *automations.Recipe, error)` (the confirmed recipe, nil when none/no `--against`); `func validateRecipe(slug string, data []byte, contentHash string, scope automations.Scope, confirmed *automations.Recipe) validateJSON` (baseline = `confirmed`'s normalised permissions, nil when `confirmed == nil` — `widening` unchanged from today).

- [ ] **Step 1: Write the failing tests** in `cmd/automations_test.go`:
  - `TestAutomationsCLI_ValidateAgainstReportsChangesSinceConfirmed`: confirm a recipe with schedule `0 9 * * 1-5`; validate the same text with `0 16 * * 1-5` and `--against <id>` → `changes_known == true`, `changes` has exactly one entry with `field == "trigger"`, `old` contains `0 9 * * 1-5`, `new` contains `0 16 * * 1-5`. A script edit yields `{field: "script", old: "", new: ""}`.
  - `TestAutomationsCLI_ValidateAgainstUnchangedHasEmptyChanges`: same text → `changes == []` (decoded as an empty array, not null), `changes_known == true`.
  - `TestAutomationsCLI_ValidateChangesUnknownWithoutAgainst`: no `--against` → raw JSON contains `"changes":[]` and `"changes_known":false`; a parse error (`"broken"`) gives the same.
  - Update `TestAutomationsCLI_ValidateJSONKeys`: add `"changes", "changes_known"` to the key list (additive pinned keys).
- [ ] **Step 2: Run** `go test ./cmd -run 'TestAutomationsCLI_Validate'` — expect FAIL (missing keys).
- [ ] **Step 3: Implement** the two fields and the new signatures; initialise `Changes` to `[]automationChangeJSON{}` in `validateRecipe`'s zero value (wire-shape rule).
- [ ] **Step 4: Run** `go test ./cmd -run 'TestAutomationsCLI_Validate|TestAutomationsCLI_Show'` — PASS; `make lint-diff` clean.
- [ ] **Step 5: Commit** `feat(automations): validate --json reports changes since the confirmed text`.

### Task 2: `install-template --render` and the installed copy's `approval_hash`

Depends on: none.

**Files:**
- Modify: `cmd/automations_templates.go` (flag in `init`, `installedRecipeJSON`, `runAutomationsInstallTemplate`, new `renderTemplateJSON`)
- Modify: `cmd/automations.go` (`autoFlags.Render bool`)
- Test: `cmd/automations_templates_test.go`

**Interfaces:**
- Consumes: `templateForInstall`, `parseTemplateParams`, `automations.FillTemplateParams`, `automations.RenderTemplate`, `workbenchScope`, `validateRecipe(slug, data, automations.ContentHash(data), scope, nil)` (Task 1's signature; until Task 1 merges, call today's with `nil` baseline — identical result).
- Produces:
  - `install-template <name> [--workbench <id>] [--param K=V]… --render --json` writes nothing (no file, no index row, no `MkdirAll`) and prints `{"name": "<template>", "scope": "personal|workbench", "params": {"KEY": ["v", …]}, "files": [{"slug": "<slug>", "text": "<rendered recipe>", "validate": <validate --json object>}]}`, `files` in the template's `files` order, never `null`. Same scope and param refusals as an install (a missing Jira project is the same error). Without `--json`, `--render` prints each file's text after a `--- <slug>.md` line. Open under AI-agent markers (it writes nothing).
  - `install-template --json`: each `installed[]` entry gains `"approval_hash"` (the indexed row's `ApprovalHash`; `""` for a copy with a parse error).

- [ ] **Step 1: Write the failing tests:**
  - `TestInstallTemplate_RenderWritesNothing`: `--render --json` for `team-performance-report` → `files` has one entry with `slug == "team-performance-report"`, `validate.ok == true`, non-empty `validate.approval_hash`; afterwards the personal folder has no `team-performance-report.md` and `GetAutomationBySlug("personal", 0, "team-performance-report")` is `db.ErrAutomationNotFound`.
  - `TestInstallTemplate_RenderHashMatchesInstall`: for `team-performance-report` (personal) and `release-buttons` (workbench, `--workbench <id>`) render then install → for each slug, `files[i].validate.approval_hash == installed[i].approval_hash`; `release-buttons` renders three files in `release, deploy-test, deploy-stage` order with `validate.scope == "workbench"`.
  - `TestInstallTemplate_RenderJSONKeys`: `wantKeys` on the top object (`name, scope, params, files`), on `files[0]` (`slug, text, validate`) and on `installed[0]` of a plain install (`automation_id, slug, path, parse_error, approval_hash`).
  - `TestInstallTemplate_RenderRefusesLikeInstall`: `jira-state-report --render` with no active Jira project → error containing the `ErrNoActiveJiraProject` text; `pr-review-rounds --render` without `--workbench` → the "is a workbench template" error.
- [ ] **Step 2: Run** `go test ./cmd -run 'TestInstallTemplate'` — expect FAIL.
- [ ] **Step 3: Implement** `--render` as an early branch after `RenderTemplate` and `workbenchScope` (before `RefuseLinkedRecipeDir` and any write); add `ApprovalHash string \`json:"approval_hash"\`` to `installedRecipeJSON`, filled in `indexTemplateFiles`.
- [ ] **Step 4: Run** `go test ./cmd -run 'TestInstallTemplate|TestTemplatesCLI'` — PASS, including the unchanged `TestInstallTemplate_InstalledUnconfirmedAndDisabled`; `make lint-diff` clean.
- [ ] **Step 5: Commit** `feat(automations): install-template --render and the installed approval hash`.

### Task 3: `AutomationsCLI` ops and decoders

Depends on: none (decodes the shapes pinned in Tasks 1–2; a field missing from an older CLI decodes to its default).

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/AutomationsCLI.swift`
- Modify (call sites of the changed ops): `AutomationEditorCenter.swift`, `AutomationsViewModel.swift`
- Test: `WatchtowerDesktop/Tests/Core/AutomationsCLITests.swift`, `WatchtowerDesktop/Tests/Core/AutomationTemplateGalleryTests.swift`

**Interfaces:**
- Produces:
  - `case validate(file: String, against: Int64?, workbench: Int64?)` → `["automations", "validate", file] + ["--against", id]? + ["--workbench", id]? + ["--json"]` (both non-nil is a programming error: `precondition`).
  - `func validate(file: URL, against: Int64?, workbench: Int64? = nil) async throws -> ValidateResult`.
  - `ValidateResult.changes: [AutomationChange]` (default `[]`), `ValidateResult.changesKnown: Bool` (key `changes_known`, default `false`).
  - `case installTemplate(name: String, workbenchID: Int64?, params: [String: String])` and `case renderTemplate(name: String, workbenchID: Int64?, params: [String: String])`; params become `--param KEY=VALUE` sorted by key, empty values omitted; render adds `--render` before `--json`.
  - `func installTemplate(_ name: String, workbenchID: Int64?, params: [String: String] = [:]) async throws -> InstallResult`; `InstallResult.installed: [InstalledRecipe]` (default `[]`), `package struct InstalledRecipe: Decodable, Equatable, Sendable { automationID: Int64; slug: String; path: String; parseError: String; approvalHash: String }` (`parse_error`/`approval_hash` default `""`).
  - `func renderTemplate(_ name: String, workbenchID: Int64?, params: [String: String]) async throws -> RenderResult`; `package struct RenderResult: Decodable, Equatable, Sendable { name: String; scope: String; params: [String: [String]]; files: [RenderedFile] }`, `package struct RenderedFile: Decodable, Equatable, Sendable { slug: String; text: String; validate: ValidateResult }`.

- [ ] **Step 1: Write the failing tests** in `AutomationsCLITests`:
  - `testValidateWorkbenchArgs`: `.validate(file: "/t/a.md", against: nil, workbench: 3)` → `["automations", "validate", "/t/a.md", "--workbench", "3", "--json"]`.
  - `testValidateDecodesChanges`: a body with `"changes":[{"field":"trigger","old":"a","new":"b"}],"changes_known":true` decodes both; the existing empty-state body (no keys) decodes to `[]`/`false`.
  - `testRenderTemplateArgsAndDecode`: `.renderTemplate(name: "jira-state-report", workbenchID: nil, params: ["PROJECT": "PAY", "EMPTY": ""])` → `["automations", "install-template", "jira-state-report", "--param", "PROJECT=PAY", "--render", "--json"]`; a two-file body decodes `files[1].validate.approvalHash`.
  - `testInstallResultDecodesInstalledCopies`: `installed[0].approvalHash == "h1"`; a body without `installed` decodes to `[]`.
  - In `AutomationTemplateGalleryTests`, update `testInstallPersonalArgs`/`testInstallWorkbenchArgs` only for the new `params:` label (same expected argv).
- [ ] **Step 2: Run** `make test-swift FILTER='AutomationsCLITests|AutomationTemplateGalleryTests'` — FAIL.
- [ ] **Step 3: Implement**; existing callers pass `workbench: nil` / `params: [:]`.
- [ ] **Step 4: Run** the same filter — PASS; `make lint-swift` clean.
- [ ] **Step 5: Commit** `feat(desktop): automations CLI render, installed hashes and validate changes`.

### Task 4: Panel route, scope choice, list sections and draft rows

Depends on: none.

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/AutomationsPanel.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/AutomationListSections.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/AutomationsViewModel.swift`
- Test: create `WatchtowerDesktop/Tests/Core/AutomationListSectionsTests.swift`; extend `WatchtowerDesktop/Tests/Core/AutomationsViewModelTests.swift`

**Interfaces:**
- Produces (all `package`, `Equatable`, `Sendable`):
  - `enum AutomationScopeChoice: Hashable { case personal; case workbench(id: Int64, name: String, folder: String) }` with `var workbenchID: Int64?` and `var recipeDir(workspaceDir: String) -> String` (`<workspace>/automations` or `<folder>/.watchtower/automations`).
  - `struct AutomationNewFlow { var fixedScope: AutomationScopeChoice?; var composerPrefill: String? }` — `fixedScope` set skips "What is it for?".
  - `enum AutomationsPanel: Equatable { case empty; case card(Int64); case new(AutomationNewFlow); case template(name: String, scope: AutomationScopeChoice); case editor(AutomationEditorTarget) }`.
  - `enum AutomationEditorTarget: Hashable { case existing(Int64, review: Bool); case newDraft(contextID: String, scope: AutomationScopeChoice, startText: String?) }` with `var startText: String?` (nil for `.existing`) — `review: true` is the banner's **Review…** (A5).
  - `struct AutomationDraftRow: Identifiable { conversationID: Int64; contextID: String; workbenchID: Int64?; name: String; updatedAt: Date }` (`id` = conversationID); `enum AutomationDraftRows { static func load(_ db: Database, databasePath: String, liveWorkbenchIDs: Set<Int64>) throws -> [AutomationDraftRow] }` — every `chat_conversations` row with `context_type = 'automation_draft'` whose cache file (`AutomationDraftEntry.cacheURL`) exists and whose newest line is `.entry`; `workbenchID` parsed from a `-wb<id>` suffix (`AutomationEditorChatSurface.draftContextID`'s format, mirrored here as `static func workbenchID(fromContextID:) -> Int64?`); a workbench id not in `liveWorkbenchIDs` is dropped; `name` = manifest name or "New automation"; `updatedAt` = the file's modification date; sorted newest first. An undecodable or unreadable cache is not a row.
  - `struct AutomationListSection: Identifiable { id: String; title: String; drafts: [AutomationDraftRow]; items: [AutomationListItem] }`; `enum AutomationListSections { static func make(items: [AutomationListItem], drafts: [AutomationDraftRow], workbenches: [(id: Int64, name: String)], query: String) -> [AutomationListSection] }` — Personal first, then each workbench by name; drafts at the top of their section; a section with nothing after filtering is omitted; the count is `drafts.count + items.count`.
  - `enum AutomationRowChip { case needsConfirmation, paused, cantRead, draft }` with `title` ("Needs confirmation", "Paused", "Can't read", "Draft"); `enum AutomationRowPresentation { static func chips(_ item: AutomationListItem) -> [AutomationRowChip]; static func line(_ item: AutomationListItem, changes: [AutomationChange]?, now: Date) -> String; static func isOn(_ item: AutomationListItem) -> Bool }` — chips: `needsConfirmation` badge → Needs confirmation; `autoPaused` badge, or disabled with a non-empty `disabledReason` → Paused; `parseError` → Can't read (plan's call: "Disabled" is no chip, the dot and "Off · " say it). `line` = `AutomationCardPresentation.rowDetailLine(...)`, prefixed "Off · " when `automation.enabled == false`.
  - `AutomationsViewModel`: `package var panel: AutomationsPanel = .empty`; `func showNew(_ flow: AutomationNewFlow)`; `func showCard(_ id: Int64)` (selects too); `select(_:)` sets `.card(id)`. Removed: `pendingEditID`, `pendingNewWorkbenchID`, `installTemplate`, `installingTemplate`, `installError`, `installCoverage` (Task 7 owns installs). Kept unchanged: `pendingConfirmID` (QuickRunCenter and the header buttons write it; the AUTO-06 guard `testDimmedRowOpensInsteadOfRunning` reads it).

- [ ] **Step 1: Write the failing tests** in `AutomationListSectionsTests`:
  - `testSectionsPersonalThenWorkbenchesWithDraftsFirst`: two personal items, one draft row for workbench 3 ("acme") and one item there → titles `["Personal", "acme"]`, acme's `drafts.count == 1` before its item, counts `2` and `2`.
  - `testQueryFiltersItemsAndDraftsAndDropsEmptySections`.
  - `testChips`: needs-confirmation → `[.needsConfirmation]`; disabled with `disabledReason` "Paused by the update…" → `[.paused]`; parse error → `[.cantRead]`; plain disabled → `[]`.
  - `testOffLinePrefix`: disabled item's `line` starts with "Off · "; enabled one does not.
  - `testDraftRowsFromCacheFiles` (TestDatabase pool + temp workspace): conversations `d1` (personal) and `d2-wb3` with cache lines, one conversation without a cache file, one with an undecodable newest line → two rows, newest first, `workbenchID` `nil` and `3`, name from the manifest.
  - `testDraftOfAGoneWorkbenchIsNotListed`: `d3-wb9` with `liveWorkbenchIDs: [3]` → not listed.
  - In `AutomationsViewModelTests`: `testSelectShowsTheCard` (`select(7)` → `panel == .card(7)`), `testShowNewKeepsTheFixedScope`.
- [ ] **Step 2: Run** `make test-swift FILTER='AutomationListSectionsTests|AutomationsViewModelTests'` — FAIL.
- [ ] **Step 3: Implement.** Remove the template-install members and their tests (`testInstallKeepsTheCoverage`, `testInstallSelectsAndOpensForm`, `testFailedInstallKeepsTheStderrAndOpensNothing`, `testInstallSurvivesNavigation` move to Task 7's suite in its own terms); keep `loadTemplates`.
- [ ] **Step 4: Run** the filter plus `QuickRunCenterTests|WorkbenchHeaderAutomationButtonsTests` — PASS; `make lint-swift` clean.
- [ ] **Step 5: Commit** `feat(desktop): automations panel route, list sections and draft rows`.

### Task 5: `AutomationEditorCenter` saves in place

Depends on: Tasks 3, 4.

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/AutomationEditorCenter.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/AutomationDraftFooter.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/AutomationSavePlan.swift` (drop `needsSheet`)
- Test: `WatchtowerDesktop/Tests/Core/AutomationEditorCenterTests.swift`, `WatchtowerDesktop/Tests/Core/AutomationFormTests.swift`, create `WatchtowerDesktop/Tests/Core/AutomationDraftFooterTests.swift`

**Interfaces:**
- Consumes: Task 3's `validate(file:against:workbench:)`, `ValidateResult.changes`; Task 4's `AutomationScopeChoice`.
- Produces:
  - **Keys.** Drafts stay keyed by `Int64`: an existing automation by its id; a new draft by `static func newDraftKey(conversationID: Int64) -> Int64` (= `-conversationID`), `static func isNewDraft(_ key: Int64) -> Bool` (`key < 0`). `newRecipeID` and `beginNew(automationsDir:)` are removed (plan's call: negative keys keep every existing `Int64`-keyed map and guard call site as is).
  - `init(cli:grants:refresh:draftCacheDir:tempDirectory:checkDelay:sleep:)` — new parameters `draftCacheDir: URL? = nil` (`<workspace>/automation-drafts`), `checkDelay: Duration = .milliseconds(500)`, `sleep: @escaping (Duration) async -> Void` (test seam, default `Task.sleep`). Enable/disable go through `cli.setEnabled`.
  - `func beginEdit(_ id: Int64, chatNewestText: String?) async` — loads `show`, records `chatNewestText` as already adopted (Review Focus 3), then `scheduleCheck`.
  - `func beginNew(key: Int64, scope: AutomationScopeChoice, recipeDir: String, startText: String?)` — `AutomationDetail(newRecipeIn: recipeDir, scope:)` (extend the existing init with `scope: AutomationScopeChoice = .personal`: `scope`/`projectID` set from it), buffer replaced with `startText` when given; kept if already open.
  - `func adoptChatDraft(_ key: Int64, text: String, slug: String?)` — no-op when `text` equals the last adopted text; else, when the buffer differs from the last adopted text (owner edits), stores the current text in `keptAside[key]` and sets `asideReason[key] = .assistantReplaced`; then `buffer.replace(text:)`, remembers `slug` as the new recipe's slug hint (used only when `^[a-z0-9][a-z0-9-]{0,63}$`), `scheduleCheck`.
  - `func restoreAside(_ key: Int64)`.
  - `func textChanged(_ key: Int64)` — the view calls it on `buffer.textRevision`; cancels the pending check and schedules one after `checkDelay`.
  - `func check(_ key: Int64) async` — flush, `prepareSave` (validate with `against: id` for an edit, `workbench: projectID` for a new workbench draft), state `.validating` → `.review(plan)` or `.failed(errors)`; a result for text changed since is dropped.
  - `func canSave(_ key: Int64) -> Bool` — `.review(plan)` with `plan.validated.ok`, and `validatedTexts[key] == form.renderedText()`.
  - `func commit(_ key: Int64, plan: AutomationSavePlan, turnOn: Bool) async` — flush; if the text differs from the validated text → `check` and return without saving (Review Focus 1). Then: an enabled automation saved with `turnOn == false` is disabled first (`cli.setEnabled(id, false)`); save with `--confirm-hash plan.validated.approvalHash --expect-content-hash <base or "">` at `path` (new: `recipeDir/<slug hint or slug(forName:)>.md`); keep-auto as today; `turnOn` and not already enabled → `cli.setEnabled(saved.automationID, true)`. Outcomes: `.done` (unchanged case) with `savedIDs[key] = saved.automationID` (new `package private(set) var savedIDs: [Int64: Int64]`), or `.failed(String)` with "Saved and confirmed, but not turned on: <stderr>" when only enable failed (the draft is gone and `savedIDs[key]` is set, so a retry only enables). A new draft's cache file `draftCacheDir/<conversationID>.jsonl` is removed after a successful save (best effort, failure logged).
  - `func confirmShown(_ id: Int64, plan: AutomationSavePlan, turnOn: Bool) async` — `confirmForeign(id, shownHash: plan.validated.approvalHash, enable: turnOn)` (unchanged bytes; the column showed this hash).
  - `AutomationDraftFooter` (pure): `enum Action { case saveAndTurnOn, saveTurnedOff, saveAndConfirm, confirmAndTurnOn, confirmTurnedOff, confirm }`; `struct AutomationDraftFooter { primary: Action; primaryEnabled: Bool; secondary: Action?; hint: String; static func make(isNew: Bool, bytesChanged: Bool, enabled: Bool, needsConfirmation: Bool) -> Self }`; `Action.title`. Table:

    | isNew | bytesChanged | needsConfirmation | enabled | primary | secondary | hint |
    |---|---|---|---|---|---|---|
    | yes | – | – | – | Save and Turn On | Save Turned Off | "Saving confirms exactly what's listed above and turns it on" |
    | no | yes | – | yes | Save and Confirm | Save Turned Off | "Saving confirms exactly what's listed above" |
    | no | yes | – | no | Save and Turn On | Save Turned Off | turns-it-on hint |
    | no | no | yes | no | Confirm and Turn On | Confirm Turned Off | "Confirming approves exactly what's listed above" |
    | no | no | yes | yes | Confirm | — | confirm hint |
    | no | no | no | – | Save and Confirm (disabled) | — | "No changes to save" |

- [ ] **Step 1: Write the failing tests.** Adapt (same names, every assertion kept; "the sheet" wording in a message becomes "the owner's press"):
  - `testSaveConfirmsTheValidatedHashOnly` (AUTO-06 guard): `beginEdit(7, chatNewestText: nil)`; edit the trigger; `await center.check(7)`; `guard case let .review(plan)`; assert no `save` yet; `await center.commit(7, plan: plan, turnOn: false)`; the argv, `--path`, validate suffix `["--against", "7", "--json"]`, `fileTexts` equalities, `saving[7] == .done`, draft gone, `refreshed == [7]`, temp dir empty — all as today — plus `savedIDs[7] == 7` (added, strictly stronger).
  - `testNoAutoOnWithoutACheckedBox` (AUTO-03 guard): same assertions through `check` + `commit(…, turnOn: false)`.
  - `testTextTypedWhileTheSheetIsUpIsNotSavedUnderTheValidatedHash` → keep the name; now it asserts the stronger rule: after `check`, an edit, then `commit` → no `save` invocation and `saving[7] == .validating` or `.review` of the new text (re-check), never the old bytes under `hv`.
  - Rewrite (not guards) `testNewRecipeSavesAtItsSlugWithAnEmptyExpectedHash`, `testNewRecipeNameClashSaysSo`, `testQuietSaveSavesInTheSameGesture` → `testNameOnlyEditSavesOnPress` on the new key API; delete the sheet-only `testWideningSheetShownOnlyOnWidening`, `testUnconfirmedRecipeAlwaysShowsSheet` in `AutomationFormTests` and rename `testScheduleOrBudgetEditShowsSheetAndPausesGrants` → `testScheduleOrBudgetEditPausesGrants` (assertions on `pausedGrants` kept). `testAuto03_KeepAutoBoxesUncheckedByDefault` is untouched.
  - New in `AutomationEditorCenterTests`:
    - `testAuto06_SavePressAfterAnUnflushedEditRechecksInsteadOfSaving`: `check`, then a `buffer.flushPending` closure that replaces the text on flush, then `commit` → zero `save` invocations, one more `validate` whose file text is the new text.
    - `testAuto06_SaveDisabledWhileChecking`: hold `validate`; `textChanged(7)`; after the injected sleep, `canSave(7) == false`; release → `canSave(7) == true`; edit again → `false`.
    - `testCheckIsDebounced`: three `textChanged` within the delay → one `validate`.
    - `testSaveAndTurnOnEnablesAfterTheConfirmedSave`: new personal draft key `newDraftKey(conversationID: 42) == -42`; `commit(…, turnOn: true)` → invocations `validate`, `save` (path `<dir>/<slug hint>.md`, `--expect-content-hash ""`), `enable <id>` in that order; the cache file `42.jsonl` is removed.
    - `testNewWorkbenchDraftValidatesAndSavesInItsFolder`: scope `.workbench(id: 3, name: "acme", folder: "/acme")` → validate argv has `--workbench 3`; save `--path /acme/.watchtower/automations/<slug>.md`.
    - `testEnableFailureAfterSaveSaysSoAndKeepsTheSave`: `enable` throws → `saving[key] == .failed("Saved and confirmed, but not turned on: …")`, `refreshed` contains the id; a second `commit` issues only `enable`.
    - `testSaveTurnedOffOnAnEnabledAutomationDisablesBeforeSaving`: `show` fixture enabled → invocations order `disable 7`, `save`; no `enable`.
    - `testChatDraftOverOwnerEditsKeepsThemAside`: adopt A, owner edits, adopt B → buffer is B, `keptAside[7]` is the owner's text; `restoreAside` puts it back; adopting B again is a no-op.
    - `testOpenDoesNotAdoptAnOldCachedDraft`: `beginEdit(7, chatNewestText: "old")`; buffer is the `show` text; `adoptChatDraft(7, text: "old", slug: nil)` changes nothing.
    - `testConfirmShownPassesTheValidatedHash`: unchanged bytes, `check`, `confirmShown(7, plan:, turnOn: true)` → `["automations", "confirm", "7", "--hash", "<validated hash>"]` then `["automations", "enable", "7"]`.
  - `AutomationDraftFooterTests.testTable`: one assertion per table row (titles, `primaryEnabled`, secondary, hint).
- [ ] **Step 2: Run** `make test-swift FILTER='AutomationEditorCenterTests|AutomationFormTests|AutomationDraftFooterTests'` — FAIL.
- [ ] **Step 3: Implement.** The debounce task is held per key and cancelled on `discard`; `recheckParse` folds into `check` (its banner reads `currentParseError` from the same result).
- [ ] **Step 4: Run** the same filter — PASS (guards `testSaveConfirmsTheValidatedHashOnly`, `testNoAutoOnWithoutACheckedBox`, `testAuto03_KeepAutoBoxesUncheckedByDefault`, `testAuto06_ConfirmSheetPassesTheShownHash`, `testAuto06_ConfirmSheetShowsHashedFieldChanges` all green); `make lint-swift` clean.
- [ ] **Step 5: Commit** `feat(desktop): automation drafts validate and save in place`.

### Task 6: The draft column (model and view)

Depends on: Task 3.

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/AutomationDraftColumnModel.swift`
- Create: `WatchtowerDesktop/Sources/Views/Automations/AutomationDraftColumn.swift`
- Delete: `WatchtowerDesktop/Sources/Views/Automations/AutomationDraftPanel.swift` (its `AutomationSessionPromptsBlock` moves into the new file unchanged)
- Modify: `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+Automations.swift`, `DesignShotCatalog.swift` (`automation-draft-panel` → `automation-draft-column`)
- Test: create `WatchtowerDesktop/Tests/Core/AutomationDraftColumnModelTests.swift`

**Interfaces:**
- Consumes: `AutomationsCLI.ValidateResult` (with `changes`), `AutomationDraftEntry`, `RecipeFrontmatter`, `AutomationCardPresentation.permissionLines`, `AutomationChangePresentation.lines`, `AutomationLLMWarning`, `OwnerAskSnapshotDiff`, `AutomationSavePlan`.
- Produces: `package struct AutomationDraftColumnModel: Equatable, Sendable` with `init(text: String, validated: AutomationsCLI.ValidateResult?, isChecking: Bool, newestChatEntry: AutomationDraftEntry?, confirmedText: String?, isNew: Bool, plan: AutomationSavePlan?)` and fields:
  - `when: String`, `whenDetail: String?` (from `RecipeFrontmatter` of `text`, same wording as today's Draft panel);
  - `mayDo: [AutomationCardPresentation.PermissionLine]` from `validated.permissions`/`outputs`/`widening` — a new recipe marks every line new; the mark copy is "New since you confirmed";
  - `sends: [String]` (output lines), `eachRun: String` (`SaveAutomationCardModel.budget`), `missedAndConcurrency: String`;
  - `changes: [String]` — `AutomationChangePresentation.lines(validated.changes, known: validated.changesKnown, confirmedBefore: !isNew && confirmedText != nil)`; empty for a new recipe (no changes block);
  - `dryRunLines: [String]`, `dryRunNote: String?`, `sessions` — only when `newestChatEntry?.recipeText == text`; otherwise `dryRunNote = "Not dry-run since the last change."` (plan's call);
  - `errors: [String]`, `pausedGrants: [String]`, `llmWarning: String?` (from `plan`);
  - `recipeDiff: OwnerAskSnapshotDiff?` (edit: `confirmedText` vs `text`; nil for new), `recipeText: String`;
  - `status: Status` — `.checking` | `.ready` | `.invalid`.
- View: `struct AutomationDraftColumn: View { let model: AutomationDraftColumnModel; @Binding var keepAuto: Set<String>; let onDryRunAgain: (() -> Void)? }` — boxes in order When, It may, Sends, Each run, Missed and Concurrency, Changed (edit only), dry-run line, **Show recipe** (`DisclosureGroup` expanding in place: the read-only `RecipeEditorView` for a new recipe, the diff lines for an edit), the paused-grants block with "Keep auto for <tool>" boxes (unchecked, AUTO-03). `.card()` per box, `SectionHeader` titles, no dividers.

- [ ] **Step 1: Write the failing tests** in `AutomationDraftColumnModelTests`:
  - `testNewRecipeMarksEveryPermissionNewAndHasNoChanges`.
  - `testEditShowsChangesAndWideningOnly`: `validated.widening == ["gmail:read@work"]` → only that line marked; `changes` lines include "Schedule … → …".
  - `testUnknownChangesSaySo`: `changesKnown == false`, edit of a confirmed recipe → `[AutomationChangePresentation.unknownChanges]`.
  - `testDryRunShownOnlyForTheSameText`.
  - `testCheckingStatus`: `isChecking: true` → `.checking` whatever `validated` holds.
  - `testInvalidShowsErrors`.
  - `testPausedGrantsAndLLMWarningFromPlan`.
- [ ] **Step 2: Run** `make test-swift FILTER=AutomationDraftColumnModelTests` — FAIL.
- [ ] **Step 3: Implement** the model, then the view; replace the `automation-draft-panel` shot with `automation-draft-column` (560 × 760) on a fixture edit of "acme digest" with one widening, one change line and a dry run.
- [ ] **Step 4: Run** `make test-swift FILTER='AutomationDraftColumnModelTests|AutomationDraftPanelModelTests'` — PASS; `make lint-swift` clean; `make desktop-shots DESKTOP_SHOTS=<scratch dir>` and look at `automation-draft-column-light.png`/`-dark.png`.
- [ ] **Step 5: Commit** `feat(desktop): automation draft column`.

### Task 7: Template panel model

Depends on: Tasks 3, 4, 6.

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/AutomationTemplatePanelModel.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/AutomationTemplate.swift` (drop `InstallChoice`/`installChoice`, now unused; keep `summaryLine`, `coverageLine`)
- Test: create `WatchtowerDesktop/Tests/Core/AutomationTemplatePanelModelTests.swift`; trim `AutomationTemplateGalleryTests.swift` to the decode/args tests

**Interfaces:**
- Consumes: Task 3's `renderTemplate`, `installTemplate(_:workbenchID:params:)`, `InstalledRecipe.approvalHash`, `confirm`, `setEnabled`; Task 6's `AutomationDraftColumnModel`.
- Produces: `@MainActor @Observable package final class AutomationTemplatePanelModel` — owned by `AppState` through `AutomationTemplatePanels` (a dictionary keyed by `"<template>|<scope>"`, so an install survives navigation):
  - `init(template: AutomationTemplate, scope: AutomationScopeChoice, cli: AutomationsCLI, refresh: @escaping @MainActor (Int64?) async -> Void, checkDelay: Duration = .milliseconds(500), sleep: …)`;
  - `var params: [String: String]` (empty = the CLI's default; the field's placeholder is the param's `example`), `func paramsChanged()` (debounced `render`);
  - `private(set) var state: State` — `.rendering`, `.rendered(RenderResult)`, `.failed(String)`, `.installing`, `.done(firstID: Int64)`, `.stopped(String, ids: [Int64])`;
  - `var columns: [AutomationDraftColumnModel]` (one per rendered file, `isNew: true`);
  - `var canSave: Bool` — `.rendered` with every file's `validate.ok` and the shown params equal to the rendered ones;
  - `var canAdjustInChat: Bool` — exactly one file (plan's call: **Adjust in Chat** is hidden for a multi-file template such as Release and deploy buttons; the caption says "Install it, then edit each one.");
  - `var adjustText: String?` — the single rendered file's text;
  - `func saveAndTurnOn() async` — `installTemplate` with the rendered params; then, per installed copy in order, `approvalHash == rendered.files[i].validate.approvalHash` → `confirm(id, hash)` → `setEnabled(id, true)`; the first mismatch stops with "This copy differs from what was shown — review it before confirming." and does not confirm that copy or any later one; a confirm or enable failure stops with "Installed, but not confirmed: …" / "Installed and confirmed, but not turned on: …"; nothing is rolled back; `refresh(firstID)` on every end.

- [ ] **Step 1: Write the failing tests** (FakeCLIRunner keyed by subcommand):
  - `testRenderOnAppearAndDebouncedOnParamEdit`: two param edits → one more `install-template … --render --json` with `--param PROJECT=PAY`.
  - `testAuto06_TemplateConfirmsOnlyTheShownHash`: render hash `h1`, install returns `h2` → no `confirm`, no `enable`; `state` is `.stopped` with the differ message and the id.
  - `testSaveAndTurnOnInstallsConfirmsAndEnablesEachCopy`: three-file render + install with matching hashes → argv order `install-template`, `confirm 11 --hash a`, `enable 11`, `confirm 12 …`, `enable 12`, `confirm 13 …`, `enable 13`; `.done(firstID: 11)`.
  - `testConfirmFailureAfterInstallLeavesTheCopy`: confirm throws → no `delete`, no `enable`; `.stopped("Installed, but not confirmed: …")`; a second `saveAndTurnOn` while `.stopped` issues no `install-template`.
  - `testCannotSaveWhileParamsChangedSinceRender`.
  - `testAdjustInChatOnlyForSingleFileTemplates`.
  - `testInstallSurvivesNavigation`: start `saveAndTurnOn` with `install-template` held, drop the view's reference, release → `.done`.
- [ ] **Step 2: Run** `make test-swift FILTER='AutomationTemplatePanelModelTests|AutomationTemplateGalleryTests'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same filter — PASS; `make lint-swift` clean.
- [ ] **Step 5: Commit** `feat(desktop): template panel installs, confirms the shown hash and turns it on`.

### Task 8: Editor chat surface — the owner's panel draft, no Save… message

Depends on: Task 4 (`AutomationScopeChoice`).

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/ChatSurfaces/AutomationEditorChatSurface.swift`
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift` (`automationEditorChat`, `newAutomationEditorChat`)
- Test: `WatchtowerDesktop/Tests/AutomationEditorChatSurfaceTests.swift`

**Interfaces:**
- Produces:
  - `spec(…, panelDraft: @escaping @MainActor () -> String? = { nil }, …)` and `newSpec(…, panelDraft: …)`: when `panelDraft()` is non-nil and differs from the conversation's newest cached draft text, the turn prompt adds `"=== THE DRAFT IN THE OWNER'S PANEL (they may have edited it — draft from this text) ===\n```markdown\n<text>\n```"` before the owner's text.
  - `rulesBlock`: "Draft with `draft_automation` and go through its dry run with the owner. Do not call `save_automation` here: the owner saves from the panel with **Save and Turn On** or **Save Turned Off** under the draft. When the draft is ready, tell them to press it." (replaces "before proposing `save_automation`").
  - `newContextBlock(workbench: nil)` drops the "pick the workbench under **For**" line; instead: "The scope is fixed: if the owner wants it for a workbench, tell them to start a new automation and pick that workbench."
  - Removed: `saveText`, `AutomationEditorChat.askToSave()`. Kept: `dryRunAgain()`, the `save_automation` decision hook (`decided`) for a card the model proposes anyway (the AUTO-06 third-caller path).
  - `AutomationEditorChat.setPanelDraft(_ provider: @escaping @MainActor () -> String?)` (the A4 view hands the center's buffer text to the spec's closure).
  - `AppState.newAutomationEditorChat(contextID: String, scope: AutomationScopeChoice) async throws -> AutomationEditorChat?` (replaces the `workbenchID:` variant; a `.workbench` scope whose workbench is gone opens nothing); `AppState.draftContextID(for scope: AutomationScopeChoice) -> String` starts a new draft id (`automationsViewModel.startNewDraft()`) and returns `AutomationEditorChatSurface.draftContextID(draftID:workbenchID:)`.
- [ ] **Step 1: Write the failing tests:** `testPerTurnPromptCarriesThePanelDraftWhenItDiffers`, `testPerTurnPromptOmitsThePanelDraftWhenItIsTheCachedDraft`, `testRulesTellTheModelNotToProposeSave` (rules contain "Do not call `save_automation` here"), `testNewChatOpensForAnExplicitContextID` (two calls with different context ids → two conversations; same id → same conversation); update `testNewContextBlockPersonal` for the new line.
- [ ] **Step 2: Run** `make test-swift FILTER=AutomationEditorChatSurfaceTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the filter — PASS; `make lint-swift` clean.
- [ ] **Step 5: Commit** `feat(desktop): editor chat drafts from the owner's panel and leaves the save to it`.

### Task 9: `create-automation` skill — the editor chat points to the Save buttons

Depends on: none.

**Files:**
- Modify: `internal/skills/shipped/create-automation.md` ("The procedure" step 3–4, "What Save does")
- Test: `internal/automations/authoring/skill_examples_test.go`

- [ ] **Step 1: Write the failing test** `TestCreateAutomationSkill_EditorSurfaceSavesFromThePanel`: the skill text contains "In the Automations panel's chat" and "**Save and Turn On**" and "**Save Turned Off**", and still contains "Call `save_automation` only with the exact text you drafted" (the main-chat rule stays).
- [ ] **Step 2: Run** `go test ./internal/automations/authoring -run TestCreateAutomationSkill` — FAIL.
- [ ] **Step 3: Edit the skill:** step 4 gains a first sentence — "In the Automations panel's chat (surface `automation_editor`) never call `save_automation`: the draft column beside the chat shows what you drafted, and the owner saves it with **Save and Turn On** (saved, confirmed and on) or **Save Turned Off**. Tell them when the draft is ready." The rest of step 4 is prefixed "In the main chat,". "What Save does" gains one paragraph: a panel save confirms exactly the text in the column and turns it on unless the owner picks **Save Turned Off**; the main chat's card still saves a new recipe off.
- [ ] **Step 4: Run** `go test ./internal/automations/authoring ./internal/skills` — PASS (examples still parse; deploy byte tests follow the embedded file).
- [ ] **Step 5: Commit** `feat(automations): editor skill leaves the save to the panel`.

### Task 10: A2 view — "What is it for?" and "How do you want to start?"

Depends on: Task 4.

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Automations/AutomationNewPanel.swift`
- Modify: `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+Automations.swift`, `DesignShotCatalog.swift`
- Test: create `WatchtowerDesktop/Tests/Core/AutomationNewChoiceTests.swift` (logic in Core: `AutomationNewChoice` below)

**Interfaces:**
- Consumes: Task 4's `AutomationNewFlow`, `AutomationScopeChoice`; `AutomationsViewModel.templates`.
- Produces:
  - Core: `package enum AutomationStart: Hashable { case words; case template(String) }`; `package enum AutomationNewChoice { static func starts(templates: [AutomationTemplate], scope: AutomationScopeChoice) -> [AutomationStart] }` — `.words` first, then the templates whose `scope` matches (`"personal"` / `"workbench"`) in the CLI's order.
  - View: `struct AutomationNewPanel: View { let flow: AutomationNewFlow; let scopes: [AutomationScopeChoice]; let templates: [AutomationTemplate]; let onContinue: (AutomationScopeChoice, AutomationStart) -> Void }` — tiles (`.card(selected:)`) for Personal and each workbench with the Global Constraints copy and the caption; the second list shows **Describe it in words** (selected by default) and the template titles with `AutomationTemplateGallery.summaryLine`; **Continue** is the screen's one `.kitPrimary`. With `flow.fixedScope` the first block is not shown. Templates still loading show a small `ProgressView` row; an empty template list shows only **Describe it in words**.
- [ ] **Step 1: Write the failing tests** `testStartsListWordsFirstThenMatchingTemplates` (personal → words, new-mail-summary, jira-state-report, team-performance-report; workbench → words, pr-review-rounds, release-buttons) and `testNoTemplatesOnlyWords`.
- [ ] **Step 2: Run** `make test-swift FILTER=AutomationNewChoiceTests` — FAIL.
- [ ] **Step 3: Implement** the Core helper and the view; replace the `automation-new-sheet-workbench` shot with `automation-new-panel` (900 × 640, Personal and two workbenches `acme`, `acme-docs`, the five fixture templates) and `automation-new-panel-workbench` (`fixedScope` = acme).
- [ ] **Step 4: Run** the filter — PASS; `make lint-swift`; `make desktop-shots DESKTOP_SHOTS=<scratch dir>` and look at both themes.
- [ ] **Step 5: Commit** `feat(desktop): new automation starts with what it is for`.

### Task 11: A3 view — the template panel

Depends on: Tasks 6, 7.

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Automations/AutomationTemplatePanel.swift`
- Delete: `WatchtowerDesktop/Sources/Views/Automations/AutomationTemplateGalleryView.swift`
- Modify: `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+Automations.swift`, `DesignShotCatalog.swift`

**Interfaces:**
- Consumes: Task 7's `AutomationTemplatePanelModel`; Task 6's `AutomationDraftColumn`.
- Produces: `struct AutomationTemplatePanel: View { @Bindable var model: AutomationTemplatePanelModel; let onAdjustInChat: (String) -> Void; let onDone: (Int64) -> Void }` — header (title, scope `Chip`), description, one `.textFieldStyle(.kit)` per param (label, placeholder = example), notes, the column(s) (one titled block per file for a multi-file template), footer: **Save and Turn On** (`.kitPrimary`, disabled unless `canSave`, "Checking…" while rendering), **Adjust in Chat** (`.kitSecondary`, only when `canAdjustInChat`); `.stopped`/`.failed` messages shown above the footer with the copy from Task 7. `.done(firstID)` calls `onDone`.
- [ ] **Step 1: Add the shot** `automation-template-panel` (1000 × 760) on a `jira-state-report` fixture (param PROJECT empty with placeholder `PAY`, one note, a rendered column), with a FakeCLIRunner answering `--render`.
- [ ] **Step 2: Implement** the view; delete the gallery view and its references.
- [ ] **Step 3: Run** `make test-swift FILTER='AutomationTemplatePanelModelTests|DesignShotsTests'`; `make lint-swift`; `make desktop-shots DESKTOP_SHOTS=<scratch dir>` and look at both themes.
- [ ] **Step 4: Commit** `feat(desktop): template panel in place`.

### Task 12: A4 view — the editor panel

Depends on: Tasks 5, 6, 8.

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Automations/AutomationEditorPanel.swift`
- Create: `WatchtowerDesktop/Sources/Views/Automations/AutomationFormFields.swift` (the field sections of today's `AutomationFormContent` — name, Runs and the schedule picker, Each run may spend, It may chips, outputs, Auto toggles, notes — without its header, Save button, Enabled toggle, sheet or Monaco)
- Modify: `WatchtowerDesktop/Sources/Views/Automations/AutomationEditorChatView.swift` (keep `AutomationEditorChatLoader`; remove `AutomationEditorChatView` and `AutomationChangeInWordsSheet`)
- Delete: `WatchtowerDesktop/Sources/Views/Automations/AutomationFormView.swift`, `AutomationSaveSheet.swift`
- Modify: `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+Automations.swift`, `DesignShotCatalog.swift`
- Test: create `WatchtowerDesktop/Tests/Core/AutomationEditorModeTests.swift`

**Interfaces:**
- Consumes: Task 5 (`beginEdit`, `beginNew`, `adoptChatDraft`, `textChanged`, `canSave`, `commit`, `confirmShown`, `keptAside`, `AutomationDraftFooter`), Task 6 (`AutomationDraftColumn`), Task 8 (`AutomationEditorChat.setPanelDraft`, `newAutomationEditorChat(contextID:scope:)`).
- Produces:
  - Core: `package enum AutomationEditorMode: String, CaseIterable { case chat, form, script }` with `static func initial(toolsAvailable: Bool) -> Self` (`.chat`, or `.form` under ollama — plan's call) and `title` ("Chat", "Form", "Script").
  - View: `struct AutomationEditorPanel: View { let target: AutomationEditorTarget; @Bindable var editor: AutomationEditorCenter; @Bindable var vm: AutomationsViewModel; let makeChat: () async throws -> AutomationEditorChat?; let scopeTitle: String; let onSaved: (Int64) -> Void; let onDiscardDraft: (() -> Void)? }`. Header: name, scope `Chip`, `KitSegmentedPicker` **Chat | Form | Script** (the Chat segment disabled with `AutomationEditorChatSurface.unavailableHelp` when the provider has no tools), a ⋯ with **Discard Draft** for a new draft. Left: `EmbeddedChatView` (focused on open, the `save_automation` card accessory and orphans footer as today) / `AutomationFormFields` / `RecipeEditorView(buffer:)`. Right: `AutomationDraftColumn` (`AutomationDraftColumnModel` from the center's state, the chat's newest entry and `form.detail.recipeText` as the confirmed text for an edit). Footer under the column: the hint, `footer.primary` as `.kitPrimary`, `footer.secondary` as `.kitSecondary`, both disabled with "Checking…" unless `editor.canSave(key)` (a confirm action is enabled when the state is `.review` of the unchanged bytes); the aside line with **Restore**; the save/confirm failure text. On `.done` with `editor.savedIDs[key]` set → `onSaved(id)`.
  - Wiring rules: `.task` opens the chat, then `beginEdit(id, chatNewestText: chat.draft.shownRecipeText)` or `beginNew(key: newDraftKey(conversationID: chat.conversationID), scope:, recipeDir: scope.recipeDir(workspaceDir:), startText: target.startText ?? chat.draft.shownRecipeText)` (the workspace dir comes in from `Navigation`, as `automationsDir` does today); `.onChange(of: chat.draft)` → `adoptChatDraft`; `.onChange(of: form.buffer.textRevision)` → `textChanged`; `chat.setPanelDraft { form.renderedText() }`; the composer prefill from `AutomationNewFlow.composerPrefill` goes into `chat.engine.draft` once.
- [ ] **Step 1: Write the failing test** `AutomationEditorModeTests.testInitialMode` (`true` → `.chat`, `false` → `.form`; titles).
- [ ] **Step 2: Run** `make test-swift FILTER=AutomationEditorModeTests` — FAIL; implement; PASS.
- [ ] **Step 3: Implement** the view and `AutomationFormFields`; move every form-field behaviour test that lived on `AutomationFormModel` unchanged (they are Core tests).
- [ ] **Step 4: Add shots** `automation-editor-panel` (1280 × 800; chat loader that never finishes on the left — the existing never-returning `makeChat` fixture —, the column of an edit with one change, footer "Save and Confirm") and `automation-editor-review` (unchanged bytes of an unconfirmed recipe, footer "Confirm and Turn On"); remove the `NewAutomationSheet` fixture.
- [ ] **Step 5: Run** `make test-swift FILTER='AutomationEditorModeTests|AutomationFormTests|AutomationEditorCenterTests|DesignShotsTests'`; `make lint-swift`; `make desktop-shots DESKTOP_SHOTS=<scratch dir>` and look at both themes.
- [ ] **Step 6: Commit** `feat(desktop): automation editor panel with chat, form and script`.

### Task 13: A1/A5/A6 wiring — the tab on a `PanelSplit`, list, card, segments; sheets removed

Depends on: Tasks 4, 10, 11, 12.

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Automations/AutomationsView.swift` (rewrite: `PanelSplit`, header, sections, panel switch; `AutomationsTabActions`/`AutomationEditorChatHooks` trimmed to what is still called)
- Modify: `WatchtowerDesktop/Sources/Views/Automations/AutomationListRow.swift` (dot, line, chips, `.kitRow(isSelected:)`, draft-row variant)
- Modify: `WatchtowerDesktop/Sources/Views/Automations/AutomationCardView.swift` (header A5; banner **Review…** → `.editor(.existing(id, review: true))`; no Change in words)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/AutomationCardPresentation.swift` (add `toggleMenuTitle(enabled:)`; `Buttons` and its AUTO-06 guard stay as they are)
- Modify: `WatchtowerDesktop/Sources/Views/Automations/ReactionsSectionView.swift` (the "New reaction automation" button becomes the header **+**)
- Modify: `WatchtowerDesktop/Sources/App/AppState+Automations.swift` (`newAutomation(forWorkbench:)` → `vm.showNew(AutomationNewFlow(fixedScope: .workbench(…)))`), `WatchtowerDesktop/Sources/App/Navigation.swift` (hooks: `scopes`, `makeNewChat(contextID:scope:)`, `makeEditChat(id)`, `templatePanel(name:scope:)`)
- Delete: `NewAutomationSheet.swift`, `AutomationConfirmSheet.swift`
- Modify: `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+Automations.swift`, `DesignShotCatalog.swift`
- Test: `WatchtowerDesktop/Tests/Core/AutomationCardPresentationTests.swift`, `WatchtowerDesktop/Tests/Core/AutomationsViewModelTests.swift`, `WatchtowerDesktop/Tests/RunAutomationCommandTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces:
  - Layout: `PanelSplit(isPanelShown: true, width: PanelSplitWidth(key: "automations.detailWidth", range: 640...1600, ideal: 900))` — main = the list column, panel = the detail (plan's call: the kit's `PanelSplit` puts its resizable panel on the trailing edge, which is the spec's "detail on the right"). The section control above both is a `KitSegmentedPicker` (**Automations | Reactions | Tracks**, Tracks only while visible); Reactions and Tracks keep their content (A6).
  - List header: "Automations" (`.title3.weight(.semibold)`), **+** (`Image(systemName: "plus")` with `.kitIcon(isOn: false)`, help "New automation") → `vm.showNew(AutomationNewFlow())`, then `SearchField`. Sections from `AutomationListSections.make` with `SectionHeader(title:count:)`; draft rows open `.editor(.newDraft(contextID:scope:startText: nil))`.
  - Panel switch on `vm.panel`: `.empty` → "Select an automation" (or the tab's `TabEmptyState` with **+**'s action when there is nothing at all); `.card(id)` → `AutomationCardView`; `.new(flow)` → `AutomationNewPanel` whose **Continue** goes to `.editor(.newDraft(contextID: appState.draftContextID(for: scope), scope:, startText: nil))` (composer prefill carried) or `.template(name:scope:)`; `.template` → `AutomationTemplatePanel` (Adjust in Chat → `.editor(.newDraft(…, startText: text))`, done → `vm.showCard(id)`); `.editor(target)` → `AutomationEditorPanel` (saved → `vm.showCard(id)`).
  - Card header (A5): name; scope `Chip` ("Personal" / workbench name) and On/Off `Chip`; **Run Now** (`.kitPrimary`, enabled by `buttons.runNow`), **Edit** (`.kitSecondary`) → `.editor(.existing(id, review: false))`, **⋯** menu with `toggleMenuTitle(enabled:)`, Dry Run (enabled by `buttons.dryRun`), Delete… (confirmation dialog stays). The Change in words button is removed from the view (`AutomationsTabActions.onChangeInWords`/`changeInWordsDisabledHelp` go).
  - `vm.pendingConfirmID` (quick run, header buttons) → `vm.showCard(id)` and clear (plan's call: the card, whose banner leads to A4 — spec A5).
  - Reactions' **+** → `vm.showNew(AutomationNewFlow(fixedScope: .personal, composerPrefill: "When I react to a Slack message with :<emoji>: (trigger slack.reaction_added), "))` and the section switches to Automations.
- [ ] **Step 1: Write the failing tests:** `AutomationCardPresentationTests.testButtonsForStates` (AUTO-06 guard) is **not touched** — it pins `toggleLabel` "Enable"/"Disable" and the help "Disabled — enable it from ⋯", so `Buttons` keeps those values (plan's call: changing them would edit a guard's assertions, which needs the owner; the ⋯ menu shows `toggleMenuTitle(enabled:)` instead and the help copy is raised in Task 15's ask). Add `testToggleMenuTitle` (`true` → "Turn Off", `false` → "Turn On"). `AutomationsViewModelTests.testPendingConfirmOpensTheCard` (setting `pendingConfirmID` and calling the view model's `consumePendingConfirm()` → `panel == .card(id)`, `pendingConfirmID == nil`; add that small method to the VM so the rule is testable without a view).
- [ ] **Step 2: Run** `make test-swift FILTER='AutomationCardPresentationTests|AutomationsViewModelTests'` — FAIL; implement the helper and `consumePendingConfirm()`; PASS (`testButtonsForStates` green unchanged).
- [ ] **Step 3: Rewrite the views** and the AppState/Navigation wiring; delete the remaining sheet files; `grep -rn 'NewAutomationSheet\|AutomationConfirmSheet\|AutomationSaveSheet\|AutomationChangeInWordsSheet\|AutomationTemplateGalleryView\|AutomationFormView(' WatchtowerDesktop/Sources WatchtowerDesktop/Tests` returns nothing.
- [ ] **Step 4: Add shots** `automation-list` (1280 × 760: Personal with two items — one off, one Needs confirmation —, acme with a Draft row and one Paused item, the card of the first selected) and `automation-card` (900 × 720, enabled personal automation with reports and history).
- [ ] **Step 5: Run** `make test-swift FILTER='Automation|QuickRun|RunAutomation|WorkbenchHeaderAutomationButtons|SidebarAutomationsVisibility|DesignShotsTests'`; `make lint-swift`; `make desktop-shots DESKTOP_SHOTS=<scratch dir>` and look at every `automation-*` shot in both themes.
- [ ] **Step 6: Commit** `feat(desktop): automations tab in one panel, no sheets`.

### Task 14: Docs — user guide, feature note, inventory amendment

Depends on: Tasks 1, 2, 9, 13.

**Files:**
- Modify: `docs/guide/features/automations.md` ("Make one", "Run one now" step 2, "Change one"), `docs/guide/features/automations-recipes.md` ("The templates"), `docs/guide/features/automations-safety.md` (confirmation wording)
- Modify: `docs/features/automations.md` (P3 "Desktop" bullets: Tab, List row, Card, Edit form, Save sheet, Confirmation sheet, Change in words / New automation, Templates; "CLI additions"; a new "### The panel (2026-10-21)" subsection; the `CLAUDE.md` index line is not changed)
- Modify: `docs/inventory/automations.md` (AUTO-03 and AUTO-06 text, AUTO-06 guards, Changelog)

- [ ] **Step 1: Guide.** Rewrite per `docs/guide/WRITING.md`: **+** → "What is it for?" → "How do you want to start?" → the chat with the draft beside it → **Save and Turn On** (or **Save Turned Off**); a template opens in the panel with its fields, **Save and Turn On** or **Adjust in Chat**; **Edit** opens the same panel on **Chat**, with **Form** and **Script**; "Needs your confirmation" → **Review…** → **Confirm and Turn On**; quick run on a dimmed row opens the card. Remove every mention of the sheets, **Templates**, **+ New**, **Change in words** and **Form** as a New tab. Keep each page ≤ 8 KB.
- [ ] **Step 2: Feature note.** The new subsection lists: the panel route (`AutomationsPanel`), sections and draft rows (`AutomationDraftRows`, cache files, `-wb<id>` context ids, cache file removed after a panel save), the in-panel save (500 ms debounce, `validate --against`/`--workbench`, `canSave`, the footer table, Save Turned Off disables first, enable after the confirmed save, no rollback), the draft column fields, the template panel (`--render`, hash comparison, multi-file templates without Adjust in Chat), the editor chat's panel-draft block and the skill rule, and v1 limits: a draft edited only in Form is in memory until saved (not a row after a relaunch); leftover `automation_draft` conversations still stay in `chat_conversations`. CLI additions: `validate` `changes`/`changes_known`; `install-template --render` and `installed[].approval_hash`.
- [ ] **Step 3: Inventory — AUTO-06.** In `docs/inventory/automations.md` replace the paragraph that starts "The Desktop confirms only what it showed:" and ends "and a `confirm: true` recipe runs only after **Run** in its sheet or alert." with exactly:

  > The Desktop confirms only what it showed (as amended with the owner's approval in ask #475). Its confirming screen is the draft column of the Automations panel: it shows every hashed field of the exact bytes it saves — the script (through **Show recipe**), permissions, outputs, scope, trigger, missed policy, budget and concurrency — and the hashed fields changed since the confirmed text (`validate --against` `changes`), or says the change is unknown (D26). **Save and Turn On**, **Save and Confirm** and **Save Turned Off** save with `--confirm-hash` = the `approval_hash` `validate` returned for the very bytes saved and `--expect-content-hash` of the file the draft started from (a recipe changed on disk is refused, never overwritten); while a validation is in flight, or the bytes changed since the last one, every save and confirm button is disabled, and a press that finds the bytes changed re-validates instead of saving. **Confirm** and **Confirm and Turn On** on unchanged bytes pass the hash the column displayed (`confirm --hash <shown>`; a stale one is refused and re-read). A draft saved from the panel is enabled unless the owner picks **Save Turned Off**: `enable` runs as a separate owner call after the confirmed save, and **Save Turned Off** on an enabled automation disables it before saving. A template is installed from its panel only after the column showed `install-template --render`'s validation of the rendered text in the chosen scope; **Save and Turn On** then runs `install-template`, which still installs unconfirmed and disabled, and confirms each installed copy only when its `approval_hash` equals the one shown, then enables it — two further owner gestures. A mismatch stops at Needs confirmation; a failed confirm or enable leaves the installed copy in the list with its chip and is never rolled back. Quick run (P3, D27) never runs what the CLI would refuse: a palette or tray row that is unconfirmed, disabled or unreadable runs nothing — it opens the automation's card — and a `confirm: true` recipe runs only after **Run** in its sheet or alert.

  Add to AUTO-06's "P3 Desktop" guard line: `WatchtowerDesktop/Tests/Core/AutomationEditorCenterTests.swift` — `testAuto06_SavePressAfterAnUnflushedEditRechecksInsteadOfSaving`, `testAuto06_SaveDisabledWhileChecking`; `WatchtowerDesktop/Tests/Core/AutomationTemplatePanelModelTests.swift` — `testAuto06_TemplateConfirmsOnlyTheShownHash`; and to the `cmd/automations_templates_test.go` line: `TestInstallTemplate_RenderHashMatchesInstall`.
- [ ] **Step 4: Inventory — AUTO-03.** Replace "or a checked "Keep auto for <tool>" box in the Save sheet (with the saved hash)" with "or a checked "Keep auto for <tool>" box in the Automations panel's draft column (with the saved hash)".
- [ ] **Step 5: Changelog line** (top of `## Changelog`):

  > - 2026-10-21 (Automations in the panel, board #405; spec `2026-10-21-automations-panel-and-inbox-design.md` §A, **AUTO-06 amended, owner approved in ask #475**): strengthening, no guard relaxed. The Desktop's confirming screen moves from the confirmation and Save sheets to the Automations panel's draft column, which shows every hashed field of the exact bytes saved and the changes since the confirmed text (`validate --json` gains `changes`/`changes_known`); a press on changed bytes re-validates instead of saving. A panel save is enabled unless the owner picks **Save Turned Off** (`enable` after the confirmed save; Save Turned Off disables first). A template installs from its panel after `install-template --render` showed its validation; `install-template` stays unconfirmed and disabled (`TestInstallTemplate_InstalledUnconfirmedAndDisabled` unchanged) and the Desktop confirms an installed copy only when its `approval_hash` equals the shown one, then enables it. Quick run on a dimmed row opens the card instead of the sheet (`testDimmedRowOpensInsteadOfRunning` unchanged). Guards whose call sites moved with the sheets keep their names and assertions: `testSaveConfirmsTheValidatedHashOnly` and `testNoAutoOnWithoutACheckedBox` save through `check` + `commit(…, turnOn:)`; `testButtonsForStates` is unchanged (the card's ⋯ shows Turn Off / Turn On from a separate helper). AUTO-03 names the draft column's Keep auto boxes (still unchecked by default). Guards added: `testAuto06_SavePressAfterAnUnflushedEditRechecksInsteadOfSaving`, `testAuto06_SaveDisabledWhileChecking`, `testAuto06_TemplateConfirmsOnlyTheShownHash`, `TestInstallTemplate_RenderHashMatchesInstall`.
- [ ] **Step 6: Run** `go test ./docs/guide` — PASS (8 KB cap, links).
- [ ] **Step 7: Commit** `docs(automations): the panel in the guide, the feature note and AUTO-06`.

### Task 15: Phase gate and the owner's review ask

Depends on: all.

- [ ] **Step 1: Load check** `bash scripts/dev-health.sh` — stop and tell the owner if the last line is `HEALTH: overloaded`.
- [ ] **Step 2: Gate** (each to a log with its exit code): `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`. All exit 0.
- [ ] **Step 3: Shots** `make desktop-shots DESKTOP_SHOTS=<scratch dir>`; look at every `automation-*-light.png` and `-dark.png` (soft fills, no hard borders, one prominent action, nothing clipped): `automation-list`, `automation-card`, `automation-new-panel`, `automation-new-panel-workbench`, `automation-template-panel`, `automation-editor-panel`, `automation-editor-review`, `automation-draft-column`.
- [ ] **Step 4: Owner review ask** (`ask_owner`, review level, in Russian per the owner's rule; the repo text stays English): attach the sixteen PNGs, list the plan's calls for a decision — list as `PanelSplit` main with the detail as the trailing panel; chips (Disabled shown by the dot and "Off · ", not a chip); multi-file templates have no **Adjust in Chat**; Save Turned Off disables before saving; the reaction prefill goes into the composer, unsent; under ollama the editor opens on **Form**; draft rows only for drafts the assistant has drafted at least once; the Run Now help still reads "Disabled — enable it from ⋯" and the menu item "Enable"/"Disable" stays in the guard while the menu shows Turn On / Turn Off — ask whether to amend `testButtonsForStates`' copy. Merge waits for the answer.
- [ ] **Step 5: Commit** any fixes from the review in their own commits; re-run the touched task's inner loop and Step 3.
