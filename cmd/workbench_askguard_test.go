package cmd

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/asks"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/devpack"
	"watchtower/internal/digest"
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

	// --stop (spec 2026-10-10-owner-asks-v2 Part 4.6): an input or model
	// failure prints nothing, so the turn ends, and records or clears
	// nothing; the owner is present and the message asks a short question.
	origBudget := askGuardModelBudget
	askGuardModelBudget = 50 * time.Millisecond
	t.Cleanup(func() { askGuardModelBudget = origBudget })
	for _, tc := range []struct {
		name  string
		gen   *stubAskGuardGen
		stdin func(t *testing.T) io.Reader
	}{
		{"stop: no input", &stubAskGuardGen{reply: e1Verdict}, func(*testing.T) io.Reader { return strings.NewReader("") }},
		{"stop: unreadable input", &stubAskGuardGen{reply: e1Verdict}, func(*testing.T) io.Reader { return strings.NewReader("not json") }},
		{"stop: input never closed", &stubAskGuardGen{reply: e1Verdict}, func(t *testing.T) io.Reader {
			r, w := io.Pipe()
			t.Cleanup(func() { _ = w.Close() })
			return r
		}},
		{"stop: model timeout", &stubAskGuardGen{block: true}, nil},
		{"stop: model error", &stubAskGuardGen{err: errors.New("provider down")}, nil},
		{"stop: prose output", &stubAskGuardGen{reply: "The message asks the owner a question."}, nil},
		{"stop: malformed output", &stubAskGuardGen{reply: `{"request": 7}`}, nil},
		{"stop: panic", &stubAskGuardGen{boom: true}, nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			database, pid, row := stopGuardFixture(t)
			setOwnerPresence(t, database, row, time.Now())
			seedOlderQuestion(t, database, pid, row)
			useAskGuardGen(t, tc.gen)
			var in io.Reader = strings.NewReader(guardPayload(e1Message, false))
			if tc.stdin != nil {
				in = tc.stdin(t)
			}

			out, _, err := runAskGuardStopHook(t, strconv.FormatInt(pid, 10), in)

			require.NoError(t, err, "PROJ-13: the hook always exits 0")
			assert.Empty(t, out, "PROJ-13: nothing on stdout ends the turn")
			q := storedChatQuestion(t, database, row)
			require.NotNil(t, q, "nothing cleared")
			assert.Equal(t, "An older question?", q.Question, "nothing recorded")
		})
	}
	t.Run("stop: bad id and broken config", func(t *testing.T) {
		useAskGuardGen(t, &stubAskGuardGen{reply: e1Verdict})
		for _, raw := range []string{"seven", "0", ""} {
			stopGuardFixture(t)
			out, _, err := runAskGuardStopHook(t, raw, strings.NewReader(guardPayload(e1Message, false)))
			require.NoError(t, err)
			assert.Empty(t, out, raw)
		}
		_, pid, _ := stopGuardFixture(t)
		brokenConfig(t)
		out, _, err := runAskGuardStopHook(t, strconv.FormatInt(pid, 10), strings.NewReader(guardPayload(e1Message, false)))
		require.NoError(t, err)
		assert.Empty(t, out)
	})
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

	// --stop, in a Desktop terminal and with a short question: no database
	// reads as away, and still nothing is created.
	t.Setenv(terminalSessionEnv, "1")
	useAskGuardGen(t, &stubAskGuardGen{reply: e1Verdict})
	out, _, err = runAskGuardStopHook(t, "1", strings.NewReader(guardPayload(e1Message, false)))
	require.NoError(t, err)
	assert.Equal(t, guardBlock(t, askGuardReasonAway), out)
	_, statErr = os.Stat(cfg.WorkspaceDir())
	assert.True(t, os.IsNotExist(statErr), "PROJ-13: the Stop guard created %s", cfg.WorkspaceDir())
	_, statErr = os.Stat(cfg.DBPath())
	assert.True(t, os.IsNotExist(statErr), "PROJ-13: the Stop guard created the database")
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

	// --stop: the guard records from the columns that are there and leaves
	// the goose version where it was.
	_, err = database.Exec(`DELETE FROM goose_db_version WHERE version_id = ?`, after)
	require.NoError(t, err)
	folder := t.TempDir()
	stopPID, err := database.CreateWorkbench("stop", folder)
	require.NoError(t, err)
	_, err = devpack.InstallStateHooks(folder, "watchtower", stopPID)
	require.NoError(t, err)
	res, err := database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, 'claude', 's', ?, ?)`, stopPID, folder, briefLaunchID)
	require.NoError(t, err)
	row, err := res.LastInsertId()
	require.NoError(t, err)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	setOwnerPresence(t, database, row, time.Now())
	useAskGuardGen(t, &stubAskGuardGen{reply: e1Verdict})
	var before int64
	require.NoError(t, database.QueryRow(`SELECT MAX(version_id) FROM goose_db_version`).Scan(&before))

	out, _, err = runAskGuardStopHook(t, strconv.FormatInt(stopPID, 10), strings.NewReader(guardPayload(e1Message, false)))

	require.NoError(t, err)
	assert.Empty(t, out, "the present owner's question passes")
	assert.NotNil(t, storedChatQuestion(t, database, row), "and is recorded")
	var afterStop int64
	require.NoError(t, database.QueryRow(`SELECT MAX(version_id) FROM goose_db_version`).Scan(&afterStop))
	assert.Equal(t, before, afterStop, "PROJ-13: the Stop guard applied a pending migration")
}

// A database another process holds exclusively: the guard gives up within
// its busy timeout and lets the tool run, well inside 2 s.
func TestProj13_AskGuardFinishesFastOnALockedDatabase(t *testing.T) {
	t.Run("pre-tool-use", func(t *testing.T) {
		database := writeActionsConfig(t)
		id, err := database.CreateWorkbench("acme", t.TempDir())
		require.NoError(t, err)
		lockDatabase(t, database)

		start := time.Now()
		out, errOut, err := runAskGuard(t, strconv.FormatInt(id, 10), strings.NewReader(askToolPayload("AskUserQuestion")))

		assert.Less(t, time.Since(start), 2*time.Second)
		require.NoError(t, err)
		assert.Empty(t, out)
		assert.Empty(t, errOut)
	})
	// --stop with a stub model: the locked database reads as the owner being
	// away, decided within the stub's time plus 2 s.
	t.Run("stop", func(t *testing.T) {
		database, pid, row := stopGuardFixture(t)
		setOwnerPresence(t, database, row, time.Now())
		useAskGuardGen(t, &stubAskGuardGen{reply: e1Verdict})
		lockDatabase(t, database)

		start := time.Now()
		out, _, err := runAskGuardStopHook(t, strconv.FormatInt(pid, 10), strings.NewReader(guardPayload(e1Message, false)))

		assert.Less(t, time.Since(start), 2*time.Second)
		require.NoError(t, err)
		assert.Equal(t, guardBlock(t, askGuardReasonAway), out)
	})
}

// lockDatabase makes database's handle hold the file exclusively until the
// test ends.
func lockDatabase(t *testing.T, database *db.DB) {
	t.Helper()
	_, err := database.Exec(`PRAGMA locking_mode=EXCLUSIVE`)
	require.NoError(t, err)
	tx, err := database.Begin()
	require.NoError(t, err)
	t.Cleanup(func() { _ = tx.Rollback() })
	_, err = tx.Exec(`UPDATE projects SET name = name`)
	require.NoError(t, err)
}

func TestAskGuard_WithoutThePreToolUseFlagIsAnError(t *testing.T) {
	writeActionsConfig(t)
	out, _, err := runWorkbenchAs(t, "workbench", "ask-guard", "--workbench", "1")
	require.Error(t, err)
	assert.NotContains(t, out, "hookSpecificOutput")
}

// --- The Stop ask guard (spec 2026-10-10-owner-asks-v2 Part 4) ---

// stubAskGuardGen stands in for the classifier's model client: no test calls
// a real model. block waits for the call's context (a model timeout or a
// signal); boom panics.
type stubAskGuardGen struct {
	reply   string
	err     error
	block   bool
	boom    bool
	calls   int
	source  string
	system  string
	message string
}

func (g *stubAskGuardGen) Generate(ctx context.Context, system, user, _ string) (string, *digest.Usage, string, error) {
	g.calls++
	g.source, _ = digest.SourceFromContext(ctx)
	g.system, g.message = system, user
	switch {
	case g.boom:
		panic("boom")
	case g.block:
		<-ctx.Done()
		return "", nil, "", ctx.Err()
	case g.err != nil:
		return "", nil, "", g.err
	}
	return g.reply, &digest.Usage{}, "", nil
}

// useAskGuardGen makes the guard's classifier calls go to gen.
func useAskGuardGen(t *testing.T, gen digest.Generator) {
	t.Helper()
	orig := askGuardGeneratorFactory
	askGuardGeneratorFactory = func(*config.Config) digest.Generator { return gen }
	t.Cleanup(func() { askGuardGeneratorFactory = orig })
}

// verdictJSON is a classifier reply: request with the named flags set.
func verdictJSON(request string, flags ...string) string {
	m := map[string]any{"request": request, "question": "", "options": []any{}}
	for _, f := range flags {
		m[f] = true
	}
	b, _ := json.Marshal(m)
	return string(b)
}

// chatVerdictJSON is a chat request asking question with options.
func chatVerdictJSON(question string, options []string, flags ...string) string {
	m := map[string]any{"request": "chat", "question": question}
	var opts []map[string]any
	for i, o := range options {
		opts = append(opts, map[string]any{"label": o, "recommended": i == 0})
	}
	m["options"] = opts
	for _, f := range flags {
		m[f] = true
	}
	b, _ := json.Marshal(m)
	return string(b)
}

// guardPayload is a Stop hook input of conversation briefLaunchID.
func guardPayload(message string, active bool) string {
	b, _ := json.Marshal(map[string]any{
		"session_id": briefLaunchID, "transcript_path": "/tmp/example/t.jsonl", "cwd": "/tmp/example",
		"hook_event_name": "Stop", "stop_hook_active": active, "last_assistant_message": message,
	})
	return string(b)
}

// stopGuardFixture is a workbench whose folder has the session state hooks
// and a claude row of conversation briefLaunchID, the hook's env pointing at
// it.
func stopGuardFixture(t *testing.T) (database *db.DB, pid, row int64) {
	t.Helper()
	database = writeActionsConfig(t)
	folder := t.TempDir()
	var err error
	pid, err = database.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	_, err = devpack.InstallStateHooks(folder, "watchtower", pid)
	require.NoError(t, err)
	res, err := database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, 'claude', 's', ?, ?)`, pid, folder, briefLaunchID)
	require.NoError(t, err)
	row, err = res.LastInsertId()
	require.NoError(t, err)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	return database, pid, row
}

