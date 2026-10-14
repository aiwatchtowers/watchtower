# Workbench rename — cleanup (board #376: #228, #229)

**Spec:** `docs/superpowers/specs/2026-10-02-workbench-rename-design.md` (§3 boundary rule, §5 legacy folders, §10 later work). This plan adds no new behaviour except where §B says so.
**Branch:** `feature/376-workbench-rename-cleanup`. Lanes A, B and C merge into it, and it reaches `main` as one PR with the owner's go-ahead.

**Boundary rule (verbatim from the spec):** *Storage and wire keep `project`; the domain, the UI and the agent say `workbench`.* That means:
- SQL, `CodingKeys` raw values, JSON tags, notification `userInfo` keys, UserDefaults keys and persisted values do not change.
- The §3 must-not-rename list stays as it is: chat projects, Jira, Claude Code's `--scope project`, and the migrations.
- Test function names stay (A4), including the `Test<Module>NN_` guard names.

## Measured scope (main @ 75ece6745)

| Area | Workbench-side | Excluded (chat/Jira) |
|---|---|---|
| Go `projectID` (code + doc comments) | 370 in 46 files (db 133, tools 84, devpack 47, sessionreport 46, cmd 18, kb 15, workbenchfiles 12, mcp 7, briefing 6, workbenchcheck 2) | 18 |
| Swift Sources `projectID` | 1,110 in 67 files | 132 |
| Swift Sources `project` (`Workbench`-typed vars, params, labels) | 912 | — |
| Swift Tests `projectID` / `project` | 1,310 / 2,310 in 91 files | 152 |
| WatchtowerKit, WatchtowerMobile | 0 | — |

Type and field level is already done in Go (`db.Target.WorkbenchID` with `json:"ProjectID"`, `TerminalSession`, `OwnerAsk`, `tools.Binding`, …) and on the Swift `Target`. What remains are Swift model properties, parameter labels, locals and Go locals and parameters.

The board's "~800" was an underestimate: the real number is about 2,400 `projectID` plus about 3,200 `project`.

