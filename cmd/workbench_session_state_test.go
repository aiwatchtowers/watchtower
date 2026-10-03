package cmd

import (
	"bytes"
	"context"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// nestedSessionID is a `claude -p` the agent ran from its shell: it inherits
// the row's env var but runs another conversation.
const nestedSessionID = "99999999-8888-4777-8666-555555555555"

func statePayload(event, sessionID, notificationType string) string {
	s := `{"session_id":"` + sessionID + `","transcript_path":"/tmp/x.jsonl","cwd":"/tmp/acme","hook_event_name":"` + event + `"`
	if notificationType != "" {
		s += `,"notification_type":"` + notificationType + `"`
	}
	return s + `}`
}

// runSessionState runs `workbench session-state --workbench N` the way the
// hook does: the payload on stdin.
func runSessionState(t *testing.T, workbenchID int64, stdin io.Reader, extra ...string) (stdout, stderr string, err error) {
	t.Helper()
	rootCmd.SetIn(stdin)
	t.Cleanup(func() { rootCmd.SetIn(nil) })
	args := append([]string{"session-state", "--workbench", strconv.FormatInt(workbenchID, 10)}, extra...)
	return runWorkbenchAs(t, "workbench", args...)
}

// stepClock makes every hook event one second later than the previous one,
// so a sequence of events never collides at the stored precision.
func stepClock(t *testing.T) {
	t.Helper()
	base, n := time.Now(), 0
	orig := hookNow
	hookNow = func() time.Time { n++; return base.Add(time.Duration(n) * time.Second) }
	t.Cleanup(func() { hookNow = orig })
}

func storedAgentState(t *testing.T, database *db.DB, rowID int64) string {
	t.Helper()
	s, err := database.GetTerminalSession(rowID)
	require.NoError(t, err)
	return s.AgentState.String
}

// brokenConfig points the commands at a config that fails to load, so any
// database open prints its failure.
func brokenConfig(t *testing.T) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "broken.yaml")
	require.NoError(t, os.WriteFile(path, []byte("active_workspace: [unterminated\n"), 0o600))
	orig := flagConfig
	flagConfig = path
	t.Cleanup(func() { flagConfig = orig })
}

func unsetTerminalEnv(t *testing.T) {
	t.Helper()
	t.Setenv(terminalSessionEnv, "") // restored after the test, then unset for it
	require.NoError(t, os.Unsetenv(terminalSessionEnv))
}

func TestSessionState_AgentStateFor(t *testing.T) {
	for _, tc := range []struct {
		event, notification string
		state, onlyFrom     string
		ok                  bool
	}{
		{"UserPromptSubmit", "", "working", "", true},
		{"Stop", "", "waiting", "", true},
		{"StopFailure", "", "waiting", "", true},
		{"PostToolUse", "", "working", "approval", true},
		{"Notification", "permission_prompt", "approval", "", true},
		{"Notification", "elicitation_dialog", "approval", "", true},
		{"Notification", "idle_prompt", "waiting", "", true},
		{"Notification", "auth_success", "", "", false},
		{"Notification", "agent_completed", "", "", false},
		{"Notification", "", "", "", false},
		{"SessionStart", "", "", "", false},
		{"PreToolUse", "", "", "", false},
		{"", "", "", "", false},
	} {
		state, onlyFrom, ok := agentStateFor(tc.event, tc.notification)
		assert.Equal(t, tc.ok, ok, "%s/%s", tc.event, tc.notification)
		assert.Equal(t, tc.state, state, "%s/%s", tc.event, tc.notification)
		assert.Equal(t, tc.onlyFrom, onlyFrom, "%s/%s", tc.event, tc.notification)
	}
}

func TestSessionState_RecordsEachEvent(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	stepClock(t)

	for _, step := range []struct {
		payload, want string
	}{
		{statePayload("UserPromptSubmit", briefLaunchID, ""), "working"},
		{statePayload("Notification", briefLaunchID, "permission_prompt"), "approval"},
		{statePayload("PostToolUse", briefLaunchID, ""), "working"},
		{statePayload("Notification", briefLaunchID, "idle_prompt"), "waiting"},
		{statePayload("PostToolUse", briefLaunchID, ""), "waiting"}, // only an approval clears
		{statePayload("Notification", briefLaunchID, "auth_success"), "waiting"},
		{statePayload("UserPromptSubmit", briefLaunchID, ""), "working"},
		{statePayload("StopFailure", briefLaunchID, ""), "waiting"},
		{statePayload("Notification", briefLaunchID, "elicitation_dialog"), "approval"},
		{statePayload("SessionEnd", briefLaunchID, ""), "approval"},
	} {
		out, errOut, err := runSessionState(t, pid, strings.NewReader(step.payload))
		require.NoError(t, err)
		assert.Empty(t, out)
		assert.Empty(t, errOut)
		assert.Equal(t, step.want, storedAgentState(t, database, row), "after %s", step.payload)
	}
}