// setOwnerPresence writes the Desktop's presence row: the owner in session
// (nil = none), seen at.
func setOwnerPresence(t *testing.T, database *db.DB, session any, at time.Time) {
	t.Helper()
	_, err := database.Exec(`INSERT INTO owner_presence (id, session_id, seen_at) VALUES (1, ?, ?)
		ON CONFLICT(id) DO UPDATE SET session_id = excluded.session_id, seen_at = excluded.seen_at`,
		session, db.AgentStateStamp(at))
	require.NoError(t, err)
}

// runAskGuardStopHook runs `workbench ask-guard --workbench <raw> --stop`
// the way the hook does: the input on stdin.
func runAskGuardStopHook(t *testing.T, raw string, stdin io.Reader) (stdout, stderr string, err error) {
	t.Helper()
	rootCmd.SetIn(stdin)
	t.Cleanup(func() { rootCmd.SetIn(nil) })
	return runWorkbenchAs(t, "workbench", "ask-guard", "--workbench", raw, "--stop")
}

// guardBlock is the hook's stdout for a block with reason.
func guardBlock(t *testing.T, reason string) string {
	t.Helper()
	b, err := json.Marshal(stopHookOutput{Decision: "block", Reason: reason})
	require.NoError(t, err)
	return string(b) + "\n"
}

// storedChatQuestion reads row's chat question; nil when there is none.
func storedChatQuestion(t *testing.T, database *db.DB, row int64) *db.ChatQuestion {
	t.Helper()
	var body sql.NullString
	require.NoError(t, database.QueryRow(`SELECT chat_question FROM terminal_sessions WHERE id = ?`, row).Scan(&body))
	if !body.Valid {
		return nil
	}
	var q db.ChatQuestion
	require.NoError(t, json.Unmarshal([]byte(body.String), &q))
	return &q
}

// seedOlderQuestion records a question on row from a Stop an hour ago.
func seedOlderQuestion(t *testing.T, database *db.DB, pid, row int64) {
	t.Helper()
	require.NoError(t, database.SetChatQuestion(row, pid, briefLaunchID,
		db.ChatQuestion{Question: "An older question?"}, time.Now().Add(-time.Hour)))
}

