package cmd

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
)

// askToolDenialJSON is the spec's §6.3 output, verbatim.
const askToolDenialJSON = `{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "In a Watchtower workbench, questions to the owner go through ask_owner so they land in the owner's stack — file it there and keep working."}}`

// askToolPayload is Claude Code's PreToolUse input for tool.
func askToolPayload(tool string) string {
	return `{"session_id":"` + briefLaunchID + `","cwd":"/tmp/acme","hook_event_name":"PreToolUse","tool_name":"` + tool +
		`","tool_input":{"questions":[{"question":"Which one?","options":[{"label":"A"},{"label":"B"}]}]}}`
}

// runAskGuard runs `workbench ask-guard --workbench <raw> --pre-tool-use`
// the way the hook does: the input on stdin.
func runAskGuard(t *testing.T, raw string, stdin io.Reader) (stdout, stderr string, err error) {
	t.Helper()
	rootCmd.SetIn(stdin)
	t.Cleanup(func() { rootCmd.SetIn(nil) })
	return runWorkbenchAs(t, "workbench", "ask-guard", "--workbench", raw, "--pre-tool-use")
}

func compactDenial(t *testing.T) string {
	t.Helper()
	var want bytes.Buffer
	require.NoError(t, json.Compact(&want, []byte(askToolDenialJSON)))
	return want.String() + "\n"
}

func TestAskGuard_DeniesAskUserQuestionInALiveWorkbench(t *testing.T) {
	database := writeActionsConfig(t)
	id, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)

	out, errOut, err := runAskGuard(t, strconv.FormatInt(id, 10), strings.NewReader(askToolPayload("AskUserQuestion")))

	require.NoError(t, err)
	assert.Empty(t, errOut)
	assert.Equal(t, compactDenial(t), out)
}

// PROJ-13: the PreToolUse hook never traps a turn — another tool, a bad
// input, every failure, a deleted workbench and a panic print nothing and
// exit 0, so the tool runs.
func TestProj13_AskGuardFailurePrintsNothingAndExitsZero(t *testing.T) {
	orig := askGuardInputWait
	askGuardInputWait = 50 * time.Millisecond
	t.Cleanup(func() { askGuardInputWait = orig })
	ask := func() io.Reader { return strings.NewReader(askToolPayload("AskUserQuestion")) }
	live := func(t *testing.T) string {
		database := writeActionsConfig(t)
		id, err := database.CreateWorkbench("acme", t.TempDir())
		require.NoError(t, err)
		return strconv.FormatInt(id, 10)
	}

	for _, tc := range []struct {
		name  string
		setup func(t *testing.T) (raw string, stdin io.Reader)
	}{
		{"another tool", func(t *testing.T) (string, io.Reader) {
			return live(t), strings.NewReader(askToolPayload("Bash"))
		}},
		{"unreadable input", func(t *testing.T) (string, io.Reader) { return live(t), strings.NewReader("not json") }},
		{"no input", func(t *testing.T) (string, io.Reader) { return live(t), strings.NewReader("") }},
		{"input never closed", func(t *testing.T) (string, io.Reader) {
			r, w := io.Pipe()
			t.Cleanup(func() { _ = w.Close() })
			return live(t), r
		}},
		{"deleted workbench", func(t *testing.T) (string, io.Reader) {
			database := writeActionsConfig(t)
			id, err := database.CreateWorkbench("acme", t.TempDir())
			require.NoError(t, err)
			require.NoError(t, database.DeleteWorkbench(id))
			return strconv.FormatInt(id, 10), ask()
		}},
		{"unknown workbench", func(t *testing.T) (string, io.Reader) { writeActionsConfig(t); return "424242", ask() }},
		{"bad id", func(t *testing.T) (string, io.Reader) { writeActionsConfig(t); return "seven", ask() }},
		{"zero id", func(t *testing.T) (string, io.Reader) { writeActionsConfig(t); return "0", ask() }},
		{"empty id", func(t *testing.T) (string, io.Reader) { writeActionsConfig(t); return "", ask() }},
		{"broken config", func(t *testing.T) (string, io.Reader) { writeActionsConfig(t); brokenConfig(t); return "1", ask() }},
		{"panic", func(t *testing.T) (string, io.Reader) {
			orig := askGuardWorkbenchLive
			askGuardWorkbenchLive = func(string) bool { panic("boom") }
			t.Cleanup(func() { askGuardWorkbenchLive = orig })
			return "1", ask()
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			raw, stdin := tc.setup(t)
			out, errOut, err := runAskGuard(t, raw, stdin)
			require.NoError(t, err, "PROJ-13: the hook always exits 0")
			assert.Empty(t, out, "PROJ-13: nothing on stdout lets the tool run")
			assert.Empty(t, errOut)
		})
	}
}

