# Chat Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the main AI Chat into a Claude-Desktop-class assistant — warm streaming sessions with visible tool steps and sources, real history with branches, attachments and artifacts, projects, and Jira/local actions — shipped as one PR.

**Architecture:** A new long-lived Go command `watchtower ai session` owns the provider process per conversation (Claude: one `claude -p --input-format stream-json` child for the conversation's life) and emits protocol-v2 NDJSON events; the system prompt moves to Go (`internal/chat`). Swift gets a `ChatSessionPool` on `AppState`, a rewritten `ChatViewModel`, a swift-markdown renderer shared by every chat, and new UI (left history, steps, source chips, artifact panel, projects). Chat tables are adopted into goose (migration 00074).

**Tech Stack:** Go 1.25, cobra, modernc SQLite + goose, `claude` CLI 2.1.x stream-json; SwiftUI macOS 14+, GRDB 7, apple/swift-markdown.

**Spec:** `docs/superpowers/specs/2026-09-26-chat-redesign-design.md` — read it before any task.

## Phase files

Detailed task steps live in per-phase files (same format, same numbering):
- `docs/superpowers/plans/2026-09-26-chat-redesign/phase1-core-go.md` — Tasks 1–9
- `docs/superpowers/plans/2026-09-26-chat-redesign/phase1-core-swift.md` — Tasks 10–16
- `docs/superpowers/plans/2026-09-26-chat-redesign/phase2-actions.md` — Tasks 17–19
- `docs/superpowers/plans/2026-09-26-chat-redesign/phase3-files-artifacts.md` — Tasks 20–23
- `docs/superpowers/plans/2026-09-26-chat-redesign/phase4-projects-docs.md` — Tasks 24–27

## Global Constraints

- Everything in the repo (code, comments, docs, commits) in English.
- Go inner loop: `go test ./internal/<pkg>` (no `-count=1`); Swift inner loop: `make test-swift FILTER=<TestClass>`; never delete `WatchtowerDesktop/.build`.
- Protocol v2 event names exactly: `session_ready`, `turn_start`, `text_delta`, `tool_start`, `tool_end`, `usage`, `turn_done`, `error`. Commands: `turn`, `cancel`, `close`. No `reset` in v2.
- Error codes exactly: `auth`, `rate_limit`, `provider_unavailable`, `session_lost`, `attachment_unsupported`, `interrupted`, `internal`.
- Pool limits: max 3 live sessions, idle TTL 10 min, poll 30 s; `cancel` → Claude `interrupt` control request, kill after 5 s without `result`; quit: `close` then SIGTERM after 2 s.
- Replay cap 24,000 chars; project text files cap 120,000 chars; prompt budget ≤ 40,000 chars without project files.
- Attachments: images png/jpeg/gif/webp ≤ 5 MB; PDF ≤ 32 MB; text-like ≤ 256 KB; stored under `Config.WorkspaceDir()/chat_files/…` mode 0600.
- System prompt, user text and attachment paths never on argv (CHAT-04); system prompt via `--system-prompt-file` (0600 temp).
- Artifact fence: `:::artifact key="…" kind="…" title="…" [meta attrs]` … `:::`; kinds `document|table|email|slack|event|code`. Artifact actions only open/copy (CHAT-05).
- New External Jira tools: `add_jira_comment`, `transition_jira_issue`, `assign_jira_issue`, `update_jira_issue` on surfaces `main`,`target`. `create_idea`, `create_track`, `remind_me` gain surface `main`.
- Migration number 00074; mirror new tables in `internal/db/schema.sql`, `TestAllTablesExist`, schema golden (`go test ./internal/db/ -run TestSchemaGolden -update`), and Swift `TestDatabase.swift`.
- Guard tests: Go `TestChat0N_…`, Swift `testChat0N…` for CHAT-01..05.
- No model names hardcoded in Swift. No TCC-prompting APIs.
- New prompt `chat.title` via the `add-ai-prompt` skill flow (light tier, both providers, tier-scan tag).

## Review Focus

1. **Existing installs:** a DB whose chat tables were created by old Swift code (with and without `turn_id`/context columns, with existing conversations) must migrate, and old conversations must open, render, and continue (Claude `--resume` session id reused). → Task 1 (three legacy shapes + parent_id backfill), Task 14 (continue a legacy conversation).
2. **Quit / crash mid-turn:** partial assistant text is persisted, no orphan `claude`/`watchtower mcp` processes survive app quit or pool eviction. → Task 7 (child reaped on close/stdin EOF/parent death), Task 11 (pool quit test), Task 14 (partial persisted).
3. **Navigating away while streaming:** leaving the chat or switching conversation keeps the turn running and persisting; returning shows the live state. → Task 11/14 ("start → leave → return" test).
4. **Artifact fence inside a code block / unterminated fence / Cyrillic titles:** a `:::artifact` literal inside a fenced code block is not an artifact; an unterminated artifact at turn end is kept as a document version; attribute values with Cyrillic and escaped quotes parse. → Task 22.
5. **Huge tool results & long threads:** a 200 KB tool result yields a ≤300-char summary and bounded sources; a 500-message conversation opens without re-rendering all markdown on each delta (only the streaming message re-renders). → Task 2/3 (summary cap), Task 15 (render isolation).

---

## File map

Go (new):
- `internal/db/chat_migrate.go` — `normalizeLegacyChatTables`.
- `internal/db/migrations/00074_chat_core.sql`.
- `internal/db/chat.go` (extend) — `ChatMessage`, `ActiveChatPath`, `GetChatConversation`, `SetChatTitle`, `ListChatProjectContext`.
- `internal/chat/events.go` — v2 `Event`, `Command`, `Source`, writer.
- `internal/chat/claude_translate.go` — Claude stream-json → v2.
- `internal/chat/sources.go` — per-tool source extraction + summary.
- `internal/chat/replay.go` — replay transcript.
- `internal/chat/prompt.go`, `internal/chat/prompt_blocks.go`, `internal/chat/skills.go`, `internal/chat/memory.go`, `internal/chat/actions_contract.go`, `internal/chat/artifacts_contract.go`.
- `internal/chat/session.go` (loop), `internal/chat/claude_backend.go`, `internal/chat/turn_backend.go` (codex/ollama), `internal/chat/attachments.go`.
- `cmd/ai_session.go`, `cmd/chat.go` (`chat title`).
- `internal/jira/write.go` — comment/transition/assign/update.
- `internal/tools/jira_write.go` — four new tools.

Swift (new, WatchtowerCore unless noted):
- `Models/ChatModels.swift` (extend ChatMessage/ChatConversation, new ChatTurnStep, ChatAttachment, ChatArtifact, ChatProject, ChatProjectSource).
- `Database/Queries/ChatTreeQueries.swift`, `ChatStepQueries.swift`, `ChatSearchQueries.swift`, `ChatArtifactQueries.swift`, `ChatAttachmentQueries.swift`, `ChatProjectQueries.swift`.
- `Services/Chat/ChatEvent.swift` (v2 parser), `ChatSessionPolicy.swift`, `ChatHistoryGrouping.swift`, `ChatToolCatalog.swift`, `ArtifactParser.swift`, `ArtifactActions.swift`, `MentionTokenizer.swift`, `CodeHighlighter.swift`, `MarkdownDocument.swift` (swift-markdown → render model).
- App target: `Services/Chat/ChatSessionClient.swift`, `ChatSessionPool.swift`; `Views/Chat/*` rewritten/new (`MarkdownView.swift`, `StepsBlockView.swift`, `SourceChipsView.swift`, `ArtifactPanelView.swift`, `ArtifactCardView.swift`, `ChatSearchView.swift`, `ChatSidebarView.swift`, `ProjectDetailView.swift`, `MentionPicker.swift`).

## Tasks & cross-task interfaces

(Exact signatures below are binding for every phase file.)

### Phase 1 — Core (Go)

**Task 1: Chat schema adoption + migration 00074.**
Produces: `func normalizeLegacyChatTables(db *sql.DB) error` (called in `(*DB).migrate()` before `goose.Up`); tables/columns per spec §2.1; `type ChatMessage struct{ ID, ConversationID int64; ParentID sql.NullInt64; Role, Text, TurnID, Status string; Provider, Model, ErrorCode string; CreatedAt float64 }`; `func (db *DB) ActiveChatPath(conversationID int64) ([]ChatMessage, error)` (root→`active_leaf_message_id`; falls back to linear id order when the leaf is NULL); `type ChatConversation struct{ ID int64; Title, TitleSource, SessionID, ContextType, ContextID, Provider, Model string; ProjectID sql.NullInt64 }`; `func (db *DB) GetChatConversation(id int64) (*ChatConversation, error)`; `func (db *DB) SetChatTitle(id int64, title, source string) (bool, error)` (no-op returning false when current `title_source='user'`); `type ChatProjectContext struct{ Name, Instructions string; Sources []ChatProjectSource; TextFiles []ChatProjectFile; BinaryFiles []ChatProjectFile }`; `func (db *DB) GetChatProjectContext(projectID int64) (*ChatProjectContext, error)`.

**Task 2: v2 events + Claude translator.**
Produces (package `chat`): `type Event struct{ Type string \`json:"type"\`; TurnID string \`json:"turn_id,omitempty"\`; Text string \`json:"text,omitempty"\`; ID string \`json:"id,omitempty"\`; Name string \`json:"name,omitempty"\`; Args json.RawMessage \`json:"args,omitempty"\`; OK *bool \`json:"ok,omitempty"\`; Summary string \`json:"summary,omitempty"\`; Sources []Source \`json:"sources,omitempty"\`; TokensIn, TokensOut int \`json:"tokens_in/out,omitempty"\`; Model, Provider, SessionID, Status, Code, Message string; Retryable bool }`; `type Source struct{ Kind, Title, URL, Ref string }`; `type Command struct{ Type, TurnID, Text string; Attachments []Attachment; Replay bool }`; `type Attachment struct{ Path, Mime, Name string }`; `type EventWriter struct` with `func NewEventWriter(w io.Writer) *EventWriter` and `func (w *EventWriter) Emit(e Event) error` (mutex, one line per event); `type ClaudeTranslator struct` with `func NewClaudeTranslator(turnID func() string) *ClaudeTranslator` and `func (t *ClaudeTranslator) Feed(line []byte) ([]Event, error)`; `func ClassifyClaudeError(msg string) (code string, retryable bool)`.

**Task 3: Source extraction + summaries.**
Produces: `func SummarizeToolResult(name string, result string) (summary string, sources []Source)` (summary ≤300 runes; sources ≤10, deduped by URL/Ref).

**Task 4: Replay builder.**
Produces: `func BuildReplay(path []db.ChatMessage, capChars int) string` (empty for empty path; `[N earlier messages omitted]` header when truncated; `const ReplayCapChars = 24000`).

**Task 5: Go system prompt.**
Produces: `type PromptOptions struct{ Surface string; ProjectID int64; ToolsAvailable bool; Provider string; SkillsDir, VaultDir string; MemoryChat bool; Now time.Time }`; `func BuildSystemPrompt(ctx context.Context, d *db.DB, cfg *config.Config, o PromptOptions) (string, error)`; `const PromptBudgetChars = 40000`; shared blocks `func LinkingRules(...) string` reused by `internal/ai/prompt.go`; `func ActionsContract(surface string) string`; `func ArtifactsContract() string` (Task 23 fills text; Task 5 creates the function returning the §7.2 contract).

**Task 6: MCP `--turn-file`.**
Produces: `watchtower mcp --chat --turn-file <path>`; `tools.Binding` gains `TurnIDFunc func() string` used by `Propose` when non-nil; mutual exclusion with `--turn`.

**Task 7: Session loop + Claude backend + `ai session` command.**
Consumes 1–6. Produces: `type Backend interface{ Start(ctx context.Context) (sessionID string, err error); Turn(ctx context.Context, cmd Command, emit func(Event)) error; Cancel() error; Close() error }`; `type Session struct` with `func NewSession(b Backend, w *EventWriter) *Session` and `func (s *Session) Run(ctx context.Context, in io.Reader) error`; `func NewClaudeBackend(opts ClaudeOptions) Backend`; `watchtower ai session --conversation N [--provider] [--model] [--surface] [--project-id] [--resume] [--db-path]`. Attachments: Claude backend calls `BuildContentBlocks(atts []Attachment) ([]json.RawMessage, error)` (Task 20; Task 7 ships a stub that returns `attachment_unsupported` for any attachment).

**Task 8: Codex/Ollama turn backend + `ai query --events v2`.**
Produces: `func NewTurnBackend(q Querier, d *db.DB, conversationID int64) Backend` where `type Querier interface{ Query(ctx, systemPrompt, userMessage, sessionID string) (<-chan ai.StreamChunk, <-chan error, <-chan string) }`; `ai query --events v2`.

**Task 9: `chat.title` prompt + `watchtower chat title <id>`.**
Produces: prompt id `prompts.ChatTitle = "chat.title"`; command prints `{"title":…,"written":bool}`.

### Phase 1 — Core (Swift)

**Task 10: Swift DB layer.** Removes Swift `ensureTable`/`ensure*Column`; models per Task 1; `ChatTreeQueries`: `activePath(db, conversationID) -> [ChatMessage]`, `siblings(db, messageID) -> [ChatMessage]`, `insertUser(db, conversationID, parentID, text, turnID) -> ChatMessage`, `insertAssistant(db, conversationID, parentID, turnID, provider, model) -> ChatMessage`, `updateAssistant(db, id, text, status, tokensIn, tokensOut, errorCode)`, `setActiveLeaf(db, conversationID, messageID)`, `selectSibling(db, conversationID, siblingID)` (moves leaf to newest leaf under sibling); `ChatStepQueries`: `upsertStart(db, messageID, seq, toolID, name, argsJSON, startedAt)`, `finish(db, messageID, toolID, ok, summary, sourcesJSON, endedAt)`, `fetch(db, messageIDs) -> [Int64: [ChatTurnStep]]`; `ChatSearchQueries.search(db, query, limit) -> [ChatSearchHit]`; `ChatConversationQueries` + `rename/pin/archive/setProject`; `ChatHistoryGrouping.group(conversations, now, calendar) -> [ChatHistorySection]`.

**Task 11: Event parser, session client, policy, pool.** `ChatEvent` enum decoding v2 lines; `ChatSessionPolicy.decide(sessions:[SessionSnapshot], now:Date, wanted:Int64?) -> [PoolAction]` (`.evict(id)`, `.spawn(id)`); `ChatSessionClient` (protocol `ChatSessionProcess` seam: `send(_ cmd: ChatCommand)`, `events: AsyncStream<ChatEvent>`, `terminate()`); `ChatSessionPool` (`@MainActor @Observable`, on `AppState`): `session(for conversationID:, config:) -> ChatSessionClient`, `prewarm(conversationID:, config:)`, `close(conversationID:)`, `closeAll() async`.

**Task 12: Markdown renderer.** Adds `apple/swift-markdown`; `MarkdownDocument.parse(_ text: String) -> [MarkdownBlock]` (Core, testable); `CodeHighlighter.tokens(_ code:, language:) -> [CodeToken]`; `MarkdownView(text:)` replaces every `MarkdownText` use.

**Task 13: Tool catalog, steps, sources views.** `ChatToolCatalog.label(name:args:) -> String`, `.icon(name:) -> String`; `StepsBlockView`, `SourceChipsView`.

**Task 14: ChatViewModel rewrite.** API: `send(text:attachments:mentions:)`, `stop()`, `retry(messageID:)`, `continueStopped(messageID:)`, `regenerate(messageID:)`, `edit(messageID:newText:)`, `selectVariant(messageID:)`, `select(conversationID:)`, `newConversation(projectID:)`; persists user message before sending (CHAT-01); consumes pool events; fires `watchtower chat title` after first completed turn.

**Task 15: Chat UI.** Left sidebar with groups + projects header, ⌘K search, thread column, message hover actions, error/stopped cards, composer (grow, Esc, ↑, model pill), empty state, Welcome chat removed.

**Task 16: App wiring.** `AppState.chatSessionPool`; `QuitCoordinator` closes pool; provider/model change closes session.

### Phase 2 — Actions

**Task 17: Jira write client.** `func (c *Client) AddComment(ctx, key, body string) (commentID string, err error)`, `GetTransitions(ctx, key) ([]Transition, error)`, `TransitionIssue(ctx, key, transitionID string) error`, `AssignIssue(ctx, key, accountID string) error`, `UpdateIssue(ctx, key string, f IssueUpdate) error` with `type IssueUpdate struct{ Summary *string; Priority *string; LabelsAdd, LabelsRemove []string; DueDate *string }`.

**Task 18: Jira write tools.** Four tools per spec §8 in `internal/tools/jira_write.go`, registered in `buildToolRegistry`; pin test updated; result JSON always `{key, url, label}`.

**Task 19: Widen local tools + contracts + generic card.** `create_idea`/`create_track`/`remind_me` surfaces += `main`; `remind_me` `message_ref` arg; Go `ActionsContract("main")` lists all main tools; Swift `AgentToolsContract` (target chat) updated for new Jira tools; `AgentActionCardView` renders generic `url`/`label`; `ChatToolCatalog` labels for new tools.

### Phase 3 — Files & artifacts

**Task 20: Go attachments.** `func BuildContentBlocks(atts []Attachment) ([]json.RawMessage, error)` (limits per constraints; error type `*AttachmentError{Name, Reason}` → `attachment_unsupported`); Claude backend integration; turn backend: text-like inlined, binaries rejected.

**Task 21: Swift attachments.** `ChatAttachmentStore.importFile(url:, conversationID:|projectID:) throws -> ChatAttachment`, validation `AttachmentValidator.validate(url:) -> Result<AttachmentKind, AttachmentRejection>`; composer paperclip/drag/paste; deletion on conversation delete.

**Task 22: Artifact parser & store.** `ArtifactParser.parse(_ text: String, final: Bool) -> ParsedMessage` where `ParsedMessage{ segments: [Segment] }` and `Segment = .markdown(String) | .artifact(ArtifactDraft)`; `ArtifactDraft{ key, kind, title, meta:[String:String], content, isComplete }`; `ChatArtifactQueries.saveVersion(db, conversationID, messageID, draft, edited) -> ChatArtifact`, `latest(db, conversationID, key)`, `versions(db, conversationID, key)`; `ArtifactActions.gmailComposeURL(meta:body:)`, `.calendarTemplateURL(meta:body:)`, `.slackTarget(meta:)`.

**Task 23: Artifact UI + prompt contract.** `ArtifactCardView`, `ArtifactPanelView` (versions, edit, copy, export, kind actions); Go `ArtifactsContract()` text.

### Phase 4 — Projects, mentions, skills, docs

**Task 24: Projects.** `ChatProjectQueries` CRUD + sources + files; sidebar Projects section; `ProjectDetailView`; new chat in project passes `--project-id`; binary project files attached on the first turn of a provider session.

**Task 25: @-mentions.** `MentionTokenizer.activeQuery(text:cursor:) -> String?`, `MentionSearch.search(db, query) -> [MentionCandidate]`, `MentionCandidate.referenceToken` (`person:<id>`, `channel:<id>`, `jira:<KEY>`, `target:<id>`, `track:<id>`); turn text gets `REFERENCED: …` suffix.

**Task 26: `/` skills.** Skill picker from `SkillsCatalog`; `chatContextTypes` gains `main`; prefix sentence per spec §6.3.

**Task 27: Contracts & docs.** `docs/inventory/chat.md` (CHAT-01..05) + README row; guard tests present and named; `docs/app-guide.md` chat section; CLAUDE.md feature note; spec status.

## Errata — resolved while writing the phase files (binding over the interface list above)

- Swift persisted message type keeps the name `ChatMessageRecord` (the name `ChatMessage` is the UI struct used by 8 chat VMs); it moves into WatchtowerCore (Task 10).
- Shared Go prompt blocks live in `internal/chat/blocks` (sub-package) — `internal/ai` importing `internal/chat` would cycle (Task 5).
- Conversation titles are indexed in their own FTS table `chat_title_fts` alongside `chat_fts` (Task 1).
- Migration 00074 does NOT backfill `active_leaf_message_id`; NULL leaf = linear path over all messages (every Discuss chat and legacy row). Memory readers filter branches through one shared recursive query (Task 1).
- Task 19 replaces Task 5's `actions_contract.go` text with fixture files shared by Go and Swift.
- `jira.Client.SearchUsers` is added in Task 17 (assignee resolution).
- `ChatSessionConfig` lives in `ChatSessionClient.swift`; `projectID` is added by Task 24. `ChatToolCatalog.label(name:args:)` takes the raw JSON args string.
- Project binary files are attached by Go on the first turn of a fresh provider session (Task 24 addendum to Task 7/20); a `--resume`d session does not re-attach.
- `create_idea` / `remind_me` keep their seeded `execute` trust → in the main chat they apply without an Approve card (owner notice in the PR).
- Phase files 3–4 were written before phase 1 code existed: every task there starts by grepping the actual names produced by earlier tasks; the code on the branch wins over plan text when they disagree.
