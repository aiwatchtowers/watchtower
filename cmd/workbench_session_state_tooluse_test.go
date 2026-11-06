package cmd

import (
	"errors"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/sqlcipher"
)

// toolEventPayload is a tool hook's input (PreToolUse, PostToolUse,
// PostToolUseFailure) of call id, its transcript at path; agentID marks one
// fired inside a subagent.
func toolEventPayload(event, id, path, agentID string) string {
	s := `{"session_id":"` + briefLaunchID + `","transcript_path":"` + path + `","cwd":"/tmp/acme","hook_event_name":"` + event + `",` +
		`"tool_name":"Bash","tool_use_id":"` + id + `","tool_input":{"command":"ls"}`
	if agentID != "" {
		s += `,"agent_id":"` + agentID + `","agent_type":"general-purpose"`
	}
	return s + `}`
}

// recordToolEvent runs `workbench session-state` on payload at second sec of
// the hook clock; the hook prints nothing.
func recordToolEvent(t *testing.T, pid int64, at func(int), sec int, payload string) {
	t.Helper()
	at(sec)
	out, errOut, err := runSessionState(t, pid, strings.NewReader(payload))
	require.NoError(t, err)
	require.Empty(t, out)
	require.Empty(t, errOut)
}

// PROJ-11, board #988 (ask #525): a main-thread tool start is a working
// signal. Out of the Stop's `waiting`, the run mark (a stamp, no state) and a
// row with nothing stored, a PreToolUse records `working` — before the tool
// finishes, so a long tool, a foreground subagent or a failing tool no longer
// reads Stopped.
func TestProj11_PreToolUseOutOfWaitingIsWorking(t *testing.T) {
	for _, from := range []string{"waiting", "run mark", "nothing stored"} {
		database, pid, row := stopStateFixture(t, "open")
		t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
		_, at := hookClock(t)
		transcript := writeTranscript(t, transcriptPrompt("go"), transcriptReply("done"))
		switch from {
		case "waiting":
			s := hookStep(t, database, pid, row, at, 1, stopPayload(transcript))
			require.Equal(t, "waiting", s.AgentState.String)
		case "run mark":
			at(1)
			_, err := database.MarkTerminalAgentRun(row, pid, briefLaunchID, hookNow(), "")
			require.NoError(t, err)
			require.Empty(t, storedAgentState(t, database, row))
		}
		appendTranscript(t, transcript, transcriptToolUse("toolu_B"))
		recordToolEvent(t, pid, at, 2, toolEventPayload("PreToolUse", "toolu_B", transcript, ""))
		assert.Equal(t, "working", storedAgentState(t, database, row), from)
		s, err := database.GetTerminalSession(row)
		require.NoError(t, err)
		assert.True(t, s.ToolRun, "%s: a tool start's working is a tool run the Stop replaces", from)
	}
}

// PROJ-11, board #988 (ask #525): a tool start never hides a permission
// dialog. PreToolUse fires before the prompt; its async hook may start after
// the prompt's notification and still writes nothing over `approval`. The
// same holds for a failed tool's PostToolUseFailure (a denied call).
func TestProj11_PreToolUseNeverOverwritesApproval(t *testing.T) {
	for _, event := range []string{"PreToolUse", "PostToolUseFailure"} {
		database, pid, row := briefSessionFixture(t)
		t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
		_, at := hookClock(t)
		recordToolEvent(t, pid, at, 1, statePayload("UserPromptSubmit", briefLaunchID, ""))
		recordToolEvent(t, pid, at, 2, statePayload("Notification", briefLaunchID, "permission_prompt"))
		before := rowSnapshot(t, database, row)
		require.Equal(t, "approval", before["agent_state"])

		recordToolEvent(t, pid, at, 3, toolEventPayload(event, "toolu_A", "", ""))
		assert.Equal(t, before, rowSnapshot(t, database, row), "%s over approval wrote", event)

		// The guard is in the write itself too: a racing approval between
		// the hook's read and its write keeps the dialog.
		s, err := database.GetTerminalSession(row)
		require.NoError(t, err)
		written, err := database.SetTerminalAgentState(row, pid, briefLaunchID, agentStateWorking, time.Now().Add(time.Hour),
			"", nil, false, db.AgentOrder{ToolRun: true, NotOverApproval: true, SeenTurnEnd: s.TurnEnd})
		require.NoError(t, err)
		assert.False(t, written, "%s: the guarded UPDATE wrote over approval", event)
	}
}

