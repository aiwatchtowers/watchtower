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

func TestMigration00076_AdoptsLegacyChatTables(t *testing.T) {
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
			raw := rawDBAt(t, 75)
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

// TestMigration00076_DownUpKeepsMessages: goose.Down/DownTo in other tests
// roll back through 00076, so its Down must be real and must never drop the
// adopted rows (the app created them, not this migration).
func TestMigration00076_DownUpKeepsMessages(t *testing.T) {
	d, err := Open(filepath.Join(t.TempDir(), "chat-cycle.db"))
	require.NoError(t, err)
	defer d.Close()

	conv := insertChatConversation(t, d, "", "")
	root := insertBranchMessage(t, d, conv, 0, "user", "keep me", "t1")
	insertBranchMessage(t, d, conv, root, "assistant", "and me", "t1")

	// DownTo(75), not a bare Down: a later migration (e.g. 00077) can move the
	// tip past 00076, and a bare Down would roll back only the tip instead of
	// the migration this test targets.
	require.NoError(t, goose.DownTo(d.DB, "migrations", 75))
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM chat_messages`).Scan(&n))
	assert.Equal(t, 2, n, "Down keeps the adopted tables and their rows")
	assert.False(t, columnNames(t, d.DB, "chat_messages")["parent_id"], "Down removes the 00076 columns")
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
