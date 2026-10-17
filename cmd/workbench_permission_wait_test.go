package cmd

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

const (
	permissionAllowJSON = `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`
	permissionDenyJSON  = `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from the owner's phone."}}}`
)

func permissionPayload(sessionID string) string {
	return `{"session_id":"` + sessionID + `","transcript_path":"/tmp/x.jsonl","cwd":"/tmp/acme",` +
		`"hook_event_name":"PermissionRequest","tool_name":"Bash",` +
		`"tool_input":{"command":"ls -la","description":"List files"},"permission_suggestions":[]}`
}

// fastPermissionPoll shrinks the poll interval for the test.
func fastPermissionPoll(t *testing.T) {
	t.Helper()
	orig := permissionPollEvery
	permissionPollEvery = 10 * time.Millisecond
	t.Cleanup(func() { permissionPollEvery = orig })
}

func runPermissionWait(t *testing.T, workbenchID int64, stdin string) (stdout, stderr string) {
	t.Helper()
	rootCmd.SetIn(strings.NewReader(stdin))
	t.Cleanup(func() { rootCmd.SetIn(nil) })
	out, errOut, err := runWorkbenchAs(t, "workbench", "permission-wait", "--workbench", strconv.FormatInt(workbenchID, 10))
	require.NoError(t, err, "the hook always exits 0")
	return out, errOut
}

// pendingPermissionID waits (bounded) for the hook's pending row of session
// row and returns its id.
func pendingPermissionID(database *db.DB, row int64) (int64, error) {
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		var id int64
		err := database.QueryRow(`SELECT id FROM permission_requests
			WHERE terminal_session_id = ? AND status = 'pending'`, row).Scan(&id)
		if err == nil {
			return id, nil
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return 0, err
		}
		time.Sleep(5 * time.Millisecond)
	}
	return 0, errors.New("no pending permission request appeared")
}

