package cmd

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
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
	"watchtower/internal/devpack"
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
		{"PostToolUse", "", "working", "", true},
		{"SubagentStop", "", "", "", true},
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
		{statePayload("Notification", briefLaunchID, "auth_success"), "waiting"},
		{statePayload("PostToolUse", briefLaunchID, ""), "working"}, // a turn started without a prompt
		{statePayload("Notification", briefLaunchID, "idle_prompt"), "waiting"},
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

// A turn the owner did not start (a teammate or background-task message, a
// wakeup) fires no UserPromptSubmit: its first tool result turns a stored
// "waiting" back to "working". A late PostToolUse stamped before the stop's
// "waiting" still writes nothing (PROJ-11's older-event guard).
func TestSessionState_ToolResultEndsWaitingOfASelfStartedTurn(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	base := time.Now()
	orig := hookNow
	t.Cleanup(func() { hookNow = orig })
	at := func(sec int) { hookNow = func() time.Time { return base.Add(time.Duration(sec) * time.Second) } }
	record := func(event string) {
		t.Helper()
		_, _, err := runSessionState(t, pid, strings.NewReader(statePayload(event, briefLaunchID, "")))
		require.NoError(t, err)
	}

	at(2)
	record("StopFailure")
	require.Equal(t, "waiting", storedAgentState(t, database, row))
	at(1)
	record("PostToolUse")
	assert.Equal(t, "waiting", storedAgentState(t, database, row), "a tool result older than the stop")
	at(3)
	record("PostToolUse")
	assert.Equal(t, "working", storedAgentState(t, database, row), "the self-started turn's first tool result")
}

// A background subagent's tool result never ends the main turn's "waiting"
// (the agent asked the owner and stopped); it still clears a granted
// permission.
func TestSessionState_SubagentToolResultClearsOnlyApproval(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	stepClock(t)
	subagent := `{"session_id":"` + briefLaunchID + `","hook_event_name":"PostToolUse","agent_id":"a1b2c3","agent_type":"general-purpose"}`

	for _, step := range []struct {
		payload, want string
	}{
		{statePayload("Notification", briefLaunchID, "idle_prompt"), "waiting"},
		{subagent, "waiting"},
		{statePayload("Notification", briefLaunchID, "permission_prompt"), "approval"},
		{subagent, "working"},
	} {
		_, _, err := runSessionState(t, pid, strings.NewReader(step.payload))
		require.NoError(t, err)
		assert.Equal(t, step.want, storedAgentState(t, database, row), "after %s", step.payload)
	}
}

// The subagent rule covers only PostToolUse: a subagent's permission prompt
// (agent_id set) still records "needs approval", whether the main turn is
// working or stopped and waiting.
func TestSessionState_SubagentPermissionPromptRecordsApproval(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	stepClock(t)
	prompt := `{"session_id":"` + briefLaunchID + `","hook_event_name":"Notification","notification_type":"permission_prompt","agent_id":"a1b2c3","agent_type":"general-purpose"}`

	for _, step := range []struct {
		payload, want string
	}{
		{statePayload("UserPromptSubmit", briefLaunchID, ""), "working"},
		{prompt, "approval"},
		{statePayload("Notification", briefLaunchID, "idle_prompt"), "waiting"},
		{prompt, "approval"},
	} {
		_, _, err := runSessionState(t, pid, strings.NewReader(step.payload))
		require.NoError(t, err)
		assert.Equal(t, step.want, storedAgentState(t, database, row), "after %s", step.payload)
	}
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
			_, err = database.SetTerminalAgentState(row, s.WorkbenchID.Int64, briefLaunchID, "working", time.Now().Add(-time.Hour), "", nil, false, db.AgentOrder{})
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
		{name: "subagent stop", stdin: func(*testing.T) io.Reader {
			return strings.NewReader(subagentStop("a", "general-purpose", subagents("a", "b")))
		}},
		{name: "subagent stop bad json", stdin: func(*testing.T) io.Reader {
			return strings.NewReader(`{"hook_event_name":"SubagentStop","session_id":`)
		}, wantStderr: "reading the hook input"},
		{name: "subagent stop list not an array", stdin: func(*testing.T) io.Reader {
			return strings.NewReader(subagentStop("a", "general-purpose", `{"a":1}`))
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

	// Board #411: over a counted `waiting`, the nested run's SubagentStop and
	// its subagent's tool result neither lower nor stamp the count.
	_, err = database.SetTerminalAgentState(row, pid, briefLaunchID, "waiting", hookNow(), "", nil, false,
		db.AgentOrder{Stop: true, Background: sql.NullInt64{Int64: 3, Valid: true}})
	require.NoError(t, err)
	before := rowSnapshot(t, database, row)
	require.Equal(t, int64(3), before["agent_background"])
	for _, p := range []string{
		strings.ReplaceAll(subagentStop("x", "general-purpose", "[]"), briefLaunchID, nestedSessionID),
		subagentToolResult(nestedSessionID),
	} {
		out, errOut, err := runSessionState(t, pid, strings.NewReader(p))
		require.NoError(t, err)
		assert.Empty(t, out)
		assert.Empty(t, errOut)
	}
	assert.Equal(t, before, rowSnapshot(t, database, row))
}

// stopStateFixture: a drift workbench (branch "merged" drifts, "open" does
// not) whose folder has the session state hooks, with one embedded claude
// row running briefLaunchID.
func stopStateFixture(t *testing.T, branch string) (database *db.DB, pid, row int64) {
	t.Helper()
	database = writeActionsConfig(t)
	folder := driftRepo(t)
	pid, _ = driftWorkbench(t, database, folder, branch)
	_, err := devpack.InstallStateHooks(folder, "watchtower", pid)
	require.NoError(t, err)
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

// A folder still on the legacy Stop entry (`project check --project N`)
// records the state like the new one once it has the state hooks.
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

// Without the state hooks nothing records "working", so the Stop hook
// records nothing either (board #340): no "waiting" stuck after the first
// turn of a folder not yet repaired. A malformed settings file counts as no
// state hooks. stdout and stderr are what they are outside a Desktop
// terminal: the block JSON on drift, nothing otherwise.
func TestSessionState_StopHookWithoutStateHooksRecordsNothing(t *testing.T) {
	for _, tc := range []struct {
		name     string
		settings func(t *testing.T, folder string, pid int64)
	}{
		{"hooks removed", func(t *testing.T, folder string, pid int64) {
			changed, err := devpack.RemoveStateHooks(folder, pid)
			require.NoError(t, err)
			require.True(t, changed)
		}},
		{"one state hook missing", func(t *testing.T, folder string, _ int64) {
			file := filepath.Join(folder, ".claude", "settings.local.json")
			b, err := os.ReadFile(file)
			require.NoError(t, err)
			var settings map[string]any
			require.NoError(t, json.Unmarshal(b, &settings))
			hooks := settings["hooks"].(map[string]any)
			require.Contains(t, hooks, "StopFailure")
			delete(hooks, "StopFailure")
			b, err = json.Marshal(settings)
			require.NoError(t, err)
			require.NoError(t, os.WriteFile(file, b, 0o644))
		}},
		{"no settings file", func(t *testing.T, folder string, _ int64) {
			require.NoError(t, os.Remove(filepath.Join(folder, ".claude", "settings.local.json")))
		}},
		{"malformed settings", func(t *testing.T, folder string, _ int64) {
			require.NoError(t, os.WriteFile(filepath.Join(folder, ".claude", "settings.local.json"), []byte("{not json"), 0o644))
		}},
	} {
		for _, branch := range []string{"open", "merged"} {
			t.Run(tc.name+"/"+branch, func(t *testing.T) {
				database, pid, row := stopStateFixture(t, branch)
				tc.settings(t, mustFolder(t, database, pid), pid)
				id := strconv.FormatInt(pid, 10)
				payload := statePayload("Stop", briefLaunchID, "")
				unsetTerminalEnv(t)
				plain, plainErr := stopHookIO(t, id, payload)

				t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
				out, errOut := stopHookIO(t, id, payload)

				assert.Equal(t, plain, out, "stdout is byte-identical")
				assert.Equal(t, branch == "merged", out != "", "blocks only on drift")
				assert.Equal(t, plainErr, errOut)
				assert.Empty(t, errOut)
				assert.Empty(t, storedAgentState(t, database, row))
			})
		}
	}
	t.Run("gone workbench", func(t *testing.T) {
		database, pid, row := stopStateFixture(t, "open")
		t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
		for _, payload := range []string{
			statePayload("Stop", briefLaunchID, ""),
			`{"session_id":"` + briefLaunchID + `","hook_event_name":"Stop","stop_hook_active":true}`,
		} {
			out, errOut := stopHookIO(t, strconv.FormatInt(pid+100, 10), payload)

			assert.Empty(t, out)
			assert.Empty(t, errOut, "a deleted workbench's leftover hook says nothing")
			assert.Empty(t, storedAgentState(t, database, row))
		}
	})
	t.Run("continued turn", func(t *testing.T) {
		database, pid, row := stopStateFixture(t, "merged")
		_, err := devpack.RemoveStateHooks(mustFolder(t, database, pid), pid)
		require.NoError(t, err)
		t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))

		out, errOut := stopHookIO(t, strconv.FormatInt(pid, 10),
			`{"session_id":"`+briefLaunchID+`","hook_event_name":"Stop","stop_hook_active":true}`)

		assert.Empty(t, out)
		assert.Empty(t, errOut)
		assert.Empty(t, storedAgentState(t, database, row))
	})
}

func mustFolder(t *testing.T, database *db.DB, pid int64) string {
	t.Helper()
	wb, err := database.GetWorkbench(pid)
	require.NoError(t, err)
	return wb.FolderPath
}

// stopFailureFixture is a StopFailure hook input captured from Claude Code
// 2.1 (a turn against an API stub answering 429), with the paths and ids
// replaced by test values: the error type is the top-level "error" string.
func stopFailureFixture(t *testing.T) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "stopfailure_rate_limit.json"))
	require.NoError(t, err)
	return string(raw)
}