// PROJ-11, board #988 (ask #525): a tool start and a failed tool keep the
// turn order of a tool result (board #368). The ended turn's PreToolUse or
// PostToolUseFailure whose async hook starts after the Stop's writes
// nothing; one landing first is replaced by the Stop's `waiting`; a later
// turn's call records `working`.
func TestProj11_EndedTurnsPreToolUseNeverOverwritesTheStop(t *testing.T) {
	for _, event := range []string{"PreToolUse", "PostToolUseFailure"} {
		t.Run(event+" after the Stop", func(t *testing.T) {
			database, pid, row := stopStateFixture(t, "open")
			t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
			_, at := hookClock(t)
			transcript := writeTranscript(t, transcriptPrompt("go"), transcriptToolUse("toolu_A"), transcriptToolResult("toolu_A"),
				transcriptReply("done"))
			recordToolEvent(t, pid, at, 1, statePayload("UserPromptSubmit", briefLaunchID, ""))
			require.Equal(t, "waiting", hookStep(t, database, pid, row, at, 2, stopPayload(transcript)).AgentState.String)

			recordToolEvent(t, pid, at, 3, toolEventPayload(event, "toolu_A", transcript, ""))
			assert.Equal(t, "waiting", storedAgentState(t, database, row), "the ended turn's %s", event)

			appendTranscript(t, transcript, transcriptToolUse("toolu_B"))
			recordToolEvent(t, pid, at, 4, toolEventPayload(event, "toolu_B", transcript, ""))
			assert.Equal(t, "working", storedAgentState(t, database, row), "a self-started turn's %s", event)
		})
		t.Run(event+" landing first", func(t *testing.T) {
			database, pid, row := stopStateFixture(t, "open")
			t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
			base, at := hookClock(t)
			transcript := writeTranscript(t, transcriptPrompt("go"), transcriptToolUse("toolu_A"), transcriptToolResult("toolu_A"),
				transcriptReply("done"))
			recordToolEvent(t, pid, at, 1, statePayload("Notification", briefLaunchID, "idle_prompt"))
			recordToolEvent(t, pid, at, 3, toolEventPayload(event, "toolu_A", "", ""))
			require.Equal(t, "working", storedAgentState(t, database, row))

			s := hookStep(t, database, pid, row, at, 2, stopPayload(transcript))
			assert.Equal(t, "waiting", s.AgentState.String, "the Stop replaces its turn's %s", event)
			assert.Equal(t, base.Add(3*time.Second).UTC().Truncate(time.Millisecond), s.AgentStateAt.UTC(), "the stored time never goes back")
		})
	}
}

// PROJ-11, board #988 (ask #525): a failed main-thread tool is a tool run
// like a successful one — out of `waiting` it records `working` and, as a
// turn the agent started itself, clears finished_at and the count; over
// `working` it is a no-op that keeps finished_at.
func TestProj11_PostToolUseFailureIsWorking(t *testing.T) {
	database, pid, row := stopStateFixture(t, "open")
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	_, at := hookClock(t)
	transcript := writeTranscript(t, transcriptPrompt("go"), transcriptReply("done"))
	recordToolEvent(t, pid, at, 1, statePayload("UserPromptSubmit", briefLaunchID, ""))
	require.NoError(t, database.FinishTerminalSession(row, "Done.", time.Now()))
	recordToolEvent(t, pid, at, 2, toolEventPayload("PostToolUseFailure", "toolu_A", "", ""))
	assert.True(t, storedFinishedAt(t, database, row).Valid, "a failed tool over working cleared finished_at")

	require.Equal(t, "waiting", hookStep(t, database, pid, row, at, 3, stopPayload(transcript)).AgentState.String)
	appendTranscript(t, transcript, transcriptToolUse("toolu_B"))
	recordToolEvent(t, pid, at, 4, toolEventPayload("PostToolUseFailure", "toolu_B", transcript, ""))
	assert.Equal(t, "working", storedAgentState(t, database, row))
	assert.False(t, storedFinishedAt(t, database, row).Valid, "a failed tool out of waiting kept finished_at")
}