// A PostToolUse input carries the tool's input and result: one past the
// other hooks' 1 MiB cap still clears "needs approval".
func TestSessionState_LargePostToolUsePayloadClearsApproval(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	stepClock(t)
	_, _, err := runSessionState(t, pid, strings.NewReader(statePayload("Notification", briefLaunchID, "permission_prompt")))
	require.NoError(t, err)
	require.Equal(t, "approval", storedAgentState(t, database, row))

	big := `{"session_id":"` + briefLaunchID + `","hook_event_name":"PostToolUse","tool_name":"Write",` +
		`"tool_input":{"file_path":"/tmp/acme/a.txt","content":"` + strings.Repeat("x", hookStdinLimit+1) + `"},` +
		`"tool_response":{"success":true}}`
	require.Greater(t, len(big), hookStdinLimit)
	out, errOut, err := runSessionState(t, pid, strings.NewReader(big))

	require.NoError(t, err)
	assert.Empty(t, out)
	assert.Empty(t, errOut)
	assert.Equal(t, "working", storedAgentState(t, database, row))
}

// An external terminal has no row: the hook neither reads stdin nor opens
// the database (a broken config would print a line if it did).
func TestSessionState_NoEnvReadsNothing(t *testing.T) {
	writeActionsConfig(t)
	unsetTerminalEnv(t)
	brokenConfig(t)

	out, errOut, err := runSessionState(t, 1, readerFunc(func([]byte) (int, error) {
		t.Error("stdin was read without the terminal env var")
		return 0, io.EOF
	}))
	require.NoError(t, err)
	assert.Empty(t, out)
	assert.Empty(t, errOut)
}

type readerFunc func([]byte) (int, error)

func (f readerFunc) Read(p []byte) (int, error) { return f(p) }