// stopFailureWith is the fixture with its "error" field replaced by errJSON,
// or removed when errJSON is empty.
func stopFailureWith(t *testing.T, errJSON string) string {
	t.Helper()
	var m map[string]json.RawMessage
	require.NoError(t, json.Unmarshal([]byte(stopFailureFixture(t)), &m))
	delete(m, "error")
	if errJSON != "" {
		m["error"] = json.RawMessage(errJSON)
	}
	out, err := json.Marshal(m)
	require.NoError(t, err)
	return string(out)
}

func storedFailure(t *testing.T, database *db.DB, rowID int64) (failure *db.AgentFailure, stateAt string) {
	t.Helper()
	s, err := database.GetTerminalSession(rowID)
	require.NoError(t, err)
	if !s.AgentStateAt.IsZero() {
		stateAt = s.AgentStateAt.UTC().Format("2006-01-02T15:04:05.000Z")
	}
	return s.AgentFailure, stateAt
}

// PROJ-11 (amended 2026-10-03), hook half: a StopFailure from working and
// from waiting stores the payload's error type with agent_failed_at =
// agent_state_at; a later plain waiting (idle_prompt ~60 s on, the Stop
// hook) keeps it; a repeated StopFailure keeps its time and one with another
// error replaces it; working and a permission prompt clear it; a missing or
// non-string error field stores ”; a long one is clipped to 60 runes on
// one line. The db half is in internal/db.
func TestProj11_StopFailureRecordsErrorOtherWritesClearIt(t *testing.T) {
	stopHookWaiting := func(t *testing.T, database *db.DB, pid, row int64) {
		// The Stop hook's write (writeStopAgentState) after its settings check.
		state, onlyFrom, _ := agentStateFor("Stop", "")
		require.NoError(t, recordAgentState(database, row, pid, briefLaunchID, state, onlyFrom, nil, false, hookNow(), hookTurn{}))
	}
	hookEvent := func(event, notification string) func(*testing.T, *db.DB, int64, int64) {
		return func(t *testing.T, _ *db.DB, pid, _ int64) {
			_, _, err := runSessionState(t, pid, strings.NewReader(statePayload(event, briefLaunchID, notification)))
			require.NoError(t, err)
		}
	}
	for _, tc := range []struct {
		name, from string
		next       func(t *testing.T, database *db.DB, pid, row int64)
		wantState  string
		kept       bool
	}{
		{"from working, idle_prompt keeps it", "UserPromptSubmit", hookEvent("Notification", "idle_prompt"), "waiting", true},
		{"from working, the Stop hook keeps it", "UserPromptSubmit", stopHookWaiting, "waiting", true},
		{"from waiting, a prompt clears it", "idle_prompt", hookEvent("UserPromptSubmit", ""), "working", false},
		{"from waiting, a permission prompt clears it", "idle_prompt", hookEvent("Notification", "permission_prompt"), "approval", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			database, pid, row := briefSessionFixture(t)
			t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
			stepClock(t)
			first := statePayload("UserPromptSubmit", briefLaunchID, "")
			if tc.from == "idle_prompt" {
				first = statePayload("Notification", briefLaunchID, "idle_prompt")
			}
			_, _, err := runSessionState(t, pid, strings.NewReader(first))
			require.NoError(t, err)

			out, errOut, err := runSessionState(t, pid, strings.NewReader(stopFailureFixture(t)))
			require.NoError(t, err)
			assert.Empty(t, out)
			assert.Empty(t, errOut)
			assert.Equal(t, "waiting", storedAgentState(t, database, row))
			failure, stateAt := storedFailure(t, database, row)
			require.NotNil(t, failure, "the StopFailure stored no error")
			want := db.AgentFailure{At: stateAt, Error: "rate_limit"}
			assert.Equal(t, want, *failure)

			tc.next(t, database, pid, row)
			assert.Equal(t, tc.wantState, storedAgentState(t, database, row))
			failure, afterAt := storedFailure(t, database, row)
			if tc.kept {
				require.NotNil(t, failure, "a plain waiting wiped the error")
				assert.Equal(t, want, *failure)
				assert.Equal(t, stateAt, afterAt, "a plain waiting moved the failed state's time")
				return
			}
			assert.Nil(t, failure, "a real state change kept the error")
		})
	}

	t.Run("a repeated StopFailure keeps its time, another error replaces it", func(t *testing.T) {
		database, pid, row := briefSessionFixture(t)
		t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
		stepClock(t)
		for _, payload := range []string{statePayload("UserPromptSubmit", briefLaunchID, ""),
			stopFailureFixture(t)} {
			_, _, err := runSessionState(t, pid, strings.NewReader(payload))
			require.NoError(t, err)
		}
		first, firstAt := storedFailure(t, database, row)
		require.NotNil(t, first)

		_, _, err := runSessionState(t, pid, strings.NewReader(stopFailureFixture(t)))
		require.NoError(t, err)
		again, againAt := storedFailure(t, database, row)
		require.NotNil(t, again)
		assert.Equal(t, *first, *again, "a repeated StopFailure rewrote the error")
		assert.Equal(t, firstAt, againAt, "a repeated StopFailure moved the time")

		_, _, err = runSessionState(t, pid, strings.NewReader(stopFailureWith(t, `"overloaded"`)))
		require.NoError(t, err)
		assert.Equal(t, "waiting", storedAgentState(t, database, row))
		other, otherAt := storedFailure(t, database, row)
		require.NotNil(t, other)
		assert.Equal(t, db.AgentFailure{At: otherAt, Error: "overloaded"}, *other)
		assert.Greater(t, otherAt, firstAt, "another error kept the first failure's time")
	})

	for _, tc := range []struct {
		name, errJSON, want string
	}{
		{"no error field", "", ""},
		{"a non-string error field", `{"type":"rate_limit"}`, ""},
		{"a null error field", `null`, ""},
		{"a long error on two lines", `"` + strings.Repeat("é", 100) + `\n` + strings.Repeat("x", 100) + `"`,
			strings.Repeat("é", 59) + "…"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			database, pid, row := briefSessionFixture(t)
			t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
			stepClock(t)
			out, errOut, err := runSessionState(t, pid, strings.NewReader(stopFailureWith(t, tc.errJSON)))
			require.NoError(t, err)
			assert.Empty(t, out)
			assert.Empty(t, errOut)
			failure, _ := storedFailure(t, database, row)
			require.NotNil(t, failure, "a StopFailure without a usable error type still flags the error")
			assert.Equal(t, tc.want, failure.Error)
			assert.LessOrEqual(t, len([]rune(failure.Error)), 60)
		})
	}
}

