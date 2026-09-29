# Projects POC — Watchtower develops Watchtower (2026-09-29)

**Status:** design, revision 4 (owner decisions 2026-09-29: own feature; setup by the assistant itself; equal Watchtower/CC flows; document comments; notifications; **the in-app flow is an embedded terminal running Claude Code**, not a Watchtower chat).
**Vision:** `2026-09-29-chat-projects-vision.md`. Projects is a **new feature**, separate from the AI Chat's v1 projects (`chat_projects`), which stay as they are.

## 1. Goal

Work on a project is done by Claude Code (CC). The owner runs it either in their own terminal or in a terminal **embedded in the Watchtower project page** — the same `claude`, the same folder, the same `.claude/`, permissions and memory. Watchtower gives the **wide overview** and the durable state around it:

- A **project** is a folder (first: this repository). The owner only picks the folder; setup — description, sources, first board — is done by CC itself through Watchtower's project tools.
- A **board** — targets with sub-targets — that outlives CC sessions.
- **Plan = board:** a `writing-plans` plan's tasks become sub-targets of the feature target; the subagent-driven-development controller moves them and reports on them.
- **Documents with inline comments:** specs and plans CC writes are attached to the project and open in the Desktop like a Claude document — the owner selects text and comments; CC reads open comments, revises the file, resolves each comment with a reply.
- **Comments on targets**, mainly so agents can ask the owner questions without blocking.
- **Notifications** when an agent asks, a document awaits review, all comments on a document are answered, or a target is done.

**Success criterion (two weeks):** the owner reviews plans and specs in the Desktop document view instead of reading md in a terminal, comes to the board when a notification says so, and checks project state there rather than asking CC.

**Later (not this POC):** a rich chat UI on the CC engine for non-developers (vision block A); work projects with an issue tracker ("let's do XXX-123" → decomposition on the board, tracker issue moved as work progresses); indexing project documents into `kb`.

## 2. Decisions (owner, 2026-09-29)

| # | Decision |
|---|---|
| D1 | Projects is its own feature and entity (`projects` table, own sidebar tab). |
| D2 | Setup is done by CC itself (skill + project MCP tools) after the owner picks a folder; nothing is handed to the owner to copy or run. |
| D3 | The in-app way to work is an embedded terminal running `claude` in the folder (SwiftTerm). Equal to the owner's own terminal: both see the same board through the same MCP server and hook. |
| D4 | Project targets live only on the project board — excluded from the Targets tab, day plan, next-step, catch-up, memory mirrors, inbox overdue notify, target extract/dedup. The daily briefing gets a separate **Projects** section. |
| D5 | `watchtower mcp --project N` is a new writable MCP mode: writes to its own project apply directly (no Approve), audited; nothing external. New contract DEV-06; DEV-01 and DEV-05 amended. |
| D6 | Plan = board via a project skill + a SessionStart hook installed into the folder. Superpowers skills are not modified. |
| D7 | Deleting a project cascades: targets, comments, documents — and removes everything Watchtower installed in the folder. |
| D8 | Plans/specs are attached documents with text-anchored comments; the Desktop never writes a project document. |
| D9 | Owner notifications (§6.5). |

## 3. Data

One goose migration (`00081_projects.sql`), mirrored into `internal/db/schema.sql`, `TestAllTablesExist`, the schema golden, and `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`.

```sql
CREATE TABLE projects (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  folder_path TEXT NOT NULL UNIQUE,          -- absolute, symlinks resolved
  description TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

CREATE TABLE project_sources (
  id INTEGER PRIMARY KEY,
  project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK(kind IN ('slack_channel','jira_project','confluence_space','person','link')),
  ref TEXT NOT NULL,
  label TEXT NOT NULL DEFAULT '',
  UNIQUE(project_id, kind, ref)
);

CREATE TABLE project_documents (
  id INTEGER PRIMARY KEY,
  project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  target_id INTEGER REFERENCES targets(id) ON DELETE SET NULL,
  rel_path TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'doc' CHECK(kind IN ('spec','plan','doc')),
  title TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),  -- re-attach bumps it ("revised")
  UNIQUE(project_id, rel_path)
);

CREATE TABLE project_comments (
  id INTEGER PRIMARY KEY,
  project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  target_id INTEGER REFERENCES targets(id) ON DELETE CASCADE,
  document_id INTEGER REFERENCES project_documents(id) ON DELETE CASCADE,
  parent_id INTEGER REFERENCES project_comments(id) ON DELETE CASCADE,
  author TEXT NOT NULL CHECK(author IN ('owner','agent')),
  agent_label TEXT NOT NULL DEFAULT '',
  body TEXT NOT NULL,
  anchor_quote TEXT NOT NULL DEFAULT '',
  anchor_prefix TEXT NOT NULL DEFAULT '',
  anchor_suffix TEXT NOT NULL DEFAULT '',
  anchor_heading TEXT NOT NULL DEFAULT '',
  status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','resolved','outdated')),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  read_at TEXT NOT NULL DEFAULT '',
  CHECK (target_id IS NOT NULL OR document_id IS NOT NULL OR parent_id IS NOT NULL)
);
```

