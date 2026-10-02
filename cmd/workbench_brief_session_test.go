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
	projectID, err := database.CreateWorkbench("acme", t.TempDir())
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
	out, errOut, err := runWorkbench(t, "brief", "--project", strconv.FormatInt(projectID, 10))
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
	for _, source := range []string{"clear", "compact", "resume", "fork"} {
		t.Run(source, func(t *testing.T) {
			database, pid, row := briefSessionFixture(t)
			t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))

			out, errOut := runBriefHook(t, pid, hookPayload(source, briefClearedID))

			assert.Equal(t, briefClearedID, storedClaudeSessionID(t, database, row))
			assert.Contains(t, out, "Setup pending", "the brief is still printed")
			assert.Empty(t, errOut)
		})
	}
}

// The dual path's other half is TerminalLaunch.sessionRowEnv.
func TestTerminalSessionEnvName(t *testing.T) {
	assert.Equal(t, "WATCHTOWER_TERMINAL_SESSION_ID", terminalSessionEnv)
}

func TestProjectBrief_HookWritesNothingWithoutTheTerminalEnv(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, "") // restored after the test, then unset for it
	require.NoError(t, os.Unsetenv(terminalSessionEnv))

	out, errOut := runBriefHook(t, pid, hookPayload("clear", briefClearedID))

	assert.Equal(t, briefLaunchID, storedClaudeSessionID(t, database, row), "an owner's own terminal has no row")
	assert.Contains(t, out, "Setup pending")
	assert.Empty(t, errOut)
}

func TestProjectBrief_HookLeavesAnotherProjectsRowAlone(t *testing.T) {
	database, _, row := briefSessionFixture(t)
	other, err := database.CreateWorkbench("other", t.TempDir())
	require.NoError(t, err)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))

	runBriefHook(t, other, hookPayload("clear", briefClearedID))

	assert.Equal(t, briefLaunchID, storedClaudeSessionID(t, database, row))
}

// Whatever stdin and the env var hold, the row keeps its id, the brief is
// printed and the hook exits 0; a deliberate skip is silent, a broken
// contract is one stderr line.
func TestProjectBrief_HookSkipsAndBadInputStillPrintTheBrief(t *testing.T) {
	for _, tc := range []struct {
		name       string
		stdin      string
		env        func(row int64) string
		wantStderr string
	}{
		// A startup is the launch's own id — or a nested `claude -p` the
		// agent ran, which inherits the env var and must not take the row.
		{name: "startup", stdin: hookPayload("startup", briefClearedID)},
		{name: "unknown source", stdin: hookPayload("later", briefClearedID)},
		{name: "empty stdin", stdin: ""},
		{name: "malformed json", stdin: `{"session_id":`, wantStderr: "reading the hook input"},
		{name: "not a uuid", stdin: hookPayload("clear", "../../etc; rm -rf ~"), wantStderr: "carries no session id"},
		{name: "uppercase uuid", stdin: hookPayload("clear", strings.ToUpper(briefClearedID)), wantStderr: "carries no session id"},
		{name: "no session id", stdin: `{"source":"clear"}`, wantStderr: "carries no session id"},
		{
			name: "bad env row id", stdin: hookPayload("clear", briefClearedID),
			env: func(row int64) string { return "row-" + strconv.FormatInt(row, 10) }, wantStderr: "invalid " + terminalSessionEnv,
		},
		{
			name: "deleted row", stdin: hookPayload("clear", briefClearedID),
			env: func(row int64) string { return strconv.FormatInt(row+100, 10) },
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			database, pid, row := briefSessionFixture(t)
			env := strconv.FormatInt(row, 10)
			if tc.env != nil {
				env = tc.env(row)
			}
			t.Setenv(terminalSessionEnv, env)

			out, errOut := runBriefHook(t, pid, tc.stdin)

			assert.Equal(t, briefLaunchID, storedClaudeSessionID(t, database, row))
			assert.Contains(t, out, "Setup pending", "the brief is printed whatever stdin holds")
			if tc.wantStderr == "" {
				assert.Empty(t, errOut)
			} else {
				assert.Contains(t, errOut, tc.wantStderr)
				assert.Equal(t, 1, strings.Count(errOut, "\n"), "one stderr line")
			}
		})
	}
}

// A hook input that never arrives (stdin left open) costs at most the wait,
// never a stalled session start: the brief is printed after it.
func TestProjectBrief_HookNeverStallsOnAnOpenStdin(t *testing.T) {
	orig := sessionStartInputWait
	sessionStartInputWait = 50 * time.Millisecond
	t.Cleanup(func() { sessionStartInputWait = orig })
	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	r, w := io.Pipe()
	t.Cleanup(func() { _ = w.Close() })
	rootCmd.SetIn(r)
	t.Cleanup(func() { rootCmd.SetIn(nil) })

	start := time.Now()
	out, errOut, err := runWorkbench(t, "brief", "--project", strconv.FormatInt(pid, 10))

	require.NoError(t, err)
	assert.Less(t, time.Since(start), 5*time.Second)
	assert.Contains(t, out, "Setup pending")
	assert.Contains(t, errOut, "reading the hook input")
	assert.Equal(t, briefLaunchID, storedClaudeSessionID(t, database, row))
}