// PROJ-11, hook half: finish_session written mid-turn, an Esc interrupt (no
// hook) and a new prompt — the prompt's `working` over the stored `working`
// is not skipped by the read-first check while finished_at is set.
func TestProj11_WorkingOverWorkingClearsFinished(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	stepClock(t)
	prompt := statePayload("UserPromptSubmit", briefLaunchID, "")
	_, _, err := runSessionState(t, pid, strings.NewReader(prompt))
	require.NoError(t, err)
	require.NoError(t, database.FinishTerminalSession(row, "Done.", time.Now()))

	_, _, err = runSessionState(t, pid, strings.NewReader(prompt))
	require.NoError(t, err)
	assert.Equal(t, "working", storedAgentState(t, database, row))
	var finished sql.NullString
	var summary string
	require.NoError(t, database.QueryRow(`SELECT finished_at, finish_summary FROM terminal_sessions WHERE id = ?`, row).
		Scan(&finished, &summary))
	assert.False(t, finished.Valid, "a new prompt over a finished working kept finished_at")
	assert.Equal(t, "Done.", summary)
}

func storedFinishedAt(t *testing.T, database *db.DB, rowID int64) sql.NullString {
	t.Helper()
	var finished sql.NullString
	require.NoError(t, database.QueryRow(`SELECT finished_at FROM terminal_sessions WHERE id = ?`, rowID).Scan(&finished))
	return finished
}

// PROJ-11: a PostToolUse over a stored `working` never clears finished_at —
// finish_session's own PostToolUse is part of the turn that finished. Pinned
// at the hook and at its precheck with no onlyFrom (a main-thread
// PostToolUse that records working from any state).
func TestProj11_PostToolUseOverWorkingKeepsFinished(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	stepClock(t)
	_, _, err := runSessionState(t, pid, strings.NewReader(statePayload("UserPromptSubmit", briefLaunchID, "")))
	require.NoError(t, err)
	require.NoError(t, database.FinishTerminalSession(row, "Done.", time.Now()))

	_, _, err = runSessionState(t, pid, strings.NewReader(statePayload("PostToolUse", briefLaunchID, "")))
	require.NoError(t, err)
	assert.True(t, storedFinishedAt(t, database, row).Valid, "finish_session's PostToolUse cleared finished_at")

	require.NoError(t, recordAgentState(database, row, pid, briefLaunchID, agentStateWorking, "", nil, false, hookNow(), hookTurn{}))
	assert.True(t, storedFinishedAt(t, database, row).Valid, "a tool run's working over working cleared finished_at")
	assert.Equal(t, "working", storedAgentState(t, database, row))
}

// rowSnapshot is every column of terminal_sessions row rowID, by name.
func rowSnapshot(t *testing.T, database *db.DB, rowID int64) map[string]any {
	t.Helper()
	rows, err := database.Query(`SELECT * FROM terminal_sessions WHERE id = ?`, rowID)
	require.NoError(t, err)
	defer rows.Close()
	cols, err := rows.Columns()
	require.NoError(t, err)
	require.True(t, rows.Next(), "row %d is gone", rowID)
	values := make([]any, len(cols))
	ptrs := make([]any, len(cols))
	for i := range values {
		ptrs[i] = &values[i]
	}
	require.NoError(t, rows.Scan(ptrs...))
	require.NoError(t, rows.Err())
	snap := make(map[string]any, len(cols))
	for i, c := range cols {
		snap[c] = values[i]
	}
	return snap
}

// subagentToolResult is a PostToolUse a background subagent of session
// sessionID fired.
func subagentToolResult(sessionID string) string {
	return `{"session_id":"` + sessionID + `","hook_event_name":"PostToolUse","agent_id":"a1b2c3","agent_type":"general-purpose"}`
}

