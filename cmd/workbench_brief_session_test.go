package cmd

import (
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/devpack"
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

// installBriefStateHooks gives the fixture workbench's folder the session
// state hooks.
func installBriefStateHooks(t *testing.T, database *db.DB, projectID int64) {
	t.Helper()
	wb, err := database.GetWorkbench(projectID)
	require.NoError(t, err)
	_, err = devpack.InstallStateHooks(wb.FolderPath, "watchtower", projectID)
	require.NoError(t, err)
}

// storeAgentState gives the fixture row a state from a previous run.
func storeAgentState(t *testing.T, database *db.DB, projectID, rowID int64, sessionID string) {
	t.Helper()
	ok, err := database.SetTerminalAgentState(rowID, projectID, sessionID, "waiting", time.Now().Add(-time.Minute), "", nil, false, db.AgentOrder{})
	require.NoError(t, err)
	require.True(t, ok)
}

// Board #312: a launch or a resume is a new process run, so the previous
// run's agent state goes — after the id moved, so a resume onto another
// conversation clears too. /clear and compaction keep it (the same run), and
// a nested `claude -p` (another id) clears nothing. The brief is unchanged.
// Board #396: with the state hooks the new run is stamped (its mark),
// without them it is left with no stamp.
func TestProjectBrief_HookClearsTheAgentStateOnANewRun(t *testing.T) {
	for _, hooks := range []bool{true, false} {
		for _, tc := range []struct {
			name, source, sessionID string
			cleared                 bool
		}{
			{"startup", "startup", briefLaunchID, true},
			{"resume", "resume", briefLaunchID, true},
			{"resume onto another conversation", "resume", briefClearedID, true},
			{"clear", "clear", briefClearedID, false},
			{"compact", "compact", briefLaunchID, false},
			{"nested session", "startup", briefClearedID, false},
		} {
			t.Run(fmt.Sprintf("%s hooks=%v", tc.name, hooks), func(t *testing.T) {
				database, pid, row := briefSessionFixture(t)
				if hooks {
					installBriefStateHooks(t, database, pid)
				}
				storeAgentState(t, database, pid, row, briefLaunchID)
				before, err := database.GetTerminalSession(row)
				require.NoError(t, err)
				t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
				want, _ := runBriefHook(t, pid, "") // the brief without a payload

				out, errOut := runBriefHook(t, pid, hookPayload(tc.source, tc.sessionID))

				s, err := database.GetTerminalSession(row)
				require.NoError(t, err)
				assert.Equal(t, !tc.cleared, s.AgentState.Valid, "agent state kept")
				switch {
				case !tc.cleared:
					assert.Equal(t, before.AgentStateAt, s.AgentStateAt, "the run's stamp kept")
				case hooks:
					assert.True(t, s.AgentStateAt.After(before.AgentStateAt), "the new run is marked")
				default:
					assert.True(t, s.AgentStateAt.IsZero(), "no stamp without the state hooks")
				}
				assert.Equal(t, want, out, "the brief is byte-identical")
				assert.Empty(t, errOut)
			})
		}
	}
}

// PROJ-12 (amended 2026-10-07, board #396): a launch or a resume of a
// session whose folder has the state hooks marks the run even with nothing
// stored — agent_state NULL with a stamp of this run, the Desktop's sign
// that the hooks run and no turn has started, so an ask's answer gets its
// Return. Without the hooks nothing is stamped, and a nested `claude -p`
// (another id) marks nothing.
func TestProj12_ANewRunWithTheStateHooksIsMarked(t *testing.T) {
	for _, tc := range []struct {
		name, source, sessionID string
		hooks, marked           bool
	}{
		{"startup", "startup", briefLaunchID, true, true},
		{"resume", "resume", briefLaunchID, true, true},
		{"startup without the state hooks", "startup", briefLaunchID, false, false},
		{"resume without the state hooks", "resume", briefLaunchID, false, false},
		{"nested session", "startup", briefClearedID, true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			database, pid, row := briefSessionFixture(t)
			if tc.hooks {
				installBriefStateHooks(t, database, pid)
			}
			t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
			start := time.Now().UTC().Truncate(time.Millisecond)

			_, errOut := runBriefHook(t, pid, hookPayload(tc.source, tc.sessionID))

			assert.Empty(t, errOut)
			s, err := database.GetTerminalSession(row)
			require.NoError(t, err)
			assert.False(t, s.AgentState.Valid, "a mark is no state")
			if tc.marked {
				assert.False(t, s.AgentStateAt.Before(start), "stamped during this run: %v", s.AgentStateAt)
			} else {
				assert.True(t, s.AgentStateAt.IsZero(), "nothing stamped: %v", s.AgentStateAt)
			}
		})
	}
}

// PROJ-12 (amended 2026-10-07, board #396): a compaction — a manual
// /compact or the one Claude Code runs by itself while idle — continues the
// run: its SessionStart ("compact", onto the same or a new id) keeps the
// run's stored state and its stamp, a turn's `waiting` or a fresh run's
// mark, so the session still gets an answer's Return.
func TestProj12_CompactWhileIdleKeepsTheRunsState(t *testing.T) {
	for _, tc := range []struct {
		name, sessionID string
		waiting         bool
	}{
		{"after a turn", briefLaunchID, true},
		{"after a turn, onto a new id", briefClearedID, true},
		{"before any turn", briefLaunchID, false},
		{"before any turn, onto a new id", briefClearedID, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			database, pid, row := briefSessionFixture(t)
			installBriefStateHooks(t, database, pid)
			t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
			_, errOut := runBriefHook(t, pid, hookPayload("startup", briefLaunchID))
			require.Empty(t, errOut)
			if tc.waiting {
				ok, err := database.SetTerminalAgentState(row, pid, briefLaunchID, "waiting", time.Now().Add(time.Second),
					"", nil, false, db.AgentOrder{})
				require.NoError(t, err)
				require.True(t, ok)
			}
			before, err := database.GetTerminalSession(row)
			require.NoError(t, err)
			require.False(t, before.AgentStateAt.IsZero())

			_, errOut = runBriefHook(t, pid, hookPayload("compact", tc.sessionID))

			assert.Empty(t, errOut)
			s, err := database.GetTerminalSession(row)
			require.NoError(t, err)
			assert.Equal(t, tc.sessionID, s.ClaudeSessionID.String)
			assert.Equal(t, before.AgentState, s.AgentState)
			assert.True(t, before.AgentStateAt.Equal(s.AgentStateAt), "stamp %v, was %v", s.AgentStateAt, before.AgentStateAt)
		})
	}
}

// Board #368: a new run also drops a turn end stored without any agent
// state (a Stop recorded it, a hook write failed), so the earlier run's
// offset never orders the new run's tool results.
func TestProjectBrief_HookClearsATurnEndWithoutAState(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	ok, err := database.SetTerminalTurnEnd(row, pid, briefLaunchID, 100)
	require.NoError(t, err)
	require.True(t, ok)
	s, err := database.GetTerminalSession(row)
	require.NoError(t, err)
	require.False(t, s.AgentState.Valid)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))

	_, errOut := runBriefHook(t, pid, hookPayload("startup", briefLaunchID))

	assert.Empty(t, errOut)
	s, err = database.GetTerminalSession(row)
	require.NoError(t, err)
	assert.False(t, s.TurnEnd.Valid, "the previous run's turn end went")
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