const (
	e1Message = "Use `snake_case` or `camelCase` for the new keys?"
	e1Verdict = `{"request":"chat","names_ask":false,"request_outside_ask":false,"closing_summary":false,` +
		`"complete_unreported":false,"question":"Use snake_case or camelCase for the new keys?",` +
		`"options":[{"label":"snake_case","recommended":false},{"label":"camelCase","recommended":false}]}`
)

// TestProj13_StopGuardDecisionTable is every row of Part 4.5 (E1-E9c) with a
// stub model and seeded presence: what the hook prints, whether it records
// the question, and that every outcome recording nothing clears the older
// question.
func TestProj13_StopGuardDecisionTable(t *testing.T) {
	branchQ := chatVerdictJSON("Which branch name do you prefer?", []string{"feat/x", "fix/x"}, "names_ask", "request_outside_ask")
	for _, tc := range []struct {
		name    string
		verdict string
		present bool
		want    string // the block reason; "" = pass
		record  string // the recorded question; "" = none (the older one cleared)
	}{
		{"E1 present, a short question", e1Verdict, true, "", "Use snake_case or camelCase for the new keys?"},
		{"E2 absent, a short question", e1Verdict, false, askGuardReasonAway, ""},
		{"E5 present, a review request", verdictJSON("full"), true, askGuardReasonFull, ""},
		{"E6 present, three decisions", verdictJSON("full"), true, askGuardReasonFull, ""},
		{"E7 a question beside a named ask, present", branchQ, true, "", "Which branch name do you prefer?"},
		{"E7 a question beside a named ask, absent", branchQ, false, askGuardReasonAway, ""},
		{"E7a a named ask and help on it", verdictJSON("chat", "names_ask"), false, "", ""},
		{"E7a covered full request", verdictJSON("full", "names_ask"), false, "", ""},
		{"E7b a named ask plus a review request", verdictJSON("full", "names_ask", "request_outside_ask"), true, askGuardReasonFull, ""},
		{"E8 all done without finish_session", verdictJSON("none", "complete_unreported"), true, askGuardReasonFinish, ""},
		{"E8a a chat candidate and all done", chatVerdictJSON("Ship it?", nil, "complete_unreported"), true, askGuardReasonFinishAsk, ""},
		{"E9 a question and all done, absent", chatVerdictJSON("Ship it?", nil, "complete_unreported"), false, askGuardReasonAway, ""},
		{"E9a a question in a progress report, absent", chatVerdictJSON("Should the badge be red or orange?", []string{"red", "orange"}), false, askGuardReasonAway, ""},
		{"E9b a closing summary, absent", chatVerdictJSON("Review the two items?", nil, "closing_summary"), false, "", ""},
		{"E9b a closing summary listing a full request", verdictJSON("full", "closing_summary"), false, "", ""},
		{"E9c a progress report", verdictJSON("none"), false, "", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			database, pid, row := stopGuardFixture(t)
			if tc.present {
				setOwnerPresence(t, database, row, time.Now())
			}
			seedOlderQuestion(t, database, pid, row)
			useAskGuardGen(t, &stubAskGuardGen{reply: tc.verdict})

			out, _, err := runAskGuardStopHook(t, strconv.FormatInt(pid, 10), strings.NewReader(guardPayload("the message", false)))

			require.NoError(t, err)
			if tc.want == "" {
				assert.Empty(t, out)
			} else {
				assert.Equal(t, guardBlock(t, tc.want), out)
			}
			q := storedChatQuestion(t, database, row)
			if tc.record == "" {
				assert.Nil(t, q, "nothing recorded, and the older question cleared")
			} else if assert.NotNil(t, q) {
				assert.Equal(t, tc.record, q.Question)
			}
		})
	}

	t.Run("E1 records both options", func(t *testing.T) {
		database, pid, row := stopGuardFixture(t)
		setOwnerPresence(t, database, row, time.Now())
		useAskGuardGen(t, &stubAskGuardGen{reply: e1Verdict})
		out, _, err := runAskGuardStopHook(t, strconv.FormatInt(pid, 10), strings.NewReader(guardPayload(e1Message, false)))
		require.NoError(t, err)
		assert.Empty(t, out)
		q := storedChatQuestion(t, database, row)
		require.NotNil(t, q)
		assert.Equal(t, []db.ChatQuestionOption{{Label: "snake_case"}, {Label: "camelCase"}}, q.Options)
	})

	t.Run("row 9 a record that fails is sent back", func(t *testing.T) {
		database, pid, row := stopGuardFixture(t)
		setOwnerPresence(t, database, row, time.Now())
		// A prompt stamped after this Stop: the record is refused as stale.
		_, err := database.Exec(`UPDATE terminal_sessions SET agent_state = 'working', agent_state_at = ? WHERE id = ?`,
			db.AgentStateStamp(time.Now().Add(time.Minute)), row)
		require.NoError(t, err)
		useAskGuardGen(t, &stubAskGuardGen{reply: e1Verdict})
		out, _, err := runAskGuardStopHook(t, strconv.FormatInt(pid, 10), strings.NewReader(guardPayload(e1Message, false)))
		require.NoError(t, err)
		assert.Equal(t, guardBlock(t, askGuardReasonAway), out)
		assert.Nil(t, storedChatQuestion(t, database, row))
	})

	t.Run("the classifier gets the v4 text and the message", func(t *testing.T) {
		database, pid, row := stopGuardFixture(t)
		setOwnerPresence(t, database, row, time.Now())
		gen := &stubAskGuardGen{reply: verdictJSON("none")}
		useAskGuardGen(t, gen)
		_, _, err := runAskGuardStopHook(t, strconv.FormatInt(pid, 10), strings.NewReader(guardPayload(e1Message, false)))
		require.NoError(t, err)
		assert.Equal(t, devpack.AskGuardClassifier, gen.system)
		assert.Equal(t, e1Message, gen.message)
		assert.Equal(t, askGuardSource, gen.source)
	})

	t.Run("an empty message calls no model and clears", func(t *testing.T) {
		database, pid, row := stopGuardFixture(t)
		seedOlderQuestion(t, database, pid, row)
		gen := &stubAskGuardGen{reply: e1Verdict}
		useAskGuardGen(t, gen)
		out, _, err := runAskGuardStopHook(t, strconv.FormatInt(pid, 10), strings.NewReader(guardPayload("  ", false)))
		require.NoError(t, err)
		assert.Empty(t, out)
		assert.Zero(t, gen.calls)
		assert.Nil(t, storedChatQuestion(t, database, row))
	})
}