// PROJ-11: a tool run that moves the state into `working` is a new turn and
// clears finished_at: a main-thread PostToolUse out of approval or out of
// waiting (after the Stop hook), through the hook. A subagent's PostToolUse
// over waiting never ends it and keeps finished_at: with no background
// count it writes nothing at all; over the Stop's count (board #411) it
// changes only agent_background_at (a heartbeat).
func TestProj11_PostToolUseIntoWorkingClearsFinished(t *testing.T) {
	for _, from := range []string{"approval", "waiting", "waiting with background agents"} {
		var database *db.DB
		var pid, row int64
		if from == "waiting with background agents" {
			database, pid, row = stopStateFixture(t, "open")
		} else {
			database, pid, row = briefSessionFixture(t)
		}
		t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
		stepClock(t)
		_, _, err := runSessionState(t, pid, strings.NewReader(statePayload("UserPromptSubmit", briefLaunchID, "")))
		require.NoError(t, err)
		require.NoError(t, database.FinishTerminalSession(row, "Done.", time.Now()))
		switch from {
		case "approval":
			_, _, err = runSessionState(t, pid, strings.NewReader(statePayload("Notification", briefLaunchID, "permission_prompt")))
			require.NoError(t, err)
			require.Equal(t, "approval", storedAgentState(t, database, row))
			_, _, err = runSessionState(t, pid, strings.NewReader(statePayload("PostToolUse", briefLaunchID, "")))
			require.NoError(t, err)
		case "waiting":
			_, _, err = runSessionState(t, pid, strings.NewReader(statePayload("Stop", briefLaunchID, "")))
			require.NoError(t, err)
			require.Equal(t, "waiting", storedAgentState(t, database, row))
			before := rowSnapshot(t, database, row)
			_, _, err = runSessionState(t, pid, strings.NewReader(subagentToolResult(briefLaunchID)))
			require.NoError(t, err)
			require.Equal(t, before, rowSnapshot(t, database, row), "a subagent's tool result over waiting without a count wrote")
			require.True(t, storedFinishedAt(t, database, row).Valid, "a subagent's tool result cleared finished_at")
			_, _, err = runSessionState(t, pid, strings.NewReader(statePayload("PostToolUse", briefLaunchID, "")))
			require.NoError(t, err)
		default:
			// `workbench session-state` records no count for a Stop: only the
			// sync Stop hook does.
			out, errOut := stopHookIO(t, strconv.FormatInt(pid, 10),
				stopWithBackground(`[{"id":"a","type":"subagent"},{"id":"b","type":"subagent"}]`))
			require.Empty(t, out)
			require.Empty(t, errOut)
			before := rowSnapshot(t, database, row)
			require.Equal(t, "waiting", before["agent_state"])
			require.Equal(t, int64(2), before["agent_background"])
			_, _, err = runSessionState(t, pid, strings.NewReader(subagentToolResult(briefLaunchID)))
			require.NoError(t, err)
			after := rowSnapshot(t, database, row)
			require.NotEqual(t, before["agent_background_at"], after["agent_background_at"], "the heartbeat did not stamp the report")
			delete(before, "agent_background_at")
			delete(after, "agent_background_at")
			require.Equal(t, before, after, "a subagent's heartbeat changed more than agent_background_at")
			require.True(t, storedFinishedAt(t, database, row).Valid, "a subagent's tool result cleared finished_at")
			_, _, err = runSessionState(t, pid, strings.NewReader(statePayload("PostToolUse", briefLaunchID, "")))
			require.NoError(t, err)
		}
		assert.Equal(t, "working", storedAgentState(t, database, row), from)
		assert.False(t, storedFinishedAt(t, database, row).Valid, "a tool run out of %s kept finished_at", from)
		s, err := database.GetTerminalSession(row)
		require.NoError(t, err)
		assert.False(t, s.Background.Valid, "a main-thread tool run out of %s kept the count", from)
		assert.True(t, s.BackgroundAt.IsZero(), "a main-thread tool run out of %s kept the report time", from)
	}
}

// toolResultPayload is a main-thread PostToolUse of call id, its transcript
// at path.
func toolResultPayload(id, path string) string {
	return `{"session_id":"` + briefLaunchID + `","transcript_path":"` + path + `","hook_event_name":"PostToolUse",` +
		`"tool_name":"Bash","tool_use_id":"` + id + `","tool_response":{"stdout":"a.txt"}}`
}

func stopPayload(path string) string {
	return `{"session_id":"` + briefLaunchID + `","transcript_path":"` + path + `","hook_event_name":"Stop","stop_hook_active":false}`
}

// PROJ-11, board #368: events are ordered by the turn they belong to, not by
// when their hook processes started. The ended turn's tool result whose
// async hook starts after the sync Stop hook leaves "waiting" alone; a turn
// started without a prompt still turns it into "working" with its first
// tool result (board #367).
func TestProj11_EndedTurnsToolResultNeverOverwritesTheStop(t *testing.T) {
	database, pid, row := stopStateFixture(t, "open")
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	base := time.Now()
	orig := hookNow
	t.Cleanup(func() { hookNow = orig })
	at := func(sec int) { hookNow = func() time.Time { return base.Add(time.Duration(sec) * time.Second) } }
	record := func(payload string) {
		t.Helper()
		_, _, err := runSessionState(t, pid, strings.NewReader(payload))
		require.NoError(t, err)
	}
	transcript := writeTranscript(t, transcriptPrompt("go"), transcriptToolUse("toolu_A"), transcriptToolResult("toolu_A"),
		transcriptReply("done"))

	at(1)
	record(statePayload("UserPromptSubmit", briefLaunchID, ""))
	at(2)
	out, errOut := stopHookIO(t, strconv.FormatInt(pid, 10), stopPayload(transcript))
	require.Empty(t, out)
	require.Empty(t, errOut)
	require.Equal(t, "waiting", storedAgentState(t, database, row))

	at(3)
	record(toolResultPayload("toolu_A", transcript))
	assert.Equal(t, "waiting", storedAgentState(t, database, row), "the ended turn's tool result, its hook started after the Stop's")

	appendTranscript(t, transcript, transcriptToolUse("toolu_B"), transcriptToolResult("toolu_B"))
	at(4)
	record(toolResultPayload("toolu_B", transcript))
	assert.Equal(t, "working", storedAgentState(t, database, row), "a self-started turn's first tool result")
}

// PROJ-11, board #368: the other interleaving — the ended turn's tool result
// lands first (out of a granted permission) with a later stamp than the
// Stop hook's start; the Stop still records "waiting". A prompt's or a
// subagent's `working` stamped after the Stop keeps the time order (owner
// decision, ask #20: a granted subagent shows working).
func TestProj11_StopReplacesItsTurnsLateToolResult(t *testing.T) {
	orig := hookNow
	t.Cleanup(func() { hookNow = orig })
	for _, tc := range []struct {
		name, payload, want string
	}{
		{"the main thread's tool result", toolResultPayload("toolu_A", ""), "waiting"},
		{"a subagent's tool result", `{"session_id":"` + briefLaunchID + `","hook_event_name":"PostToolUse","agent_id":"a1b2c3"}`, "working"},
	} {
		database, pid, row := stopStateFixture(t, "open")
		t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
		base := time.Now()
		at := func(sec int) { hookNow = func() time.Time { return base.Add(time.Duration(sec) * time.Second) } }
		transcript := writeTranscript(t, transcriptToolUse("toolu_A"), transcriptToolResult("toolu_A"), transcriptReply("done"))

		at(1)
		_, _, err := runSessionState(t, pid, strings.NewReader(statePayload("Notification", briefLaunchID, "permission_prompt")))
		require.NoError(t, err)
		at(3)
		_, _, err = runSessionState(t, pid, strings.NewReader(tc.payload))
		require.NoError(t, err)
		require.Equal(t, "working", storedAgentState(t, database, row), tc.name)
		at(2)
		_, errOut := stopHookIO(t, strconv.FormatInt(pid, 10), stopPayload(transcript))
		require.Empty(t, errOut)

		assert.Equal(t, tc.want, storedAgentState(t, database, row), tc.name)
		s, err := database.GetTerminalSession(row)
		require.NoError(t, err)
		assert.Equal(t, base.Add(3*time.Second).UTC().Truncate(time.Millisecond), s.AgentStateAt.UTC(), "%s: the stored time never goes back", tc.name)
	}
}

