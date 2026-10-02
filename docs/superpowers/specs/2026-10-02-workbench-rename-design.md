# Workbench rename — design

**Date:** 2026-10-02 · **Status:** owner decisions recorded 2026-10-02; ready for planning · **Ships as:** one PR `feature/workbench-rename` → `main`

Watchtower has two unrelated things called "Project":

- **AI Chat projects** — `chat_projects` / `chat_project_sources` (migration 00076), Swift `ChatProject`, `Views/Chat/ProjectDetailView`, `ai session --project-id`. These **keep** the name "Projects". It is the same meaning as Projects in claude.ai and ChatGPT.
- **Folder-bound boards that Claude Code works** (`docs/features/projects.md`, PROJ-01..08, DEV-06). These are **renamed to Workbench**.

This spec covers the rename of the second thing. It is a naming change, not a behaviour change. Every contract in `docs/inventory/projects.md` and DEV-06 holds with the same meaning. The only new behaviour is the compatibility layer for folders set up before the rename (§5).

---

## 1. Owner decisions (recorded, not open)

| # | Decision |
|---|---|
| O1 | AI Chat projects keep "Projects". The folder-bound boards become **Workbench**. |
| O2 | The rename covers everything the owner and the agent see: UI strings, docs, the inventory wording (PROJ-01..08 keep their numbers and meaning; rewording approved), CLI, MCP server name, tool names and the skill. |
| O3 | Go packages, types and files, and Swift types, views and files, are renamed. Chat project code (`ChatProject…`) is untouched. |
| O4 | **The DB schema does not change.** Tables `projects`, `project_sources`, `project_documents`, `project_comments`, `project_target_images`, the columns `targets.project_id` and `terminal_sessions.project_id`, and all triggers stay. `internal/db/schema.sql` gains one mapping comment. |
| O5 | The sidebar tab is **"Workbench"** (singular, like Inbox and Calendar). Its items are "workbenches". The + menu reads **New Workbench…** / **Add Existing Folder…**. |
| O6 | Folders that are already connected migrate **only by a manual resync**: CLI `watchtower workbench resync <id>`, or the Desktop's existing **Re-run Setup**. Nothing resyncs automatically on an app or daemon update. Until a folder is resynced it must keep working. `watchtower project …` and `watchtower mcp --project N` stay as hidden aliases. |
| O7 | The whole rename ships as **one PR**. Sub-tasks are branches merged into `feature/workbench-rename`. Nothing partial reaches `main`. |
| O8 | Any further open question gets the conservative, easily reversible answer, listed in §2. |

## 2. Decisions taken without the owner (conservative, reversible)

| # | Decision | Why it is the safe choice | Reversal |
|---|---|---|---|
| A1 | **Persisted identifiers keep their bytes.** This covers DB values (`custom_label='project'`, `agent_actions.surface='project'`, `agent_actions.context_type='project'`, the kb source `project_doc`, briefing attention `source_type="project"`), the on-disk store `<workspace>/project_files/<id>/`, the UserDefaults keys `projects.*`, the `sidebar.hiddenItems` raw value `projects`, the notification `userInfo` `"type": "project"` / `projectId`, and the `.git/info/exclude` block markers. Code constants that hold these values are renamed (`workbenchSurface = "project"`), and each carries a one-line comment explaining why the value is legacy. | No data migration, no lost layout, no orphaned notification route. It follows the persona-merge precedent of stable legacy identifiers. | A later PR can migrate any one of them on its own. |
| A2 | **CLI `--json` keys stay** (`project_id` in `integrate status --json`, `id`/`docs_ok`/… in `resync --json`, the `create`/`delete`/`attach-doc`/`check` payloads). New fields are only ever added. | These are a Go↔Swift dual-path wire contract. Old Desktop builds and new CLI builds, or the reverse, keep decoding. | Rename the keys in a later PR once both sides ship together. |
| A3 | **MCP result keys the agent reads are renamed** (`project_id` → `workbench_id` in `workbench_board` / `workbench_info`). | Nothing persists them, and the skill never names them. | Trivial. |
| A4 | **Test function names are not renamed**, in Go or Swift. Guard tests keep `TestProjNN_…` / `testProjNN_…`, and so do other cited tests (`TestProjectResync_IsAdditive`, `TestProjectMode_…`, `TestProjectBinding_…`). Test **files** and Swift test **classes** follow their subject's new name. The inventory updates the file paths only. | The CLAUDE.md guard-test rule: no renaming out of `Test<Module>NN_`, and the inventory traceability stays intact. `PROJ-NN` ids are kept. | A later cosmetic PR can rename non-guard tests. |
| A5 | **The `.git/info/exclude` block markers stay** (`# >>> watchtower-project: managed by …`). Only the skill path line inside the block changes. | Changing a marker would orphan the existing block in every connected folder. The owner never reads these lines. | Read both markers and write the new one, later. |
| A6 | **Owner permission rules are not rewritten.** Rules such as `mcp__watchtower-project__update_target` in the folder's `settings.local.json`, or in `~/.claude/settings.json`, are left alone. `resync` lists them in its suggestions so the owner can re-allow them under the new name. | PROJ-04: we never change the owner's content. | Resync can additively copy them later, with owner approval. |
| A7 | **`project_scope` stays accepted** on `search_knowledge` as a deprecated alias of `workbench_scope`. Its schema description reads "deprecated alias of workbench_scope". Sending both is refused. | The pre-rename skill tells the agent to use `project_scope`. The MCP SDK validates input against the schema, so a hidden alias would be rejected. | Drop it one release after the last legacy folder is resynced. |
| A8 | **Briefing:** the block header becomes `=== WORKBENCHES ===` and `briefing.daily` moves to v9. A customized stored template keeps working unchanged. | This is the existing prompt-store auto-upgrade path. Attention items keep `source_type="project"` (A1). | Roll back to v8. |
| A9 | **The sidebar enum case is renamed** `.workbench` with an explicit `rawValue` `"projects"`. | `sidebar.hiddenItems` persists raw values (A1). | — |
| A10 | **The Desktop nudges but never acts.** A legacy folder shows the existing orange install icon with the tooltip "Set up by an older Watchtower — Re-run Setup to update". The session brief adds one line asking the agent to suggest Re-run Setup to the owner. | O6 forbids an automatic resync. The nudge is read-only. | Remove the line or tooltip. |
| A11 | **Historical docs are not rewritten.** Earlier specs, plans, audits, `docs/review/review-lessons.md` and dated changelog entries keep "project". Only living docs change (§7). | Dated records should say what was true on their date. | — |