- `targets.project_id INTEGER REFERENCES projects(id) ON DELETE CASCADE` + `idx_targets_project`. Project targets: `level='custom'`, `custom_label='project'`, `period_start = period_end =` creation day (UTC `YYYY-MM-DD`), `source_type='chat'`, `ownership='mine'`, `status='todo'`.
- A reply inherits its root's `target_id`/`document_id`; status is meaningful on roots only. `outdated` = the anchor no longer matches the file (§6.3). **New for the agent** = open owner roots, plus owner replies newer than their thread's latest agent reply. **Unread for the owner** = agent comments with empty `read_at`.

## 4. Go

### 4.1 db layer
- `db.Target.ProjectID sql.NullInt64` through `targetSelectCols`/`scanTarget`/`CreateTarget`/`UpdateTarget`. `TargetFilter.ProjectID int64`: 0 means **exclude** project targets — the default for every existing caller; N means only project N's.
- `project_id IS NULL` in every non-board reader: `GetTargets` (default), `GetTargetsNeedingNextStep`, `GetTargetsForBriefing`, `GetTargetCounts`, `NotifyDueTargets`, `ListCatchupTargets`, `ListTargetsForMirror`, `internal/dayplan/gather.go`, `internal/db/channel_stats.go`, the extract/dedup snapshots in `internal/targets/pipeline.go`. `nextstep.go`'s single-target path skips a project target. `targets_promote.go` copies `project_id`.
- `internal/db/projects.go`: project CRUD, sources, documents, comments, `GetProjectBoard`, `DeleteProject` (one transaction).

### 4.2 Registry and tools
- `tools.Binding` gains `ProjectID int64` and `DirectApply bool`; `Registry.CallRead` takes the `Binding` too (runtime-B and MCP callers pass theirs). New surface `"project"`.
- **DirectApply:** `Propose` with `DirectApply` treats a non-`External` tool as execute trust for that call only — row inserted approved (`trust_at_create='execute'`) and applied inline, audit kept. An `External` tool is refused outright under DirectApply (AGENT-03). Not global trust.
- **Scope rule:** every project tool resolves the target/document/comment it touches and fails unless it belongs to `Binding.ProjectID`; new rows take `project_id` from the binding only. `attach_document` requires a path that resolves (after symlinks) inside `folder_path` to an existing `.md`/`.txt` file.
- Tools (surface `project`):

  | Tool | Kind | What |
  |---|---|---|
  | `project_info` | read | name, folder, description, sources, counts |
  | `project_board` | read | target tree + comment counters + attached documents |
  | `update_project` | write | description |
  | `add_project_source` / `remove_project_source` | write | kinds per §3 |
  | `create_targets` | write | array of `{key?, text, intent?, parent_id? \| parent_key?}`, one transaction — a whole plan in one call |
  | `update_target` | write | status, progress, title, intent |
  | `attach_document` | write | `rel_path`, `kind`, `title?`, `target_id?`; re-attaching an existing path bumps `updated_at` ("revised") |
  | `list_comments` | read | by `target_id`, `document_id`, or `new_for_agent` (default) |
  | `add_comment` | write | on a target, or a reply (`parent_id`); author always `agent` |
  | `resolve_comment` | write | `comment_id`, optional reply |

  Every write tool requires `reason` like every registry write. `list_targets`/`get_target` on the project surface are limited to the project.
- `TestBuildToolRegistry_PinsWriteToolsReadToolsAndSurfaces` extended.

### 4.3 MCP
- `watchtower mcp --project N`: DB writable; `WithRegistry(reg, Binding{Surface:"project", ProjectID:N, DirectApply:true})`; every existing read tool stays mounted. Fails at startup if project N does not exist. Mutually exclusive with `--chat`. If the project is deleted while the server runs, every tool returns `project N no longer exists`.
- Plain `watchtower mcp` untouched (DEV-01 guards unchanged).