// Board #988: a turn opened without a UserPromptSubmit — a message from a
// teammate or another session injected after the Stop (and after an idle
// notice, as around an interrupted /login) — turns `waiting` into `working`
// at its first tool start and keeps it there through its tool results.
func TestSessionState_InjectedMessageTurnIsWorking(t *testing.T) {
	database, pid, row := stopStateFixture(t, "open")
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	_, at := hookClock(t)
	transcript := writeTranscript(t, transcriptPrompt("go"), transcriptToolUse("toolu_A"), transcriptToolResult("toolu_A"),
		transcriptReply("done"))
	recordToolEvent(t, pid, at, 1, statePayload("UserPromptSubmit", briefLaunchID, ""))
	require.Equal(t, "waiting", hookStep(t, database, pid, row, at, 2, stopPayload(transcript)).AgentState.String)
	recordToolEvent(t, pid, at, 3, statePayload("Notification", briefLaunchID, "idle_prompt"))

	appendTranscript(t, transcript, transcriptPrompt("Another Claude session sent a message: teammate-message"),
		transcriptToolUse("toolu_B"))
	recordToolEvent(t, pid, at, 4, toolEventPayload("PreToolUse", "toolu_B", transcript, ""))
	assert.Equal(t, "working", storedAgentState(t, database, row), "the injected turn's tool start")

	appendTranscript(t, transcript, transcriptToolResult("toolu_B"))
	recordToolEvent(t, pid, at, 5, toolEventPayload("PostToolUse", "toolu_B", transcript, ""))
	assert.Equal(t, "working", storedAgentState(t, database, row), "the injected turn's tool result")

	// Without the tool start (a folder not yet repaired) the tool result
	// alone still ends the Stop's waiting: the turn order never holds back
	// a turn that has no prompt.
	require.Equal(t, "waiting", hookStep(t, database, pid, row, at, 6, stopPayload(transcript)).AgentState.String)
	appendTranscript(t, transcript, transcriptPrompt("Another Claude session sent a message: teammate-message"),
		transcriptToolUse("toolu_C"), transcriptToolResult("toolu_C"))
	recordToolEvent(t, pid, at, 7, toolEventPayload("PostToolUse", "toolu_C", transcript, ""))
	assert.Equal(t, "working", storedAgentState(t, database, row), "the injected turn's first tool result")
}

// A subagent's tool start writes nothing (its state stays the main thread's),
// and a subagent's failed tool is only a heartbeat of the Stop's count: it
// never turns `waiting` or `approval` into `working`.
func TestSessionState_SubagentToolStartOrFailureNeverMovesTheState(t *testing.T) {
	for _, from := range []string{"approval", "waiting"} {
		for _, event := range []string{"PreToolUse", "PostToolUseFailure"} {
			database, pid, row := briefSessionFixture(t)
			t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
			_, at := hookClock(t)
			recordToolEvent(t, pid, at, 1, statePayload("UserPromptSubmit", briefLaunchID, ""))
			if from == "approval" {
				recordToolEvent(t, pid, at, 2, statePayload("Notification", briefLaunchID, "permission_prompt"))
			} else {
				recordToolEvent(t, pid, at, 2, statePayload("Notification", briefLaunchID, "idle_prompt"))
			}
			before := rowSnapshot(t, database, row)
			recordToolEvent(t, pid, at, 3, toolEventPayload(event, "toolu_S", "", "a1b2c3"))
			assert.Equal(t, before, rowSnapshot(t, database, row), "a subagent's %s over %s wrote", event, from)
		}
	}
}

// busyError is SQLite giving up on another connection's write lock.
var busyError = sqlcipher.Error{Code: sqlcipher.ErrBusy}

// Board #988 (ask #525, F2): an async state hook's write that gave up on the
// lock is tried once more; a sync hook's (the Stop's, a codex one's) and an
// error that is not a busy lock are not.
func TestHookLockWaitRetriesABusyWriteOnce(t *testing.T) {
	database, _, _ := briefSessionFixture(t)
	for _, tc := range []struct {
		name  string
		lock  hookLockWait
		err   error
		calls int
	}{
		{"async, busy then free", stateHookLockWait, busyError, 2},
		{"async, another error", stateHookLockWait, errors.New("disk I/O"), 1},
		{"sync, busy", hookLockWait{}, busyError, 1},
	} {
		calls := 0
		err := tc.lock.write(database, func() error {
			calls++
			if calls == 1 {
				return tc.err
			}
			return nil
		})
		assert.Equal(t, tc.calls, calls, tc.name)
		if tc.calls == 2 {
			assert.NoError(t, err, tc.name)
		} else {
			assert.Error(t, err, tc.name)
		}
	}
	assert.Greater(t, stateHookLockWait.wait, sessionRecordBusyTimeout, "the async wait is longer than the sync one")
	assert.LessOrEqual(t, 2*stateHookLockWait.wait, 4*time.Second, "both tries fit the async hook's 5 s timeout")
}