func TestProj11_HookNeverWritesStdoutAndExitsZero(t *testing.T) {
	orig := sessionStateInputWait
	sessionStateInputWait = 50 * time.Millisecond
	t.Cleanup(func() { sessionStateInputWait = orig })

	for _, tc := range []struct {
		name       string
		stdin      func(t *testing.T) io.Reader
		env        func(row int64) string
		setup      func(t *testing.T, database *db.DB, row int64)
		args       []string
		wantState  string
		wantStderr string
	}{
		{name: "valid write", wantState: "working"},
		{name: "repeat is a no-op", wantState: "working", setup: func(t *testing.T, database *db.DB, row int64) {
			s, err := database.GetTerminalSession(row)
			require.NoError(t, err)
			_, err = database.SetTerminalAgentState(row, s.WorkbenchID.Int64, briefLaunchID, "working", time.Now().Add(-time.Hour), "")
			require.NoError(t, err)
		}},
		{name: "unknown flag", args: []string{"--future-flag"}, wantState: "working"},
		{name: "bad env", env: func(row int64) string { return "row-" + strconv.FormatInt(row, 10) }, wantStderr: "invalid " + terminalSessionEnv},
		{name: "bad json", stdin: func(*testing.T) io.Reader { return strings.NewReader(`{"session_id":`) }, wantStderr: "reading the hook input"},
		{name: "empty stdin", stdin: func(*testing.T) io.Reader { return strings.NewReader(``) }},
		{name: "not a uuid", stdin: func(*testing.T) io.Reader {
			return strings.NewReader(statePayload("UserPromptSubmit", "../../etc", ""))
		}, wantStderr: "carries no session id"},
		{name: "no session id", stdin: func(*testing.T) io.Reader {
			return strings.NewReader(`{"hook_event_name":"UserPromptSubmit"}`)
		}},
		{name: "stdin never closed", stdin: func(t *testing.T) io.Reader {
			r, w := io.Pipe()
			t.Cleanup(func() { _ = w.Close() })
			return r
		}, wantStderr: "reading the hook input"},
		{name: "broken config", setup: func(t *testing.T, _ *db.DB, _ int64) {
			brokenConfig(t)
		}, wantStderr: "session state not recorded"},
		{name: "deleted row", setup: func(t *testing.T, database *db.DB, row int64) {
			_, err := database.Exec(`DELETE FROM terminal_sessions WHERE id = ?`, row)
			require.NoError(t, err)
		}},
		{name: "panic", setup: func(t *testing.T, _ *db.DB, _ int64) {
			orig := hookNow
			hookNow = func() time.Time { panic("boom") }
			t.Cleanup(func() { hookNow = orig })
		}, wantStderr: "panic: boom"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			database, pid, row := briefSessionFixture(t)
			env := strconv.FormatInt(row, 10)
			if tc.env != nil {
				env = tc.env(row)
			}
			t.Setenv(terminalSessionEnv, env)
			if tc.setup != nil {
				tc.setup(t, database, row)
			}
			var stdin io.Reader = strings.NewReader(statePayload("UserPromptSubmit", briefLaunchID, ""))
			if tc.stdin != nil {
				stdin = tc.stdin(t)
			}

			out, errOut, err := runSessionState(t, pid, stdin, tc.args...)

			require.NoError(t, err, "the hook always exits 0")
			assert.Empty(t, out, "a UserPromptSubmit hook's stdout would become agent context")
			if tc.wantStderr == "" {
				assert.Empty(t, errOut)
			} else {
				assert.Contains(t, errOut, tc.wantStderr)
				assert.Equal(t, 1, strings.Count(errOut, "\n"), "one stderr line")
			}
			if tc.name != "deleted row" {
				assert.Equal(t, tc.wantState, storedAgentState(t, database, row))
			}
			if tc.name == "repeat is a no-op" {
				s, err := database.GetTerminalSession(row)
				require.NoError(t, err)
				assert.False(t, s.AgentStateAt.IsZero())
				assert.True(t, s.AgentStateAt.Before(time.Now().Add(-30*time.Minute)), "a repeat keeps the transition time, got %v", s.AgentStateAt)
			}
		})
	}
}

func TestProj11_NestedSessionNeverMovesTheRow(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	stepClock(t)
	_, _, err := runSessionState(t, pid, strings.NewReader(statePayload("UserPromptSubmit", briefLaunchID, "")))
	require.NoError(t, err)
	require.Equal(t, "working", storedAgentState(t, database, row))

	for _, p := range []string{
		statePayload("Notification", nestedSessionID, "permission_prompt"),
		statePayload("Notification", nestedSessionID, "idle_prompt"),
		statePayload("StopFailure", nestedSessionID, ""),
	} {
		out, errOut, err := runSessionState(t, pid, strings.NewReader(p))
		require.NoError(t, err)
		assert.Empty(t, out)
		assert.Empty(t, errOut)
	}
	// The nested run's Stop hook too.
	out, errOut := stopHookIO(t, strconv.FormatInt(pid, 10), statePayload("Stop", nestedSessionID, ""))
	assert.Empty(t, out)
	assert.Empty(t, errOut)

	assert.Equal(t, "working", storedAgentState(t, database, row))
}

