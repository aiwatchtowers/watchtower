# Chat Redesign — Phase 1: Core (Go) — Tasks 1–9

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the main AI Chat a Go-owned engine: goose-owned chat tables with branches and FTS, a long-lived `watchtower ai session` command that keeps one warm `claude` process per conversation and speaks protocol v2 (token streaming, visible tool steps with sources, interrupt), a Go system prompt, a turn file for the MCP server, a replay path for Codex/Ollama and lost sessions, and AI conversation titles.

**Architecture:** Migration 00074 adopts the Swift-created `chat_conversations`/`chat_messages` (after a Go pre-goose normalizer) and adds the new columns/tables. A new package `internal/chat` holds the v2 event types, the Claude stream-json → v2 translator, per-tool source extraction, the replay builder, the system-prompt builder, the session loop and two backends (Claude warm process; Codex/Ollama one call per turn). A leaf sub-package `internal/chat/blocks` holds prompt text shared with `internal/ai` (ask/repl), so there is one copy and no import cycle. `cmd/ai_session.go` wires config → prompt → backend → session; `cmd/chat.go` adds `chat title`.

**Tech Stack:** Go 1.25, cobra, modernc SQLite + goose (FTS5), testify, `claude` CLI 2.1.x `--input-format stream-json`.

**Spec:** `docs/superpowers/specs/2026-09-26-chat-redesign-design.md` (§1 transport, §2 data, §3.4 sources, §4 prompt, §5 errors, §9 contracts). The skeleton `docs/superpowers/plans/2026-09-26-chat-redesign.md` holds the binding cross-task interfaces — read both first.

## Global Constraints