// The pure table, over the resolution flags the hook test cannot reach one
// by one.
func TestDecideStopTable(t *testing.T) {
	chat := &askGuardVerdict{Request: askRequestChat, Question: "Q?"}
	present := askGuardResolution{Matched: true, Recordable: true, Present: true}
	for _, tc := range []struct {
		name   string
		active bool
		v      *askGuardVerdict
		r      askGuardResolution
		want   stopDecision
	}{
		{"model failure", false, nil, present, stopDecision{}},
		{"present and recordable", false, chat, present, stopDecision{Record: true}},
		{"present, no core hooks", false, chat, askGuardResolution{Matched: true, Present: true}, stopDecision{Reason: askGuardReasonAway, Clear: true}},
		{"continued, away but recordable", true, chat, askGuardResolution{Matched: true, Recordable: true}, stopDecision{Record: true}},
		{"continued, not recordable", true, chat, askGuardResolution{}, stopDecision{Clear: true}},
		{"continued, a full request", true, &askGuardVerdict{Request: askRequestFull}, present, stopDecision{Clear: true}},
		{"continued, complete", true, &askGuardVerdict{Request: askRequestNone, CompleteUnreported: true}, present, stopDecision{Clear: true}},
		{"continued, covered chat", true, &askGuardVerdict{Request: askRequestChat, Question: "Q?", NamesAsk: true}, present, stopDecision{Clear: true}},
	} {
		assert.Equal(t, tc.want, decideStop(tc.active, false, tc.v, tc.r), tc.name)
	}
	assert.Equal(t, stopDecision{Clear: true}, decideStop(false, true, nil, present), "an empty message")
}