// A turn without a prompt over a stored "waiting": the Stop's state write
// is a repeat, but it still records the turn end, so that turn's late tool
// result writes nothing.
func TestSessionState_StopRecordsTheTurnEndOverWaiting(t *testing.T) {
	database, pid, row := stopStateFixture(t, "open")
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	stepClock(t)
	transcript := writeTranscript(t, transcriptPrompt("go"), transcriptReply("done"))
	_, errOut := stopHookIO(t, strconv.FormatInt(pid, 10), stopPayload(transcript))
	require.Empty(t, errOut)
	require.Equal(t, "waiting", storedAgentState(t, database, row))

	appendTranscript(t, transcript, transcriptToolUse("toolu_A"), transcriptToolResult("toolu_A"), transcriptReply("again"))
	_, errOut = stopHookIO(t, strconv.FormatInt(pid, 10), stopPayload(transcript))
	require.Empty(t, errOut)
	_, _, err := runSessionState(t, pid, strings.NewReader(toolResultPayload("toolu_A", transcript)))
	require.NoError(t, err)

	assert.Equal(t, "waiting", storedAgentState(t, database, row))
	s, err := database.GetTerminalSession(row)
	require.NoError(t, err)
	size, _ := transcriptSize(transcript)
	assert.Equal(t, size, s.TurnEnd.Int64)
}

// The turn end only orders late tool results: a Stop whose turn-end write
// fails still records "waiting", and says on stderr what it lost.
func TestSessionState_StopRecordsWaitingWhenTheTurnEndFails(t *testing.T) {
	database, pid, row := stopStateFixture(t, "open")
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	stepClock(t)
	_, _, err := runSessionState(t, pid, strings.NewReader(statePayload("UserPromptSubmit", briefLaunchID, "")))
	require.NoError(t, err)
	require.Equal(t, "working", storedAgentState(t, database, row))
	orig := setTerminalTurnEnd
	t.Cleanup(func() { setTerminalTurnEnd = orig })
	setTerminalTurnEnd = func(*db.DB, int64, int64, string, int64) (bool, error) {
		return false, errors.New("database is locked")
	}
	transcript := writeTranscript(t, transcriptPrompt("go"), transcriptReply("done"))

	out, errOut := stopHookIO(t, strconv.FormatInt(pid, 10), stopPayload(transcript))

	assert.Empty(t, out)
	assert.Equal(t, "watchtower: turn end not recorded: database is locked\n", errOut)
	assert.Equal(t, "waiting", storedAgentState(t, database, row))
	s, err := database.GetTerminalSession(row)
	require.NoError(t, err)
	assert.False(t, s.TurnEnd.Valid)
}

// A Stop the drift check blocks continues the turn: it records the turn end
// it marked before the check (the continued turn's calls come after it),
// and no "waiting".
func TestSessionState_BlockedStopRecordsTheTurnEndButNoWaiting(t *testing.T) {
	database, pid, row := stopStateFixture(t, "merged")
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	stepClock(t)
	_, _, err := runSessionState(t, pid, strings.NewReader(statePayload("UserPromptSubmit", briefLaunchID, "")))
	require.NoError(t, err)
	transcript := writeTranscript(t, transcriptPrompt("go"), transcriptReply("done"))

	out, _ := stopHookIO(t, strconv.FormatInt(pid, 10), stopPayload(transcript))

	require.NotEmpty(t, out, "the drift blocks the stop")
	assert.Equal(t, "working", storedAgentState(t, database, row))
	s, err := database.GetTerminalSession(row)
	require.NoError(t, err)
	size, _ := transcriptSize(transcript)
	assert.Equal(t, size, s.TurnEnd.Int64)
}

// A Stop the drift check blocks has no state write to report a failed turn
// end for it: the mark before the check says so on stderr itself.
func TestSessionState_BlockedStopReportsAFailedTurnEnd(t *testing.T) {
	_, pid, row := stopStateFixture(t, "merged")
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	orig := setTerminalTurnEnd
	t.Cleanup(func() { setTerminalTurnEnd = orig })
	setTerminalTurnEnd = func(*db.DB, int64, int64, string, int64) (bool, error) {
		return false, errors.New("database is locked")
	}
	transcript := writeTranscript(t, transcriptPrompt("go"), transcriptReply("done"))

	out, errOut := stopHookIO(t, strconv.FormatInt(pid, 10), stopPayload(transcript))

	require.NotEmpty(t, out, "the drift blocks the stop")
	assert.Equal(t, "watchtower: turn end not recorded: database is locked\n", errOut)
}

// A tool result the transcript cannot place (no tool_use_id, an unreadable
// transcript) falls back to the time order: after the Stop, "working".
func TestSessionState_UnplacedToolResultFallsBackToTime(t *testing.T) {
	for _, payload := range []string{
		statePayload("PostToolUse", briefLaunchID, ""),
		toolResultPayload("toolu_A", filepath.Join(os.TempDir(), "no-such-transcript.jsonl")),
	} {
		database, pid, row := stopStateFixture(t, "open")
		t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
		stepClock(t)
		transcript := writeTranscript(t, transcriptToolUse("toolu_A"), transcriptToolResult("toolu_A"), transcriptReply("done"))
		_, errOut := stopHookIO(t, strconv.FormatInt(pid, 10), stopPayload(transcript))
		require.Empty(t, errOut)

		_, _, err := runSessionState(t, pid, strings.NewReader(payload))
		require.NoError(t, err)
		assert.Equal(t, "working", storedAgentState(t, database, row), payload)
	}
}

// A folder without the state hooks gets no turn end either, not even the
// one recorded before the drift check (nothing would read it; the sync Stop
// hook must not take the write lock for it).
func TestSessionState_StopHookWithoutStateHooksRecordsNoTurnEnd(t *testing.T) {
	for _, branch := range []string{"open", "merged"} {
		database, pid, row := stopStateFixture(t, branch)
		_, err := devpack.RemoveStateHooks(mustFolder(t, database, pid), pid)
		require.NoError(t, err)
		t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
		transcript := writeTranscript(t, transcriptPrompt("go"), transcriptReply("done"))

		_, errOut := stopHookIO(t, strconv.FormatInt(pid, 10), stopPayload(transcript))
		require.Empty(t, errOut)
		s, err := database.GetTerminalSession(row)
		require.NoError(t, err)
		assert.False(t, s.TurnEnd.Valid, branch)
	}
}

