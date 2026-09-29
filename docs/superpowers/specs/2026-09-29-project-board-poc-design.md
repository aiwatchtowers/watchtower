# Project Board POC — Watchtower develops Watchtower (2026-09-29)

**Status:** design, owner-approved direction (plan approved 2026-09-29); this spec awaits owner review before the implementation plan.
**Vision:** `2026-09-29-chat-projects-vision.md` — this POC covers block A partially (external Claude Code via MCP + integrate; *not* the CC engine inside the Watchtower chat), block D (the board), and a slice of block B (project documents in the index).

## 1. Goal

Dogfood: the owner develops Watchtower with terminal Claude Code (CC), and Watchtower is the project's durable home.

- A **project** is bound to a folder (first: this repository).
- The project has a **board** — targets with sub-targets — that outlives CC sessions and is visible and editable in the Desktop.
- **Owner ↔ agent comments** on targets: the owner leaves a note while no agent runs; the next CC session sees it at start. Agents report questions, blockers and done-summaries the same way.
- **Plan = board:** when a `writing-plans` plan is written, each task becomes a sub-target of the feature's target; the subagent-driven-development controller marks progress and reads comments per task.

**Success criterion (two weeks of use):** the owner opens the board instead of the md plan and answers agents in the Desktop rather than in the terminal. If not, the POC failed cheaply.

## 2. Decisions (owner, 2026-09-29)

| # | Decision |
|---|---|
| D1 | Index the project's **documents** (md/txt), not code. Project documents are isolated: a search outside the project never returns them. |
| D2 | Project targets live only on the project board: excluded from the Targets tab, day plan, next-step, catch-up, memory mirrors, inbox overdue notify, target extract/dedup. The daily briefing gains a separate **Projects** section. |
| D3 | `watchtower mcp --project N` is a new, writable MCP mode for external CC: writes to its own project's board and comments apply **directly** (no Approve), audited; nothing external. New contract DEV-06; DEV-01 and DEV-05 amended. |
| D4 | Plan = board, via a project skill + a SessionStart hook installed into the folder. Superpowers skills are not modified. |
| D5 | Onboarding: after the folder is picked, a Watchtower project chat reads the indexed documents and proposes project instructions and an initial board behind Approve cards. |

## 3. Data

One goose migration (next free number), mirrored into `internal/db/schema.sql`, `TestAllTablesExist`, the schema golden and `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`.

- `chat_projects.folder_path TEXT NOT NULL DEFAULT ''` — absolute path; empty = a v1 folder-less project (unchanged behaviour).
- `targets.project_id INTEGER REFERENCES chat_projects(id) ON DELETE SET NULL`, index `idx_targets_project`. Project targets are created with `level='custom'`, `custom_label='project'`, `period_start = period_end = ` creation day (the NOT NULL columns are satisfied; the board UI does not show them), `source_type='chat'`, `ownership='mine'`.
  - Deleting a project turns its targets into ordinary targets (SET NULL) — acceptable for a POC, surfaced in the delete confirmation.
- `target_comments`:
  ```
  id INTEGER PRIMARY KEY,
  target_id INTEGER NOT NULL REFERENCES targets(id) ON DELETE CASCADE,
  author TEXT NOT NULL CHECK(author IN ('owner','agent')),
  agent_label TEXT NOT NULL DEFAULT '',     -- e.g. "implementer T3"; '' for the owner
  body TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  read_at TEXT NOT NULL DEFAULT ''          -- owner's read mark, agent comments only
  ```
  index on `(target_id, created_at)`. A table rather than the existing `targets.notes` JSON array, because concurrent agents appending to one JSON value would overwrite each other.
  - **Owner comments new to the agent** = owner comments on a target newer than that target's latest agent comment. No per-agent read state.
- `kb_documents.project_id INTEGER` (NULL for every existing source).

## 4. Go

### 4.1 db layer
- `db.Target.ProjectID sql.NullInt64` through `targetSelectCols`/`scanTarget`/`CreateTarget`/`UpdateTarget`. `TargetFilter.ProjectID *int64`: nil means **exclude** project targets — the default for every existing caller.
- `project_id IS NULL` added to every non-board reader: `GetTargets` (default), `GetTargetsNeedingNextStep`, `GetTargetsForBriefing`, `GetTargetCounts`, `NotifyDueTargets`, `ListCatchupTargets`, `ListTargetsForMirror`, `internal/dayplan/gather.go` (raw SQL), `internal/db/channel_stats.go`, and the extract/dedup snapshots in `internal/targets/pipeline.go`. `internal/targets/nextstep.go`'s single-target path refuses a project target. `targets_promote.go` copies `project_id` to the promoted child.
- New `internal/db/target_comments.go`: add, list by target, mark read, unread counts.
- `GetProjectBoard(projectID)`: all project targets as a tree (by `parent_id`) with status, progress, and per target the count of owner comments new to the agent and of agent comments unread by the owner.
- `CreateChatProject(name, folder)`, `GetChatProject(id)`, `ListChatProjects()`. Go becomes a second writer of `chat_projects` next to Swift `ChatProjectQueries.create` — a deliberate dual path, recorded in CLAUDE.md.