// stopStateFixture: a drift workbench (branch "merged" drifts, "open" does
// not) with one embedded claude row running briefLaunchID.
func stopStateFixture(t *testing.T, branch string) (database *db.DB, pid, row int64) {
	t.Helper()
	database = writeActionsConfig(t)
	pid, _ = driftWorkbench(t, database, driftRepo(t), branch)
	res, err := database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, 'claude', 's', '/tmp/acme', ?)`, pid, briefLaunchID)
	require.NoError(t, err)
	row, err = res.LastInsertId()
	require.NoError(t, err)
	return database, pid, row
}

func TestSessionState_StopHookRecordsWaitingWithoutDrift(t *testing.T) {
	database, pid, row := stopStateFixture(t, "open")
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))

	out, errOut := stopHookIO(t, strconv.FormatInt(pid, 10), statePayload("Stop", briefLaunchID, ""))

	assert.Empty(t, out)
	assert.Empty(t, errOut)
	assert.Equal(t, "waiting", storedAgentState(t, database, row))
}

// The turn goes on when the hook blocks: no "waiting", and stdout is the
// same block JSON as outside a Desktop terminal.
func TestSessionState_StopHookBlockWritesNoState(t *testing.T) {
	database, pid, row := stopStateFixture(t, "merged")
	payload := statePayload("Stop", briefLaunchID, "")
	unsetTerminalEnv(t)
	plain, _ := stopHookIO(t, strconv.FormatInt(pid, 10), payload)
	require.NotEmpty(t, plain)

	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	out, errOut := stopHookIO(t, strconv.FormatInt(pid, 10), payload)

	assert.Equal(t, plain, out, "the block JSON is byte-identical")
	assert.Empty(t, errOut)
	assert.Empty(t, storedAgentState(t, database, row))
}

func TestSessionState_StopHookActive(t *testing.T) {
	payload := `{"session_id":"` + briefLaunchID + `","hook_event_name":"Stop","stop_hook_active":true}`
	t.Run("with the env var the continued turn ended", func(t *testing.T) {
		database, pid, row := stopStateFixture(t, "merged")
		t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))

		out, errOut := stopHookIO(t, strconv.FormatInt(pid, 10), payload)

		assert.Empty(t, out, "never blocks twice")
		assert.Empty(t, errOut)
		assert.Equal(t, "waiting", storedAgentState(t, database, row))
	})
	t.Run("without it no database is opened", func(t *testing.T) {
		_, pid, _ := stopStateFixture(t, "merged")
		unsetTerminalEnv(t)
		brokenConfig(t)

		out, errOut := stopHookIO(t, strconv.FormatInt(pid, 10), payload)

		assert.Empty(t, out)
		assert.Empty(t, errOut, "a broken config would print a line if the DB were opened")
	})
}

// In a Desktop terminal a Stop whose input cannot be read, or whose
// --workbench is bad on the stop_hook_active path, says the state was lost
// in one stderr line; stdout stays empty.
func TestSessionState_StopHookLostStateIsOneLine(t *testing.T) {
	for _, tc := range []struct{ name, rawID, input, want string }{
		{"unreadable input", "", `{"session_id":`, "session state not recorded: reading the hook input"},
		{"bad id on the continued turn", "abc", `{"session_id":"` + briefLaunchID + `","stop_hook_active":true}`, "session state not recorded: invalid --workbench"},
		{"bad id", "abc", `{"session_id":"` + briefLaunchID + `"}`, "board drift check skipped and session state not recorded: invalid --workbench"},
		{"broken config", "", statePayload("Stop", briefLaunchID, ""), "board drift check skipped and session state not recorded"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			database, pid, row := stopStateFixture(t, "open")
			t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
			if tc.name == "broken config" {
				brokenConfig(t)
			}
			rawID := tc.rawID
			if rawID == "" {
				rawID = strconv.FormatInt(pid, 10)
			}

			out, errOut := stopHookIO(t, rawID, tc.input)

			assert.Empty(t, out)
			assert.Contains(t, errOut, tc.want)
			assert.Equal(t, 1, strings.Count(errOut, "\n"), "one stderr line")
			assert.Empty(t, storedAgentState(t, database, row))
		})
	}
}

// A folder never resynced since the rename runs the legacy Stop entry
// (`project check --project N`); its state half arrives with the binary too.
func TestSessionState_LegacyStopHookRecordsWaiting(t *testing.T) {
	database, pid, row := stopStateFixture(t, "open")
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	var out, errOut bytes.Buffer

	runStopHook(context.Background(), strings.NewReader(statePayload("Stop", briefLaunchID, "")), &out, &errOut,
		strconv.FormatInt(pid, 10), legacyWorkbenchVocabulary)

	assert.Empty(t, out.String())
	assert.Empty(t, errOut.String())
	assert.Equal(t, "waiting", storedAgentState(t, database, row))
}

// A failed state write on the Stop path is one stderr line; stdout stays
// empty and the drift decision is unchanged.
func TestSessionState_StopHookStateFailureIsOneLine(t *testing.T) {
	_, pid, _ := stopStateFixture(t, "open")
	t.Setenv(terminalSessionEnv, "nope")

	out, errOut := stopHookIO(t, strconv.FormatInt(pid, 10), statePayload("Stop", briefLaunchID, ""))

	assert.Empty(t, out)
	assert.Contains(t, errOut, "invalid "+terminalSessionEnv)
	assert.Equal(t, 1, strings.Count(errOut, "\n"))
}
