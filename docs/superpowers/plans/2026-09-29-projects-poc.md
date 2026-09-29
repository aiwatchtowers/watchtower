# Projects POC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Projects feature: a folder-bound project with a board of targets, documents with text-anchored comments and owner↔agent comments, driven by Claude Code (the owner's terminal or one embedded in the Desktop) through a project-bound MCP server, a project skill and a SessionStart hook.

**Architecture:** Go owns the data (`projects*` tables, `targets.project_id`), the project CLI (`watchtower project …`, incl. the hook body `project brief`), the project tools on a new registry surface `project` applied directly under `Binding.DirectApply`, the `watchtower mcp --project N` mode, and the folder installer (`internal/devpack`). Swift adds a Projects tab: SwiftTerm terminal running `claude` in the folder, a documents view with inline comments, a board, and notifications. Project targets are excluded from every non-board reader.

**Tech Stack:** Go 1.25, cobra, modernc SQLite + goose, `modelcontextprotocol/go-sdk` (existing), `claude` CLI; SwiftUI macOS 14+, GRDB 7, SwiftTerm (new SPM dependency), AppKit `NSTextView`.

**Spec:** `docs/superpowers/specs/2026-09-29-project-board-poc-design.md` (revision 4) — read it before any task.

## Phase files

Detailed task steps live in per-phase files (same numbering):
- `docs/superpowers/plans/2026-09-29-projects-poc/phase1-go-core.md` — Tasks 1–5
- `docs/superpowers/plans/2026-09-29-projects-poc/phase2-tools-mcp.md` — Tasks 6–9
- `docs/superpowers/plans/2026-09-29-projects-poc/phase3-install.md` — Tasks 10–12
- `docs/superpowers/plans/2026-09-29-projects-poc/phase4-desktop-terminal-docs.md` — Tasks 13–18
- `docs/superpowers/plans/2026-09-29-projects-poc/phase5-board-briefing-docs.md` — Tasks 19–22

## Global Constraints

- Everything in the repo (code, comments, docs, commits) in English. Public repo hygiene: no real ids/names/paths in fixtures — placeholders only (`acme`, `/tmp/…`, `t.TempDir()`).
- Migration file `internal/db/migrations/00081_projects.sql`; table/column names exactly as spec §3; mirror in `internal/db/schema.sql`, `TestAllTablesExist`, schema golden (`go test ./internal/db/ -run TestSchemaGolden -update`), Swift `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`.
- Project targets: `level='custom'`, `custom_label='project'`, `period_start=period_end=<UTC YYYY-MM-DD of creation>`, `source_type='chat'`, `ownership='mine'`, `status='todo'`.
- Registry surface id `"project"`. MCP server name registered in CC: `watchtower-project`. Skill name `watchtower-project`. Hook command `<abs watchtower bin> project brief --project <N>`.
- `project brief` output ≤ 4000 chars, always exit 0.
- DirectApply never runs an `External` tool (refuse with a ValidationError).
- Go inner loop `go test ./internal/<pkg>` (no `-count=1`); `go test ./cmd -run <Name>` targeted; Swift `make test-swift FILTER=<Class>`; `make lint-diff`. Never delete `WatchtowerDesktop/.build`. Full gate (`make test`, `make test-swift`, `make lint-all`) once per phase by the controller.
- Tests that spawn processes kill the process group and wait in `t.Cleanup`. The `claude mcp` invocation goes through an injectable runner so tests never exec the real `claude`.
- No TCC-prompting APIs in Swift (no Accessibility, no `NSEvent` global monitors, no AppleEvents).
- Contracts: DEV-06 guards `TestDev06_*` (Go); PROJ-01..04 guards `TestProj0N_*` (Go) / `testProj0N…` (Swift).
- Cyclomatic complexity gate: keep functions small (repo uses gocyclo via lint; split helpers).

## Review Focus

1. **Folder edge cases** — a folder path with spaces/Unicode, a symlinked folder, a folder deleted or moved after `project create`: `create` stores the symlink-resolved absolute path; `brief` prints one line and exits 0; `attach_document` rejects `../` and symlink escapes. → Task 2 (resolve + uniqueness), Task 5 (missing folder brief), Task 8 (escape tests).
2. **Existing `.claude/settings.local.json`** with other keys, with an existing `SessionStart` hook of the owner's, or malformed JSON: the installer merges without losing a key, installing twice is idempotent (one entry), malformed JSON is left byte-identical and reported, remove deletes only our entry. → Task 11.
3. **A whole plan in one `create_targets` call with nested `parent_key` refs**, one bad item (unknown `parent_key`, empty text, parent in another project): the batch is all-or-nothing, nothing half-created. → Task 7.
4. **Document revised heavily between loads** — duplicate occurrences of the quoted text, whitespace-only reflow, the quoted passage deleted: best prefix/suffix match wins, a lost quote becomes `outdated` (never silently re-attached to a wrong place). Anchors live on the rendered plain text. → Task 15.
5. **Project deleted while CC is connected** (MCP server running, hook installed, terminal open): every project tool answers `project N no longer exists`, the hook prints one line, the Desktop closes the terminal session and removes the project from the list. → Task 9 (tool error), Task 5 (brief), Task 20 (Desktop delete).

