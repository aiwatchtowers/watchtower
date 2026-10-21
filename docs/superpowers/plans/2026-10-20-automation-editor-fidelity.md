# Automation editor fidelity — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The automation editor assistant wraps the owner's procedure as is, can read the workbench's skills and commands, shows every session prompt before save, and a new automation can be created for a workbench.

**Architecture:** One new Go read tool (`workbench_skills`) in the authoring package beside `draft_automation`; rule and SDK text in the shipped `create-automation` skill; WatchtowerCore formatting of dry-run session steps shown on the Draft panel and the save card; a "For" picker in the New automation sheet plus a workbench ⋯ menu entry that feed the editor chat's context.

**Tech Stack:** Go 1.26 (`internal/automations/authoring`, `cmd`), SwiftUI + WatchtowerCore.

**Spec:** `docs/superpowers/specs/2026-10-20-automation-editor-fidelity-design.md`

## Global Constraints

- `workbench_skills` is `AccessRead`, surfaces `main` and `automation_editor`, never in `tools.ReadTools()` (DEV-01).
- It reads only `.claude/commands/*.md`, `.claude/skills/*/SKILL.md`, `.agents/skills/*/SKILL.md` under the workbench folder; lstat only — symlinks and non-regular files are skipped; a `name` containing `/`, `\` or `..` is a validation error.
- Description: frontmatter `description`, else the first non-empty non-heading line, cut to 300 runes. File text cap 64 KiB, `truncated: true` past it.
- Unknown workbench or missing folder → error, never an empty list.
- No change to `AgentToolsContract` / `ActionsContract` (they list write tools only) and no change to AUTO-* guard tests.
- Swift copy: the block title is **"Sessions it starts"**; the unmatched line is **"No dry run of this exact text — the sessions are not shown."**; the scope line is **"For: Personal"** / **"For: workbench <name>"**; the menu item is **"New Automation…"**; the picker label is **"For"**.
- Desktop rules: `docs/review/review-rules.md` "Swift / Desktop conventions"; new UI from `Sources/DesignKit` per `docs/design/desktop-style-guide.md`.

## Review Focus

- A workbench folder under a TCC-protected location: the tool reads only when called with that workbench's id (no probing of other workbenches) — test that listing workbench A never stats workbench B's folder (resolver called once with A's id).
- A skill folder whose `SKILL.md` is a symlink to outside the repo: skipped, not followed — test in Task 1.
- A dry run where a `session()` step's args are clipped (`StepClipBytes`) or not valid JSON: the sessions block shows the title with "(prompt not available)" instead of crashing or hiding the row — test in Task 3.
- Switching the "For" picker after typing in the chat: each scope keeps its own draft conversation; nothing written under one scope is sent under another — test in Task 4 (`draftContextID`).
- The save card on the main chat (no Draft panel): shows neither the sessions block nor the unmatched line — test in Task 3.

---

### Task 1: `workbench_skills` read tool

**Files:**
- Create: `internal/automations/authoring/workbench_skills.go`
- Create: `internal/automations/authoring/workbench_skills_test.go`
- Modify: `cmd/actions_registry.go` (append next to `authoring.NewDraftAutomation`)
- Modify: `cmd/actions_registry_test.go` (`TestAutomationEditorSurface_MountsOnlyDraftSaveAndReads`: add `"workbench_skills"` to the must-be-listed names)

**Interfaces:**
- Consumes: `authoring.Deps.Workbench` (`automations.WorkbenchResolver`, returns `WorkbenchInfo{Folder, …}`).
- Produces: `func NewWorkbenchSkills(d Deps) *tools.Tool`, name `"workbench_skills"`, args `{workbench_id int64 (required), name string (optional)}`; list result `{"skills":[{"name","kind","description"}]}` sorted by name; read result `{"name","kind","text","truncated"}`. Command names are `/<stem>`; skill names are frontmatter `name` else the folder name; `kind` is `"command"` or `"skill"`.

- [ ] **Step 1: Write the failing tests** in `workbench_skills_test.go` with a fake resolver over a `t.TempDir()` folder containing `.claude/commands/release.md` (frontmatter `description: Release Command`), `.claude/skills/deploy/SKILL.md` (no frontmatter, first line `# Deploy`, second `Ships to stage.`), `.agents/skills/lint/SKILL.md`, a symlinked `.claude/skills/evil/SKILL.md` → file outside, and a 70 KiB command `big.md`:
  - `TestWorkbenchSkills_ListsCommandsAndSkills`: names `[/big /release deploy lint]`, `/release` description `"Release Command"`, `deploy` description `"Ships to stage."`, no `evil`.
  - `TestWorkbenchSkills_ReadsOneByName`: `name:"/release"` returns the file text; `name:"/big"` returns 65536 bytes and `truncated: true`.
  - `TestWorkbenchSkills_RefusesPathNames`: `name:"../x"`, `"a/b"` → `*tools.ValidationError`.
  - `TestWorkbenchSkills_UnknownWorkbench`: resolver error → error returned; missing folder → error.
  - `TestWorkbenchSkills_ResolvesOnlyItsWorkbench`: the fake resolver records ids; one call with id 7 records `[7]`.