- Everything in the repo (code, comments, docs, commits) in English.
- Go inner loop: `go test ./internal/<pkg>` (add `-run`), never `-count=1`. Lint: `make lint-diff`. Gate at the end of the phase: `make test`, `make lint-all`.
- Protocol v2 event names exactly: `session_ready`, `turn_start`, `text_delta`, `tool_start`, `tool_end`, `usage`, `turn_done`, `error`. Commands: `turn`, `cancel`, `close`. No `reset` in v2.
- Error codes exactly: `auth`, `rate_limit`, `provider_unavailable`, `session_lost`, `attachment_unsupported`, `interrupted`, `internal`.
- `cancel` → Claude `interrupt` control request; kill after 5 s without `result`. Close: stdin EOF, then SIGTERM after 2 s, then SIGKILL.
- Replay cap 24,000 chars; project text files cap 120,000 chars; prompt budget ≤ 40,000 chars without project files.
- System prompt, user text and attachment paths never on argv (CHAT-04); system prompt via `--system-prompt-file` (0600 temp).
- Migration number 00074; mirror new tables in `internal/db/schema.sql`, `TestAllTablesExist`, schema golden (`go test ./internal/db/ -run TestSchemaGolden -update`).
- Guard tests: `TestChat0N_…` for CHAT-01..05.
- New prompt `chat.title`: light tier, both providers, source-tagged (the `add-ai-prompt` skill flow).
- One commit per task; stage only the files the task lists (never `git add -A`); end every commit message with the line `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## Review Focus

1. **Existing installs:** a DB whose chat tables were created by old Swift code (with and without `turn_id`/context columns, with conversations) migrates, keeps every row, keeps `session_id`, and chains legacy rows linearly. → Task 1 (`TestMigration00074_AdoptsLegacyChatTables`, three shapes; `TestMigration00074_DownUpKeepsMessages`).
2. **No orphan processes:** closing a session, stdin EOF (the app died) and a cancelled context all leave no `claude` and no grandchild (`watchtower mcp`) alive, even when the child ignores SIGTERM. → Task 7 (`TestClaudeBackend_CloseReapsStubbornChild`, `TestClaudeBackend_StdinEOFEndsSessionAndSweepsGroup`, `TestClaudeBackend_ContextCancelEndsSession`).
3. **Huge tool results:** a 200 KB tool result yields a ≤300-rune summary and ≤10 sources, and the stdout reader does not choke on a multi-megabyte line. → Task 3 (`TestSummarizeToolResult_HugeResultIsBounded`), Task 7 (64 MiB scanner buffer).
4. **Memory never reads an abandoned branch:** after an edit/regenerate, `ListOwnerChatTurns` and `ListRecentChatTurns` see only the active path; Discuss conversations (no active leaf) keep today's linear behavior. → Task 1 (`TestListOwnerChatTurns_ActiveBranchOnly`, `TestListRecentChatTurns_ActiveBranchOnly`).
5. **Lost Claude session:** a rejected `--resume` retries once, silently, as a fresh session with the replayed history — the owner sees an answer, not an error. → Task 7 (`TestClaudeBackend_SessionLostRetriesWithReplay`).

## Decisions this file makes (spec ambiguities resolved)

- **Active branch for memory readers:** `ListOwnerChatTurns` and `ListRecentChatTurns` filter through one shared recursive-CTE fragment (`activeBranchCTE` + `onActiveBranch` in `internal/db/chat.go`), not by calling `ActiveChatPath` per conversation. A conversation with a NULL (or dangling) `active_leaf_message_id` keeps every message — the shape of every Discuss chat and every legacy row. Consequence (documented in code): the memory ingest floor is id-based, so an owner turn that sat on an inactive branch when the ingest ran is not ingested later if the owner switches back. Accepted.
- **No `active_leaf_message_id` backfill:** the migration backfills `parent_id` (linear chain) only. Backfilling the leaf would freeze Discuss conversations (still written by old Swift code without `parent_id`) at their pre-migration last message. NULL leaf = linear fallback everywhere.
- **Title FTS:** a second external-content FTS5 table `chat_title_fts(title)` over `chat_conversations`, with triggers; `chat_fts(text)` covers messages. Tokenizer `porter unicode61 remove_diacritics 2` (the `kb_fts` precedent). Update triggers fire only on `text`/`title` changes, so status/token writes never churn the index.
- **Shared prompt blocks live in `internal/chat/blocks`**, not `internal/chat/prompt_blocks.go`: `internal/chat` imports `internal/ai` (`StreamChunk`, MCP-config helpers), so `internal/ai/prompt.go` cannot import `internal/chat`. `blocks.LinkingRules(teams []blocks.SlackTeam, fallbackTeamID string) string` is the binding `LinkingRules(...)`.
- **Terminal events:** every turn ends with exactly one of `turn_done` or `error{turn_id}`; `Session` enforces it. A failed provider start emits `error` without `turn_id` and the command exits non-zero.
- **`session_ready`** is emitted once the provider process is spawned (Claude prints nothing before the first user message); its `session_id` is the resume id or empty. The live id arrives on `turn_done.session_id`.
- **Options outside the binding signatures:** `Session` has exported fields `Provider`, `Model`, `TurnFile`; `NewTurnBackend` takes variadic `...TurnOption` (`WithSystemPrompt`). The binding call shapes stay valid.
- **Replay with steps:** `BuildReplay(path, cap)` (binding) delegates to `BuildReplaySteps(path, steps, cap)`; step one-liners come from `db.ChatStepSummaries`. `HistoryBefore(path, turnID)` drops the current turn's already-persisted rows (CHAT-01 persists the user message before the turn is sent).
- **Codex/Ollama tool steps:** Ollama's runtime-B loop emits `ai.StreamChunk{Tool: …}` only after `EmitToolEvents()` is called (the session turns it on); the chunk stream every other consumer sees is unchanged. Codex exposes no tool events in v1.
- **Task 5 does not create the actions-contract fixture files** — Task 19 (phase 2) creates `internal/chat/testdata/actions_contract_{main,target}.txt` and pins both sides. Task 5 ports today's Swift text into `internal/chat/actions_contract.go` (that file holds only `ActionsContract`) and asserts key lines; any other surface returns `""`.
- **`session_lost` detection:** a child spawned with `--resume` that exits (or reports an error result) before its first `result`, with a message `ClassifyClaudeError` maps to `session_lost`, is restarted once without `--resume`, and the turn is re-sent with the replay prefix. A second failure surfaces as `error{code: session_lost}`.

---

## Task 1: Chat schema adoption + migration 00074

**Files:**
- Create: `internal/db/chat_migrate.go`
- Create: `internal/db/migrations/00074_chat_core.sql`
- Create: `internal/db/chat_migration_test.go`
- Modify: `internal/db/db.go` (`migrate`, lines 109-111)
- Modify: `internal/db/chat.go` (new types + readers; active-branch filter in `ListRecentChatTurns`)
- Modify: `internal/db/memory.go` (`ChatTablesPresent` doc; `ListOwnerChatTurns` query, lines 838-868)
- Modify: `internal/db/chat_test.go`, `internal/db/memory_test.go` (drop `createChatTablesForTest`, update `TestChatTablesPresent`)
- Modify: every `internal/memory/*_test.go` calling `createChatTables`, and `internal/memory/chat_evidence_test.go` (its definition); `internal/targets/nextstep_test.go` (drop `createChatTablesForNextStepTest`)
- Modify: `internal/db/schema.sql`, `internal/db/db_test.go` (`TestAllTablesExist`), `internal/db/testdata/schema_v73.golden`

**Interfaces:**
- Consumes: nothing new.
- Produces (binding):
  - `func normalizeLegacyChatTables(db *sql.DB) error` — called first in `(*DB).migrate()`.
  - Tables/columns per spec §2.1, plus: `chat_fts(text)` and `chat_title_fts(title)` external-content FTS5 tables kept by triggers; `chat_turn_steps UNIQUE(message_id, tool_id)`, `ok` NULL while running; `chat_project_sources UNIQUE(project_id, kind, ref)`; `chat_artifacts.kind CHECK IN ('document','table','email','slack','event','code')`. All timestamps REAL unix seconds (the chat tables' convention).
  - `type ChatMessage struct{ ID, ConversationID int64; ParentID sql.NullInt64; Role, Text, TurnID, Status string; Provider, Model, ErrorCode string; CreatedAt float64 }`
  - `func (db *DB) ActiveChatPath(conversationID int64) ([]ChatMessage, error)` — root→leaf; linear id order when the leaf is NULL or dangling; `nil, nil` for an unknown conversation.
  - `type ChatConversation struct{ ID int64; Title, TitleSource, SessionID, ContextType, ContextID, Provider, Model string; ProjectID sql.NullInt64 }`; `func (db *DB) GetChatConversation(id int64) (*ChatConversation, error)` (`nil, nil` when absent).
  - `func (db *DB) SetChatTitle(id int64, title, source string) (bool, error)` — false and no write when the stored `title_source='user'`; error for a source outside `prefix|ai|user`.
  - `type ChatProjectSource struct{ Kind, Ref, Label string }`, `type ChatProjectFile struct{ ID int64; Name, Mime, Path string; Size int64 }`, `type ChatProjectContext struct{ Name, Instructions string; Sources []ChatProjectSource; TextFiles []ChatProjectFile; BinaryFiles []ChatProjectFile }`; `func (db *DB) GetChatProjectContext(projectID int64) (*ChatProjectContext, error)` (`nil, nil` when absent; binary = `image/*` or `application/pdf`).
  - `func (db *DB) ChatStepSummaries(messageIDs []int64) (map[int64][]string, error)` — per message, `"<name>: <summary>"` lines in `seq` order, `"<name> (failed): <summary>"` when `ok=0`.

- [ ] **Step 1: Write the failing migration tests**

Create `internal/db/chat_migration_test.go`:

```go
package db

import (
	"database/sql"
	"fmt"
	"path/filepath"
	"testing"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	_ "modernc.org/sqlite"
)

// The two chat table shapes the Desktop app has ever created (GRDB
// ensureTable + guarded ALTERs), verbatim, so adoption is tested against what
// real installs have on disk.
const (
	legacyChatConvNoContext = `CREATE TABLE chat_conversations (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		title TEXT NOT NULL DEFAULT '',
		session_id TEXT,
		created_at REAL NOT NULL,
		updated_at REAL NOT NULL)`
	legacyChatMsgNoTurn = `CREATE TABLE chat_messages (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		conversation_id INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
		role TEXT NOT NULL,
		text TEXT NOT NULL,
		created_at REAL NOT NULL)`
	legacyChatConvCurrent = `CREATE TABLE chat_conversations (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		title TEXT NOT NULL DEFAULT '',
		session_id TEXT,
		context_type TEXT,
		context_id TEXT,
		created_at REAL NOT NULL,
		updated_at REAL NOT NULL)`
	legacyChatMsgCurrent = `CREATE TABLE chat_messages (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		conversation_id INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
		role TEXT NOT NULL,
		text TEXT NOT NULL,
		created_at REAL NOT NULL,
		turn_id TEXT NOT NULL DEFAULT '')`
)

// rawDBAt opens a bare in-memory database migrated only up to version.
func rawDBAt(t *testing.T, version int64) *sql.DB {
	t.Helper()
	raw, err := sql.Open("sqlite", ":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { _ = raw.Close() })
	raw.SetMaxOpenConns(1)
	_, err = raw.Exec("PRAGMA foreign_keys=ON")
	require.NoError(t, err)
	require.NoError(t, goose.UpTo(raw, "migrations", version))
	return raw
}

func columnNames(t *testing.T, raw *sql.DB, table string) map[string]bool {
	t.Helper()
	rows, err := raw.Query(fmt.Sprintf("SELECT name FROM pragma_table_info('%s')", table))
	require.NoError(t, err)
	defer rows.Close()
	out := map[string]bool{}
	for rows.Next() {
		var name string
		require.NoError(t, rows.Scan(&name))
		out[name] = true
	}
	require.NoError(t, rows.Err())
	return out
}

func TestMigration00074_AdoptsLegacyChatTables(t *testing.T) {
	cases := []struct {
		name       string
		ddl        []string
		hasContext bool
	}{
		{"no chat tables (CLI-only install)", nil, false},
		{"oldest Swift shape: no context columns, no turn_id", []string{legacyChatConvNoContext, legacyChatMsgNoTurn}, false},
		{"current Swift shape", []string{
			legacyChatConvCurrent, legacyChatMsgCurrent,
			`CREATE INDEX idx_chat_messages_conversation ON chat_messages(conversation_id)`,
		}, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			raw := rawDBAt(t, 73)
			for _, s := range tc.ddl {
				_, err := raw.Exec(s)
				require.NoError(t, err)
			}
			var convID int64
			if tc.ddl != nil {
				res, err := raw.Exec(`INSERT INTO chat_conversations (title, session_id, created_at, updated_at)
					VALUES ('Legacy chat about payouts', 'sess-legacy', 1, 1)`)
				require.NoError(t, err)
				convID, err = res.LastInsertId()
				require.NoError(t, err)
				if tc.hasContext {
					_, err = raw.Exec(`UPDATE chat_conversations SET context_type = 'action_item', context_id = '7' WHERE id = ?`, convID)
					require.NoError(t, err)
				}
				for i, m := range []struct{ role, text string }{
					{"user", "first question"}, {"assistant", "first answer"}, {"user", "another question"},
				} {
					_, err := raw.Exec(`INSERT INTO chat_messages (conversation_id, role, text, created_at) VALUES (?, ?, ?, ?)`,
						convID, m.role, m.text, float64(10+i))
					require.NoError(t, err)
				}
			}

			d := &DB{DB: raw}
			require.NoError(t, d.migrate())

			conv := columnNames(t, raw, "chat_conversations")
			for _, c := range []string{"context_type", "context_id", "pinned", "archived_at", "title_source",
				"provider", "model", "project_id", "active_leaf_message_id"} {
				assert.True(t, conv[c], "chat_conversations.%s", c)
			}
			msg := columnNames(t, raw, "chat_messages")
			for _, c := range []string{"turn_id", "status", "provider", "model", "tokens_in", "tokens_out",
				"parent_id", "error_code"} {
				assert.True(t, msg[c], "chat_messages.%s", c)
			}
			for _, tbl := range []string{"chat_turn_steps", "chat_attachments", "chat_artifacts", "chat_projects",
				"chat_project_sources", "chat_fts", "chat_title_fts"} {
				var n int
				require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE name = ?`, tbl).Scan(&n))
				assert.Equal(t, 1, n, "table %s", tbl)
			}
			if tc.ddl == nil {
				return
			}

			path, err := d.ActiveChatPath(convID)
			require.NoError(t, err)
			require.Len(t, path, 3)
			assert.False(t, path[0].ParentID.Valid, "the first message stays a root")
			assert.Equal(t, path[0].ID, path[1].ParentID.Int64, "legacy rows are backfilled into a linear chain")
			assert.Equal(t, path[1].ID, path[2].ParentID.Int64)
			assert.Equal(t, "complete", path[2].Status)

			c, err := d.GetChatConversation(convID)
			require.NoError(t, err)
			require.NotNil(t, c)
			assert.Equal(t, "sess-legacy", c.SessionID, "the Claude session id survives so --resume keeps working")
			assert.Equal(t, "prefix", c.TitleSource)
			if tc.hasContext {
				assert.Equal(t, "track", c.ContextType, "the action_item → track data fix moved into the migration")
			}

			var hits int
			require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM chat_fts WHERE chat_fts MATCH 'question'`).Scan(&hits))
			assert.Equal(t, 2, hits, "legacy messages are indexed by the migration")
			require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM chat_title_fts WHERE chat_title_fts MATCH 'payouts'`).Scan(&hits))
			assert.Equal(t, 1, hits, "legacy titles are indexed by the migration")
		})
	}
}

// TestMigration00074_DownUpKeepsMessages: goose.Down/DownTo in other tests
// roll back through 00074, so its Down must be real and must never drop the
// adopted rows (the app created them, not this migration).
func TestMigration00074_DownUpKeepsMessages(t *testing.T) {
	d, err := Open(filepath.Join(t.TempDir(), "chat-cycle.db"))
	require.NoError(t, err)
	defer d.Close()

	conv := insertChatConversation(t, d, "", "")
	root := insertBranchMessage(t, d, conv, 0, "user", "keep me", "t1")
	insertBranchMessage(t, d, conv, root, "assistant", "and me", "t1")

	require.NoError(t, goose.Down(d.DB, "migrations"))
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM chat_messages`).Scan(&n))
	assert.Equal(t, 2, n, "Down keeps the adopted tables and their rows")
	assert.False(t, columnNames(t, d.DB, "chat_messages")["parent_id"], "Down removes the 00074 columns")
	assert.True(t, columnNames(t, d.DB, "chat_messages")["turn_id"], "Down keeps the adopted shape")

	require.NoError(t, goose.Up(d.DB, "migrations"))
	path, err := d.ActiveChatPath(conv)
	require.NoError(t, err)
	require.Len(t, path, 2)
	assert.Equal(t, path[0].ID, path[1].ParentID.Int64, "re-Up re-chains the rows")
}

// TestChatFTS_TriggersFollowWrites: Swift writes need no indexing code — the
// triggers keep both FTS tables in step with inserts, text updates and deletes.
func TestChatFTS_TriggersFollowWrites(t *testing.T) {
	d := openTestDB(t)
	conv := insertChatConversation(t, d, "", "")
	id := insertChatMessage(t, d, conv, "user", "the payments rollout slipped", 1)

	count := func(table, q string) int {
		t.Helper()
		var n int
		require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM `+table+` WHERE `+table+` MATCH ?`, q).Scan(&n))
		return n
	}
	assert.Equal(t, 1, count("chat_fts", "rollout"))

	_, err := d.Exec(`UPDATE chat_messages SET text = 'the refunds launch slipped' WHERE id = ?`, id)
	require.NoError(t, err)
	assert.Equal(t, 0, count("chat_fts", "rollout"), "an edited message drops its old terms")
	assert.Equal(t, 1, count("chat_fts", "refunds"))

	_, err = d.Exec(`DELETE FROM chat_messages WHERE id = ?`, id)
	require.NoError(t, err)
	assert.Equal(t, 0, count("chat_fts", "refunds"))

	_, err = d.Exec(`UPDATE chat_conversations SET title = 'Quarterly planning' WHERE id = ?`, conv)
	require.NoError(t, err)
	assert.Equal(t, 1, count("chat_title_fts", "quarterly"))
	_, err = d.Exec(`DELETE FROM chat_conversations WHERE id = ?`, conv)
	require.NoError(t, err)
	assert.Equal(t, 0, count("chat_title_fts", "quarterly"))
}
```

Append to `internal/db/chat_test.go` (add `"github.com/stretchr/testify/assert"` and `"github.com/stretchr/testify/require"` to its imports; `insertChatConversation`/`insertChatMessage` already exist in `memory_test.go`, same package):

```go
// insertBranchMessage inserts one chat message under parent (0 = a root) with
// a turn id — the redesigned chat's write shape.
func insertBranchMessage(t *testing.T, d *DB, conv, parent int64, role, text, turnID string) int64 {
	t.Helper()
	var p any
	if parent != 0 {
		p = parent
	}
	res, err := d.Exec(`INSERT INTO chat_messages (conversation_id, parent_id, role, text, turn_id, created_at)
		VALUES (?, ?, ?, ?, ?, ?)`, conv, p, role, text, turnID, float64(time.Now().Unix()))
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func setActiveLeaf(t *testing.T, d *DB, conv, leaf int64) {
	t.Helper()
	_, err := d.Exec(`UPDATE chat_conversations SET active_leaf_message_id = ? WHERE id = ?`, leaf, conv)
	require.NoError(t, err)
}

func pathTexts(msgs []ChatMessage) []string {
	out := make([]string, len(msgs))
	for i, m := range msgs {
		out[i] = m.Text
	}
	return out
}

func TestActiveChatPath_FollowsActiveLeaf(t *testing.T) {
	d := openTestDB(t)
	conv := insertChatConversation(t, d, "", "")
	q := insertBranchMessage(t, d, conv, 0, "user", "question", "t1")
	insertBranchMessage(t, d, conv, q, "assistant", "answer v1", "t1")
	v2 := insertBranchMessage(t, d, conv, q, "assistant", "answer v2", "t1") // regenerate = sibling
	follow := insertBranchMessage(t, d, conv, v2, "user", "follow-up", "t2")

	path, err := d.ActiveChatPath(conv)
	require.NoError(t, err)
	assert.Equal(t, []string{"question", "answer v1", "answer v2", "follow-up"}, pathTexts(path),
		"a NULL leaf falls back to linear id order")

	setActiveLeaf(t, d, conv, follow)
	path, err = d.ActiveChatPath(conv)
	require.NoError(t, err)
	assert.Equal(t, []string{"question", "answer v2", "follow-up"}, pathTexts(path))
	assert.Equal(t, "t2", path[2].TurnID)

	setActiveLeaf(t, d, conv, 999999)
	path, err = d.ActiveChatPath(conv)
	require.NoError(t, err)
	assert.Len(t, path, 4, "a dangling leaf falls back to linear order instead of hiding the conversation")

	path, err = d.ActiveChatPath(424242)
	require.NoError(t, err)
	assert.Nil(t, path, "unknown conversation reads empty")
}

func TestGetChatConversationAndSetTitle(t *testing.T) {
	d := openTestDB(t)
	conv := insertChatConversation(t, d, "", "")

	c, err := d.GetChatConversation(conv)
	require.NoError(t, err)
	require.NotNil(t, c)
	assert.Equal(t, "prefix", c.TitleSource)
	assert.False(t, c.ProjectID.Valid)

	written, err := d.SetChatTitle(conv, "Payments rollout", "ai")
	require.NoError(t, err)
	assert.True(t, written)
	c, err = d.GetChatConversation(conv)
	require.NoError(t, err)
	assert.Equal(t, "Payments rollout", c.Title)
	assert.Equal(t, "ai", c.TitleSource)

	_, err = d.Exec(`UPDATE chat_conversations SET title = 'Mine', title_source = 'user' WHERE id = ?`, conv)
	require.NoError(t, err)
	written, err = d.SetChatTitle(conv, "AI would overwrite", "ai")
	require.NoError(t, err)
	assert.False(t, written, "an owner-set title is never overwritten")
	c, err = d.GetChatConversation(conv)
	require.NoError(t, err)
	assert.Equal(t, "Mine", c.Title)

	_, err = d.SetChatTitle(conv, "x", "robot")
	assert.Error(t, err)

	missing, err := d.GetChatConversation(999999)
	require.NoError(t, err)
	assert.Nil(t, missing)
}

func TestGetChatProjectContext(t *testing.T) {
	d := openTestDB(t)
	res, err := d.Exec(`INSERT INTO chat_projects (name, instructions, created_at, updated_at)
		VALUES ('Payments', 'Answer in bullets.', 1, 1)`)
	require.NoError(t, err)
	pid, err := res.LastInsertId()
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO chat_project_sources (project_id, kind, ref, label)
		VALUES (?, 'jira_project', 'PAY', 'Payments board')`, pid)
	require.NoError(t, err)
	for _, f := range []struct{ name, mime string }{
		{"notes.md", "text/markdown"}, {"arch.png", "image/png"}, {"spec.pdf", "application/pdf"},
	} {
		_, err = d.Exec(`INSERT INTO chat_attachments (project_id, name, mime, size, path, sha256, created_at)
			VALUES (?, ?, ?, 10, ?, ?, 1)`, pid, f.name, f.mime, "/tmp/"+f.name, "h-"+f.name)
		require.NoError(t, err)
	}

	pc, err := d.GetChatProjectContext(pid)
	require.NoError(t, err)
	require.NotNil(t, pc)
	assert.Equal(t, "Payments", pc.Name)
	assert.Equal(t, "Answer in bullets.", pc.Instructions)
	assert.Equal(t, []ChatProjectSource{{Kind: "jira_project", Ref: "PAY", Label: "Payments board"}}, pc.Sources)
	require.Len(t, pc.TextFiles, 1)
	assert.Equal(t, "notes.md", pc.TextFiles[0].Name)
	require.Len(t, pc.BinaryFiles, 2)

	none, err := d.GetChatProjectContext(999999)
	require.NoError(t, err)
	assert.Nil(t, none)
}

func TestChatStepSummaries(t *testing.T) {
	d := openTestDB(t)
	conv := insertChatConversation(t, d, "", "")
	msg := insertBranchMessage(t, d, conv, 0, "assistant", "answer", "t1")
	_, err := d.Exec(`INSERT INTO chat_turn_steps
		(message_id, seq, tool_id, name, args_json, ok, summary, sources_json, started_at, ended_at) VALUES
		(?, 2, 'b', 'get_jira_issue', '{}', 0, 'no such issue', '[]', 2, 3),
		(?, 1, 'a', 'search_knowledge', '{}', 1, '3 results', '[]', 1, 2)`, msg, msg)
	require.NoError(t, err)

	got, err := d.ChatStepSummaries([]int64{msg})
	require.NoError(t, err)
	assert.Equal(t, []string{"search_knowledge: 3 results", "get_jira_issue (failed): no such issue"}, got[msg])

	empty, err := d.ChatStepSummaries(nil)
	require.NoError(t, err)
	assert.Empty(t, empty)
}

// TestListRecentChatTurns_ActiveBranchOnly: the next-step prompt excerpt
// never quotes an abandoned branch (spec §2.2).
func TestListRecentChatTurns_ActiveBranchOnly(t *testing.T) {
	d := openTestDB(t)
	conv := insertChatConversation(t, d, "target", "42")
	old := insertBranchMessage(t, d, conv, 0, "user", "old wording", "t1")
	insertBranchMessage(t, d, conv, old, "assistant", "reply to old", "t1")
	edited := insertBranchMessage(t, d, conv, 0, "user", "edited wording", "t2")
	leaf := insertBranchMessage(t, d, conv, edited, "assistant", "reply to edit", "t2")
	setActiveLeaf(t, d, conv, leaf)

	turns, err := d.ListRecentChatTurns("target", "42", 10)
	require.NoError(t, err)
	var texts []string
	for _, tr := range turns {
		texts = append(texts, tr.Text)
	}
	assert.Equal(t, []string{"edited wording", "reply to edit"}, texts)
}

// TestListOwnerChatTurns_ActiveBranchOnly: memory's chat ingest reads only the
// active branch; a conversation without an active leaf (every Discuss chat,
// every legacy row) keeps its full linear history.
func TestListOwnerChatTurns_ActiveBranchOnly(t *testing.T) {
	d := openTestDB(t)
	conv := insertChatConversation(t, d, "situation", "42")
	old := insertBranchMessage(t, d, conv, 0, "user", "old wording", "t1")
	insertBranchMessage(t, d, conv, old, "assistant", "reply to old", "t1")
	edited := insertBranchMessage(t, d, conv, 0, "user", "edited wording", "t2")
	leaf := insertBranchMessage(t, d, conv, edited, "assistant", "reply to edit", "t2")
	setActiveLeaf(t, d, conv, leaf)

	linear := insertChatConversation(t, d, "situation", "43")
	insertChatMessage(t, d, linear, "user", "discuss turn", 5)

	turns, err := d.ListOwnerChatTurns(0, []string{"situation"})
	require.NoError(t, err)
	var texts []string
	for _, tr := range turns {
		texts = append(texts, tr.Text)
	}
	assert.Equal(t, []string{"edited wording", "discuss turn"}, texts)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `go test ./internal/db/ -run 'TestMigration00074|TestChatFTS|TestActiveChatPath|TestGetChatConversation|TestGetChatProjectContext|TestChatStepSummaries|ActiveBranchOnly'`
Expected: FAIL to compile — `d.ActiveChatPath undefined`, `undefined: ChatMessage`, etc.

- [ ] **Step 3: Add the pre-goose normalizer and call it from `migrate`**

Create `internal/db/chat_migrate.go`:

```go
package db

import (
	"database/sql"
	"fmt"
)

// normalizeLegacyChatTables brings chat tables the Desktop app created before
// migration 00074 up to the one shape 00074 expects, and runs BEFORE goose.
//
// The Swift side used to create chat_conversations/chat_messages lazily (GRDB
// ensureTable) and add context_type/context_id/turn_id with guarded ALTERs, so
// an install may hold the tables with or without those columns. A SQL
// migration cannot say "add the column if missing", hence this Go step.
// Idempotent: a no-op on a fresh install (no tables yet — 00074 creates them)
// and on every open after adoption (columns present).
func normalizeLegacyChatTables(db *sql.DB) error {
	adds := []struct{ table, column, ddl string }{
		{"chat_conversations", "context_type", "ALTER TABLE chat_conversations ADD COLUMN context_type TEXT"},
		{"chat_conversations", "context_id", "ALTER TABLE chat_conversations ADD COLUMN context_id TEXT"},
		{"chat_messages", "turn_id", "ALTER TABLE chat_messages ADD COLUMN turn_id TEXT NOT NULL DEFAULT ''"},
	}
	for _, a := range adds {
		cols, err := chatTableColumns(db, a.table)
		if err != nil {
			return err
		}
		if cols == nil || cols[a.column] {
			continue // table absent (00074 creates it) or column already there
		}
		if _, err := db.Exec(a.ddl); err != nil {
			return fmt.Errorf("adding %s.%s: %w", a.table, a.column, err)
		}
	}
	return nil
}

// chatTableColumns returns the column set of table, or nil when the table does
// not exist. table is always one of the constant names above, never input.
func chatTableColumns(db *sql.DB, table string) (map[string]bool, error) {
	rows, err := db.Query(fmt.Sprintf("SELECT name FROM pragma_table_info('%s')", table))
	if err != nil {
		return nil, fmt.Errorf("reading %s columns: %w", table, err)
	}
	defer rows.Close()
	var cols map[string]bool
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return nil, fmt.Errorf("scanning %s column: %w", table, err)
		}
		if cols == nil {
			cols = map[string]bool{}
		}
		cols[name] = true
	}
	return cols, rows.Err()
}
```

In `internal/db/db.go` replace `migrate`:

```go
func (db *DB) migrate() error {
	// Before goose: adopt Swift-created chat tables into the shape 00074
	// expects (see normalizeLegacyChatTables).
	if err := normalizeLegacyChatTables(db.DB); err != nil {
		return fmt.Errorf("normalizing legacy chat tables: %w", err)
	}
	return goose.Up(db.DB, "migrations")
}
```

- [ ] **Step 4: Write migration 00074**

Create `internal/db/migrations/00074_chat_core.sql`:

```sql
-- +goose NO TRANSACTION
-- +goose Up
-- Chat core (spec docs/superpowers/specs/2026-09-26-chat-redesign-design.md §2.1).
-- Adopts the Swift-created chat_conversations/chat_messages into goose and adds
-- what the redesigned chat needs. Legacy installs reach this file with the
-- tables present — normalizeLegacyChatTables (Go, before goose) has already
-- added any missing context_type/context_id/turn_id, so the ALTERs below see
-- one known shape. NO TRANSACTION because the Down recreates both tables and
-- must switch foreign_keys off around that: a DROP of chat_conversations with
-- foreign_keys on would cascade-delete every message (the 00056 precedent).
-- A partial failure leaves the added columns behind and a re-run fails on
-- "duplicate column" — the accepted NO TRANSACTION trade-off (00049, 00056).
PRAGMA foreign_keys = OFF;

CREATE TABLE IF NOT EXISTS chat_conversations (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    title        TEXT NOT NULL DEFAULT '',
    session_id   TEXT,
    context_type TEXT,
    context_id   TEXT,
    created_at   REAL NOT NULL,
    updated_at   REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS chat_messages (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
    role            TEXT NOT NULL,
    text            TEXT NOT NULL,
    created_at      REAL NOT NULL,
    turn_id         TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_chat_messages_conversation ON chat_messages(conversation_id);

-- One-time data fix formerly run by Swift ensureContextColumns.
UPDATE chat_conversations SET context_type = 'track' WHERE context_type = 'action_item';

CREATE TABLE chat_projects (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    name         TEXT NOT NULL,
    instructions TEXT NOT NULL DEFAULT '',
    created_at   REAL NOT NULL,
    updated_at   REAL NOT NULL,
    archived_at  REAL
);

ALTER TABLE chat_conversations ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;
ALTER TABLE chat_conversations ADD COLUMN archived_at REAL;
ALTER TABLE chat_conversations ADD COLUMN title_source TEXT NOT NULL DEFAULT 'prefix'
    CHECK(title_source IN ('prefix','ai','user'));
ALTER TABLE chat_conversations ADD COLUMN provider TEXT;
ALTER TABLE chat_conversations ADD COLUMN model TEXT;
ALTER TABLE chat_conversations ADD COLUMN project_id INTEGER REFERENCES chat_projects(id) ON DELETE SET NULL;
ALTER TABLE chat_conversations ADD COLUMN active_leaf_message_id INTEGER;
CREATE INDEX IF NOT EXISTS idx_chat_conversations_project ON chat_conversations(project_id);

ALTER TABLE chat_messages ADD COLUMN status TEXT NOT NULL DEFAULT 'complete'
    CHECK(status IN ('complete','partial','error'));
ALTER TABLE chat_messages ADD COLUMN provider TEXT;
ALTER TABLE chat_messages ADD COLUMN model TEXT;
ALTER TABLE chat_messages ADD COLUMN tokens_in INTEGER;
ALTER TABLE chat_messages ADD COLUMN tokens_out INTEGER;
ALTER TABLE chat_messages ADD COLUMN parent_id INTEGER REFERENCES chat_messages(id) ON DELETE CASCADE;
ALTER TABLE chat_messages ADD COLUMN error_code TEXT;
CREATE INDEX IF NOT EXISTS idx_chat_messages_parent ON chat_messages(parent_id);

-- Legacy rows become a linear chain: each message's parent is the previous
-- message of its conversation in id order; the first stays a root (NULL).
-- active_leaf_message_id is deliberately NOT backfilled: NULL means "linear",
-- which keeps Discuss chats (still written without parent_id) whole.
UPDATE chat_messages SET parent_id = (
    SELECT MAX(p.id) FROM chat_messages p
    WHERE p.conversation_id = chat_messages.conversation_id AND p.id < chat_messages.id
) WHERE parent_id IS NULL;

CREATE TABLE chat_turn_steps (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    message_id   INTEGER NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
    seq          INTEGER NOT NULL,
    tool_id      TEXT NOT NULL,
    name         TEXT NOT NULL,
    args_json    TEXT NOT NULL DEFAULT '{}',
    ok           INTEGER,
    summary      TEXT NOT NULL DEFAULT '',
    sources_json TEXT NOT NULL DEFAULT '[]',
    started_at   REAL NOT NULL,
    ended_at     REAL,
    UNIQUE(message_id, tool_id)
);

CREATE TABLE chat_attachments (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id INTEGER REFERENCES chat_conversations(id) ON DELETE CASCADE,
    project_id      INTEGER REFERENCES chat_projects(id) ON DELETE CASCADE,
    message_id      INTEGER REFERENCES chat_messages(id) ON DELETE SET NULL,
    name            TEXT NOT NULL,
    mime            TEXT NOT NULL,
    size            INTEGER NOT NULL,
    path            TEXT NOT NULL,
    sha256          TEXT NOT NULL,
    created_at      REAL NOT NULL,
    CHECK ((conversation_id IS NULL) <> (project_id IS NULL))
);
CREATE INDEX IF NOT EXISTS idx_chat_attachments_conversation ON chat_attachments(conversation_id);
CREATE INDEX IF NOT EXISTS idx_chat_attachments_project ON chat_attachments(project_id);

CREATE TABLE chat_artifacts (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
    message_id      INTEGER NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
    artifact_key    TEXT NOT NULL,
    version         INTEGER NOT NULL,
    kind            TEXT NOT NULL CHECK(kind IN ('document','table','email','slack','event','code')),
    title           TEXT NOT NULL DEFAULT '',
    content         TEXT NOT NULL,
    meta_json       TEXT NOT NULL DEFAULT '{}',
    edited          INTEGER NOT NULL DEFAULT 0,
    created_at      REAL NOT NULL,
    UNIQUE(conversation_id, artifact_key, version)
);

CREATE TABLE chat_project_sources (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER NOT NULL REFERENCES chat_projects(id) ON DELETE CASCADE,
    kind       TEXT NOT NULL CHECK(kind IN ('jira_project','slack_channel','target','track','person')),
    ref        TEXT NOT NULL,
    label      TEXT NOT NULL DEFAULT '',
    UNIQUE(project_id, kind, ref)
);

CREATE VIRTUAL TABLE chat_fts USING fts5(
    text,
    content='chat_messages', content_rowid='id',
    tokenize='porter unicode61 remove_diacritics 2'
);
CREATE VIRTUAL TABLE chat_title_fts USING fts5(
    title,
    content='chat_conversations', content_rowid='id',
    tokenize='porter unicode61 remove_diacritics 2'
);

-- +goose StatementBegin
CREATE TRIGGER chat_messages_fts_ai AFTER INSERT ON chat_messages BEGIN
    INSERT INTO chat_fts(rowid, text) VALUES (NEW.id, NEW.text);
END;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TRIGGER chat_messages_fts_ad AFTER DELETE ON chat_messages BEGIN
    INSERT INTO chat_fts(chat_fts, rowid, text) VALUES ('delete', OLD.id, OLD.text);
END;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TRIGGER chat_messages_fts_au AFTER UPDATE OF text ON chat_messages BEGIN
    INSERT INTO chat_fts(chat_fts, rowid, text) VALUES ('delete', OLD.id, OLD.text);
    INSERT INTO chat_fts(rowid, text) VALUES (NEW.id, NEW.text);
END;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TRIGGER chat_conversations_fts_ai AFTER INSERT ON chat_conversations BEGIN
    INSERT INTO chat_title_fts(rowid, title) VALUES (NEW.id, NEW.title);
END;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TRIGGER chat_conversations_fts_ad AFTER DELETE ON chat_conversations BEGIN
    INSERT INTO chat_title_fts(chat_title_fts, rowid, title) VALUES ('delete', OLD.id, OLD.title);
END;
-- +goose StatementEnd
-- +goose StatementBegin
CREATE TRIGGER chat_conversations_fts_au AFTER UPDATE OF title ON chat_conversations BEGIN
    INSERT INTO chat_title_fts(chat_title_fts, rowid, title) VALUES ('delete', OLD.id, OLD.title);
    INSERT INTO chat_title_fts(rowid, title) VALUES (NEW.id, NEW.title);
END;
-- +goose StatementEnd

INSERT INTO chat_fts(chat_fts) VALUES ('rebuild');
INSERT INTO chat_title_fts(chat_title_fts) VALUES ('rebuild');

PRAGMA foreign_keys = ON;

-- +goose Down
-- Returns the two adopted tables to their pre-00074 (normalized) shape and
-- keeps every row: the app created them, not this migration.
PRAGMA foreign_keys = OFF;

DROP TRIGGER IF EXISTS chat_conversations_fts_au;
DROP TRIGGER IF EXISTS chat_conversations_fts_ad;
DROP TRIGGER IF EXISTS chat_conversations_fts_ai;
DROP TRIGGER IF EXISTS chat_messages_fts_au;
DROP TRIGGER IF EXISTS chat_messages_fts_ad;
DROP TRIGGER IF EXISTS chat_messages_fts_ai;
DROP TABLE IF EXISTS chat_title_fts;
DROP TABLE IF EXISTS chat_fts;
DROP TABLE IF EXISTS chat_turn_steps;
DROP TABLE IF EXISTS chat_artifacts;
DROP TABLE IF EXISTS chat_attachments;
DROP TABLE IF EXISTS chat_project_sources;

CREATE TABLE chat_messages_old (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
    role            TEXT NOT NULL,
    text            TEXT NOT NULL,
    created_at      REAL NOT NULL,
    turn_id         TEXT NOT NULL DEFAULT ''
);
INSERT INTO chat_messages_old (id, conversation_id, role, text, created_at, turn_id)
    SELECT id, conversation_id, role, text, created_at, turn_id FROM chat_messages;
DROP TABLE chat_messages;
ALTER TABLE chat_messages_old RENAME TO chat_messages;
CREATE INDEX IF NOT EXISTS idx_chat_messages_conversation ON chat_messages(conversation_id);

CREATE TABLE chat_conversations_old (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    title        TEXT NOT NULL DEFAULT '',
    session_id   TEXT,
    context_type TEXT,
    context_id   TEXT,
    created_at   REAL NOT NULL,
    updated_at   REAL NOT NULL
);
INSERT INTO chat_conversations_old (id, title, session_id, context_type, context_id, created_at, updated_at)
    SELECT id, title, session_id, context_type, context_id, created_at, updated_at FROM chat_conversations;
DROP TABLE chat_conversations;
ALTER TABLE chat_conversations_old RENAME TO chat_conversations;

DROP TABLE IF EXISTS chat_projects;

PRAGMA foreign_keys = ON;
```

- [ ] **Step 5: Add the Go readers to `internal/db/chat.go`**

Replace the import block of `internal/db/chat.go` with:

```go
import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
)
```

Append:

```go
// activeBranchCTE yields active_path(id, parent_id): every message on its
// conversation's active branch (root → active_leaf_message_id). Paired with
// onActiveBranch. The p.id < a.id guard makes a malformed parent cycle
// terminate instead of recursing forever (a parent always predates its child).
const activeBranchCTE = `WITH RECURSIVE active_path(id, parent_id) AS (
	SELECT m.id, m.parent_id FROM chat_messages m
	JOIN chat_conversations c ON c.id = m.conversation_id AND c.active_leaf_message_id = m.id
	UNION ALL
	SELECT p.id, p.parent_id FROM chat_messages p
	JOIN active_path a ON p.id = a.parent_id AND p.id < a.id
)
`

// onActiveBranch filters messages m of conversation c to the active branch. A
// conversation without an active leaf — every Discuss chat and every legacy
// row — keeps all its messages (linear), as does one whose leaf row is gone.
const onActiveBranch = `(c.active_leaf_message_id IS NULL
	OR NOT EXISTS (SELECT 1 FROM chat_messages leaf
		WHERE leaf.id = c.active_leaf_message_id AND leaf.conversation_id = c.id)
	OR m.id IN (SELECT id FROM active_path))`

// ChatMessage is one chat_messages row, as the chat engine reads it.
type ChatMessage struct {
	ID, ConversationID         int64
	ParentID                   sql.NullInt64
	Role, Text, TurnID, Status string
	Provider, Model, ErrorCode string
	CreatedAt                  float64
}

const chatMessageColumns = `m.id, m.conversation_id, m.parent_id, m.role, m.text, m.turn_id, m.status,
	COALESCE(m.provider, ''), COALESCE(m.model, ''), COALESCE(m.error_code, ''), m.created_at`

func scanChatMessages(rows *sql.Rows) ([]ChatMessage, error) {
	defer rows.Close()
	var out []ChatMessage
	for rows.Next() {
		var m ChatMessage
		if err := rows.Scan(&m.ID, &m.ConversationID, &m.ParentID, &m.Role, &m.Text, &m.TurnID, &m.Status,
			&m.Provider, &m.Model, &m.ErrorCode, &m.CreatedAt); err != nil {
			return nil, fmt.Errorf("scanning chat message: %w", err)
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// ActiveChatPath returns the conversation's visible thread, root first: the
// parent chain of active_leaf_message_id. When the leaf is NULL (a legacy or
// Discuss conversation) or points at a deleted row, it falls back to every
// message in id order. An unknown conversation is (nil, nil).
func (db *DB) ActiveChatPath(conversationID int64) ([]ChatMessage, error) {
	var leaf sql.NullInt64
	err := db.QueryRow(`SELECT active_leaf_message_id FROM chat_conversations WHERE id = ?`, conversationID).Scan(&leaf)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading active leaf of conversation %d: %w", conversationID, err)
	}
	if leaf.Valid {
		rows, err := db.Query(`WITH RECURSIVE path(id, parent_id, depth) AS (
				SELECT id, parent_id, 0 FROM chat_messages WHERE id = ? AND conversation_id = ?
				UNION ALL
				SELECT p.id, p.parent_id, path.depth + 1 FROM chat_messages p
				JOIN path ON p.id = path.parent_id AND p.id < path.id
			)
			SELECT `+chatMessageColumns+` FROM chat_messages m JOIN path ON path.id = m.id
			ORDER BY path.depth DESC`, leaf.Int64, conversationID)
		if err != nil {
			return nil, fmt.Errorf("reading active path of conversation %d: %w", conversationID, err)
		}
		out, err := scanChatMessages(rows)
		if err != nil || len(out) > 0 {
			return out, err
		}
	}
	rows, err := db.Query(`SELECT `+chatMessageColumns+` FROM chat_messages m
		WHERE m.conversation_id = ? ORDER BY m.id`, conversationID)
	if err != nil {
		return nil, fmt.Errorf("reading messages of conversation %d: %w", conversationID, err)
	}
	return scanChatMessages(rows)
}

// ChatConversation is the part of a chat_conversations row the Go side reads.
type ChatConversation struct {
	ID                                                                     int64
	Title, TitleSource, SessionID, ContextType, ContextID, Provider, Model string
	ProjectID                                                              sql.NullInt64
}

// GetChatConversation reads one conversation; (nil, nil) when absent.
func (db *DB) GetChatConversation(id int64) (*ChatConversation, error) {
	var c ChatConversation
	err := db.QueryRow(`SELECT id, title, title_source, COALESCE(session_id, ''), COALESCE(context_type, ''),
			COALESCE(context_id, ''), COALESCE(provider, ''), COALESCE(model, ''), project_id
		FROM chat_conversations WHERE id = ?`, id).Scan(&c.ID, &c.Title, &c.TitleSource, &c.SessionID,
		&c.ContextType, &c.ContextID, &c.Provider, &c.Model, &c.ProjectID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading chat conversation %d: %w", id, err)
	}
	return &c, nil
}

// SetChatTitle writes a conversation title and its source. It never
// overwrites an owner-set title: when the stored title_source is 'user' it
// writes nothing and returns false. The Go side only ever writes 'ai'
// (`watchtower chat title`); Swift owns 'prefix' and 'user'.
func (db *DB) SetChatTitle(id int64, title, source string) (bool, error) {
	switch source {
	case "prefix", "ai", "user":
	default:
		return false, fmt.Errorf("invalid chat title source %q", source)
	}
	res, err := db.Exec(`UPDATE chat_conversations SET title = ?, title_source = ?
		WHERE id = ? AND title_source != 'user'`, title, source, id)
	if err != nil {
		return false, fmt.Errorf("setting title of conversation %d: %w", id, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("setting title of conversation %d: %w", id, err)
	}
	return n > 0, nil
}

// ChatProjectSource is one pinned source of a chat project.
type ChatProjectSource struct{ Kind, Ref, Label string }

// ChatProjectFile is one file attached to a chat project.
type ChatProjectFile struct {
	ID               int64
	Name, Mime, Path string
	Size             int64
}

// ChatProjectContext is what a chat session needs from a project: its
// instructions, pinned sources and files, split into text-like files (inlined
// into the prompt) and binaries (images/PDFs, attached to the first turn).
type ChatProjectContext struct {
	Name, Instructions string
	Sources            []ChatProjectSource
	TextFiles          []ChatProjectFile
	BinaryFiles        []ChatProjectFile
}

// isBinaryChatMime reports whether a project file travels as a content block
// (image or PDF) rather than as inlined text.
func isBinaryChatMime(mime string) bool {
	return strings.HasPrefix(mime, "image/") || mime == "application/pdf"
}

// GetChatProjectContext reads a project with its sources and files; (nil, nil)
// when the project does not exist.
func (db *DB) GetChatProjectContext(projectID int64) (*ChatProjectContext, error) {
	var pc ChatProjectContext
	err := db.QueryRow(`SELECT name, instructions FROM chat_projects WHERE id = ?`, projectID).
		Scan(&pc.Name, &pc.Instructions)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading chat project %d: %w", projectID, err)
	}
	if pc.Sources, err = db.chatProjectSources(projectID); err != nil {
		return nil, err
	}
	rows, err := db.Query(`SELECT id, name, mime, path, size FROM chat_attachments
		WHERE project_id = ? ORDER BY id`, projectID)
	if err != nil {
		return nil, fmt.Errorf("reading files of chat project %d: %w", projectID, err)
	}
	defer rows.Close()
	for rows.Next() {
		var f ChatProjectFile
		if err := rows.Scan(&f.ID, &f.Name, &f.Mime, &f.Path, &f.Size); err != nil {
			return nil, fmt.Errorf("scanning chat project file: %w", err)
		}
		if isBinaryChatMime(f.Mime) {
			pc.BinaryFiles = append(pc.BinaryFiles, f)
		} else {
			pc.TextFiles = append(pc.TextFiles, f)
		}
	}
	return &pc, rows.Err()
}

func (db *DB) chatProjectSources(projectID int64) ([]ChatProjectSource, error) {
	rows, err := db.Query(`SELECT kind, ref, label FROM chat_project_sources WHERE project_id = ? ORDER BY id`, projectID)
	if err != nil {
		return nil, fmt.Errorf("reading sources of chat project %d: %w", projectID, err)
	}
	defer rows.Close()
	var out []ChatProjectSource
	for rows.Next() {
		var s ChatProjectSource
		if err := rows.Scan(&s.Kind, &s.Ref, &s.Label); err != nil {
			return nil, fmt.Errorf("scanning chat project source: %w", err)
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

// ChatStepSummaries returns, per assistant message, one line per tool step in
// seq order — "name: summary", or "name (failed): summary" — for the replay
// transcript (tool steps are replayed as one-line summaries, never in full).
func (db *DB) ChatStepSummaries(messageIDs []int64) (map[int64][]string, error) {
	if len(messageIDs) == 0 {
		return nil, nil
	}
	ph := make([]string, len(messageIDs))
	args := make([]any, len(messageIDs))
	for i, id := range messageIDs {
		ph[i] = "?"
		args[i] = id
	}
	rows, err := db.Query(`SELECT message_id, name, ok, summary FROM chat_turn_steps
		WHERE message_id IN (`+strings.Join(ph, ",")+`) ORDER BY message_id, seq`, args...)
	if err != nil {
		return nil, fmt.Errorf("reading chat turn steps: %w", err)
	}
	defer rows.Close()
	out := map[int64][]string{}
	for rows.Next() {
		var (
			msgID         int64
			name, summary string
			ok            sql.NullInt64
		)
		if err := rows.Scan(&msgID, &name, &ok, &summary); err != nil {
			return nil, fmt.Errorf("scanning chat turn step: %w", err)
		}
		label := name
		if ok.Valid && ok.Int64 == 0 {
			label += " (failed)"
		}
		if summary != "" {
			label += ": " + summary
		}
		out[msgID] = append(out[msgID], label)
	}
	return out, rows.Err()
}
```

- [ ] **Step 6: Filter the two memory/next-step readers to the active branch**

In `internal/db/chat.go`, `ListRecentChatTurns`: replace the `db.Query(...)` call with

```go
	// Newest first so LIMIT keeps the RECENT tail, then reversed below. Only
	// the active branch counts (spec §2.2): an edited or regenerated message's
	// abandoned sibling never reaches the next-step prompt.
	rows, err := db.Query(activeBranchCTE+`SELECT m.id, m.role, m.text, CAST(m.created_at AS INTEGER)
		FROM chat_messages m
		JOIN chat_conversations c ON c.id = m.conversation_id
		WHERE c.context_type = ? AND c.context_id = ? AND `+onActiveBranch+`
		ORDER BY m.created_at DESC, m.id DESC
		LIMIT ?`, contextType, contextID, limit)
```

and in its doc comment replace the paragraph that starts "The chat tables are Swift-owned" with:

```go
// The chat tables are goose-owned since migration 00074, so they always exist
// after Open; ChatTablesPresent stays as a cheap guard for a handle opened on a
// pre-00074 file. A non-positive limit is a clean empty read.
```

In `internal/db/memory.go`, `ListOwnerChatTurns`: replace the `db.Query(...)` call with

```go
	rows, err := db.Query(activeBranchCTE+`SELECT m.id, m.conversation_id, c.context_type, COALESCE(c.context_id, ''),
			CAST(m.created_at AS INTEGER), m.text
		FROM chat_messages m
		JOIN chat_conversations c ON c.id = m.conversation_id
		WHERE m.role = 'user' AND c.context_type IN (`+placeholders+`) AND m.id > ? AND `+onActiveBranch+`
		ORDER BY m.id`, args...)
```

and append to its doc comment:

```go
//
// Only the active branch is read (spec §2.2): an owner turn replaced by an
// edit is not a statement the owner stands by. Because the ingest floor is
// id-based, a turn that sat on an inactive branch when the ingest ran is not
// picked up later if the owner switches back to that branch — accepted.
```

Replace the doc comment of `ChatTablesPresent` with:

```go
// ChatTablesPresent reports whether chat_conversations and chat_messages both
// exist. Since migration 00074 adopted them into goose they always do after
// Open; the check stays so a reader handed a pre-00074 raw handle degrades to
// an empty read instead of an error (MEM-05/MEM-09).
```

- [ ] **Step 7: Remove the test helpers that created the chat tables by hand**

The tables now exist in every migrated test DB, so a helper's `CREATE TABLE chat_…` fails with "table already exists". Delete every call, then the three helper definitions:

```bash
grep -rlE 'createChatTables(ForTest|ForNextStepTest)?\(' internal | xargs perl -0pi -e 's/^[ \t]*createChatTables(?:ForTest|ForNextStepTest)?\(t, \w+\)\n//mg'
grep -rnE 'createChatTables(ForTest|ForNextStepTest)?' internal
```

Expected from the second command: only the three `func createChatTables…` definitions (`internal/db/memory_test.go`, `internal/memory/chat_evidence_test.go`, `internal/targets/nextstep_test.go`). Delete each definition together with its doc comment in the editor.

In `internal/db/memory_test.go` replace `TestChatTablesPresent` with:

```go
// TestChatTablesPresent: since migration 00074 adopted the chat tables into
// goose, a freshly migrated database always has them.
func TestChatTablesPresent(t *testing.T) {
	db := openTestDB(t)

	present, err := db.ChatTablesPresent()
	if err != nil {
		t.Fatalf("ChatTablesPresent: %v", err)
	}
	if !present {
		t.Fatal("chat tables must exist after migration 00074")
	}
}
```

Leave `TestListRecentChatTurnsAbsentTables`, `TestValidateChatRefsTablesAbsent`, `TestIngestChatStatementsAbsentTablesNoop` and `TestBuildNextStepPrompt_AbsentChatTablesStillBuilds` untouched: their assertions (empty read, ref dropped, floor unchanged, prompt builds) still hold on empty tables, and the MEM-09 guard list in `docs/inventory/memory.md` names them — do not rename or weaken them.

- [ ] **Step 8: Mirror the schema and register the tables**

In `internal/db/schema.sql`, append after the knowledge-search block:

```sql
-- Chat (see 00074). Adopted from the Desktop app; conversations form a tree via
-- chat_messages.parent_id, the visible thread is root → active_leaf_message_id
-- (NULL = linear). chat_fts / chat_title_fts are external-content FTS5 indexes
-- kept by triggers.
CREATE TABLE IF NOT EXISTS chat_projects (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    name         TEXT NOT NULL,
    instructions TEXT NOT NULL DEFAULT '',
    created_at   REAL NOT NULL,
    updated_at   REAL NOT NULL,
    archived_at  REAL
);

CREATE TABLE IF NOT EXISTS chat_conversations (
    id                     INTEGER PRIMARY KEY AUTOINCREMENT,
    title                  TEXT NOT NULL DEFAULT '',
    session_id             TEXT,
    context_type           TEXT,
    context_id             TEXT,
    created_at             REAL NOT NULL,
    updated_at             REAL NOT NULL,
    pinned                 INTEGER NOT NULL DEFAULT 0,
    archived_at            REAL,
    title_source           TEXT NOT NULL DEFAULT 'prefix' CHECK(title_source IN ('prefix','ai','user')),
    provider               TEXT,
    model                  TEXT,
    project_id             INTEGER REFERENCES chat_projects(id) ON DELETE SET NULL,
    active_leaf_message_id INTEGER
);
CREATE INDEX IF NOT EXISTS idx_chat_conversations_project ON chat_conversations(project_id);

CREATE TABLE IF NOT EXISTS chat_messages (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
    role            TEXT NOT NULL,
    text            TEXT NOT NULL,
    created_at      REAL NOT NULL,
    turn_id         TEXT NOT NULL DEFAULT '',
    status          TEXT NOT NULL DEFAULT 'complete' CHECK(status IN ('complete','partial','error')),
    provider        TEXT,
    model           TEXT,
    tokens_in       INTEGER,
    tokens_out      INTEGER,
    parent_id       INTEGER REFERENCES chat_messages(id) ON DELETE CASCADE,
    error_code      TEXT
);
CREATE INDEX IF NOT EXISTS idx_chat_messages_conversation ON chat_messages(conversation_id);
CREATE INDEX IF NOT EXISTS idx_chat_messages_parent ON chat_messages(parent_id);

CREATE TABLE IF NOT EXISTS chat_turn_steps (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    message_id   INTEGER NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
    seq          INTEGER NOT NULL,
    tool_id      TEXT NOT NULL,
    name         TEXT NOT NULL,
    args_json    TEXT NOT NULL DEFAULT '{}',
    ok           INTEGER,
    summary      TEXT NOT NULL DEFAULT '',
    sources_json TEXT NOT NULL DEFAULT '[]',
    started_at   REAL NOT NULL,
    ended_at     REAL,
    UNIQUE(message_id, tool_id)
);

CREATE TABLE IF NOT EXISTS chat_attachments (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id INTEGER REFERENCES chat_conversations(id) ON DELETE CASCADE,
    project_id      INTEGER REFERENCES chat_projects(id) ON DELETE CASCADE,
    message_id      INTEGER REFERENCES chat_messages(id) ON DELETE SET NULL,
    name            TEXT NOT NULL,
    mime            TEXT NOT NULL,
    size            INTEGER NOT NULL,
    path            TEXT NOT NULL,
    sha256          TEXT NOT NULL,
    created_at      REAL NOT NULL,
    CHECK ((conversation_id IS NULL) <> (project_id IS NULL))
);
CREATE INDEX IF NOT EXISTS idx_chat_attachments_conversation ON chat_attachments(conversation_id);
CREATE INDEX IF NOT EXISTS idx_chat_attachments_project ON chat_attachments(project_id);

CREATE TABLE IF NOT EXISTS chat_artifacts (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
    message_id      INTEGER NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
    artifact_key    TEXT NOT NULL,
    version         INTEGER NOT NULL,
    kind            TEXT NOT NULL CHECK(kind IN ('document','table','email','slack','event','code')),
    title           TEXT NOT NULL DEFAULT '',
    content         TEXT NOT NULL,
    meta_json       TEXT NOT NULL DEFAULT '{}',
    edited          INTEGER NOT NULL DEFAULT 0,
    created_at      REAL NOT NULL,
    UNIQUE(conversation_id, artifact_key, version)
);

CREATE TABLE IF NOT EXISTS chat_project_sources (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER NOT NULL REFERENCES chat_projects(id) ON DELETE CASCADE,
    kind       TEXT NOT NULL CHECK(kind IN ('jira_project','slack_channel','target','track','person')),
    ref        TEXT NOT NULL,
    label      TEXT NOT NULL DEFAULT '',
    UNIQUE(project_id, kind, ref)
);

CREATE VIRTUAL TABLE IF NOT EXISTS chat_fts USING fts5(
    text, content='chat_messages', content_rowid='id',
    tokenize='porter unicode61 remove_diacritics 2'
);
CREATE VIRTUAL TABLE IF NOT EXISTS chat_title_fts USING fts5(
    title, content='chat_conversations', content_rowid='id',
    tokenize='porter unicode61 remove_diacritics 2'
);
CREATE TRIGGER IF NOT EXISTS chat_messages_fts_ai AFTER INSERT ON chat_messages BEGIN
    INSERT INTO chat_fts(rowid, text) VALUES (NEW.id, NEW.text);
END;
CREATE TRIGGER IF NOT EXISTS chat_messages_fts_ad AFTER DELETE ON chat_messages BEGIN
    INSERT INTO chat_fts(chat_fts, rowid, text) VALUES ('delete', OLD.id, OLD.text);
END;
CREATE TRIGGER IF NOT EXISTS chat_messages_fts_au AFTER UPDATE OF text ON chat_messages BEGIN
    INSERT INTO chat_fts(chat_fts, rowid, text) VALUES ('delete', OLD.id, OLD.text);
    INSERT INTO chat_fts(rowid, text) VALUES (NEW.id, NEW.text);
END;
CREATE TRIGGER IF NOT EXISTS chat_conversations_fts_ai AFTER INSERT ON chat_conversations BEGIN
    INSERT INTO chat_title_fts(rowid, title) VALUES (NEW.id, NEW.title);
END;
CREATE TRIGGER IF NOT EXISTS chat_conversations_fts_ad AFTER DELETE ON chat_conversations BEGIN
    INSERT INTO chat_title_fts(chat_title_fts, rowid, title) VALUES ('delete', OLD.id, OLD.title);
END;
CREATE TRIGGER IF NOT EXISTS chat_conversations_fts_au AFTER UPDATE OF title ON chat_conversations BEGIN
    INSERT INTO chat_title_fts(chat_title_fts, rowid, title) VALUES ('delete', OLD.id, OLD.title);
    INSERT INTO chat_title_fts(rowid, title) VALUES (NEW.id, NEW.title);
END;
```

In `internal/db/db_test.go`, `TestAllTablesExist`, change the last line of `expectedTables` to:

```go
		"kb_documents", "kb_chunks", "kb_sources",
		"chat_conversations", "chat_messages", "chat_turn_steps", "chat_attachments",
		"chat_artifacts", "chat_projects", "chat_project_sources", "chat_fts", "chat_title_fts",
```

Regenerate the golden:

Run: `go test ./internal/db/ -run TestSchemaGolden -update -v`
Expected: PASS, log line `wrote testdata/schema_v73.golden (… bytes)` (the file name stays `schema_v73.golden`; the test hardcodes it).

- [ ] **Step 9: Run the affected packages**

Run: `go test ./internal/db/ ./internal/memory/ ./internal/targets/`
Expected: PASS. If a `goose.Down`/`DownTo` test (e.g. `TestMemorySurfacesMigrationDownUpCycle`, `TestMigration00019ClearsBeliefContentHash`) fails, the 00074 Down is wrong — fix the SQL, never the test.

- [ ] **Step 10: Commit**

Run `git status --short internal/memory internal/targets` first and confirm only the edited test files are listed. Then:

```bash
git add internal/db/chat_migrate.go internal/db/migrations/00074_chat_core.sql internal/db/chat_migration_test.go \
  internal/db/db.go internal/db/chat.go internal/db/chat_test.go internal/db/memory.go internal/db/memory_test.go \
  internal/db/schema.sql internal/db/db_test.go internal/db/testdata/schema_v73.golden \
  internal/memory internal/targets/nextstep_test.go
git commit -m "feat(db): adopt chat tables into goose with branches and FTS (migration 00074)" \
  -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: v2 events + Claude translator

**Files:**
- Create: `internal/chat/events.go`
- Create: `internal/chat/claude_translate.go`
- Create: `internal/chat/sources.go` (minimal `SummarizeToolResult`; Task 3 fills it)
- Create: `internal/chat/testmain_test.go`
- Create: `internal/chat/events_test.go`
- Create: `internal/chat/claude_translate_test.go`
- Create: `internal/chat/testdata/record_fixtures.sh`
- Create (recorded): `internal/chat/testdata/claude_text.jsonl`, `claude_thinking.jsonl`, `claude_tool.jsonl`, `claude_interrupt.jsonl`, `claude_resume_missing.jsonl`, `claude_resume_missing.stderr`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces (binding, package `chat`):
  - `type Event struct{ Type, TurnID, Text, ID, Name string; Args json.RawMessage; OK *bool; Summary string; Sources []Source; TokensIn, TokensOut int; Model, Provider, SessionID, Status, Code, Message string; Retryable bool }` with JSON tags `type, turn_id, text, id, name, args, ok, summary, sources, tokens_in, tokens_out, model, provider, session_id, status, code, message, retryable` (all but `type` `omitempty`; `ok` is a pointer so `false` is emitted).
  - Constants `EventSessionReady … EventError`, `StatusComplete="complete"`, `StatusInterrupted="interrupted"`, `CodeAuth … CodeInternal`, `CommandTurn/CommandCancel/CommandClose`.
  - `type Source struct{ Kind, Title, URL, Ref string }` (tags `kind, title, url,omitempty, ref`).
  - `type Command struct{ Type, TurnID, Text string; Attachments []Attachment; Replay bool }` (tags `type, turn_id, text, attachments, replay`); `type Attachment struct{ Path, Mime, Name string }`.
  - `type EventWriter struct`; `func NewEventWriter(w io.Writer) *EventWriter`; `func (w *EventWriter) Emit(e Event) error` (mutex, one `\n`-terminated JSON line per event, one `Write` call).
  - `type ClaudeTranslator struct`; `func NewClaudeTranslator(turnID func() string) *ClaudeTranslator`; `func (t *ClaudeTranslator) Feed(line []byte) ([]Event, error)`; `func (t *ClaudeTranslator) MarkInterrupted()`; `func (t *ClaudeTranslator) SessionID() string`.
  - `func ClassifyClaudeError(msg string) (code string, retryable bool)`.
  - Helpers used by later tasks: `func errorEvent(turnID, code, msg string, retryable bool) Event`, `func isTerminal(e Event) bool`, `func truncateRunes(s string, n int) string`, `func collapseSpace(s string) string`, `const SummaryMaxRunes = 300`, `func SummarizeToolResult(name, result string) (string, []Source)` (minimal here).
  - Tool name mapping: `mcp__watchtower__X` → `X`; `mcp__<server>__<tool>` → `<server>:<tool>`; anything else unchanged.

- [ ] **Step 1: Record the real Claude fixtures**

Create `internal/chat/testdata/record_fixtures.sh`:

```bash
#!/usr/bin/env bash
# Records the Claude stream-json fixtures replayed by claude_translate_test.go.
# Needs a logged-in `claude` CLI (2.1.x) and Go. Run from the repo root:
#   bash internal/chat/testdata/record_fixtures.sh
# Afterwards scrub the output (see the plan): no home paths, emails or tokens.
set -euo pipefail
out=internal/chat/testdata
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

flags=(-p --input-format stream-json --output-format stream-json
  --include-partial-messages --verbose --setting-sources project,local)

# user <text> — one stream-json user message (texts here contain no quotes).
user() { printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"%s"}]}}\n' "$1"; }

# 1. Plain text, one turn.
user "Reply with exactly three words." | claude "${flags[@]}" --model haiku > "$out/claude_text.jsonl"

# 2. Extended thinking: MAX_THINKING_TOKENS turns thinking blocks on.
user "What is 17 times 23? Think first, then answer with the number only." \
  | MAX_THINKING_TOKENS=2048 claude "${flags[@]}" --model sonnet > "$out/claude_thinking.jsonl"

# 3. One MCP tool call against `watchtower mcp` on an empty temp database.
go build -o "$work/watchtower" .
cat > "$work/mcp.json" <<JSON
{"mcpServers":{"watchtower":{"command":"$work/watchtower","args":["mcp","--db-path","$work/wt.db"]}}}
JSON
user "Call the list_targets tool once with no arguments, then say how many targets it returned." \
  | claude "${flags[@]}" --model haiku --mcp-config "$work/mcp.json" \
      --allowedTools mcp__watchtower \
      --disallowedTools "Bash,Read,Grep,Glob,LS,WebFetch,WebSearch,Edit,Write,Task" \
  > "$out/claude_tool.jsonl"

# 4. Interrupt mid-turn, then a second turn in the same process.
{
  user "Write a 600-word essay about lighthouses."
  sleep 4
  printf '{"type":"control_request","request_id":"r1","request":{"subtype":"interrupt"}}\n'
  sleep 3
  user "Now reply with just: ok"
  sleep 20
} | claude "${flags[@]}" --model haiku > "$out/claude_interrupt.jsonl"

# 5. --resume of a session that does not exist (the session_lost signal).
user "hi" | claude "${flags[@]}" --model haiku --resume 00000000-0000-4000-8000-000000000000 \
  > "$out/claude_resume_missing.jsonl" 2> "$out/claude_resume_missing.stderr" || true

# Scrub the home directory out of system/init lines.
sed -i '' "s#$HOME#/HOME#g" "$out"/claude_*.jsonl "$out"/claude_*.stderr
echo "recorded:"; wc -l "$out"/claude_*
```

Run: `bash internal/chat/testdata/record_fixtures.sh`
Expected: five `.jsonl` files and one `.stderr`; `claude_tool.jsonl` contains `"name":"mcp__watchtower__list_targets"`; `claude_interrupt.jsonl` contains `"control_response"` and two `"type":"result"` lines; `claude_resume_missing.stderr` or `.jsonl` contains `No conversation found`.

Then inspect every fixture for secrets: `grep -iE '@[a-z0-9-]+\.[a-z]+|sk-ant|oauth|token' internal/chat/testdata/claude_*` must print nothing that identifies a person or credential (usage fields like `"input_tokens"` are fine). Replace anything else by hand with `REDACTED`.

If `claude` is not installed or not logged in, STOP and report BLOCKED — do not hand-write these files; the synthetic fixtures in Step 2 do not replace them (spec §10: translator tested on recorded fixtures).

- [ ] **Step 2: Write the failing tests**

Create `internal/chat/testmain_test.go`:

```go
package chat

import (
	"fmt"
	"os"
	"testing"

	"watchtower/internal/db"
)

// TestMain installs the migrated-schema template so db.OpenTestDB is fast.
func TestMain(m *testing.M) {
	if err := db.InitTestTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}
```

Create `internal/chat/events_test.go`:

```go
package chat

import (
	"bufio"
	"bytes"
	"encoding/json"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestEventWriter_OneJSONLinePerEventUnderConcurrency(t *testing.T) {
	var buf bytes.Buffer
	w := NewEventWriter(&buf)
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			require.NoError(t, w.Emit(Event{Type: EventTextDelta, TurnID: "t1", Text: "chunk with\nnewline"}))
		}()
	}
	wg.Wait()

	sc := bufio.NewScanner(&buf)
	n := 0
	for sc.Scan() {
		var e Event
		require.NoError(t, json.Unmarshal(sc.Bytes(), &e), "every line is one complete JSON event")
		assert.Equal(t, "chunk with\nnewline", e.Text)
		n++
	}
	assert.Equal(t, 50, n)
}

func TestEvent_FalseOKIsSerialized(t *testing.T) {
	ok := false
	b, err := json.Marshal(Event{Type: EventToolEnd, TurnID: "t", ID: "x", OK: &ok})
	require.NoError(t, err)
	assert.Contains(t, string(b), `"ok":false`, "a failed step must reach Swift as ok:false, not as a missing field")
	assert.NotContains(t, string(b), `"text"`, "empty fields are omitted")
}

func TestCommand_DecodesSpecShape(t *testing.T) {
	var c Command
	require.NoError(t, json.Unmarshal([]byte(
		`{"type":"turn","turn_id":"u1","text":"hi","attachments":[{"path":"/abs/x.png","mime":"image/png","name":"x.png"}],"replay":true}`), &c))
	assert.Equal(t, Command{Type: CommandTurn, TurnID: "u1", Text: "hi",
		Attachments: []Attachment{{Path: "/abs/x.png", Mime: "image/png", Name: "x.png"}}, Replay: true}, c)
}
```

Create `internal/chat/claude_translate_test.go`:

```go
package chat

import (
	"bufio"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// feedAll runs every line through a fresh translator bound to turn id "t1".
func feedAll(t *testing.T, tr *ClaudeTranslator, lines ...string) []Event {
	t.Helper()
	var out []Event
	for _, l := range lines {
		evs, err := tr.Feed([]byte(l))
		require.NoError(t, err, l)
		out = append(out, evs...)
	}
	return out
}

func fixedTurn(id string) func() string { return func() string { return id } }

func types(evs []Event) []string {
	out := make([]string, len(evs))
	for i, e := range evs {
		out[i] = e.Type
	}
	return out
}

const (
	lnMsgStart  = `{"type":"stream_event","event":{"type":"message_start","message":{"model":"claude-sonnet-x","content":[]}},"session_id":"s1"}`
	lnTextStart = `{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}`
	lnTextStop  = `{"type":"stream_event","event":{"type":"content_block_stop","index":0}}`
	lnMsgStop   = `{"type":"stream_event","event":{"type":"message_stop"}}`
	lnResultOK  = `{"type":"result","subtype":"success","is_error":false,"result":"Hello","session_id":"s1","usage":{"input_tokens":10,"cache_read_input_tokens":5,"cache_creation_input_tokens":2,"output_tokens":7}}`
)

func textDelta(i int, s string) string {
	return `{"type":"stream_event","event":{"type":"content_block_delta","index":` + strconv.Itoa(i) +
		`,"delta":{"type":"text_delta","text":"` + s + `"}}}`
}

func TestClaudeTranslator_TextDeltasStreamTokenLevel(t *testing.T) {
	tr := NewClaudeTranslator(fixedTurn("t1"))
	evs := feedAll(t, tr,
		`{"type":"system","subtype":"init","session_id":"s1","model":"claude-sonnet-x"}`,
		lnMsgStart, lnTextStart, textDelta(0, "Hel"), textDelta(0, "lo"), lnTextStop,
		`{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}}`,
		lnMsgStop,
		`{"type":"assistant","message":{"model":"claude-sonnet-x","content":[{"type":"text","text":"Hello"}]},"session_id":"s1"}`,
		lnResultOK,
	)
	require.Equal(t, []string{EventTextDelta, EventTextDelta, EventUsage, EventTurnDone}, types(evs),
		"the full assistant message must not duplicate the streamed text")
	assert.Equal(t, "Hel", evs[0].Text)
	assert.Equal(t, "t1", evs[0].TurnID)
	assert.Equal(t, 17, evs[2].TokensIn, "input + cache read + cache creation")
	assert.Equal(t, 7, evs[2].TokensOut)
	assert.Equal(t, "claude-sonnet-x", evs[2].Model)
	assert.Equal(t, StatusComplete, evs[3].Status)
	assert.Equal(t, "s1", evs[3].SessionID)
	assert.Equal(t, "s1", tr.SessionID())
}

// TestChat02_ToolCallNeverWipesText: CHAT-02 — every tool call becomes a
// visible tool_start/tool_end pair, and the text before the tool stays (there
// is no reset event in protocol v2).
func TestChat02_ToolCallNeverWipesText(t *testing.T) {
	tr := NewClaudeTranslator(fixedTurn("t1"))
	evs := feedAll(t, tr,
		lnMsgStart, lnTextStart, textDelta(0, "Let me look."), lnTextStop,
		`{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"mcp__watchtower__search_knowledge","input":{}}}}`,
		`{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"queries\":"}}}`,
		`{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"[\"pay\"]}"}}}`,
		`{"type":"stream_event","event":{"type":"content_block_stop","index":1}}`,
		lnMsgStop,
		`{"type":"user","message":{"role":"user","content":[{"type":"text","text":"not a tool result, ignored"},{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"{\"hits\":[]}"}],"is_error":false}]}}`,
		lnMsgStart, lnTextStart, textDelta(0, "Found it."), lnTextStop, lnMsgStop,
		lnResultOK,
	)
	require.Equal(t, []string{EventTextDelta, EventToolStart, EventToolEnd, EventTextDelta, EventUsage, EventTurnDone}, types(evs))
	for _, e := range evs {
		assert.NotEqual(t, "reset", e.Type, "protocol v2 never wipes text")
	}
	start, end := evs[1], evs[2]
	assert.Equal(t, "toolu_1", start.ID)
	assert.Equal(t, "search_knowledge", start.Name, "the mcp__watchtower__ prefix is stripped")
	assert.JSONEq(t, `{"queries":["pay"]}`, string(start.Args))
	assert.Equal(t, "toolu_1", end.ID)
	require.NotNil(t, end.OK)
	assert.True(t, *end.OK)
}

func TestClaudeTranslator_ToolArgsEdgeCases(t *testing.T) {
	tr := NewClaudeTranslator(fixedTurn("t1"))
	evs := feedAll(t, tr,
		`{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"a","name":"mcp__confluence__search"}}}`,
		`{"type":"stream_event","event":{"type":"content_block_stop","index":0}}`,
		`{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"b","name":"mcp__watchtower__get_target"}}}`,
		`{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"id\":"}}}`,
		`{"type":"stream_event","event":{"type":"content_block_stop","index":1}}`,
	)
	require.Len(t, evs, 2)
	assert.Equal(t, "confluence:search", evs[0].Name, "external MCP tools keep server:name")
	assert.JSONEq(t, `{}`, string(evs[0].Args), "no input deltas → empty object")
	assert.JSONEq(t, `{"_raw":"{\"id\":"}`, string(evs[1].Args), "truncated JSON is wrapped, never emitted invalid")
}

func TestClaudeTranslator_FailedToolIsARedStepNotATurnError(t *testing.T) {
	tr := NewClaudeTranslator(fixedTurn("t1"))
	evs := feedAll(t, tr,
		`{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"x","name":"mcp__watchtower__get_jira_issue"}}}`,
		`{"type":"stream_event","event":{"type":"content_block_stop","index":0}}`,
		`{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"no jira issue with key ABC-1","is_error":true}]}}`,
	)
	require.Equal(t, []string{EventToolStart, EventToolEnd}, types(evs))
	require.NotNil(t, evs[1].OK)
	assert.False(t, *evs[1].OK)
	assert.Equal(t, "no jira issue with key ABC-1", evs[1].Summary)
	assert.Empty(t, evs[1].Sources)
}

func TestClaudeTranslator_ThinkingIsDropped(t *testing.T) {
	tr := NewClaudeTranslator(fixedTurn("t1"))
	evs := feedAll(t, tr,
		lnMsgStart,
		`{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}}`,
		`{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"secret reasoning"}}}`,
		`{"type":"stream_event","event":{"type":"content_block_stop","index":0}}`,
		`{"type":"stream_event","event":{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}}`,
		textDelta(1, "391"),
	)
	require.Equal(t, []string{EventTextDelta}, types(evs))
	assert.Equal(t, "391", evs[0].Text)
}

func TestClaudeTranslator_InterruptEndsTurnInterrupted(t *testing.T) {
	tr := NewClaudeTranslator(fixedTurn("t1"))
	tr.MarkInterrupted()
	evs := feedAll(t, tr,
		`{"type":"control_response","response":{"subtype":"success","request_id":"r1"}}`,
		`{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"s1","usage":{"input_tokens":1,"output_tokens":0}}`,
	)
	require.Equal(t, []string{EventUsage, EventTurnDone}, types(evs))
	assert.Equal(t, StatusInterrupted, evs[1].Status)

	// The flag is consumed: the next failed turn is a real error again.
	evs = feedAll(t, tr, `{"type":"result","subtype":"error_during_execution","is_error":true,"result":"","session_id":"s1"}`)
	require.Equal(t, []string{EventUsage, EventError}, types(evs))
}

func TestClaudeTranslator_ErrorResultIsClassified(t *testing.T) {
	tr := NewClaudeTranslator(fixedTurn("t9"))
	evs := feedAll(t, tr, `{"type":"result","subtype":"success","is_error":true,"result":"API Error: 429 rate_limit_error","session_id":"s1"}`)
	require.Equal(t, []string{EventUsage, EventError}, types(evs))
	assert.Equal(t, "t9", evs[1].TurnID, "a turn error carries its turn id, so it is terminal")
	assert.Equal(t, CodeRateLimit, evs[1].Code)
	assert.True(t, evs[1].Retryable)
}

func TestClaudeTranslator_SubagentEventsIgnored(t *testing.T) {
	tr := NewClaudeTranslator(fixedTurn("t1"))
	evs := feedAll(t, tr,
		`{"type":"stream_event","parent_tool_use_id":"toolu_parent","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"inner"}}}`)
	assert.Empty(t, evs)
}

func TestClaudeTranslator_BadLineIsAnError(t *testing.T) {
	tr := NewClaudeTranslator(fixedTurn("t1"))
	_, err := tr.Feed([]byte(`not json`))
	assert.Error(t, err)
	evs, err := tr.Feed([]byte("   "))
	assert.NoError(t, err)
	assert.Empty(t, evs)
}

func TestClassifyClaudeError(t *testing.T) {
	cases := []struct {
		msg       string
		code      string
		retryable bool
	}{
		{"No conversation found with session ID: 0000", CodeSessionLost, false},
		{"Invalid API key · Please run /login", CodeAuth, false},
		{"API Error: 401 authentication_error", CodeAuth, false},
		{"API Error: 429 rate_limit_error", CodeRateLimit, true},
		{"Claude AI usage limit reached|1760000000", CodeRateLimit, true},
		{"API Error: 529 overloaded_error", CodeRateLimit, true},
		{`exec: "claude": executable file not found in $PATH`, CodeProviderUnavailable, true},
		{"issue PROJ-4291 is blocked", CodeInternal, true},
		{"something odd", CodeInternal, true},
	}
	for _, c := range cases {
		code, retry := ClassifyClaudeError(c.msg)
		assert.Equal(t, c.code, code, c.msg)
		assert.Equal(t, c.retryable, retry, c.msg)
	}
}

// readFixture returns the non-empty lines of a recorded fixture.
func readFixture(t *testing.T, name string) []string {
	t.Helper()
	f, err := os.Open(filepath.Join("testdata", name))
	require.NoError(t, err, "record fixtures with testdata/record_fixtures.sh")
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64<<10), 16<<20)
	var out []string
	for sc.Scan() {
		if strings.TrimSpace(sc.Text()) != "" {
			out = append(out, sc.Text())
		}
	}
	require.NoError(t, sc.Err())
	return out
}

func TestClaudeTranslator_RecordedFixtures(t *testing.T) {
	t.Run("text", func(t *testing.T) {
		evs := feedAll(t, NewClaudeTranslator(fixedTurn("t1")), readFixture(t, "claude_text.jsonl")...)
		require.NotEmpty(t, evs)
		assert.Contains(t, types(evs), EventTextDelta)
		assert.NotContains(t, types(evs), EventError)
		last := evs[len(evs)-1]
		assert.Equal(t, EventTurnDone, last.Type)
		assert.Equal(t, StatusComplete, last.Status)
		assert.NotEmpty(t, last.SessionID)
	})
	t.Run("thinking", func(t *testing.T) {
		evs := feedAll(t, NewClaudeTranslator(fixedTurn("t1")), readFixture(t, "claude_thinking.jsonl")...)
		var text strings.Builder
		for _, e := range evs {
			if e.Type == EventTextDelta {
				text.WriteString(e.Text)
			}
		}
		assert.Contains(t, text.String(), "391", "the answer streams; the thinking does not")
		assert.Equal(t, EventTurnDone, evs[len(evs)-1].Type)
	})
	t.Run("tool", func(t *testing.T) {
		evs := feedAll(t, NewClaudeTranslator(fixedTurn("t1")), readFixture(t, "claude_tool.jsonl")...)
		var start, end *Event
		for i := range evs {
			switch evs[i].Type {
			case EventToolStart:
				start = &evs[i]
			case EventToolEnd:
				end = &evs[i]
			}
		}
		require.NotNil(t, start, "a tool_start was translated")
		require.NotNil(t, end, "a tool_end was translated")
		assert.Equal(t, "list_targets", start.Name)
		assert.Equal(t, start.ID, end.ID)
		require.NotNil(t, end.OK)
		assert.True(t, *end.OK)
		assert.Equal(t, StatusComplete, evs[len(evs)-1].Status)
	})
	t.Run("interrupt then second turn", func(t *testing.T) {
		turn := "t1"
		tr := NewClaudeTranslator(func() string { return turn })
		var dones []Event
		for _, l := range readFixture(t, "claude_interrupt.jsonl") {
			if strings.Contains(l, `"control_response"`) {
				tr.MarkInterrupted() // the backend marks it when it sends the request
			}
			evs, err := tr.Feed([]byte(l))
			require.NoError(t, err)
			for _, e := range evs {
				if e.Type == EventTurnDone {
					dones = append(dones, e)
					turn = "t2"
				}
			}
		}
		require.Len(t, dones, 2)
		assert.Equal(t, StatusInterrupted, dones[0].Status)
		assert.Equal(t, "t1", dones[0].TurnID)
		assert.Equal(t, StatusComplete, dones[1].Status)
		assert.Equal(t, "t2", dones[1].TurnID)
	})
	t.Run("resume missing is session_lost", func(t *testing.T) {
		stderr, err := os.ReadFile(filepath.Join("testdata", "claude_resume_missing.stderr"))
		require.NoError(t, err)
		lost := false
		if code, _ := ClassifyClaudeError(string(stderr)); code == CodeSessionLost {
			lost = true
		}
		stdout, err := os.ReadFile(filepath.Join("testdata", "claude_resume_missing.jsonl"))
		require.NoError(t, err)
		tr := NewClaudeTranslator(fixedTurn("t1"))
		for _, l := range strings.Split(string(stdout), "\n") {
			evs, err := tr.Feed([]byte(l))
			if err != nil {
				continue
			}
			for _, e := range evs {
				if e.Type == EventError && e.Code == CodeSessionLost {
					lost = true
				}
			}
		}
		assert.True(t, lost, "the recorded rejection must classify as session_lost — adjust ClassifyClaudeError's phrases to the recorded text")
	})
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `go test ./internal/chat/`
Expected: FAIL to compile — `undefined: NewEventWriter`, `undefined: NewClaudeTranslator`, etc.

- [ ] **Step 4: Write `events.go`**

Create `internal/chat/events.go`:

```go
// Package chat is the main AI Chat's engine: the protocol-v2 events a
// `watchtower ai session` process streams to the Desktop app, the translator
// from Claude's stream-json into those events, the system prompt, the replay
// transcript, and the session loop with its provider backends.
package chat

import (
	"encoding/json"
	"fmt"
	"io"
	"sync"
)

// Protocol v2 event types (spec §1.1). There is deliberately no "reset":
// text already shown is never wiped (CHAT-02).
const (
	EventSessionReady = "session_ready"
	EventTurnStart    = "turn_start"
	EventTextDelta    = "text_delta"
	EventToolStart    = "tool_start"
	EventToolEnd      = "tool_end"
	EventUsage        = "usage"
	EventTurnDone     = "turn_done"
	EventError        = "error"
)

// turn_done statuses.
const (
	StatusComplete    = "complete"
	StatusInterrupted = "interrupted"
)

// Error codes (spec §5).
const (
	CodeAuth                  = "auth"
	CodeRateLimit             = "rate_limit"
	CodeProviderUnavailable   = "provider_unavailable"
	CodeSessionLost           = "session_lost"
	CodeAttachmentUnsupported = "attachment_unsupported"
	CodeInterrupted           = "interrupted"
	CodeInternal              = "internal"
)

// Commands read from stdin.
const (
	CommandTurn   = "turn"
	CommandCancel = "cancel"
	CommandClose  = "close"
)

// Event is one NDJSON line on the session's stdout.
type Event struct {
	Type      string          `json:"type"`
	TurnID    string          `json:"turn_id,omitempty"`
	Text      string          `json:"text,omitempty"`
	ID        string          `json:"id,omitempty"`
	Name      string          `json:"name,omitempty"`
	Args      json.RawMessage `json:"args,omitempty"`
	OK        *bool           `json:"ok,omitempty"`
	Summary   string          `json:"summary,omitempty"`
	Sources   []Source        `json:"sources,omitempty"`
	TokensIn  int             `json:"tokens_in,omitempty"`
	TokensOut int             `json:"tokens_out,omitempty"`
	Model     string          `json:"model,omitempty"`
	Provider  string          `json:"provider,omitempty"`
	SessionID string          `json:"session_id,omitempty"`
	Status    string          `json:"status,omitempty"`
	Code      string          `json:"code,omitempty"`
	Message   string          `json:"message,omitempty"`
	Retryable bool            `json:"retryable,omitempty"`
}

// Source is one source chip of a tool_end (spec §3.4).
type Source struct {
	Kind  string `json:"kind"`
	Title string `json:"title"`
	URL   string `json:"url,omitempty"`
	Ref   string `json:"ref"`
}

// Attachment is a file the owner attached to a turn. Its path travels on
// stdin inside the turn command, never on argv (CHAT-04).
type Attachment struct {
	Path string `json:"path"`
	Mime string `json:"mime"`
	Name string `json:"name"`
}

// Command is one JSONL line on the session's stdin.
type Command struct {
	Type        string       `json:"type"`
	TurnID      string       `json:"turn_id,omitempty"`
	Text        string       `json:"text,omitempty"`
	Attachments []Attachment `json:"attachments,omitempty"`
	Replay      bool         `json:"replay,omitempty"`
}

// errorEvent builds an error event. A non-empty turnID makes it the turn's
// terminal event.
func errorEvent(turnID, code, msg string, retryable bool) Event {
	return Event{Type: EventError, TurnID: turnID, Code: code, Message: msg, Retryable: retryable}
}

// isTerminal reports whether e ends its turn: every turn ends with exactly one
// turn_done or one turn-scoped error.
func isTerminal(e Event) bool {
	return e.Type == EventTurnDone || (e.Type == EventError && e.TurnID != "")
}

// EventWriter writes events as NDJSON, one line per event. Safe for
// concurrent use; each event is a single Write, so lines never interleave.
type EventWriter struct {
	mu sync.Mutex
	w  io.Writer
}

// NewEventWriter wraps w.
func NewEventWriter(w io.Writer) *EventWriter { return &EventWriter{w: w} }

// Emit writes one event line.
func (w *EventWriter) Emit(e Event) error {
	b, err := json.Marshal(e)
	if err != nil {
		return fmt.Errorf("encoding %s event: %w", e.Type, err)
	}
	b = append(b, '\n')
	w.mu.Lock()
	defer w.mu.Unlock()
	_, err = w.w.Write(b)
	return err
}
```

- [ ] **Step 5: Write the minimal `sources.go`**

Create `internal/chat/sources.go` (Task 3 replaces `SummarizeToolResult`'s body):

```go
package chat

import (
	"strings"
	"unicode/utf8"
)

// SummaryMaxRunes caps a tool_end summary (spec §1.1).
const SummaryMaxRunes = 300

// SummarizeToolResult turns a tool's raw result into a one-line summary and
// the sources it cites. name is the display name (no mcp__watchtower__ prefix).
func SummarizeToolResult(name, result string) (string, []Source) {
	_ = name
	return truncateRunes(collapseSpace(result), SummaryMaxRunes), nil
}

// collapseSpace folds every run of whitespace into one space and trims.
func collapseSpace(s string) string { return strings.Join(strings.Fields(s), " ") }

// truncateRunes cuts s to at most n runes, ending with "…" when cut.
func truncateRunes(s string, n int) string {
	if n <= 0 {
		return ""
	}
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	r := []rune(s)
	return string(r[:n-1]) + "…"
}
```

- [ ] **Step 6: Write the translator**

Create `internal/chat/claude_translate.go`:

```go
package chat

import (
	"bytes"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"sync"
)

// claudeLine is the union of the stream-json line shapes the translator reads.
type claudeLine struct {
	Type            string          `json:"type"`
	Subtype         string          `json:"subtype"`
	SessionID       string          `json:"session_id"`
	IsError         bool            `json:"is_error"`
	Result          string          `json:"result"`
	Usage           *claudeUsage    `json:"usage"`
	Event           *claudeStreamEv `json:"event"`
	Message         *claudeMessage  `json:"message"`
	ParentToolUseID *string         `json:"parent_tool_use_id"`
}

type claudeUsage struct {
	InputTokens   int `json:"input_tokens"`
	OutputTokens  int `json:"output_tokens"`
	CacheRead     int `json:"cache_read_input_tokens"`
	CacheCreation int `json:"cache_creation_input_tokens"`
}

type claudeStreamEv struct {
	Type         string         `json:"type"`
	Index        int            `json:"index"`
	ContentBlock *claudeBlock   `json:"content_block"`
	Delta        *claudeDelta   `json:"delta"`
	Message      *claudeMessage `json:"message"`
}

type claudeBlock struct {
	Type string `json:"type"`
	ID   string `json:"id"`
	Name string `json:"name"`
}

type claudeDelta struct {
	Type        string `json:"type"`
	Text        string `json:"text"`
	PartialJSON string `json:"partial_json"`
}

type claudeMessage struct {
	Model   string          `json:"model"`
	Content json.RawMessage `json:"content"`
}

type claudeContent struct {
	Type      string          `json:"type"`
	ToolUseID string          `json:"tool_use_id"`
	Content   json.RawMessage `json:"content"`
	IsError   bool            `json:"is_error"`
}

// blocks decodes the message content leniently: a plain-string content (or an
// unknown shape) yields no blocks rather than failing the line.
func (m *claudeMessage) blocks() []claudeContent {
	if m == nil || len(m.Content) == 0 {
		return nil
	}
	var out []claudeContent
	if err := json.Unmarshal(m.Content, &out); err != nil {
		return nil
	}
	return out
}

type pendingBlock struct {
	kind, id, name string
	args           strings.Builder
}

// ClaudeTranslator maps `claude --output-format stream-json
// --include-partial-messages` lines onto protocol-v2 events:
// text_delta per token, tool_start when a tool_use block closes (with its
// accumulated input JSON), tool_end per tool_result, usage + turn_done (or a
// turn error) per result. Thinking blocks, full assistant messages and
// subagent events are dropped. Safe for concurrent use: the backend feeds it
// from its reader goroutine and marks interrupts from Cancel.
type ClaudeTranslator struct {
	turnID func() string

	mu          sync.Mutex
	blocks      map[int]*pendingBlock
	toolNames   map[string]string // tool_use id → display name
	model       string
	sessionID   string
	interrupted bool
}

// NewClaudeTranslator returns a translator stamping events with turnID().
func NewClaudeTranslator(turnID func() string) *ClaudeTranslator {
	return &ClaudeTranslator{turnID: turnID, blocks: map[int]*pendingBlock{}, toolNames: map[string]string{}}
}

// MarkInterrupted records that an interrupt was requested for the running
// turn, so its error_during_execution result ends it as "interrupted".
func (t *ClaudeTranslator) MarkInterrupted() {
	t.mu.Lock()
	t.interrupted = true
	t.mu.Unlock()
}

// SessionID is the most recent Claude session id seen on any line.
func (t *ClaudeTranslator) SessionID() string {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.sessionID
}

// Feed translates one stdout line. A blank line yields nothing; a line that
// is not JSON is an error the caller may log and skip.
func (t *ClaudeTranslator) Feed(line []byte) ([]Event, error) {
	line = bytes.TrimSpace(line)
	if len(line) == 0 {
		return nil, nil
	}
	var l claudeLine
	if err := json.Unmarshal(line, &l); err != nil {
		return nil, fmt.Errorf("decoding claude stream line: %w", err)
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if l.SessionID != "" {
		t.sessionID = l.SessionID
	}
	switch l.Type {
	case "stream_event":
		if l.Event == nil || (l.ParentToolUseID != nil && *l.ParentToolUseID != "") {
			return nil, nil
		}
		return t.streamEvent(l.Event), nil
	case "user":
		return t.toolResults(l.Message), nil
	case "result":
		return t.result(l), nil
	}
	return nil, nil
}

func (t *ClaudeTranslator) streamEvent(ev *claudeStreamEv) []Event {
	switch ev.Type {
	case "message_start":
		t.blocks = map[int]*pendingBlock{}
		if ev.Message != nil && ev.Message.Model != "" {
			t.model = ev.Message.Model
		}
	case "content_block_start":
		if ev.ContentBlock != nil {
			t.blocks[ev.Index] = &pendingBlock{kind: ev.ContentBlock.Type, id: ev.ContentBlock.ID, name: ev.ContentBlock.Name}
		}
	case "content_block_delta":
		if ev.Delta == nil {
			return nil
		}
		switch ev.Delta.Type {
		case "text_delta":
			if ev.Delta.Text != "" {
				return []Event{{Type: EventTextDelta, TurnID: t.turnID(), Text: ev.Delta.Text}}
			}
		case "input_json_delta":
			if b := t.blocks[ev.Index]; b != nil {
				b.args.WriteString(ev.Delta.PartialJSON)
			}
		}
	case "content_block_stop":
		b := t.blocks[ev.Index]
		delete(t.blocks, ev.Index)
		if b == nil || b.kind != "tool_use" {
			return nil
		}
		name := displayToolName(b.name)
		t.toolNames[b.id] = name
		return []Event{{Type: EventToolStart, TurnID: t.turnID(), ID: b.id, Name: name, Args: toolArgs(b.args.String())}}
	}
	return nil
}

func (t *ClaudeTranslator) toolResults(m *claudeMessage) []Event {
	var out []Event
	for _, c := range m.blocks() {
		if c.Type != "tool_result" {
			continue
		}
		text := toolResultText(c.Content)
		ok := !c.IsError
		var summary string
		var sources []Source
		if ok {
			summary, sources = SummarizeToolResult(t.toolNames[c.ToolUseID], text)
		} else {
			summary = truncateRunes(collapseSpace(text), SummaryMaxRunes)
		}
		out = append(out, Event{Type: EventToolEnd, TurnID: t.turnID(), ID: c.ToolUseID, OK: &ok,
			Summary: summary, Sources: sources})
	}
	return out
}

func (t *ClaudeTranslator) result(l claudeLine) []Event {
	turnID := t.turnID()
	interrupted := t.interrupted
	t.interrupted = false
	usage := Event{Type: EventUsage, TurnID: turnID, Model: t.model}
	if l.Usage != nil {
		usage.TokensIn = l.Usage.InputTokens + l.Usage.CacheRead + l.Usage.CacheCreation
		usage.TokensOut = l.Usage.OutputTokens
	}
	switch {
	case l.Subtype == "success" && !l.IsError:
		return []Event{usage, {Type: EventTurnDone, TurnID: turnID, Status: StatusComplete, SessionID: t.sessionID}}
	case interrupted:
		return []Event{usage, {Type: EventTurnDone, TurnID: turnID, Status: StatusInterrupted, SessionID: t.sessionID}}
	default:
		msg := strings.TrimSpace(l.Result)
		if msg == "" {
			msg = "claude turn failed: " + l.Subtype
		}
		code, retry := ClassifyClaudeError(msg)
		return []Event{usage, errorEvent(turnID, code, msg, retry)}
	}
}

// displayToolName strips the built-in server prefix and renders an external
// MCP tool as server:tool (spec §1.1).
func displayToolName(raw string) string {
	if n, ok := strings.CutPrefix(raw, "mcp__watchtower__"); ok {
		return n
	}
	if rest, ok := strings.CutPrefix(raw, "mcp__"); ok {
		if server, tool, ok := strings.Cut(rest, "__"); ok {
			return server + ":" + tool
		}
	}
	return raw
}

// toolArgs returns the accumulated tool input as JSON: {} when empty, the
// input itself when valid, otherwise {"_raw": "<text>"} so an event never
// carries invalid JSON.
func toolArgs(s string) json.RawMessage {
	s = strings.TrimSpace(s)
	if s == "" {
		return json.RawMessage(`{}`)
	}
	if json.Valid([]byte(s)) {
		return json.RawMessage(s)
	}
	b, _ := json.Marshal(map[string]string{"_raw": s})
	return b
}

// toolResultText flattens a tool_result's content: a string, or the text
// parts of a content-block array.
func toolResultText(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var s string
	if err := json.Unmarshal(raw, &s); err == nil {
		return s
	}
	var parts []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if err := json.Unmarshal(raw, &parts); err != nil {
		return ""
	}
	var b strings.Builder
	for _, p := range parts {
		if p.Type == "text" {
			b.WriteString(p.Text)
		}
	}
	return b.String()
}

var httpStatusRe = regexp.MustCompile(`\b(401|403|429|529)\b`)

// ClassifyClaudeError maps a provider error message onto a spec §5 code.
// Order matters: a rejected --resume is session_lost even if it also says
// "error"; an HTTP status is matched as a whole word so an issue key like
// PROJ-4291 is never mistaken for a 429.
func ClassifyClaudeError(msg string) (code string, retryable bool) {
	m := strings.ToLower(msg)
	status := httpStatusRe.FindString(m)
	switch {
	case containsAny(m, "no conversation found", "session not found", "could not find session"):
		return CodeSessionLost, false
	case status == "401" || status == "403" ||
		containsAny(m, "not logged in", "/login", "invalid api key", "authentication_error", "oauth token has expired"):
		return CodeAuth, false
	case status == "429" || status == "529" ||
		containsAny(m, "rate limit", "rate_limit", "usage limit", "overloaded"):
		return CodeRateLimit, true
	case containsAny(m, "executable file not found", "cli not found", "no such file or directory"):
		return CodeProviderUnavailable, true
	}
	return CodeInternal, true
}

func containsAny(s string, subs ...string) bool {
	for _, sub := range subs {
		if strings.Contains(s, sub) {
			return true
		}
	}
	return false
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `go test ./internal/chat/`
Expected: PASS. If `TestClaudeTranslator_RecordedFixtures/…` fails, read the fixture: the recorded CLI may name an event differently — fix the translator (never the fixture), re-run.

- [ ] **Step 8: Commit**

```bash
git add internal/chat/events.go internal/chat/claude_translate.go internal/chat/sources.go \
  internal/chat/testmain_test.go internal/chat/events_test.go internal/chat/claude_translate_test.go \
  internal/chat/testdata/record_fixtures.sh internal/chat/testdata/claude_text.jsonl \
  internal/chat/testdata/claude_thinking.jsonl internal/chat/testdata/claude_tool.jsonl \
  internal/chat/testdata/claude_interrupt.jsonl internal/chat/testdata/claude_resume_missing.jsonl \
  internal/chat/testdata/claude_resume_missing.stderr
git commit -m "feat(chat): protocol v2 events and Claude stream-json translator" \
  -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Source extraction + summaries

**Files:**
- Modify: `internal/chat/sources.go` (replace `SummarizeToolResult`)
- Create: `internal/chat/sources_test.go`

**Interfaces:**
- Consumes: Task 2 `Source`, `truncateRunes`, `collapseSpace`, `SummaryMaxRunes`.
- Produces (binding): `func SummarizeToolResult(name string, result string) (summary string, sources []Source)` — summary ≤ 300 runes; sources ≤ 10, deduplicated by `URL` (or `Ref` when there is no URL); `const MaxSources = 10`. Source kinds: `slack`, `jira`, `email`, `meeting`, `document`, `person`. Refs: `jira:<KEY>`, `slack:<channel>:<ts>`, `transcript:<id>`, `person:<user_id>`, `digest:<id>`, `target:<id>`, and the knowledge ref verbatim for `search_knowledge`/`get_knowledge_document`.

- [ ] **Step 1: Write the failing tests**

Create `internal/chat/sources_test.go`:

```go
package chat

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestSummarizeToolResult_PerTool(t *testing.T) {
	cases := []struct {
		name, tool, result string
		summary            string
		sources            []Source
	}{
		{
			name: "search_knowledge hits",
			tool: "search_knowledge",
			result: `{"hits":[
				{"ref":"slack:1:C1:100.1","source":"slack","title":"#payments thread","link":"https://acme.slack.com/archives/C1/p1001"},
				{"ref":"jira:PAY-7","source":"jira","title":"PAY-7 Refund flow"},
				{"ref":"gmail:1:t9","source":"gmail","title":"Re: vendor contract"},
				{"ref":"transcript:4","source":"transcript","title":"Weekly sync"},
				{"ref":"digest:9","source":"digest","title":"Daily digest"}]}`,
			summary: "5 results: #payments thread; PAY-7 Refund flow; Re: vendor contract",
			sources: []Source{
				{Kind: "slack", Title: "#payments thread", URL: "https://acme.slack.com/archives/C1/p1001", Ref: "slack:1:C1:100.1"},
				{Kind: "jira", Title: "PAY-7 Refund flow", Ref: "jira:PAY-7"},
				{Kind: "email", Title: "Re: vendor contract", Ref: "gmail:1:t9"},
				{Kind: "meeting", Title: "Weekly sync", Ref: "transcript:4"},
				{Kind: "document", Title: "Daily digest", Ref: "digest:9"},
			},
		},
		{
			name:    "get_knowledge_document",
			tool:    "get_knowledge_document",
			result:  `{"ref":"jira:PAY-7","source":"jira","title":"PAY-7 Refund flow","link":"","text":"long body"}`,
			summary: "Opened PAY-7 Refund flow",
			sources: []Source{{Kind: "jira", Title: "PAY-7 Refund flow", Ref: "jira:PAY-7"}},
		},
		{
			name:    "get_jira_issue (Go field names, no json tags)",
			tool:    "get_jira_issue",
			result:  `{"Key":"PAY-7","Summary":"Refund flow","Status":"In Progress"}`,
			summary: "Opened PAY-7: Refund flow (In Progress)",
			sources: []Source{{Kind: "jira", Title: "PAY-7: Refund flow", Ref: "jira:PAY-7"}},
		},
		{
			name:    "list_jira_issues",
			tool:    "list_jira_issues",
			result:  `[{"Key":"PAY-1","Summary":"A"},{"Key":"PAY-2","Summary":"B"}]`,
			summary: "2 issues: PAY-1, PAY-2",
			sources: []Source{{Kind: "jira", Title: "PAY-1: A", Ref: "jira:PAY-1"}, {Kind: "jira", Title: "PAY-2: B", Ref: "jira:PAY-2"}},
		},
		{
			name:    "list_messages",
			tool:    "list_messages",
			result:  `[{"ts":"100.1","channel":"payments","sender":"Ann","text":"shipped","permalink":"https://acme.slack.com/archives/C1/p1001"}]`,
			summary: "1 messages",
			sources: []Source{{Kind: "slack", Title: "#payments · Ann", URL: "https://acme.slack.com/archives/C1/p1001", Ref: "slack:payments:100.1"}},
		},
		{
			name:    "get_transcript",
			tool:    "get_transcript",
			result:  `{"id":4,"title":"Weekly sync","transcript_text":"..."}`,
			summary: "Opened Weekly sync",
			sources: []Source{{Kind: "meeting", Title: "Weekly sync", Ref: "transcript:4"}},
		},
		{
			name:    "get_person",
			tool:    "get_person",
			result:  `{"UserID":"1:U42","Summary":"Leads payments"}`,
			summary: "Opened person 1:U42",
			sources: []Source{{Kind: "person", Title: "1:U42", Ref: "person:1:U42"}},
		},
		{
			name:    "get_digest",
			tool:    "get_digest",
			result:  `{"ID":9,"Type":"daily","Summary":"Quiet day"}`,
			summary: "Opened daily digest #9",
			sources: []Source{{Kind: "document", Title: "daily digest #9", Ref: "digest:9"}},
		},
		{
			name:    "get_target",
			tool:    "get_target",
			result:  `{"ID":3,"Text":"Ship refunds"}`,
			summary: "Opened target: Ship refunds",
			sources: []Source{{Kind: "document", Title: "Ship refunds", Ref: "target:3"}},
		},
		{
			name:    "unknown tool yields no sources",
			tool:    "confluence:search",
			result:  "  plain\n\ntext   result ",
			summary: "plain text result",
		},
		{
			name:    "known tool with malformed JSON falls back to the text",
			tool:    "search_knowledge",
			result:  "not json at all",
			summary: "not json at all",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			summary, sources := SummarizeToolResult(c.tool, c.result)
			assert.Equal(t, c.summary, summary)
			assert.Equal(t, c.sources, sources)
		})
	}
}

func TestSummarizeToolResult_DedupesSources(t *testing.T) {
	_, sources := SummarizeToolResult("search_knowledge", `{"hits":[
		{"ref":"a","source":"slack","title":"one","link":"https://x/1"},
		{"ref":"b","source":"slack","title":"one again","link":"https://x/1"},
		{"ref":"c","source":"jira","title":"c"},
		{"ref":"c","source":"jira","title":"c again"}]}`)
	require.Len(t, sources, 2, "same URL, or same ref when there is no URL, is one chip")
}

// TestSummarizeToolResult_HugeResultIsBounded: a 200 KB tool result must still
// produce a ≤300-rune summary and ≤10 sources (Review Focus 3).
func TestSummarizeToolResult_HugeResultIsBounded(t *testing.T) {
	type msg struct {
		TS        string `json:"ts"`
		Channel   string `json:"channel"`
		Sender    string `json:"sender"`
		Text      string `json:"text"`
		Permalink string `json:"permalink"`
	}
	var msgs []msg
	for i := 0; i < 600; i++ {
		msgs = append(msgs, msg{TS: fmt.Sprintf("%d.1", i), Channel: "general", Sender: "Ann",
			Text: strings.Repeat("платёж ", 40), Permalink: fmt.Sprintf("https://acme.slack.com/p%d", i)})
	}
	b, err := json.Marshal(msgs)
	require.NoError(t, err)
	require.Greater(t, len(b), 200_000)

	summary, sources := SummarizeToolResult("list_messages", string(b))
	assert.LessOrEqual(t, utf8.RuneCountInString(summary), SummaryMaxRunes)
	assert.Len(t, sources, MaxSources)

	summary, sources = SummarizeToolResult("some_unknown_tool", strings.Repeat("Кириллица ", 30_000))
	assert.LessOrEqual(t, utf8.RuneCountInString(summary), SummaryMaxRunes, "runes, not bytes")
	assert.True(t, utf8.ValidString(summary), "never cuts a multi-byte rune in half")
	assert.Empty(t, sources)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `go test ./internal/chat/ -run TestSummarizeToolResult`
Expected: FAIL — `undefined: MaxSources`, then summaries/sources mismatch.

- [ ] **Step 3: Implement the per-tool extraction**

Replace the whole of `internal/chat/sources.go` with:

```go
package chat

import (
	"encoding/json"
	"fmt"
	"strings"
	"unicode/utf8"
)

// SummaryMaxRunes caps a tool_end summary (spec §1.1).
const SummaryMaxRunes = 300

// MaxSources caps the source chips one tool_end carries.
const MaxSources = 10

// SummarizeToolResult turns a read tool's raw result into a one-line summary
// and the sources it cites (spec §3.4). name is the display name (no
// mcp__watchtower__ prefix). Known read tools get a structured summary and
// chips; an unknown tool, or a result that does not parse, falls back to the
// collapsed text and no chips. The summary is at most SummaryMaxRunes runes and
// there are at most MaxSources chips, deduplicated by URL (or ref).
func SummarizeToolResult(name, result string) (string, []Source) {
	extract, ok := sourceExtractors[name]
	var summary string
	var sources []Source
	if ok {
		summary, sources = extract([]byte(result))
	}
	if summary == "" {
		summary = collapseSpace(result)
	}
	return truncateRunes(summary, SummaryMaxRunes), capSources(sources)
}

// sourceExtractors maps a read tool to its parser. Each parser returns ("",
// nil) when the result does not match its shape. Struct fields without json
// tags match the tools' untagged db structs (encoding/json matches field
// names case-insensitively).
var sourceExtractors = map[string]func([]byte) (string, []Source){
	"search_knowledge":       knowledgeHitSources,
	"get_knowledge_document": knowledgeDocSource,
	"get_jira_issue":         jiraIssueSource,
	"list_jira_issues":       jiraIssueListSources,
	"list_messages":          slackMessageSources,
	"get_transcript":         transcriptSource,
	"get_person":             personSource,
	"get_digest":             digestSource,
	"get_target":             targetSource,
}

type kbDoc struct {
	Ref, Source, Title, Link string
}

// kbKind maps a knowledge-index source onto a chip kind.
func kbKind(source string) string {
	switch source {
	case "slack":
		return "slack"
	case "gmail", "imap":
		return "email"
	case "jira":
		return "jira"
	case "calendar", "transcript", "recap":
		return "meeting"
	default:
		return "document"
	}
}

func (d kbDoc) source() Source {
	return Source{Kind: kbKind(d.Source), Title: d.Title, URL: d.Link, Ref: d.Ref}
}

func knowledgeHitSources(raw []byte) (string, []Source) {
	var r struct{ Hits []kbDoc }
	if json.Unmarshal(raw, &r) != nil {
		return "", nil
	}
	sources := make([]Source, 0, len(r.Hits))
	titles := make([]string, 0, 3)
	for _, h := range r.Hits {
		sources = append(sources, h.source())
		if len(titles) < 3 && h.Title != "" {
			titles = append(titles, h.Title)
		}
	}
	summary := fmt.Sprintf("%d results", len(r.Hits))
	if len(titles) > 0 {
		summary += ": " + strings.Join(titles, "; ")
	}
	return summary, sources
}

func knowledgeDocSource(raw []byte) (string, []Source) {
	var d kbDoc
	if json.Unmarshal(raw, &d) != nil || d.Ref == "" {
		return "", nil
	}
	return "Opened " + d.Title, []Source{d.source()}
}

type jiraIssueView struct{ Key, Summary, Status string }

func (j jiraIssueView) source() Source {
	return Source{Kind: "jira", Title: j.Key + ": " + j.Summary, Ref: "jira:" + j.Key}
}

func jiraIssueSource(raw []byte) (string, []Source) {
	var j jiraIssueView
	if json.Unmarshal(raw, &j) != nil || j.Key == "" {
		return "", nil
	}
	summary := "Opened " + j.Key + ": " + j.Summary
	if j.Status != "" {
		summary += " (" + j.Status + ")"
	}
	return summary, []Source{j.source()}
}

func jiraIssueListSources(raw []byte) (string, []Source) {
	var list []jiraIssueView
	if json.Unmarshal(raw, &list) != nil {
		return "", nil
	}
	keys := make([]string, 0, len(list))
	sources := make([]Source, 0, len(list))
	for _, j := range list {
		keys = append(keys, j.Key)
		sources = append(sources, j.source())
	}
	return fmt.Sprintf("%d issues: %s", len(list), strings.Join(keys, ", ")), sources
}

func slackMessageSources(raw []byte) (string, []Source) {
	var list []struct {
		TS                         string `json:"ts"`
		Channel, Sender, Permalink string
	}
	if json.Unmarshal(raw, &list) != nil {
		return "", nil
	}
	sources := make([]Source, 0, len(list))
	for _, m := range list {
		ch := strings.TrimPrefix(m.Channel, "#")
		sources = append(sources, Source{Kind: "slack", Title: "#" + ch + " · " + m.Sender, URL: m.Permalink,
			Ref: "slack:" + ch + ":" + m.TS})
	}
	return fmt.Sprintf("%d messages", len(list)), sources
}

func transcriptSource(raw []byte) (string, []Source) {
	var tr struct {
		ID    int64
		Title string
	}
	if json.Unmarshal(raw, &tr) != nil || tr.ID == 0 {
		return "", nil
	}
	return "Opened " + tr.Title, []Source{{Kind: "meeting", Title: tr.Title, Ref: fmt.Sprintf("transcript:%d", tr.ID)}}
}

func personSource(raw []byte) (string, []Source) {
	var p struct{ UserID string }
	if json.Unmarshal(raw, &p) != nil || p.UserID == "" {
		return "", nil
	}
	return "Opened person " + p.UserID, []Source{{Kind: "person", Title: p.UserID, Ref: "person:" + p.UserID}}
}

func digestSource(raw []byte) (string, []Source) {
	var d struct {
		ID   int64
		Type string
	}
	if json.Unmarshal(raw, &d) != nil || d.ID == 0 {
		return "", nil
	}
	title := fmt.Sprintf("%s digest #%d", d.Type, d.ID)
	return "Opened " + title, []Source{{Kind: "document", Title: title, Ref: fmt.Sprintf("digest:%d", d.ID)}}
}

func targetSource(raw []byte) (string, []Source) {
	var tg struct {
		ID   int64
		Text string
	}
	if json.Unmarshal(raw, &tg) != nil || tg.ID == 0 {
		return "", nil
	}
	return "Opened target: " + tg.Text, []Source{{Kind: "document", Title: tg.Text, Ref: fmt.Sprintf("target:%d", tg.ID)}}
}

// capSources drops duplicates (same URL, or same ref when there is no URL)
// and keeps at most MaxSources, in order. Returns nil for none.
func capSources(in []Source) []Source {
	var out []Source
	seen := map[string]bool{}
	for _, s := range in {
		key := s.URL
		if key == "" {
			key = "ref:" + s.Ref
		}
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, s)
		if len(out) == MaxSources {
			break
		}
	}
	return out
}

// collapseSpace folds every run of whitespace into one space and trims.
func collapseSpace(s string) string { return strings.Join(strings.Fields(s), " ") }

// truncateRunes cuts s to at most n runes, ending with "…" when cut.
func truncateRunes(s string, n int) string {
	if n <= 0 {
		return ""
	}
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	r := []rune(s)
	return string(r[:n-1]) + "…"
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `go test ./internal/chat/`
Expected: PASS (the translator tests from Task 2 still pass; `TestChat02_ToolCallNeverWipesText`'s `{"hits":[]}` now summarizes to `0 results`).

- [ ] **Step 5: Commit**

```bash
git add internal/chat/sources.go internal/chat/sources_test.go
git commit -m "feat(chat): per-tool source chips and bounded tool summaries" \
  -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Replay builder

**Files:**
- Create: `internal/chat/replay.go`
- Create: `internal/chat/replay_test.go`

**Interfaces:**
- Consumes: Task 1 `db.ChatMessage`; Task 2 `truncateRunes`.
- Produces (binding): `const ReplayCapChars = 24000`; `func BuildReplay(path []db.ChatMessage, capChars int) string`. Also `func BuildReplaySteps(path []db.ChatMessage, steps map[int64][]string, capChars int) string` (steps keyed by message id, the `db.ChatStepSummaries` shape) and `func HistoryBefore(path []db.ChatMessage, turnID string) []db.ChatMessage` (drops the trailing rows of the current turn). Output: `""` for an empty path; otherwise a block opening with `replayHeader`, then `[N earlier messages omitted]` when truncated, one `Owner:`/`Assistant:`/`System:` entry per message, tool steps as `  · step: <line>`, closing with `replayFooter` and a blank line — so the caller prepends it to the turn text.

- [ ] **Step 1: Write the failing tests**

Create `internal/chat/replay_test.go`:

```go
package chat

import (
	"database/sql"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/stretchr/testify/assert"

	"watchtower/internal/db"
)

func msg(id int64, role, text, turn string) db.ChatMessage {
	return db.ChatMessage{ID: id, Role: role, Text: text, TurnID: turn, Status: "complete",
		ParentID: sql.NullInt64{Int64: id - 1, Valid: id > 1}}
}

func TestBuildReplay_Empty(t *testing.T) {
	assert.Equal(t, "", BuildReplay(nil, ReplayCapChars))
}

func TestBuildReplay_RendersRolesAndFrame(t *testing.T) {
	out := BuildReplay([]db.ChatMessage{
		msg(1, "user", "What slipped?", "t1"),
		msg(2, "assistant", "The refunds launch.", "t1"),
		msg(3, "system", "Action applied: created target", ""),
	}, ReplayCapChars)
	assert.True(t, strings.HasPrefix(out, replayHeader+"\n"))
	assert.True(t, strings.HasSuffix(out, replayFooter+"\n\n"), "the caller prepends it to the turn text")
	assert.Contains(t, out, "Owner: What slipped?\n")
	assert.Contains(t, out, "Assistant: The refunds launch.\n")
	assert.Contains(t, out, "System: Action applied: created target\n")
	assert.NotContains(t, out, "omitted")
}

func TestBuildReplay_MarksStoppedAnswers(t *testing.T) {
	m := msg(2, "assistant", "Half an answer", "t1")
	m.Status = "partial"
	out := BuildReplay([]db.ChatMessage{msg(1, "user", "q", "t1"), m}, ReplayCapChars)
	assert.Contains(t, out, "Assistant (stopped early): Half an answer")
}

func TestBuildReplaySteps_OneLinePerStep(t *testing.T) {
	out := BuildReplaySteps([]db.ChatMessage{msg(1, "user", "q", "t1"), msg(2, "assistant", "a", "t1")},
		map[int64][]string{2: {"search_knowledge: 3 results", "get_jira_issue (failed): no such issue"}}, ReplayCapChars)
	assert.Contains(t, out, "Assistant: a\n  · step: search_knowledge: 3 results\n  · step: get_jira_issue (failed): no such issue\n")
}

func TestBuildReplay_CapKeepsNewestAndCountsOmitted(t *testing.T) {
	var path []db.ChatMessage
	for i := int64(1); i <= 10; i++ {
		path = append(path, msg(i, "user", strings.Repeat("x", 90)+string(rune('a'+i-1)), "t"))
	}
	out := BuildReplay(path, 300) // each entry ≈ 98 runes + newline → three fit
	assert.Contains(t, out, "[7 earlier messages omitted]")
	assert.Contains(t, out, strings.Repeat("x", 90)+"j", "the newest message is kept")
	assert.NotContains(t, out, strings.Repeat("x", 90)+"g")
}

func TestBuildReplay_SingleHugeMessageIsTruncatedNotDropped(t *testing.T) {
	out := BuildReplay([]db.ChatMessage{msg(1, "user", strings.Repeat("я", 50_000), "t")}, ReplayCapChars)
	body := strings.TrimSuffix(strings.TrimPrefix(out, replayHeader+"\n"), replayFooter+"\n\n")
	assert.LessOrEqual(t, utf8.RuneCountInString(body), ReplayCapChars+1)
	assert.Contains(t, out, "Owner: яяя")
	assert.True(t, utf8.ValidString(out))
}

func TestHistoryBefore_DropsTheCurrentTurn(t *testing.T) {
	path := []db.ChatMessage{msg(1, "user", "a", "t1"), msg(2, "assistant", "b", "t1"), msg(3, "user", "c", "t2")}
	assert.Len(t, HistoryBefore(path, "t2"), 2, "the user message persisted before the turn is not replayed twice")
	assert.Len(t, HistoryBefore(path, "t9"), 3)
	assert.Len(t, HistoryBefore(path, ""), 3)
	assert.Empty(t, HistoryBefore([]db.ChatMessage{msg(1, "user", "c", "t2")}, "t2"))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `go test ./internal/chat/ -run 'TestBuildReplay|TestHistoryBefore'`
Expected: FAIL to compile — `undefined: BuildReplay`.

- [ ] **Step 3: Implement the replay builder**

Create `internal/chat/replay.go`:

```go
package chat

import (
	"fmt"
	"strings"
	"unicode/utf8"

	"watchtower/internal/db"
)

// ReplayCapChars bounds the replayed history (spec §2.4), in runes.
const ReplayCapChars = 24000

const (
	replayHeader = "=== CONVERSATION SO FAR (replayed from Watchtower's history; the earlier model session is not available) ==="
	replayFooter = "=== END OF CONVERSATION SO FAR — the owner's new message follows ==="
)

// HistoryBefore returns path without the trailing messages of turnID. The
// owner's message is persisted before the turn is sent (CHAT-01), so the
// active path already ends with it; replaying it and then sending it again
// would duplicate it.
func HistoryBefore(path []db.ChatMessage, turnID string) []db.ChatMessage {
	if turnID == "" {
		return path
	}
	end := len(path)
	for end > 0 && path[end-1].TurnID == turnID {
		end--
	}
	return path[:end]
}

// BuildReplay renders path as a transcript block to prepend to the first turn
// of a fresh provider session. See BuildReplaySteps.
func BuildReplay(path []db.ChatMessage, capChars int) string {
	return BuildReplaySteps(path, nil, capChars)
}

// BuildReplaySteps renders path (root first) as a transcript block, newest
// messages kept first: when the entries exceed capChars runes, the oldest are
// dropped and counted in a "[N earlier messages omitted]" line; a single
// newest entry longer than the cap is truncated rather than dropped. Tool
// steps are one line each (steps is keyed by message id). Empty path → "".
func BuildReplaySteps(path []db.ChatMessage, steps map[int64][]string, capChars int) string {
	if len(path) == 0 {
		return ""
	}
	entries := make([]string, len(path))
	for i, m := range path {
		entries[i] = replayEntry(m, steps[m.ID])
	}

	start, used := len(entries), 0
	for i := len(entries) - 1; i >= 0; i-- {
		n := utf8.RuneCountInString(entries[i])
		if used+n > capChars {
			if start == len(entries) { // the newest alone is over the cap
				entries[i] = truncateRunes(entries[i], capChars-1) + "\n"
				start = i
			}
			break
		}
		used += n
		start = i
	}

	var b strings.Builder
	b.WriteString(replayHeader + "\n")
	if start > 0 {
		fmt.Fprintf(&b, "[%d earlier messages omitted]\n", start)
	}
	for _, e := range entries[start:] {
		b.WriteString(e)
	}
	b.WriteString(replayFooter + "\n\n")
	return b.String()
}

// replayEntry renders one message and its step lines, newline-terminated.
func replayEntry(m db.ChatMessage, steps []string) string {
	speaker := "System"
	switch m.Role {
	case "user":
		speaker = "Owner"
	case "assistant":
		speaker = "Assistant"
		if m.Status == "partial" {
			speaker = "Assistant (stopped early)"
		}
	}
	var b strings.Builder
	b.WriteString(speaker + ": " + strings.TrimSpace(m.Text) + "\n")
	for _, s := range steps {
		b.WriteString("  · step: " + s + "\n")
	}
	return b.String()
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `go test ./internal/chat/ -run 'TestBuildReplay|TestHistoryBefore'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/chat/replay.go internal/chat/replay_test.go
git commit -m "feat(chat): replay transcript builder for non-continuous provider sessions" \
  -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Go system prompt

**Files:**
- Create: `internal/chat/blocks/blocks.go`, `internal/chat/blocks/blocks_test.go`
- Create: `internal/chat/prompt.go`, `internal/chat/prompt_sections.go`, `internal/chat/actions_contract.go`, `internal/chat/artifacts_contract.go`
- Create: `internal/chat/prompt_test.go`, `internal/chat/testdata/system_prompt_main.golden` (generated)
- Modify: `internal/ai/prompt.go` (`systemPromptTemplate`, `BuildSystemPrompt`, imports)

**Interfaces:**
- Consumes: Task 1 `db.GetChatProjectContext`; Task 2 `truncateRunes`; existing `db.ResolveOwner`, `db.ListSlackAccounts`, `db.GetWorkspace`, `db.ListGoogleAccounts`, `db.ListJiraAccounts`, `db.FormatConnectedWorkspaces`, `skills.List`, `prompts.Directive`.
- Produces (binding):
  - `type PromptOptions struct{ Surface string; ProjectID int64; ToolsAvailable bool; Provider string; SkillsDir, VaultDir string; MemoryChat bool; Now time.Time }`
  - `func BuildSystemPrompt(ctx context.Context, d *db.DB, cfg *config.Config, o PromptOptions) (string, error)` — sections in spec §4.1 order; no DB schema; error for a surface other than `main`/`target`.
  - `const PromptBudgetChars = 40000`, `const ProjectFilesCapChars = 120000`.
  - `func ActionsContract(surface string) string` (in `actions_contract.go`, alone in that file — Task 19 replaces the file); `"main"`/`"target"` → today's Swift `AgentToolsContract.promptBlock` text; anything else → `""`.
  - `func ArtifactsContract() string` (spec §7.2; Task 23 may refine the text).
  - Package `blocks`: `type SlackTeam struct{ AccountID int64; TeamID, Name string }`; `const ToolsList`, `const DataAccessRules`, `const Workflow`; `func LinkingRules(teams []SlackTeam, fallbackTeamID string) string` — shared with `internal/ai/prompt.go`.

- [ ] **Step 1: Write the failing `blocks` tests**

Create `internal/chat/blocks/blocks_test.go`:

```go
package blocks

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestLinkingRules_MapsEachConnectedAccount(t *testing.T) {
	out := LinkingRules([]SlackTeam{
		{AccountID: 1, TeamID: "T111", Name: "Acme"},
		{AccountID: 2, TeamID: "T222", Name: "Partner org"},
	}, "T111")
	assert.Contains(t, out, "- account 1 → team_id T111 (Acme)")
	assert.Contains(t, out, "- account 2 → team_id T222 (Partner org)")
	assert.Contains(t, out, "An id without a prefix uses team_id T111.")
	assert.Contains(t, out, "slack://channel?team=T111&id=C123&message=1740577800.000100", "example uses the first team")
	assert.Contains(t, out, `prefer the hit's "link"`)
	assert.Contains(t, out, "chunk_anchor")
}

func TestLinkingRules_SingleLegacyTeam(t *testing.T) {
	out := LinkingRules(nil, "T001")
	assert.Contains(t, out, "team_id: T001")
	assert.NotContains(t, out, "account 1 →")
	assert.Contains(t, out, "deep link")
}

func TestLinkingRules_NoTeamAtAll(t *testing.T) {
	out := LinkingRules(nil, "")
	assert.Contains(t, out, "omit Slack deep links")
	assert.Contains(t, out, "team=T0000000", "the example still renders with a placeholder id")
}

// The CLI prompt test forbids "!" and "<>" (sanitized-input check), so the
// shared text must never contain them.
func TestSharedBlocks_HaveNoForbiddenCharacters(t *testing.T) {
	for _, s := range []string{ToolsList, DataAccessRules, Workflow, LinkingRules(nil, "T1")} {
		assert.False(t, strings.ContainsAny(s, "!<>"), s)
	}
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `go test ./internal/chat/blocks/`
Expected: FAIL — `no Go files` / `undefined: LinkingRules`.

- [ ] **Step 3: Write `blocks.go`**

Create `internal/chat/blocks/blocks.go`:

```go
// Package blocks holds the system-prompt text shared by the main AI Chat
// (internal/chat) and the CLI ask/repl prompt (internal/ai): the read-tool
// list, the data-access rules, the workflow and the Slack linking rules —
// one copy (spec §4.1). It is a leaf package so both sides can import it
// (internal/chat imports internal/ai, so the text cannot live in chat).
package blocks

import (
	"fmt"
	"strings"
)

// SlackTeam maps one connected Slack account to the team id its deep links
// use. AccountID is the N of an "N:C123" namespaced id.
type SlackTeam struct {
	AccountID int64
	TeamID    string
	Name      string
}

// ToolsList names the read tools every tool-bearing surface has.
const ToolsList = `=== TOOLS (local Watchtower data — already connected; use them, never ask the user) ===
- search_knowledge / get_knowledge_document: relevance search across Slack, mail, Jira, calendar, transcripts, recaps, digests, decisions and ideas; open a hit in full by its ref.
- list_messages: search/list raw Slack messages by person, channel, and/or keyword, newest first. At least one of person/channel/query is required.
- list_people / get_person: people cards; list_tracks / get_track: work narratives.
- list_targets / get_target: the owner's action items and goals.
- get_today_briefing / list_digests / get_digest: the daily briefing and AI summaries of Slack activity.
- list_jira_issues / get_jira_issue: synced Jira issues.
- list_transcripts / get_transcript: recorded meeting transcripts.
- list_upcoming_events: calendar events in the next N hours.
- memory_recall / memory_open / memory_map: the assistant's long-term memory, once it has been built.
Never ask for a database path; the data is already local and the tools are already connected.`

// DataAccessRules is the ground rule written against a real failure mode:
// an unbriefed model tries a tool it does not have, gets silently denied, and
// asks the user to "approve tool permissions".
const DataAccessRules = `There is no SQL tool and no shell — you cannot run database or shell commands of any kind.
You also have NO internet access and NO live access to Slack, Jira, or Calendar — the local database already mirrors them, and the tools above are the only way in. Never say you will check an external system, and never ask the user to approve tool permissions: everything you can use is already connected; everything else is unavailable by design.`

// Workflow tells the model how to look things up.
const Workflow = `=== WORKFLOW ===
1. Look the data up with the tools above. For a topical question (what was decided / discussed / happened about X) start with search_knowledge: pass 2-5 queries — the key terms, synonyms, both Russian and English variants, and word stems ending in * for Russian word forms — then open the best hits with get_knowledge_document or the source tools. Use list_messages for "latest from a person/channel" questions.
2. If results are empty or insufficient, broaden the lookup (wider filters, different keywords)
3. Analyze the actual content from the results
4. Respond with insights, organized by topic
5. Include Slack deep links for key messages`

// LinkingRules renders the Slack deep-link rules. teams lists the connected
// accounts (AccountID > 0) so the model can map a namespaced "N:C123" id to
// the right team — the per-account ladder of internal/ai/slack_link.go;
// fallbackTeamID is the team for an un-namespaced id (the legacy single
// workspace). With no team at all the model is told to name channels instead.
func LinkingRules(teams []SlackTeam, fallbackTeamID string) string {
	example := fallbackTeamID
	if len(teams) > 0 && teams[0].TeamID != "" {
		example = teams[0].TeamID
	}
	if example == "" {
		example = "T0000000"
	}
	var b strings.Builder
	b.WriteString("=== LINKING RULES ===\n")
	b.WriteString("ALWAYS include Slack links as descriptive markdown — never bare URLs.\n\n")
	b.WriteString("Slack deep link format: slack://channel?team={team_id}&id={channel_id}&message={ts}\n")
	b.WriteString(teamMapping(teams, fallbackTeamID))
	b.WriteString("\nChannel link: [#channel-name](slack://channel?team={team_id}&id={channel_id})\n")
	b.WriteString("Message link: [descriptive text](slack://channel?team={team_id}&id={channel_id}&message={ts})\n")
	b.WriteString("  Use the raw ts value (with dot). Example: \"1740577800.000100\" → message=1740577800.000100\n")
	fmt.Fprintf(&b, "  Example: [message about the deploy](slack://channel?team=%s&id=C123&message=1740577800.000100)\n", example)
	b.WriteString(`
Rules:
- Every channel mention (#name) MUST be a link to that channel
- Every referenced message or thread MUST have a link with descriptive text in the user's language
- Link text should describe WHAT is being linked, not "click here" or "link"
- When listing messages, each one gets its own link
- list_messages returns the channel and ts of every message, so you can always build a link
- search_knowledge hits: prefer the hit's "link" (a permalink) when present. To link a specific Slack message instead, take anchor.channel_id without its "N:" account prefix ("1:C123" → C123) and, as the message ts, anchor.thread_ts for a thread hit, otherwise the hit's chunk_anchor.`)
	return b.String()
}

func teamMapping(teams []SlackTeam, fallback string) string {
	var named []SlackTeam
	for _, t := range teams {
		if t.AccountID > 0 && t.TeamID != "" {
			named = append(named, t)
		}
	}
	if len(named) == 0 {
		if fallback == "" {
			return "team_id: unknown — omit Slack deep links and name the channel instead.\n"
		}
		return "team_id: " + fallback + "\n"
	}
	var b strings.Builder
	b.WriteString("Slack ids in tool results look like \"N:C123\" (N = the connected Slack account). Strip the \"N:\" prefix and use that account's team_id:\n")
	for _, t := range named {
		label := ""
		if t.Name != "" {
			label = " (" + t.Name + ")"
		}
		fmt.Fprintf(&b, "- account %d → team_id %s%s\n", t.AccountID, t.TeamID, label)
	}
	if fallback != "" {
		fmt.Fprintf(&b, "An id without a prefix uses team_id %s.\n", fallback)
	}
	return b.String()
}
```

Run: `go test ./internal/chat/blocks/`
Expected: PASS.

- [ ] **Step 4: Make `internal/ai/prompt.go` reuse the blocks**

In `internal/ai/prompt.go`, add `"watchtower/internal/chat/blocks"` to the imports and replace `systemPromptTemplate` and `BuildSystemPrompt` with:

```go
const systemPromptTemplate = `You are Watchtower, an AI assistant that answers questions about a Slack workspace from its local database.

Workspace: "%s" (domain: %s.slack.com)
Current time: %s

IMPORTANT: You MUST look things up with the tools below to answer every question. You have NO pre-loaded data — the local database is your only source of truth.

%s

%s
The schema below documents the fields behind those tools; read it as reference, never as something to execute.

=== DATABASE SCHEMA (reference) ===
%s

=== TARGETS & GOAL HIERARCHY ===
The workspace uses a hierarchical goal system called "targets" (replaces the old flat "tasks").
- Table: targets — personal action items and goals, each with a level tag: quarter, month, week, day, or custom.
  level and period_start/period_end together express WHEN a target is due (e.g. a quarter OKR vs today's to-do).
  parent_id links child targets to their parent for tree rendering and progress rollup (progress 0.0–1.0).
- Table: target_links — typed edges between targets or to external refs (Jira keys, Slack permalinks).
  relation is one of: contributes_to, blocks, related, duplicates.
  target_target_id references another target; external_ref holds e.g. 'jira:PROJ-123' or 'slack:C123:ts'.
  created_by is 'ai' (auto-linked) or 'user' (manually added).
Reach targets and their links with list_targets / get_target — status, priority, level, and ownership are filters on list_targets.

%s

%s

=== RESPONSE STYLE ===
- Be concise and direct
%s
- Use markdown for readability
- Highlight: decisions, action items, unanswered questions, unusual activity`

// BuildSystemPrompt generates the system prompt for `ask`/`repl`. The tool
// list, data-access rules, workflow and linking rules are the shared blocks
// the main AI Chat uses too (internal/chat/blocks — one copy). The database
// path is deliberately NOT part of the prompt: the assistant reads the data
// through the read-only watchtower MCP tools.
func BuildSystemPrompt(workspaceName, domain, teamID, schema, language string) string {
	// Sanitize workspace name and domain to prevent prompt injection
	safeName := safeNameRe.ReplaceAllString(workspaceName, "")
	safeDomain := safeDomainRe.ReplaceAllString(domain, "")
	safeTeamID := safeDomainRe.ReplaceAllString(teamID, "")
	if safeName == "" {
		safeName = "unknown"
	}
	if safeDomain == "" {
		safeDomain = "unknown"
	}
	if safeTeamID == "" {
		safeTeamID = "unknown"
	}

	now := time.Now().UTC().Format("2006-01-02 15:04 UTC")
	return fmt.Sprintf(systemPromptTemplate,
		safeName, safeDomain, now,
		blocks.ToolsList,
		blocks.DataAccessRules,
		schema,
		blocks.Workflow,
		blocks.LinkingRules(nil, safeTeamID),
		languageInstruction(language),
	)
}
```

Run: `go test ./internal/ai/`
Expected: PASS — every existing `TestBuildSystemPrompt_*` assertion still holds (tool names, "no SQL tool and no shell", the NO-internet sentence, "deep link", the knowledge-link rule, sanitized inputs, language directive).

- [ ] **Step 5: Write the failing prompt-builder tests**

Create `internal/chat/prompt_test.go`:

```go
package chat

import (
	"context"
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

var updateGolden = flag.Bool("update", false, "rewrite testdata/*.golden")

// promptFixture is a realistic multi-account install: two Slack orgs, one
// Google and one Jira account, two skills (one disabled) and a memory map.
func promptFixture(t *testing.T) (*db.DB, *config.Config, PromptOptions) {
	t.Helper()
	d := db.OpenTestDB(t)
	_, err := d.CreateSlackAccount(db.SlackAccount{TeamID: "T111", TeamName: "Acme", TeamDomain: "acme", CurrentUserID: "1:U1"})
	require.NoError(t, err)
	_, err = d.CreateSlackAccount(db.SlackAccount{TeamID: "T222", TeamName: "Partner", TeamDomain: "partner",
		Label: "Partner org", CurrentUserID: "2:U9"})
	require.NoError(t, err)
	_, err = d.CreateGoogleAccount(db.GoogleAccount{Email: "owner@example.com", CalendarEnabled: true, GmailEnabled: true})
	require.NoError(t, err)
	db.SeedTestJiraAccount(t, d)

	skillsDir := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(skillsDir, "meeting-notes.md"),
		[]byte("---\ndescription: Turn a transcript into publishable meeting notes\n---\nSteps…\n"), 0o600))
	require.NoError(t, os.WriteFile(filepath.Join(skillsDir, "old-flow.md"),
		[]byte("---\ndescription: Retired flow\nenabled: false\n---\nx\n"), 0o600))

	vault := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(vault, "map.md"),
		[]byte("# Map\n- The payments team ships refunds in Q4\n"), 0o600))

	cfg := &config.Config{}
	cfg.Digest.Language = "English"
	return d, cfg, PromptOptions{
		Surface: "main", ToolsAvailable: true, Provider: "claude",
		SkillsDir: skillsDir, VaultDir: vault, MemoryChat: true,
		Now: time.Date(2026, 9, 26, 9, 30, 0, 0, time.UTC),
	}
}

func TestBuildSystemPrompt_Golden(t *testing.T) {
	d, cfg, o := promptFixture(t)
	got, err := BuildSystemPrompt(context.Background(), d, cfg, o)
	require.NoError(t, err)

	path := filepath.Join("testdata", "system_prompt_main.golden")
	if *updateGolden {
		require.NoError(t, os.WriteFile(path, []byte(got), 0o644))
		return
	}
	want, err := os.ReadFile(path)
	require.NoError(t, err, "run: go test ./internal/chat -run TestBuildSystemPrompt_Golden -update")
	assert.Equal(t, string(want), got)
}

func TestBuildSystemPrompt_SectionsAndOrder(t *testing.T) {
	d, cfg, o := promptFixture(t)
	got, err := BuildSystemPrompt(context.Background(), d, cfg, o)
	require.NoError(t, err)

	order := []string{
		"You are Watchtower",
		"Respond ONLY in English",
		"=== CONNECTED SOURCES ===",
		"=== LINKING RULES ===",
		"=== TOOLS",
		"=== WORKFLOW ===",
		"=== AGENT ACTIONS ===",
		"=== ARTIFACTS ===",
		"=== SKILLS ===",
		"=== MEMORY",
		"=== WATCHTOWER APP",
		"=== RESPONSE STYLE ===",
	}
	last := -1
	for _, marker := range order {
		i := strings.Index(got, marker)
		require.GreaterOrEqual(t, i, 0, "missing %q", marker)
		assert.Greater(t, i, last, "%q out of order", marker)
		last = i
	}
	assert.Contains(t, got, "- account 2 → team_id T222 (Partner org)", "per-account Slack link rule")
	assert.Contains(t, got, "owner@example.com")
	assert.Contains(t, got, "- meeting-notes — Turn a transcript into publishable meeting notes")
	assert.NotContains(t, got, "old-flow", "a disabled skill is not listed")
	assert.Contains(t, got, "ships refunds in Q4")
	assert.NotContains(t, got, "CREATE TABLE", "the chat has no SQL tool, so no schema (spec §4.1)")
}

func TestBuildSystemPrompt_GatesAndSurfaces(t *testing.T) {
	d, cfg, o := promptFixture(t)

	o.MemoryChat = false
	got, err := BuildSystemPrompt(context.Background(), d, cfg, o)
	require.NoError(t, err)
	assert.NotContains(t, got, "=== MEMORY", "memory.surfaces.chat off → no memory block")

	o.ToolsAvailable = false
	got, err = BuildSystemPrompt(context.Background(), d, cfg, o)
	require.NoError(t, err)
	assert.Contains(t, got, "No tools are connected in this session")
	assert.NotContains(t, got, "=== AGENT ACTIONS ===")
	assert.NotContains(t, got, "search_knowledge")

	o.ToolsAvailable = true
	o.Surface = "target"
	got, err = BuildSystemPrompt(context.Background(), d, cfg, o)
	require.NoError(t, err)
	assert.Contains(t, got, "Never create other Watchtower tasks from here")

	o.Surface = "meeting"
	_, err = BuildSystemPrompt(context.Background(), d, cfg, o)
	assert.Error(t, err)
}

func TestBuildSystemPrompt_EmptyInstall(t *testing.T) {
	d := db.OpenTestDB(t)
	got, err := BuildSystemPrompt(context.Background(), d, &config.Config{}, PromptOptions{
		Surface: "main", ToolsAvailable: true, Now: time.Now()})
	require.NoError(t, err)
	assert.Contains(t, got, "Owner: unknown")
	assert.Contains(t, got, "- Slack: not connected")
	assert.Contains(t, got, "omit Slack deep links")
	assert.NotContains(t, got, "=== SKILLS ===", "no skills dir → no skills block")
}

// TestBuildSystemPrompt_Budget: spec §4.2 — the prompt without project files
// stays under 40k chars even with a large memory map and many skills.
func TestBuildSystemPrompt_Budget(t *testing.T) {
	d, cfg, o := promptFixture(t)
	for i := 0; i < 30; i++ {
		name := filepath.Join(o.SkillsDir, "skill-"+string(rune('a'+i%26))+strings.Repeat("x", i/26)+".md")
		require.NoError(t, os.WriteFile(name, []byte("---\ndescription: "+strings.Repeat("d", 180)+"\n---\n"), 0o600))
	}
	require.NoError(t, os.WriteFile(filepath.Join(o.VaultDir, "map.md"), []byte(strings.Repeat("м", 50_000)), 0o600))

	got, err := BuildSystemPrompt(context.Background(), d, cfg, o)
	require.NoError(t, err)
	assert.LessOrEqual(t, utf8.RuneCountInString(got), PromptBudgetChars)
}

func TestBuildSystemPrompt_ProjectBlock(t *testing.T) {
	d, cfg, o := promptFixture(t)
	res, err := d.Exec(`INSERT INTO chat_projects (name, instructions, created_at, updated_at)
		VALUES ('Payments', 'Always answer in bullets.', 1, 1)`)
	require.NoError(t, err)
	pid, err := res.LastInsertId()
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO chat_project_sources (project_id, kind, ref, label) VALUES (?, 'jira_project', 'PAY', 'Payments')`, pid)
	require.NoError(t, err)

	dir := t.TempDir()
	small := filepath.Join(dir, "notes.md")
	require.NoError(t, os.WriteFile(small, []byte("Refunds ship on Oct 3."), 0o600))
	big := filepath.Join(dir, "dump.txt")
	require.NoError(t, os.WriteFile(big, []byte(strings.Repeat("z", ProjectFilesCapChars)), 0o600))
	for _, f := range []struct{ name, mime, path string }{
		{"notes.md", "text/markdown", small}, {"dump.txt", "text/plain", big}, {"arch.png", "image/png", "/nonexistent.png"},
	} {
		_, err = d.Exec(`INSERT INTO chat_attachments (project_id, name, mime, size, path, sha256, created_at)
			VALUES (?, ?, ?, 1, ?, ?, 1)`, pid, f.name, f.mime, f.path, "h-"+f.name)
		require.NoError(t, err)
	}

	o.ProjectID = pid
	got, err := BuildSystemPrompt(context.Background(), d, cfg, o)
	require.NoError(t, err)
	assert.Contains(t, got, "=== PROJECT: Payments ===")
	assert.Contains(t, got, "Always answer in bullets.")
	assert.Contains(t, got, "- jira_project: PAY (Payments)")
	assert.Contains(t, got, "--- file: notes.md ---\nRefunds ship on Oct 3.")
	assert.Contains(t, got, "Not inlined (over the 120000-char project-file cap): dump.txt")
	assert.Contains(t, got, "Attached to the first message of each session: arch.png")
	assert.Less(t, strings.Index(got, "=== PROJECT"), strings.Index(got, "=== WATCHTOWER APP"))
}

func TestActionsContract(t *testing.T) {
	main := ActionsContract("main")
	assert.True(t, strings.HasPrefix(main, "=== AGENT ACTIONS ===\n"))
	for _, tool := range []string{"create_target", "create_jira_issue", "connect_jira_board", "list_jira_projects", "get_action"} {
		assert.Contains(t, main, tool)
	}
	target := ActionsContract("target")
	assert.Contains(t, target, "create_jira_issue")
	assert.NotContains(t, target, "create_target —", "the target chat may not create other targets")
	assert.Equal(t, "", ActionsContract("meeting"), "a draft-only surface has no actions contract (AGENT-04)")
}

func TestArtifactsContract(t *testing.T) {
	c := ArtifactsContract()
	assert.Contains(t, c, `:::artifact key="`)
	for _, kind := range []string{"document", "table", "email", "slack", "event", "code"} {
		assert.Contains(t, c, kind)
	}
	assert.Contains(t, c, "never send", "CHAT-05: artifacts only open or copy")
}
```

- [ ] **Step 6: Run to verify they fail**

Run: `go test ./internal/chat/ -run 'TestBuildSystemPrompt|TestActionsContract|TestArtifactsContract'`
Expected: FAIL to compile — `undefined: BuildSystemPrompt`, `undefined: PromptOptions`.

- [ ] **Step 7: Write `actions_contract.go` (only `ActionsContract` — Task 19 replaces this file)**

Create `internal/chat/actions_contract.go`:

```go
package chat

// ActionsContract is the system-prompt block that teaches an action surface
// how write tools work: they create PROPOSALS the owner approves. A Go port of
// Swift AgentToolsContract.promptBlock(surface:) — the Swift copy stays for
// the target chat until it moves to this engine (dual path; Task 19 pins both
// to shared fixtures). Any surface other than main/target is draft-only and
// gets "" (AGENT-04).
func ActionsContract(surface string) string {
	var tools, coexistence string
	switch surface {
	case "main":
		tools = "- create_target — propose a new task or reminder (a task with a due date) in the owner's task list.\n" +
			"- create_jira_issue — propose a Jira issue on a connected site.\n" +
			"- connect_jira_board — propose watching a Jira board so its issues start syncing; pass board_name " +
			"when the project has several boards, and ask the owner when the project is ambiguous."
	case "target":
		tools = "- create_jira_issue — propose a Jira issue on a connected site."
		coexistence = "\nChanges to THIS task and its vertical line still go through `watchtower-action` blocks " +
			"(TASK ACTIONS above); a Jira issue goes through the create_jira_issue tool. Never create " +
			"other Watchtower tasks from here — report the finding in prose instead."
	default:
		return ""
	}
	return "=== AGENT ACTIONS ===\n" +
		"You have write TOOLS. A write tool never changes anything by itself: calling it records a " +
		"PROPOSAL and returns a receipt with an action id. The owner sees a card in this chat and " +
		"approves or rejects it; only then does the app execute it.\n" +
		"Write tools on this surface:\n" +
		tools + "\n" +
		"Rules:\n" +
		"- After calling a write tool, tell the owner what you proposed and that it awaits their approval; " +
		"never claim it is done, created, or sent.\n" +
		"- One proposal per item; never propose the same item twice in one turn.\n" +
		"- For Jira, call list_jira_projects FIRST to pick a synced project and a known issue type. When the " +
		"project or type is ambiguous, ask the owner instead of guessing.\n" +
		"- get_action <id> answers what happened to a proposal; an ACTIONS SINCE YOUR LAST MESSAGE block " +
		"at the top of the owner's message reports outcomes since your last turn.\n" +
		coexistence
}
```

- [ ] **Step 8: Write `artifacts_contract.go`**

Create `internal/chat/artifacts_contract.go`:

```go
package chat

// ArtifactsContract teaches the model the artifact fence (spec §7.2). The
// Desktop parses the fence out of the streamed text into versioned artifacts;
// artifact actions only open or copy, never send (CHAT-05).
func ArtifactsContract() string {
	return `=== ARTIFACTS ===
Put anything the owner will copy, send or keep — a draft, a document longer than about 15 lines, a table — in an artifact instead of the chat text:

:::artifact key="q3-plan" kind="document" title="Q3 plan"
…content…
:::

- kind is one of: document (markdown), table (CSV with a header row), email, slack, event, code.
- email: add to="…" cc="…" subject="…" attributes; the content is the body.
- slack: add channel="…" (a channel id or a message permalink); the content is the message.
- event: add start="YYYY-MM-DDTHH:MM" end="YYYY-MM-DDTHH:MM" attendees="a@example.com, b@example.com" location="…"; the content is the description.
- code: add language="…".
- key is a short stable slug. To revise an artifact, emit it again with the SAME key — that saves a new version.
- Artifacts never send anything: the owner opens a ready draft in Gmail, Slack or Calendar and sends it themselves. Never claim you sent it.
- Keep the chat text around an artifact to one or two sentences.`
}
```

- [ ] **Step 9: Write the prompt sections**

Create `internal/chat/prompt_sections.go`:

```go
package chat

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"

	"watchtower/internal/chat/blocks"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/prompts"
	"watchtower/internal/skills"
)

// memoryMapMaxRunes caps the hot map in the prompt (the Swift MEMORY block's
// 4 KB precedent).
const memoryMapMaxRunes = 4000

// noToolsBlock is the honest variant for a session without tools: nothing
// promises what the session cannot do (Swift AgentToolsContract.noToolsBlock).
const noToolsBlock = `=== TOOLS ===
No tools are connected in this session. Answer from the conversation only, and say so plainly when the owner asks you to look something up or to create something.`

// appGuide is the short, current app guide (spec §4.1 item 9) — reviewed
// against WatchtowerDesktop/Sources/App/SidebarDestination.swift.
const appGuide = `=== WATCHTOWER APP (answer questions about the app from this) ===
Watchtower is a macOS app that mirrors the owner's Slack, Google (Gmail, Calendar), Jira and recorded meetings into a local database and runs AI pipelines over it. Sidebar:
- AI Chat — this chat: history on the left, projects, attachments, artifacts in a side panel, proposals the owner approves.
- Catch Up — a recap of everything since the owner last caught up.
- Briefings — the daily briefing; Day Plan — today's time-blocked plan.
- Inbox — the action strip: proposals awaiting approval and due reminders.
- Ideas — ideas and notes mined from conversations; Digests — Slack/mail/Jira digests and the Decisions journal.
- Calendar — events with meeting prep, and Recordings (transcripts, recaps, notes).
- Targets — the owner's goals and tasks; Tracks — narratives of ongoing work.
- People — people cards; Memory — the assistant's long-term memory.
- Workload, Blockers, Project Map, Releases, Boards — Jira views.
- Statistics, Search (full-text over Slack), Usage (AI cost), MCP Server (connect Watchtower to coding agents).
Settings hold the connected accounts (Slack, Google, Jira, Quick Connections), features, the AI provider and models, prompts and skills.`

const responseStyle = `=== RESPONSE STYLE ===
- Give the answer first and keep it short. Do not narrate your search steps — the app already shows them.
- Use markdown (headings, lists, tables) when it helps; put anything the owner will copy, send or keep in an artifact.
- Highlight decisions, owners, deadlines and open questions.`

func identityBlock(d *db.DB, cfg *config.Config, now time.Time) (string, error) {
	owner, err := d.ResolveOwner()
	if err != nil {
		return "", fmt.Errorf("resolving owner: %w", err)
	}
	var b strings.Builder
	b.WriteString("You are Watchtower, the owner's work assistant. You answer from the owner's own synced sources — " +
		"Slack, mail, Jira, calendar, meeting transcripts and Watchtower's digests, decisions, targets and memory — " +
		"and you show where each fact came from.\n\n")
	fmt.Fprintf(&b, "Current time: %s (%s)\n", now.Format("Monday, 2006-01-02 15:04 MST"), now.UTC().Format("15:04 UTC"))
	switch {
	case owner.DisplayName != "" && owner.Email != "":
		fmt.Fprintf(&b, "Owner: %s (%s)\n", owner.DisplayName, owner.Email)
	case owner.DisplayName != "":
		fmt.Fprintf(&b, "Owner: %s\n", owner.DisplayName)
	case owner.Email != "":
		fmt.Fprintf(&b, "Owner: %s\n", owner.Email)
	case owner.Known():
		fmt.Fprintf(&b, "Owner: %s\n", owner.ID)
	default:
		b.WriteString("Owner: unknown — no Slack, Google or Jira identity is connected yet.\n")
	}
	b.WriteString("\n" + prompts.Directive(cfg.Digest.Language))
	return b.String(), nil
}

// sourcesBlock lists the connected accounts and returns the Slack teams and
// fallback team the linking rules need.
func sourcesBlock(d *db.DB) (string, []blocks.SlackTeam, string, error) {
	slackAccts, err := d.ListSlackAccounts()
	if err != nil {
		return "", nil, "", fmt.Errorf("listing slack accounts: %w", err)
	}
	var active []db.SlackAccount
	var teams []blocks.SlackTeam
	for _, a := range slackAccts {
		if a.Status == "removed" {
			continue
		}
		active = append(active, a)
		name := a.Label
		if name == "" {
			name = a.TeamName
		}
		teams = append(teams, blocks.SlackTeam{AccountID: a.ID, TeamID: a.TeamID, Name: name})
	}
	fallback := ""
	ws, err := d.GetWorkspace()
	if err != nil {
		return "", nil, "", err
	}
	if ws != nil {
		fallback = ws.ID
	}
	if fallback == "" && len(teams) > 0 {
		fallback = teams[0].TeamID
	}

	google, err := d.ListGoogleAccounts()
	if err != nil {
		return "", nil, "", fmt.Errorf("listing google accounts: %w", err)
	}
	jira, err := d.ListJiraAccounts()
	if err != nil {
		return "", nil, "", fmt.Errorf("listing jira accounts: %w", err)
	}

	var b strings.Builder
	b.WriteString("=== CONNECTED SOURCES ===\n")
	if len(active) == 0 {
		b.WriteString("- Slack: not connected\n")
	} else {
		b.WriteString("- Slack: " + db.FormatConnectedWorkspaces(active) + "\n")
	}
	var gl []string
	for _, g := range google {
		var parts []string
		if g.CalendarEnabled {
			parts = append(parts, "Calendar")
		}
		if g.GmailEnabled {
			parts = append(parts, "Gmail")
		}
		entry := g.Email + " (" + strings.Join(parts, ", ") + ")"
		if g.Status == "revoked" || g.Status == "error" {
			entry += " — needs re-login"
		}
		gl = append(gl, entry)
	}
	if len(gl) == 0 {
		b.WriteString("- Google: not connected\n")
	} else {
		b.WriteString("- Google: " + strings.Join(gl, "; ") + "\n")
	}
	var jl []string
	for _, j := range jira {
		if !j.Enabled || j.Status == "removed" {
			continue
		}
		name := j.Label
		if name == "" {
			name = j.SiteName
		}
		jl = append(jl, name+" ("+j.SiteURL+")")
	}
	if len(jl) == 0 {
		b.WriteString("- Jira: not connected\n")
	} else {
		b.WriteString("- Jira: " + strings.Join(jl, "; ") + "\n")
	}
	b.WriteString("Only these sources are synced; when the owner asks about something outside them, say it is not connected.")
	return b.String(), teams, fallback, nil
}

// skillsBlock lists the enabled skills (the same frontmatter load_skill reads).
// No directory or no enabled skill → "".
func skillsBlock(dir string) (string, error) {
	if dir == "" {
		return "", nil
	}
	list, err := skills.List(dir)
	if err != nil {
		return "", fmt.Errorf("listing skills: %w", err)
	}
	var lines []string
	for _, s := range list {
		if s.Enabled {
			lines = append(lines, "- "+s.Name+" — "+s.Description)
		}
	}
	if len(lines) == 0 {
		return "", nil
	}
	return "=== SKILLS ===\nSkills are the owner's saved playbooks. When a request matches a skill's description, " +
		"call load_skill with its name FIRST and follow it.\n" + strings.Join(lines, "\n"), nil
}

// memoryBlock is the hot map (<vault>/map.md, the Swift RelevantMemory.hotMap
// equivalent), capped. A missing or blank map → "".
func memoryBlock(vaultDir string) string {
	if vaultDir == "" {
		return ""
	}
	data, err := os.ReadFile(filepath.Join(vaultDir, "map.md"))
	if err != nil {
		return ""
	}
	m := strings.TrimSpace(string(data))
	if m == "" {
		return ""
	}
	return "=== MEMORY (notes the assistant has built from Slack/Jira — model-mediated, not the owner's own words) ===\n" +
		"Hot map:\n" + truncateRunes(m, memoryMapMaxRunes) + "\n" +
		"Use memory_recall / memory_open for more; treat these notes as possibly outdated."
}

// projectBlock renders a project's instructions, pinned sources and files:
// text files are inlined until ProjectFilesCapChars, the rest listed by name;
// binaries are listed as attached to the first message of each session.
func projectBlock(d *db.DB, projectID int64) (string, error) {
	pc, err := d.GetChatProjectContext(projectID)
	if err != nil || pc == nil {
		return "", err
	}
	var b strings.Builder
	b.WriteString("=== PROJECT: " + pc.Name + " ===\n")
	if s := strings.TrimSpace(pc.Instructions); s != "" {
		b.WriteString("Instructions from the owner (follow them in this chat):\n" + s + "\n")
	}
	if len(pc.Sources) > 0 {
		b.WriteString("Pinned sources (prefer these when relevant):\n")
		for _, s := range pc.Sources {
			line := "- " + s.Kind + ": " + s.Ref
			if s.Label != "" {
				line += " (" + s.Label + ")"
			}
			b.WriteString(line + "\n")
		}
	}
	used := 0
	var overflow, unreadable []string
	for _, f := range pc.TextFiles {
		data, err := os.ReadFile(f.Path)
		if err != nil {
			unreadable = append(unreadable, f.Name)
			continue
		}
		n := utf8.RuneCount(data)
		if used+n > ProjectFilesCapChars {
			overflow = append(overflow, f.Name)
			continue
		}
		used += n
		b.WriteString("--- file: " + f.Name + " ---\n" + string(data) + "\n")
	}
	if len(overflow) > 0 {
		fmt.Fprintf(&b, "Not inlined (over the %d-char project-file cap): %s\n", ProjectFilesCapChars, strings.Join(overflow, ", "))
	}
	if len(unreadable) > 0 {
		b.WriteString("Unreadable project files: " + strings.Join(unreadable, ", ") + "\n")
	}
	if len(pc.BinaryFiles) > 0 {
		names := make([]string, len(pc.BinaryFiles))
		for i, f := range pc.BinaryFiles {
			names[i] = f.Name
		}
		b.WriteString("Attached to the first message of each session: " + strings.Join(names, ", ") + "\n")
	}
	return strings.TrimRight(b.String(), "\n"), nil
}
```

- [ ] **Step 10: Write `prompt.go`**

Create `internal/chat/prompt.go`:

```go
package chat

import (
	"context"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/chat/blocks"
	"watchtower/internal/config"
	"watchtower/internal/db"
)

// PromptBudgetChars is the prompt target without project files (spec §4.2).
const PromptBudgetChars = 40000

// ProjectFilesCapChars caps the text project files inlined into the prompt.
const ProjectFilesCapChars = 120000

// PromptOptions selects what BuildSystemPrompt includes.
type PromptOptions struct {
	Surface        string // main | target
	ProjectID      int64  // 0 = no project
	ToolsAvailable bool   // false = a provider session without tools
	Provider       string
	SkillsDir      string // skills.Dir(workspace); "" = no skills block
	VaultDir       string // memory vault root; "" = no memory block
	MemoryChat     bool   // memory.enabled && memory.surfaces.chat
	Now            time.Time
}

// BuildSystemPrompt assembles the main chat's system prompt in the spec §4.1
// order: identity/time/owner/language, connected sources + Slack linking
// rules, tools & workflow, the surface's actions contract, the artifacts
// contract, skills, memory, the project block, the app guide and the response
// style. No DB schema — the chat has no SQL tool.
func BuildSystemPrompt(ctx context.Context, d *db.DB, cfg *config.Config, o PromptOptions) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if o.Surface != "main" && o.Surface != "target" {
		return "", fmt.Errorf("chat surface %q has no system prompt here (main|target)", o.Surface)
	}
	now := o.Now
	if now.IsZero() {
		now = time.Now()
	}

	identity, err := identityBlock(d, cfg, now)
	if err != nil {
		return "", err
	}
	sources, teams, fallback, err := sourcesBlock(d)
	if err != nil {
		return "", err
	}
	sections := []string{identity, sources}

	if o.ToolsAvailable {
		sections = append(sections,
			blocks.LinkingRules(teams, fallback),
			blocks.ToolsList+"\n\n"+blocks.DataAccessRules,
			blocks.Workflow,
			ActionsContract(o.Surface),
		)
	} else {
		sections = append(sections, noToolsBlock)
	}
	sections = append(sections, ArtifactsContract())

	if o.ToolsAvailable {
		sk, err := skillsBlock(o.SkillsDir)
		if err != nil {
			return "", err
		}
		sections = append(sections, sk)
	}
	if o.MemoryChat {
		sections = append(sections, memoryBlock(o.VaultDir))
	}
	if o.ProjectID > 0 {
		pb, err := projectBlock(d, o.ProjectID)
		if err != nil {
			return "", err
		}
		sections = append(sections, pb)
	}
	sections = append(sections, appGuide, responseStyle)

	var kept []string
	for _, s := range sections {
		if s = strings.TrimSpace(s); s != "" {
			kept = append(kept, s)
		}
	}
	return strings.Join(kept, "\n\n") + "\n", nil
}
```

- [ ] **Step 11: Generate the golden and run the tests**

Run: `go test ./internal/chat/ -run TestBuildSystemPrompt_Golden -update`
Then open `internal/chat/testdata/system_prompt_main.golden` and read it end to end: owner line present, both Slack accounts mapped, no schema, no temp paths, no "!" in the shared blocks. Then:

Run: `go test ./internal/chat/... ./internal/ai/`
Expected: PASS.

- [ ] **Step 12: Commit**

```bash
git add internal/chat/blocks/blocks.go internal/chat/blocks/blocks_test.go internal/chat/prompt.go \
  internal/chat/prompt_sections.go internal/chat/actions_contract.go internal/chat/artifacts_contract.go \
  internal/chat/prompt_test.go internal/chat/testdata/system_prompt_main.golden internal/ai/prompt.go
git commit -m "feat(chat): Go-owned system prompt with shared tool/link blocks" \
  -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: MCP `--turn-file`

**Files:**
- Create: `internal/chat/turnfile.go`, `internal/chat/turnfile_test.go`
- Modify: `internal/tools/registry.go` (`Binding`, `Propose`)
- Modify: `internal/tools/registry_test.go` (new test)
- Modify: `cmd/mcp.go` (flag + binding)
- Create: `cmd/mcp_test.go`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces (binding):
  - `tools.Binding` gains `TurnIDFunc func() string`; `Propose` uses `TurnIDFunc()` when non-nil, else `TurnID`.
  - `watchtower mcp --chat --turn-file <path>`; `--turn` and `--turn-file` are mutually exclusive; `--turn-file` requires `--chat`.
  - `func WriteTurnFile(path, turnID string) error` (atomic tmp+rename, mode 0600) and `func TurnFileReader(path string) func() string` (trimmed file content; `""` when unreadable) in package `chat`.
  - `func mcpTurnBinding(chatMode bool, turn, turnFile string) (string, func() string, error)` in `cmd/mcp.go`.

- [ ] **Step 1: Write the failing tests**

Create `internal/chat/turnfile_test.go`:

```go
package chat

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestTurnFile_WriteThenRead(t *testing.T) {
	path := filepath.Join(t.TempDir(), "turn.txt")
	read := TurnFileReader(path)
	assert.Equal(t, "", read(), "a missing file reads as no turn")

	require.NoError(t, WriteTurnFile(path, "turn-1"))
	assert.Equal(t, "turn-1", read())
	require.NoError(t, WriteTurnFile(path, "turn-2"))
	assert.Equal(t, "turn-2", read(), "the reader sees the newest turn on every call")

	info, err := os.Stat(path)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm())
}
```

Append to `internal/tools/registry_test.go`:

```go
// A warm chat session spans many turns: the proposal must carry the turn that
// is running at propose time, read through TurnIDFunc, not the launch value.
func TestPropose_TurnIDFuncWinsOverStaticTurn(t *testing.T) {
	database := openDB(t)
	var executed []Call
	reg := New(database)
	require.NoError(t, reg.Register(newEchoTool(t, false, &executed)))

	current := "turn-live"
	rc, err := reg.Propose(context.Background(), "echo",
		json.RawMessage(`{"text":"hi","reason":"because"}`),
		Binding{Surface: "main", ConversationID: 4, TurnID: "turn-at-launch", TurnIDFunc: func() string { return current }})
	require.NoError(t, err)

	row, err := database.GetAgentAction(rc.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "turn-live", row.TurnID)
}
```

Create `cmd/mcp_test.go`:

```go
package cmd

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestMCPTurnBinding(t *testing.T) {
	turn, fn, err := mcpTurnBinding(true, "t1", "")
	require.NoError(t, err)
	assert.Equal(t, "t1", turn)
	assert.Nil(t, fn)

	path := filepath.Join(t.TempDir(), "turn.txt")
	require.NoError(t, os.WriteFile(path, []byte("t-from-file\n"), 0o600))
	turn, fn, err = mcpTurnBinding(true, "", path)
	require.NoError(t, err)
	assert.Equal(t, "", turn)
	require.NotNil(t, fn)
	assert.Equal(t, "t-from-file", fn())

	_, _, err = mcpTurnBinding(true, "t1", path)
	assert.ErrorContains(t, err, "mutually exclusive")

	_, _, err = mcpTurnBinding(false, "", path)
	assert.ErrorContains(t, err, "requires --chat")
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `go test ./internal/chat/ -run TestTurnFile && go test ./internal/tools/ -run TestPropose_TurnIDFunc && go test ./cmd/ -run TestMCPTurnBinding`
Expected: FAIL to compile — `undefined: WriteTurnFile`, `unknown field TurnIDFunc`, `undefined: mcpTurnBinding`.

- [ ] **Step 3: Implement**

Create `internal/chat/turnfile.go`:

```go
package chat

import (
	"os"
	"strings"
)

// WriteTurnFile records the running turn id for the chat-mode MCP server
// (spec §1.2): a warm session spans many turns, so the server reads the file
// at propose time instead of taking --turn at launch. Written to a temp file
// and renamed, so a reader never sees a half-written id; mode 0600.
func WriteTurnFile(path, turnID string) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(turnID), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// TurnFileReader returns a function reading the current turn id from path;
// an unreadable file reads as "".
func TurnFileReader(path string) func() string {
	return func() string {
		b, err := os.ReadFile(path)
		if err != nil {
			return ""
		}
		return strings.TrimSpace(string(b))
	}
}
```

In `internal/tools/registry.go`, replace the `Binding` struct with:

```go
// Binding is where a proposal came from: the chat surface, conversation and
// turn the Desktop passed to the chat-mode server. TurnIDFunc, when set, is
// read at propose time and wins over TurnID — a warm `ai session` spans many
// turns and publishes the running one through a turn file (spec §1.2).
type Binding struct {
	Surface        string
	ConversationID int64
	ContextType    string
	ContextID      string
	TurnID         string
	TurnIDFunc     func() string
}

// turnID is the turn a proposal attaches to right now.
func (b Binding) turnID() string {
	if b.TurnIDFunc != nil {
		return b.TurnIDFunc()
	}
	return b.TurnID
}
```

and in `Propose`, in the `row := db.AgentAction{…}` literal, replace `TurnID: b.TurnID,` with `TurnID: b.turnID(),`.

In `cmd/mcp.go`: add `"errors"` and `"watchtower/internal/chat"` to the imports; add `mcpFlagTurnFile string` to the flag `var` block; in `init` add

```go
	mcpCmd.Flags().StringVar(&mcpFlagTurnFile, "turn-file", "", "file holding the running turn id for --chat (a warm ai session); excludes --turn")
```

add the helper

```go
// mcpTurnBinding resolves the turn a chat-mode proposal attaches to: a fixed
// --turn (one-shot `ai query`) or a --turn-file read at propose time (a warm
// `ai session`). Exactly one may be given, and only in chat mode.
func mcpTurnBinding(chatMode bool, turn, turnFile string) (string, func() string, error) {
	if turnFile == "" {
		return turn, nil, nil
	}
	if !chatMode {
		return "", nil, errors.New("--turn-file requires --chat")
	}
	if turn != "" {
		return "", nil, errors.New("--turn and --turn-file are mutually exclusive")
	}
	return "", chat.TurnFileReader(turnFile), nil
}
```

and in `runMCP` replace the `if mcpFlagChat { … }` binding construction with

```go
	turn, turnFunc, err := mcpTurnBinding(mcpFlagChat, mcpFlagTurn, mcpFlagTurnFile)
	if err != nil {
		return err
	}
	if mcpFlagChat {
		// Chat mode: the connection stays writable ONLY so the registry can
		// record proposals (agent_actions) — the tools themselves still never
		// write domain data on propose (AGENT-01). Dev mode below keeps the
		// query_only fence (AGENT-02 / DEV-01).
		if mcpFlagSurface != "main" && mcpFlagSurface != "target" {
			return fmt.Errorf("--surface must be main or target")
		}
		opts = append(opts, internalmcp.WithRegistry(buildToolRegistry(cfg, database), tools.Binding{
			Surface: mcpFlagSurface, ConversationID: mcpFlagConversation, TurnID: turn, TurnIDFunc: turnFunc,
			ContextType: mcpFlagContextType, ContextID: mcpFlagContextID,
		}))
	} else {
```

(the `else` branch is unchanged). Then move the three `turn, turnFunc, err := mcpTurnBinding(…)` / `if err != nil { return err }` lines up to just after `dbPath` is resolved (before `db.Open`), so a bad flag combination fails before the database is opened.

- [ ] **Step 4: Run to verify they pass**

Run: `go test ./internal/chat/ -run TestTurnFile && go test ./internal/tools/ && go test ./cmd/ -run 'TestMCP'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/chat/turnfile.go internal/chat/turnfile_test.go internal/tools/registry.go \
  internal/tools/registry_test.go cmd/mcp.go cmd/mcp_test.go
git commit -m "feat(mcp): --turn-file so a warm chat session binds proposals to the running turn" \
  -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Session loop + Claude backend + `ai session` command

**Files:**
- Create: `internal/chat/session.go`, `internal/chat/session_test.go`
- Create: `internal/chat/claude_backend.go`, `internal/chat/claude_backend_test.go`
- Modify: `internal/chat/claude_translate.go` (unexported `clearInterrupted`)
- Modify: `internal/chat/replay.go`, `internal/chat/replay_test.go` (`ReplayFromDB`)
- Create: `internal/chat/attachments.go` (stub; Task 20 replaces the body)
- Create: `internal/chat/testdata/fake_claude.sh`
- Modify: `internal/ai/client.go` (export `DisallowedTools`, `AllowedTools`, `ChatMCPConfig`; methods delegate)
- Modify: `internal/ai/client_test.go` (equivalence test)
- Create: `cmd/ai_session.go`, `cmd/ai_session_test.go`

**Interfaces:**
- Consumes: Task 1 `db.GetChatConversation`, `db.ActiveChatPath`, `db.ChatStepSummaries`; Task 2 `Event`, `Command`, `Attachment`, `EventWriter`, `ClaudeTranslator`, `ClassifyClaudeError`, `errorEvent`, `isTerminal`; Task 4 `HistoryBefore`, `BuildReplaySteps`, `ReplayCapChars`; Task 5 `BuildSystemPrompt`, `PromptOptions`; Task 6 `WriteTurnFile`, `--turn-file`.
- Produces (binding):
  - `type Backend interface{ Start(ctx context.Context) (sessionID string, err error); Turn(ctx context.Context, cmd Command, emit func(Event)) error; Cancel() error; Close() error }` — `emit` is only called from inside `Turn`, on `Turn`'s goroutine.
  - `type Session struct{ Provider, Model, TurnFile string; … }`; `func NewSession(b Backend, w *EventWriter) *Session`; `func (s *Session) Run(ctx context.Context, in io.Reader) error` — emits `session_ready`, runs one turn at a time, guarantees exactly one terminal event per turn, writes `TurnFile` before each turn's `turn_start`, and on `close`/stdin EOF/ctx cancel cancels the running turn and calls `Backend.Close` before returning.
  - `type ClaudeOptions struct{ Binary, Model, ResumeSessionID, SystemPrompt, MCPConfig, AllowedTools, DisallowedTools string; Env []string; Replay func(turnID string) (string, error); InterruptGrace, CloseGrace time.Duration }`; `func NewClaudeBackend(opts ClaudeOptions) Backend`.
  - `func ReplayFromDB(d *db.DB, conversationID int64, turnID string) (string, error)` — `BuildReplaySteps` over `HistoryBefore(ActiveChatPath)` with `ChatStepSummaries`.
  - `func BuildContentBlocks(atts []Attachment) ([]json.RawMessage, error)` — stub: `nil, nil` for none, an error for any attachment (Task 20 implements it).
  - `ai.DisallowedTools`, `func ai.AllowedTools(ext []ai.ExternalMCPServer) string`, `func ai.ChatMCPConfig(dbPath string, mcpArgs []string, ext []ai.ExternalMCPServer) string`.
  - `watchtower ai session --conversation N [--provider P] [--model M] [--surface main|target] [--project-id K] [--resume SID] [--db-path PATH]`; reads commands on stdin, writes v2 events on stdout; the backend is chosen in `newSessionBackend(...)` (claude here; Task 8 adds codex/ollama).

- [ ] **Step 1: Export the MCP-config helpers from `internal/ai`**

Append to `internal/ai/client_test.go`:

```go
// The warm chat session builds its MCP config with the exported helpers; they
// must render exactly what the one-shot client sends, so `ai query` and
// `ai session` expose the same tools.
func TestChatMCPConfig_MatchesClient(t *testing.T) {
	ext := []ExternalMCPServer{{Name: "confluence", Kind: "http", URL: "https://mcp.example.com"}}
	args := []string{"--chat", "--surface", "main", "--conversation", "7", "--turn-file", "/tmp/t"}
	c := NewClient("m", "/tmp/wt.db", "")
	c.SetMCPArgs(args)
	c.SetExternalMCPServers(ext)

	assert.Equal(t, c.buildMCPConfig(), ChatMCPConfig("/tmp/wt.db", args, ext))
	assert.Equal(t, c.allowedToolsFlag(), AllowedTools(ext))
	assert.Equal(t, "mcp__watchtower,mcp__confluence", AllowedTools(ext))
	assert.Contains(t, DisallowedTools, "Bash")
	assert.Contains(t, DisallowedTools, "WebFetch")
}
```

Run: `go test ./internal/ai/ -run TestChatMCPConfig_MatchesClient`
Expected: FAIL — `undefined: ChatMCPConfig`.

In `internal/ai/client.go`:

1. Add, above `func (c *Client) allowedToolsFlag`:

```go
// DisallowedTools hides every built-in Claude Code tool from the chat model
// (see buildArgs for why each group is hidden). Shared by the one-shot client
// and the warm `ai session` backend.
const DisallowedTools = "Edit,Write,NotebookEdit,TodoWrite,Task,TodoRead," +
	"Bash,BashOutput,KillShell,WebSearch,WebFetch,Read,Grep,Glob,LS," +
	"ExitPlanMode,SlashCommand,Skill"

// AllowedTools builds the --allowedTools value: the built-in watchtower
// server plus one mcp__<Name> token per external server, in slice order.
func AllowedTools(ext []ExternalMCPServer) string {
	tools := "mcp__watchtower"
	for _, s := range ext {
		tools += ",mcp__" + s.Name
	}
	return tools
}

// ChatMCPConfig renders the chat's mcp-config JSON: the watchtower server
// (this binary as `mcp --db-path <db>` plus mcpArgs) and every external
// server. Shared by the one-shot client and the warm `ai session` backend.
func ChatMCPConfig(dbPath string, mcpArgs []string, ext []ExternalMCPServer) string {
	args := append([]string{"mcp", "--db-path", dbPath}, mcpArgs...)
	servers := map[string]any{
		"watchtower": map[string]any{
			"command": watchtowerBinary(),
			"args":    args,
		},
	}
	for _, s := range ext {
		servers[s.Name] = externalServerConfig(s)
	}
	data, err := json.Marshal(map[string]any{"mcpServers": servers})
	if err != nil {
		return "{}"
	}
	return string(data)
}
```

2. Replace the bodies of `allowedToolsFlag` and `buildMCPConfig` with `return AllowedTools(c.externalServers)` and `return ChatMCPConfig(c.dbPath, c.mcpArgs, c.externalServers)` (keep their doc comments).

3. In `buildArgs`, replace the two-line `"--disallowedTools", "Edit,Write,…" + "…Skill",` value with `"--disallowedTools", DisallowedTools,` (keep the comment above it).

Run: `go test ./internal/ai/`
Expected: PASS.

- [ ] **Step 2: Add the fake `claude` and the attachment stub**

Create `internal/chat/testdata/fake_claude.sh`:

```sh
#!/bin/sh
# Fake `claude` for internal/chat backend tests; behaviour by $FAKE_MODE:
#   normal (default) · slow (first turn never finishes until interrupted)
#   ignore_interrupt (first turn never finishes and ignores the interrupt)
#   crash_once (dies on the first user message ever) · lost (--resume rejected)
#   stubborn (ignores SIGTERM and stdin EOF) · grandchild (leaves a child behind)
# Appends argv (one arg per line, runs separated by "--") to $FAKE_ARGV and
# every stdin line to $FAKE_STDIN. "Once" modes key on the $FAKE_MARK file.
{ for a in "$@"; do printf '%s\n' "$a"; done; echo "--"; } >> "$FAKE_ARGV"

resumed=no
for a in "$@"; do [ "$a" = "--resume" ] && resumed=yes; done

if [ "$FAKE_MODE" = "lost" ] && [ "$resumed" = yes ]; then
  echo "No conversation found with session ID: gone" >&2
  exit 1
fi
if [ "$FAKE_MODE" = "stubborn" ]; then
  trap '' TERM
  echo $$ > "$FAKE_PID"
  sleep 300 &
  echo $! > "$FAKE_CHILD_PID"
  while :; do sleep 1; done
fi
if [ "$FAKE_MODE" = "grandchild" ]; then
  sleep 300 &
  echo $! > "$FAKE_CHILD_PID"
fi

first_time() {
  if [ -f "$FAKE_MARK" ]; then return 1; fi
  : > "$FAKE_MARK"
  return 0
}

reply() {
  printf '%s\n' '{"type":"stream_event","event":{"type":"message_start","message":{"model":"fake-model"}}}'
  printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text"}}}'
  printf '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"%s"}}}\n' "$1"
  printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_stop","index":0}}'
  printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"sess-fake","usage":{"input_tokens":3,"output_tokens":2}}'
}

n=0
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$FAKE_STDIN"
  case "$line" in
    *'"subtype":"interrupt"'*)
      [ "$FAKE_MODE" = "ignore_interrupt" ] && continue
      printf '%s\n' '{"type":"control_response","response":{"subtype":"success"}}'
      printf '%s\n' '{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"sess-fake","usage":{"input_tokens":1,"output_tokens":0}}'
      ;;
    *'"type":"user"'*)
      n=$((n+1))
      case "$FAKE_MODE" in
        crash_once)
          if first_time; then exit 3; fi ;;
        slow|ignore_interrupt)
          if first_time; then
            printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"partial"}}}'
            continue
          fi ;;
      esac
      reply "turn $n"
      ;;
  esac
done
```

Create `internal/chat/attachments.go`:

```go
package chat

import (
	"encoding/json"
	"fmt"
)

// BuildContentBlocks turns a turn's attachments into provider content blocks.
// Task 20 implements it; until then every attachment is rejected (surfaced as
// attachment_unsupported) so nothing is silently dropped. The error names the
// file, never its path.
func BuildContentBlocks(atts []Attachment) ([]json.RawMessage, error) {
	if len(atts) == 0 {
		return nil, nil
	}
	return nil, fmt.Errorf("attachments are not supported yet: %s", atts[0].Name)
}
```

- [ ] **Step 3: Write the failing session tests (fake backend)**

Create `internal/chat/session_test.go`:

```go
package chat

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// harness runs a Session over pipes and collects its events.
type harness struct {
	t      *testing.T
	in     *io.PipeWriter
	events chan Event
	done   chan error
	cancel context.CancelFunc
}

func startSession(t *testing.T, b Backend, configure func(*Session)) *harness {
	t.Helper()
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	s := NewSession(b, NewEventWriter(outW))
	if configure != nil {
		configure(s)
	}
	ctx, cancel := context.WithCancel(context.Background())
	h := &harness{t: t, in: inW, events: make(chan Event, 1024), done: make(chan error, 1), cancel: cancel}
	go func() {
		sc := bufio.NewScanner(outR)
		sc.Buffer(make([]byte, 0, 64<<10), 16<<20)
		for sc.Scan() {
			var e Event
			if json.Unmarshal(sc.Bytes(), &e) == nil {
				h.events <- e
			}
		}
		close(h.events)
	}()
	go func() {
		err := s.Run(ctx, inR)
		_ = outW.Close()
		h.done <- err
	}()
	t.Cleanup(func() {
		cancel()
		_ = inW.Close()
	})
	return h
}

func (h *harness) send(c Command) {
	h.t.Helper()
	b, err := json.Marshal(c)
	require.NoError(h.t, err)
	_, err = h.in.Write(append(b, '\n'))
	require.NoError(h.t, err)
}

func (h *harness) sendRaw(line string) {
	h.t.Helper()
	_, err := h.in.Write([]byte(line + "\n"))
	require.NoError(h.t, err)
}

// next returns the next event of type want, skipping others; fails after 10 s.
func (h *harness) next(want string) Event {
	h.t.Helper()
	deadline := time.After(10 * time.Second)
	for {
		select {
		case e, ok := <-h.events:
			require.True(h.t, ok, "session ended before a %s event", want)
			if e.Type == want {
				return e
			}
		case <-deadline:
			h.t.Fatalf("no %s event within 10s", want)
		}
	}
}

// finish closes stdin and waits for Run to return.
func (h *harness) finish() error {
	h.t.Helper()
	_ = h.in.Close()
	select {
	case err := <-h.done:
		return err
	case <-time.After(15 * time.Second):
		h.t.Fatal("session did not stop within 15s of stdin EOF")
		return nil
	}
}

// fakeBackend scripts a Backend.
type fakeBackend struct {
	mu       sync.Mutex
	startErr error
	turn     func(ctx context.Context, c Command, emit func(Event)) error
	release  chan struct{}
	cancels  int
	closed   bool
}

func (f *fakeBackend) Start(context.Context) (string, error) { return "sess-0", f.startErr }
func (f *fakeBackend) Turn(ctx context.Context, c Command, emit func(Event)) error {
	return f.turn(ctx, c, emit)
}
func (f *fakeBackend) Cancel() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.cancels++
	if f.release != nil {
		close(f.release)
		f.release = nil
	}
	return nil
}
func (f *fakeBackend) Close() error {
	f.mu.Lock()
	f.closed = true
	f.mu.Unlock()
	return nil
}

func echoTurn(_ context.Context, c Command, emit func(Event)) error {
	emit(Event{Type: EventTextDelta, Text: "echo: " + c.Text})
	emit(Event{Type: EventTurnDone, Status: StatusComplete})
	return nil
}

func TestSession_ReadyTurnClose(t *testing.T) {
	fb := &fakeBackend{turn: echoTurn}
	h := startSession(t, fb, func(s *Session) { s.Provider, s.Model = "claude", "sonnet" })

	ready := h.next(EventSessionReady)
	assert.Equal(t, "sess-0", ready.SessionID)
	assert.Equal(t, "claude", ready.Provider)
	assert.Equal(t, "sonnet", ready.Model)

	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "hi"})
	assert.Equal(t, "t1", h.next(EventTurnStart).TurnID)
	delta := h.next(EventTextDelta)
	assert.Equal(t, "echo: hi", delta.Text)
	assert.Equal(t, "t1", delta.TurnID, "the session stamps the turn id")
	assert.Equal(t, StatusComplete, h.next(EventTurnDone).Status)

	h.send(Command{Type: CommandClose})
	require.NoError(t, <-h.done)
	assert.True(t, fb.closed, "close always closes the backend")
}

func TestSession_RejectsOverlappingTurnAndCancels(t *testing.T) {
	fb := &fakeBackend{release: make(chan struct{})}
	release := fb.release
	fb.turn = func(ctx context.Context, c Command, emit func(Event)) error {
		<-release
		emit(Event{Type: EventTurnDone, Status: StatusInterrupted})
		return nil
	}
	h := startSession(t, fb, nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "long"})
	h.next(EventTurnStart)

	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "second"})
	busy := h.next(EventError)
	assert.Equal(t, "t2", busy.TurnID)
	assert.Contains(t, busy.Message, "already running")

	h.send(Command{Type: CommandCancel})
	done := h.next(EventTurnDone)
	assert.Equal(t, "t1", done.TurnID)
	assert.Equal(t, StatusInterrupted, done.Status)
	require.NoError(t, h.finish())
	assert.Equal(t, 1, fb.cancels)
}

func TestSession_WritesTurnFileBeforeTheTurn(t *testing.T) {
	path := filepath.Join(t.TempDir(), "turn.txt")
	read := TurnFileReader(path)
	fb := &fakeBackend{turn: func(_ context.Context, c Command, emit func(Event)) error {
		emit(Event{Type: EventTextDelta, Text: read()})
		emit(Event{Type: EventTurnDone, Status: StatusComplete})
		return nil
	}}
	h := startSession(t, fb, func(s *Session) { s.TurnFile = path })
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "turn-42", Text: "x"})
	assert.Equal(t, "turn-42", h.next(EventTextDelta).Text, "the MCP server reads the running turn from the file")
	require.NoError(t, h.finish())
}

func TestSession_BackendErrorWithoutTerminalBecomesTurnError(t *testing.T) {
	fb := &fakeBackend{turn: func(context.Context, Command, func(Event)) error {
		return errors.New("API Error: 429 rate_limit_error")
	}}
	h := startSession(t, fb, nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "x"})
	e := h.next(EventError)
	assert.Equal(t, "t1", e.TurnID)
	assert.Equal(t, CodeRateLimit, e.Code)
	assert.True(t, e.Retryable)
	require.NoError(t, h.finish())
}

func TestSession_ExactlyOneTerminalPerTurn(t *testing.T) {
	fb := &fakeBackend{turn: func(_ context.Context, _ Command, emit func(Event)) error {
		emit(Event{Type: EventTurnDone, Status: StatusComplete})
		emit(Event{Type: EventTurnDone, Status: StatusComplete})
		emit(Event{Type: EventTextDelta, Text: "late"})
		return nil
	}}
	h := startSession(t, fb, nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "x"})
	h.next(EventTurnDone)
	require.NoError(t, h.finish())
	for e := range h.events {
		assert.NotEqual(t, EventTurnDone, e.Type, "a second terminal event must be dropped")
		assert.NotEqual(t, "late", e.Text, "nothing after the terminal event")
	}
}

func TestSession_StartFailureIsProviderUnavailable(t *testing.T) {
	fb := &fakeBackend{startErr: errors.New(`starting claude: exec: "claude": executable file not found in $PATH`)}
	h := startSession(t, fb, nil)
	e := h.next(EventError)
	assert.Equal(t, CodeProviderUnavailable, e.Code)
	assert.Empty(t, e.TurnID)
	assert.Error(t, <-h.done)
	assert.True(t, fb.closed, "a failed start still cleans up (temp files)")
}

func TestSession_BadCommandIsReportedAndSessionContinues(t *testing.T) {
	h := startSession(t, &fakeBackend{turn: echoTurn}, nil)
	h.next(EventSessionReady)
	h.sendRaw(`{not json`)
	assert.Equal(t, CodeInternal, h.next(EventError).Code)
	h.sendRaw(`{"type":"dance"}`)
	assert.Contains(t, h.next(EventError).Message, "unknown command")
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "still here"})
	assert.Equal(t, "echo: still here", h.next(EventTextDelta).Text)
	require.NoError(t, h.finish())
}

func TestSession_TurnWithoutIDIsRejected(t *testing.T) {
	h := startSession(t, &fakeBackend{turn: echoTurn}, nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, Text: "no id"})
	assert.Contains(t, h.next(EventError).Message, "turn_id")
	require.NoError(t, h.finish())
}
```

Run: `go test ./internal/chat/ -run TestSession_`
Expected: FAIL to compile — `undefined: NewSession`.

- [ ] **Step 4: Write `session.go`**

Create `internal/chat/session.go`:

```go
package chat

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sync"
)

// maxCommandBytes bounds one stdin command line (a long pasted message).
const maxCommandBytes = 8 << 20

// Backend runs turns against one provider. emit is only ever called from
// inside Turn, on Turn's goroutine.
type Backend interface {
	// Start brings the provider up (for Claude: spawns the warm process) and
	// returns the session id it resumes, if any.
	Start(ctx context.Context) (sessionID string, err error)
	// Turn sends one owner turn and emits its events until the turn ends.
	Turn(ctx context.Context, cmd Command, emit func(Event)) error
	// Cancel asks the running turn to stop.
	Cancel() error
	// Close ends the provider session and reaps every child process.
	Close() error
}

// Session is the `watchtower ai session` loop: commands on stdin, protocol-v2
// events on stdout, one turn at a time.
type Session struct {
	Provider string // reported in session_ready
	Model    string // reported in session_ready
	TurnFile string // when set, the running turn id is written here before each turn (spec §1.2)

	b Backend
	w *EventWriter

	mu      sync.Mutex
	running string // turn id in flight, "" when idle
	wg      sync.WaitGroup
}

// NewSession wires a backend to an event writer.
func NewSession(b Backend, w *EventWriter) *Session { return &Session{b: b, w: w} }

type inbound struct {
	cmd Command
	err error
}

// Run starts the backend, emits session_ready and serves commands until
// close, stdin EOF or ctx cancellation — then cancels the running turn,
// closes the backend (reaping its processes) and waits for the turn to end.
func (s *Session) Run(ctx context.Context, in io.Reader) error {
	sid, err := s.b.Start(ctx)
	if err != nil {
		code, retry := ClassifyClaudeError(err.Error())
		if code == CodeInternal {
			code = CodeProviderUnavailable
		}
		_ = s.w.Emit(Event{Type: EventError, Code: code, Message: err.Error(), Retryable: retry})
		_ = s.b.Close()
		return err
	}
	if err := s.w.Emit(Event{Type: EventSessionReady, SessionID: sid, Provider: s.Provider, Model: s.Model}); err != nil {
		_ = s.b.Close()
		return err
	}

	done := make(chan struct{})
	cmds := make(chan inbound)
	go readCommands(in, cmds, done)

	turnCtx, cancelTurns := context.WithCancel(ctx)
	defer func() {
		close(done)
		cancelTurns()
		_ = s.b.Close()
		s.wg.Wait()
	}()

	for {
		select {
		case <-ctx.Done():
			return nil
		case m, ok := <-cmds:
			if !ok {
				return nil // stdin EOF: the app went away
			}
			if m.err != nil {
				_ = s.w.Emit(Event{Type: EventError, Code: CodeInternal, Message: m.err.Error()})
				continue
			}
			switch m.cmd.Type {
			case CommandTurn:
				s.startTurn(turnCtx, m.cmd)
			case CommandCancel:
				s.cancel()
			case CommandClose:
				return nil
			default:
				_ = s.w.Emit(Event{Type: EventError, Code: CodeInternal, Message: fmt.Sprintf("unknown command %q", m.cmd.Type)})
			}
		}
	}
}

func readCommands(in io.Reader, out chan<- inbound, done <-chan struct{}) {
	defer close(out)
	sc := bufio.NewScanner(in)
	sc.Buffer(make([]byte, 0, 64<<10), maxCommandBytes)
	for sc.Scan() {
		line := bytes.TrimSpace(sc.Bytes())
		if len(line) == 0 {
			continue
		}
		var msg inbound
		if err := json.Unmarshal(line, &msg.cmd); err != nil {
			msg.err = fmt.Errorf("invalid command: %w", err)
		}
		select {
		case out <- msg:
		case <-done:
			return
		}
	}
	if err := sc.Err(); err != nil {
		select {
		case out <- inbound{err: fmt.Errorf("reading commands: %w", err)}:
		case <-done:
		}
	}
}

func (s *Session) startTurn(ctx context.Context, c Command) {
	if c.TurnID == "" {
		_ = s.w.Emit(Event{Type: EventError, Code: CodeInternal, Message: "turn command without turn_id"})
		return
	}
	s.mu.Lock()
	if s.running != "" {
		s.mu.Unlock()
		_ = s.w.Emit(errorEvent(c.TurnID, CodeInternal, "a turn is already running in this session", true))
		return
	}
	s.running = c.TurnID
	s.mu.Unlock()

	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		defer func() {
			s.mu.Lock()
			s.running = ""
			s.mu.Unlock()
		}()
		s.runTurn(ctx, c)
	}()
}

// runTurn publishes the turn id, emits turn_start, runs the backend and makes
// sure exactly one terminal event (turn_done or a turn error) goes out.
func (s *Session) runTurn(ctx context.Context, c Command) {
	if s.TurnFile != "" {
		if err := WriteTurnFile(s.TurnFile, c.TurnID); err != nil {
			_ = s.w.Emit(errorEvent(c.TurnID, CodeInternal, "recording the turn id: "+err.Error(), true))
			return
		}
	}
	_ = s.w.Emit(Event{Type: EventTurnStart, TurnID: c.TurnID})

	terminal := false
	emit := func(e Event) {
		if terminal {
			return
		}
		if e.TurnID == "" {
			e.TurnID = c.TurnID
		}
		if isTerminal(e) {
			terminal = true
		}
		_ = s.w.Emit(e)
	}
	err := s.b.Turn(ctx, c, emit)
	if terminal {
		return
	}
	switch {
	case ctx.Err() != nil:
		emit(Event{Type: EventTurnDone, Status: StatusInterrupted})
	case err == nil:
		emit(errorEvent(c.TurnID, CodeInternal, "the turn ended without a result", true))
	case errors.Is(err, context.Canceled):
		emit(Event{Type: EventTurnDone, Status: StatusInterrupted})
	default:
		code, retry := ClassifyClaudeError(err.Error())
		emit(errorEvent(c.TurnID, code, err.Error(), retry))
	}
}

func (s *Session) cancel() {
	s.mu.Lock()
	running := s.running
	s.mu.Unlock()
	if running == "" {
		return
	}
	if err := s.b.Cancel(); err != nil {
		_ = s.w.Emit(Event{Type: EventError, Code: CodeInternal, Message: "cancel: " + err.Error()})
	}
}
```

Run: `go test ./internal/chat/ -run TestSession_`
Expected: PASS.

- [ ] **Step 5: Write the failing Claude backend tests**

Create `internal/chat/claude_backend_test.go`:

```go
package chat

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

type fakeFiles struct{ argv, stdin, pid, childPID, mark string }

// fakeClaude installs testdata/fake_claude.sh as an executable `claude` and
// returns backend options pointing at it.
func fakeClaude(t *testing.T, mode string) (ClaudeOptions, fakeFiles) {
	t.Helper()
	dir := t.TempDir()
	script, err := os.ReadFile(filepath.Join("testdata", "fake_claude.sh"))
	require.NoError(t, err)
	bin := filepath.Join(dir, "claude")
	require.NoError(t, os.WriteFile(bin, script, 0o755))
	f := fakeFiles{
		argv: filepath.Join(dir, "argv"), stdin: filepath.Join(dir, "stdin"),
		pid: filepath.Join(dir, "pid"), childPID: filepath.Join(dir, "child"), mark: filepath.Join(dir, "mark"),
	}
	return ClaudeOptions{
		Binary: bin, Model: "fake-model", SystemPrompt: "SYSTEM-PROMPT-SECRET",
		MCPConfig: `{"mcpServers":{}}`, AllowedTools: "mcp__watchtower", DisallowedTools: "Bash",
		Env: []string{"FAKE_MODE=" + mode, "FAKE_ARGV=" + f.argv, "FAKE_STDIN=" + f.stdin,
			"FAKE_PID=" + f.pid, "FAKE_CHILD_PID=" + f.childPID, "FAKE_MARK=" + f.mark},
		InterruptGrace: 300 * time.Millisecond,
		CloseGrace:     200 * time.Millisecond,
	}, f
}

// argvRuns splits the fake's argv log into one slice per process run.
func argvRuns(t *testing.T, path string) [][]string {
	t.Helper()
	data, err := os.ReadFile(path)
	require.NoError(t, err)
	var runs [][]string
	var cur []string
	for _, l := range strings.Split(strings.TrimRight(string(data), "\n"), "\n") {
		if l == "--" {
			runs = append(runs, cur)
			cur = nil
			continue
		}
		cur = append(cur, l)
	}
	return runs
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func readPIDFile(t *testing.T, path string) int {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if b, err := os.ReadFile(path); err == nil {
			if pid, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil && pid > 0 {
				return pid
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("pid file %s never appeared", path)
	return 0
}

// waitGone polls until pid no longer exists (reaped), failing after 5 s.
func waitGone(t *testing.T, pid int, what string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if err := syscall.Kill(pid, 0); errors.Is(err, syscall.ESRCH) {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("%s (pid %d) is still alive", what, pid)
}

func TestClaudeBackend_MultiTurnInOneWarmProcess(t *testing.T) {
	opts, f := fakeClaude(t, "normal")
	h := startSession(t, NewClaudeBackend(opts), nil)
	h.next(EventSessionReady)

	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "hello"})
	assert.Equal(t, "turn 1", h.next(EventTextDelta).Text)
	u := h.next(EventUsage)
	assert.Equal(t, 3, u.TokensIn)
	done := h.next(EventTurnDone)
	assert.Equal(t, StatusComplete, done.Status)
	assert.Equal(t, "sess-fake", done.SessionID)

	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "again"})
	assert.Equal(t, "turn 2", h.next(EventTextDelta).Text, "the second turn reaches the same process")
	h.next(EventTurnDone)
	require.NoError(t, h.finish())

	assert.Len(t, argvRuns(t, f.argv), 1, "one claude process for the whole conversation")
}

func TestClaudeBackend_CancelInterruptsAndProcessStaysWarm(t *testing.T) {
	opts, f := fakeClaude(t, "slow")
	h := startSession(t, NewClaudeBackend(opts), nil)
	h.next(EventSessionReady)

	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "long answer please"})
	assert.Equal(t, "partial", h.next(EventTextDelta).Text)
	h.send(Command{Type: CommandCancel})
	done := h.next(EventTurnDone)
	assert.Equal(t, "t1", done.TurnID)
	assert.Equal(t, StatusInterrupted, done.Status)

	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "next"})
	assert.Equal(t, "turn 2", h.next(EventTextDelta).Text)
	assert.Equal(t, StatusComplete, h.next(EventTurnDone).Status)
	require.NoError(t, h.finish())

	stdin, err := os.ReadFile(f.stdin)
	require.NoError(t, err)
	assert.Contains(t, string(stdin), `"subtype":"interrupt"`, "cancel sends the interrupt control request")
	assert.Len(t, argvRuns(t, f.argv), 1)
}

func TestClaudeBackend_CancelKillsAfterGraceAndNextTurnResumes(t *testing.T) {
	opts, f := fakeClaude(t, "ignore_interrupt")
	opts.ResumeSessionID = "sess-0"
	h := startSession(t, NewClaudeBackend(opts), nil)
	h.next(EventSessionReady)

	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "long"})
	h.next(EventTextDelta)
	h.send(Command{Type: CommandCancel})
	done := h.next(EventTurnDone)
	assert.Equal(t, StatusInterrupted, done.Status, "no result within the grace → killed, still reported as interrupted")

	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "next"})
	assert.Equal(t, "turn 1", h.next(EventTextDelta).Text, "a fresh process answers")
	h.next(EventTurnDone)
	require.NoError(t, h.finish())

	runs := argvRuns(t, f.argv)
	require.Len(t, runs, 2)
	assert.True(t, contains(runs[1], "--resume"), "the respawn resumes the session")
}

func TestClaudeBackend_CrashThenNextTurnRespawnsWithResume(t *testing.T) {
	opts, f := fakeClaude(t, "crash_once")
	opts.ResumeSessionID = "sess-0"
	h := startSession(t, NewClaudeBackend(opts), nil)
	h.next(EventSessionReady)

	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "x"})
	e := h.next(EventError)
	assert.Equal(t, "t1", e.TurnID)
	assert.Equal(t, CodeInternal, e.Code)
	assert.True(t, e.Retryable)

	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "retry"})
	assert.Equal(t, "turn 1", h.next(EventTextDelta).Text)
	assert.Equal(t, StatusComplete, h.next(EventTurnDone).Status)
	require.NoError(t, h.finish())

	runs := argvRuns(t, f.argv)
	require.Len(t, runs, 2)
	idx := indexOf(runs[1], "--resume")
	require.GreaterOrEqual(t, idx, 0)
	assert.Equal(t, "sess-0", runs[1][idx+1])
}

func indexOf(list []string, s string) int {
	for i, x := range list {
		if x == s {
			return i
		}
	}
	return -1
}

// TestClaudeBackend_SessionLostRetriesWithReplay: a rejected --resume is
// retried once as a fresh session carrying the replayed history — the owner
// sees an answer, not an error (spec §5, Review Focus 5).
func TestClaudeBackend_SessionLostRetriesWithReplay(t *testing.T) {
	opts, f := fakeClaude(t, "lost")
	opts.ResumeSessionID = "gone"
	opts.Replay = func(turnID string) (string, error) {
		assert.Equal(t, "t1", turnID)
		return "=== CONVERSATION SO FAR ===\nOwner: earlier question\n=== END ===\n\n", nil
	}
	h := startSession(t, NewClaudeBackend(opts), nil)
	h.next(EventSessionReady)

	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "hello"})
	assert.Equal(t, "turn 1", h.next(EventTextDelta).Text)
	assert.Equal(t, StatusComplete, h.next(EventTurnDone).Status)
	require.NoError(t, h.finish())
	for e := range h.events {
		assert.NotEqual(t, EventError, e.Type, "session_lost is recovered silently")
	}

	runs := argvRuns(t, f.argv)
	last := runs[len(runs)-1]
	assert.False(t, contains(last, "--resume"), "the retry starts a fresh session")
	assert.True(t, contains(last, "--system-prompt-file"), "a fresh session gets the system prompt")
	stdin, err := os.ReadFile(f.stdin)
	require.NoError(t, err)
	assert.Contains(t, string(stdin), "CONVERSATION SO FAR")
	assert.Contains(t, string(stdin), "hello")
}

func TestClaudeBackend_ReplayCommandStartsFreshSession(t *testing.T) {
	opts, f := fakeClaude(t, "normal")
	opts.ResumeSessionID = "sess-0"
	opts.Replay = func(string) (string, error) { return "=== CONVERSATION SO FAR ===\n=== END ===\n\n", nil }
	h := startSession(t, NewClaudeBackend(opts), nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "edited question", Replay: true})
	h.next(EventTurnDone)
	require.NoError(t, h.finish())

	runs := argvRuns(t, f.argv)
	require.Len(t, runs, 2, "the warm process is replaced by a fresh one")
	assert.True(t, contains(runs[0], "--resume"))
	assert.False(t, contains(runs[1], "--resume"))
}

// TestChat04_ClaudeArgvCarriesNoContent: CHAT-04 — the system prompt, the
// owner's text and attachment paths never appear on any process's argv; the
// prompt travels in a 0600 file, the text on stdin.
func TestChat04_ClaudeArgvCarriesNoContent(t *testing.T) {
	opts, f := fakeClaude(t, "normal")
	h := startSession(t, NewClaudeBackend(opts), nil)
	h.next(EventSessionReady)

	h.send(Command{Type: CommandTurn, TurnID: "t0", Text: "see attached",
		Attachments: []Attachment{{Path: "/private/ATTACHMENT-PATH-SECRET.png", Mime: "image/png", Name: "x.png"}}})
	assert.Equal(t, CodeAttachmentUnsupported, h.next(EventError).Code)

	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "USER-TEXT-SECRET"})
	h.next(EventTurnDone)

	runs := argvRuns(t, f.argv)
	require.Len(t, runs, 1)
	argv := strings.Join(runs[0], "\n")
	for _, secret := range []string{"SYSTEM-PROMPT-SECRET", "USER-TEXT-SECRET", "ATTACHMENT-PATH-SECRET"} {
		assert.NotContains(t, argv, secret)
	}
	i := indexOf(runs[0], "--system-prompt-file")
	require.GreaterOrEqual(t, i, 0)
	promptFile := runs[0][i+1]
	data, err := os.ReadFile(promptFile)
	require.NoError(t, err)
	assert.Equal(t, "SYSTEM-PROMPT-SECRET", string(data))
	info, err := os.Stat(promptFile)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm())

	stdin, err := os.ReadFile(f.stdin)
	require.NoError(t, err)
	assert.Contains(t, string(stdin), "USER-TEXT-SECRET", "the owner's text travels on stdin")
	require.NoError(t, h.finish())

	_, err = os.Stat(promptFile)
	assert.True(t, os.IsNotExist(err), "the prompt file is deleted when the session exits")
}

func TestChat04_ClaudeArgsOnResume(t *testing.T) {
	args := claudeArgs(ClaudeOptions{Model: "sonnet", AllowedTools: "mcp__watchtower", DisallowedTools: "Bash"},
		"/tmp/p", "/tmp/m", "sess-9")
	assert.True(t, contains(args, "--resume"))
	assert.False(t, contains(args, "--system-prompt-file"), "a resumed session reuses its recorded prompt")
	assert.True(t, contains(args, "--input-format"))
	assert.True(t, contains(args, "--include-partial-messages"))
	assert.True(t, contains(args, "/tmp/m"), "mcp config travels as a file path")
}

// TestClaudeBackend_CloseReapsStubbornChild: Review Focus 2 — a child that
// ignores stdin EOF and SIGTERM, and its own child, are both gone after Close.
func TestClaudeBackend_CloseReapsStubbornChild(t *testing.T) {
	opts, f := fakeClaude(t, "stubborn")
	b := NewClaudeBackend(opts)
	_, err := b.Start(context.Background())
	require.NoError(t, err)
	leader := readPIDFile(t, f.pid)
	child := readPIDFile(t, f.childPID)

	start := time.Now()
	require.NoError(t, b.Close())
	assert.Less(t, time.Since(start), 3*time.Second, "EOF, TERM, then KILL — bounded")
	waitGone(t, leader, "claude")
	waitGone(t, child, "claude's child")
}

func TestClaudeBackend_StdinEOFEndsSessionAndSweepsGroup(t *testing.T) {
	opts, f := fakeClaude(t, "grandchild")
	s := NewSession(NewClaudeBackend(opts), NewEventWriter(io.Discard))
	require.NoError(t, s.Run(context.Background(), strings.NewReader("")))
	waitGone(t, readPIDFile(t, f.childPID), "the MCP-server stand-in left behind by claude")
}

func TestClaudeBackend_ContextCancelEndsSession(t *testing.T) {
	opts, f := fakeClaude(t, "grandchild")
	inR, inW := io.Pipe()
	defer inW.Close()
	ctx, cancel := context.WithCancel(context.Background())
	s := NewSession(NewClaudeBackend(opts), NewEventWriter(io.Discard))
	done := make(chan error, 1)
	go func() { done <- s.Run(ctx, inR) }()

	child := readPIDFile(t, f.childPID)
	cancel()
	select {
	case err := <-done:
		assert.NoError(t, err)
	case <-time.After(5 * time.Second):
		t.Fatal("Run did not return after ctx cancel")
	}
	waitGone(t, child, "claude's child")
}

func TestClaudeBackend_MissingBinaryIsProviderUnavailable(t *testing.T) {
	opts, _ := fakeClaude(t, "normal")
	opts.Binary = filepath.Join(t.TempDir(), "no-such-claude")
	h := startSession(t, NewClaudeBackend(opts), nil)
	e := h.next(EventError)
	assert.Equal(t, CodeProviderUnavailable, e.Code)
	assert.True(t, e.Retryable)
}
```

Run: `go test ./internal/chat/ -run 'TestClaudeBackend|TestChat04'`
Expected: FAIL to compile — `undefined: NewClaudeBackend`, `undefined: claudeArgs`.

- [ ] **Step 6: Write the Claude backend**

Create `internal/chat/claude_backend.go`:

```go
package chat

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"watchtower/internal/claude"
)

// ClaudeOptions configures the warm Claude backend.
type ClaudeOptions struct {
	Binary          string   // claude executable; "" = claude.FindBinary("")
	Model           string   // --model; "" = the CLI default
	ResumeSessionID string   // --resume on the first spawn; "" = fresh session
	SystemPrompt    string   // written to a 0600 file, passed as --system-prompt-file
	MCPConfig       string   // mcp-config JSON, written to a 0600 file; "" = none
	AllowedTools    string   // --allowedTools
	DisallowedTools string   // --disallowedTools
	Env             []string // extra environment (tests)
	// Replay renders the history before turnID (BuildReplaySteps output) for a
	// fresh provider session that is not continuous with the branch.
	Replay         func(turnID string) (string, error)
	InterruptGrace time.Duration // default 5 s: kill if no result after an interrupt
	CloseGrace     time.Duration // default 2 s per step: stdin EOF → SIGTERM → SIGKILL
}

// claudeProc is one running `claude -p --input-format stream-json` child.
type claudeProc struct {
	cmd       *exec.Cmd
	pgid      int
	stdin     io.WriteCloser
	writeMu   sync.Mutex
	events    chan Event
	exited    chan struct{} // closed once cmd.Wait returns
	outDone   chan struct{} // closed when stdout reaches EOF
	errDone   chan struct{} // closed when stderr reaches EOF
	stop      chan struct{} // closed to release a reader blocked on events
	stopOnce  sync.Once
	stderr    *boundedBuffer
	resumed   bool
	gotResult atomic.Bool
}

func (p *claudeProc) write(b []byte) error {
	p.writeMu.Lock()
	defer p.writeMu.Unlock()
	_, err := p.stdin.Write(b)
	return err
}

func (p *claudeProc) closeStdin() {
	p.writeMu.Lock()
	defer p.writeMu.Unlock()
	_ = p.stdin.Close()
}

type claudeBackend struct {
	opts       ClaudeOptions
	tr         *ClaudeTranslator
	promptFile string
	mcpFile    string
	curTurn    atomic.Value // string: the running turn id (read by the translator)
	active     atomic.Bool  // a Turn is in flight
	closeOnce  sync.Once

	mu        sync.Mutex
	proc      *claudeProc
	resume    string // session id the next spawn resumes ("" = fresh)
	cancelled bool
}

// NewClaudeBackend returns a backend that keeps one warm claude process for
// the conversation: turns go to its stdin as stream-json user messages, its
// stream-json stdout is translated to protocol v2.
func NewClaudeBackend(opts ClaudeOptions) Backend {
	if opts.Binary == "" {
		opts.Binary = claude.FindBinary("")
	}
	if opts.InterruptGrace <= 0 {
		opts.InterruptGrace = 5 * time.Second
	}
	if opts.CloseGrace <= 0 {
		opts.CloseGrace = 2 * time.Second
	}
	b := &claudeBackend{opts: opts, resume: opts.ResumeSessionID}
	b.curTurn.Store("")
	b.tr = NewClaudeTranslator(func() string { s, _ := b.curTurn.Load().(string); return s })
	return b
}

// claudeArgs builds the child's argv. It never carries content (CHAT-04): the
// system prompt and MCP config are file paths, the owner's text goes to stdin.
func claudeArgs(o ClaudeOptions, promptFile, mcpFile, resume string) []string {
	args := []string{"-p", "--input-format", "stream-json", "--output-format", "stream-json",
		"--include-partial-messages", "--verbose",
		// Skip user-level settings: their plugins/hooks probe ~/Desktop and
		// ~/Documents at startup and trigger TCC prompts (see internal/ai).
		"--setting-sources", "project,local"}
	if o.Model != "" {
		args = append(args, "--model", o.Model)
	}
	if mcpFile != "" {
		args = append(args, "--mcp-config", mcpFile)
	}
	if o.AllowedTools != "" {
		args = append(args, "--allowedTools", o.AllowedTools)
	}
	if o.DisallowedTools != "" {
		args = append(args, "--disallowedTools", o.DisallowedTools)
	}
	if resume != "" {
		// A resumed session reuses the prompt recorded with it (spec §1.3).
		args = append(args, "--resume", resume)
	} else {
		args = append(args, "--system-prompt-file", promptFile)
	}
	return args
}

// Start writes the prompt/MCP files and spawns the warm process.
func (b *claudeBackend) Start(ctx context.Context) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	var err error
	if b.promptFile, err = writePrivateTemp("wt-chat-prompt-*.txt", b.opts.SystemPrompt); err != nil {
		return "", fmt.Errorf("writing system prompt file: %w", err)
	}
	if b.opts.MCPConfig != "" {
		if b.mcpFile, err = writePrivateTemp("wt-chat-mcp-*.json", b.opts.MCPConfig); err != nil {
			return "", fmt.Errorf("writing mcp config file: %w", err)
		}
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if _, err := b.spawnLocked(); err != nil {
		return "", err
	}
	return b.resume, nil
}

func (b *claudeBackend) spawnLocked() (*claudeProc, error) {
	cmd := exec.Command(b.opts.Binary, claudeArgs(b.opts, b.promptFile, b.mcpFile, b.resume)...)
	// A TCC-neutral cwd: never inherit one inside ~/Documents or ~/Desktop.
	cmd.Dir = os.TempDir()
	cmd.Env = append(append(os.Environ(), "PATH="+claude.RichPATH()), b.opts.Env...)
	// Own process group, so Close can reap the MCP servers claude spawns.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("claude stdin: %w", err)
	}
	// os.Pipe (not StdoutPipe): Wait must not depend on stdout EOF, which a
	// grandchild holding the pipe would delay.
	outR, outW, err := os.Pipe()
	if err != nil {
		return nil, fmt.Errorf("claude stdout: %w", err)
	}
	errR, errW, err := os.Pipe()
	if err != nil {
		outR.Close()
		outW.Close()
		return nil, fmt.Errorf("claude stderr: %w", err)
	}
	cmd.Stdout, cmd.Stderr = outW, errW
	if err := cmd.Start(); err != nil {
		outR.Close()
		outW.Close()
		errR.Close()
		errW.Close()
		return nil, fmt.Errorf("starting claude: %w", err)
	}
	outW.Close()
	errW.Close()

	p := &claudeProc{
		cmd: cmd, pgid: cmd.Process.Pid, stdin: stdin,
		events: make(chan Event, 256), exited: make(chan struct{}), outDone: make(chan struct{}),
		errDone: make(chan struct{}), stop: make(chan struct{}),
		stderr: &boundedBuffer{limit: 64 << 10}, resumed: b.resume != "",
	}
	go func() {
		_ = cmd.Wait()
		close(p.exited)
	}()
	go func() {
		_, _ = io.Copy(p.stderr, errR)
		errR.Close()
		close(p.errDone)
	}()
	go b.read(p, outR)
	b.proc = p
	return p, nil
}

// read translates the child's stdout into events on p.events.
func (b *claudeBackend) read(p *claudeProc, r *os.File) {
	defer close(p.outDone)
	defer r.Close()
	sc := bufio.NewScanner(r)
	// Tool results arrive as one line each; allow multi-megabyte lines.
	sc.Buffer(make([]byte, 0, 64<<10), 64<<20)
	for sc.Scan() {
		evs, err := b.tr.Feed(sc.Bytes())
		if err != nil {
			continue // non-JSON noise on stdout is not a protocol event
		}
		for _, e := range evs {
			if isTerminal(e) {
				p.gotResult.Store(true)
			}
			if e.Type == EventTurnDone && e.SessionID != "" {
				b.mu.Lock()
				b.resume = e.SessionID
				b.mu.Unlock()
			}
			select {
			case p.events <- e:
			case <-p.stop:
				return
			}
		}
	}
}

type outcomeKind int

const (
	outcomeDone outcomeKind = iota
	outcomeExited
	outcomeLost
	outcomeContext
)

type outcome struct {
	kind outcomeKind
	msg  string
}

// Turn sends one owner message to the warm process and relays its events.
func (b *claudeBackend) Turn(ctx context.Context, c Command, emit func(Event)) error {
	blocks, err := BuildContentBlocks(c.Attachments)
	if err != nil {
		emit(errorEvent(c.TurnID, CodeAttachmentUnsupported, err.Error(), false))
		return nil
	}
	b.curTurn.Store(c.TurnID)
	b.active.Store(true)
	defer b.active.Store(false)
	b.mu.Lock()
	b.cancelled = false
	b.mu.Unlock()

	fresh := c.Replay
	if fresh {
		b.restartFresh()
	}
	for attempt := 0; ; attempt++ {
		text := c.Text
		if fresh {
			prefix, err := b.replayText(c.TurnID)
			if err != nil {
				return fmt.Errorf("building the replay: %w", err)
			}
			text = prefix + c.Text
		}
		p, err := b.ensureProc()
		if err != nil {
			return err
		}
		drain(p.events)
		line, err := userMessageLine(text, blocks)
		if err != nil {
			return err
		}
		_ = p.write(line) // a dead child surfaces as an exit below

		out := b.await(ctx, p, emit)
		switch out.kind {
		case outcomeDone:
			return nil
		case outcomeContext:
			return ctx.Err()
		case outcomeLost:
			if attempt == 0 {
				fresh = true
				b.restartFresh()
				continue
			}
			emit(errorEvent(c.TurnID, CodeSessionLost, out.msg, false))
			return nil
		default:
			b.mu.Lock()
			cancelled, sid := b.cancelled, b.resume
			b.mu.Unlock()
			if cancelled {
				emit(Event{Type: EventTurnDone, TurnID: c.TurnID, Status: StatusInterrupted, SessionID: sid})
				return nil
			}
			code, retry := ClassifyClaudeError(out.msg)
			emit(errorEvent(c.TurnID, code, out.msg, retry))
			return nil
		}
	}
}

// await relays events until the turn's terminal event, the child's exit, or
// ctx cancellation. A --resume rejection (as an error result, or as an exit
// before any result) is reported as outcomeLost instead of being emitted.
func (b *claudeBackend) await(ctx context.Context, p *claudeProc, emit func(Event)) outcome {
	handle := func(e Event) (outcome, bool) {
		if e.Type == EventError && e.Code == CodeSessionLost && p.resumed {
			return outcome{kind: outcomeLost, msg: e.Message}, true
		}
		emit(e)
		if isTerminal(e) {
			return outcome{kind: outcomeDone}, true
		}
		return outcome{}, false
	}
	for {
		select {
		case e := <-p.events:
			if o, done := handle(e); done {
				return o
			}
		case <-p.exited:
			// Deliver what the child printed before it died, then judge the exit.
			waitClosed(p.outDone, 500*time.Millisecond)
			if o, done := drainPending(p.events, handle); done {
				return o
			}
			waitClosed(p.errDone, 500*time.Millisecond)
			msg := strings.TrimSpace(p.stderr.String())
			if msg == "" {
				msg = "claude exited: " + p.cmd.ProcessState.String()
			}
			if p.resumed && !p.gotResult.Load() {
				if code, _ := ClassifyClaudeError(msg); code == CodeSessionLost {
					return outcome{kind: outcomeLost, msg: msg}
				}
			}
			return outcome{kind: outcomeExited, msg: msg}
		case <-ctx.Done():
			return outcome{kind: outcomeContext}
		}
	}
}

// ensureProc returns the live child, respawning (with --resume of the last
// session, if any) when it has exited.
func (b *claudeBackend) ensureProc() (*claudeProc, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.proc != nil {
		select {
		case <-b.proc.exited:
			sweep(b.proc)
		default:
			return b.proc, nil
		}
	}
	return b.spawnLocked()
}

// restartFresh replaces the child with a fresh session (no --resume); the
// next turn carries the replayed history.
func (b *claudeBackend) restartFresh() {
	b.mu.Lock()
	p := b.proc
	b.proc = nil
	b.resume = ""
	b.mu.Unlock()
	if p != nil {
		b.stopProc(p)
	}
}

func (b *claudeBackend) replayText(turnID string) (string, error) {
	if b.opts.Replay == nil {
		return "", nil
	}
	return b.opts.Replay(turnID)
}

// Cancel sends the interrupt control request; if the turn has not ended
// within InterruptGrace the child is killed and the next turn resumes.
func (b *claudeBackend) Cancel() error {
	if !b.active.Load() {
		return nil
	}
	turn, _ := b.curTurn.Load().(string)
	b.mu.Lock()
	p := b.proc
	b.cancelled = true
	b.mu.Unlock()
	if p == nil {
		return nil
	}
	b.tr.MarkInterrupted()
	req, err := json.Marshal(map[string]any{
		"type": "control_request", "request_id": "interrupt-" + turn,
		"request": map[string]string{"subtype": "interrupt"},
	})
	if err != nil {
		return err
	}
	if err := p.write(append(req, '\n')); err != nil {
		killGroup(p)
		return nil
	}
	time.AfterFunc(b.opts.InterruptGrace, func() {
		if t, _ := b.curTurn.Load().(string); t != turn || !b.active.Load() {
			return
		}
		select {
		case <-p.exited:
		default:
			killGroup(p)
		}
	})
	return nil
}

// Close ends the child (stdin EOF → SIGTERM → SIGKILL, CloseGrace apart),
// sweeps its process group and removes the temp files. Idempotent.
func (b *claudeBackend) Close() error {
	b.closeOnce.Do(func() {
		b.mu.Lock()
		p := b.proc
		b.proc = nil
		b.mu.Unlock()
		if p != nil {
			b.stopProc(p)
		}
		for _, f := range []string{b.promptFile, b.mcpFile} {
			if f != "" {
				_ = os.Remove(f)
			}
		}
	})
	return nil
}

func (b *claudeBackend) stopProc(p *claudeProc) {
	p.stopOnce.Do(func() { close(p.stop) })
	p.closeStdin()
	if !waitClosed(p.exited, b.opts.CloseGrace) {
		_ = syscall.Kill(-p.pgid, syscall.SIGTERM)
		if !waitClosed(p.exited, b.opts.CloseGrace) {
			killGroup(p)
			<-p.exited
		}
	}
	sweep(p)
}

// killGroup SIGKILLs the child and everything in its process group.
func killGroup(p *claudeProc) { _ = syscall.Kill(-p.pgid, syscall.SIGKILL) }

// sweep terminates what is left of the child's process group (the MCP
// servers claude spawned) once claude itself is gone.
func sweep(p *claudeProc) { _ = syscall.Kill(-p.pgid, syscall.SIGTERM) }

func waitClosed(ch <-chan struct{}, d time.Duration) bool {
	select {
	case <-ch:
		return true
	case <-time.After(d):
		return false
	}
}

func drain(ch chan Event) {
	for {
		select {
		case <-ch:
		default:
			return
		}
	}
}

// drainPending feeds every buffered event to handle until one ends the turn
// (done=true) or the buffer is empty (done=false).
func drainPending(ch chan Event, handle func(Event) (outcome, bool)) (outcome, bool) {
	for {
		select {
		case e := <-ch:
			if o, done := handle(e); done {
				return o, true
			}
		default:
			return outcome{}, false
		}
	}
}

// userMessageLine is one stream-json user message: the text block first,
// then any attachment content blocks.
func userMessageLine(text string, blocks []json.RawMessage) ([]byte, error) {
	textBlock, err := json.Marshal(map[string]string{"type": "text", "text": text})
	if err != nil {
		return nil, err
	}
	content := append([]json.RawMessage{textBlock}, blocks...)
	line, err := json.Marshal(map[string]any{
		"type":    "user",
		"message": map[string]any{"role": "user", "content": content},
	})
	if err != nil {
		return nil, fmt.Errorf("encoding user message: %w", err)
	}
	return append(line, '\n'), nil
}

// writePrivateTemp writes content to a new 0600 temp file.
func writePrivateTemp(pattern, content string) (string, error) {
	f, err := os.CreateTemp("", pattern)
	if err != nil {
		return "", err
	}
	path := f.Name()
	if err := f.Chmod(0o600); err != nil {
		f.Close()
		os.Remove(path)
		return "", err
	}
	if _, err := f.WriteString(content); err != nil {
		f.Close()
		os.Remove(path)
		return "", err
	}
	if err := f.Close(); err != nil {
		os.Remove(path)
		return "", err
	}
	return path, nil
}

// boundedBuffer keeps the first limit bytes written to it (stderr capture).
type boundedBuffer struct {
	mu    sync.Mutex
	buf   []byte
	limit int
}

func (b *boundedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if room := b.limit - len(b.buf); room > 0 {
		if len(p) > room {
			b.buf = append(b.buf, p[:room]...)
		} else {
			b.buf = append(b.buf, p...)
		}
	}
	return len(p), nil
}

func (b *boundedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return string(b.buf)
}
```

Append to `internal/chat/claude_translate.go` (a killed child never delivers the result that would consume an interrupt mark, so each new turn starts clean):

```go
// clearInterrupted drops a pending interrupt mark. Called when a turn starts:
// a child killed after an interrupt never delivers the result that consumes
// the mark, and a stale mark would turn the next turn's error into
// "interrupted".
func (t *ClaudeTranslator) clearInterrupted() {
	t.mu.Lock()
	t.interrupted = false
	t.mu.Unlock()
}
```

and in `claude_backend.go`'s `Turn`, right after `b.curTurn.Store(c.TurnID)`, add `b.tr.clearInterrupted()`.

Run: `go test ./internal/chat/ -run 'TestClaudeBackend|TestChat04|TestSession_'`
Expected: PASS. Then run the package three times to shake out timing flakes:

Run: `go test ./internal/chat/ -run 'TestClaudeBackend' -count=3`
Expected: PASS all three (this one explicit `-count` is deliberate: it re-runs the process-lifecycle tests, it is not a cache-busting habit).

- [ ] **Step 7: Add `ReplayFromDB` (shared by the Claude replay and Task 8's turn backend)**

Append to `internal/chat/replay_test.go` (add `"github.com/stretchr/testify/require"` to its imports):

```go
func TestReplayFromDB_UsesActivePathAndSteps(t *testing.T) {
	d := db.OpenTestDB(t)
	res, err := d.Exec(`INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 1, 1)`)
	require.NoError(t, err)
	conv, err := res.LastInsertId()
	require.NoError(t, err)
	insert := func(parent any, role, text, turn string) int64 {
		r, err := d.Exec(`INSERT INTO chat_messages (conversation_id, parent_id, role, text, turn_id, created_at)
			VALUES (?, ?, ?, ?, ?, 1)`, conv, parent, role, text, turn)
		require.NoError(t, err)
		id, err := r.LastInsertId()
		require.NoError(t, err)
		return id
	}
	q := insert(nil, "user", "what slipped?", "t1")
	a := insert(q, "assistant", "refunds", "t1")
	insert(a, "user", "why?", "t2") // the running turn, persisted before it was sent
	_, err = d.Exec(`INSERT INTO chat_turn_steps (message_id, seq, tool_id, name, ok, summary, started_at)
		VALUES (?, 1, 'x', 'search_knowledge', 1, '2 results', 1)`, a)
	require.NoError(t, err)

	out, err := ReplayFromDB(d, conv, "t2")
	require.NoError(t, err)
	assert.Contains(t, out, "Owner: what slipped?")
	assert.Contains(t, out, "  · step: search_knowledge: 2 results")
	assert.NotContains(t, out, "why?", "the running turn is sent as the turn text, not replayed")
}
```

Append to `internal/chat/replay.go` (`fmt` is already imported there):

```go
// ReplayFromDB renders the conversation's active path before turnID as a
// replay block (spec §2.4): the running turn's persisted rows are excluded,
// tool steps become one line each.
func ReplayFromDB(d *db.DB, conversationID int64, turnID string) (string, error) {
	path, err := d.ActiveChatPath(conversationID)
	if err != nil {
		return "", fmt.Errorf("reading the conversation: %w", err)
	}
	hist := HistoryBefore(path, turnID)
	ids := make([]int64, 0, len(hist))
	for _, m := range hist {
		ids = append(ids, m.ID)
	}
	steps, err := d.ChatStepSummaries(ids)
	if err != nil {
		return "", err
	}
	return BuildReplaySteps(hist, steps, ReplayCapChars), nil
}
```

Run: `go test ./internal/chat/ -run TestReplayFromDB`
Expected: PASS.

- [ ] **Step 8: Write the failing `ai session` command test**

Create `cmd/ai_session_test.go`:

```go
package cmd

import (
	"bufio"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/chat"
	"watchtower/internal/db"
)

const fakeSessionClaude = `#!/bin/sh
while IFS= read -r line; do
  case "$line" in *'"type":"user"'*)
    printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello from fake"}}}'
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"hello from fake","session_id":"sess-e2e","usage":{"input_tokens":1,"output_tokens":1}}'
  ;; esac
done
`

func resetAISessionFlags(t *testing.T) {
	t.Helper()
	reset := func() {
		aiSessionFlagConversation, aiSessionFlagProjectID = 0, 0
		aiSessionFlagModel, aiSessionFlagResume, aiSessionFlagDBPath = "", "", ""
		aiSessionFlagSurface = "main"
	}
	reset()
	t.Cleanup(reset)
}

func TestAISession_RequiresConversation(t *testing.T) {
	resetAISessionFlags(t)
	aiSessionCmd.SetOut(io.Discard)
	err := aiSessionCmd.RunE(aiSessionCmd, nil)
	assert.ErrorContains(t, err, "--conversation")
}

func TestAISession_EndToEndWithFakeClaude(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetAISessionFlags(t)

	fake := filepath.Join(t.TempDir(), "claude")
	require.NoError(t, os.WriteFile(fake, []byte(fakeSessionClaude), 0o755))
	f, err := os.OpenFile(flagConfig, os.O_APPEND|os.O_WRONLY, 0)
	require.NoError(t, err)
	_, err = f.WriteString("claude_path: " + fake + "\n")
	require.NoError(t, err)
	require.NoError(t, f.Close())

	dbPath := filepath.Join(os.Getenv("HOME"), ".local", "share", "watchtower", "test-ws", "watchtower.db")
	database, err := db.Open(dbPath)
	require.NoError(t, err)
	res, err := database.Exec(`INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 1, 1)`)
	require.NoError(t, err)
	convID, err := res.LastInsertId()
	require.NoError(t, err)
	require.NoError(t, database.Close())

	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	aiSessionCmd.SetIn(inR)
	aiSessionCmd.SetOut(outW)
	t.Cleanup(func() { aiSessionCmd.SetIn(nil); aiSessionCmd.SetOut(nil) })
	aiSessionFlagConversation = convID

	done := make(chan error, 1)
	go func() {
		err := aiSessionCmd.RunE(aiSessionCmd, nil)
		_ = outW.Close()
		done <- err
	}()

	events := make(chan chat.Event, 64)
	go func() {
		sc := bufio.NewScanner(outR)
		for sc.Scan() {
			var e chat.Event
			if json.Unmarshal(sc.Bytes(), &e) == nil {
				events <- e
			}
		}
		close(events)
	}()
	next := func(want string) chat.Event {
		t.Helper()
		deadline := time.After(20 * time.Second)
		for {
			select {
			case e, ok := <-events:
				require.True(t, ok, "stream ended before %s", want)
				if e.Type == want {
					return e
				}
			case <-deadline:
				t.Fatalf("no %s event", want)
			}
		}
	}

	ready := next(chat.EventSessionReady)
	assert.Equal(t, "claude", ready.Provider)
	assert.NotEmpty(t, ready.Model)

	cmdLine, err := json.Marshal(chat.Command{Type: chat.CommandTurn, TurnID: "t1", Text: "hi"})
	require.NoError(t, err)
	_, err = inW.Write(append(cmdLine, '\n'))
	require.NoError(t, err)
	assert.Equal(t, "hello from fake", next(chat.EventTextDelta).Text)
	done1 := next(chat.EventTurnDone)
	assert.Equal(t, "sess-e2e", done1.SessionID)

	_, err = inW.Write([]byte(`{"type":"close"}` + "\n"))
	require.NoError(t, err)
	select {
	case err := <-done:
		assert.NoError(t, err)
	case <-time.After(15 * time.Second):
		t.Fatal("ai session did not exit after close")
	}
}
```

Run: `go test ./cmd/ -run TestAISession`
Expected: FAIL to compile — `undefined: aiSessionCmd`.

- [ ] **Step 9: Write the `ai session` command**

Create `cmd/ai_session.go`:

```go
package cmd

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/spf13/cobra"

	"watchtower/internal/ai"
	"watchtower/internal/chat"
	"watchtower/internal/claude"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/providers"
	"watchtower/internal/skills"
)

var (
	aiSessionFlagConversation int64
	aiSessionFlagModel        string
	aiSessionFlagSurface      string
	aiSessionFlagProjectID    int64
	aiSessionFlagResume       string
	aiSessionFlagDBPath       string
)

var aiSessionCmd = &cobra.Command{
	Use:   "session",
	Short: "Run a long-lived chat session (protocol v2 over stdin/stdout; used by the desktop app)",
	Long: `Runs one chat conversation as a long-lived process. Commands arrive on stdin
as JSON lines ({"type":"turn"|"cancel"|"close", ...}); protocol-v2 events go
to stdout as NDJSON. With the claude provider one warm claude process serves
every turn. The system prompt is built here and passed by file; message text
and attachment paths travel on stdin, never on argv.`,
	Args: cobra.NoArgs,
	RunE: runAISession,
}

func init() {
	aiCmd.AddCommand(aiSessionCmd)
	f := aiSessionCmd.Flags()
	f.Int64Var(&aiSessionFlagConversation, "conversation", 0, "chat conversation id (required)")
	f.StringVar(&aiSessionFlagModel, "model", "", "override the AI model (default: the provider's strong tier)")
	f.StringVar(&aiSessionFlagSurface, "surface", "main", "chat surface: main|target")
	f.Int64Var(&aiSessionFlagProjectID, "project-id", 0, "chat project whose instructions and files join the prompt")
	f.StringVar(&aiSessionFlagResume, "resume", "", "Claude session id to resume")
	f.StringVar(&aiSessionFlagDBPath, "db-path", "", "SQLite database path (overrides the workspace default)")
}

func runAISession(cmd *cobra.Command, _ []string) error {
	out := chat.NewEventWriter(cmd.OutOrStdout())
	fail := func(code, msg string) error {
		_ = out.Emit(chat.Event{Type: chat.EventError, Code: code, Message: msg})
		return errors.New(msg)
	}
	if aiSessionFlagConversation <= 0 {
		return fail(chat.CodeInternal, "--conversation is required")
	}
	if aiSessionFlagSurface != "main" && aiSessionFlagSurface != "target" {
		return fail(chat.CodeInternal, "--surface must be main or target")
	}

	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fail(chat.CodeInternal, fmt.Sprintf("loading config: %v", err))
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	applyProviderOverride(cfg)
	if err := cfg.ValidateWorkspace(); err != nil {
		return fail(chat.CodeInternal, fmt.Sprintf("invalid config: %v", err))
	}
	dbPath := aiSessionFlagDBPath
	if dbPath == "" {
		dbPath = cfg.DBPath()
	}
	database, err := db.Open(dbPath)
	if err != nil {
		return fail(chat.CodeInternal, fmt.Sprintf("opening database: %v", err))
	}
	defer database.Close()

	conv, err := database.GetChatConversation(aiSessionFlagConversation)
	if err != nil {
		return fail(chat.CodeInternal, err.Error())
	}
	if conv == nil {
		return fail(chat.CodeInternal, fmt.Sprintf("conversation %d not found", aiSessionFlagConversation))
	}

	ctx := cmd.Context()
	if ctx == nil { // RunE called directly (tests)
		ctx = context.Background()
	}
	ctx, cancel := notifyShutdownContext(ctx, stderrLogf)
	defer cancel()

	model := aiSessionFlagModel
	if model == "" {
		_, model = providers.ResolveModelsFor(cfg, cfg.AI.Provider)
	}
	prompt, err := chat.BuildSystemPrompt(ctx, database, cfg, chat.PromptOptions{
		Surface: aiSessionFlagSurface, ProjectID: aiSessionFlagProjectID, ToolsAvailable: true,
		Provider: cfg.AI.Provider, SkillsDir: skills.Dir(cfg.WorkspaceDir()), VaultDir: memoryVaultPath(cfg),
		MemoryChat: cfg.Memory.Enabled && cfg.Memory.Surfaces.Chat, Now: time.Now(),
	})
	if err != nil {
		return fail(chat.CodeInternal, fmt.Sprintf("building the system prompt: %v", err))
	}

	turnFile, err := newTurnFile()
	if err != nil {
		return fail(chat.CodeInternal, fmt.Sprintf("creating the turn file: %v", err))
	}
	defer os.Remove(turnFile)
	mcpArgs := []string{"--chat", "--surface", aiSessionFlagSurface,
		"--conversation", strconv.FormatInt(conv.ID, 10), "--turn-file", turnFile}
	if conv.ContextType != "" {
		mcpArgs = append(mcpArgs, "--context-type", conv.ContextType, "--context-id", conv.ContextID)
	}

	backend, err := newSessionBackend(sessionWiring{
		cfg: cfg, database: database, dbPath: dbPath, conv: conv,
		model: model, prompt: prompt, mcpArgs: mcpArgs, turnFile: turnFile,
	})
	if err != nil {
		return fail(chat.CodeProviderUnavailable, err.Error())
	}

	s := chat.NewSession(backend, out)
	s.Provider = providers.ByID(cfg.AI.Provider).ID
	s.Model = model
	s.TurnFile = turnFile
	return s.Run(ctx, cmd.InOrStdin())
}

// sessionWiring is what a provider backend needs from the command.
type sessionWiring struct {
	cfg      *config.Config
	database *db.DB
	dbPath   string
	conv     *db.ChatConversation
	model    string
	prompt   string
	mcpArgs  []string
	turnFile string
}

// newSessionBackend picks the provider backend for `ai session`.
func newSessionBackend(w sessionWiring) (chat.Backend, error) {
	switch w.cfg.AI.Provider {
	case "codex", "ollama":
		return nil, fmt.Errorf("provider %s does not support chat sessions yet", w.cfg.AI.Provider)
	default:
		ext := loadExternalMCPServers(w.cfg, w.dbPath)
		return chat.NewClaudeBackend(chat.ClaudeOptions{
			Binary:          claude.FindBinary(w.cfg.ClaudePath),
			Model:           w.model,
			ResumeSessionID: aiSessionFlagResume,
			SystemPrompt:    w.prompt,
			MCPConfig:       ai.ChatMCPConfig(w.dbPath, w.mcpArgs, ext),
			AllowedTools:    ai.AllowedTools(ext),
			DisallowedTools: ai.DisallowedTools,
			Replay: func(turnID string) (string, error) {
				return chat.ReplayFromDB(w.database, w.conv.ID, turnID)
			},
		}), nil
	}
}

// newTurnFile creates the empty 0600 file the session publishes turn ids in.
func newTurnFile() (string, error) {
	f, err := os.CreateTemp("", "wt-chat-turn-*.txt")
	if err != nil {
		return "", err
	}
	path := f.Name()
	if err := f.Chmod(0o600); err != nil {
		f.Close()
		os.Remove(path)
		return "", err
	}
	if err := f.Close(); err != nil {
		os.Remove(path)
		return "", err
	}
	return path, nil
}
```

Run: `go test ./cmd/ -run 'TestAISession|TestMCP' && go test ./internal/chat/ ./internal/ai/`
Expected: PASS.

- [ ] **Step 10: Lint the diff**

Run: `make lint-diff`
Expected: no new issues. A complexity finding on `Turn`/`await`/`runAISession` is fixed by extracting a helper (the repo's sentrux gate counts cyclomatic complexity), never by re-baselining.

- [ ] **Step 11: Commit**

```bash
git add internal/chat/session.go internal/chat/session_test.go internal/chat/claude_backend.go \
  internal/chat/claude_backend_test.go internal/chat/claude_translate.go internal/chat/attachments.go \
  internal/chat/replay.go internal/chat/replay_test.go \
  internal/chat/testdata/fake_claude.sh \
  internal/ai/client.go internal/ai/client_test.go cmd/ai_session.go cmd/ai_session_test.go
git commit -m "feat(chat): warm ai session with a long-lived claude process (protocol v2)" \
  -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Codex/Ollama turn backend + `ai query --events v2`

**Files:**
- Modify: `internal/ai/provider.go` (`ToolEvent`, `StreamChunk.Tool`)
- Modify: `internal/agentloop/client.go` (`EmitToolEvents`, tool start/end chunks)
- Modify: `internal/agentloop/loop_test.go` (new test)
- Create: `internal/chat/turn_backend.go`, `internal/chat/turn_backend_test.go`
- Modify: `cmd/ai.go` (`--events`, `streamQueryV2`, `emitError`)
- Modify: `cmd/ai_test.go` (new tests)
- Modify: `cmd/ai_session.go` (`newSessionBackend`: codex, ollama), `cmd/ai_session_test.go`

**Interfaces:**
- Consumes: Task 2 `Event`, `EventWriter`, `ClassifyClaudeError`, `errorEvent`, `toolArgs`, `SummarizeToolResult`; Task 6 `TurnFileReader`, `tools.Binding.TurnIDFunc`; Task 7 `Backend`, `ReplayFromDB`, `sessionWiring`, `newSessionBackend`.
- Produces (binding):
  - `type Querier interface{ Query(ctx context.Context, systemPrompt, userMessage, sessionID string) (<-chan ai.StreamChunk, <-chan error, <-chan string) }` — `ai.Provider` satisfies it.
  - `func NewTurnBackend(q Querier, d *db.DB, conversationID int64, opts ...TurnOption) Backend`; `type TurnOption func(*turnBackend)`; `func WithSystemPrompt(p string) TurnOption`. Every turn = one provider call with the replayed active path (spec §2.4). When `q` has `EmitToolEvents()`, the backend turns it on. Any attachment → `error{attachment_unsupported}` before the call (Task 20 inlines text files).
  - `func ChunkEvents(turnID string, c ai.StreamChunk) []Event` — text → `text_delta`; tool start/end → `tool_start`/`tool_end`; a bare boundary → nothing.
  - `ai.ToolEvent{ID, Name string; Args json.RawMessage; Done, OK bool; Result string}`; `ai.StreamChunk.Tool *ToolEvent`; `func (c *agentloop.Client) EmitToolEvents()`.
  - `watchtower ai query --events v1|v2` (default `v1`, unchanged); v2 prints `turn_start`, `text_delta`…, then `turn_done` or `error`, using `--turn` as the turn id (`query` when absent).

- [ ] **Step 1: Write the failing agentloop test**

Append to `internal/agentloop/loop_test.go`:

```go
// With EmitToolEvents on (the chat session turns it on), each tool call is
// reported as a start and an end chunk around its dispatch; the boundary and
// the text stay exactly as before.
func TestLoop_EmitsToolEventsWhenEnabled(t *testing.T) {
	reg := &fakeReg{tools: map[string]*tools.Tool{"list_targets": tools.NewListTargets()}, readData: []any{}}
	srv, _ := scriptedServer(t, toolCallResp("list_targets", `{}`), finalResp("here it is"))
	c := clientWith(reg, srv.URL)
	c.EmitToolEvents()

	var chunks []ai.StreamChunk
	_, _, err := c.run(context.Background(), "", "go", func(ch ai.StreamChunk) { chunks = append(chunks, ch) })
	require.NoError(t, err)
	require.Len(t, chunks, 4)
	assert.True(t, chunks[0].ToolBoundary)
	require.NotNil(t, chunks[1].Tool)
	assert.Equal(t, "c1", chunks[1].Tool.ID)
	assert.Equal(t, "list_targets", chunks[1].Tool.Name)
	assert.False(t, chunks[1].Tool.Done)
	require.NotNil(t, chunks[2].Tool)
	assert.True(t, chunks[2].Tool.Done)
	assert.True(t, chunks[2].Tool.OK)
	assert.Equal(t, "[]", chunks[2].Tool.Result)
	assert.Equal(t, "here it is", chunks[3].Text)
}
```

Run: `go test ./internal/agentloop/ -run TestLoop_EmitsToolEvents`
Expected: FAIL to compile — `c.EmitToolEvents undefined`, `chunks[1].Tool undefined`.

- [ ] **Step 2: Add `ToolEvent` and emit it from the loop**

In `internal/ai/provider.go`, add `import "encoding/json"` next to `"context"` and replace `StreamChunk` with:

```go
// StreamChunk is one piece of a streamed assistant turn. ToolBoundary marks a
// tool call interrupting the turn: any text streamed before it was pre-tool
// reasoning (the "let me check X first" preamble), so a v1 consumer discards
// what it has shown and starts the visible answer fresh from the text that
// follows. Text is empty on a boundary chunk. Tool, when set, reports one tool
// call's start or end — only from a loop whose tool events were switched on
// (agentloop.Client.EmitToolEvents, used by the protocol-v2 chat session).
type StreamChunk struct {
	Text         string
	ToolBoundary bool
	Tool         *ToolEvent
}

// ToolEvent is one tool call observed by an in-process tool loop: a start
// (Done=false, Args set) or an end (Done=true, OK and Result set).
type ToolEvent struct {
	ID     string
	Name   string
	Args   json.RawMessage
	Done   bool
	OK     bool
	Result string
}
```

In `internal/agentloop/client.go`:

1. Add a field to `Client`: `toolEvents bool // emit ai.StreamChunk{Tool: …} around each dispatch (EmitToolEvents)`.
2. Add:

```go
// EmitToolEvents makes Query report every tool call as a start and an end
// chunk (ai.StreamChunk.Tool) around its dispatch, so a protocol-v2 chat can
// show the call as a step. Off by default: v1 consumers see only the
// boundary and the text, unchanged.
func (c *Client) EmitToolEvents() { c.toolEvents = true }
```

3. In `run`, replace the dispatch loop

```go
		for _, call := range m.ToolCalls {
			msgs = append(msgs, oaMessage{
				Role:       "tool",
				ToolCallID: call.ID,
				Name:       call.Function.Name,
				Content:    c.dispatch(ctx, call),
			})
		}
```

with

```go
		for _, call := range m.ToolCalls {
			c.emitTool(emit, &ai.ToolEvent{ID: call.ID, Name: call.Function.Name, Args: json.RawMessage(call.Function.Arguments)})
			result := c.dispatch(ctx, call)
			c.emitTool(emit, &ai.ToolEvent{ID: call.ID, Name: call.Function.Name, Done: true,
				OK: !strings.HasPrefix(result, `{"error":`), Result: result})
			msgs = append(msgs, oaMessage{
				Role:       "tool",
				ToolCallID: call.ID,
				Name:       call.Function.Name,
				Content:    result,
			})
		}
```

4. Add:

```go
// emitTool forwards a tool start/end chunk when tool events are on.
func (c *Client) emitTool(emit func(ai.StreamChunk), ev *ai.ToolEvent) {
	if emit != nil && c.toolEvents {
		emit(ai.StreamChunk{Tool: ev})
	}
}
```

Run: `go test ./internal/agentloop/ ./internal/ai/`
Expected: PASS (the existing `TestLoop_EmitsToolBoundaryBeforeFinalAnswer` still sees exactly two chunks — tool events are off by default).

- [ ] **Step 3: Write the failing turn-backend tests**

Create `internal/chat/turn_backend_test.go`:

```go
package chat

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
	"watchtower/internal/db"
)

type fakeQuerier struct {
	mu         sync.Mutex
	chunks     []ai.StreamChunk
	err        error
	block      bool
	calls      int
	gotSystem  string
	gotUser    string
	toolEvents bool
}

func (f *fakeQuerier) EmitToolEvents() { f.toolEvents = true }

func (f *fakeQuerier) Query(ctx context.Context, system, user, _ string) (<-chan ai.StreamChunk, <-chan error, <-chan string) {
	f.mu.Lock()
	f.calls++
	f.gotSystem, f.gotUser = system, user
	f.mu.Unlock()
	textCh := make(chan ai.StreamChunk)
	errCh := make(chan error, 1)
	sidCh := make(chan string, 1)
	go func() {
		defer close(textCh)
		defer close(errCh)
		defer close(sidCh)
		for _, c := range f.chunks {
			select {
			case textCh <- c:
			case <-ctx.Done():
				errCh <- ctx.Err()
				return
			}
		}
		if f.block {
			<-ctx.Done()
			errCh <- ctx.Err()
			return
		}
		if f.err != nil {
			errCh <- f.err
		}
	}()
	return textCh, errCh, sidCh
}

func (f *fakeQuerier) seen() (int, string, string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls, f.gotSystem, f.gotUser
}

// seedConversation: t1 = a finished exchange, t2 = the owner message of the
// running turn (persisted before the turn is sent, CHAT-01).
func seedConversation(t *testing.T) (*db.DB, int64) {
	t.Helper()
	d := db.OpenTestDB(t)
	res, err := d.Exec(`INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 1, 1)`)
	require.NoError(t, err)
	conv, err := res.LastInsertId()
	require.NoError(t, err)
	var parent any
	for _, m := range []struct{ role, text, turn string }{
		{"user", "what slipped?", "t1"}, {"assistant", "the refunds launch", "t1"}, {"user", "why?", "t2"},
	} {
		r, err := d.Exec(`INSERT INTO chat_messages (conversation_id, parent_id, role, text, turn_id, created_at)
			VALUES (?, ?, ?, ?, ?, 1)`, conv, parent, m.role, m.text, m.turn)
		require.NoError(t, err)
		id, err := r.LastInsertId()
		require.NoError(t, err)
		parent = id
	}
	return d, conv
}

func TestTurnBackend_ReplaysHistoryAndStreams(t *testing.T) {
	d, conv := seedConversation(t)
	fq := &fakeQuerier{chunks: []ai.StreamChunk{{Text: "Because "}, {Text: "QA found a bug."}}}
	h := startSession(t, NewTurnBackend(fq, d, conv, WithSystemPrompt("SYS")), nil)
	assert.Empty(t, h.next(EventSessionReady).SessionID, "a stateless provider has no session id")

	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "why?"})
	assert.Equal(t, "Because ", h.next(EventTextDelta).Text)
	assert.Equal(t, "QA found a bug.", h.next(EventTextDelta).Text)
	assert.Equal(t, StatusComplete, h.next(EventTurnDone).Status)
	require.NoError(t, h.finish())

	_, system, user := fq.seen()
	assert.Equal(t, "SYS", system)
	assert.True(t, strings.HasPrefix(user, replayHeader), "every turn carries the replayed history")
	assert.Contains(t, user, "Owner: what slipped?")
	assert.Contains(t, user, "Assistant: the refunds launch")
	assert.True(t, strings.HasSuffix(user, "why?"))
	assert.Equal(t, 1, strings.Count(user, "why?"), "the running turn is not replayed as history")
}

func TestTurnBackend_ToolChunksBecomeSteps(t *testing.T) {
	d, conv := seedConversation(t)
	fq := &fakeQuerier{chunks: []ai.StreamChunk{
		{ToolBoundary: true},
		{Tool: &ai.ToolEvent{ID: "c1", Name: "list_targets", Args: []byte(`{}`)}},
		{Tool: &ai.ToolEvent{ID: "c1", Name: "list_targets", Done: true, OK: true, Result: `[]`}},
		{Text: "No open targets."},
	}}
	b := NewTurnBackend(fq, d, conv)
	assert.True(t, fq.toolEvents, "the backend switches the loop's tool events on")
	h := startSession(t, b, nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "why?"})

	start := h.next(EventToolStart)
	assert.Equal(t, "list_targets", start.Name)
	assert.JSONEq(t, `{}`, string(start.Args))
	end := h.next(EventToolEnd)
	require.NotNil(t, end.OK)
	assert.True(t, *end.OK)
	assert.Equal(t, "No open targets.", h.next(EventTextDelta).Text)
	h.next(EventTurnDone)
	require.NoError(t, h.finish())
}

func TestTurnBackend_ErrorIsClassified(t *testing.T) {
	d, conv := seedConversation(t)
	fq := &fakeQuerier{err: errors.New("codex CLI failed (exit 1): 429 Too Many Requests")}
	h := startSession(t, NewTurnBackend(fq, d, conv), nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "why?"})
	e := h.next(EventError)
	assert.Equal(t, "t2", e.TurnID)
	assert.Equal(t, CodeRateLimit, e.Code)
	require.NoError(t, h.finish())
}

func TestTurnBackend_CancelEndsInterrupted(t *testing.T) {
	d, conv := seedConversation(t)
	fq := &fakeQuerier{chunks: []ai.StreamChunk{{Text: "partial"}}, block: true}
	h := startSession(t, NewTurnBackend(fq, d, conv), nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "why?"})
	h.next(EventTextDelta)
	h.send(Command{Type: CommandCancel})
	assert.Equal(t, StatusInterrupted, h.next(EventTurnDone).Status)
	require.NoError(t, h.finish())
}

func TestTurnBackend_AttachmentRejectedBeforeTheCall(t *testing.T) {
	d, conv := seedConversation(t)
	fq := &fakeQuerier{}
	h := startSession(t, NewTurnBackend(fq, d, conv), nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t2", Text: "see this",
		Attachments: []Attachment{{Path: "/tmp/x.png", Mime: "image/png", Name: "x.png"}}})
	e := h.next(EventError)
	assert.Equal(t, CodeAttachmentUnsupported, e.Code)
	assert.False(t, e.Retryable)
	require.NoError(t, h.finish())
	calls, _, _ := fq.seen()
	assert.Zero(t, calls, "nothing reaches the provider")
}

func TestChunkEvents(t *testing.T) {
	assert.Nil(t, ChunkEvents("t", ai.StreamChunk{ToolBoundary: true}), "v2 never wipes text")
	assert.Equal(t, []Event{{Type: EventTextDelta, TurnID: "t", Text: "x"}}, ChunkEvents("t", ai.StreamChunk{Text: "x"}))
	failed := ChunkEvents("t", ai.StreamChunk{Tool: &ai.ToolEvent{ID: "a", Name: "get_target", Done: true, Result: `{"error":"no target"}`}})
	require.Len(t, failed, 1)
	require.NotNil(t, failed[0].OK)
	assert.False(t, *failed[0].OK)
	assert.Contains(t, failed[0].Summary, "no target")
}
```

Run: `go test ./internal/chat/ -run 'TestTurnBackend|TestChunkEvents'`
Expected: FAIL to compile — `undefined: NewTurnBackend`.

- [ ] **Step 4: Write the turn backend**

Create `internal/chat/turn_backend.go`:

```go
package chat

import (
	"context"
	"sync"

	"watchtower/internal/ai"
	"watchtower/internal/db"
)

// Querier is the one-shot streaming call a stateless provider offers;
// ai.Provider (codex, ollama/runtime B) satisfies it.
type Querier interface {
	Query(ctx context.Context, systemPrompt, userMessage, sessionID string) (<-chan ai.StreamChunk, <-chan error, <-chan string)
}

// TurnOption configures NewTurnBackend.
type TurnOption func(*turnBackend)

// WithSystemPrompt sets the system prompt sent with every call.
func WithSystemPrompt(p string) TurnOption { return func(b *turnBackend) { b.systemPrompt = p } }

type turnBackend struct {
	q              Querier
	d              *db.DB
	conversationID int64
	systemPrompt   string

	mu        sync.Mutex
	cancel    context.CancelFunc
	cancelled bool
}

// NewTurnBackend runs every turn as one provider call carrying the replayed
// active path (spec §2.4) — the Codex/Ollama path, which has no provider
// session to keep warm. A querier with tool events (runtime B) has them
// switched on so its tool calls become visible steps.
func NewTurnBackend(q Querier, d *db.DB, conversationID int64, opts ...TurnOption) Backend {
	b := &turnBackend{q: q, d: d, conversationID: conversationID}
	for _, o := range opts {
		o(b)
	}
	if e, ok := q.(interface{ EmitToolEvents() }); ok {
		e.EmitToolEvents()
	}
	return b
}

func (b *turnBackend) Start(ctx context.Context) (string, error) { return "", ctx.Err() }

func (b *turnBackend) Turn(ctx context.Context, c Command, emit func(Event)) error {
	if len(c.Attachments) > 0 {
		emit(errorEvent(c.TurnID, CodeAttachmentUnsupported,
			"this provider does not take attachments yet: "+c.Attachments[0].Name, false))
		return nil
	}
	replay, err := ReplayFromDB(b.d, b.conversationID, c.TurnID)
	if err != nil {
		return err
	}

	turnCtx, cancel := context.WithCancel(ctx)
	b.mu.Lock()
	b.cancel, b.cancelled = cancel, false
	b.mu.Unlock()
	defer func() {
		cancel()
		b.mu.Lock()
		b.cancel = nil
		b.mu.Unlock()
	}()

	textCh, errCh, sidCh := b.q.Query(turnCtx, b.systemPrompt, replay+c.Text, "")
	for chunk := range textCh {
		for _, e := range ChunkEvents(c.TurnID, chunk) {
			emit(e)
		}
	}
	for range sidCh {
	}
	var qerr error
	for err := range errCh {
		if err != nil && qerr == nil {
			qerr = err
		}
	}

	b.mu.Lock()
	cancelled := b.cancelled
	b.mu.Unlock()
	switch {
	case cancelled:
		emit(Event{Type: EventTurnDone, TurnID: c.TurnID, Status: StatusInterrupted})
	case qerr != nil && ctx.Err() != nil:
		return ctx.Err()
	case qerr != nil:
		code, retry := ClassifyClaudeError(qerr.Error())
		emit(errorEvent(c.TurnID, code, qerr.Error(), retry))
	default:
		emit(Event{Type: EventTurnDone, TurnID: c.TurnID, Status: StatusComplete})
	}
	return nil
}

func (b *turnBackend) Cancel() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.cancel != nil {
		b.cancelled = true
		b.cancel()
	}
	return nil
}

func (b *turnBackend) Close() error { return b.Cancel() }

// ChunkEvents maps one ai.StreamChunk from a one-call-per-turn provider onto
// v2 events: text → text_delta, a tool start/end → tool_start/tool_end, and a
// bare boundary → nothing (protocol v2 never wipes text).
func ChunkEvents(turnID string, c ai.StreamChunk) []Event {
	switch {
	case c.Tool != nil && !c.Tool.Done:
		return []Event{{Type: EventToolStart, TurnID: turnID, ID: c.Tool.ID, Name: displayToolName(c.Tool.Name),
			Args: toolArgs(string(c.Tool.Args))}}
	case c.Tool != nil:
		ok := c.Tool.OK
		var summary string
		var sources []Source
		if ok {
			summary, sources = SummarizeToolResult(displayToolName(c.Tool.Name), c.Tool.Result)
		} else {
			summary = truncateRunes(collapseSpace(c.Tool.Result), SummaryMaxRunes)
		}
		return []Event{{Type: EventToolEnd, TurnID: turnID, ID: c.Tool.ID, OK: &ok, Summary: summary, Sources: sources}}
	case c.Text != "":
		return []Event{{Type: EventTextDelta, TurnID: turnID, Text: c.Text}}
	}
	return nil
}
```

Run: `go test ./internal/chat/ -run 'TestTurnBackend|TestChunkEvents'`
Expected: PASS.

- [ ] **Step 5: Wire codex and ollama into `ai session`**

Append to `cmd/ai_session_test.go` (add `"watchtower/internal/config"` to its imports):

```go
func TestNewSessionBackend_EveryProviderHasABackend(t *testing.T) {
	database := db.OpenTestDB(t)
	conv := &db.ChatConversation{ID: 1}
	for _, p := range []string{"claude", "codex", "ollama"} {
		cfg := &config.Config{}
		cfg.AI.Provider = p
		b, err := newSessionBackend(sessionWiring{
			cfg: cfg, database: database, dbPath: ":memory:", conv: conv, model: "m", prompt: "p",
			turnFile: filepath.Join(t.TempDir(), "turn"),
		})
		require.NoError(t, err, p)
		require.NotNil(t, b, p)
	}
}
```

Run: `go test ./cmd/ -run TestNewSessionBackend`
Expected: FAIL — `provider codex does not support chat sessions yet`.

In `cmd/ai_session.go`, add `"watchtower/internal/agentloop"`, `"watchtower/internal/codex"` and `"watchtower/internal/tools"` to the imports and replace the `case "codex", "ollama":` branch of `newSessionBackend` with:

```go
	case "codex":
		// Stateless per turn: the backend replays the active path every turn.
		// The MCP server reads the running turn from the turn file.
		c := codex.NewClient(w.model, w.dbPath, w.cfg.CodexPath)
		c.SetMCPArgs(w.mcpArgs)
		return chat.NewTurnBackend(c, w.database, w.conv.ID, chat.WithSystemPrompt(w.prompt)), nil
	case "ollama":
		// Runtime B: the registry runs in-process; proposals bind to the
		// running turn through the same turn file.
		binding := tools.Binding{
			Surface: aiSessionFlagSurface, ConversationID: w.conv.ID,
			ContextType: w.conv.ContextType, ContextID: w.conv.ContextID,
			TurnIDFunc: chat.TurnFileReader(w.turnFile),
		}
		loop := agentloop.NewClient(w.model, w.cfg.AI.OllamaURL, buildToolRegistry(w.cfg, w.database), binding)
		return chat.NewTurnBackend(loop, w.database, w.conv.ID, chat.WithSystemPrompt(w.prompt)), nil
```

Run: `go test ./cmd/ -run 'TestNewSessionBackend|TestAISession'`
Expected: PASS.

- [ ] **Step 6: Write the failing `--events v2` tests**

Append to `cmd/ai_test.go`, and add to its imports: `"bufio"`, `"bytes"`, `"encoding/json"`, `"errors"`, `"github.com/stretchr/testify/assert"`, `"github.com/stretchr/testify/require"`, `"watchtower/internal/ai"`, `"watchtower/internal/chat"` (skip any already present):

```go
func runV2(t *testing.T, chunks []ai.StreamChunk, sid string, err error) []chat.Event {
	t.Helper()
	textCh := make(chan ai.StreamChunk, len(chunks))
	for _, c := range chunks {
		textCh <- c
	}
	close(textCh)
	sidCh := make(chan string, 1)
	sidCh <- sid
	close(sidCh)
	errCh := make(chan error, 1)
	if err != nil {
		errCh <- err
	}
	close(errCh)

	var buf bytes.Buffer
	streamQueryV2(&buf, "t1", textCh, errCh, sidCh)
	var out []chat.Event
	sc := bufio.NewScanner(&buf)
	for sc.Scan() {
		var e chat.Event
		require.NoError(t, json.Unmarshal(sc.Bytes(), &e))
		out = append(out, e)
	}
	return out
}

func TestAIQueryV2_StreamsWithoutReset(t *testing.T) {
	evs := runV2(t, []ai.StreamChunk{{Text: "Let me check."}, {ToolBoundary: true}, {Text: "Found it."}}, "s1", nil)
	var types []string
	for _, e := range evs {
		types = append(types, e.Type)
	}
	assert.Equal(t, []string{chat.EventTurnStart, chat.EventTextDelta, chat.EventTextDelta, chat.EventTurnDone}, types)
	assert.Equal(t, "t1", evs[3].TurnID)
	assert.Equal(t, "s1", evs[3].SessionID)
	assert.Equal(t, chat.StatusComplete, evs[3].Status)
}

func TestAIQueryV2_ErrorIsTerminal(t *testing.T) {
	evs := runV2(t, []ai.StreamChunk{{Text: "partial"}}, "", errors.New("API Error: 429 rate_limit_error"))
	last := evs[len(evs)-1]
	assert.Equal(t, chat.EventError, last.Type)
	assert.Equal(t, "t1", last.TurnID)
	assert.Equal(t, chat.CodeRateLimit, last.Code)
	for _, e := range evs {
		assert.NotEqual(t, chat.EventTurnDone, e.Type)
	}
}
```

Run: `go test ./cmd/ -run TestAIQueryV2`
Expected: FAIL to compile — `undefined: streamQueryV2`.

- [ ] **Step 7: Implement `--events v2`**

In `cmd/ai.go`: add `"io"` and `"watchtower/internal/chat"` to the imports; add `aiFlagEvents string` to the flag `var` block; in `init` add

```go
	aiQueryCmd.Flags().StringVar(&aiFlagEvents, "events", "v1", "output protocol: v1 (text/reset/session_id/done) or v2 (chat events)")
```

At the top of `runAIQuery`, after `enc := json.NewEncoder(os.Stdout)`, add

```go
	if aiFlagEvents != "v1" && aiFlagEvents != "v2" {
		return emitError(enc, fmt.Sprintf("--events must be v1 or v2, got %q", aiFlagEvents))
	}
```

Right after `textCh, errCh, sidCh := aiClient.Query(ctx, systemPrompt, prompt, aiFlagSessionID)` add

```go
	if aiFlagEvents == "v2" {
		streamQueryV2(os.Stdout, v2TurnID(), textCh, errCh, sidCh)
		return nil
	}
```

Replace `emitError` with

```go
func emitError(enc *json.Encoder, msg string) error {
	if aiFlagEvents == "v2" {
		_ = enc.Encode(chat.Event{Type: chat.EventError, TurnID: v2TurnID(), Code: chat.CodeInternal, Message: msg, Retryable: true})
		return nil
	}
	_ = enc.Encode(aiStreamEvent{Type: "error", Error: msg})
	_ = enc.Encode(aiStreamEvent{Type: "done"})
	return nil
}
```

and add

```go
// v2TurnID is the turn id `ai query --events v2` stamps on its events: the
// --turn flag when given (tool-bearing chats pass one), else "query".
func v2TurnID() string {
	if aiFlagTurn != "" {
		return aiFlagTurn
	}
	return "query"
}

// streamQueryV2 renders a one-shot query as protocol-v2 events: turn_start,
// text_delta per chunk (a tool boundary never wipes text), then turn_done —
// or, on failure, one classified turn error in its place.
func streamQueryV2(w io.Writer, turnID string, textCh <-chan ai.StreamChunk, errCh <-chan error, sidCh <-chan string) {
	out := chat.NewEventWriter(w)
	_ = out.Emit(chat.Event{Type: chat.EventTurnStart, TurnID: turnID})
	for chunk := range textCh {
		for _, e := range chat.ChunkEvents(turnID, chunk) {
			_ = out.Emit(e)
		}
	}
	sid := ""
	for s := range sidCh {
		if s != "" {
			sid = s
		}
	}
	for err := range errCh {
		if err != nil {
			code, retry := chat.ClassifyClaudeError(err.Error())
			_ = out.Emit(chat.Event{Type: chat.EventError, TurnID: turnID, Code: code, Message: err.Error(), Retryable: retry})
			return
		}
	}
	_ = out.Emit(chat.Event{Type: chat.EventTurnDone, TurnID: turnID, Status: chat.StatusComplete, SessionID: sid})
}
```

Run: `go test ./cmd/ -run 'TestAIQuery|TestAISession|TestNewSessionBackend|TestMCP' && go test ./internal/chat/ ./internal/agentloop/ ./internal/ai/`
Expected: PASS. The v1 path (`TestAIQuery…` tests that already existed in `cmd/ai_test.go`) is byte-identical.

- [ ] **Step 8: Commit**

```bash
git add internal/ai/provider.go internal/agentloop/client.go internal/agentloop/loop_test.go \
  internal/chat/turn_backend.go internal/chat/turn_backend_test.go cmd/ai.go cmd/ai_test.go \
  cmd/ai_session.go cmd/ai_session_test.go
git commit -m "feat(chat): codex/ollama turn backend with replay; ai query --events v2" \
  -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: `chat.title` prompt + `watchtower chat title <id>`

**Files:**
- Modify: `internal/prompts/store.go` (`ChatTitle`), `internal/prompts/defaults.go` (template + the four registries)
- Modify: `internal/prompts/defaults_extra_test.go` (registration test)
- Modify: `internal/digest/models.go` (`chat.title` → light)
- Create: `cmd/chat.go`, `cmd/chat_test.go`

**Interfaces:**
- Consumes: Task 1 `db.GetChatConversation`, `db.ActiveChatPath`, `db.SetChatTitle`; existing `prompts.Store`, `prompts.Directive`, `digest.WithSource`, `digest.TierForSource`, `cliGenerator`.
- Produces (binding): `prompts.ChatTitle = "chat.title"` (v1, light tier); `watchtower chat title <conversation-id> [--db-path PATH]` printing `{"title": "...", "written": bool}` on stdout — `written:false` without any AI call when the stored `title_source` is `user`; non-zero exit (error on stderr, nothing on stdout) when the conversation is missing, has no owner message yet, or the model returns an empty title. Test seam `var chatTitleGeneratorFactory func(*config.Config) digest.Generator`.

- [ ] **Step 1: Write the failing tests**

Append to `internal/prompts/defaults_extra_test.go`:

```go
// TestChatTitlePromptRegistered pins chat.title into all four registration
// surfaces, with the language directive slot and no leading dash.
func TestChatTitlePromptRegistered(t *testing.T) {
	id := ChatTitle
	allIDs := make(map[string]bool, len(AllIDs))
	for _, x := range AllIDs {
		allIDs[x] = true
	}
	assert.NotEmpty(t, Defaults[id], "Defaults must contain %q", id)
	assert.True(t, allIDs[id], "AllIDs must contain %q", id)
	assert.Equal(t, 1, DefaultVersions[id])
	assert.NotEmpty(t, Descriptions[id])
	rendered := DefaultFor(id)
	assert.True(t, HasDirective(fmt.Sprintf(rendered, Directive(""))))
	assert.False(t, strings.HasPrefix(rendered, "-"))
}
```

Create `cmd/chat_test.go`:

```go
package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
)

type chatTitleMockGen struct {
	reply   string
	calls   int
	source  string
	lastMsg string
}

func (m *chatTitleMockGen) Generate(ctx context.Context, _, user, _ string) (string, *digest.Usage, string, error) {
	m.calls++
	m.source, _ = digest.SourceFromContext(ctx)
	m.lastMsg = user
	return m.reply, &digest.Usage{}, "", nil
}

func stubChatTitleGenerator(t *testing.T, gen digest.Generator) {
	t.Helper()
	old := chatTitleGeneratorFactory
	t.Cleanup(func() { chatTitleGeneratorFactory = old })
	chatTitleGeneratorFactory = func(*config.Config) digest.Generator { return gen }
}

// seedTitleConversation opens the test workspace DB (setupWatchTestEnv) and
// inserts a conversation with the given title source and messages.
func seedTitleConversation(t *testing.T, titleSource string, msgs ...[2]string) int64 {
	t.Helper()
	d, err := db.Open(filepath.Join(os.Getenv("HOME"), ".local", "share", "watchtower", "test-ws", "watchtower.db"))
	require.NoError(t, err)
	defer d.Close()
	res, err := d.Exec(`INSERT INTO chat_conversations (title, title_source, created_at, updated_at) VALUES ('Mine', ?, 1, 1)`, titleSource)
	require.NoError(t, err)
	conv, err := res.LastInsertId()
	require.NoError(t, err)
	for _, m := range msgs {
		_, err := d.Exec(`INSERT INTO chat_messages (conversation_id, role, text, created_at) VALUES (?, ?, ?, 1)`, conv, m[0], m[1])
		require.NoError(t, err)
	}
	return conv
}

func runChatTitleCmd(t *testing.T, id int64) (map[string]any, error) {
	t.Helper()
	var buf bytes.Buffer
	chatTitleCmd.SetOut(&buf)
	t.Cleanup(func() { chatTitleCmd.SetOut(nil) })
	err := chatTitleCmd.RunE(chatTitleCmd, []string{strconv.FormatInt(id, 10)})
	if err != nil {
		return nil, err
	}
	var out map[string]any
	require.NoError(t, json.Unmarshal(buf.Bytes(), &out))
	return out, nil
}

func TestChatTitle_WritesAITitle(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	gen := &chatTitleMockGen{reply: "\"Payments rollout risks.\"\n"}
	stubChatTitleGenerator(t, gen)
	conv := seedTitleConversation(t, "prefix",
		[2]string{"user", "What could go wrong with the payments rollout?"},
		[2]string{"assistant", "Three risks: refunds, FX, and support load."})

	out, err := runChatTitleCmd(t, conv)
	require.NoError(t, err)
	assert.Equal(t, "Payments rollout risks", out["title"], "quotes and the trailing period are stripped")
	assert.Equal(t, true, out["written"])
	assert.Equal(t, "chat.title", gen.source, "tier routing hears the source tag")
	assert.Contains(t, gen.lastMsg, "Owner: What could go wrong with the payments rollout?")
	assert.Contains(t, gen.lastMsg, "Assistant: Three risks")

	d, err := db.Open(filepath.Join(os.Getenv("HOME"), ".local", "share", "watchtower", "test-ws", "watchtower.db"))
	require.NoError(t, err)
	defer d.Close()
	c, err := d.GetChatConversation(conv)
	require.NoError(t, err)
	assert.Equal(t, "Payments rollout risks", c.Title)
	assert.Equal(t, "ai", c.TitleSource)
}

func TestChatTitle_OwnerTitleIsNeverTouched(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	gen := &chatTitleMockGen{reply: "AI title"}
	stubChatTitleGenerator(t, gen)
	conv := seedTitleConversation(t, "user", [2]string{"user", "hi"})

	out, err := runChatTitleCmd(t, conv)
	require.NoError(t, err)
	assert.Equal(t, "Mine", out["title"])
	assert.Equal(t, false, out["written"])
	assert.Zero(t, gen.calls, "no AI call for an owner-named conversation")
}

func TestChatTitle_DegenerateInputs(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	stubChatTitleGenerator(t, &chatTitleMockGen{reply: "  \n\n"})

	empty := seedTitleConversation(t, "prefix")
	_, err := runChatTitleCmd(t, empty)
	assert.ErrorContains(t, err, "no owner message")

	_, err = runChatTitleCmd(t, 999999)
	assert.ErrorContains(t, err, "not found")

	blank := seedTitleConversation(t, "prefix", [2]string{"user", "hi"})
	_, err = runChatTitleCmd(t, blank)
	assert.ErrorContains(t, err, "empty title")

	err = chatTitleCmd.RunE(chatTitleCmd, []string{"abc"})
	assert.ErrorContains(t, err, "invalid conversation id")
}

func TestCleanChatTitle(t *testing.T) {
	cases := map[string]string{
		"Payments rollout":                   "Payments rollout",
		"# Title: Q3 plan.\n\nextra":         "Q3 plan",
		"«Релиз платежей»":                   "Релиз платежей",
		"**Vendor contract review**":         "Vendor contract review",
		"":                                   "",
		strings.Repeat("Долгое название ", 10): strings.TrimSpace(string([]rune(strings.Repeat("Долгое название ", 10))[:59])) + "…",
	}
	for in, want := range cases {
		assert.Equal(t, want, cleanChatTitle(in), in)
	}
}

func TestChatTitleIsLightTier(t *testing.T) {
	assert.Equal(t, digest.TierLight, digest.TierForSource("chat.title"))
}
```

Run: `go test ./internal/prompts/ -run TestChatTitlePromptRegistered; go test ./cmd/ -run 'TestChatTitle|TestCleanChatTitle'`
Expected: FAIL to compile — `undefined: ChatTitle`, `undefined: chatTitleCmd`.

- [ ] **Step 2: Register the prompt**

In `internal/prompts/store.go`, add to the ID `const` block after `CatchupCompose`:

```go
	ChatTitle                  = "chat.title"
```

In `internal/prompts/defaults.go`:
- `Defaults`: add `ChatTitle: defaultChatTitle,` after `CatchupCompose: defaultCatchupCompose,`.
- `AllIDs`: add `ChatTitle,` after `CatchupCompose,`.
- `DefaultVersions`: add `ChatTitle: 1, // v1: light-tier conversation title from the first exchange` after the `CatchupCompose` entry.
- `Descriptions`: add `ChatTitle: "AI Chat: name a conversation from its first exchange (light tier, at most 60 characters)",` after the `CatchupCompose` entry.
- Append the template:

```go
// defaultChatTitle names a main-chat conversation from its first exchange
// (`watchtower chat title`, light tier). The first verb is the language
// directive, like every other prompt; the exchange rides the user message.
const defaultChatTitle = `%s

You name a conversation between the owner and their work assistant. Read the first exchange in the user message and reply with a short title for the whole conversation:
- at most 60 characters, ideally 3-6 words;
- name the subject, not the act ("Payments rollout risks", not "Question about payments");
- no quotes, no trailing period, no markdown, no emoji;
- reply with the title only, on one line.`
```

In `internal/digest/models.go`, add `"chat.title",` to the light-tier `case` list (after `"reactioncmd.command",`) with the comment `// chat.title: a ≤60-char title from one exchange — bounded, fixed-shape output`.

Run: `go test ./internal/prompts/ ./internal/digest/`
Expected: PASS (including `TestTierForSource_EveryGenerateCallIsTagged`, which scans the not-yet-written `cmd/chat.go` in Step 3 too — rerun after it).

- [ ] **Step 3: Write the command**

Create `cmd/chat.go`:

```go
package cmd

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"github.com/spf13/cobra"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/prompts"
)

// chatTitleGeneratorFactory is the seam tests override to inject a mock
// generator (the dictateGeneratorFactory pattern).
var chatTitleGeneratorFactory = func(cfg *config.Config) digest.Generator {
	return cliGenerator(cfg)
}

const (
	chatTitleMaxRunes     = 60
	chatTitleExcerptRunes = 4000
)

var chatTitleFlagDBPath string

var chatCmd = &cobra.Command{
	Use:   "chat",
	Short: "AI Chat helpers (used by the desktop app)",
}

var chatTitleCmd = &cobra.Command{
	Use:   "title <conversation-id>",
	Short: "Name a chat conversation from its first exchange",
	Long: `Generates a title of at most 60 characters for a chat conversation from its
first owner message and assistant reply, and stores it with title_source='ai'.
A title the owner set (title_source='user') is never overwritten: the command
then prints it with "written": false and makes no AI call.`,
	Args: cobra.ExactArgs(1),
	RunE: runChatTitle,
}

func init() {
	rootCmd.AddCommand(chatCmd)
	chatCmd.AddCommand(chatTitleCmd)
	chatTitleCmd.Flags().StringVar(&chatTitleFlagDBPath, "db-path", "", "SQLite database path (overrides the workspace default)")
}

type chatTitleResult struct {
	Title   string `json:"title"`
	Written bool   `json:"written"`
}

func runChatTitle(cmd *cobra.Command, args []string) error {
	id, err := strconv.ParseInt(args[0], 10, 64)
	if err != nil || id <= 0 {
		return fmt.Errorf("invalid conversation id %q", args[0])
	}
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	applyProviderOverride(cfg)
	if err := cfg.ValidateWorkspace(); err != nil {
		return err
	}
	dbPath := chatTitleFlagDBPath
	if dbPath == "" {
		dbPath = cfg.DBPath()
	}
	database, err := db.Open(dbPath)
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	conv, err := database.GetChatConversation(id)
	if err != nil {
		return err
	}
	if conv == nil {
		return fmt.Errorf("conversation %d not found", id)
	}
	enc := json.NewEncoder(cmd.OutOrStdout())
	if conv.TitleSource == "user" {
		return enc.Encode(chatTitleResult{Title: conv.Title, Written: false})
	}

	path, err := database.ActiveChatPath(id)
	if err != nil {
		return err
	}
	owner, assistant := firstChatExchange(path)
	if owner == "" {
		return fmt.Errorf("conversation %d has no owner message yet", id)
	}

	store := prompts.New(database, nil)
	tmpl, _, _ := store.Get(prompts.ChatTitle)
	if tmpl == "" {
		tmpl = prompts.Defaults[prompts.ChatTitle]
	}
	system := fmt.Sprintf(tmpl, prompts.Directive(cfg.Digest.Language))
	user := "=== FIRST EXCHANGE ===\nOwner: " + excerptRunes(owner, chatTitleExcerptRunes) +
		"\n\nAssistant: " + excerptRunes(assistant, chatTitleExcerptRunes)

	ctx := cmd.Context()
	if ctx == nil { // RunE invoked directly (tests)
		ctx = context.Background()
	}
	reply, _, _, err := chatTitleGeneratorFactory(cfg).Generate(digest.WithSource(ctx, "chat.title"), system, user, "")
	if err != nil {
		return fmt.Errorf("generating the title: %w", err)
	}
	title := cleanChatTitle(reply)
	if title == "" {
		return fmt.Errorf("the model returned an empty title")
	}
	written, err := database.SetChatTitle(id, title, "ai")
	if err != nil {
		return err
	}
	return enc.Encode(chatTitleResult{Title: title, Written: written})
}

// firstChatExchange returns the first owner message and the first assistant
// reply after it on the active path.
func firstChatExchange(path []db.ChatMessage) (owner, assistant string) {
	for _, m := range path {
		switch {
		case m.Role == "user" && owner == "":
			owner = strings.TrimSpace(m.Text)
		case m.Role == "assistant" && owner != "" && assistant == "":
			assistant = strings.TrimSpace(m.Text)
		}
	}
	return owner, assistant
}

// cleanChatTitle takes the first non-empty line of the reply and strips the
// decoration models add anyway: heading/list markers, a "Title:" label,
// quotes of any script, emphasis and a trailing period; then caps it at
// chatTitleMaxRunes runes.
func cleanChatTitle(reply string) string {
	for _, line := range strings.Split(reply, "\n") {
		s := strings.TrimSpace(line)
		s = strings.TrimLeft(s, "#>-* ")
		if strings.HasPrefix(strings.ToLower(s), "title:") {
			s = strings.TrimSpace(s[len("title:"):])
		}
		s = strings.Trim(s, "\"'`“”«»*_ ")
		s = strings.TrimSpace(strings.TrimSuffix(s, "."))
		if s == "" {
			continue
		}
		if r := []rune(s); len(r) > chatTitleMaxRunes {
			s = strings.TrimSpace(string(r[:chatTitleMaxRunes-1])) + "…"
		}
		return s
	}
	return ""
}

// excerptRunes caps s at n runes (the first exchange can be a pasted document).
func excerptRunes(s string, n int) string {
	if r := []rune(s); len(r) > n {
		return string(r[:n]) + "…"
	}
	return s
}
```

Run: `go test ./cmd/ -run 'TestChatTitle|TestCleanChatTitle' && go test ./internal/digest/ ./internal/prompts/`
Expected: PASS (the tier scan now sees the tagged `chat.title` call and accepts it as light).

- [ ] **Step 4: Run the phase gate**

Run: `go test ./internal/... ./cmd/... > /tmp/phase1-go.log 2>&1; echo "exit=$?"`
Expected: `exit=0`. On failure read the log file (do not pipe through `tail`), fix, re-run. Then:

Run: `make lint-diff`
Expected: no new issues.

- [ ] **Step 5: Commit**

```bash
git add internal/prompts/store.go internal/prompts/defaults.go internal/prompts/defaults_extra_test.go \
  internal/digest/models.go cmd/chat.go cmd/chat_test.go
git commit -m "feat(chat): chat.title prompt and 'watchtower chat title' command" \
  -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```