---

## File map

Go (new): `internal/db/migrations/00081_projects.sql`, `internal/db/projects.go`, `internal/db/project_comments.go`, `internal/db/project_board.go`, `internal/tools/projects.go`, `internal/tools/project_docs.go`, `internal/devpack/project.go`, `internal/devpack/project_settings.go`, `internal/devpack/projectskill/watchtower-project/SKILL.md`, `cmd/project.go`, `cmd/project_brief.go`, `docs/inventory/projects.md`.
Go (modify): `internal/db/{models.go,targets.go,targets_promote.go,targets_remind.go,catchup.go,memory.go,channel_stats.go,schema.sql}`, `internal/dayplan/gather.go`, `internal/targets/{pipeline.go,nextstep.go}`, `internal/tools/{registry.go,targets_read.go}`, `internal/agentloop/client.go`, `internal/mcp/{server.go,actions.go}`, `cmd/{mcp.go,actions_registry.go,integrate.go}`, `internal/briefing/pipeline.go`, `internal/prompts/defaults.go`, `docs/inventory/dev-surface.md`.
Swift (new, WatchtowerCore unless noted): `Models/Project.swift` (Project, ProjectDocument, ProjectComment, ProjectBoardNode), `Database/Queries/ProjectQueries.swift`, `Services/CommentAnchor.swift`, `Services/ProjectNotificationPolicy.swift`; app target: `Services/ProjectCLI.swift`, `Services/ProjectTerminalCenter.swift`, `Services/ProjectNotificationCenter.swift`, `ViewModels/ProjectsViewModel.swift`, `ViewModels/ProjectDocumentViewModel.swift`, `ViewModels/ProjectBoardViewModel.swift`, `Views/Projects/{ProjectsView,ProjectPageView,ProjectTerminalView,ProjectDocumentsView,DocumentTextView,CommentThreadView,ProjectBoardView}.swift`.
Swift (modify): `Package.swift` (SwiftTerm), sidebar/navigation enum, `AppState`, `QuitCoordinator`, `Models/Target.swift`, `Database/Queries/TargetQueries.swift`, `NotificationService.swift`.

## Tasks & cross-task interfaces

### Phase 1 — Go core

**Task 1: Migration 00081 + schema mirrors.** Produces the tables of spec §3 and `targets.project_id` + `idx_targets_project`; schema.sql, golden, `TestAllTablesExist`, Swift `TestDatabase+Schema.swift`.

**Task 2: Project store (`internal/db/projects.go`, `project_comments.go`).** Produces (package `db`):
```go
type Project struct{ ID int64; Name, FolderPath, Description, CreatedAt, UpdatedAt string }
type ProjectSource struct{ ID, ProjectID int64; Kind, Ref, Label string }
type ProjectDocument struct{ ID, ProjectID int64; TargetID sql.NullInt64; RelPath, Kind, Title, CreatedAt, UpdatedAt string }
type ProjectComment struct{ ID, ProjectID int64; TargetID, DocumentID, ParentID sql.NullInt64; Author, AgentLabel, Body, AnchorQuote, AnchorPrefix, AnchorSuffix, AnchorHeading, Status, CreatedAt, ReadAt string }
type ProjectCommentFilter struct{ ProjectID, TargetID, DocumentID int64; NewForAgent bool } // zero ids = any
var ErrProjectFolderTaken = errors.New("folder is already bound to a project")
var ErrProjectNotFound = errors.New("project not found")
func ResolveProjectFolder(dir string) (string, error)            // abs + EvalSymlinks + must be a directory
func (db *DB) CreateProject(name, folder string) (int64, error)  // folder must already be resolved
func (db *DB) GetProject(id int64) (*Project, error)              // ErrProjectNotFound
func (db *DB) ListProjects() ([]Project, error)
func (db *DB) UpdateProjectDescription(id int64, description string) error
func (db *DB) DeleteProject(id int64) error                       // one tx; cascades
func (db *DB) AddProjectSource(s ProjectSource) (int64, error)    // idempotent on UNIQUE → existing id
func (db *DB) RemoveProjectSource(projectID, sourceID int64) error
func (db *DB) ListProjectSources(projectID int64) ([]ProjectSource, error)
func (db *DB) UpsertProjectDocument(d ProjectDocument) (id int64, created bool, err error) // on (project, rel_path): bump updated_at, update kind/title/target
func (db *DB) GetProjectDocument(id int64) (*ProjectDocument, error)
func (db *DB) ListProjectDocuments(projectID int64) ([]ProjectDocument, error)
func (db *DB) AddProjectComment(c ProjectComment) (int64, error)  // reply inherits root target/document; validates same project
func (db *DB) GetProjectComment(id int64) (*ProjectComment, error)
func (db *DB) ListProjectComments(f ProjectCommentFilter) ([]ProjectComment, error) // ordered created_at, id
func (db *DB) SetProjectCommentStatus(id int64, status string) error // roots only
func (db *DB) MarkProjectCommentsRead(projectID, targetID, documentID int64) error // agent comments
```