### 4.2 Registry and tools (`internal/tools/`, `cmd/actions_registry.go`)
- `tools.Binding` gains `ProjectID int64` and `DirectApply bool`; new surface `"project"`.
- **DirectApply:** `Registry.Propose` with `DirectApply` records the `agent_actions` row as approved and applies it inline — the audit trail stays. It refuses any `External` tool (AGENT-03 unchanged). It is deliberately *not* `execute` trust, since trust is keyed only by tool name and would leak into the Desktop chat.
- **Scope rule:** every tool on the `project` surface that touches a target resolves it and fails unless `target.project_id == Binding.ProjectID`; created targets take `project_id` from the binding, never from an argument. A `parent_id` must belong to the same project.
- Tools:

  | Tool | Kind | Surfaces | Notes |
  |---|---|---|---|
  | `project_board` | read | project, main | tree + comment counters |
  | `create_target` | write | main (existing), project | + optional `parent_id` |
  | `create_targets` | write | project, main | array of `{text, intent, parent_ref?}` — one call imports a plan; `parent_ref` points at another item in the batch or at an existing id |
  | `update_target` | write | project, main | status, progress, title, intent, sub_items |
  | `add_target_comment` | write | project, main | `body`, `agent_label` (author is `agent` for tools, always) |
  | `list_target_comments` | read | project, main | by target |

  On `main` these tools only operate when the conversation belongs to a project and stay behind Approve (the onboarding chat). `list_targets`, `get_target` and `search_knowledge` honour `Binding.ProjectID`; with 0 they behave exactly as today.
- `TestBuildToolRegistry_PinsWriteToolsReadToolsAndSurfaces` is extended for the new surface and tools.

### 4.3 MCP (`cmd/mcp.go`)
- `watchtower mcp --project N`: DB stays writable; `WithRegistry(reg, Binding{Surface: "project", ProjectID: N, DirectApply: true})`. Fails at startup if project N does not exist or is archived. Mutually exclusive with `--chat`.
- Plain `watchtower mcp` is untouched (`SetReadOnly`, DEV-01 guards unchanged).
- `mcp --chat` resolves `ProjectID` from the conversation's `chat_conversations.project_id` (no new flag), so a Desktop project chat's search sees that project's documents.