// Board #988 (F2): a state write that loses the lock once lands on the
// retry, through the hook.
func TestSessionState_BusyStateWriteIsRetried(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	_, at := hookClock(t)
	orig := setTerminalAgentState
	t.Cleanup(func() { setTerminalAgentState = orig })
	calls := 0
	setTerminalAgentState = func(d *db.DB, id, workbenchID int64, sessionID, state string, at time.Time, onlyFrom string,
		failure *db.AgentFailure, prompt bool, order db.AgentOrder) (bool, error) {
		calls++
		if calls == 1 {
			return false, busyError
		}
		return orig(d, id, workbenchID, sessionID, state, at, onlyFrom, failure, prompt, order)
	}
	recordToolEvent(t, pid, at, 1, statePayload("UserPromptSubmit", briefLaunchID, ""))
	assert.Equal(t, 2, calls)
	assert.Equal(t, "working", storedAgentState(t, database, row))
}

// Board #988 (F2): the SessionStart's id move that loses the lock once lands
// on the retry, so the row follows the resumed conversation and its later
// hooks are not dropped as a nested session's.
func TestApplySessionStart_BusyIDMoveIsRetried(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	orig := setTerminalClaudeSessionID
	t.Cleanup(func() { setTerminalClaudeSessionID = orig })
	calls := 0
	setTerminalClaudeSessionID = func(d *db.DB, id, workbenchID int64, sessionID string) (bool, error) {
		calls++
		if calls == 1 {
			return false, busyError
		}
		return orig(d, id, workbenchID, sessionID)
	}
	require.NoError(t, applySessionStart(database, row, pid, briefClearedID, "", true, false))
	assert.Equal(t, 2, calls)
	assert.Equal(t, briefClearedID, storedClaudeSessionID(t, database, row))
}

// lockClock pins lockNow to the times returned by next, one per read.
func lockClock(t *testing.T, next func() time.Time) {
	t.Helper()
	orig := lockNow
	lockNow = next
	t.Cleanup(func() { lockNow = orig })
}

// Board #988 review (F1): one hook process's writes share one lock budget.
// A write past the deadline is not tried, a retry is tried only while time
// is left, and a try's wait is cut to what is left.
func TestHookLockWaitStopsAtTheBudget(t *testing.T) {
	database, _, _ := briefSessionFixture(t)
	base := time.Now()

	lockClock(t, func() time.Time { return base })
	calls := 0
	err := stateHookLockWait.until(base.Add(-time.Millisecond)).write(database, func() error { calls++; return nil })
	assert.ErrorIs(t, err, errHookOutOfTime)
	assert.Zero(t, calls, "a write past the deadline was tried")

	reads := 0
	lockClock(t, func() time.Time {
		reads++
		if reads == 1 {
			return base
		}
		return base.Add(stateHookBudget)
	})
	calls = 0
	err = stateHookLockWait.until(base.Add(stateHookBudget)).write(database, func() error { calls++; return busyError })
	assert.True(t, db.IsBusy(err), "the busy error is returned: %v", err)
	assert.Equal(t, 1, calls, "a retry was tried with no time left")

	lockClock(t, func() time.Time { return base })
	wait, ok := stateHookLockWait.until(base.Add(300 * time.Millisecond)).attemptWait()
	assert.True(t, ok)
	assert.Equal(t, 300*time.Millisecond, wait, "a try's wait is cut to the budget left")
	wait, ok = hookLockWait{}.attemptWait()
	assert.True(t, ok)
	assert.Equal(t, sessionRecordBusyTimeout, wait, "the zero value is the sync hooks' one short wait")
}

// Board #988 review (F1): a UserPromptSubmit's state write goes before its
// clear of the chat question, so a budget spent on the first write leaves
// the state recorded and only the clear undone.
func TestSessionState_PromptStateWriteGoesFirstWithinTheBudget(t *testing.T) {
	database, pid, row := briefSessionFixture(t)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	base := time.Now()
	askChatQuestion(t, database, pid, row, base)
	reads := 0
	lockClock(t, func() time.Time {
		reads++
		if reads == 1 {
			return base
		}
		return base.Add(time.Hour)
	})
	turn := hookTurn{lock: stateHookLockWait.until(base.Add(stateHookBudget))}
	err := recordAgentState(database, row, pid, briefLaunchID, agentStateWorking, "", nil, true, base.Add(time.Second), turn)
	assert.ErrorIs(t, err, errHookOutOfTime, "the clear past the budget is reported")
	assert.Equal(t, "working", storedAgentState(t, database, row), "the state write went first")
	assert.NotEmpty(t, chatQuestionAt(t, database, row), "the clear had no time left")
}
