package cmd

import (
	"database/sql"
	"encoding/json"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// sessionTargetFixture is one workbench with a task and an agent session.
func sessionTargetFixture(t *testing.T) (database *db.DB, session, target int64) {
	t.Helper()
	database = writeActionsConfig(t)
	wb, err := database.CreateWorkbench("alpha", t.TempDir())
	require.NoError(t, err)
	target = db.SeedTestWorkbenchTarget(t, database, wb, sql.NullInt64{}, "Alpha feature")
	res, err := database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, 'claude', 'New session', '/tmp/acme', 'uuid')`, wb)
	require.NoError(t, err)
	session, err = res.LastInsertId()
	require.NoError(t, err)
	return database, session, target
}

func runSessionTarget(t *testing.T, args ...string) (string, string, error) {
	t.Helper()
	return runWorkbench(t, append([]string{"session-target"}, args...)...)
}

func boundTarget(t *testing.T, database *db.DB, session int64) sql.NullInt64 {
	t.Helper()
	var v sql.NullInt64
	require.NoError(t, database.QueryRow(`SELECT target_id FROM terminal_sessions WHERE id = ?`, session).Scan(&v))
	return v
}

func TestWorkbenchSessionTarget_RefusedUnderAgent(t *testing.T) {
	database, session, target := sessionTargetFixture(t)
	t.Setenv("CLAUDECODE", "1")
	_, _, err := runSessionTarget(t, "--session", strconv.FormatInt(session, 10), "--target", strconv.FormatInt(target, 10))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "under an AI agent")
	assert.False(t, boundTarget(t, database, session).Valid)
}

func TestWorkbenchSessionTarget_SetsAndPrintsJSON(t *testing.T) {
	database, session, target := sessionTargetFixture(t)
	out, _, err := runSessionTarget(t, "--session", strconv.FormatInt(session, 10),
		"--target", strconv.FormatInt(target, 10), "--json")
	require.NoError(t, err)
	assert.Equal(t, 1, strings.Count(out, "\n"), "exactly one line: %q", out)
	var got map[string]int64
	require.NoError(t, json.Unmarshal([]byte(out), &got), out)
	assert.Equal(t, session, got["session_id"])
	assert.Equal(t, target, got["target_id"])
	assert.Contains(t, got, "stamped")
	assert.Len(t, got, 3)
	assert.Equal(t, sql.NullInt64{Int64: target, Valid: true}, boundTarget(t, database, session))
}

func TestWorkbenchSessionTarget_ClearSetsNull(t *testing.T) {
	database, session, target := sessionTargetFixture(t)
	_, _, err := runSessionTarget(t, "--session", strconv.FormatInt(session, 10), "--target", strconv.FormatInt(target, 10))
	require.NoError(t, err)
	out, _, err := runSessionTarget(t, "--session", strconv.FormatInt(session, 10), "--clear", "--json")
	require.NoError(t, err)
	var got map[string]int64
	require.NoError(t, json.Unmarshal([]byte(out), &got), out)
	assert.Equal(t, int64(0), got["target_id"])
	assert.False(t, boundTarget(t, database, session).Valid)
}

func TestWorkbenchSessionTarget_RequiresExactlyOneOfTargetClear(t *testing.T) {
	database, session, target := sessionTargetFixture(t)
	s := strconv.FormatInt(session, 10)
	_, _, err := runSessionTarget(t, "--session", s)
	require.Error(t, err)
	_, _, err = runSessionTarget(t, "--session", s, "--target", strconv.FormatInt(target, 10), "--clear")
	require.Error(t, err)
	assert.False(t, boundTarget(t, database, session).Valid)
}

func TestWorkbenchSessionTarget_UnknownSession(t *testing.T) {
	_, _, target := sessionTargetFixture(t)
	_, _, err := runSessionTarget(t, "--session", "999999", "--target", strconv.FormatInt(target, 10))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "999999")
}

func TestWorkbenchSessionTarget_RefusesShellSession(t *testing.T) {
	database, _, target := sessionTargetFixture(t)
	res, err := database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path)
		VALUES (1, 'shell', 'sh', '/tmp/acme')`)
	require.NoError(t, err)
	shell, err := res.LastInsertId()
	require.NoError(t, err)
	_, _, err = runSessionTarget(t, "--session", strconv.FormatInt(shell, 10), "--target", strconv.FormatInt(target, 10))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "is not an agent session of this workbench")
	assert.False(t, boundTarget(t, database, shell).Valid)
}