**Task 3: Targets `project_id` + exclusions (PROJ-01).** Produces `db.Target.ProjectID sql.NullInt64`; `TargetFilter.ProjectID int64` (0 = exclude project targets, N = only N); `func (db *DB) CreateProjectTarget(projectID int64, parentID sql.NullInt64, title, intent string) (int64, error)` and `func (db *DB) CreateProjectTargetsTx(tx *sql.Tx, …)` helper used by Task 7 (exact tx helper name: `func (db *DB) WithTx(fn func(*sql.Tx) error) error` if absent); every reader in spec §4.1 excludes project targets; guard `TestProj01_ProjectTargetsNeverReachNonBoardReaders`.

**Task 4: Board query (`internal/db/project_board.go`) + CLI `project create|list|show|board|delete`.** Produces:
```go
type BoardNode struct{ Target Target; Children []BoardNode; NewForAgent, UnreadForOwner int; Documents []ProjectDocument }
func (db *DB) GetProjectBoard(projectID int64) ([]BoardNode, error) // roots in (status order: in_progress, blocked, todo, done, dismissed/snoozed), then id
```
`cmd/project.go`: `project create --folder --name --json` (prints `{"id":N,"folder":…,"name":…}`), `list --json`, `show N --json`, `board N --json`, `delete N` (calls the package var `projectRemoveInstall func(ctx, *config.Config, *db.Project) error`, default no-op until Task 12 wires `devpack.RemoveProject`).

**Task 5: `project brief`.** Produces `cmd/project_brief.go`: `func renderProjectBrief(board []db.BoardNode, p *db.Project, comments []db.ProjectComment, docs map[int64]db.ProjectDocument) string` (pure, ≤ 4000 chars) and the `project brief --project N` command (always exit 0).

### Phase 2 — Tools + MCP

**Task 6: Registry DirectApply + bound reads.** `tools.Binding` gains `ProjectID int64`, `DirectApply bool`; `func (r *Registry) CallRead(ctx, name string, args json.RawMessage, b Binding) (any, error)` — `Call.Binding` now populated for reads; agentloop's `ToolRegistry` interface + caller updated; DirectApply semantics per spec §4.2; guards `TestDev06_ExternalToolRefusedUnderDirectApply`.

**Task 7: Project tools** (`internal/tools/projects.go`): `NewProjectInfo`, `NewProjectBoard`, `NewUpdateProject`, `NewAddProjectSource`, `NewRemoveProjectSource`, `NewCreateTargets`, `NewUpdateTarget` — all `Surfaces: []string{"project"}`; helper `func projectOf(ctx context.Context, d *db.DB, b Binding) (*db.Project, error)` (returns ValidationError `project N no longer exists`) and `func targetInProject(d *db.DB, projectID, targetID int64) (*db.Target, error)`. `list_targets`/`get_target` limit to `Binding.ProjectID` when set. Guard `TestDev06_WriteOutsideTheBoundProjectIsRefused`.

**Task 8: Document + comment tools** (`internal/tools/project_docs.go`): `NewAttachDocument`, `NewListComments`, `NewAddComment`, `NewResolveComment`; `func resolveInsideFolder(folder, rel string) (string, error)`. Guard `TestDev06_AttachDocumentStaysInsideTheFolder`.

**Task 9: `mcp --project N` + registry assembly + contracts.** `cmd/mcp.go` flag `--project int64`; `buildToolRegistry` registers the Task 7/8 tools; pin test extended; `internal/mcp` read handler passes the binding to `CallRead`; `TestDev06_PlainMCPStaysReadOnly`; `docs/inventory/dev-surface.md` DEV-06 + DEV-01/05 amendments; `docs/inventory/projects.md` PROJ-01..04 + README mapping row.

### Phase 3 — Install into the folder

**Task 10: The `watchtower-project` skill** — `internal/devpack/projectskill/watchtower-project/SKILL.md` (embedded separately from the generic pack via `//go:embed projectskill/*/SKILL.md`, so plain `integrate claude-code` never installs it); content per spec §5; `func ProjectSkill() (name string, body []byte)`.