// Board #368: a conversation switch (/clear, a fork) starts a new transcript,
// so the old one's turn end goes with the old id: the new conversation's
// first tool result after a granted permission records "working" even when
// its call sits at an offset below the old turn end.
func TestSessionState_ConversationSwitchDropsTheTurnEnd(t *testing.T) {
	const newID = "22222222-3333-4444-8555-666666666666"
	database, pid, row := stopStateFixture(t, "open")
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	stepClock(t)
	old := writeTranscript(t, transcriptPrompt("go"), transcriptToolUse("toolu_OLD"), transcriptToolResult("toolu_OLD"),
		transcriptReply("done"))
	_, errOut := stopHookIO(t, strconv.FormatInt(pid, 10), stopPayload(old))
	require.Empty(t, errOut)
	oldEnd, _ := transcriptSize(old)
	s, err := database.GetTerminalSession(row)
	require.NoError(t, err)
	require.Equal(t, oldEnd, s.TurnEnd.Int64)

	moved, err := database.SetTerminalClaudeSessionID(row, pid, newID)
	require.NoError(t, err)
	require.True(t, moved)
	fresh := writeTranscript(t, transcriptToolUse("toolu_NEW"), transcriptToolResult("toolu_NEW"),
		transcriptReply(strings.Repeat("x", int(oldEnd))))
	_, _, err = runSessionState(t, pid, strings.NewReader(`{"session_id":"`+newID+`","hook_event_name":"Notification","notification_type":"permission_prompt"}`))
	require.NoError(t, err)
	require.Equal(t, "approval", storedAgentState(t, database, row))

	_, _, err = runSessionState(t, pid, strings.NewReader(`{"session_id":"`+newID+`","transcript_path":"`+fresh+
		`","hook_event_name":"PostToolUse","tool_use_id":"toolu_NEW"}`))
	require.NoError(t, err)
	assert.Equal(t, "working", storedAgentState(t, database, row))
}

// stopWithBackground is the Stop hook input of briefLaunchID with field as
// its raw background_tasks value ("" leaves the key out).
func stopWithBackground(field string) string {
	s := `{"session_id":"` + briefLaunchID + `","transcript_path":"/tmp/x.jsonl","hook_event_name":"Stop","stop_hook_active":false`
	if field != "" {
		s += `,"background_tasks":` + field
	}
	return s + `}`
}

// hookClock sets the hook clock to base + sec seconds on each call.
func hookClock(t *testing.T) (base time.Time, at func(sec int)) {
	t.Helper()
	base = time.Now()
	orig := hookNow
	t.Cleanup(func() { hookNow = orig })
	return base, func(sec int) { hookNow = func() time.Time { return base.Add(time.Duration(sec) * time.Second) } }
}

// PROJ-11, board #411: the Stop stores how many background subagents and
// workflows its input lists, stamped with the state's own time; none, an
// absent field or a malformed one stores NULL.
func TestProj11_StopRecordsBackgroundSubagents(t *testing.T) {
	captured, err := os.ReadFile("testdata/stop_background_tasks.json")
	require.NoError(t, err)
	capturedInput := strings.ReplaceAll(string(captured), "00000000-0000-4000-8000-000000000411", briefLaunchID)
	for _, tc := range []struct {
		name, input string
		want        sql.NullInt64
	}{
		{"subagents, a shell and a teammate", stopWithBackground(`[{"id":"a","type":"subagent"},{"id":"b","type":"subagent"},
			{"id":"s","type":"shell"},{"id":"t","type":"teammate"}]`), sql.NullInt64{Int64: 2, Valid: true}},
		{"the captured input", capturedInput, sql.NullInt64{Int64: 2, Valid: true}},
		{"a workflow", stopWithBackground(`[{"id":"w","type":"workflow"}]`), sql.NullInt64{Int64: 1, Valid: true}},
		{"empty", stopWithBackground(`[]`), sql.NullInt64{}},
		{"absent", stopWithBackground(""), sql.NullInt64{}},
		{"malformed entries ignored", stopWithBackground(`[{"id":"a","type":"subagent"},1,"subagent",{"type":7}]`),
			sql.NullInt64{Int64: 1, Valid: true}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			database, pid, row := stopStateFixture(t, "open")
			t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))

			out, errOut := stopHookIO(t, strconv.FormatInt(pid, 10), tc.input)

			assert.Empty(t, out)
			assert.Empty(t, errOut)
			s, err := database.GetTerminalSession(row)
			require.NoError(t, err)
			assert.Equal(t, "waiting", s.AgentState.String)
			assert.Equal(t, tc.want, s.Background)
			if tc.want.Valid {
				assert.Equal(t, s.AgentStateAt, s.BackgroundAt, "the count is stamped with the Stop's time")
			} else {
				assert.True(t, s.BackgroundAt.IsZero())
			}
		})
	}
}

// PROJ-11, board #411 (Review Focus 2): a background_tasks that is no array,
// or whose entries are all malformed, never costs the Stop its "waiting".
func TestProj11_MalformedBackgroundTasksStillRecordWaiting(t *testing.T) {
	for _, field := range []string{`{"x":1}`, `[1, "a", {"type": 7}]`, `"subagent"`, `null`} {
		t.Run(field, func(t *testing.T) {
			database, pid, row := stopStateFixture(t, "open")
			t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))

			out, errOut := stopHookIO(t, strconv.FormatInt(pid, 10), stopWithBackground(field))

			assert.Empty(t, out)
			assert.Empty(t, errOut)
			s, err := database.GetTerminalSession(row)
			require.NoError(t, err)
			assert.Equal(t, "waiting", s.AgentState.String)
			assert.False(t, s.Background.Valid)
		})
	}
}

// PROJ-11, board #411: a Stop over a stored "waiting" whose count differs is
// a new transition: it writes and advances agent_state_at.
func TestProj11_StopOverWaitingWithAnotherCountWrites(t *testing.T) {
	database, pid, row := stopStateFixture(t, "open")
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	base, at := hookClock(t)
	stamp := func(sec int) time.Time {
		return base.Add(time.Duration(sec) * time.Second).UTC().Truncate(time.Millisecond)
	}
	stop := func(sec int, field string) *db.TerminalSession {
		t.Helper()
		at(sec)
		out, errOut := stopHookIO(t, strconv.FormatInt(pid, 10), stopWithBackground(field))
		require.Empty(t, out)
		require.Empty(t, errOut)
		s, err := database.GetTerminalSession(row)
		require.NoError(t, err)
		return s
	}

	s := stop(1, `[{"id":"a","type":"subagent"},{"id":"b","type":"subagent"}]`)
	require.Equal(t, int64(2), s.Background.Int64)

	s = stop(2, `[{"id":"b","type":"subagent"}]`)
	assert.Equal(t, sql.NullInt64{Int64: 1, Valid: true}, s.Background)
	assert.Equal(t, stamp(2), s.AgentStateAt.UTC())
	assert.Equal(t, stamp(2), s.BackgroundAt.UTC())

	s = stop(3, `[]`)
	assert.Equal(t, "waiting", s.AgentState.String)
	assert.False(t, s.Background.Valid)
	assert.True(t, s.BackgroundAt.IsZero())
	assert.Equal(t, stamp(3), s.AgentStateAt.UTC(), "the last subagent gone is a new transition too")
}

