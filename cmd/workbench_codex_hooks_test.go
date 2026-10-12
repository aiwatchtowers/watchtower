package cmd

import (
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// The Codex hook mapping (spec 2026-10-12-codex-workbench-agent §5, §6.3,
// §6.4): every hook command with --agent codex, on a codex row, fed the
// Task 0 fixtures.

// codexRowFixture is a workbench whose folder has no settings.local.json
// (the Claude Code state hooks are not installed) and a codex row in it
// storing sessionID ("" = none yet), the hook env naming the row.
func codexRowFixture(t *testing.T, sessionID string) (database *db.DB, pid, row int64) {
	t.Helper()
	database = writeActionsConfig(t)
	pid, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	return database, pid, codexRowIn(t, database, pid, sessionID)
}

// codexRowIn adds a codex row storing sessionID ("" = none) to workbench pid
// and points the hook env at it.
func codexRowIn(t *testing.T, database *db.DB, pid int64, sessionID string) int64 {
	t.Helper()
	row := insertHookRow(t, database, pid, "codex")
	if sessionID != "" {
		_, err := database.Exec(`UPDATE terminal_sessions SET claude_session_id = ? WHERE id = ?`, sessionID, row)
		require.NoError(t, err)
	}
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	return row
}

func codexRow(t *testing.T, database *db.DB, row int64) *db.TerminalSession {
	t.Helper()
	s, err := database.GetTerminalSession(row)
	require.NoError(t, err)
	return s
}

// codexPayload is fixture name with fields set (nil deletes one).
func codexPayload(t *testing.T, name string, fields map[string]any) string {
	t.Helper()
	var m map[string]any
	require.NoError(t, json.Unmarshal(codexHookFixture(t, name), &m))
	for k, v := range fields {
		if v == nil {
			delete(m, k)
			continue
		}
		m[k] = v
	}
	b, err := json.Marshal(m)
	require.NoError(t, err)
	return string(b)
}

func runCodexState(t *testing.T, stdin string) {
	t.Helper()
	out, errOut := runCodexHook(t, stdin, "session-state", "--agent", "codex")
	assert.Empty(t, out)
	assert.Empty(t, errOut)
}

func runCodexStop(t *testing.T, stdin string) (stdout, stderr string) {
	t.Helper()
	return runCodexHook(t, stdin, "check", "--agent", "codex", "--stop-hook")
}

func runCodexBriefHook(t *testing.T, stdin string) string {
	t.Helper()
	out, errOut := runCodexHook(t, stdin, "brief", "--agent", "codex")
	assert.Empty(t, errOut)
	assert.Contains(t, out, "Watchtower workbench #", "the brief is printed")
	return out
}

// storeCodexState gives the codex row a state stamped a minute ago.
func storeCodexState(t *testing.T, database *db.DB, pid, row int64, sessionID, state string) {
	t.Helper()
	ok, err := database.SetTerminalAgentState(row, pid, sessionID, state, time.Now().Add(-time.Minute), "", nil, false, db.AgentOrder{})
	require.NoError(t, err)
	require.True(t, ok)
}

// --- SessionStart: the brief hook records the session (§5) ---

func TestCodexSessionStart_StartupSetsNullID(t *testing.T) {
	database, _, row := codexRowFixture(t, "")

	runCodexBriefHook(t, string(codexHookFixture(t, "session_start_startup")))

	s := codexRow(t, database, row)
	assert.Equal(t, codexTUISession, s.ClaudeSessionID.String)
	assert.Equal(t, codexTUIRollout, s.TranscriptPath.String, "the transcript path is stored")
	assert.False(t, s.AgentState.Valid)
	assert.False(t, s.AgentStateAt.IsZero(), "the run is marked")
}

func TestCodexSessionStart_StartupWithOtherStoredIDWritesNothing(t *testing.T) {
	database, pid, row := codexRowFixture(t, briefClearedID)
	storeCodexState(t, database, pid, row, briefClearedID, agentStateWorking)
	before := rowSnapshot(t, database, row)

	out, errOut := runCodexHook(t, string(codexHookFixture(t, "session_start_startup")), "brief", "--agent", "codex")

	assert.Contains(t, out, "Watchtower workbench #", "the brief is printed")
	assert.Equal(t, before, rowSnapshot(t, database, row), "a stale or foreign start")
	assert.Equal(t, "watchtower: codex SessionStart (startup) ignored: terminal session "+strconv.FormatInt(row, 10)+
		" stores session "+briefClearedID+", the hook came from session "+codexTUISession+"\n", errOut,
		"one line names the dropped start (#399 m5)")
}

func TestCodexSessionStart_ResumeMarksRun(t *testing.T) {
	t.Run("same id", func(t *testing.T) {
		database, pid, row := codexRowFixture(t, codexTUISession)
		storeCodexState(t, database, pid, row, codexTUISession, agentStateWaiting)

		runCodexBriefHook(t, string(codexHookFixture(t, "session_start_resume")))

		s := codexRow(t, database, row)
		assert.Equal(t, codexTUISession, s.ClaudeSessionID.String)
		assert.False(t, s.AgentState.Valid, "the previous run's state goes")
		assert.WithinDuration(t, time.Now(), s.AgentStateAt, time.Minute, "the run's mark")
		assert.Equal(t, codexTUIRollout, s.TranscriptPath.String)
	})
	t.Run("another id", func(t *testing.T) {
		database, pid, row := codexRowFixture(t, briefClearedID)
		storeCodexState(t, database, pid, row, briefClearedID, agentStateWaiting)

		runCodexBriefHook(t, string(codexHookFixture(t, "session_start_resume")))

		s := codexRow(t, database, row)
		assert.Equal(t, codexTUISession, s.ClaudeSessionID.String, "the resume moves the id")
		assert.False(t, s.AgentState.Valid)
		assert.WithinDuration(t, time.Now(), s.AgentStateAt, time.Minute, "and marks the run")
		assert.Equal(t, codexTUIRollout, s.TranscriptPath.String)
	})
}

func TestCodexSessionStart_ClearMovesIDAndClearsState(t *testing.T) {
	database, pid, row := codexRowFixture(t, codexTUISession)
	_, err := database.RecordTerminalAgentTurn(row, pid, codexTUISession, codexSubagentID, true, time.Now().Add(-time.Minute))
	require.NoError(t, err)
	ok, err := database.SetTerminalAgentState(row, pid, codexTUISession, agentStateWaiting, time.Now().Add(-time.Minute), "",
		nil, false, db.AgentOrder{Stop: true, Background: sql.NullInt64{Int64: 1, Valid: true}})
	require.NoError(t, err)
	require.True(t, ok)
	require.NoError(t, database.SetChatQuestion(row, pid, codexTUISession, db.ChatQuestion{Question: "example?"}, time.Now()))
	_, err = database.SetTerminalTranscriptPath(row, pid, codexTUISession, codexTUIRollout)
	require.NoError(t, err)

	runCodexBriefHook(t, string(codexHookFixture(t, "session_start_clear")))

	s := codexRow(t, database, row)
	assert.Equal(t, "01a10000-0000-7000-8000-000000000002", s.ClaudeSessionID.String)
	assert.Contains(t, s.TranscriptPath.String, "000000000002.jsonl", "the new session's transcript")
	assert.False(t, s.Background.Valid, "the old session's background count goes")
	assert.Empty(t, s.ChatQuestionAt, "and its chat question")
	turns, err := database.TerminalAgentTurns(row)
	require.NoError(t, err)
	assert.Empty(t, turns, "and its agent turns")
}

// Capture note answer 3: a compaction keeps the session id, so it is
// neither a move nor a new run, and the live turn's state stays.
func TestCodexSessionStart_CompactKeepsTheLiveTurn(t *testing.T) {
	database, pid, row := codexRowFixture(t, codexTUISession)
	_, err := database.SetTerminalTranscriptPath(row, pid, codexTUISession, codexTUIRollout)
	require.NoError(t, err)
	storeCodexState(t, database, pid, row, codexTUISession, agentStateWorking)
	_, err = database.RecordTerminalAgentTurn(row, pid, codexTUISession, codexSubagentID, true, time.Now())
	require.NoError(t, err)
	before := rowSnapshot(t, database, row)

	runCodexBriefHook(t, string(codexHookFixture(t, "session_start_compact")))

	assert.Equal(t, before, rowSnapshot(t, database, row))
}

func TestCodexSessionStart_UnknownSourceActsAsStartup(t *testing.T) {
	for _, source := range []any{"something-new", "", nil} {
		database, pid, row := codexRowFixture(t, "")
		runCodexBriefHook(t, codexPayload(t, "session_start_startup", map[string]any{"source": source}))
		assert.Equal(t, codexTUISession, codexRow(t, database, row).ClaudeSessionID.String, "%v sets a NULL id", source)

		other := codexRowIn(t, database, pid, briefClearedID)
		before := rowSnapshot(t, database, other)
		_, errOut := runCodexHook(t, codexPayload(t, "session_start_startup", map[string]any{"source": source}),
			"brief", "--agent", "codex")
		assert.Equal(t, before, rowSnapshot(t, database, other), "%v never moves an id", source)
		assert.Contains(t, errOut, "codex SessionStart (startup) ignored", "%v reads as a startup", source)
	}
}

func TestCodexSessionStart_MissingSessionIDPrintsBriefOnly(t *testing.T) {
	for _, id := range []any{nil, "", "not-a-uuid", 42} {
		database, _, row := codexRowFixture(t, "")
		before := rowSnapshot(t, database, row)

		out, errOut := runCodexHook(t, codexPayload(t, "session_start_startup", map[string]any{"session_id": id}),
			"brief", "--agent", "codex")

		assert.Contains(t, out, "Watchtower workbench #", "%v: the brief", id)
		assert.Equal(t, before, rowSnapshot(t, database, row), "%v: no write", id)
		if _, isString := id.(string); isString || id == nil {
			assert.Empty(t, errOut, "%v", id)
		}
	}
}

func TestCodexSessionStart_RelativeTranscriptPathNotStored(t *testing.T) {
	database, _, row := codexRowFixture(t, "")

	runCodexBriefHook(t, codexPayload(t, "session_start_startup", map[string]any{"transcript_path": "sessions/x.jsonl"}))

	s := codexRow(t, database, row)
	assert.Equal(t, codexTUISession, s.ClaudeSessionID.String)
	assert.False(t, s.TranscriptPath.Valid)
}

func TestCodexSessionStart_PlanTable(t *testing.T) {
	null, stored := sql.NullString{}, sql.NullString{String: codexTUISession, Valid: true}
	other := sql.NullString{String: briefClearedID, Valid: true}
	for _, tc := range []struct {
		stored sql.NullString
		source string
		want   sessionStartPlan
	}{
		{null, "startup", sessionStartSet}, {null, "clear", sessionStartSet}, {null, "compact", sessionStartSet},
		{stored, "startup", sessionStartMark}, {stored, "resume", sessionStartMark}, {stored, "x", sessionStartMark},
		{stored, "clear", sessionStartNone}, {stored, "compact", sessionStartNone}, {stored, "fork", sessionStartNone},
		{other, "startup", sessionStartNone}, {other, "x", sessionStartNone},
		{other, "resume", sessionStartMove}, {other, "clear", sessionStartMove},
		{other, "compact", sessionStartMove}, {other, "fork", sessionStartMove},
	} {
		got := planCodexSessionStart(tc.stored, hookEvent{SessionID: codexTUISession, Source: tc.source})
		assert.Equal(t, tc.want, got, "%v %s", tc.stored, tc.source)
	}
	assert.Equal(t, sessionStartNone, planCodexSessionStart(null, hookEvent{SessionID: "x", Source: "startup"}))
}

// Controller ruling: a nested claude run from a codex row's shell inherits
// the row's env var and the folder's Claude Code hooks, and never writes its
// id into the codex row, on any source, NULL id or not.
func TestCodexSessionStart_NestedClaudeNeverTakesTheRow(t *testing.T) {
	database, pid, _ := codexRowFixture(t, "")
	installBriefStateHooks(t, database, pid)
	for _, stored := range []string{"", codexTUISession} {
		row := codexRowIn(t, database, pid, stored)
		before := rowSnapshot(t, database, row)
		for _, source := range []string{"startup", "clear", "compact", "resume", "fork"} {
			out, errOut := runBriefHook(t, pid, hookPayload(source, briefClearedID))
			assert.Contains(t, out, "Watchtower workbench #")
			assert.Empty(t, errOut)
			assert.Equal(t, before, rowSnapshot(t, database, row), "stored %q, source %s", stored, source)
		}
	}
}

func TestCodexBrief_NoClaudeCodeStringAndWithinBudget(t *testing.T) {
	database, pid, _ := codexRowFixture(t, "")
	var inputs []db.WorkbenchTargetInput
	for i := range 80 {
		inputs = append(inputs, db.WorkbenchTargetInput{Title: strings.Repeat("A long target title ", 8) + strconv.Itoa(i)})
	}
	require.NoError(t, database.WithTx(func(tx *sql.Tx) error {
		_, err := database.CreateWorkbenchTargetsTx(tx, pid, db.ActorAgent, inputs)
		return err
	}))

	out := runCodexBriefHook(t, string(codexHookFixture(t, "session_start_startup")))

	assert.NotContains(t, out, "Claude Code")
	assert.LessOrEqual(t, utf8.RuneCountInString(strings.TrimSuffix(out, "\n")), briefMaxChars)
}

// --- State hooks (§6.3) ---

func TestProj11_CodexPermissionRequestIsApproval(t *testing.T) {
	database, _, row := codexRowFixture(t, codexTUISession)
	stepClock(t)

	runCodexState(t, string(codexHookFixture(t, "user_prompt_submit")))
	assert.Equal(t, agentStateWorking, storedAgentState(t, database, row))
	runCodexState(t, string(codexHookFixture(t, "permission_request")))
	assert.Equal(t, agentStateApproval, storedAgentState(t, database, row))

	state, onlyFrom, ok := agentStateFor("PermissionRequest", "")
	assert.Equal(t, []any{agentStateApproval, "", true}, []any{state, onlyFrom, ok})
}

func TestProj11_CodexPostToolUseClearsApproval(t *testing.T) {
	for _, from := range []string{agentStateApproval, agentStateWaiting} {
		database, pid, row := codexRowFixture(t, codexTUISession)
		storeCodexState(t, database, pid, row, codexTUISession, from)

		runCodexState(t, string(codexHookFixture(t, "post_tool_use")))

		s := codexRow(t, database, row)
		assert.Equal(t, agentStateWorking, s.AgentState.String, "from %s", from)
		assert.False(t, s.TurnEnd.Valid, "no transcript turn order for codex")
	}
}

func TestProj11_CodexStopWritesWaitingAndOpenTurnCount(t *testing.T) {
	database, pid, row := codexRowFixture(t, codexExecSession)
	storeCodexState(t, database, pid, row, codexExecSession, agentStateWorking)
	stepClock(t)

	runCodexState(t, string(codexHookFixture(t, "subagent_start")))
	out, errOut := runCodexStop(t, codexPayload(t, "stop", map[string]any{"session_id": codexExecSession}))

	assert.Empty(t, out, "no drift")
	assert.Empty(t, errOut)
	s := codexRow(t, database, row)
	assert.Equal(t, agentStateWaiting, s.AgentState.String)
	assert.Equal(t, sql.NullInt64{Int64: 1, Valid: true}, s.Background, "one open subagent turn")
	assert.False(t, s.TurnEnd.Valid, "agent_turn_end stays NULL for codex")
}

func TestProj11_CodexStopWithoutOpenTurnsHasNoCount(t *testing.T) {
	database, pid, row := codexRowFixture(t, codexTUISession)
	storeCodexState(t, database, pid, row, codexTUISession, agentStateWorking)

	_, errOut := runCodexStop(t, string(codexHookFixture(t, "stop")))

	assert.Empty(t, errOut)
	s := codexRow(t, database, row)
	assert.Equal(t, agentStateWaiting, s.AgentState.String)
	assert.False(t, s.Background.Valid)
}

func TestProj11_CodexSubagentStopLowersCount(t *testing.T) {
	database, pid, row := codexRowFixture(t, codexExecSession)
	storeCodexState(t, database, pid, row, codexExecSession, agentStateWorking)
	stepClock(t)
	runCodexState(t, string(codexHookFixture(t, "subagent_start")))
	runCodexStop(t, codexPayload(t, "stop", map[string]any{"session_id": codexExecSession}))
	require.Equal(t, int64(1), codexRow(t, database, row).Background.Int64)

	runCodexState(t, string(codexHookFixture(t, "subagent_stop")))

	s := codexRow(t, database, row)
	assert.Equal(t, agentStateWaiting, s.AgentState.String)
	assert.Equal(t, sql.NullInt64{Int64: 0, Valid: true}, s.Background, "the closed turn no longer counts")
	turns, err := database.TerminalAgentTurns(row)
	require.NoError(t, err)
	assert.True(t, turns.Closed(codexSubagentID))
}

func TestProj11_CodexSubagentWithoutAgentIDWritesNothing(t *testing.T) {
	database, _, row := codexRowFixture(t, codexExecSession)
	before := rowSnapshot(t, database, row)
	runCodexState(t, codexPayload(t, "subagent_start", map[string]any{"agent_id": nil}))
	runCodexState(t, codexPayload(t, "subagent_stop", map[string]any{"agent_id": ""}))
	assert.Equal(t, before, rowSnapshot(t, database, row))
}

// A payload of another session, or any payload on a row with no id yet
// (spec I6), writes nothing.
// A dropped event of another session says so in one stderr line; a row
// with no id yet stays silent (#399 m5).
func TestProj11_CodexForeignSessionIDIgnored(t *testing.T) {
	for _, stored := range []string{"", briefClearedID} {
		database, _, row := codexRowFixture(t, stored)
		before := rowSnapshot(t, database, row)
		for _, name := range []string{"user_prompt_submit", "permission_request", "post_tool_use", "subagent_start", "subagent_stop"} {
			out, errOut := runCodexHook(t, string(codexHookFixture(t, name)), "session-state", "--agent", "codex")
			assert.Empty(t, out)
			assertForeignNote(t, errOut, stored, row, name)
		}
		out, errOut := runCodexStop(t, string(codexHookFixture(t, "stop")))
		assert.Empty(t, out)
		assertForeignNote(t, errOut, stored, row, "stop")
		assert.Equal(t, before, rowSnapshot(t, database, row), "stored %q", stored)
	}
}

// assertForeignNote: no line for a row with no id yet, else one line naming
// the row and both ids.
func assertForeignNote(t *testing.T, errOut, stored string, row int64, name string) {
	t.Helper()
	if stored == "" {
		assert.Empty(t, errOut, name)
		return
	}
	assert.Equal(t, 1, strings.Count(errOut, "\n"), "%s: %q", name, errOut)
	assert.Contains(t, errOut, "ignored: terminal session "+strconv.FormatInt(row, 10)+" stores session "+stored, name)
}

// Codex has no StopFailure or Notification: a payload naming one records
// nothing, and the Stop's waiting carries no error (business limit 1).
func TestProj11_CodexRowNeverGetsFailure(t *testing.T) {
	database, pid, row := codexRowFixture(t, codexTUISession)
	storeCodexState(t, database, pid, row, codexTUISession, agentStateWorking)
	before := rowSnapshot(t, database, row)
	for _, event := range []map[string]any{
		{"hook_event_name": "StopFailure", "error": "rate_limit"},
		{"hook_event_name": "Notification", "notification_type": "idle_prompt"},
		{"hook_event_name": "Notification", "notification_type": "permission_prompt"},
	} {
		runCodexState(t, codexPayload(t, "stop", event))
	}
	assert.Equal(t, before, rowSnapshot(t, database, row))

	runCodexStop(t, codexPayload(t, "stop", map[string]any{"error": "rate_limit"}))
	s := codexRow(t, database, row)
	assert.Equal(t, agentStateWaiting, s.AgentState.String)
	assert.Nil(t, s.AgentFailure)
}

// The Stop gate (HasCoreStateHooks reads settings.local.json) is true for a
// codex row by construction (spec §6.3).
func TestProj11_CodexStopGateTrueWithoutSettingsFile(t *testing.T) {
	database, pid, row := codexRowFixture(t, codexTUISession)
	wb, err := database.GetWorkbench(pid)
	require.NoError(t, err)
	_, err = os.Stat(filepath.Join(wb.FolderPath, ".claude", "settings.local.json"))
	require.ErrorIs(t, err, os.ErrNotExist)

	runCodexStop(t, string(codexHookFixture(t, "stop")))

	assert.Equal(t, agentStateWaiting, storedAgentState(t, database, row))
}

// The block JSON is the Claude Code Stop hook's, byte for byte, and
// stop_hook_active never blocks again (PROJ-07).
func TestProj07_CodexStopBlockShape(t *testing.T) {
	database := writeActionsConfig(t)
	pid, _ := driftWorkbench(t, database, driftRepo(t), "merged")
	claudeOut := stopHook(t, pid, `{"hook_event_name":"Stop","stop_hook_active":false}`)
	require.NotEmpty(t, claudeOut)
	row := codexRowIn(t, database, pid, codexTUISession)

	out, errOut := runCodexStop(t, string(codexHookFixture(t, "stop")))

	assert.Equal(t, claudeOut, out)
	assert.Empty(t, errOut)
	assert.False(t, codexRow(t, database, row).AgentState.Valid, "a blocked stop records no waiting")

	out, _ = runCodexStop(t, codexPayload(t, "stop", map[string]any{"stop_hook_active": true}))
	assert.Empty(t, out, "never blocks a continued turn")
	assert.Equal(t, agentStateWaiting, storedAgentState(t, database, row))
}

// --- Ask guard (§6.4) ---

func runCodexAskStop(t *testing.T, stdin string) (stdout, stderr string) {
	t.Helper()
	return runCodexHook(t, stdin, "ask-guard", "--agent", "codex", "--stop")
}

func runCodexAskTool(t *testing.T, stdin string) (stdout, stderr string) {
	t.Helper()
	return runCodexHook(t, stdin, "ask-guard", "--agent", "codex", "--pre-tool-use")
}

func TestProj13_CodexAskGuardStopUsesLastAssistantMessage(t *testing.T) {
	t.Run("present: the question is recorded", func(t *testing.T) {
		database, _, row := codexRowFixture(t, codexTUISession)
		setOwnerPresence(t, database, row, time.Now())
		gen := &stubAskGuardGen{reply: e1Verdict}
		useAskGuardGen(t, gen)

		out, errOut := runCodexAskStop(t, codexPayload(t, "stop", map[string]any{"last_assistant_message": e1Message}))

		assert.Empty(t, out)
		assert.Empty(t, errOut)
		assert.Equal(t, e1Message, gen.message, "the classifier reads last_assistant_message")
		q := storedChatQuestion(t, database, row)
		require.NotNil(t, q)
		assert.Equal(t, "Use snake_case or camelCase for the new keys?", q.Question)
	})
	t.Run("away: sent back", func(t *testing.T) {
		database, _, row := codexRowFixture(t, codexTUISession)
		useAskGuardGen(t, &stubAskGuardGen{reply: e1Verdict})

		out, _ := runCodexAskStop(t, codexPayload(t, "stop", map[string]any{"last_assistant_message": e1Message}))

		assert.Equal(t, guardBlock(t, askGuardReasonAway), out)
		assert.Nil(t, storedChatQuestion(t, database, row))
	})
	t.Run("continued turn: never blocks", func(t *testing.T) {
		_, _, _ = codexRowFixture(t, codexTUISession)
		useAskGuardGen(t, &stubAskGuardGen{reply: verdictJSON("full")})

		out, _ := runCodexAskStop(t, codexPayload(t, "stop", map[string]any{"stop_hook_active": true}))

		assert.Empty(t, out)
	})
}

func TestProj13_CodexAskGuardEmptyMessageNoModelCall(t *testing.T) {
	database, pid, row := codexRowFixture(t, codexTUISession)
	require.NoError(t, database.SetChatQuestion(row, pid, codexTUISession,
		db.ChatQuestion{Question: "An older question?"}, time.Now().Add(-time.Hour)))
	gen := &stubAskGuardGen{reply: e1Verdict}
	useAskGuardGen(t, gen)

	out, errOut := runCodexAskStop(t, codexPayload(t, "stop", map[string]any{"last_assistant_message": "  "}))

	assert.Empty(t, out)
	assert.Empty(t, errOut)
	assert.Zero(t, gen.calls)
	assert.Nil(t, storedChatQuestion(t, database, row), "the older question is cleared")
}

func TestProj13_CodexPreToolUseDeniesRequestUserInput(t *testing.T) {
	database, _, row := codexRowFixture(t, codexTUISession)
	ask := string(codexHookFixture(t, "pre_tool_use_request_user_input"))

	out, errOut := runCodexAskTool(t, ask)
	assert.Equal(t, denialWith(t, askToolDenialReasonAway), out)
	assert.Empty(t, errOut)

	setOwnerPresence(t, database, row, time.Now())
	out, _ = runCodexAskTool(t, ask)
	assert.Equal(t, denialWith(t, askToolDenialReasonPresent), out)

	for _, other := range []string{"Bash", "AskUserQuestion", "mcp__watchtower_workbench__ask_owner"} {
		out, _ = runCodexAskTool(t, codexPayload(t, "pre_tool_use_request_user_input", map[string]any{"tool_name": other}))
		assert.Empty(t, out, other)
	}
	out, _ = runCodexAskTool(t, string(codexHookFixture(t, "pre_tool_use_bash")))
	assert.Empty(t, out)
}

// The presence of another session never reads as here: a foreign id is
// denied with the away reason.
func TestProj13_CodexPreToolUseForeignSessionIsAway(t *testing.T) {
	database, _, row := codexRowFixture(t, briefClearedID)
	setOwnerPresence(t, database, row, time.Now())

	out, _ := runCodexAskTool(t, string(codexHookFixture(t, "pre_tool_use_request_user_input")))

	assert.Equal(t, denialWith(t, askToolDenialReasonAway), out)
}

// --- Session probe (§6.3) ---

func TestSessionProbe_CodexRowIsUnknownWithoutClaudeDir(t *testing.T) {
	database, pid, row := codexRowFixture(t, codexTUISession)
	ok, err := database.SetTerminalAgentState(row, pid, codexTUISession, agentStateWaiting, time.Now().Add(-time.Hour), "",
		nil, false, db.AgentOrder{Stop: true, Background: sql.NullInt64{Int64: 2, Valid: true}})
	require.NoError(t, err)
	require.True(t, ok)
	origDir := terminalClaudeDir
	terminalClaudeDir = func() string { t.Error("a codex row read the claude dir"); return "" }
	t.Cleanup(func() { terminalClaudeDir = origDir })

	got := runSessionProbe(t, pid, row)

	assert.Equal(t, true, got["ok"])
	assert.Equal(t, probeUnknown, got["outcome"])
	assert.Equal(t, true, got["ended"])
	s := codexRow(t, database, row)
	assert.False(t, s.Background.Valid, "the count ended")
	assert.Equal(t, agentStateWaiting, s.AgentState.String)
}

// hookSessionRow takes any agent's row: a nested `claude` the codex agent
// runs inherits the row's env var, and its Claude Code state, Stop and ask
// guard hooks must leave a codex row alone whether it stores an id yet or
// not (#399 m6).
func TestProj11_NestedClaudeHooksNeverTouchACodexRow(t *testing.T) {
	database, pid, _ := codexRowFixture(t, "")
	installBriefStateHooks(t, database, pid)
	wb := strconv.FormatInt(pid, 10)
	for _, stored := range []string{"", codexTUISession} {
		row := codexRowIn(t, database, pid, stored)
		before := rowSnapshot(t, database, row)
		for _, tc := range []struct{ event, notification string }{
			{"UserPromptSubmit", ""}, {"Notification", "permission_prompt"}, {"PostToolUse", ""},
			{"SubagentStart", ""}, {"SubagentStop", ""}, {"StopFailure", ""},
		} {
			out, _, err := runSessionState(t, pid, strings.NewReader(statePayload(tc.event, nestedSessionID, tc.notification)))
			require.NoError(t, err, tc.event)
			assert.Empty(t, out, tc.event)
		}
		stop := `{"session_id":"` + nestedSessionID + `","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":""}`
		out, _, err := runWorkbenchCheckCmd(t, strings.NewReader(stop), "check", "--workbench", wb, "--stop-hook")
		require.NoError(t, err)
		assert.Empty(t, out, "Stop")
		out, _, err = runAskGuardStopHook(t, wb, strings.NewReader(stop))
		require.NoError(t, err)
		assert.Empty(t, out, "ask guard Stop")
		assert.Equal(t, before, rowSnapshot(t, database, row), "stored %q", stored)
	}
}