**Task 11: Settings + exclude merge** (`internal/devpack/project_settings.go`): `func InstallSessionStartHook(dir, command string) (changed bool, err error)`, `func RemoveSessionStartHook(dir, command string) (changed bool, err error)`, `var ErrMalformedSettings`; `func EnsureGitExclude(dir string, lines []string) (added []string, err error)`, `func RemoveGitExclude(dir string, lines []string) error`.

**Task 12: Project install orchestration + CLI.** `internal/devpack/project.go`:
```go
type CommandRunner func(ctx context.Context, dir, name string, args ...string) ([]byte, error)
type ProjectInstallOptions struct{ ProjectID int64; Folder, Bin string; Run CommandRunner }
type ProjectInstallReport struct{ Skill Action; HookChanged, MCPRegistered bool; MCPCommand string; Excluded []string }
type ProjectStatus struct{ Skill Status; Hook, MCP bool }
func InstallProject(ctx context.Context, o ProjectInstallOptions) (ProjectInstallReport, error)
func RemoveProject(ctx context.Context, o ProjectInstallOptions) error
func StatusProject(ctx context.Context, o ProjectInstallOptions) (ProjectStatus, error)
```
`cmd/integrate.go`: `--project N` on `claude-code`/`status`/`remove` (`--json` on status); wires `projectRemoveInstall`. PROJ-02/PROJ-04 guards.

### Phase 4 — Desktop: shell, terminal, documents, notifications

**Task 13: Core models + queries** (WatchtowerCore): `Project`, `ProjectDocument`, `ProjectComment`, `ProjectBoardNode`; `ProjectQueries` — `fetchAll`, `fetch(id:)`, `documents(projectID:)`, `comments(documentID:)`, `comments(targetID:)`, `addOwnerComment(...)`, `reply(to:body:)`, `setStatus(commentID:status:)`, `markAgentCommentsRead(projectID:targetID:documentID:)`, `board(projectID:)`, `unreadCounts()`.

**Task 14: `ProjectCLI` + Projects tab shell** — `ProjectCLI` (app target) wraps `project create/delete/list` and `integrate claude-code|status|remove --project`; sidebar tab **Projects**, `ProjectsViewModel` (on AppState), `ProjectsView` (list + New project… NSOpenPanel + TCC-location warning), `ProjectPageView` with Terminal | Board | Documents panes (Board placeholder until Task 19).

**Task 15: `CommentAnchor`** (WatchtowerCore, pure): `struct CommentAnchor { quote, prefix, suffix, heading: String }`, `static func make(text: String, range: Range<String.Index>, headings: [(offset: Int, title: String)]) -> CommentAnchor`, `func locate(in text: String) -> Range<String.Index>?` (nil = outdated).

**Task 16: Documents view** — `ProjectDocumentsView`, `DocumentTextView` (`NSViewRepresentable` over `NSTextView`, markdown → `NSAttributedString`, selection → Comment, highlights for anchored threads), `CommentThreadView`, `ProjectDocumentViewModel` (file watch via `DispatchSource` on the open file, re-anchor, mark outdated).

**Task 17: Embedded terminal** — SwiftTerm dependency; `ProjectTerminalCenter` (on AppState; one `LocalProcess` per project; login shell `exec claude` / first-run prompt; SIGHUP → SIGKILL after 3 s; restart); `ProjectTerminalView`; `QuitCoordinator` closes terminals.

**Task 18: Notifications** — `ProjectNotificationPolicy` (WatchtowerCore, pure: `static func decide(previous: Snapshot, current: Snapshot) -> [ProjectNotice]`), `ProjectNotificationCenter` (30 s poll, persisted watermark per project in UserDefaults, posts through `NotificationService`, deep link), Settings toggle `projects.notifications` default on.

### Phase 5 — Board, exclusions, briefing, docs

**Task 19: Board pane** — `ProjectBoardView` + `ProjectBoardViewModel` (tree, detail with status/title edit, comment thread reuse of `CommentThreadView`, mark read).

**Task 20: Targets-tab exclusions + delete flow** — `Target.projectID`; `TargetQueries` excludes `project_id IS NOT NULL` in `fetchAll`/`fetchCounts`/`fetchDistinctTags`/badge; project delete from the page (confirmation, closes the terminal, runs CLI delete); Swift `testProj01…`.

**Task 21: Briefing Projects section** — `gatherProjects()`; `briefing.daily` v8 with `=== PROJECTS ===`; placeholder-count fallback.

**Task 22: Docs** — CLAUDE.md feature note, `docs/app-guide.md` Projects section, inventory changelogs, manual checklist in the PR body (TCC, terminal, end-to-end of spec §10).