### 4.4 CLI (`cmd/project.go`)
- `watchtower project create --folder DIR [--name NAME] [--json]` (name = folder base name by default; refuses a missing directory or an already-bound folder), `list [--json]`, `show N [--json]`, `board N [--json]`, `delete N` (runs the §5 removal first; a removal failure is reported and the delete still happens).
- `watchtower project brief --project N` — the SessionStart hook body, ≤ 4000 chars: counts; the open part of the tree (in progress first, done omitted) with ids; comments new for the agent (target comments, then document comments with heading + quote), each with id; two lines of board rules. Missing project or unreadable DB → one line, exit 0 — a hook never breaks a CC session start.

### 4.5 Briefing
- `gatherProjects()` in `internal/briefing/pipeline.go`: per project with activity — in progress, done since the previous briefing day, blocked, unread agent comments, documents with open owner comments. A `=== PROJECTS ===` block in `briefing.daily` (v7 → v8), counted in `hasData`. A customized DB prompt with the old placeholder count falls back to the default.

## 5. Install into the folder (`internal/devpack/`, `cmd/integrate.go`)

`watchtower integrate claude-code --project N` (DIR = the project's folder); the Desktop runs it right after `project create`. Local to the owner's machine, never committed:

- **MCP:** `claude mcp add --scope local watchtower-project -- <bin> mcp --project N`, run with cwd = DIR. If `claude` is absent, the command is printed.
- **Skill** `watchtower-project` → `DIR/.claude/skills/watchtower-project/SKILL.md` (marker `x-watchtower-pack` + `.watchtower-shipped` digest, DEV-04), path appended to `DIR/.git/info/exclude` in a git work tree. It teaches:
  - **setup** (triggered by the first-run prompt, or when `project_info` shows an empty description): read README/CLAUDE.md/docs, then `update_project` (description), `add_project_source` for sources clearly named in the docs, and propose a first board to the owner; create it with `create_targets` after the owner agrees in the terminal;
  - a feature is agreed → a feature target; a spec/plan is written → `attach_document`; a plan → `create_targets`, one sub-target per plan task (plan path + task number in each intent);
  - before revising an attached document → `list_comments(document_id)`; after → `resolve_comment` each addressed one with a one-line reply, then `attach_document` again (marks it revised);
  - SDD controller: before dispatching a task → `update_target(in_progress)` + `list_comments(target_id)`, owner comments go verbatim into the implementer brief; after review passes → `update_target(done)` + one `add_comment` summary;
  - blocked or needs an owner decision → `add_comment` with the question, continue with other work;
  - comment discipline: questions, blockers, done-summaries only.
- **Hook:** `SessionStart` in `DIR/.claude/settings.local.json` running `<bin> project brief --project N`, merged preserving every other key, recognised by its command; a malformed existing file is left untouched and reported. `settings.local.json` is made ignored (`.git/info/exclude`) if it is not.
- `integrate status --project N` reports MCP, skill, hook; `integrate remove --project N` undoes all three plus the exclude lines it added; `project delete` calls the same removal.

## 6. Desktop

### 6.1 Projects tab
- Sidebar tab **Projects**: project list (name, folder, open/in-progress counts, badge = unread agent comments + documents revised since last viewed). **New project…** → NSOpenPanel (choose or create a folder) → `watchtower project create --folder` → `watchtower integrate claude-code --project N` → the project opens with its terminal running the first-run setup prompt.
- Project page: **Terminal** | **Board** | **Documents** panes, header with folder (reveal in Finder), install status (Repair runs `integrate` again), Delete (confirmation lists what is removed, incl. the folder cleanup).

### 6.2 Terminal
- SwiftTerm `LocalProcessTerminalView` running the owner's login shell in DIR: `$SHELL -l -c 'exec claude'`, or `exec claude "<first-run prompt>"` for a new project (prompt: `Set up this Watchtower project using the watchtower-project skill.` — fixed text, no owner data). Login shell so `PATH` and `claude` auth are the owner's own.
- `ProjectTerminalCenter` on `AppState` owns one terminal session per project — it survives navigation (the surviving-state house rule); closing a project's terminal or quitting the app sends SIGHUP to the process group, then SIGKILL after 3 s (`QuitCoordinator` hooks in like the chat session pool). Restart button when the process exits.
- TCC: a folder under `~/Documents`, `~/Desktop`, `~/Downloads` or `~/Library/CloudStorage` makes macOS attribute CC's file access to Watchtower. POC: the New-project flow warns for those locations; the manual checklist verifies no unexpected prompt for a folder outside them.

### 6.3 Documents with inline comments
- List of attached documents (kind, title, linked target, open-comment count, "revised" mark). Opening one renders the markdown in a selectable `NSTextView` (wrapper; `SwiftUI.Text` cannot report a selection range). Select → **Comment** → a margin thread; the anchor is taken on the **rendered plain text**: `anchor_quote` = selection, prefix/suffix = 64 chars around it, `anchor_heading` = nearest preceding heading.
- Re-anchoring on every load/file change (the view watches the open file): exact quote match; several matches → best prefix/suffix match; none → the thread moves to an "Outdated" list and is set `outdated`. Pure logic in WatchtowerCore (`CommentAnchor`).
- Threads show agent replies and resolved state; the owner can reply, resolve, reopen. The Desktop never writes the file.

### 6.4 Board
- Target tree with status, progress, comment/document badges. Selecting a target shows title, intent, status, progress and its comment thread; the owner can edit status/title and comment (direct GRDB writes, the targets dual-path precedent). Viewing marks agent comments read.
- `TargetQueries.fetchAll`/`fetchCounts`/`fetchDistinctTags` and the Targets badge exclude `project_id IS NOT NULL`; `Target.projectID` added.

### 6.5 Notifications
- `ProjectNotificationCenter` (on `AppState`) polls or observes `project_comments`, `project_documents`, project targets and posts via the existing `NotificationService` on: a new agent root comment on a target ("Agent asks on ‹target›"); a document attached or revised ("‹doc› ready for review"); the last open owner comment on a document resolved ("All comments on ‹doc› answered"); a target moved to `done` by an agent ("‹target› done").
- Pure `ProjectNotificationPolicy` (WatchtowerCore, no clock/I-O): events since a per-project watermark (persisted), burst coalescing (≥ 3 events of one kind in a project within a poll → one summary notification), never the owner's own writes. Click deep-links to the project's Board or Documents pane. Settings toggle, default on.

## 7. Contracts

- **DEV-06 (new, `docs/inventory/dev-surface.md`):** `watchtower mcp --project N` writes only project N's rows (project, sources, targets, documents, comments), applies them directly with an `agent_actions` audit row, and never runs an `External` tool. Guards `TestDev06_WriteOutsideTheBoundProjectIsRefused`, `TestDev06_ExternalToolRefusedUnderDirectApply`, `TestDev06_PlainMCPStaysReadOnly`, `TestDev06_AttachDocumentStaysInsideTheFolder`.
- **DEV-01 amendment:** "read-only forever" applies to `watchtower mcp` without `--project`. **DEV-05 amendment:** the SessionStart hook installed by `integrate --project` is the explicit CLI opt-in the contract requires.
- **`docs/inventory/projects.md` (new):** PROJ-01 project targets never reach a non-board reader; PROJ-02 delete leaves nothing — no project row, target, comment, document, nor installed file/registration in the folder; PROJ-03 the Desktop never writes a project document; PROJ-04 the install never overwrites the owner's own content (settings keys, an edited skill).
- Changelog entries dated 2026-09-29 citing this spec; CLAUDE.md feature note; `docs/app-guide.md` for the Projects tab.

## 8. Out of scope (POC)

A Watchtower chat for projects (rich CC-engine chat UI, permission cards), indexing project documents into `kb`, issue-tracker automation, artefact-id dossiers, Google Drive, multi-agent claims/locks, using `project_sources` for search, migrating `chat_projects`.

## 9. Phasing

1. Go core — migration, `projects.go`, target exclusions, `project` CLI incl. `brief`/`delete`.
2. Registry `DirectApply` + project tools + `mcp --project` + contracts.
3. Install into the folder (skill, hook, local MCP, removal). **Dogfooding starts here** from the owner's own terminal.
4. Desktop: Projects tab shell, terminal, documents with inline comments, notifications.
5. Desktop board + Targets-tab exclusions; briefing Projects section; docs.

## 10. Verification

- Inner loop per task: the touched package, `go test ./cmd -run 'TestBuildToolRegistry|TestProject|TestIntegrate|TestDev06'`, `make test-swift FILTER=…`, `make lint-diff`. Full gate once per phase and before the PR.
- End to end on this repository: New project → terminal opens, CC runs setup: description + sources set, first board proposed and created on "yes" → a fresh CC session (embedded or iTerm) shows the brief, `/mcp` lists `watchtower-project` → agreeing a feature and writing its spec + plan attaches both documents and fills the board → the owner comments a paragraph of the plan in the Desktop → a notification-free owner write; the next brief lists the comment; CC revises the plan, resolves the comment with a reply → "All comments answered" notification; the view shows the new text and resolved thread → an SDD task goes in_progress → done with a summary comment → "done" notification → Delete project leaves `git status` clean, no `watchtower-project` in `claude mcp list`, no project rows. Project targets never appear in the Targets tab, the day-plan input or next-step.
