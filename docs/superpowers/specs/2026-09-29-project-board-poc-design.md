# Projects POC — Watchtower develops Watchtower (2026-09-29)

**Status:** design, revision 3 (owner feedback 2026-09-29) — awaits owner review before the implementation plan.
**Vision:** `2026-09-29-chat-projects-vision.md`. This POC is a **new feature, Projects** — separate from the AI Chat's v1 projects (`chat_projects`), which stay as they are.

## 1. Goal

Two **equal** ways to work on a project, the customer picks per task: in terminal Claude Code (CC) with Watchtower connected, or in the Watchtower project chat, which runs the same CC engine in the project's folder. Either way Watchtower is the **wide overview**: every project's board, what agents are doing, what they are asking, which plans wait for review — and it pings the owner when something needs them.

- A **project** is a folder (first: this repository) plus optional sources. The owner only creates/opens the folder; everything else is set up **through the project chat**.
- The project has a **board** — targets with sub-targets — that outlives CC sessions.
- **Plan = board:** when a `writing-plans` plan is written, its tasks become sub-targets of the feature target; the subagent-driven-development controller moves them and reports on them.
- **Documents with inline comments:** specs and plans an agent writes are attached to the project and open in the Desktop like a Claude document — the owner selects text and comments; the agent reads open comments, revises the file, and resolves each comment with a reply.
- **Comments on targets:** mainly so agents can ask the owner questions without blocking.

- **Notifications:** a macOS notification when an agent asks a question, attaches or revises a document awaiting review, answers all open comments on a document, or completes a target; clicking opens it.

**Success criterion (two weeks):** the owner reviews plans and specs in the Desktop document view instead of reading md in the terminal, comes to the board when a notification says so, and checks project state there rather than asking CC.

**Later (not this POC):** the same for work projects with an issue tracker — "let's do XXX-123" → Watchtower decomposes it on the board and moves the tracker issue as work progresses.

## 2. Decisions (owner, 2026-09-29)

| # | Decision |
|---|---|
| D1 | Projects is its own feature and entity (`projects` table, own sidebar tab), not an extension of `chat_projects`. |
| D2 | Setup is chat-driven: the owner picks the folder; the project chat configures description, sources and the board via tools. |
| D3 | Only **documents** (md/txt) of the folder are indexed, not code. Project documents are isolated: a search outside the project never returns them. |
| D4 | Project targets live only on the project board — excluded from the Targets tab, day plan, next-step, catch-up, memory mirrors, inbox overdue notify, target extract/dedup. The daily briefing gets a separate **Projects** section. |
| D5 | `watchtower mcp --project N` is a new writable MCP mode for external CC: writes to its own project apply directly (no Approve), audited; nothing external. New contract DEV-06; DEV-01 and DEV-05 amended. |
| D6 | Plan = board via a project skill + a SessionStart hook installed into the folder. Superpowers skills are not modified. |
| D7 | Deleting a project cascades: targets, comments, documents, index rows — and removes everything Watchtower installed in the folder. |
| D8 | Plans/specs are attached documents with text-anchored comments. |
| D9 | The assistant does setup itself — description, sources, board, and connecting CC to the folder (skill, hook, MCP) — after the owner's yes in chat. Nothing is handed to the owner to copy or click through. |
| D10 | Working through Watchtower and through CC are equal flows: the project chat runs the CC engine in the folder (files, Bash, the folder's `.claude/` and memory, CC's own permission modes, approvals as cards). |
| D11 | Owner notifications for agent questions, documents to review, answered comments, completed targets. |

## 3. Data

One goose migration, mirrored into `internal/db/schema.sql`, `TestAllTablesExist`, the schema golden, and `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`.