- [ ] **Step 2: Run** `go test ./internal/automations/authoring -run TestWorkbenchSkills` — expect FAIL (undefined).
- [ ] **Step 3: Implement** `NewWorkbenchSkills`. Description text: "List the skills and slash commands of a workbench folder (.claude/commands, .claude/skills, .agents/skills), or read one by name. Read a skill or command before you wrap it in session(): never guess what it does." Use `os.Lstat` per entry; frontmatter parse = leading `---` block, `description:`/`name:` keys only.
- [ ] **Step 4: Register** in `buildToolRegistry` beside draft/save; update the registry test.
- [ ] **Step 5: Run** `go test ./internal/automations/authoring ./cmd -run 'TestWorkbenchSkills|TestAutomationEditorSurface'` — PASS; `make lint-diff` clean.
- [ ] **Step 6: Commit** `feat(automations): workbench_skills read tool for the editor chat`.

### Task 2: `create-automation` skill — wrap as is, exact SDK returns

Depends on: Task 1 (tool name).

**Files:**
- Modify: `internal/skills/shipped/create-automation.md`
- Modify: `internal/automations/authoring/skill_examples_test.go` (only if a new assertion is needed)

- [ ] **Step 1: Add a failing test** `TestCreateAutomationSkill_WrapRules` in `skill_examples_test.go` asserting the skill text contains the section heading `## Wrapping the owner's procedure`, the string `workbench_skills`, `{session_id}` and `does not count toward`.
- [ ] **Step 2: Run** `go test ./internal/automations/authoring -run TestCreateAutomationSkill` — FAIL.
- [ ] **Step 3: Edit the skill**, after "The interview": the section with the four rules from the spec §1 (as is; additions are a separate question with the reason; never guess — `workbench_skills`, else ask; session prompts in the owner's language). In the SDK table's `session()` row: the return shapes for `wait: "finish"` / `"none"` and the dry-run `{status:"dry_run"}` note. In the limits paragraph: waiting for a session, an ask or a proposal does not count toward `minutes`. Replace the "Release button" example's script with one `session()` that names the workbench's release command and an `output.report` with `s.summary`; keep the `shell("make release")` shape as a second short block in the same example labelled "a plain command".
- [ ] **Step 4: Run** `go test ./internal/automations/authoring -run TestCreateAutomationSkill` — PASS (examples still parse).
- [ ] **Step 5: Commit** `feat(automations): editor skill wraps the owner's procedure as is`.

### Task 3: Sessions on the Draft panel and the save card; scope line

Depends on: none.

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/AutomationCardPresentation.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/SaveAutomationCardModel.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Automations/AutomationDraftPanel.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Chat/AgentActionCardView.swift` (`SaveAutomationCardDetails`, a new `latestDraftSessions` input beside `latestDraftText`)
- Modify: `WatchtowerDesktop/Sources/Views/Automations/AutomationEditorChatView.swift` (pass it)
- Test: `WatchtowerDesktop/Tests/Core/…AutomationCardPresentationTests.swift`, `…SaveAutomationCardModelTests.swift` (existing files)

**Interfaces:**
- Produces: `package struct AutomationSessionPrompt: Equatable, Sendable { kind: String; title: String; prompt: String? }` and `package static func sessionPrompts(_ steps: [AutomationDraftEntry.Step]) -> [AutomationSessionPrompt]` (steps of kind `session` and `agent`, in seq order; `prompt` nil when args are not JSON or lack `prompt`; `title` = args `title`, else `"session"`/`"agent"`). `SaveAutomationCardModel.scopeLine(workbenchName: (Int64) -> String?) -> String` — `"For: Personal"` without `workbench_id`, `"For: workbench <name>"` (fallback `#<id>`).

- [ ] **Step 1: Write failing tests:** `sessionPrompts` over a session step with `{"title":"Release","prompt":"Run /release"}`, an agent step, an `llm` step (ignored) and a session step with clipped args (`prompt` nil); `scopeLine` for no id, id 1 → "watchtower", id 9 unknown → `"For: workbench #9"`.
- [ ] **Step 2: Run** `make test-swift FILTER='AutomationCardPresentationTests|SaveAutomationCardModelTests'` — FAIL.
- [ ] **Step 3: Implement** the two functions; decode `workbench_id` in `SaveAutomationCardModel.Args`.
- [ ] **Step 4: Views:** Draft panel shows a "Sessions it starts" block above the steps when non-empty — title, then the prompt (`lineLimit(2)`, expandable; "(prompt not available)" when nil). The save card shows the scope line first, and in the editor chat the same block from the latest draft entry whose recipe text equals the card's; when the editor has a draft but none matches, the unmatched line; on the main chat (`latestDraftText == nil`) neither.
- [ ] **Step 5: Run** the filter again — PASS; `make lint-swift` clean; `make desktop-shots` look at the Draft panel and card.
- [ ] **Step 6: Commit** `feat(desktop): show session prompts and scope before an automation is saved`.

### Task 4: "For" picker and New Automation… from the workbench

Depends on: none (run after Task 3 — one Swift lane).

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/ChatSurfaces/AutomationEditorChatSurface.swift` (`newContextBlock` → `static func newContextBlock(workbench: (id: Int64, name: String, folder: String)?) -> String`; `newSpec(…, workbench:)`; `static func draftContextID(draftID: String, workbenchID: Int64?) -> String` = `draftID` or `"\(draftID)-wb\(id)"`)
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift` (`newAutomationEditorChat(workbenchID: Int64?)`, resolving name/folder from the workbenches view model)
- Modify: `WatchtowerDesktop/Sources/Views/Automations/NewAutomationSheet.swift` (a "For" `Picker`: Personal + workbenches; the chat reloads per scope; Form shows "The form makes personal automations only." when a workbench is picked; Template passes the pick to the gallery)
- Modify: `WatchtowerDesktop/Sources/Views/Automations/AutomationsView.swift` (pass workbenches and the initial pick; observe `vm.pendingNewWorkbenchID` like `pendingConfirmID`)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/…/AutomationsViewModel.swift` (`var pendingNewWorkbenchID: Int64?`)
- Modify: `WatchtowerDesktop/Sources/App/AppState+Automations.swift` (`func newAutomation(forWorkbench id: Int64)`: set the pending id, `selectedDestination = .automations`)
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkbenchHeaderControls.swift` (`moreMenu`: "New Automation…" calling a new `onNewAutomation` closure supplied by the page)
- Test: `WatchtowerDesktop/Tests/…/AutomationEditorChatSurfaceTests.swift`

- [ ] **Step 1: Failing tests:** `newContextBlock(workbench: nil)` contains `Scope: personal`; with `(1, "watchtower", "watchtower")` contains `Scope: workbench 1 (watchtower, folder watchtower)`, ``Always pass `workbench_id: 1` `` and `workbench_skills`; `draftContextID("d", nil) == "d"`, `draftContextID("d", 1) == "d-wb1"`; the existing CLI-flag pins still hold.
- [ ] **Step 2: Run** `make test-swift FILTER=AutomationEditorChatSurfaceTests` — FAIL.
- [ ] **Step 3: Implement** the surface changes, then AppState, sheet, view model, menu.
- [ ] **Step 4: Run** the filter — PASS; `make lint-swift`; `make desktop-shots` the sheet with a workbench picked.
- [ ] **Step 5: Commit** `feat(desktop): create an automation for a workbench`.

### Task 5: Docs

Depends on: Tasks 1–4.

**Files:**
- Modify: `docs/features/automations.md` (P3 editor section: `workbench_skills`, the For picker, the sessions block, the scope line; remove the line-286 "Left: …" follow-up)
- Modify: `docs/guide/features/automations.md` (per `docs/guide/WRITING.md`: For picker, New Automation… in the workbench ⋯ menu, "Sessions it starts" on the save card)
- Modify: `CLAUDE.md` Automations bullet only if it names the editor's tools.

- [ ] **Step 1:** Edit; run `go test ./docs/guide/` — PASS.
- [ ] **Step 2: Commit** `docs(automations): workbench scope at creation, session prompts on save`.