// PROJ-11, board #411 (Review Focus 3): a Stop repeating the same non-zero
// count is a state repeat but a fresh report: agent_state_at keeps the first
// Stop's time, agent_background_at takes the second's.
func TestProj11_StopWithTheSameCountRefreshesTheReportTime(t *testing.T) {
	database, pid, row := stopStateFixture(t, "open")
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	base, at := hookClock(t)
	two := `[{"id":"a","type":"subagent"},{"id":"b","type":"subagent"}]`

	at(1)
	_, errOut := stopHookIO(t, strconv.FormatInt(pid, 10), stopWithBackground(two))
	require.Empty(t, errOut)
	at(2)
	out, errOut := stopHookIO(t, strconv.FormatInt(pid, 10), stopWithBackground(two))

	assert.Empty(t, out)
	assert.Empty(t, errOut)
	s, err := database.GetTerminalSession(row)
	require.NoError(t, err)
	assert.Equal(t, sql.NullInt64{Int64: 2, Valid: true}, s.Background)
	assert.Equal(t, base.Add(time.Second).UTC().Truncate(time.Millisecond), s.AgentStateAt.UTC(), "a repeat keeps the transition time")
	assert.Equal(t, base.Add(2*time.Second).UTC().Truncate(time.Millisecond), s.BackgroundAt.UTC(), "the report time is the second Stop's")
}

// subagentStop is a SubagentStop of briefLaunchID's subagent agentID of type
// agentType, field its raw background_tasks value ("" leaves the key out).
func subagentStop(agentID, agentType, field string) string {
	s := `{"session_id":"` + briefLaunchID + `","hook_event_name":"SubagentStop","stop_hook_active":false,` +
		`"agent_id":"` + agentID + `","agent_type":"` + agentType + `"`
	if field != "" {
		s += `,"background_tasks":` + field
	}
	return s + `}`
}

// subagents is a background_tasks array of running subagents with ids.
func subagents(ids ...string) string {
	entries := make([]string, len(ids))
	for i, id := range ids {
		entries[i] = `{"id":"` + id + `","type":"subagent","status":"running"}`
	}
	return "[" + strings.Join(entries, ",") + "]"
}

// countedWaiting runs the sync Stop hook at second sec of the hook clock
// with field as its background_tasks, and requires the `waiting` it stores.
func countedWaiting(t *testing.T, database *db.DB, pid, row int64, at func(int), sec int, field string) {
	t.Helper()
	at(sec)
	out, errOut := stopHookIO(t, strconv.FormatInt(pid, 10), stopWithBackground(field))
	require.Empty(t, out)
	require.Empty(t, errOut)
	require.Equal(t, "waiting", storedAgentState(t, database, row))
}

// PROJ-11, board #411 (hook half): only the Stop hook raises the count from
// NULL. Over a `waiting` without one, a late subagent tool result, a
// SubagentStop listing subagents, the idle notice and a Stop reaching
// `workbench session-state` (not installed there) all leave it NULL.
func TestProj11_OnlyTheStopStartsBackground(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	stepClock(t)
	_, _, err := runSessionState(t, pid, strings.NewReader(statePayload("UserPromptSubmit", briefLaunchID, "")))
	require.NoError(t, err)

	for _, p := range []string{
		stopWithBackground(subagents("a", "b")),
		subagentToolResult(briefLaunchID),
		subagentStop("x", "general-purpose", subagents("x", "a", "b", "c")),
		statePayload("Notification", briefLaunchID, "idle_prompt"),
	} {
		out, errOut, err := runSessionState(t, pid, strings.NewReader(p))
		require.NoError(t, err)
		assert.Empty(t, out)
		assert.Empty(t, errOut)
		s, err := database.GetTerminalSession(row)
		require.NoError(t, err)
		assert.Equal(t, "waiting", s.AgentState.String, "after %s", p)
		assert.False(t, s.Background.Valid, "after %s", p)
		assert.True(t, s.BackgroundAt.IsZero(), "after %s", p)
	}
}

// PROJ-11, board #411: a SubagentStop only lowers the Stop's count, to the
// subagents its own snapshot still lists besides itself — never raising it,
// never over another state, never from an older report, ignoring an
// internal agent (empty agent_type) and a missing or malformed list — and
// never touches the state, its time or finished_at.
func TestProj11_SubagentStopOnlyLowersTheCount(t *testing.T) {
	database, pid, row := stopStateFixture(t, "open")
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	base, at := hookClock(t)
	stamp := func(sec int) time.Time {
		return base.Add(time.Duration(sec) * time.Second).UTC().Truncate(time.Millisecond)
	}
	captured, err := os.ReadFile("testdata/subagentstop_background_tasks.json")
	require.NoError(t, err)
	capturedInput := strings.ReplaceAll(string(captured), "00000000-0000-4000-8000-000000000411", briefLaunchID)

	countedWaiting(t, database, pid, row, at, 1, subagents("a", "b", "c"))
	require.NoError(t, database.FinishTerminalSession(row, "Done.", time.Now()))
	finished := storedFinishedAt(t, database, row)
	require.True(t, finished.Valid)

	for _, step := range []struct {
		name, input string
		sec         int
		want        int64
		wantAt      int
	}{
		{"its own id and two others", subagentStop("a", "general-purpose", subagents("a", "b", "c")), 2, 2, 2},
		{"a longer list never raises", subagentStop("x", "general-purpose", subagents("x", "b", "c", "d", "e")), 3, 2, 3},
		{"an internal agent", subagentStop("b", "", "[]"), 4, 2, 3},
		{"no list", subagentStop("b", "general-purpose", ""), 5, 2, 3},
		{"a null list", subagentStop("b", "general-purpose", "null"), 6, 2, 3},
		{"an object list", subagentStop("b", "general-purpose", `{"b":1}`), 7, 2, 3},
		{"an older report", subagentStop("b", "general-purpose", "[]"), 2, 2, 3},
		{"the captured input", capturedInput, 8, 1, 8},
	} {
		at(step.sec)
		out, errOut, err := runSessionState(t, pid, strings.NewReader(step.input))
		require.NoError(t, err)
		assert.Empty(t, out, step.name)
		assert.Empty(t, errOut, step.name)
		s, err := database.GetTerminalSession(row)
		require.NoError(t, err)
		assert.Equal(t, sql.NullInt64{Int64: step.want, Valid: true}, s.Background, step.name)
		assert.Equal(t, stamp(step.wantAt), s.BackgroundAt.UTC(), step.name)
		assert.Equal(t, "waiting", s.AgentState.String, step.name)
		assert.Equal(t, stamp(1), s.AgentStateAt.UTC(), step.name)
		assert.Equal(t, finished, storedFinishedAt(t, database, row), step.name)
	}

	// Over `working`: nothing.
	at(9)
	_, _, err = runSessionState(t, pid, strings.NewReader(statePayload("UserPromptSubmit", briefLaunchID, "")))
	require.NoError(t, err)
	before := rowSnapshot(t, database, row)
	at(10)
	_, errOut, err := runSessionState(t, pid, strings.NewReader(subagentStop("b", "general-purpose", "[]")))
	require.NoError(t, err)
	assert.Empty(t, errOut)
	assert.Equal(t, before, rowSnapshot(t, database, row), "a SubagentStop over working wrote")
}