```sql
CREATE TABLE projects (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  folder_path TEXT NOT NULL UNIQUE,          -- absolute
  description TEXT NOT NULL DEFAULT '',      -- set through the project chat
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
  rel_path TEXT NOT NULL,                    -- relative to folder_path
  kind TEXT NOT NULL DEFAULT 'doc' CHECK(kind IN ('spec','plan','doc')),
  title TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  UNIQUE(project_id, rel_path)
);

CREATE TABLE project_comments (
  id INTEGER PRIMARY KEY,
  project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  target_id INTEGER REFERENCES targets(id) ON DELETE CASCADE,
  document_id INTEGER REFERENCES project_documents(id) ON DELETE CASCADE,
  parent_id INTEGER REFERENCES project_comments(id) ON DELETE CASCADE,  -- a reply
  author TEXT NOT NULL CHECK(author IN ('owner','agent')),
  agent_label TEXT NOT NULL DEFAULT '',      -- e.g. "implementer T3"
  body TEXT NOT NULL,
  anchor_quote TEXT NOT NULL DEFAULT '',     -- document comments: the selected text
  anchor_prefix TEXT NOT NULL DEFAULT '',    -- up to 64 chars before / after, for re-anchoring
  anchor_suffix TEXT NOT NULL DEFAULT '',
  anchor_heading TEXT NOT NULL DEFAULT '',   -- nearest heading, shown to the agent
  status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','resolved','outdated')),
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  read_at TEXT NOT NULL DEFAULT '',          -- owner's read mark on agent comments
  CHECK (target_id IS NOT NULL OR document_id IS NOT NULL OR parent_id IS NOT NULL)
);
```

- `targets.project_id INTEGER REFERENCES projects(id) ON DELETE CASCADE` + index. Project targets are created with `level='custom'`, `custom_label='project'`, `period_start = period_end =` creation day, `source_type='chat'`, `ownership='mine'`; the board UI does not show level/period.
- `kb_documents.project_id INTEGER` (NULL for every existing source). Deleting a project deletes its `kb_documents` rows in the same transaction (the chunk/FTS triggers follow).
- A comment's **status** is only meaningful on thread roots. `outdated` = the anchor no longer matches the file (§6.3). "New for the agent" = open owner roots, or owner replies newer than the thread's last agent reply — no per-agent read state.

## 4. Go

### 4.1 db layer
- `db.Target.ProjectID sql.NullInt64` through `targetSelectCols`/`scanTarget`/`CreateTarget`/`UpdateTarget`. `TargetFilter.ProjectID *int64`: nil = **exclude** project targets, the default for every existing caller.
- `project_id IS NULL` added to every non-board reader: `GetTargets` (default), `GetTargetsNeedingNextStep`, `GetTargetsForBriefing`, `GetTargetCounts`, `NotifyDueTargets`, `ListCatchupTargets`, `ListTargetsForMirror`, `internal/dayplan/gather.go` (raw SQL), `internal/db/channel_stats.go`, the extract/dedup snapshots in `internal/targets/pipeline.go`. `nextstep.go`'s single-target path refuses a project target. `targets_promote.go` copies `project_id`.
- New `internal/db/projects.go`: project CRUD, sources, documents, comments (add / reply / resolve / mark outdated / list by target, document, or "new for the agent"), `GetProjectBoard(projectID)` (target tree + per target: open owner threads, unread agent comments, attached documents), `DeleteProject` (one transaction: the row — cascades — plus its `kb_documents`).

### 4.2 Registry and tools (`internal/tools/`, `cmd/actions_registry.go`)
- `tools.Binding` gains `ProjectID int64` and `DirectApply bool`; new surface `"project"`.
- **DirectApply:** `Registry.Propose` with `DirectApply` records the `agent_actions` row approved and applies inline (audit kept). Refuses every `External` tool (AGENT-03 unchanged). Not `execute` trust — trust is keyed by tool name only and would leak into other chats.
- **Scope rule:** every `project`-surface tool resolves the target/document/comment it touches and fails unless it belongs to `Binding.ProjectID`. New rows take `project_id` from the binding, never from an argument. `attach_document` paths must resolve inside `folder_path` (no `..`, no symlink escape) and point to an existing `.md`/`.txt` file.
- Tools (all on surface `project`):

  | Tool | Kind | What |
  |---|---|---|
  | `project_info` | read | name, folder, description, sources, counts |
  | `project_board` | read | target tree + comment counters + attached documents |
  | `update_project` | write | description |
  | `connect_claude_code` / `disconnect_claude_code` | write | runs the §5 install/removal for this project's folder (local files + `claude mcp add --scope local`); project chat only, not on `mcp --project` |
  | `add_project_source` / `remove_project_source` | write | kinds per §3 |
  | `create_targets` | write | array of `{text, intent, parent_id? \| parent_ref?}` — a whole plan in one call |
  | `update_target` | write | status, progress, title, intent, sub_items |
  | `attach_document` | write | `rel_path`, `kind`, optional `target_id` |
  | `list_comments` | read | by `target_id`, `document_id`, or `new_for_agent=true` (default) |
  | `add_comment` | write | on a target, or reply to a comment; author is always `agent` |
  | `resolve_comment` | write | `comment_id`, optional reply body |

  `list_targets`, `get_target`, `search_knowledge`, `get_knowledge_document` honour `Binding.ProjectID`; with 0 they behave exactly as today.