// PROJ-13: a short question passes as text only when the owner is present
// in this session and it is recorded; every other case (E2-E4, E10d, no
// env, a nested session, a read error, a write error, missing columns) sends
// it back with R-away and records nothing.
func TestProj13_ChatPassesOnlyWhenPresentAndRecorded(t *testing.T) {
	for _, tc := range []struct {
		name  string
		setup func(t *testing.T, database *db.DB, pid, row int64) (payload string)
		pass  bool
	}{
		{"present", func(t *testing.T, database *db.DB, _, row int64) string {
			setOwnerPresence(t, database, row, time.Now())
			return guardPayload(e1Message, false)
		}, true},
		{"E2 no presence row", func(*testing.T, *db.DB, int64, int64) string { return guardPayload(e1Message, false) }, false},
		{"in no session", func(t *testing.T, database *db.DB, _, _ int64) string {
			setOwnerPresence(t, database, nil, time.Now())
			return guardPayload(e1Message, false)
		}, false},
		{"E3 another session present", func(t *testing.T, database *db.DB, pid, _ int64) string {
			other, err := database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
				VALUES (?, 'claude', 'other', '/tmp/example', 'other-uuid')`, pid)
			require.NoError(t, err)
			id, err := other.LastInsertId()
			require.NoError(t, err)
			setOwnerPresence(t, database, id, time.Now())
			return guardPayload(e1Message, false)
		}, false},
		{"E4 a presence write 91 s old", func(t *testing.T, database *db.DB, _, row int64) string {
			setOwnerPresence(t, database, row, time.Now().Add(-91*time.Second))
			return guardPayload(e1Message, false)
		}, false},
		{"no env", func(t *testing.T, database *db.DB, _, row int64) string {
			setOwnerPresence(t, database, row, time.Now())
			unsetTerminalEnv(t)
			return guardPayload(e1Message, false)
		}, false},
		{"a nested session", func(t *testing.T, database *db.DB, _, row int64) string {
			setOwnerPresence(t, database, row, time.Now())
			return strings.Replace(guardPayload(e1Message, false), briefLaunchID, nestedSessionID, 1)
		}, false},
		{"another workbench's row", func(t *testing.T, database *db.DB, _, row int64) string {
			setOwnerPresence(t, database, row, time.Now())
			other, err := database.CreateWorkbench("other", t.TempDir())
			require.NoError(t, err)
			_, err = database.Exec(`UPDATE terminal_sessions SET project_id = ? WHERE id = ?`, other, row)
			require.NoError(t, err)
			return guardPayload(e1Message, false)
		}, false},
		{"E10d no core state hooks", func(t *testing.T, database *db.DB, pid, row int64) string {
			setOwnerPresence(t, database, row, time.Now())
			require.NoError(t, os.Remove(filepath.Join(mustFolder(t, database, pid), ".claude", "settings.local.json")))
			return guardPayload(e1Message, false)
		}, false},
		{"a read error", func(t *testing.T, database *db.DB, _, row int64) string {
			setOwnerPresence(t, database, row, time.Now())
			// A view over a dropped table: every read of it fails.
			for _, q := range []string{
				`DROP TABLE owner_presence`,
				`CREATE TABLE presence_src (id INTEGER, session_id INTEGER, seen_at TEXT)`,
				`CREATE VIEW owner_presence AS SELECT id, session_id, seen_at FROM presence_src`,
				`DROP TABLE presence_src`,
			} {
				_, err := database.Exec(q)
				require.NoError(t, err, q)
			}
			return guardPayload(e1Message, false)
		}, false},
		{"a write error", func(t *testing.T, database *db.DB, _, row int64) string {
			setOwnerPresence(t, database, row, time.Now())
			_, err := database.Exec(`CREATE TRIGGER refuse_chat_question BEFORE UPDATE OF chat_question ON terminal_sessions
				BEGIN SELECT RAISE(ABORT, 'refused'); END`)
			require.NoError(t, err)
			return guardPayload(e1Message, false)
		}, false},
		{"missing columns", func(t *testing.T, database *db.DB, _, _ int64) string {
			_, err := database.Exec(`DROP TABLE owner_presence`)
			require.NoError(t, err)
			return guardPayload(e1Message, false)
		}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			database, pid, row := stopGuardFixture(t)
			payload := tc.setup(t, database, pid, row)
			useAskGuardGen(t, &stubAskGuardGen{reply: e1Verdict})

			out, _, err := runAskGuardStopHook(t, strconv.FormatInt(pid, 10), strings.NewReader(payload))

			require.NoError(t, err)
			if tc.pass {
				assert.Empty(t, out)
				q := storedChatQuestion(t, database, row)
				require.NotNil(t, q, "a passed question is recorded")
				assert.Equal(t, "Use snake_case or camelCase for the new keys?", q.Question)
				return
			}
			assert.Equal(t, guardBlock(t, askGuardReasonAway), out)
			var body sql.NullString
			require.NoError(t, database.QueryRow(`SELECT chat_question FROM terminal_sessions WHERE id = ?`, row).Scan(&body))
			assert.False(t, body.Valid, "nothing recorded")
		})
	}
}

// PROJ-13 row 1 (E10b): with stop_hook_active the guard never blocks,
// whatever the verdict; a chat request is still recorded, the owner present
// or away.
func TestProj13_ContinuedTurnNeverBlocks(t *testing.T) {
	for _, verdict := range []string{
		e1Verdict,
		verdictJSON("full"),
		verdictJSON("none", "complete_unreported"),
		chatVerdictJSON("Ship it?", nil, "complete_unreported"),
		verdictJSON("full", "names_ask", "request_outside_ask"),
		verdictJSON("none"),
	} {
		for _, present := range []bool{true, false} {
			t.Run(fmt.Sprintf("%s present=%v", verdict, present), func(t *testing.T) {
				database, pid, row := stopGuardFixture(t)
				if present {
					setOwnerPresence(t, database, row, time.Now())
				}
				useAskGuardGen(t, &stubAskGuardGen{reply: verdict})

				out, _, err := runAskGuardStopHook(t, strconv.FormatInt(pid, 10), strings.NewReader(guardPayload("the message", true)))

				require.NoError(t, err)
				assert.Empty(t, out, "PROJ-13: a continued turn is never blocked")
				q := storedChatQuestion(t, database, row)
				if verdict == e1Verdict || strings.Contains(verdict, "Ship it?") {
					require.NotNil(t, q, "a chat request is recorded on the continued turn")
				} else {
					assert.Nil(t, q)
				}
			})
		}
	}
}

// E10c: the drift check blocks the Stop on which the guard recorded a
// question; the agent's next Stop, with no question, clears it. A Stop the
// guard itself blocks clears an older question too. The inputs are the
// captured fixture of TestStopHookInputParsesTheCapturedFixtures.
func TestStopWithoutAQuestionClearsTheOlderOne(t *testing.T) {
	raw, err := os.ReadFile("testdata/stop_no_background_tasks.json")
	require.NoError(t, err)
	var fixture map[string]any
	require.NoError(t, json.Unmarshal(raw, &fixture))
	claudeID := fixture["session_id"].(string)
	input := func(message string, active bool) string {
		fixture["last_assistant_message"], fixture["stop_hook_active"] = message, active
		b, err := json.Marshal(fixture)
		require.NoError(t, err)
		return string(b)
	}

	database := writeActionsConfig(t)
	folder := driftRepo(t)
	pid, _ := driftWorkbench(t, database, folder, "merged")
	_, err = devpack.InstallStateHooks(folder, "watchtower", pid)
	require.NoError(t, err)
	res, err := database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
		VALUES (?, 'claude', 's', ?, ?)`, pid, folder, claudeID)
	require.NoError(t, err)
	row, err := res.LastInsertId()
	require.NoError(t, err)
	t.Setenv(terminalSessionEnv, strconv.FormatInt(row, 10))
	stepClock(t)
	raw10 := strconv.FormatInt(pid, 10)
	gen := &stubAskGuardGen{}
	useAskGuardGen(t, gen)

	// The Stop: the guard records the question, the drift check blocks it.
	setOwnerPresence(t, database, row, time.Now())
	gen.reply = e1Verdict
	out, _, err := runAskGuardStopHook(t, raw10, strings.NewReader(input(e1Message, false)))
	require.NoError(t, err)
	require.Empty(t, out)
	require.NotNil(t, storedChatQuestion(t, database, row), "recorded")
	drift, _ := stopHookIO(t, raw10, input(e1Message, false))
	require.Contains(t, drift, `"decision":"block"`, "the drift check blocks the same Stop")

	// The agent fixes the board; its next Stop asks nothing.
	gen.reply = verdictJSON("none")
	out, _, err = runAskGuardStopHook(t, raw10, strings.NewReader(input("Board fixed.", true)))
	require.NoError(t, err)
	assert.Empty(t, out)
	assert.Nil(t, storedChatQuestion(t, database, row), "the next Stop with no question clears it")

	// A Stop the guard blocks clears an older question too.
	gen.reply = e1Verdict
	_, _, err = runAskGuardStopHook(t, raw10, strings.NewReader(input(e1Message, false)))
	require.NoError(t, err)
	require.NotNil(t, storedChatQuestion(t, database, row))
	gen.reply = verdictJSON("full")
	out, _, err = runAskGuardStopHook(t, raw10, strings.NewReader(input("Please review docs/plan.md.", false)))
	require.NoError(t, err)
	assert.Equal(t, guardBlock(t, askGuardReasonFull), out)
	assert.Nil(t, storedChatQuestion(t, database, row), "a blocked Stop clears the older question")
}

// E10e and Part 4.3 (F3): the model's question and options are normalised in
// a fixed order, and the result always passes asks.Validate with origin chat.
func TestAskGuardModelOutputNormalisation(t *testing.T) {
	long := strings.Repeat("é", 310)
	label := strings.Repeat("x", 45)
	v, err := decodeAskGuardVerdict("```json\n" + `{"request":"chat","question":"Line one\nline   two ` + long + `",
		"options":[{"label":"  Yes "},{"label":"yes","recommended":true},{"label":"Yes "},{"label":""},{"label":"   "},
		{"label":"No"},{"label":"` + label + `"},{"label":"Maybe"},{"label":"Later"},{"label":"Never"}]}` + "\n```")
	require.NoError(t, err)
	assert.Equal(t, askRequestChat, v.Request)
	assert.Equal(t, 300, utf8.RuneCountInString(v.Question))
	assert.True(t, strings.HasPrefix(v.Question, "Line one line two é"), "one line, whitespace collapsed")
	assert.Equal(t, []db.ChatQuestionOption{
		{Label: "Yes", Recommended: true}, {Label: "No"}, {Label: strings.Repeat("x", 40)}, {Label: "Maybe"},
	}, v.Options, "trimmed, clipped to 40, empty dropped, duplicates folded with recommended OR-ed, first 4 kept")

	one, err := decodeAskGuardVerdict(`{"request":"chat","question":"Host name?","options":[{"label":"Yes"},{"label":"yes "}]}`)
	require.NoError(t, err)
	assert.Empty(t, one.Options, "a single remaining option becomes none")

	for reply, want := range map[string]string{
		`{"request":"maybe"}`:                  askRequestNone,
		`{"request":""}`:                       askRequestNone,
		`{"request":"chat","question":"   "}`:  askRequestFull,
		`{"request":"chat"}`:                   askRequestFull,
		`{"request":"full","question":"Why?"}`: askRequestFull,
		`{"request":"none"}`:                   askRequestNone,
	} {
		v, err := decodeAskGuardVerdict(reply)
		require.NoError(t, err, reply)
		assert.Equal(t, want, v.Request, reply)
	}

	for _, bad := range []string{"", "Sure, the message asks a question.", `{"names_ask":true}`, `{"request":1}`,
		`{"request":"none"} trailing`, `[{"request":"none"}]`, `{"request":"chat","options":"a,b"}`} {
		_, err := decodeAskGuardVerdict(bad)
		assert.Error(t, err, "%q is not a verdict", bad)
	}

	// The normalised options always make a valid chat-origin ask question.
	for _, opts := range [][]string{nil, {"a"}, {"a", "A"}, {"a", "b"}, {"a", "b", "c", "d", "e"}} {
		var list []map[string]any
		for _, o := range opts {
			list = append(list, map[string]any{"label": o})
		}
		b, _ := json.Marshal(map[string]any{"request": "chat", "question": "Q?", "options": list})
		v, err := decodeAskGuardVerdict(string(b))
		require.NoError(t, err)
		var aOpts []asks.Option
		for _, o := range v.Options {
			aOpts = append(aOpts, asks.Option{Label: o.Label, Recommended: o.Recommended})
		}
		_, verr := asks.Validate(asks.Input{Kind: "question", Title: "Q?",
			Questions: []asks.Question{{ID: "q1", Question: v.Question, Options: aOpts}}}, asks.OriginChat)
		assert.NoError(t, verr, "options %v", opts)
	}
}

// PROJ-13: the guard writes only the chat question — never agent_state, its
// time, finished_at, the turn order, the background count or the error.
func TestProj13_StopGuardNeverTouchesTheStateColumns(t *testing.T) {
	database, pid, row := stopGuardFixture(t)
	at := db.AgentStateStamp(time.Now().Add(-time.Minute))
	_, err := database.Exec(`UPDATE terminal_sessions SET agent_state = 'waiting', agent_state_at = ?, finished_at = ?,
		finish_summary = 'done', agent_failed_at = ?, agent_error = 'overloaded', agent_turn_end = 4096, agent_tool_run = 1,
		agent_background = 2, agent_background_at = ? WHERE id = ?`, at, at, at, at, row)
	require.NoError(t, err)
	state := func() string {
		t.Helper()
		var cols [10]sql.NullString
		ptrs := make([]any, len(cols))
		for i := range cols {
			ptrs[i] = &cols[i]
		}
		require.NoError(t, database.QueryRow(`SELECT agent_state, agent_state_at, finished_at, finish_summary,
			agent_failed_at, agent_error, agent_turn_end, agent_tool_run, agent_background, agent_background_at
			FROM terminal_sessions WHERE id = ?`, row).Scan(ptrs...))
		return fmt.Sprint(cols)
	}
	want := state()
	setOwnerPresence(t, database, row, time.Now())
	gen := &stubAskGuardGen{}
	useAskGuardGen(t, gen)
	for _, tc := range []struct{ name, verdict string }{
		{"a recorded question", e1Verdict},
		{"a clear", verdictJSON("none")},
		{"a recorded question again", e1Verdict},
		{"a block", verdictJSON("full")},
	} {
		gen.reply = tc.verdict
		_, _, err := runAskGuardStopHook(t, strconv.FormatInt(pid, 10), strings.NewReader(guardPayload("the message", false)))
		require.NoError(t, err)
		assert.Equal(t, want, state(), tc.name)
	}
}

func TestTierForSourceAskGuardIsLight(t *testing.T) {
	assert.Equal(t, digest.TierLight, digest.TierForSource(askGuardSource))
}

// fakeClaudeConfig writes a config whose claude binary is script (in dir)
// and returns its path.
func fakeClaudeConfig(t *testing.T, dir, script string) string {
	t.Helper()
	path := filepath.Join(dir, "config.yaml")
	body := "active_workspace: test\nclaude_path: " + strconv.Quote(script) + "\nai:\n  provider: claude\n"
	require.NoError(t, os.WriteFile(path, []byte(body), 0o600))
	return path
}

// The production model client (askGuardGeneratorFactory) runs the CLI in its
// own process group, without the Desktop terminal's session variable, and
// with the message on stdin, never on argv. A fake claude binary records all
// three; the real CLI is never invoked.
func TestAskGuardModelChildIsIsolated(t *testing.T) {
	const marker = "AGENT-MESSAGE-ask-guard-7c2d"
	dir := t.TempDir()
	verdict, err := json.Marshal(map[string]any{"type": "result", "result": e1Verdict, "is_error": false})
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(filepath.Join(dir, "reply"), verdict, 0o600))
	script := filepath.Join(dir, "fake-claude")
	require.NoError(t, os.WriteFile(script, []byte("#!/bin/sh\n"+
		"printf '%s\\n' \"$@\" > '"+dir+"/argv'\n"+
		"env > '"+dir+"/env'\n"+
		"ps -o pgid= -p $$ | tr -d ' ' > '"+dir+"/pgid'\n"+
		"echo $$ > '"+dir+"/pid'\n"+
		"cat > '"+dir+"/stdin'\n"+
		"cat '"+dir+"/reply'\n"), 0o755))
	t.Setenv(terminalSessionEnv, "42")
	cfg, err := config.Load(fakeClaudeConfig(t, dir, script))
	require.NoError(t, err)

	v, err := classifyAskGuard(context.Background(), askGuardGeneratorFactory(cfg), marker)

	require.NoError(t, err)
	assert.Equal(t, askRequestChat, v.Request)
	read := func(name string) string {
		b, err := os.ReadFile(filepath.Join(dir, name))
		require.NoError(t, err)
		return strings.TrimSpace(string(b))
	}
	assert.NotContains(t, read("argv"), marker, "the message never reaches argv")
	assert.Contains(t, read("stdin"), marker, "the message travels on stdin")
	assert.NotContains(t, read("env"), terminalSessionEnv+"=", "the child never gets the terminal session variable")
	assert.Equal(t, read("pid"), read("pgid"), "the child leads its own process group")
	assert.Contains(t, read("argv"), "--model", "a model call")
}

// E10a (PROJ-13): Claude Code's SIGTERM (its hook timeout), or a SIGHUP,
// during the model call ends the hook with exit 0 and nothing on stdout, and
// the model's whole process group is gone before it exits. The hook is the
// real CLI in a subprocess; the model a fake claude that starts a grandchild
// and waits.
func TestProj13_ACancelledModelCallLeavesNoProcess(t *testing.T) {
	for _, sig := range []syscall.Signal{syscall.SIGTERM, syscall.SIGHUP} {
		t.Run(sig.String(), func(t *testing.T) { cancelledModelCallLeavesNoProcess(t, sig) })
	}
}

func cancelledModelCallLeavesNoProcess(t *testing.T, sig syscall.Signal) {
	dir := t.TempDir()
	script := filepath.Join(dir, "fake-claude")
	require.NoError(t, os.WriteFile(script, []byte("#!/bin/sh\n"+
		"echo $$ > '"+dir+"/pid.tmp' && mv '"+dir+"/pid.tmp' '"+dir+"/pid'\n"+
		"sleep 60 &\n"+
		"echo $! > '"+dir+"/child.tmp' && mv '"+dir+"/child.tmp' '"+dir+"/child'\n"+
		"wait\n"), 0o755))
	cfgPath := fakeClaudeConfig(t, dir, script)

	p := startCLI(t, "--config", cfgPath, "workbench", "ask-guard", "--workbench", "1", "--stop")
	_, err := io.WriteString(p.stdin, guardPayload(e1Message, false))
	require.NoError(t, err)
	require.NoError(t, p.stdin.Close())

	readPID := func(name string) int {
		t.Helper()
		deadline := time.Now().Add(20 * time.Second)
		for {
			if b, err := os.ReadFile(filepath.Join(dir, name)); err == nil {
				n, err := strconv.Atoi(strings.TrimSpace(string(b)))
				require.NoError(t, err)
				return n
			}
			if time.Now().After(deadline) {
				t.Fatalf("the fake model never wrote %s", name)
			}
			time.Sleep(20 * time.Millisecond)
		}
	}
	group := readPID("pid")
	// Reap the model's group whatever happens below.
	t.Cleanup(func() { _ = syscall.Kill(-group, syscall.SIGKILL) })
	child := readPID("child")
	require.NoError(t, syscall.Kill(-group, 0), "fixture: the model's group runs")

	require.NoError(t, p.cmd.Process.Signal(sig))
	done := make(chan error, 1)
	go func() { done <- p.wait() }()
	select {
	case err := <-done:
		assert.Equal(t, 0, exitCode(err), "PROJ-13: the hook exits 0")
	case <-time.After(15 * time.Second):
		t.Fatalf("the hook did not exit after %v", sig)
	}
	_, open := <-p.lines
	assert.False(t, open, "PROJ-13: nothing on stdout")

	// Killed at once; the init process may take a moment to reap the
	// grandchild once it is a zombie.
	deadline := time.Now().Add(2 * time.Second)
	for syscall.Kill(-group, 0) == nil || syscall.Kill(child, 0) == nil {
		if time.Now().After(deadline) {
			t.Fatalf("the model's process group %d (child %d) outlived the hook", group, child)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// The fixed reasons are the spec's literal strings (Part 4.5); R-finish is
// the v3 prompt's finish reason, unchanged.
func TestAskGuardReasonsAreTheSpecsText(t *testing.T) {
	assert.Equal(t, "You asked the owner for a review, a check or several decisions in plain text. File it with ask_owner "+
		"(kind review, check or question with up to 4 questions), name it as 'ask #<id>' in your text, then stop.", askGuardReasonFull)
	assert.Equal(t, "The owner is not in this session, so a question in the terminal would wait unseen. File it with "+
		"ask_owner (kind question; one decision with 2-3 short options shows as a one-tap Quick ask), name it as "+
		"'ask #<id>' in your text, then stop.", askGuardReasonAway)
	assert.Equal(t, "Your work in this session looks complete, and your message still asks the owner something. File "+
		"the open question with ask_owner and name it as 'ask #<id>', then call finish_session with a 2-3 line "+
		"summary for the owner (what was done, the PRs, what is left on them), say 'session finished', then stop.",
		askGuardReasonFinishAsk)

	v3, err := os.ReadFile(filepath.Join("..", "internal", "devpack", "askguard_prompt.md"))
	require.NoError(t, err)
	flat := strings.Join(strings.Fields(string(v3)), " ")
	_, after, ok := strings.Cut(flat, `2. Finished without saying so:`)
	require.True(t, ok, "the v3 prompt's case 2")
	_, reason, ok := strings.Cut(after, `"reason": "`)
	require.True(t, ok)
	reason, _, ok = strings.Cut(reason, `"}`)
	require.True(t, ok)
	assert.Equal(t, reason, askGuardReasonFinish, "R-finish is the v3 finish reason, unchanged")
}

// A read failure after the session matched (here the presence read) sends
// a short question back and blocks its record, and still clears the older
// Stop's question (4.2 step 6).
func TestStopGuardReadFailureStillClearsTheOlderQuestion(t *testing.T) {
	database, pid, row := stopGuardFixture(t)
	seedOlderQuestion(t, database, pid, row)
	for _, q := range []string{
		// The columns are there; the read fails on a value the scan cannot take.
		`DROP TABLE owner_presence`,
		`CREATE TABLE owner_presence (id INTEGER, session_id INTEGER, seen_at TEXT)`,
		`INSERT INTO owner_presence VALUES (1, 'not a number', 'x')`,
	} {
		_, err := database.Exec(q)
		require.NoError(t, err, q)
	}
	useAskGuardGen(t, &stubAskGuardGen{reply: e1Verdict})

	out, errOut, err := runAskGuardStopHook(t, strconv.FormatInt(pid, 10), strings.NewReader(guardPayload(e1Message, false)))

	require.NoError(t, err)
	assert.Equal(t, guardBlock(t, askGuardReasonAway), out)
	assert.Contains(t, errOut, "ask guard reads the owner as away")
	assert.Nil(t, storedChatQuestion(t, database, row), "the older question is cleared, nothing recorded")
}

// A deleted workbench's leftover Stop hook says nothing (the drift hook and
// --pre-tool-use precedent): a short question passes, nothing is written.
func TestStopGuardDeletedWorkbenchPassesSilently(t *testing.T) {
	database, pid, _ := stopGuardFixture(t)
	require.NoError(t, database.DeleteWorkbench(pid))
	gen := &stubAskGuardGen{reply: e1Verdict}
	useAskGuardGen(t, gen)
	for _, verdict := range []string{e1Verdict, verdictJSON("full"), verdictJSON("none", "complete_unreported")} {
		gen.reply = verdict
		out, _, err := runAskGuardStopHook(t, strconv.FormatInt(pid, 10), strings.NewReader(guardPayload(e1Message, false)))
		require.NoError(t, err)
		assert.Empty(t, out, verdict)
	}
}

// A signal after the model call — here while the guard reads the session —
// writes nothing and prints nothing on stdout: no record, no clear, one
// stderr line.
func TestStopGuardCancelledDuringTheDatabasePhaseWritesNothing(t *testing.T) {
	database, pid, row := stopGuardFixture(t)
	setOwnerPresence(t, database, row, time.Now())
	seedOlderQuestion(t, database, pid, row)
	useAskGuardGen(t, &stubAskGuardGen{reply: e1Verdict})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	orig, calls := hookNow, 0
	hookNow = func() time.Time {
		calls++
		if calls == 2 { // the presence read's clock, after the model call
			cancel()
		}
		return time.Now()
	}
	t.Cleanup(func() { hookNow = orig })
	var out, errOut bytes.Buffer

	runAskGuardStop(ctx, strings.NewReader(guardPayload(e1Message, false)), &out, &errOut, strconv.FormatInt(pid, 10))

	assert.Empty(t, out.String())
	assert.Contains(t, errOut.String(), "watchtower: ask guard skipped: cancelled")
	q := storedChatQuestion(t, database, row)
	require.NotNil(t, q, "nothing cleared")
	assert.Equal(t, "An older question?", q.Question, "nothing recorded")
}

// The classifier reads only the message's last 32 KiB, cut on a rune
// boundary behind a marker; a shorter message goes whole.
func TestAskGuardMessageTail(t *testing.T) {
	assert.Equal(t, 32<<10, askGuardMessageLimit)
	short := strings.Repeat("a", askGuardMessageLimit)
	assert.Equal(t, short, askGuardMessageTail(short))

	long := strings.Repeat("é", askGuardMessageLimit) + "Ship it?" // 2 bytes a rune
	got := askGuardMessageTail(long)
	require.True(t, strings.HasPrefix(got, askGuardCutMarker))
	tail := strings.TrimPrefix(got, askGuardCutMarker)
	assert.True(t, utf8.ValidString(tail), "cut on a rune boundary")
	assert.LessOrEqual(t, len(tail), askGuardMessageLimit)
	assert.True(t, strings.HasSuffix(tail, "Ship it?"), "the end of the message is kept")

	// The hook hands the model the tail.
	database, pid, row := stopGuardFixture(t)
	setOwnerPresence(t, database, row, time.Now())
	gen := &stubAskGuardGen{reply: verdictJSON("none")}
	useAskGuardGen(t, gen)
	_, _, err := runAskGuardStopHook(t, strconv.FormatInt(pid, 10), strings.NewReader(guardPayload(long, false)))
	require.NoError(t, err)
	assert.Equal(t, got, gen.message)
}

// A continued turn outside a Desktop terminal row (no or an unreadable
// variable, or no conversation id) has nothing to record or clear: the guard
// calls no model and prints nothing.
func TestStopGuardContinuedTurnWithoutASessionCallsNoModel(t *testing.T) {
	for _, tc := range []struct {
		name    string
		env     func(t *testing.T)
		payload string
	}{
		{"no env", unsetTerminalEnv, guardPayload(e1Message, true)},
		{"an unreadable env", func(t *testing.T) { t.Setenv(terminalSessionEnv, "row-seven") }, guardPayload(e1Message, true)},
		{"no conversation id", func(*testing.T) {}, strings.Replace(guardPayload(e1Message, true), briefLaunchID, "", 1)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, pid, _ := stopGuardFixture(t)
			tc.env(t)
			gen := &stubAskGuardGen{reply: e1Verdict}
			useAskGuardGen(t, gen)

			out, _, err := runAskGuardStopHook(t, strconv.FormatInt(pid, 10), strings.NewReader(tc.payload))

			require.NoError(t, err)
			assert.Empty(t, out)
			assert.Zero(t, gen.calls, "no model call")
		})
	}
}

// An unreadable terminal session variable is named on stderr, and a short
// question reads as the owner being away.
func TestStopGuardUnreadableSessionVariableReadsAsAway(t *testing.T) {
	_, pid, _ := stopGuardFixture(t)
	t.Setenv(terminalSessionEnv, "row-seven")
	useAskGuardGen(t, &stubAskGuardGen{reply: e1Verdict})

	out, errOut, err := runAskGuardStopHook(t, strconv.FormatInt(pid, 10), strings.NewReader(guardPayload(e1Message, false)))

	require.NoError(t, err)
	assert.Equal(t, guardBlock(t, askGuardReasonAway), out)
	assert.Contains(t, errOut, "ask guard reads the owner as away")
	assert.Contains(t, errOut, terminalSessionEnv)
}

// Diagnostics: a request in another case or with spaces is still read; an
// unknown one reads as none and is named on stderr; a timeout names the
// budget; a reply that is no verdict is described, never echoed.
func TestAskGuardDiagnostics(t *testing.T) {
	v, err := decodeAskGuardVerdict(`{"request":" CHAT ","question":"Ship it?"}`)
	require.NoError(t, err)
	assert.Equal(t, askRequestChat, v.Request)
	assert.Empty(t, v.UnknownRequest)
	v, err = decodeAskGuardVerdict(`{"request":"Full"}`)
	require.NoError(t, err)
	assert.Equal(t, askRequestFull, v.Request)
	v, err = decodeAskGuardVerdict(`{"request":"maybe"}`)
	require.NoError(t, err)
	assert.Equal(t, askRequestNone, v.Request)
	assert.Equal(t, "maybe", v.UnknownRequest)

	const prose = "SECRET-PROSE the message asks the owner a question"
	_, err = decodeAskGuardVerdict(prose)
	require.Error(t, err)
	assert.NotContains(t, err.Error(), "SECRET-PROSE", "the reply is described, never echoed")
	assert.Contains(t, err.Error(), "bytes")

	orig := askGuardModelBudget
	askGuardModelBudget = 20 * time.Millisecond
	t.Cleanup(func() { askGuardModelBudget = orig })
	_, err = classifyAskGuard(context.Background(), &stubAskGuardGen{block: true}, "msg")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "ran past its 20ms budget")
	parent, cancel := context.WithCancel(context.Background())
	cancel()
	_, err = classifyAskGuard(parent, &stubAskGuardGen{block: true}, "msg")
	require.Error(t, err)
	assert.NotContains(t, err.Error(), "budget", "a signal is not the budget")

	database, pid, row := stopGuardFixture(t)
	setOwnerPresence(t, database, row, time.Now())
	useAskGuardGen(t, &stubAskGuardGen{reply: `{"request":"maybe"}`})
	out, errOut, err := runAskGuardStopHook(t, strconv.FormatInt(pid, 10), strings.NewReader(guardPayload(e1Message, false)))
	require.NoError(t, err)
	assert.Empty(t, out)
	assert.Contains(t, errOut, `read the classifier's request "maybe" as none`)
}
