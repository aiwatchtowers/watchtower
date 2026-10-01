package cmd

import (
	"io"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

const (
	briefLaunchID  = "11111111-2222-4333-8444-555555555555"
	briefClearedID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
)

// briefSessionFixture: a project with one embedded claude row launched with
// briefLaunchID.
func briefSessionFixture(t *testing.T) (database *db.DB, projectID, rowID int64) {
	t.Helper()
	database = writeActionsConfig(t)
	projectID, err := database.CreateProject("acme", t.TempDir())
	require.NoError(t, err)
	res, err := database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, 'claude', 's', '/tmp/acme', ?)`, projectID, briefLaunchID)
	require.NoError(t, err)
	rowID, err = res.LastInsertId()
	require.NoError(t, err)
	return database, projectID, rowID
}

// runBriefHook runs `project brief --project N` the way the SessionStart hook
// does: the payload on stdin.
func runBriefHook(t *testing.T, projectID int64, stdin string) (stdout, stderr string) {
	t.Helper()
	rootCmd.SetIn(strings.NewReader(stdin))
	t.Cleanup(func() { rootCmd.SetIn(nil) })
	out, errOut, err := runProject(t, "brief", "--project", strconv.FormatInt(projectID, 10))
	require.NoError(t, err, "the hook always exits 0")
	return out, errOut
}

func storedClaudeSessionID(t *testing.T, database *db.DB, rowID int64) string {
	t.Helper()
	s, err := database.GetTerminalSession(rowID)
	require.NoError(t, err)
	return s.ClaudeSessionID.String
}

func hookPayload(source, sessionID string) string {
	return `{"session_id":"` + sessionID + `","transcript_path":"/tmp/x.jsonl","cwd":"/tmp/acme",` +
		`"hook_event_name":"SessionStart","source":"` + source + `"}`
}

// Board #160: after /clear the row follows the new conversation, so the
// Desktop's next relaunch resumes it, and the brief is printed as before.
func TestProjectBrief_HookRecordsTheSessionIDAfterClear(t *testing.T) {
	for _, source := range []string{"clear", "compact", "resume"} {
		t.Run(source, func(t *testing.T) {
			database, pid, row := briefSessionFixture(t)
			t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))

			out, _ := runBriefHook(t, pid, hookPayload(source, briefClearedID))

			assert.Equal(t, briefClearedID, storedClaudeSessionID(t, database, row))
			assert.Contains(t, out, "Setup pending", "the brief is still printed")
		})
	}
}

func TestProjectBrief_HookWritesNothingWithoutTheTerminalEnv(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, "") // restored after the test, then unset for it
	require.NoError(t, os.Unsetenv(terminalSessionEnv))

	out, _ := runBriefHook(t, pid, hookPayload("clear", briefClearedID))

	assert.Equal(t, briefLaunchID, storedClaudeSessionID(t, database, row), "an owner's own terminal has no row")
	assert.Contains(t, out, "Setup pending")
}

// A startup is the launch's own id — or a nested `claude -p` the agent ran,
// which inherits the env var and must not take the row over.
func TestProjectBrief_HookIgnoresStartup(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))

	runBriefHook(t, pid, hookPayload("startup", briefClearedID))

	assert.Equal(t, briefLaunchID, storedClaudeSessionID(t, database, row))
}

func TestProjectBrief_HookLeavesAnotherProjectsRowAlone(t *testing.T) {
	database, _, row := briefSessionFixture(t)
	other, err := database.CreateProject("other", t.TempDir())
	require.NoError(t, err)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))

	runBriefHook(t, other, hookPayload("clear", briefClearedID))

	assert.Equal(t, briefLaunchID, storedClaudeSessionID(t, database, row))
}

func TestProjectBrief_HookBadInputStillPrintsTheBrief(t *testing.T) {
	for name, stdin := range map[string]string{
		"malformed json":   `{"session_id":`,
		"not a uuid":       hookPayload("clear", "../../etc; rm -rf ~"),
		"uppercase uuid":   hookPayload("clear", strings.ToUpper(briefClearedID)),
		"unknown source":   hookPayload("later", briefClearedID),
		"empty":            "",
		"bad env row id":   hookPayload("clear", briefClearedID),
		"oversized object": `{"session_id":"` + strings.Repeat("a", 2*sessionStartInputMax) + `"}`,
	} {
		t.Run(name, func(t *testing.T) {
			database, pid, row := briefSessionFixture(t)
			env := strconv.FormatInt(row, 10)
			if name == "bad env row id" {
				env = "row-" + env
			}
			t.Setenv(terminalSessionEnv, env)

			out, errOut := runBriefHook(t, pid, stdin)

			assert.Equal(t, briefLaunchID, storedClaudeSessionID(t, database, row))
			assert.Contains(t, out, "Setup pending", "the brief is printed whatever stdin holds")
			if name == "malformed json" || name == "oversized object" {
				assert.Contains(t, errOut, "decoding the hook input", "a bad payload is one stderr line")
			}
		})
	}
}

// A payload that never arrives (stdin left open) costs at most the wait,
// never a stalled session start.
func TestReadSessionStartInput_NeverStalls(t *testing.T) {
	orig := sessionStartInputWait
	sessionStartInputWait = 50 * time.Millisecond
	t.Cleanup(func() { sessionStartInputWait = orig })
	r, w := io.Pipe()
	t.Cleanup(func() { _ = w.Close() })

	start := time.Now()
	_, err := readSessionStartInput(r)

	require.Error(t, err)
	assert.Less(t, time.Since(start), 2*time.Second)
}