### 4.4 CLI (`cmd/project.go`)
- `watchtower project create --folder DIR [--name NAME]` (name defaults to the folder's base name; refuses a missing directory or a folder already bound to a project), `project list [--json]`, `project show N`, `project board N [--json]`.
- `watchtower project brief --project N` — the SessionStart hook body, ≤ 4000 characters:
  1. one line: project name + counts (open / in progress / blocked);
  2. the open part of the tree (in-progress first, then todo; done omitted), one line per target with id;
  3. owner comments new to the agent, newest first, with target id;
  4. a two-line reminder of the board rules (see §5).

  A missing project prints one line and exits 0 — a hook must never break a CC session start.

### 4.5 Index — project documents (`internal/kb/`)
- New source `project_files`: for each non-archived project with a `folder_path`, walks the folder; includes `*.md`, `*.txt`; skips `.git`, `.build`, `node_modules`, `.claude/worktrees`, hidden directories, and files over 1 MB. Doc id `pf:<project_id>:<relpath>`, cursor = max mtime seen, sections split at markdown headings, `link` = `file://` path, `project_id` set on `kb_documents`. Reconciled every run (the set is small). Registered before Slack in `allSources()`.
- `kb.Request.ProjectID`: 0 → `AND d.source <> 'project_files'`; N → project documents of N are included alongside everything else (soft scope). `project_files` is rejected as an explicit `sources` value. `GetDocument` applies the same rule, so an id from another project cannot be opened.

### 4.6 Briefing
- `gatherProjects()` in `internal/briefing/pipeline.go`: for each project with targets — in progress, done since the previous briefing day, blocked, agent comments unread by the owner. A new `=== PROJECTS ===` block in `briefing.daily` (v7 → v8), counted in `hasData`. A customized DB prompt with the old placeholder count must not break formatting — verify the `getPrompt` path and fall back to the default when the count mismatches.

## 5. Integrate into the folder (`cmd/integrate.go`, `internal/devpack/`)

`watchtower integrate claude-code --project N [--path DIR]` — DIR defaults to the project's `folder_path`. Everything is **local to the owner's machine and never committed**:

- **MCP:** `claude mcp add --scope local watchtower-project -- <bin> mcp --project N`, run with cwd = DIR (local scope is stored per path in the owner's `~/.claude.json`). If `claude` is absent, the command is printed, as today.
- **Skill** `watchtower-project` → `DIR/.claude/skills/watchtower-project/SKILL.md`, with the existing `x-watchtower-pack` marker and `.watchtower-shipped` digest (never clobbers an edited copy, DEV-04); the path is appended to `DIR/.git/info/exclude` when DIR is a git work tree. The skill teaches:
  - a new feature is agreed → create a feature target (`create_target`);
  - a plan is written → `create_targets`, one sub-target per plan task, the plan path and task number in each intent;
  - SDD controller: before dispatching a task → `update_target(in_progress)` and `list_target_comments`, owner comments go verbatim into the implementer brief; after the task passes review → `update_target(done)` + one `add_target_comment` summary (what changed, commit);
  - blocked or needs an owner decision → a comment with the question, then continue with other work;
  - comment discipline: only questions, blockers and done-summaries; never progress chatter.
- **Hook:** a `SessionStart` entry in `DIR/.claude/settings.local.json` running `<bin> project brief --project N`. The file is read, merged and rewritten preserving every other key; the entry is recognised by its command, so `integrate remove --project N` deletes only it. `settings.local.json` is already git-ignored by Claude Code convention; the installer checks and adds it to `.git/info/exclude` if it is not ignored.
- `integrate status --project N` reports MCP (via `claude mcp get`), skill and hook state. `integrate remove --project N` undoes all three.

## 6. Desktop

- **Projects:** "New project from folder…" (NSOpenPanel → `watchtower project create --folder`), a Folder row on the project page, and a **Connect Claude Code** button that runs `integrate claude-code --project N` and shows `integrate status`.
- **Board** tab in `ProjectDetailView`: the target tree (status, progress, comment badges), selecting a target opens `TargetDetailView` plus a comments thread; the owner can add a comment (`author='owner'`, direct GRDB write, the targets dual-path precedent); opening a target marks its agent comments read. The project row in the chat sidebar shows the unread agent-comment count.
- `TargetQueries.fetchAll`/`fetchCounts`/`fetchDistinctTags` and the sidebar badge exclude `project_id IS NOT NULL`; `Target.projectID` added.
- **Onboarding:** after "New project from folder", once the project's documents are indexed (sync-now nudge, then the chat opens), a project chat opens seeded with "Organize this project: read the documents and propose instructions and an initial board." The assistant uses `search_knowledge` / `get_knowledge_document` and proposes via `create_targets` Approve cards; instructions are proposed as text for the owner to paste (no new tool).

## 7. Contracts

- **DEV-06 (new, `docs/inventory/dev-surface.md`):** `watchtower mcp --project N` writes only the targets and target comments of project N, applies them directly with an `agent_actions` audit row, and never runs an `External` tool. Guards: `TestDev06_WriteToAnotherProjectsTargetIsRefused`, `TestDev06_ExternalToolRefusedUnderDirectApply`, `TestDev06_PlainMCPStaysReadOnly`.
- **DEV-01 amendment:** "read-only forever" applies to `watchtower mcp` without `--project`; project mode is the separate DEV-06 surface. Existing guards unchanged.
- **DEV-05 amendment:** the SessionStart hook installed by `integrate --project` is the explicit CLI opt-in the contract already requires; nothing is injected without that command.
- **Targets:** a guard test pins that each reader in §4.1's exclusion list returns no project target.
- Changelog entries in both inventory files, dated 2026-09-29, citing this spec.

## 8. Out of scope (POC)

The CC engine inside the Watchtower chat, permission cards, artefact id dossiers, Google Drive, multi-agent claims/locks, Codex/Ollama specifics, code indexing, a Stop hook, cross-project boards.

## 9. Phasing

1. Go core — migration, db, exclusions, comments, `project` CLI (§3, §4.1, §4.4).
2. Registry DirectApply, tools, `mcp --project`, contracts (§4.2, §4.3, §7).
3. Integrate (§5). **Dogfooding starts here**, with `watchtower project board` as the viewer.
4. Desktop board, comments, exclusions (§6 without onboarding).
5. Project documents in the index + scoped search (§4.5), then onboarding (§6).
6. Briefing Projects section (§4.6).

## 10. Verification

- Inner loop per task: the touched package (`go test ./internal/db`, `./internal/tools`, `./internal/mcp`, `./internal/kb`, `./internal/briefing`, `./internal/devpack`), `go test ./cmd -run 'TestBuildToolRegistry|TestProject|TestIntegrate|TestDev06'`, `make test-swift FILTER=…`, `make lint-diff`. Full gate once per phase and before the PR.
- End to end: `project create --folder <repo>` → `integrate claude-code --project 1` → a fresh CC session in the repo shows the brief; `/mcp` lists `watchtower-project`; agreeing a feature and writing a plan fills the board; an owner comment added in the Desktop appears in the next session's brief; an SDD task flips in_progress → done with an agent summary comment. Project targets do not appear in the Targets tab, the day-plan input or next-step; `search_knowledge` from a normal chat returns no project document, from the project chat it does; `git status` in the repo is clean after `integrate`.