- `TestBuildToolRegistry_PinsWriteToolsReadToolsAndSurfaces` extended for the new surface.

### 4.3 Surfaces that bind a project
- **External CC:** `watchtower mcp --project N` — writable DB, `Binding{Surface:"project", ProjectID:N, DirectApply:true}`. Fails at startup if project N does not exist. Mutually exclusive with `--chat`. Plain `watchtower mcp` is untouched (`SetReadOnly`, DEV-01 guards unchanged).
- **Project chat (Desktop):** a warm `ai session` with a new `--work-project N` flag (conversation `context_type='project'`, `context_id=N`). The session's MCP child runs `mcp --chat --surface project --work-project N` with `DirectApply:true` — local project writes by the owner's own assistant in the owner's own chat apply immediately and show as steps (the target-chat `execute` directive precedent); anything `External` stays behind Approve. The system prompt (`BuildSystemPrompt`) gets a project block: name, folder, description, sources, board summary, and the setup guidance ("the owner only picked a folder; read its documents and propose description, sources, a board and connecting Claude Code; apply them yourself when the owner agrees — never ask the owner to copy or run anything").
- **Project chat as an executor (phase 8, §6.6):** the same session with cwd = `folder_path` and `--setting-sources project,local` instead of `chat.NeutralWorkDir`, CC built-ins (Read/Write/Edit/Glob/Grep/Bash) enabled, the folder's skills/`.mcp.json`/permission rules/auto-memory in effect — exactly as terminal CC in that folder. Plain AI Chat conversations keep the neutral cwd and hidden built-ins.

### 4.4 CLI (`cmd/project.go`)
- `watchtower project create --folder DIR [--name NAME]` (name defaults to the folder base name; refuses a missing directory or an already-bound folder), `list [--json]`, `show N`, `board N [--json]`, `delete N` (runs the folder cleanup of §5 first, then `DeleteProject`; a cleanup failure is reported and the delete still happens).
- `watchtower project brief --project N` — the SessionStart hook body, ≤ 4000 chars: counts; the open part of the tree (in progress first, done omitted) with ids; comments new for the agent (target comments, then document comments with `anchor_heading` + quote), each with its id; two lines of board rules. A missing project prints one line and exits 0 — a hook must never break a CC session.

### 4.5 Index — project documents (`internal/kb/`)
- Source `project_files`: for each project, walks `folder_path`; includes `*.md`, `*.txt`; skips `.git`, `.build`, `node_modules`, `.claude/worktrees`, hidden directories, files over 1 MB. Id `pf:<project_id>:<rel_path>`, cursor = max mtime, sections at markdown headings, `link` = `file://` path, `kb_documents.project_id` set. Reconciled every run. Registered before Slack in `allSources()`.
- `kb.Request.ProjectID`: 0 → `AND d.source <> 'project_files'`; N → that project's documents are included alongside everything else (soft scope). `project_files` is rejected as an explicit `sources` value; `GetDocument` applies the same rule.

### 4.6 Briefing
- `gatherProjects()` in `internal/briefing/pipeline.go`: per project — in progress, done since the previous briefing day, blocked, unread agent comments, documents with open owner comments. A `=== PROJECTS ===` block in `briefing.daily` (v7 → v8), counted in `hasData`. A customized DB prompt with the old placeholder count must not break formatting — verify the `getPrompt` path and fall back to the default on a count mismatch.

## 5. Integrate into the folder (`cmd/integrate.go`, `internal/devpack/`)