func permissionRequestCount(t *testing.T, database *db.DB) int {
	t.Helper()
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM permission_requests`).Scan(&n))
	return n
}

// answerFromPhone closes the hook's request with status once it is pending,
// the way the hub's CAS does.
func answerFromPhone(database *db.DB, row int64, status string) <-chan error {
	done := make(chan error, 1)
	go func() {
		id, err := pendingPermissionID(database, row)
		if err == nil {
			var ok bool
			ok, err = database.ClosePermissionRequest(id, status, time.Now())
			if err == nil && !ok {
				err = errors.New("the request was no longer pending")
			}
		}
		done <- err
	}()
	return done
}

func TestProj21_PermissionWaitPhoneAllowPrintsAllow(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	stepClock(t)
	fastPermissionPoll(t)
	done := answerFromPhone(database, row, db.PermissionAllowed)

	out, errOut := runPermissionWait(t, pid, permissionPayload(briefLaunchID))

	require.NoError(t, <-done)
	assert.Equal(t, permissionAllowJSON, out)
	assert.Empty(t, errOut)
	var req struct {
		tool, summary string
	}
	require.NoError(t, database.QueryRow(`SELECT tool_name, summary FROM permission_requests`).Scan(&req.tool, &req.summary))
	assert.Equal(t, "Bash", req.tool)
	assert.Equal(t, "ls -la\nList files", req.summary)
}

func TestProj21_PermissionWaitPhoneDenyPrintsDeny(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	stepClock(t)
	fastPermissionPoll(t)
	done := answerFromPhone(database, row, db.PermissionDenied)

	out, errOut := runPermissionWait(t, pid, permissionPayload(briefLaunchID))

	require.NoError(t, <-done)
	assert.Equal(t, permissionDenyJSON, out)
	assert.Empty(t, errOut)
	var decoded map[string]any
	require.NoError(t, json.Unmarshal([]byte(out), &decoded), "valid JSON")
}

// The owner answers at the Mac first: the tool's PostToolUse stamps
// `working` after the request; the hook closes its row and prints nothing.
func TestProj21_PermissionWaitMacAnswerWins(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	stepClock(t)
	fastPermissionPoll(t)
	done := make(chan error, 1)
	go func() {
		_, err := pendingPermissionID(database, row)
		if err == nil {
			_, err = database.SetTerminalAgentState(row, pid, briefLaunchID, agentStateWorking,
				time.Now().Add(time.Hour), "", nil, false, db.AgentOrder{})
		}
		done <- err
	}()

	out, errOut := runPermissionWait(t, pid, permissionPayload(briefLaunchID))

	require.NoError(t, <-done)
	assert.Empty(t, out)
	assert.Empty(t, errOut)
	var status string
	require.NoError(t, database.QueryRow(`SELECT status FROM permission_requests`).Scan(&status))
	assert.Equal(t, db.PermissionAnsweredOnMac, status)
}

// The request itself records `approval` at once, before the 6 s
// Notification would.
func TestPermissionWait_RecordsApprovalAtOnce(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	stepClock(t)
	fastPermissionPoll(t)
	done := make(chan error, 1)
	go func() {
		id, err := pendingPermissionID(database, row)
		if err == nil {
			if s, sErr := database.GetTerminalSession(row); sErr != nil || s.AgentState.String != agentStateApproval {
				err = errors.Join(sErr, errors.New("state is not approval while pending"))
			}
			_, cErr := database.ClosePermissionRequest(id, db.PermissionAllowed, time.Now())
			err = errors.Join(err, cErr)
		}
		done <- err
	}()

	out, _ := runPermissionWait(t, pid, permissionPayload(briefLaunchID))

	require.NoError(t, <-done)
	assert.Equal(t, permissionAllowJSON, out)
}

// The session finished or was deleted while the prompt waits: no decision.
// A finished session's request is closed answered_on_mac; a deleted one's
// went with its row.
func TestPermissionWait_SessionGoneExitsSilently(t *testing.T) {
	for _, tc := range []struct{ name, stmt, want string }{
		{"finished", `UPDATE terminal_sessions SET finished_at = '2026-10-17T10:00:00Z' WHERE id = ?`, db.PermissionAnsweredOnMac},
		{"deleted", `DELETE FROM terminal_sessions WHERE id = ?`, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			database, pid, row := briefSessionFixture(t)
			t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
			stepClock(t)
			fastPermissionPoll(t)
			done := make(chan error, 1)
			go func() {
				_, err := pendingPermissionID(database, row)
				if err == nil {
					_, err = database.Exec(tc.stmt, row)
				}
				done <- err
			}()

			out, errOut := runPermissionWait(t, pid, permissionPayload(briefLaunchID))

			require.NoError(t, <-done)
			assert.Empty(t, out)
			assert.Empty(t, errOut)
			var status string
			err := database.QueryRow(`SELECT status FROM permission_requests`).Scan(&status)
			if tc.want == "" {
				assert.ErrorIs(t, err, sql.ErrNoRows)
			} else {
				require.NoError(t, err)
				assert.Equal(t, tc.want, status)
			}
		})
	}
}

func TestProj21_PermissionWaitNotABoardSessionExitsSilently(t *testing.T) {
	database, pid, _ := briefSessionFixture(t)
	unsetTerminalEnv(t)

	start := time.Now()
	out, errOut := runPermissionWait(t, pid, permissionPayload(briefLaunchID))

	assert.Less(t, time.Since(start), 100*time.Millisecond)
	assert.Empty(t, out)
	assert.Empty(t, errOut)
	assert.Equal(t, 0, permissionRequestCount(t, database))
}

// A nested `claude -p` inherits the env var but runs another conversation.
func TestPermissionWait_ForeignSessionExitsSilently(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))

	out, errOut := runPermissionWait(t, pid, permissionPayload(nestedSessionID))

	assert.Empty(t, out)
	assert.Empty(t, errOut)
	assert.Equal(t, 0, permissionRequestCount(t, database))
}

func TestProj21_PermissionWaitDBFailureExitsSilently(t *testing.T) {
	_, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	brokenConfig(t)

	out, errOut := runPermissionWait(t, pid, permissionPayload(briefLaunchID))

	assert.Empty(t, out)
	assert.Contains(t, errOut, "permission request not recorded")
}

func TestPermissionSummary(t *testing.T) {
	long := strings.Repeat("é", 2001)
	for _, tc := range []struct {
		name, tool, input, want string
	}{
		{"bash with description", "Bash", `{"command":"go test ./...","description":"Run the tests"}`, "go test ./...\nRun the tests"},
		{"bash without description", "Bash", `{"command":"ls"}`, "ls"},
		{"edit", "Edit", `{"file_path":"/tmp/acme/a.go","old_string":"a","new_string":"b"}`, "/tmp/acme/a.go"},
		{"write", "Write", `{"file_path":"/tmp/acme/b.go","content":"x"}`, "/tmp/acme/b.go"},
		{"webfetch", "WebFetch", `{"url":"https://example.com/x","prompt":"read"}`, "https://example.com/x"},
		{"mcp tool", "mcp__acme__do_thing", `{ "b": 2,  "a": "x" }`, `{"b":2,"a":"x"}`},
		{"no input", "mcp__acme__ping", ``, ""},
		{"clipped", "Bash", `{"command":"` + long + `"}`, strings.Repeat("é", 2000)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			assert.Equal(t, tc.want, permissionSummary(tc.tool, json.RawMessage(tc.input)))
		})
	}
}

// SIGTERM (the hook's timeout, Claude Code quitting) ends the wait: no
// decision, and the request stays for the Desktop's expiry.
func TestPermissionWait_CancelExitsSilently(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	stepClock(t)
	fastPermissionPoll(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, err := pendingPermissionID(database, row)
		cancel()
		done <- err
	}()
	var out, errOut bytes.Buffer

	runPermissionWaitHook(ctx, strings.NewReader(permissionPayload(briefLaunchID)), &out, &errOut, strconv.FormatInt(pid, 10))

	require.NoError(t, <-done)
	assert.Empty(t, out.String())
	assert.Empty(t, errOut.String())
	var status string
	require.NoError(t, database.QueryRow(`SELECT status FROM permission_requests`).Scan(&status))
	assert.Equal(t, db.PermissionPending, status)
}
