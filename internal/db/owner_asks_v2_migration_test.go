package db

import (
	"database/sql"
	"testing"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestMigration00107_UpDownUpKeepsAsksAndSessions: the migration applies over
// a 00106 database holding an open and an answered ask and a terminal
// session; old asks read level full, origin agent and an empty chat_asked_at;
// Down drops exactly what Up added and leaves the rows; a second Up restores
// the defaults.
func TestMigration00107_UpDownUpKeepsAsksAndSessions(t *testing.T) {
	t.Parallel()
	raw := rawDBAt(t, 106)
	_, err := raw.Exec(`INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', '/tmp/acme')`)
	require.NoError(t, err)
	_, err = raw.Exec(`INSERT INTO terminal_sessions (id, project_id, kind, title, folder_path, claude_session_id,
		agent_state, agent_state_at) VALUES (5, 1, 'claude', 'New session', '/tmp/acme', 'uuid',
		'waiting', '2026-10-10T12:00:00.000Z')`)
	require.NoError(t, err)
	_, err = raw.Exec(`INSERT INTO owner_asks (id, project_id, session_id, kind, title) VALUES (10, 1, 5, 'question', 'Open')`)
	require.NoError(t, err)
	_, err = raw.Exec(`INSERT INTO owner_asks (id, project_id, session_id, kind, title, status, answer, answered_at)
		VALUES (11, 1, 5, 'question', 'Answered', 'answered', '{"note":"ok"}', '2026-10-10T12:05:00Z')`)
	require.NoError(t, err)

	assertV2Defaults := func(stage string) {
		t.Helper()
		for _, id := range []int64{10, 11} {
			var level, origin, chatAskedAt string
			require.NoError(t, raw.QueryRow(`SELECT level, origin, chat_asked_at FROM owner_asks WHERE id = ?`, id).
				Scan(&level, &origin, &chatAskedAt), stage)
			assert.Equal(t, "full", level, "%s: ask %d level", stage, id)
			assert.Equal(t, "agent", origin, "%s: ask %d origin", stage, id)
			assert.Equal(t, "", chatAskedAt, "%s: ask %d chat_asked_at", stage, id)
		}
		var q, qAt sql.NullString
		require.NoError(t, raw.QueryRow(`SELECT chat_question, chat_question_at FROM terminal_sessions WHERE id = 5`).
			Scan(&q, &qAt), stage)
		assert.False(t, q.Valid || qAt.Valid, "%s: an existing session holds no chat question", stage)
		var n int
		require.NoError(t, raw.QueryRow(`SELECT COUNT(*) FROM owner_presence`).Scan(&n), stage)
		assert.Zero(t, n, "%s: owner_presence starts empty", stage)
	}

	require.NoError(t, goose.Up(raw, "migrations"))
	assertV2Defaults("up")

	// DownTo(106), not a bare Down: a later migration can move the tip past 00107.
	require.NoError(t, goose.DownTo(raw, "migrations", 106))
	askCols := columnNames(t, raw, "owner_asks")
	for _, c := range []string{"level", "origin", "chat_asked_at"} {
		assert.False(t, askCols[c], "Down kept owner_asks.%s", c)
	}
	sessCols := columnNames(t, raw, "terminal_sessions")
	assert.False(t, sessCols["chat_question"] || sessCols["chat_question_at"], "Down kept the chat question columns")
	var name string
	assert.ErrorIs(t, raw.QueryRow(`SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'owner_presence'`).Scan(&name),
		sql.ErrNoRows, "Down kept owner_presence")
	var status, answer, state string
	require.NoError(t, raw.QueryRow(`SELECT status, answer FROM owner_asks WHERE id = 11`).Scan(&status, &answer))
	assert.Equal(t, "answered", status)
	assert.Equal(t, `{"note":"ok"}`, answer)
	require.NoError(t, raw.QueryRow(`SELECT agent_state FROM terminal_sessions WHERE id = 5`).Scan(&state))
	assert.Equal(t, "waiting", state, "Down changed the session's other columns")

	require.NoError(t, goose.Up(raw, "migrations"))
	assertV2Defaults("re-up")
}

func TestMigration00107_OwnerPresenceIsASingleton(t *testing.T) {
	d := openTestDB(t)
	_, err := d.Exec(`INSERT INTO owner_presence (id, session_id, seen_at) VALUES (2, NULL, '')`)
	assert.Error(t, err, "the CHECK accepted id 2")
	_, err = d.Exec(`INSERT INTO owner_presence (id, session_id, seen_at) VALUES (1, NULL, '')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO owner_presence (id, session_id, seen_at) VALUES (1, NULL, '')`)
	assert.Error(t, err, "a second row with id 1")
}

func TestMigration00107_LevelAndOriginChecks(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	id := mustInsertAsk(t, d, questionAsk(pid, "Q"))
	for _, col := range []string{"level", "origin"} {
		_, err := d.Exec(`UPDATE owner_asks SET `+col+` = 'x' WHERE id = ?`, id)
		assert.Error(t, err, "the CHECK accepted %s 'x'", col)
	}
	for _, set := range []string{`level = 'quick'`, `level = 'full'`, `origin = 'chat'`, `origin = 'agent'`} {
		_, err := d.Exec(`UPDATE owner_asks SET `+set+` WHERE id = ?`, id)
		require.NoError(t, err, set)
	}
}

func TestMigration00107_DeletedSessionLeavesPresenceInNoSession(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	sid := newTestSession(t, d, pid)
	_, err := d.Exec(`INSERT INTO owner_presence (id, session_id, seen_at) VALUES (1, ?, '2026-10-10T12:00:00.000Z')`, sid)
	require.NoError(t, err)

	_, err = d.Exec(`DELETE FROM terminal_sessions WHERE id = ?`, sid)
	require.NoError(t, err)
	var session sql.NullInt64
	var seenAt string
	require.NoError(t, d.QueryRow(`SELECT session_id, seen_at FROM owner_presence WHERE id = 1`).Scan(&session, &seenAt))
	assert.False(t, session.Valid, "the presence row still names the deleted session")
	assert.Equal(t, "2026-10-10T12:00:00.000Z", seenAt)
}
