# Chat Redesign — one place to do the work

**Date:** 2026-09-26
**Status:** implemented on `feature/chat-redesign` (2026-09-26); design approved by owner (sections 1–3 in conversation; remaining sections delegated). Contracts: `docs/inventory/chat.md`.
**Branch:** `feature/chat-redesign` — the whole redesign lands in main as one PR.

## Goal

The owner should stop switching to Claude Desktop for work questions. The main AI Chat becomes a first-class assistant modeled on Claude Desktop / ChatGPT (UX) and Onyx (answers grounded in the owner's own sources, with visible sources). Four axes, all in scope:

1. **Ask about work** — answers from Slack/Jira/mail/meetings/knowledge with visible tool steps and source chips.
2. **Long conversations & projects** — real history (grouped, searchable, pinned), branching, projects with pinned instructions/files/sources.
3. **Files & artifacts** — attach images/PDFs/text; produce documents/tables/drafts as artifacts in a side panel.
4. **Actions** — do things through the existing Approve registry.

Primary provider is **Claude** (full experience). Codex and Ollama speak the same event protocol but are not guaranteed token streaming, visible steps or binary attachments in v1.

### Non-goals (v1)

- Sending Slack messages, sending/drafting Gmail, creating calendar events **through APIs** (requires new OAuth scopes: Slack `chat:write` app change + re-auth; Gmail `gmail.compose` restricted scope + CASA; Calendar `calendar.events` re-verification). v1 prepares these as artifacts and opens them "ready" in the target app (owner decision 2026-09-26).
- Migrating the Discuss chats (target/idea/meeting/track) onto the new session engine. They receive the shared renderer in this PR; engine migration is a follow-up per surface.
- Numbered `[1]` inline citations (needs model discipline; source chips ship instead).
- Web search, code execution, vector search.
- Mobile / web clients.

## Current state (2026-09-26, the problems this fixes)

- Every turn spawns `watchtower ai query` → `claude -p` → an MCP subprocess: cold start each turn.
- Streaming is whole-message (`--include-partial-messages` absent); markdown renders only after the turn.
- Tool calls are invisible: any `tool_use` becomes a `reset` event that wipes the text already shown (`internal/ai/client.go` scanner loop, `cmd/ai.go` `runAIQuery`).
- Continuity is Claude-`--resume`-only; Codex (`--ephemeral`) and Ollama are stateless per turn.
- The system prompt is built in Swift (`ChatViewModel.formatSystemPrompt`), passed on argv, contains the entire `sqlite_master` schema, a stale app guide, no owner/language/memory/skills.
- History: right-hand flat list, title-only in-memory search, 80-char prefix titles, no regenerate/edit/retry, plain-text messages with no metadata. Tables are created ad hoc by Swift, not by a goose migration.
- Hand-rolled markdown: no tables, no code highlighting, no copy on code blocks.
- No attachments, artifacts, projects, @-mentions, slash commands. Main-chat write tools: `create_target`, `create_jira_issue`, `connect_jira_board` only.

Spikes run 2026-09-26 against `claude` 2.1.283:
- `claude -p --input-format stream-json --output-format stream-json --include-partial-messages --verbose` keeps one process across turns: turn 2 remembered turn 1; warm turn ≈1.3 s to result vs ≈4.5 s cold.
- `{"type":"control_request","request_id":…,"request":{"subtype":"interrupt"}}` on stdin stops the running turn (`result` with `subtype: error_during_execution`, `control_response` success) and the process accepts the next turn.
- `image` (base64 png) and `document` (base64 pdf) content blocks on stdin are understood natively.

---

## 1. Transport — warm sessions (`watchtower ai session`)

### 1.1 Go command

`watchtower ai session --conversation N [--provider P] [--model M] [--surface main] [--project-id K] [--resume SID] [--db-path …]` is a long-lived process, one per open conversation.

**stdin (JSONL commands):**
```json
{"type":"turn","turn_id":"<uuid>","text":"…","attachments":[{"path":"/abs","mime":"image/png","name":"x.png"}],"replay":false}
{"type":"cancel"}
{"type":"close"}
```
`replay: true` tells the session the provider session is not continuous with this branch (after edit/regenerate/branch switch, or after `session_lost`) — the session rebuilds history from `chat_messages` (§2.4) and starts a fresh provider session.

**stdout (NDJSON events, protocol v2):**
| event | fields | notes |
|---|---|---|
| `session_ready` | `session_id?`, `provider`, `model` | emitted once the provider process is up |
| `turn_start` | `turn_id` | |
| `text_delta` | `turn_id`, `text` | token-level for Claude |
| `tool_start` | `turn_id`, `id`, `name`, `args` (object) | `name` without the `mcp__watchtower__` prefix; external MCP tools keep `server:name` |
| `tool_end` | `turn_id`, `id`, `ok`, `summary` (≤300 chars), `sources[]` | `sources` extracted from known read-tool results (§3.4) |
| `usage` | `turn_id`, `tokens_in`, `tokens_out`, `model` | |
| `turn_done` | `turn_id`, `status` (`complete`\|`interrupted`), `session_id?` | |
| `error` | `turn_id?`, `code`, `message`, `retryable` | codes §5 |

There is **no** `reset` in v2 — text is never wiped.

**Claude path:** one `claude -p --input-format stream-json --output-format stream-json --include-partial-messages --verbose [--resume SID] --system-prompt-file <0600 tmp> --mcp-config … --allowedTools … --disallowedTools … --setting-sources project,local [--model M]` child for the life of the session. A translator maps Claude stream events to v2: `content_block_delta/text_delta` → `text_delta`; `content_block_start` of `tool_use` + accumulated `input_json_delta` → `tool_start` at `content_block_stop`; `user` messages carrying `tool_result` → `tool_end`; `result` → `usage` + `turn_done`; thinking blocks are dropped. `cancel` sends the `interrupt` control request; if no `result` arrives within 5 s the child is killed and the next turn uses `--resume`.

**Codex / Ollama path:** the session keeps the same outer protocol but runs one provider call per turn, always with replay (§2.4). Codex/Ollama emit whole-text `text_delta`s and, where the provider exposes them (Ollama runtime B does), `tool_start`/`tool_end`. Binary attachments on these providers fail with `error{code:"attachment_unsupported"}` before the call.

**`ai query`** (one-shot) stays for the Discuss chats and gains `--events v2` (default v1 unchanged) so the shared Swift engine can consume it when those surfaces migrate.

### 1.2 Turn identity for the MCP server

The MCP server currently receives `--turn T` at launch; a warm process spans many turns. The session writes the current `turn_id` to a 0600 file and launches `watchtower mcp --chat … --turn-file <path>`; `Registry.Propose` reads the file at propose time. `--turn` stays for one-shot use; exactly one of the two is accepted.

### 1.3 System prompt

Built by Go (§4), written to a 0600 temp file, passed with `--system-prompt-file` (never argv), deleted when the session exits. On `--resume` Claude reuses the recorded prompt (verified on claude 2.1.283, 2026-09-27: a session started with `--system-prompt-file` and resumed without it still follows that prompt).

### 1.4 Swift — `ChatSessionPool`

`@MainActor @Observable` on `AppState` (survives navigation, the center house pattern).
- At most **3** live sessions; LRU eviction; idle TTL **10 min** (checked by a 30 s poll, pure decision function `ChatSessionPolicy.decide` à la `WarmEnginePolicy`).
- **Prewarm** on opening a conversation or first keystroke in an empty composer, so the process is ready at Enter.
- Crash / unexpected exit → session marked dead; the next turn respawns with `--resume` (Claude) or replay.
- Stop → `cancel`; partial text is persisted with `status='partial'`.
- Provider/model change mid-conversation → close + reopen (Claude keeps `--resume`, others replay).
- `QuitCoordinator` and app termination close every session (`close`, then SIGTERM after 2 s).
- The pool is injectable (process factory seam) for tests.

---

## 2. Data

### 2.1 Migration `00076_chat_core`

Adopts the Swift-created tables into goose. Existing installs have the tables with or without `turn_id` and the context columns (Swift guarded ALTERs). The repo has only SQL migrations, so adoption is two steps:
1. `normalizeLegacyChatTables` runs in `(*DB).migrate()` **before** `goose.Up`: if `chat_conversations` exists without `context_type`/`context_id`, or `chat_messages` exists without `turn_id`, it adds them (`PRAGMA table_info` check). Idempotent, a no-op on fresh installs and after adoption.
2. SQL migration `00076_chat_core.sql`: `CREATE TABLE IF NOT EXISTS` both tables in their full current shape (+ `idx_chat_messages_conversation`), then `ALTER TABLE … ADD COLUMN` for the new columns, then the new tables.

Swift's `ensureTable`/`ensure*Column` calls are deleted (the `action_item → track` data fix moves into the migration); Swift keeps a floor check that the tables exist.

`chat_conversations` + `pinned INTEGER NOT NULL DEFAULT 0`, `archived_at REAL`, `title_source TEXT NOT NULL DEFAULT 'prefix' CHECK(title_source IN ('prefix','ai','user'))`, `provider TEXT`, `model TEXT`, `project_id INTEGER REFERENCES chat_projects(id) ON DELETE SET NULL`, `active_leaf_message_id INTEGER`.

`chat_messages` + `status TEXT NOT NULL DEFAULT 'complete' CHECK(status IN ('complete','partial','error'))`, `provider TEXT`, `model TEXT`, `tokens_in INTEGER`, `tokens_out INTEGER`, `parent_id INTEGER REFERENCES chat_messages(id) ON DELETE CASCADE`, `error_code TEXT`.

New tables:
- `chat_turn_steps(id, message_id FK cascade, seq, tool_id, name, args_json, ok, summary, sources_json, started_at, ended_at)`.
- `chat_attachments(id, conversation_id FK cascade NULL, project_id FK cascade NULL, message_id FK set null NULL, name, mime, size, path, sha256, created_at)` — CHECK exactly one of conversation_id/project_id.
- `chat_artifacts(id, conversation_id FK cascade, message_id FK cascade, artifact_key, version, kind, title, content, meta_json, edited INTEGER DEFAULT 0, created_at)`, UNIQUE(conversation_id, artifact_key, version).
- `chat_projects(id, name, instructions, created_at, updated_at, archived_at)`.
- `chat_project_sources(id, project_id FK cascade, kind CHECK(kind IN ('jira_project','slack_channel','target','track','person')), ref, label)`.
- `chat_fts` FTS5 (external content over `chat_messages.text`, plus conversation title in a second table or column) with insert/update/delete triggers, so Swift writes need no indexing code.

Mirror into `schema.sql`, `TestAllTablesExist`, schema golden. Swift test DB (`TestDatabase.swift`) mirrors the new shape.

### 2.2 Writers

Swift remains the writer of `chat_conversations`/`chat_messages`/`chat_turn_steps`/`chat_artifacts`/`chat_attachments`/`chat_projects*` (as today). Go writes only `chat_conversations.title`/`title_source` via `watchtower chat title <id>` (§4.4). Memory's chat ingest and `ListRecentChatTurns` keep reading and must only see the **active branch** (§2.3) — they read through a new `db.ActiveChatPath` helper where they read message lists.

### 2.3 Branches (regenerate / edit)

Messages form a tree via `parent_id` (the first message has NULL). The conversation's visible thread is the path from root to `active_leaf_message_id`. Regenerate an assistant message → a new sibling assistant message under the same parent. Edit a user message → a new sibling user message under that message's parent, then a new assistant reply. Siblings show `‹ i/n ›`; switching selects the most recent leaf under the chosen sibling. Legacy rows get `parent_id` backfilled to the previous message in `id` order within the conversation (linear chain).

### 2.4 Replay

When a provider session is not continuous with the active branch (Codex/Ollama always; Claude after branch/edit/regenerate or `session_lost`), the session builds the history from the active path: last messages up to **24k chars** (older ones summarized as "[N earlier messages omitted]"), rendered as a transcript block prefixed to the first turn of the new provider session. Tool steps are not replayed, only their summaries in one line each.

---

## 3. UI

### 3.1 Layout
- **History on the left**, groups: Pinned / Today / Yesterday / Previous 7 days / Previous 30 days / Older, Projects section above (§6). Row actions: rename, pin, move to project, archive, delete.
- **⌘K** search over `chat_fts` with highlighted snippets; opening a hit scrolls to the message.
- **Thread**: centered column, max ~760 pt.
- Toolbar: title (double-click to rename), New chat (⌘N). Provider/model picker moves into the composer.

### 3.2 Assistant message, top to bottom
1. **Steps block** — "Worked for 12s · 4 steps", collapsed when done, expanded while running with the live step on top. Each step: icon + human label from `ChatToolCatalog` (single Swift catalog, `ReactionToolCatalog` precedent): "Searched knowledge: *payments rollout*", "Opened PROJ-123", "Proposed: create Jira issue". Expand → args + summary. Failed step is marked red.
2. **Text** — markdown rendered live while streaming (throttled ~30 fps; an unterminated fence renders as code).
3. **Source chips** — Onyx-style chips (Slack thread / Jira / email / meeting / document / person) deduplicated from the turn's `tool_end.sources`; click opens the permalink/deep link.
4. **Artifact cards** (§7) and **Approve cards** (existing `AgentActionFeed`).
5. Hover actions: Copy, Regenerate, `‹ › ` variants, model · time; user messages: Copy, Edit.
6. Error → error card with message + **Retry**; stopped → "Stopped" + **Continue**.

### 3.3 Renderer
Replace `MarkdownText` with **apple/swift-markdown** parsing + our SwiftUI renderer: headings, paragraphs, emphasis, links (via `AllowedURLSchemes`), lists (nested, task), block quotes, tables, thematic breaks, inline/fenced code. Code blocks: language label, Copy, lightweight in-house highlighter (keywords/strings/comments/numbers for common languages). Shared: all Discuss chats and setup assistants switch to it in this PR.

### 3.4 Sources
`tool_end.sources[]` items: `{kind, title, url?, ref}`. Extraction in Go per known read tool: `search_knowledge` hits (link/anchor), `get_knowledge_document`, `get_jira_issue`/`list_jira_issues`, `list_messages` (permalink), `get_transcript`, `get_person`, `get_digest`, `get_target`. Unknown tools yield none.

### 3.5 Composer
Grows to ~40% window height; Enter send, Shift+Enter newline, Esc stop, ↑ in empty field edits last message; dictation stays; paperclip + drag & drop + paste for attachments (§7.1); `@` mention picker and `/` skill picker (§6.3); provider/model pill.

### 3.6 Empty state
Greeting + four static work prompts ("What mattered yesterday?", "Prep me for today's meetings", "What's waiting on me?", "Summarize PROJ-…"). The auto-generated Welcome chat is removed.

---

## 4. Prompt & context (Go-owned)

### 4.1 `internal/chat` package
`BuildSystemPrompt(ctx, db, cfg, Options{Surface, ProjectID, ToolsAvailable, Provider}) (string, error)` assembles, in order:
1. Identity + current time + owner (`db.ResolveOwner`, display name/email) + language directive (`prompts.Directive`).
2. Connected sources (Slack workspaces via `db.FormatConnectedWorkspaces`, Google/Jira accounts) and the per-account Slack link rule (`internal/ai/slack_link.go` ladder) — fixes the "account #1 team for `slack://`" gap for the main chat.
3. Tools & workflow: "search_knowledge first for topical questions", linking rules (moved from `internal/ai/prompt.go`, shared, not duplicated), no SQL/shell/internet.
4. Agent actions contract for the surface (Go port of `AgentToolsContract.promptBlock(.main)`; Swift copy stays for the target chat until it migrates — dual path, pinned by a fixture test on both sides).
5. Artifacts contract (§7.2).
6. Skills: enabled skills from the skills dir (Go reader of the same frontmatter `load_skill` reads) + load instruction.
7. Memory: when `memory.surfaces.chat` is on, the hot map (the Swift `RelevantMemory.hotMap` equivalent; Go reads `map.md`).
8. Project block (§6): instructions, pinned sources, text project files (cap 120k chars total, larger files listed by name only).
9. A short current app guide (Go const, reviewed against the sidebar).

The DB schema is **dropped** from the prompt (the chat has no SQL tool). `internal/ai/prompt.go` (used by `ask`/`repl`) reuses blocks 2–3 from `internal/chat` so there is one copy.

### 4.2 Budget
Prompt target ≤ 40k chars without project files. A test asserts the builder output for a fixture DB stays under the budget.

### 4.3 Turn text
Swift appends to the user's text only structured references (mentions, `/skill`) and the existing "ACTIONS SINCE YOUR LAST MESSAGE" block.

### 4.4 Titles
New prompt `chat.title` (light tier, `CostLight`, both providers). `watchtower chat title <conversation-id>` reads the first exchange, generates ≤60 chars, writes only if `title_source != 'user'`, sets `title_source='ai'`. Swift calls it fire-and-forget after the first completed turn.

---

## 5. Errors

| code | when | retryable | UI |
|---|---|---|---|
| `auth` | provider CLI not logged in | no | card with "Open Terminal: claude login" hint |
| `rate_limit` | provider rate limit | yes | card + Retry |
| `provider_unavailable` | binary missing / exited non-zero at start | yes | card + Retry |
| `session_lost` | `--resume` rejected | — | session silently retries once with replay; error only if that fails |
| `attachment_unsupported` | binary file on non-Claude provider, oversize, bad type | no | card naming the file |
| `interrupted` | user Stop | — | "Stopped" + Continue |
| `internal` | anything else | yes | card + Retry |

A failed tool is a red step, not a turn error. The user message is persisted **before** the turn is sent; partial assistant text is persisted on stop/crash (`status='partial'`).

---

## 6. Projects, mentions, skills

### 6.1 Projects
Sidebar "Projects" section; project page: name, instructions editor (debounced save), files (§7.1 with `project_id`), pinned sources (Jira project, Slack channel, target, track, person — picked from DB), and its chats. "New chat" inside a project sets `project_id`; the session prompt includes the project block (§4.1.8). Binary project files (images/PDFs) attach to the first turn of each provider session in that project (Claude only). Deleting a project keeps its chats (`ON DELETE SET NULL`) and deletes its files.

### 6.2 @-mentions
Typing `@` opens a picker over people, Slack channels, Jira issues, targets, tracks (local DB, prefix match, 8 results). A mention renders as a chip in the composer and is sent as `@Label` in the text plus a trailing block `REFERENCED: person:<id> "Label"; jira:PROJ-1; …` so the model can call the right `get_*` tool.

### 6.3 `/` skills
Typing `/` lists enabled skills; choosing one prefixes the turn with `Use skill <name>: load it with load_skill first.` The main chat is added to `SkillsCatalog.chatContextTypes` (as `main`).

---

## 7. Files & artifacts

### 7.1 Attachments
- Sources: paperclip, drag & drop, paste (images).
- Stored under `Config.WorkspaceDir()/chat_files/<conversation|project>/<uuid>.<ext>` (0600), row in `chat_attachments`, sha256 dedupe within a conversation.
- Supported: images png/jpeg/gif/webp ≤ 5 MB → `image` block; PDF ≤ 32 MB → `document` block; text-like (txt, md, csv, tsv, json, yaml, log, source code) ≤ 256 KB → inlined as a text block with a filename header. Others rejected in the composer with a reason.
- Paths travel in the `turn` command (stdin), never argv; Go reads files and builds content blocks.
- Deleting a conversation/project deletes its files post-commit (best effort).

### 7.2 Artifacts
The model emits:
```
:::artifact key="q3-plan" kind="document" title="Q3 plan"
…markdown / csv / text…
:::
```
Kinds: `document` (markdown), `table` (csv), `email` (meta: to, cc, subject; body = content), `slack` (meta: channel ref / permalink; body), `event` (meta: title, start, end, attendees, location; body = description), `code` (meta: language).
- Swift parses artifacts from assistant text (streaming-aware: an open block renders as a card "Writing *Q3 plan*…" and live-updates the panel), stores a version per (conversation, key), replaces the block in the message with a card.
- **Artifact panel** (right side, resizable): latest version, version switcher, inline edit (edit = new version with `edited=1`), Copy, Export (.md / .csv / .txt), and kind actions that **open ready, never send**: `email` → Gmail compose URL (to/cc/subject/body; falls back to `mailto:`); `slack` → copies body to clipboard and opens the thread/channel deep link; `event` → Google Calendar template URL.
- Asking to modify an artifact: the model re-emits the same `key` → new version.
- The prompt contract (§4.1.5) tells the model when to use artifacts (anything the owner will copy, send, or keep: > ~15 lines, drafts, tables) and to keep chat text short around them.

---

## 8. Actions

New registry write tools (all through Propose/Apply; AGENT-01..06 unchanged):
| tool | surfaces | External | notes |
|---|---|---|---|
| `add_jira_comment` | main, target | yes | key, body (plain text → ADF paragraph) |
| `transition_jira_issue` | main, target | yes | key, target status name; Validate resolves the transition via GET transitions |
| `assign_jira_issue` | main, target | yes | key, assignee (email / display name / "me") → accountId via `jira_user_map` / owner identity / user search |
| `update_jira_issue` | main, target | yes | key, any of summary, priority, labels (add/remove), due date |

Existing tools widened to `main`: `create_idea`, `create_track`, `remind_me` (`remind_me` gains optional `message_ref`; on non-reaction surfaces the binding's ContextID is not used as a message ref). The surface pin test is updated; the reaction surface is unchanged (REACT-02).

`AgentActionCardView` result rendering becomes generic: any `url` (+ optional `label`) in `result_json` renders as a link, plus the existing special keys.

Jira client gains `AddComment`, `GetTransitions`, `TransitionIssue`, `AssignIssue`, `UpdateIssue` (over the generic `do`), and a local mirror refresh of the issue after apply (the `mirrorCreatedIssue` precedent).

---

## 9. Contracts (new inventory file `docs/inventory/chat.md`)

- **CHAT-01 owner text is never lost:** the user message is persisted before the turn is sent; partial assistant text survives stop, crash and app quit.
- **CHAT-02 no silent tool activity:** every tool call in a turn is persisted and visible as a step; text already shown is never wiped.
- **CHAT-03 bounded warm sessions:** at most 3 live session processes; all are terminated on app quit; an idle session dies within TTL + one poll.
- **CHAT-04 content stays off argv:** system prompt, user text and attachment paths never appear on any process's argv.
- **CHAT-05 artifacts never send:** artifact actions only open or copy; no external write happens outside the registry's Approve path.

Guard tests named `TestChat0N_…` (Go) / `testChat0N…` (Swift).

## 10. Testing

**Go:** Claude→v2 translator on recorded fixtures (text, tool_use/tool_result, interrupt, error, thinking) — fixtures recorded from real `claude` runs; session command end-to-end against a fake `claude` script (multi-turn, cancel, crash→resume, session_lost→replay); replay builder (cap, branch path); migration adoption on three legacy shapes (no tables, tables without `turn_id`/context columns, current shape) + backfill of `parent_id`; FTS triggers; prompt builder golden + budget; `chat title` with a stub generator; Jira tools with `httptest`; registry surface pin; `--turn-file`; sources extraction per read tool.

**Swift (WatchtowerCore where possible):** v2 event parser; `ChatSessionPolicy.decide` (TTL, LRU, prewarm, busy) and pool with a fake process factory (start → navigate away → return); branch tree ops (regenerate, edit, switch, active path); markdown renderer AST mapping (tables, nested lists, fences, unterminated fence); highlighter tokens; artifact parser (streaming partial blocks, versions, kinds, URL builders); mention/skill tokenizers; attachment validation; history grouping; FTS search query.

Gate: `make test`, `make test-swift`, `make lint-all`.

## 11. Delivery

One branch, one PR. Internally ordered: (1) core — migration, session command, translator, prompt, pool, renderer, UI; (2) actions; (3) files & artifacts; (4) projects, mentions, skills. `docs/app-guide.md` updated, CLAUDE.md feature note added.