// PROJ-11, board #411 (hook half): from a counted `waiting`, a main turn
// (UserPromptSubmit, a main-thread PostToolUse), a StopFailure and the idle
// notice NULL the count and its report time; a permission prompt keeps them.
func TestProj11_MainTurnAndIdleNoticeClearTheCount(t *testing.T) {
	for _, tc := range []struct {
		name, input string
		keeps       bool
	}{
		{"UserPromptSubmit", statePayload("UserPromptSubmit", briefLaunchID, ""), false},
		{"main PostToolUse", statePayload("PostToolUse", briefLaunchID, ""), false},
		{"StopFailure", stopFailureWith(t, `"rate_limit"`), false},
		{"idle_prompt", statePayload("Notification", briefLaunchID, "idle_prompt"), false},
		{"permission_prompt", statePayload("Notification", briefLaunchID, "permission_prompt"), true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			database, pid, row := stopStateFixture(t, "open")
			t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
			_, at := hookClock(t)
			countedWaiting(t, database, pid, row, at, 1, subagents("a", "b"))
			counted, err := database.GetTerminalSession(row)
			require.NoError(t, err)
			require.True(t, counted.Background.Valid)

			at(2)
			out, errOut, err := runSessionState(t, pid, strings.NewReader(tc.input))
			require.NoError(t, err)
			assert.Empty(t, out)
			assert.Empty(t, errOut)
			s, err := database.GetTerminalSession(row)
			require.NoError(t, err)
			if tc.keeps {
				assert.Equal(t, "approval", s.AgentState.String)
				assert.Equal(t, counted.Background, s.Background)
				assert.Equal(t, counted.BackgroundAt, s.BackgroundAt)
			} else {
				assert.False(t, s.Background.Valid)
				assert.True(t, s.BackgroundAt.IsZero())
			}
		})
	}
}

// dropHookEvent deletes hooks.<event> from folder's settings file, leaving
// the folder as an install from before that event's entry left it.
func dropHookEvent(t *testing.T, folder, event string) {
	t.Helper()
	file := filepath.Join(folder, ".claude", "settings.local.json")
	b, err := os.ReadFile(file)
	require.NoError(t, err)
	var settings map[string]any
	require.NoError(t, json.Unmarshal(b, &settings))
	hooks := settings["hooks"].(map[string]any)
	require.Contains(t, hooks, event)
	delete(hooks, event)
	b, err = json.Marshal(settings)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(file, b, 0o644))
}

// PROJ-11, board #411: a folder installed before the SubagentStop entry (the
// four older state hooks only) keeps its Stop "waiting" and its run mark
// until the owner repairs it, while the status the Desktop reads reports
// state_hooks false, so the Desktop offers that repair.
func TestProj11_StopStateWriteNeedsOnlyTheCoreHooks(t *testing.T) {
	t.Run("the Stop records waiting", func(t *testing.T) {
		database, pid, row := stopStateFixture(t, "open")
		dropHookEvent(t, mustFolder(t, database, pid), "SubagentStop")
		t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))

		out, errOut := stopHookIO(t, strconv.FormatInt(pid, 10), statePayload("Stop", briefLaunchID, ""))

		assert.Empty(t, out)
		assert.Empty(t, errOut)
		assert.Equal(t, "waiting", storedAgentState(t, database, row))
	})
	t.Run("a new run is marked", func(t *testing.T) {
		database, pid, row := briefSessionFixture(t)
		installBriefStateHooks(t, database, pid)
		dropHookEvent(t, mustFolder(t, database, pid), "SubagentStop")
		t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
		start := time.Now().UTC().Truncate(time.Millisecond)

		_, errOut := runBriefHook(t, pid, hookPayload("startup", briefLaunchID))

		assert.Empty(t, errOut)
		s, err := database.GetTerminalSession(row)
		require.NoError(t, err)
		assert.False(t, s.AgentState.Valid, "a mark is no state")
		assert.False(t, s.AgentStateAt.Before(start), "stamped during this run: %v", s.AgentStateAt)
	})
	t.Run("the status reports the hooks missing", func(t *testing.T) {
		useFakeWorkbenchClaude(t)
		p := testWorkbench(t)
		var out bytes.Buffer
		require.NoError(t, runWorkbenchInstall(context.Background(), &out, p))
		dropHookEvent(t, p.FolderPath, "SubagentStop")
		out.Reset()

		require.NoError(t, runWorkbenchStatus(context.Background(), &out, p, true))

		assert.Contains(t, out.String(), `"state_hooks": false`)
		assert.Contains(t, out.String(), `"stop_hook": true`)
	})
}

// malformHookEvent replaces hooks.<event> in folder's settings file with an
// object where Claude Code expects an array: an owner's malformed entry.
func malformHookEvent(t *testing.T, folder, event string) {
	t.Helper()
	file := filepath.Join(folder, ".claude", "settings.local.json")
	b, err := os.ReadFile(file)
	require.NoError(t, err)
	var settings map[string]any
	require.NoError(t, json.Unmarshal(b, &settings))
	settings["hooks"].(map[string]any)[event] = map[string]any{"hooks": []any{}}
	b, err = json.Marshal(settings)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(file, b, 0o644))
}

// PROJ-11/PROJ-04, board #411: a malformed owner hooks.SubagentStop is
// refused by the status, which reads state_hooks false, while the Stop's
// state write reads only the core hooks and still records waiting.
func TestProj11_MalformedSubagentStopKeepsTheStopWaiting(t *testing.T) {
	t.Run("the Stop records waiting", func(t *testing.T) {
		database, pid, row := stopStateFixture(t, "open")
		malformHookEvent(t, mustFolder(t, database, pid), "SubagentStop")
		t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))

		out, errOut := stopHookIO(t, strconv.FormatInt(pid, 10), statePayload("Stop", briefLaunchID, ""))

		assert.Empty(t, out)
		assert.Empty(t, errOut)
		assert.Equal(t, "waiting", storedAgentState(t, database, row))
	})
	t.Run("the status reads state_hooks false", func(t *testing.T) {
		useFakeWorkbenchClaude(t)
		p := testWorkbench(t)
		var out bytes.Buffer
		require.NoError(t, runWorkbenchInstall(context.Background(), &out, p))
		malformHookEvent(t, p.FolderPath, "SubagentStop")
		o, err := workbenchInstallOptions(p)
		require.NoError(t, err)

		st, err := devpack.StatusWorkbench(context.Background(), o)

		require.ErrorIs(t, err, devpack.ErrMalformedSettings)
		assert.False(t, st.StateHooks)
		has, err := devpack.HasCoreStateHooks(p.FolderPath, p.ID)
		require.NoError(t, err)
		assert.True(t, has, "the core hooks still read installed")
		out.Reset()
		require.ErrorIs(t, runWorkbenchStatus(context.Background(), &out, p, true), devpack.ErrMalformedSettings)
		assert.NotContains(t, out.String(), `"state_hooks": true`)
	})
}