**Overlap with work in flight.** The open WT series (#565: #599 and others) and #533 edit `CodeFilesCenter`, `WorkbenchesViewModel+Sessions`, `WorkbenchPageView` and the code-viewer centers. These are the files with the highest counts. A mass Swift rename that lands before those branches merge would give them conflicts on hundreds of lines. Lane B therefore starts only after #565 and #533 are in `main`. Lane A (Go) barely touches those branches.

## Lane A — Go: `projectID` → `workbenchID` (#228)

**A1. Go locals, parameters, unexported fields and doc comments.**
- Rename `projectID` → `workbenchID`, plus `parentProjectID`, `parentProject`, the `projects` local in `briefing/workbenches.go`, the `sessionreport/refresh.go` field, and test locals (`projectTools`, `projectDB`, `projectTarget`, …). Use `gopls rename` per package.
- The briefing placeholder `"(no project activity)"` keeps its wording: customized `briefing.daily` templates match on it (spec A8; renaming it was tried and reverted in review).
- Untouched:
  - every SQL string
  - `json:"ProjectID"` on `db.Target` (MCP `list_targets`/`get_target` output)
  - `json:"project_id"` in `workbenchcheck/check.go` and `cmd/integrate_workbench.go`
  - the chat-side `ChatConversation.ProjectID`, `chat.Prompt.ProjectID` and `cmd/ai_session.go`
  - `ProjectScope` (the A7 alias, lane C)
- Tests: the existing package suites are the safety net (`go test ./internal/{db,tools,devpack,sessionreport,kb,workbenchfiles,mcp,briefing,workbenchcheck} ./cmd/...`), plus `make lint-diff`. Review greps:
  - `\bprojectID\b` outside the excluded files must come back empty
  - the diff must contain no change to any `json:"…"` tag
- Depends on: none.

## Lane B — Swift: workbench-side `projectID` → `workbenchID` (#228)

**B1. Pin the persisted keys before renaming (test first).**
- New Core test: encode `WorkbenchNotificationPolicy.Snapshot` and assert the JSON keys `"projectID"` / `"projectName"` byte for byte. Today they come from implicit `CodingKeys` raw values. Renaming the cases without explicit raw values would silently reset every notification watermark, which re-baselines and drops the new-since-last-time notices.
- Also assert that a snapshot stored by today's build decodes after the rename.
- Depends on: none.

**B2. Model properties in WatchtowerCore.**
- Rename the `projectID` property → `workbenchID` in:
  - `TerminalSession`
  - `SessionAgentStatus`
  - `WorkbenchRoute`
  - `WorkbenchComment`
  - `WorkbenchNotificationPolicy.Notice` and `Snapshot` — with explicit raw values `"projectID"`/`"projectName"`
  - `TerminalSessionQueries.NewSession`
  - `OwnerAsk`
- The `CodingKeys` raw values `"project_id"` and `row["project_id"]` stay.
- Tests: `make test-swift FILTER='Core'` plus B1.
- Depends on: B1.

**B3. Sources: labels, parameters, locals.**
- `projectID:` → `workbenchID:` (about 590 argument labels) and `projectID` locals/properties in the ViewModels, Views and Services: `WorkbenchesViewModel(+Panel/+Sessions/+Git/+Asks/+Report)`, `OwnerAsksViewModel` (`watchedProjectID`), the code-viewer and code-nav centers, `NotificationService`, `AppState`, `TerminalCenter`, and `ChatQuestionEscalator`/`ChatQuestionEscalationPolicy`. The last two are workbench-side despite the `Chat` name.
- Also `projectName` → `workbenchName`, and `project(id:)` → `workbench(id:)`.
- Untouched:
  - the 132 chat-side `projectID` (`ChatConversation`, `ChatProject*`, `ProjectDetailViewModel`, …)
  - the notification `userInfo` literals `"projectId"`/`"type": "project"` (`testKeysKeepTheirPreRenameBytes`)
  - the "Project setup" title match in `TerminalSessionPolicy`
- Depends on: B2. Starts after #565 and #533 merge.

**B4. Tests and test support.**
- Same rename in `Tests/`, including the helpers `TestDatabase.insertWorkbenchTarget(_:projectID:)` and the rest.
- Test function names stay.
- Gate for lane B: unfiltered `make test-swift` once, plus `make lint-all`.
- Depends on: B3.

**B5 (only if the owner picks it). `project: Workbench` locals and labels → `workbench`.** About 900 in Sources and 2,300 in Tests. This is purely cosmetic: the type already says `Workbench`. Depends on: B4.

## Lane B′ — vocabulary before the install status loads (#228, "тест словаря до загрузки статуса")

**B6.**
- `WorkbenchesViewModel.vocabulary(workbenchID:)` falls back to `.current` while the status is unknown. Its doc comment also claims `.current` "when the read failed". In fact `refreshInstallStatus` keeps the last known status after a failed read, so a legacy folder stays `.legacy`.
- Default taken: keep the code (the last known status is the better guess) and fix the comment.
- Tests:
  - first read failed → `.current`
  - legacy read then failed read → `.legacy`
  - the delete-confirmation summary built before the status loads names the current skill
  - the first-run prompt is built only after `refreshInstallStatus`
- If lane C goes ahead, B6 is dropped together with `WorkbenchVocabulary`.
- Depends on: none.

## Lane B″ — `Spell` on read-tool results (#228, "Spell для данных read-тулов")

**B7.**
- In a legacy MCP session (`mcp --project N`), `Binding.Spell` already rewrites tool names in descriptions, schemas, errors and write receipts. It does not touch the success path of read tools (`internal/mcp/actions.go:58-67`) or `get_action`'s `Args`/`Result`.
- So `search_knowledge` hits, `load_skill` bodies and target texts can name tools that the legacy session does not list.
- Fix: spell the marshalled read result the same way `spellSchema` does.
- Test: a legacy-mode read that returns `workbench_board` in a hit comes back as `project_board`.
- If lane C goes ahead, B7 is dropped: `Spell` disappears with the alias.
- Depends on: none.

## Lane C — remove the legacy aliases (#229)

**Precondition (spec §10):** `integrate status` reports `legacy=false` for every workbench. Any workbench still reporting `legacy=true` gets **Re-run Setup** from the owner first; C1 then checks every workbench again.

**C1. Re-check the precondition.**
- Run `integrate status --workbench N --json` for every workbench. All must report `legacy=false`.
- Depends on: the owner's resync.

**C2. Go — serve only the new vocabulary.**
- Remove:
  - the `project` command alias
  - the hidden `--project` flags (`addWorkbenchIDFlag`, `checkWorkbenchIDFlags`, `workbenchFlagName`, `vocabularyFor`)
  - the legacy brief line and the legacy "Setup pending" names
  - the legacy skill name in the Stop-hook reason
  - `resyncVocabulary`'s legacy branch
  - `mcpFlagWorkbenchLegacy` / `Binding.LegacyNames` / `Spell` / `spellSchema`
  - the served `LegacyWorkbenchToolNames`
  - the `project_scope` alias
- **Stays:**
  - a read-only old → new map (`CanonicalToolName`), so `agent_actions` rows stored as `update_project` still resolve (`TestLegacyName_RowStoredUnderAnOldNameStillApplies`)
  - the devpack cleanup of an old folder: `LegacySkillName`, `LegacyMCPServerName`, `legacySuffix`/`looksLikeLegacyHook`, the exclude line, `LegacyPermissionRules`, the codex suffix
  - `TestProj02_RemoveLegacyFolderLeavesNothingInstalled` and `TestProj04_ResyncKeepsAnEditedLegacySkill`
  - the `legacy_*` resync JSON keys (A2)
  - the `.git/info/exclude` markers
  - the `workbenchdocs` skip of `.claude/skills/watchtower-project`
- Depends on: C1.

**C3. Desktop.**
- Remove `WorkbenchVocabulary` and its users:
  - the legacy skill name in `TerminalLaunch` and `WorkbenchDeleteSummary`
  - `vocabulary(…)`
  - the MobileHub slice parameter
- A folder that `integrate status` still reports as `legacy` now counts as `needsRepair`, because its hooks would fail. It no longer gets the orange "Set up by an older Watchtower" hint. Repair still runs the migrating resync.
- Tests: the existing `WorkbenchCLITests.testLegacyFolderStatus` now expects `needsRepair`. `WorkbenchesViewModelResyncTests` keeps the Repair → resync path.
- Depends on: C2.

**C4. Inventory and docs.**
- Inventory: amend DEV-05 ("either spelling") and DEV-06 (the legacy vocabulary and its guard list), and `docs/inventory/workbench.md` (the alias notes and the PROJ-02/04 legacy wording; the guards themselves stay).
- Docs: `docs/features/workbench.md` "Rename" section, and the spec §10 status line.
- Guard tests that pin the alias are removed together with it:
  - `TestMCPProjectMode_LegacyFlagServesTheOldToolNames`
  - `workbench_flags_test`
  - `workbench_names_test`
  - `cmd/workbench_legacy_test`
  - the `project_scope` cases
- **This needs the owner's explicit approval (CLAUDE.md, Behavior Inventory).**
- Depends on: C2, C3.

## Order and lanes

- A, B1, B6/B7 (or C) are independent.
- B2–B5 wait for #565 and #533.
- C waits for the owner to resync any legacy workbench.
- At most one Swift lane at a time.
- Each lane: implementer subagent in its own worktree off the feature branch → `local-review` → merge into the feature branch.
- The final PR → `main` gets `debate-review` and the owner's go-ahead.