`watchtower integrate claude-code --project N` (DIR = the project's folder). Local to the owner's machine, never committed:

- **MCP:** `claude mcp add --scope local watchtower-project -- <bin> mcp --project N`, run with cwd = DIR. If `claude` is absent, the command is printed, as today.
- **Skill** `watchtower-project` → `DIR/.claude/skills/watchtower-project/SKILL.md` with the `x-watchtower-pack` marker + `.watchtower-shipped` digest (DEV-04); appended to `DIR/.git/info/exclude` when DIR is a git work tree. It teaches:
  - a feature is agreed → a feature target (`create_targets` with one item);
  - a spec or plan file is written → `attach_document` (kind `spec`/`plan`, the feature target);
  - a plan is written → `create_targets`, one sub-target per plan task, plan path + task number in each intent;
  - before revising an attached document → `list_comments(document_id)`; after revising → `resolve_comment` each addressed comment with a one-line reply; leave unaddressed ones open;
  - SDD controller: before dispatching a task → `update_target(in_progress)` + `list_comments(target_id)`, owner comments go verbatim into the implementer brief; after review passes → `update_target(done)` + one `add_comment` summary (what changed, commit);
  - blocked or needs an owner decision → `add_comment` with the question, continue with other work;
  - comment discipline: questions, blockers, done-summaries only.
- **Hook:** a `SessionStart` entry in `DIR/.claude/settings.local.json` running `<bin> project brief --project N`, merged preserving every other key, recognised by its command. The installer ensures `settings.local.json` is ignored (adds it to `.git/info/exclude` if not).
- `integrate status --project N` reports MCP (`claude mcp get`), skill, hook. `integrate remove --project N` undoes all three plus the exclude lines it added. Project delete (§4.4) calls the same removal.
- The project chat runs the install itself through `connect_claude_code` once the owner agrees (D9); the same code path as the CLI command.

## 6. Desktop

### 6.1 Projects tab
- New sidebar tab **Projects**: list of projects (name, folder, open/in-progress counts, badge = unread agent comments + documents with new agent replies). "New project…" → NSOpenPanel (open an existing folder or create one) → `watchtower project create --folder` → the project opens on its chat.
- Project page, three panes: **Chat** (the project chat, §4.3), **Board**, **Documents**. A small header: folder (reveal in Finder), Claude Code connection status + Connect/Disconnect, Delete (confirmation lists what is removed, including the folder cleanup).

### 6.2 Board
- Target tree with status, progress, comment and document badges. Selecting a target shows its detail (reuse `TargetDetailView` sections that make sense: title, intent, status, sub-items) plus its comment thread; the owner can comment and reply (direct GRDB write, the targets dual-path precedent). Viewing marks agent comments read.
- `TargetQueries.fetchAll`/`fetchCounts`/`fetchDistinctTags` and the Targets sidebar badge exclude `project_id IS NOT NULL`; `Target.projectID` added.

### 6.3 Documents with inline comments
- List of attached documents (kind, title, linked target, open-comment count). Opening one shows the file rendered as markdown in a **selectable text view** (`NSTextView` wrapper; `SwiftUI.Text` selection cannot report a range). Select text → "Comment" → a margin thread anchored to the selection: `anchor_quote` = selection, `anchor_prefix`/`anchor_suffix` = 64 chars around it, `anchor_heading` = nearest preceding heading.
- **Re-anchoring** on every load (the file is re-read from disk; it changes as the agent revises it): find the quote; if several matches, pick the one whose prefix/suffix match best; if none, the thread is shown in an "Outdated" list and its status set to `outdated` (owner can reopen with a fresh selection or resolve). Pure logic in WatchtowerCore (`CommentAnchor`), tested there.
- Threads show agent replies and resolved state; the owner can resolve or reopen.
- The file is never written by the Desktop — only the agent edits documents (in CC). The view refreshes on file change (a file-system watch on the open document).

### 6.4 Notifications
- `ProjectNotificationCenter` (on `AppState`, the `MeetingReminderCenter` shape) observes `project_comments`, `project_documents` and project targets via GRDB `ValueObservation` and posts through the existing `NotificationService` on:
  - a new agent root comment on a target (a question) — "Agent asks on ‹target›";
  - a document attached, or an attached document's file changed while it has owner comments — "‹plan› is ready for review";
  - the last open owner comment on a document resolved — "All comments on ‹plan› answered";
  - a target moved to `done` by an agent — "‹target› done".
- Pure decision logic (`ProjectNotificationPolicy`, WatchtowerCore, no clock/I-O): what is new since the last seen watermark (persisted per project), coalescing a burst (an SDD run closing 10 tasks → one "10 targets done" notification per project per minute), never notifying about the owner's own writes. Clicking deep-links into the project's Board or Documents pane. Settings toggle, default on.

### 6.5 Onboarding
- After "New project…", the chat opens with a seeded first turn: "Set up this project." The assistant reads the folder's documents (`search_knowledge` / `get_knowledge_document`, available once the first index pass ran — the Desktop nudges a sync and the chat waits for the `project_files` cursor) and proposes description, sources, an initial board and connecting Claude Code; on the owner's "yes" it applies all of it through the §4.2 tools (direct, visible as steps).

### 6.6 Project chat as an executor
- The project chat runs the CC engine in the folder (§4.3). Tool steps (file edits, Bash) render in the existing steps block.
- **Permissions are CC's own:** the folder's `settings*.json` allow/deny rules and CC's permission modes (default / acceptEdits / plan; a mode picker in the composer, no bypass). A check the rules do not settle arrives as a stream-json `can_use_tool` control request (CLI started with `--permission-prompt-tool stdio`, the channel `interrupt` already uses) → new protocol v2 event `permission_request` → an approval card (Allow once / Always in this project → the rule appended to `.claude/settings.local.json` as CC does / Deny) → a `permission` command back. **Spike first:** confirm `can_use_tool` over our stream-json session on the current CLI before building the card.
- The session's MCP child stays the project-bound Watchtower server (§4.3), so the executor sees the same board, documents and comments as terminal CC.
- Security note (vision §5.1): the executor reads synced third-party text and has Bash. POC keeps CC's model unchanged and documents the risk in `docs/inventory/projects.md`; a stricter network rule is an owner call after the POC.

## 7. Contracts

- **DEV-06 (new, `docs/inventory/dev-surface.md`):** a project-bound surface (`mcp --project N`, the project chat) writes only project N's rows (project, sources, targets, documents, comments), applies them directly with an `agent_actions` audit row, and never runs an `External` tool without Approve. Guards: `TestDev06_WriteOutsideTheBoundProjectIsRefused`, `TestDev06_ExternalToolRefusedUnderDirectApply`, `TestDev06_PlainMCPStaysReadOnly`, `TestDev06_AttachDocumentStaysInsideTheFolder`.
- **DEV-01 amendment:** "read-only forever" applies to `watchtower mcp` without `--project`; project mode is the DEV-06 surface. Existing guards unchanged.
- **DEV-05 amendment:** the SessionStart hook installed by `integrate --project` is the explicit CLI opt-in the contract already requires.
- **New inventory file `docs/inventory/projects.md`:** PROJ-01 project targets never reach a non-board reader (guard over the §4.1 exclusion list); PROJ-02 project documents never reach a search outside the project; PROJ-03 delete leaves nothing — no project row, target, comment, document, index row, nor installed file/registration in the folder; PROJ-04 the Desktop never writes a project document.
- Changelog entries dated 2026-09-29 citing this spec. CLAUDE.md feature note; `docs/app-guide.md` for the Projects tab.

## 8. Out of scope (POC)

Issue-tracker automation (the "XXX-123" flow), artefact-id dossiers, Google Drive, multi-agent claims/locks, code indexing, using `project_sources` for search boosting (stored and shown in prompts/brief only), Codex/Ollama specifics, migrating `chat_projects` into Projects.

## 9. Phasing

1. Go core — migration, `projects.go`, target exclusions, `project` CLI incl. `brief`/`delete`.
2. Registry DirectApply + project tools + `mcp --project` + contracts.
3. Integrate (skill, hook, local MCP, removal). **Dogfooding starts here** — board via `watchtower project board`, comments via CLI until phase 4.
4. Desktop documents view with inline comments (+ `CommentAnchor` in WatchtowerCore) and notifications — so reviewing this feature's own plans moves into the Desktop as early as possible.
5. Desktop Projects tab: board, target comments, Target-tab exclusions.
6. Project documents in the index + scoped search; project chat (`ai session --work-project`) + chat-driven setup/onboarding incl. `connect_claude_code`.
7. Briefing Projects section.
8. Project chat as an executor: spike `can_use_tool`, then cwd/built-ins, permission cards, mode picker.

## 10. Verification

- Inner loop per task: the touched package, `go test ./cmd -run 'TestBuildToolRegistry|TestProject|TestIntegrate|TestDev06'`, `make test-swift FILTER=…`, `make lint-diff`. Full gate once per phase and before the PR.
- End to end on this repository: New project → the chat proposes description + board, applied on "yes" → Connect Claude Code → a fresh CC session shows the brief, `/mcp` lists `watchtower-project` → agreeing a feature and writing its spec + plan attaches both documents and fills the board → the owner comments a paragraph of the plan in the Desktop → the next CC session's brief lists it; CC revises the plan and resolves the comment with a reply; the Desktop shows the new text and the resolved thread → an SDD task goes in_progress → done with a summary comment → Delete project leaves `git status` clean, no `watchtower-project` in `claude mcp list`, no project rows. Project targets never show in the Targets tab, day-plan input or next-step; `search_knowledge` outside the project returns no project document.