---

## 3. Vocabulary and the boundary rule

> **Storage and wire keep `project`; the domain, the UI and the agent say `workbench`.**

- *Storage* covers SQL table and column names, DB values, on-disk paths, UserDefaults keys and persisted enum raw values. All of it is unchanged (O4, A1).
- *Wire* covers CLI `--json` keys and notification `userInfo`. Both are unchanged, and new keys are only added (A2).
- *Domain, UI and agent* cover Go and Swift identifiers, files and packages, UI strings, CLI command and flag names, MCP server and tool names, tool descriptions and errors, the skill, the brief, the briefing and docs. All of them are renamed.

Singular is **Workbench**, plural **workbenches**. In code, use `Workbench` / `Workbenches` / `workbench`. The `Projects` → `Workbenches` plural form is used only where the old name was plural.

### Must-not-rename collisions

These contain "project" but are **not** this feature. The rename never touches them. Each implementer brief lists them, and a review grep checks them.

| Area | Identifiers kept |
|---|---|
| AI Chat projects | `chat_projects`, `chat_project_sources`, `ChatProject*`, `ChatProjectQueries`, `ChatProjectSource`, `db.ChatProjectContext`, `chat_conversations.project_id`, Swift `ChatConversation.projectID`, `ChatModels…projectID`, `Views/Chat/ProjectDetailView.swift`, `Views/Chat/ProjectSourcePickerSheet.swift`, `ViewModels/ProjectDetailViewModel.swift` (+ `Tests/ProjectDetailViewModelTests.swift`), `internal/chat/project_attachments.go`, `internal/chat/claude_backend_project_test.go`, `projectBlock`/`projectBlocks`/`projectPending` in `internal/chat`, `ai session --project-id`, the chat sidebar "Projects" group |
| Jira | `jira_project`, `list_jira_projects`, `project_key`, `ListJiraProjectKeys`, `GetKnownProjectKeys`, `jira create --project`, `jira project-map`, `internal/jira/project_map.go`, Swift `ProjectMapView` / `ProjectMapViewModel`, `SidebarDestination.projectMap`, the source kinds "Jira project" inside workbench sources and tool texts |
| Claude Code's own terms | `integrate --scope project` (the cwd skills scope), `claude mcp add --scope local`, `~/.claude/projects/*/<id>.jsonl` transcripts, "project memory" in the app guide |
| Other features | Track category `"project"` (`Track.swift`, `TracksListView`), memory "people, projects and beliefs", feature registry descriptions |
| Generic Desktop pieces used by workbenches | `TerminalCenter`, `TerminalLaunch`, `TerminalSessionOrder`, `TerminalSessionPolicy`, `WorkspaceLayout`, `WorkspacePaneView`, `CommentAnchor`, `DocumentTextView`, `CommentableDocumentText`, `PanelResizeHandle`, `TerminalsSection`, `WorkOnTargetButton` (no "project" in the name; only their contents change) |
| Migrations | `00081_projects.sql` … `00089`, and the migration tests `projects_migration_test.go`, `project_status_rollup_migration_test.go`, `proj05_*`, `proj06_*` (named after the migration, not the feature) |

---

## 4. Old → new mapping

Counts were measured on `origin/main` at `a38e795c` with `grep`.

### 4.1 Owner-facing UI (Swift strings)

There are about 64 string literals mentioning "project" in workbench files, plus `App/` and `Settings`. The main ones:

| Old | New |
|---|---|
| Sidebar "Projects" (`SidebarDestination.projects`) | "Workbench" (case `.workbench`, rawValue `"projects"` — A9) |
| "Projects unavailable" | "Workbench unavailable" |
| Panel header "Projects", "Toggle Projects Panel", "Back to Projects" | "Workbenches", "Toggle Workbench Panel", "Back to Workbenches" |
| + menu "New Project…" / "Add Existing Folder…", `.help("New project…")`, NSSavePanel "New Project" / "Project name:" | "New Workbench…" / "Add Existing Folder…", "New workbench…", "New Workbench" / "Workbench name:" |
| "Pick a folder to start a project…" | "Pick a folder to start a workbench…" |
| "Delete Project", "Project actions" | "Delete Workbench", "Workbench actions" |
| `NewProjectFolder` error "…to make a project of it." | "…to make a workbench of it." |
| "Claude Code creates the board through the watchtower-project tools." | "…through the watchtower-workbench tools." |
| Settings → Notifications "Project notifications" | "Workbench notifications" |
| Briefing attention label *Project* (`BriefingDetailView` `case "project"`) | *Workbench* (the case value stays `"project"`, A1) |
| Delete confirmation (`ProjectDeleteSummary`) "the watchtower-project skill … the watchtower-project MCP connection" | the new names. For a legacy folder it names what is actually installed (§5.4) |
| Tray quit alert "Send them from the project's …" | "…from the workbench's …" |
| `ProjectNotificationPolicy` notice titles and bodies | "workbench" wording |

### 4.2 CLI