// PROJ-13: before the first `watchtower` run there is no database. The
// hook lets the tool run and creates nothing — no workspace directory, no
// database file (db.Open would create both and migrate).
func TestProj13_AskGuardWithNoDatabaseCreatesNothing(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	configPath := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(configPath, []byte("active_workspace: test\n"), 0o600))
	orig := flagConfig
	flagConfig = configPath
	t.Cleanup(func() { flagConfig = orig })
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	_, statErr := os.Stat(cfg.WorkspaceDir())
	require.True(t, os.IsNotExist(statErr), "fixture: no workspace directory yet")

	out, errOut, err := runAskGuard(t, "1", strings.NewReader(askToolPayload("AskUserQuestion")))

	require.NoError(t, err)
	assert.Empty(t, out)
	assert.Empty(t, errOut)
	_, statErr = os.Stat(cfg.WorkspaceDir())
	assert.True(t, os.IsNotExist(statErr), "PROJ-13: the hook created %s", cfg.WorkspaceDir())
	_, statErr = os.Stat(cfg.DBPath())
	assert.True(t, os.IsNotExist(statErr), "PROJ-13: the hook created the database")
}

// PROJ-13: the hook never migrates. With the newest migration not applied
// it still answers from the tables that are there and leaves the goose
// version where it was — applying a migration could wait behind the
// daemon's write lock far past the 2 s budget.
func TestProj13_AskGuardNeverRunsAMigration(t *testing.T) {
	database := writeActionsConfig(t)
	id, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	var latest int64
	require.NoError(t, database.QueryRow(`SELECT MAX(version_id) FROM goose_db_version`).Scan(&latest))
	_, err = database.Exec(`DELETE FROM goose_db_version WHERE version_id = ?`, latest)
	require.NoError(t, err)

	out, errOut, err := runAskGuard(t, strconv.FormatInt(id, 10), strings.NewReader(askToolPayload("AskUserQuestion")))

	require.NoError(t, err)
	assert.Empty(t, errOut)
	assert.Equal(t, compactDenial(t), out, "the live workbench is still found")
	var after int64
	require.NoError(t, database.QueryRow(`SELECT MAX(version_id) FROM goose_db_version`).Scan(&after))
	assert.Less(t, after, latest, "PROJ-13: the hook applied the pending migration")
}

// A database another process holds exclusively: the guard gives up within
// its busy timeout and lets the tool run, well inside 2 s.
func TestProj13_AskGuardFinishesFastOnALockedDatabase(t *testing.T) {
	database := writeActionsConfig(t)
	id, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	_, err = database.Exec(`PRAGMA locking_mode=EXCLUSIVE`)
	require.NoError(t, err)
	tx, err := database.Begin()
	require.NoError(t, err)
	t.Cleanup(func() { _ = tx.Rollback() })
	_, err = tx.Exec(`UPDATE projects SET name = name`)
	require.NoError(t, err)

	start := time.Now()
	out, errOut, err := runAskGuard(t, strconv.FormatInt(id, 10), strings.NewReader(askToolPayload("AskUserQuestion")))

	assert.Less(t, time.Since(start), 2*time.Second)
	require.NoError(t, err)
	assert.Empty(t, out)
	assert.Empty(t, errOut)
}

func TestAskGuard_WithoutThePreToolUseFlagIsAnError(t *testing.T) {
	writeActionsConfig(t)
	out, _, err := runWorkbenchAs(t, "workbench", "ask-guard", "--workbench", "1")
	require.Error(t, err)
	assert.NotContains(t, out, "hookSpecificOutput")
}