| Old | New | Old form kept? |
|---|---|---|
| `watchtower project create\|list\|show\|board\|import-docs\|attach-doc\|delete\|brief\|check\|resync` | `watchtower workbench …` (same subcommands and flags) | **yes**: cobra `Aliases: ["project"]`. It is absent from the root command list and shown only in `workbench --help` |
| `project brief --project N` (SessionStart hook) | `workbench brief --workbench N` | **yes**: hidden `--project` flag (`MarkHidden`, no deprecation notice, because stdout and stderr belong to Claude Code's hook) |
| `project check --project N [--stop-hook]` (Stop hook) | `workbench check --workbench N [--stop-hook]` | **yes**, the same way |
| `watchtower mcp --project N` | `watchtower mcp --workbench N` | **yes**, hidden. It also selects the legacy tool vocabulary (§5.2) |
| `integrate claude-code\|status\|remove --project N` | `… --workbench N` | **yes**, hidden |
| `--project` and `--workbench` together | refused: "--project is the old name of --workbench; pass one" | — |
| `integrate --scope project`, `ai session --project-id`, `jira create --project` | unchanged (§3) | — |
| Help texts: "Manage folder-bound projects…", "Create a project bound to a folder", … (about 25 `Short`/`Long` strings in `cmd/project*.go`, `cmd/mcp.go`, `cmd/integrate.go`) | "workbench" wording | — |
| `--json` keys | unchanged (A2), plus the new `legacy*` fields (§5.4) | — |

**How the alias is built:** `projectCmd` becomes `workbenchCmd` with `Use: "workbench"` and `Aliases: []string{"project"}`. Each command that took `--project` registers `--workbench` as the real flag and `--project` as a hidden flag bound to the same variable through a small helper (`addWorkbenchIDFlag(cmd, &v)`). The helper also records which spelling was used (`cmd.Flags().Changed("project")`), because brief, check and mcp need that signal (§5.2).

### 4.3 MCP server, tools and skill

| Old | New |
|---|---|
| Registered server name `watchtower-project` (`devpack.ProjectMCPServerName`) | `watchtower-workbench` (`WorkbenchMCPServerName`); `LegacyMCPServerName = "watchtower-project"` is kept for detection and removal |
| Registration argv `… mcp --project N` | `… mcp --workbench N` |
| Tool `project_info` | `workbench_info` |
| Tool `project_board` | `workbench_board` |
| Tool `update_project` | `update_workbench` |
| Tool `add_project_source` | `add_workbench_source` |
| Tool `remove_project_source` | `remove_workbench_source` |
| `create_targets`, `update_target`, `attach_document`, `list_comments`, `add_comment`, `resolve_comment`, `get_target`, … | unchanged (neutral names) |
| `search_knowledge` argument `project_scope` | `workbench_scope`; `project_scope` stays as a deprecated alias (A7) |
| `search_knowledge` source filter `project_doc` | unchanged (a stored kb source value, A1); its description reads "this workbench's attached documents; workbench sessions only" |
| Errors: "this tool works only in a project session (watchtower mcp --project N)", "project N no longer exists", "… is not in this project", "project_doc is searchable only from that project's own session", "this project has no usable Slack channel…" | "workbench session (watchtower mcp --workbench N)", "workbench N no longer exists", "… is not in this workbench", … (16 test literals pin these strings; §8) |
| Tool descriptions (about 260 lines mention "project" across `internal/tools/{projects,project_docs,project_targets,project_images,project_knowledge,knowledge,targets_read}.go`; "Jira project(s)" inside them stays) | "workbench" wording |
| Skill `watchtower-project` (`internal/devpack/projectskill/watchtower-project/SKILL.md`, 121 lines, 19 lines mention project; frontmatter `name`, the `mcp__watchtower-project__<tool>` prefix, 5 tool names, `project_scope`) | `watchtower-workbench` at `internal/devpack/workbenchskill/watchtower-workbench/SKILL.md` (same DEV-04 marker) |
| Exclude line `/.claude/skills/watchtower-project/` | `/.claude/skills/watchtower-workbench/` (markers unchanged, A5) |
| Desktop argv prompts (`TerminalLaunch.firstRunPrompt`, `TerminalLaunch` work-on prompt, `ProjectCommentPrompt`): "…this Watchtower project using the watchtower-project skill." / "Work on target #N using the watchtower-project skill." / "Address … using the watchtower-project skill." | "…this Watchtower workbench using the watchtower-workbench skill." and the same pattern. A **legacy** folder gets the old skill name (§5.3) |
| Brief (`cmd/project_brief.go`): `Watchtower project #N "name" — folder`, "Recent in project sources (last 14 days):", "Setup pending: run the watchtower-project skill's setup (project_info, update_project, first board)." | `Watchtower workbench #N "name" — folder`, "Recent in workbench sources …", "Setup pending: run the watchtower-workbench skill's setup (workbench_info, update_workbench, first board)." The legacy variant is in §5.2 |
| `Board language:` line (`tools.BoardLanguageLine`) | unchanged (it has no "project" in it) |
| `project check` Stop-hook reason "(update_target; the watchtower-project skill's \"Keeping the board in step with git\")" | the skill name that matches the invocation's vocabulary (§5.2) |
| `project resync` suggestion "ask Claude Code to run the watchtower-project skill's setup" | the new skill name, plus the legacy and permission notes (§5.4) |
| Briefing `=== PROJECTS ===`, prompt text "Watchtower projects — folder-bound boards…" (`internal/prompts/defaults.go`) | `=== WORKBENCHES ===`, "Watchtower workbenches — …", `briefing.daily` v9 (A8) |

### 4.4 Go code

Totals: 61 Go files have "project" in their name (excluding `internal/chat`), with about 2,750 lines that mention it. About 19 more files reference the feature's identifiers.

**Packages**

| Old | New |
|---|---|
| `internal/projectcheck` | `internal/workbenchcheck` |
| `internal/projectdocs` | `internal/workbenchdocs` |
| `internal/projectfiles` | `internal/workbenchfiles` |
| `internal/devpack/projectskill/` | `internal/devpack/workbenchskill/` |

**Files** (`git mv`, so rename detection keeps history)

| Old | New |
|---|---|
| `cmd/project.go`, `project_brief.go`, `project_brief_session.go`, `project_check.go`, `project_resync.go`, `integrate_project.go` (+ `_test.go`, `project_images_test.go`) | `cmd/workbench*.go`, `cmd/integrate_workbench.go` (+ tests) |
| `internal/briefing/projects.go` (+test) | `internal/briefing/workbenches.go` |
| `internal/db/projects.go`, `project_board.go`, `project_comments.go`, `project_folder.go`, `project_images.go`, `project_targets.go` (+ tests) | `internal/db/workbenches.go`, `workbench_board.go`, `workbench_comments.go`, `workbench_folder.go`, `workbench_images.go`, `workbench_targets.go` |
| `internal/devpack/project.go`, `project_settings.go` (+ tests, `project_stop_hook_test.go`) | `internal/devpack/workbench.go`, `workbench_settings.go`, … |
| `internal/kb/source_project.go` (+test) | `internal/kb/source_workbench.go` |
| `internal/mcp/project_test.go` | `internal/mcp/workbench_test.go` |
| `internal/tools/projects.go`, `project_docs.go`, `project_images.go`, `project_knowledge.go`, `project_scope.go`, `project_targets.go` (+ tests, `project_targets_git_test.go`, `registry_project_test.go`) | `internal/tools/workbenches.go`, `workbench_docs.go`, … |
| Migration files and migration tests | **unchanged** (§3) |

**Identifiers.** About 140 non-test declarations. The rule is `Project` → `Workbench` and `Projects` → `Workbenches`, applied type-aware with `gopls rename` so that chat `ProjectID` fields and Jira `ProjectKey` stay put. Representative examples:

| Old | New |
|---|---|
| `db.Project`, `ProjectDocument`, `ProjectComment`, `ProjectCommentFilter`, `ProjectSource`, `ProjectTargetImage`, `ProjectTargetInput` | `db.Workbench`, `WorkbenchDocument`, `WorkbenchComment`, … |
| `db.CreateProject`, `GetProject`, `ListProjects`, `DeleteProject`, `ResolveProjectFolder`, `GetProjectBoard`, `CreateProjectTargetsTx`, `ListProjectTargetImages`, `ImportProjectDocuments`, `AttachOwnerProjectDocument`, `SeedTestProjectTarget`, … | `CreateWorkbench`, `GetWorkbench`, … |
| `db.ErrProjectNotFound`, `db.ErrNotInProject` | `ErrWorkbenchNotFound`, `ErrNotInWorkbench` |
| `db.Target.ProjectID`, `TargetFilter.ProjectID`, `TerminalSession.ProjectID`, `tools.Binding.ProjectID`, `kb.Request.ProjectID`, `kb.DocOptions.ProjectID` | `…WorkbenchID`. **Every SQL string keeps `project_id`.** |
| `tools.ProjectTools`, `NewProjectInfo`, `NewProjectBoard`, `NewUpdateProject`, `NewAddProjectSource`, `NewRemoveProjectSource`, `ProjectKnowledgeScope`, `ResolveProjectDocumentPath`, `ProjectAlive`, `projectSurface`, `ProjectContextType` | `WorkbenchTools`, `NewWorkbenchInfo`, …, `workbenchSurface = "project"`, `WorkbenchContextType = "project"` (A1) |
| `devpack.InstallProject`, `RemoveProject`, `StatusProject`, `ProjectInstallOptions`, `ProjectInstallReport`, `ProjectStatus`, `ProjectSkill`, `ProjectSkillName`, `ProjectHookCommand`, `ProjectStopHookCommand`, `ProjectMCPCommand`, `ProjectMCPServerName` | `InstallWorkbench`, …, plus `Legacy*` constants (§5) |
| `kb.IndexProjectDocs`, `indexAllProjectDocs` | `IndexWorkbenchDocs`, … |
| `briefing.gatherProjects`, `renderProjectActivity` | `gatherWorkbenches`, … |
| `cmd` `runProject*`, `mcpProjectOptions`, `projectRemoveInstall`, `*JSON` structs | `runWorkbench*`, `mcpWorkbenchOptions`, … (struct JSON tags unchanged, A2) |
| `internal/chat` `projectBlock`, `ProjectAttachments`, … ; Jira `syncProject`, `ProjectMap*` | **unchanged** (§3) |

`internal/db/schema.sql` gains one line above the `projects` block: `-- Workbench (the folder-bound boards; renamed 2026-10-02): the projects* tables, targets.project_id and terminal_sessions.project_id keep their names.` `TestSchemaGolden` dumps `sqlite_master` from the migrations, not from `schema.sql`, so the golden file does **not** change. No migration is added.

### 4.5 Swift code

Totals: 69 workbench files in `Sources` and `Tests` (excluding the chat and Jira files in §3), with about 2,340 lines that mention "project", plus about 27 other files that reference their types.

| Old | New |
|---|---|
| `Views/Projects/` (20 files: `ProjectsView`, `ProjectPageView`, `ProjectBoardView`, `ProjectBoardCardView`, `ProjectBoardKanbanView`, `ProjectDocumentsView`, `ProjectDocumentsList`, `ProjectDocumentThreadsPanel`, `ProjectCommentsSendBar`, `ProjectCommentDraftRow`, `ProjectDriftBanner`, `ProjectSessionView`, `ProjectSessionsPanel`, `ProjectTargetDetailCard`, `ProjectTargetImagesSection`, `AddProjectDocumentSheet`, + 4 generic files) | `Views/Workbench/` (`WorkbenchesView`, `WorkbenchPageView`, `WorkbenchBoardView`, …, `AddWorkbenchDocumentSheet`) |
| `ProjectsViewModel` (+`+Panel`, `+Sessions`), `ProjectBoardViewModel`, `ProjectDocumentViewModel` | `WorkbenchesViewModel`, `WorkbenchBoardViewModel`, `WorkbenchDocumentViewModel` |
| `Services/ProjectCLI`, `ProjectNotificationCenter`, `ProjectInstallStatus`, `ProjectCreated`, `ProjectDeleted`, `ProjectResynced`, `ProjectDocsReport`, `ProjectDocumentAttached` | `WorkbenchCLI`, `WorkbenchNotificationCenter`, … |
| WatchtowerCore `Models/Project.swift` (`Project`, `ProjectSummary`, `ProjectRoute`, `ProjectPane`, `ProjectSubject`, `ProjectDocument`, `ProjectComment`, `ProjectCommentThread`, `ProjectTargetImage`, `ProjectDocumentListItem`), `ProjectDrift.swift`, `Queries/ProjectQueries(+Activity)`, `ProjectActivityReading`, `DefaultProjectActivityReader`, `ProjectQueryError` | `Workbench.swift` (`Workbench`, `WorkbenchSummary`, `WorkbenchRoute`, …), `WorkbenchDrift.swift`, `WorkbenchQueries`, … |
| WatchtowerCore services `NewProjectFolder`, `ProjectBoardCard`, `ProjectBoardKanban`, `ProjectBoardOutline`, `ProjectBoardOrder`, `ProjectCommentDrafts`, `ProjectCommentPrompt`, `ProjectDeleteSummary`, `ProjectDocumentGrouping`, `ProjectFolderPolicy`, `ProjectImageLoader`, `ProjectNotificationPolicy` | `NewWorkbenchFolder`, `WorkbenchBoardCard`, … |
| Workbench-side `ProjectDetailSectionHeader`, `ProjectDetailMenuLabel` (inside `ProjectTargetDetailCard.swift`) | `WorkbenchDetailSectionHeader`, `WorkbenchDetailMenuLabel`. Note the collision: the chat `ProjectDetailViewModel` / `ProjectDetailView` keep their names |
| `AppState.projectsViewModel`, `navigateToProject`, `routeProject`, `Target.projectID` (Swift property; `CodingKeys` keep `"project_id"`) | `workbenchesViewModel`, `navigateToWorkbench`, `routeWorkbench`, `Target.workbenchID` |
| Tests: `Tests/Core/Project*Tests.swift` (15), `Tests/Project*Tests.swift` (14), `Tests/Support/TestDatabase+Projects.swift` | `Workbench*Tests.swift`, `TestDatabase+Workbenches.swift`. Test functions keep their names (A4) |
| UserDefaults `projects.layout.<id>`, `projects.panelWidth`, `projects.panelVisible`, `projects.viewedDocuments`, `projects.sessionOrder.<id\|standalone>`, `projects.boardMode.<id>`, `projects.boardKanbanFilter.<id>`, `projects.notifications`, `projects.notificationSnapshot.<id>` | **keys unchanged** (A1). The Swift constants that hold them are renamed. Losing these keys would silently reset every layout, panel width, board mode and the notification watermark (a burst of re-notifications) |
| `WatchtowerDesktop/Package.swift` comment "Projects tab" | "Workbench tab" |

---

## 5. Migration of already-connected folders

### 5.1 What a connected folder holds today

A folder set up by `integrate claude-code --project N` contains these items:

1. `.claude/skills/watchtower-project/SKILL.md` with the DEV-04 marker and a shipped-digest sidecar.
2. `.claude/settings.local.json` → `SessionStart`: `'<bin>' project brief --project N`; `Stop`: `'<bin>' project check --project N --stop-hook`.
3. A Claude Code local-scope MCP registration `watchtower-project` → `<bin> mcp --project N`.
4. `.git/info/exclude` lines inside our marked block.

The owner's own repository is one such folder, workbench #1. The session writing this spec runs on its `watchtower-project` registration.

### 5.2 Before resync: the legacy folder keeps working

The rule is that **the spelling the folder's install used decides the vocabulary the agent sees.** Only pre-rename installs ever wrote `--project`, so the flag is a reliable legacy signal and needs no extra state.

| Surface | Legacy folder (invoked with `--project`) | Resynced folder (`--workbench`) |
|---|---|---|
| SessionStart hook `project brief --project N` | Runs through the alias. The header uses the new wording ("Watchtower workbench #N …"). The "Setup pending" line names the **old** skill and tools (`watchtower-project`, `project_info`, `update_project`). One extra line, budgeted inside the 4000-char cap and dropped first: "This folder's Watchtower setup predates the Workbench rename — suggest Re-run Setup to the owner." (A10) | New skill and tool names. No legacy line |
| Stop hook `project check --project N --stop-hook` | Runs through the alias. Its reason names the old skill | New skill name |
| MCP `watchtower mcp --project N` (served under the old registration name `watchtower-project`) | **Legacy tool vocabulary.** The same eleven tools, with the five renamed ones served under their old names (`project_info`, `project_board`, `update_project`, `add_project_source`, `remove_project_source`). Descriptions and errors use the new wording | New names only |
| Old skill copy | Unchanged on disk. It names `mcp__watchtower-project__project_board` and the other old tools, which still resolve | — |
| Desktop | The install icon shows "Set up by an older Watchtower — Re-run Setup to update" (A10). Argv prompts name `watchtower-project` (§5.3) | Normal |

**Tradeoff of the legacy tool names.** The alternative is a clean break, where the new binary serves only the new names. Then every un-resynced folder's skill would point at tools that no longer exist. The agent would fail on its first board write in every session until the owner resyncs, and this session's own `project_board` calls would break the moment the CLI binary updates.

The alias costs one map from new name to old name in the tool registry (`tools.LegacyWorkbenchToolNames`, five entries) and one binding flag (`Binding.LegacyNames`). The server lists each tool under the name the binding asks for. `Registry.Get` resolves both spellings, so an `agent_actions` row recorded under either name stays readable by `get_action`. The audit row always records the **canonical new name**.

DEV-06 is unchanged: still exactly eleven workbench tools in either vocabulary, the same `DirectApply` path, the same scoping. The cost is small, so it is taken.

Removing the alias is a later decision, made once no legacy folder is left (§10).

### 5.3 Desktop prompts for a legacy folder

`TerminalLaunch.firstRunPrompt`, the "Work on it" prompt and `ProjectCommentPrompt` name a skill. A legacy folder has only `watchtower-project` installed. The Desktop already fetches `integrate status --workbench N --json` for the install icon, and the prompt builders take a `skillName` parameter chosen from its new `legacy` field. If the status is unknown (not fetched yet, or failed), they use the new name. Claude Code also finds the only installed Watchtower skill by its description, so a mismatch degrades softly; it does not break.

### 5.4 What resync does (`workbench resync <id>`, Desktop **Re-run Setup**, and `integrate claude-code --workbench N`)

Resync is the existing additive install (`devpack.InstallWorkbench`). It gains legacy steps. Each step runs even if another failed, as today. PROJ-04 holds throughout: nothing the owner owns is overwritten.

1. **Exclude lines.** Add `/.claude/skills/watchtower-workbench/` to our block. After step 2, drop `/.claude/skills/watchtower-project/` from our block only if that directory is gone. This is the existing `goneExcludeLines` rule extended to the legacy line. An edited legacy skill keeps its line, so it stays git-invisible. Markers are unchanged (A5).
2. **Skill.** Install `watchtower-workbench` (the DEV-04 decision as today). Then remove the legacy `watchtower-project` skill through the existing `removeSkill` path: it deletes only a marked copy whose bytes match the shipped-digest sidecar, together with its sidecar, by name. A **drifted** (owner-edited) or **foreign** legacy copy is kept and reported. The report line reads: "Your own copy of the old watchtower-project skill was kept — delete .claude/skills/watchtower-project yourself once you no longer need it; until then Claude Code sees both skills."
3. **Hooks.** The hook recognizer (`looksLikeOurHook`) accepts both the new suffix (`workbench brief --workbench N`) and the legacy suffix (`project brief --project N`), and the same for the Stop hook. The upsert therefore **replaces the legacy entry in place** with the new command, keeping the owner's other hooks and keys byte-exact (the existing merge). It never adds a second brief. A malformed `settings.local.json` is still left byte-identical and reported. The MCP step below still runs, and the brief keeps working through the alias.
4. **MCP.** If `claude mcp get watchtower-project` succeeds, run `claude mcp remove --scope local watchtower-project`. Then (re)register `watchtower-workbench` → `<bin> mcp --workbench N`. This is the Repair behaviour today, plus the legacy removal. A failure is reported along with the manual command for both the remove and the add.
5. **Permissions (report only, A6).** If the folder's `settings.local.json` lists allow rules naming `mcp__watchtower-project__…`, add a suggestion: "N permission rules still name the old watchtower-project server; re-allow the tools under watchtower-workbench when Claude Code asks." The global `~/.claude/settings.json` is not read.
6. **Index and docs import.** Unchanged.

The `--json` output gains these fields additively (A2): `legacy_skill` (a devpack state such as `removed`/`drifted`/`foreign`/`""`), `legacy_mcp_removed` (bool), `legacy_hooks_replaced` (bool) and `legacy_permission_rules` (int).

`integrate status --workbench N --json` gains `legacy` (bool: any legacy item present — old registration, a marked old skill, or a legacy hook command) and `legacy_skill`. A legacy hook still counts as `hook: true`, so the Desktop's Repair stays disabled for a working legacy folder; only the "older setup" tooltip shows.

### 5.5 Remove and delete (PROJ-02 continuity)

`integrate remove --workbench N` (and the hidden `--project N`) and `workbench delete N` remove **both** vocabularies:

- the new and legacy hooks (by either suffix);
- the new and legacy skill (each through `removeSkill`, so an edited copy stays — PROJ-04);
- both MCP registrations;
- the exclude lines of whichever paths are gone.

A legacy folder deleted without a resync leaves nothing behind. This is the PROJ-02 guarantee, extended to the legacy names.

### 5.6 The owner's own session during the rollout

1. While the PR is open, nothing changes for the owner, because the installed CLI is the old binary.
2. After merge and the app update, the CLI binary is replaced. The **running** Claude Code session keeps its already-spawned `mcp --project 1` process until the session restarts. The next session start spawns the new binary with `--project 1`, which gives the legacy vocabulary and matches the old skill. Work continues unchanged.
3. The owner presses **Re-run Setup** on workbench #1 when convenient. A session open at that moment keeps its connected server, but Claude Code re-reads MCP config only at session start. Its old skill text and the old server name stay consistent until `/clear`, a restart or a resume. After that, the new skill and server load together, and the brief's legacy line disappears.
4. One manual step is expected: Claude Code asks once per tool to allow `mcp__watchtower-workbench__…` (A6).

---

## 6. Contracts touched

| Contract | Change | Strength |
|---|---|---|
| PROJ-01..08 (`docs/inventory/projects.md` → `docs/inventory/workbench.md`) | Reworded "project" → "workbench" (owner-approved). Same ids, same meaning, guard tests listed under new file paths. PROJ-02 and PROJ-04 gain one sentence each about legacy names (§5.4, §5.5) and one new guard each (§8) | unchanged / strengthened |
| DEV-06 (`dev-surface.md`) | `watchtower mcp --workbench N` (alias `--project N`, legacy tool names), registered as `watchtower-workbench`. Still eleven tools, `DirectApply`, scoped | unchanged semantics |
| DEV-01 | "read-only without `--workbench`/`--project`" | unchanged |
| DEV-04 (skill marker and digest) | The legacy skill removal goes through the same marker/digest decision | unchanged |
| DEV-05 (hooks are an explicit CLI opt-in) | Resync replaces our own legacy entry. It is still the explicit CLI or Desktop action | unchanged |
| Go↔Swift dual paths | `ProjectMCPCommand` ↔ Swift `ProjectCLI` MCP command string; `TerminalLaunch` prompts ↔ skill name; `ProjectDeleteSummary` ↔ what `delete` removes; `terminalSessionEnv` (unchanged); `boardSiblingOrder` ↔ `ProjectBoardOrder` (renamed only) | both sides change in the same PR |
| `briefing.daily` | v8 → v9 (header and wording) | — |
| `docs/inventory/README.md` mapping row | file paths updated | — |

---

## 7. Docs

- `docs/features/projects.md` → `docs/features/workbench.md` (`git mv` and reword). Its title becomes "Workbench — Claude Code works a folder-bound board (2026-09-29, POC; renamed 2026-10-02)". It adds a "Rename and legacy folders" bullet summarizing §5.
- `CLAUDE.md`: the Feature Notes link and its one-line summary.
- `docs/inventory/projects.md` → `docs/inventory/workbench.md`: reworded, with a changelog entry dated 2026-10-02. The changelog's historical entries are not rewritten (A11). The 173 "project" mentions are reviewed one by one; "Jira project" mentions stay. `docs/inventory/README.md` and `dev-surface.md` (49 mentions) are updated.
- `docs/app-guide.md`: about 28 lines. The "Projects" section becomes "Workbench". The parenthesis "(This is separate from the AI Chat's own "Projects"…)" becomes a one-line pointer the other way. The chat "Projects" section (line ~317) is untouched.
- Living cross-references in `docs/features/{knowledge-search,developer-surface,chat-redesign}.md` are updated where they mean the boards.
- `docs/review/review-rules.md`: identifier mentions updated if present.

---

## 8. Plan outline

All sub-task branches are cut from, and merged back into, `feature/workbench-rename`, which is itself cut from `main`. One PR goes to `main` at the end (O7). Each sub-task runs only its inner loop (CLAUDE.md). The controller runs the full gate (`make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`) once after W4, and once more before the PR.

```
W1 Go mechanical ─┬─> W3 CLI + text ──> W4 MCP/skill/migration ──┐
                  │                                              ├─> W6 docs + inventory ──> gate ──> PR
W2 Swift mechanical ─────────────────────────> W5 Swift behaviour + UI ┘
```

W1 and W2 can run in parallel lanes, in separate worktrees, because they touch disjoint trees. Swift stays one lane at a time: W2, then W5.

### W1 — Go mechanical rename (Depends on: none)

- `git mv` the packages and files (§4.4). Run type-aware `gopls rename` for identifiers. No behaviour or text change: every string literal, SQL statement, JSON tag, test function name and user-visible message stays byte-identical.
- **Interfaces:** the §4.4 identifiers.
- **Tests:** `go build ./...` and `go vet ./...`; `go test ./internal/{db,tools,mcp,devpack,kb,briefing,workbenchcheck,workbenchdocs,workbenchfiles}` and `go test ./cmd -run 'Project|Workbench|Integrate|MCP|Dev06|Proj0'`. A grep check: the diff contains no change inside a string literal, a SQL statement or a JSON tag. A collision grep: no `ChatProject`/`jira`/`project_key` identifier is touched.
- **Size:** about 80 files (61 renamed plus about 19 referencing), about 1,500 changed lines. Pure renames dominate, and git similarity stays high.

### W2 — Swift mechanical rename (Depends on: none)

- `git mv Views/Projects Views/Workbench` and the files and types in §4.5. Renames in Xcode-free style with `sed` over a reviewed identifier list, compile-driven. UserDefaults key strings, raw values, `CodingKeys` and all UI strings are unchanged.
- **Tests:** `make test-swift FILTER='Workbench|Terminal|TargetQueries|AgentAction|Notification|Briefing'`. Test function names are unchanged. A grep check: the diff changes no string literal.
- **Size:** about 96 files (69 renamed plus about 27 referencing), about 1,500 changed lines.

### W3 — CLI, alias flags, Go owner/agent-facing text (Depends on: W1)

- `workbench` command with `Aliases: ["project"]`; `--workbench` with hidden `--project` through `addWorkbenchIDFlag`, which reports the legacy spelling. `Short`/`Long` texts. The brief, check and resync wording, with legacy variants selected by the flag signal. `briefing` `=== WORKBENCHES ===` and `briefing.daily` v9.
- **Interfaces:** `addWorkbenchIDFlag(cmd *cobra.Command, v *int64|*string) (legacy func() bool)`; `renderWorkbenchBrief(…, vocab vocabulary)`, where `vocabulary` = `{SkillName, InfoTool, UpdateTool, Legacy bool}`.
- **Test cases:**
  - `watchtower project create --folder X --json` and `watchtower workbench create …` produce identical JSON.
  - `project brief --project N` and `workbench brief --workbench N` both exit 0. The first carries the old skill/tool names and the legacy line; the second the new names and no legacy line.
  - The legacy line is the first thing dropped when the brief hits the 4000-char cap. Extend the cap test.
  - `--project` and `--workbench` together → error.
  - `project check --project N --stop-hook` produces the decision JSON with the old skill name; `--workbench` with the new one; still once per stop and silent on `stop_hook_active` (PROJ-07 guards green).
  - The root `--help` does not list `project`.
  - The briefing prompt v9: header present, `%s` count unchanged, `source_type="project"` retained. A customized v8 template still renders.
  - All `TestProj0*` in `cmd` stay green. Guard assertions whose expected literal says "project" are updated to the new literal, never loosened (see "Guard tests" below).
- **Size:** about 12 files, about 350 lines.

### W4 — MCP, tools, skill, devpack migration (Depends on: W1, W3)

- Server registration name; five tool renames; `LegacyWorkbenchToolNames` and `Binding.LegacyNames`; `Registry.Get` resolving both spellings; `workbench_scope` with the `project_scope` alias; reworded descriptions and errors. Skill moved and rewritten (`watchtower-workbench`, same DEV-04 marker). In devpack: legacy constants, the dual-suffix hook recognizer, legacy skill and MCP removal in install, remove and status, the exclude-line swap, the permission-rule count. `integrate status` and `resync` JSON additions.
- **Interfaces:** `devpack.LegacyMCPServerName`, `devpack.LegacySkillName`; `WorkbenchInstallReport.{LegacySkill SkillStatus, LegacyMCPRemoved, LegacyHooksReplaced bool, LegacyPermissionRules int}`; `WorkbenchStatus.Legacy bool`; `tools.Binding.LegacyNames bool`; `tools.LegacyWorkbenchToolNames map[string]string`.
- **Test cases:**
  - `mcp --workbench N` lists `workbench_info`… and no `project_*` tool. `mcp --project N` lists `project_info`… and no `workbench_*` tool. Both list exactly eleven workbench tools (extends the DEV-06 guards).
  - A write through a legacy name records the canonical name in `agent_actions.tool`. `get_action` on a row stored under an old name resolves.
  - `search_knowledge` with `project_scope: only` behaves like `workbench_scope: only`; with both → refused; `project_doc` filter unchanged (PROJ-08 guards green).
  - The install on a legacy fixture folder (old skill with sidecar, legacy hooks, `claude mcp get watchtower-project` answering 0): the new skill is installed and the legacy skill removed; the hooks are replaced in place (exactly one SessionStart and one Stop entry of ours, owner hooks and keys byte-exact); `mcp remove watchtower-project` then `mcp add watchtower-workbench … mcp --workbench N` (fake runner argv asserted); the old exclude line dropped and the new one added.
  - **New guard `TestProj04_ResyncKeepsAnEditedLegacySkill`:** an edited legacy skill stays byte-identical and is reported `drifted`, and its exclude line stays.
  - The same guard pattern for a **foreign** legacy skill (no marker) → untouched.
  - A malformed `settings.local.json` on a legacy folder: byte-identical, reported, and the MCP step still runs.
  - **New guard `TestProj02_RemoveLegacyFolderLeavesNothingInstalled`:** `integrate remove --workbench N` on a never-resynced folder removes the legacy hooks, skill, registration and exclude lines, and `git status` is clean. The existing `TestProj02_RemoveProject*` stay green.
  - `integrate status --json` reports `legacy: true` and `hook: true` for a legacy folder, and `legacy: false` after resync.
  - The permission-rule count: `settings.local.json` with two `mcp__watchtower-project__…` allows → `legacy_permission_rules: 2`, file unchanged.
  - The skill content test: `name: watchtower-workbench`, the `mcp__watchtower-workbench__` prefix, no `mcp__watchtower-project__` string, every tool it names exists in `WorkbenchTools()`.
- **Size:** about 20 files, about 800 lines (half tests).

### W5 — Swift behaviour and UI strings (Depends on: W2, W4)

- `WorkbenchCLI` calls `workbench …`/`--workbench`; the MCP manual command string (dual path with `WorkbenchMCPCommand`); `WorkbenchInstallStatus` decodes `legacy`/`legacy_skill`; `WorkbenchResynced.summaryLines` for the legacy fields; prompt builders take `skillName`; the install-icon tooltip; every UI string in §4.1; the `SidebarDestination` case with rawValue `"projects"`.
- **Test cases:**
  - `WorkbenchCLITests`: argv for each call uses `workbench`/`--workbench`; the MCP command string equals Go's for the same input (both quoted fixtures).
  - The status decode with and without `legacy` (an old CLI's JSON still decodes → `legacy == false`).
  - `TerminalLaunch`/`WorkbenchCommentPrompt`: legacy → `watchtower-project`, otherwise and unknown → `watchtower-workbench`; still a single line with no control characters.
  - Resync summary lines for `legacy_skill` = `removed`/`drifted`, `legacy_mcp_removed`, `legacy_permission_rules > 0`.
  - `WorkbenchDeleteSummary` names the installed vocabulary.
  - A `SidebarDestination.workbench.rawValue == "projects"` test, and `sidebar.hiddenItems` holding `"projects"` still hides the tab.
  - A UserDefaults key test: `WorkspaceLayout.key(workbenchID: 7) == "projects.layout.7"` and the same for each key in §4.5.
  - Notification route: `userInfo["type"] == "project"` still opens the workbench pane.
  - `testProj01_*` and `testProj03*` are green.
- **Size:** about 30 files, about 400 lines.

### W6 — Docs and inventory (Depends on: W3, W4, W5)

- §7. The `schema.sql` mapping comment. `docs/app-guide.md`.
- **Checks:** `TestSchemaGolden` unchanged (no `-update`); `TestAllTablesExist` and `TestSchemaDrift_*` green; every guard path in `docs/inventory/workbench.md` exists (a grep script over `file::Test` pairs); the CLAUDE.md link resolves; `scripts/leak-check.sh` is clean.
- **Size:** about 10 files, about 700 changed lines.

### Guard tests (applies to W1–W5)

- No `TestProjNN_`/`testProjNN_` function is renamed, split or removed (A4).
- Where a guard pins a literal that is reworded, such as "project N no longer exists" or "… is not in this project", the expected literal is replaced by the new one with the same strictness (same `==`/`Contains` form, same coverage). That is a wording update under O2, not a weakened assertion. The implementer lists every such edit in the PR body. There are about 16 such literals across `internal/tools`, `internal/mcp`, `internal/db`, `internal/devpack` and `cmd/project_brief_test.go`.
- The two new guards (`TestProj04_ResyncKeepsAnEditedLegacySkill`, `TestProj02_RemoveLegacyFolderLeavesNothingInstalled`) strengthen PROJ-04 and PROJ-02.

---

## 9. Risks

| Risk | Mitigation |
|---|---|
| **The diff is large and mechanical** (about 175 renamed files, about 4k changed lines), so review fatigue can hide a real change | W1 and W2 are reviewed as "rename only" with the grep checks above: no literal, SQL or JSON-tag change. Behaviour lives only in W3–W5, which are small and reviewed normally. Separate commits for `git mv` and for identifier edits |
| **Merge conflicts with parallel work** in `Views/Projects`, `internal/tools/project*`, `cmd/project*` (the area is active: several PRs on 2026-10-01/02) | Announce a short freeze on the workbench area while W1/W2 land. Rebase `feature/workbench-rename` onto `main` before W3 and again before the PR. Keep content edits in renamed files small so git rename detection (≥ 50 % similarity) carries in-flight changes across. A branch that lands on `main` mid-rename is ported by re-applying the identifier map |
| **Chat or Jira "project" caught by the rename** | The §3 list goes into every brief. `gopls rename` is type-aware. Swift renames use an explicit identifier list, never a blanket regex. A review grep runs over the diff for `ChatProject`, `jira`, `project_key`, `projectMap` |
| **Swift `.build` cost** | One Swift lane (W2, then W5). Filtered test runs. Never delete `.build`. A worktree clones a warm `.build` with `cp -c` |
| **A persisted key renamed by accident** resets layouts or re-fires notifications | The W5 key-equality tests (§8) |
| **A legacy folder in a mixed state** (hooks updated, MCP step failed) | Each step is reported. The brief's tool-name line follows the hook flag while the server follows its registration flag, so a mismatch affects only the setup hint, never a write. Re-running resync converges |
| **The owner's own session loses its tools** during the rollout | §5.2's legacy vocabulary keeps `mcp --project 1` serving the old names. The owner resyncs at a moment of their choosing (§5.6) |
| **Two skills visible** when an edited legacy copy is kept | Reported on every resync with the exact path to delete. Never auto-deleted (PROJ-04) |

## 10. Out of scope and later

- Renaming DB tables, columns, values or UserDefaults keys (A1).
- Removing the `project` CLI alias, the `--project` flags, the legacy tool names and `project_scope`. Revisit once `integrate status` reports no legacy folder on the owner's install. A separate, owner-approved PR.
- Rewriting historical docs (A11).
- Renaming the chat-side `ProjectDetailView` / `ProjectDetailViewModel` to `ChatProject…` for symmetry. Optional, and a separate PR.
