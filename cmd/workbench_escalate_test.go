package cmd

import (
	"database/sql"
	"encoding/json"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/asks"
	"watchtower/internal/db"
)

// escalateFixture is a workbench with a claude row that waits on the turn
// end at which the Stop ask guard recorded q, asked ten minutes ago; the
// clock reads now.
type escalateFixture struct {
	database *db.DB
	pid, row int64
	asked    time.Time
	at       string
}

func newEscalateFixture(t *testing.T, q db.ChatQuestion) escalateFixture {
	t.Helper()
	database, pid, row := briefSessionFixture(t)
	now := time.Now().Truncate(time.Millisecond)
	orig := hookNow
	hookNow = func() time.Time { return now }
	t.Cleanup(func() { hookNow = orig })
	asked := now.Add(-10 * time.Minute)
	f := escalateFixture{database: database, pid: pid, row: row, asked: asked, at: db.AgentStateStamp(asked)}
	f.setState(t, "waiting", asked.Add(time.Second))
	require.NoError(t, database.SetChatQuestion(row, pid, briefLaunchID, q, asked))
	return f
}

// setState stores the row's agent state stamped at.
func (f escalateFixture) setState(t *testing.T, state string, at time.Time) {
	t.Helper()
	_, err := f.database.Exec(`UPDATE terminal_sessions SET agent_state = ?, agent_state_at = ? WHERE id = ?`,
		state, db.AgentStateStamp(at), f.row)
	require.NoError(t, err)
}

// escalate runs the verb for the fixture's question with reason.
func (f escalateFixture) escalate(t *testing.T, reason string) escalateResult {
	t.Helper()
	return runEscalate(t, "--workbench", strconv.FormatInt(f.pid, 10), "--session", strconv.FormatInt(f.row, 10),
		"--at", f.at, "--reason", reason)
}

// runEscalate runs `workbench escalate-question args…`: it always exits 0
// and prints one JSON object.
func runEscalate(t *testing.T, args ...string) escalateResult {
	t.Helper()
	out, _, err := runWorkbenchAs(t, "workbench", append([]string{"escalate-question"}, args...)...)
	require.NoError(t, err, "the verb always exits 0")
	var res escalateResult
	dec := json.NewDecoder(strings.NewReader(out))
	require.NoError(t, dec.Decode(&res), "stdout %q", out)
	assert.False(t, dec.More(), "one JSON object, got %q", out)
	return res
}

func twoOptions() db.ChatQuestion {
	return db.ChatQuestion{Question: "Use snake_case or camelCase for the new keys?",
		Options: []db.ChatQuestionOption{{Label: "snake_case", Recommended: true}, {Label: "camelCase"}}}
}

// countAsks is how many asks workbench pid holds.
func countAsks(t *testing.T, database *db.DB, pid int64) int {
	t.Helper()
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM owner_asks WHERE project_id = ?`, pid).Scan(&n))
	return n
}

// E12: the question is filed as a Quick ask of origin chat with the stored
// options, the title clipped, the summary ending in the reason's line, the
// session and its single linked target; the question is cleared.
func TestEscalateFilesAQuickAskWithTheSameOptions(t *testing.T) {
	long := strings.Repeat("word ", 30) + "or that?" // 158 runes
	for _, tc := range []struct {
		reason, line string
		links        int
	}{
		{escalateReasonTimeout, "Asked in the terminal; no answer for 10 min.", 1},
		{escalateReasonLeft, "Asked in the terminal; you left the session.", 0},
		{escalateReasonAway, "Asked in the terminal while you were away.", 2},
	} {
		t.Run(tc.reason, func(t *testing.T) {
			q := twoOptions()
			q.Question = long
			f := newEscalateFixture(t, q)
			var targets []int64
			require.NoError(t, f.database.WithTx(func(tx *sql.Tx) error {
				var err error
				targets, err = f.database.CreateWorkbenchTargetsTx(tx, f.pid,
					[]db.WorkbenchTargetInput{{Title: "one"}, {Title: "two"}})
				return err
			}))
			for _, id := range targets[:tc.links] {
				require.NoError(t, f.database.LinkSessionTarget(f.row, id))
			}

			res := f.escalate(t, tc.reason)

			require.True(t, res.OK, "%+v", res)
			assert.Equal(t, escalateFiled, res.Outcome)
			assert.Equal(t, asks.LevelQuick, res.Level)
			a, err := f.database.GetOwnerAsk(f.pid, res.AskID)
			require.NoError(t, err)
			assert.Equal(t, asks.KindQuestion, a.Kind)
			assert.Equal(t, "open", a.Status)
			assert.Equal(t, strings.TrimSpace(string([]rune(strings.TrimSpace(long))[:escalateTitleRunes])), a.Title)
			assert.Equal(t, long+"\n"+tc.line, a.Summary)
			assert.Equal(t, asks.OriginChat, a.Origin)
			assert.Equal(t, asks.LevelQuick, a.Level)
			assert.Equal(t, f.at, a.ChatAskedAt)
			assert.Equal(t, sql.NullInt64{Int64: f.row, Valid: true}, a.SessionID)
			if tc.links == 1 {
				assert.Equal(t, sql.NullInt64{Int64: targets[0], Valid: true}, a.TargetID, "the single linked target")
			} else {
				assert.False(t, a.TargetID.Valid, "%d linked targets: none", tc.links)
			}
			var p asks.Payload
			require.NoError(t, json.Unmarshal([]byte(a.Payload), &p))
			require.Len(t, p.Questions, 1)
			assert.Equal(t, "q1", p.Questions[0].ID)
			assert.Equal(t, strings.TrimSpace(long), p.Questions[0].Question)
			assert.Equal(t, []asks.Option{{Label: "snake_case", Recommended: true}, {Label: "camelCase"}}, p.Questions[0].Options)
			s, err := f.database.GetTerminalSession(f.row)
			require.NoError(t, err)
			assert.Empty(t, s.ChatQuestionAt, "the question is cleared as it is filed")
		})
	}
}

// PROJ-13 (E11a, E16, E17): the escalation is a compare-and-take — filed
// once; a cleared or replaced question, a state off waiting or a waiting
// stamped past the 30 s tolerance is gone, and nothing is written.
func TestProj13_EscalationIsCompareAndTake(t *testing.T) {
	t.Run("filed once, the second run is gone", func(t *testing.T) {
		f := newEscalateFixture(t, twoOptions())
		first := f.escalate(t, escalateReasonTimeout)
		require.Equal(t, escalateFiled, first.Outcome)
		second := f.escalate(t, escalateReasonTimeout)
		assert.Equal(t, escalateResult{OK: true, Outcome: escalateGone}, second)
		assert.Equal(t, 1, countAsks(t, f.database, f.pid), "E17: one ask")
	})
	for _, tc := range []struct {
		name  string
		setup func(t *testing.T, f escalateFixture)
	}{
		{"E11a the owner's turn moved the state to working", func(t *testing.T, f escalateFixture) {
			f.setState(t, "working", f.asked.Add(time.Minute))
		}},
		{"a permission prompt", func(t *testing.T, f escalateFixture) {
			f.setState(t, "approval", f.asked.Add(time.Minute))
		}},
		{"waiting stamped 31 s after the question", func(t *testing.T, f escalateFixture) {
			f.setState(t, "waiting", f.asked.Add(31*time.Second))
		}},
		{"E16 a newer Stop replaced the question", func(t *testing.T, f escalateFixture) {
			require.NoError(t, f.database.SetChatQuestion(f.row, f.pid, briefLaunchID,
				db.ChatQuestion{Question: "Newer?"}, f.asked.Add(9*time.Minute)))
		}},
		{"the question was cleared", func(t *testing.T, f escalateFixture) {
			require.NoError(t, f.database.ClearChatQuestionBefore(f.row, f.pid, briefLaunchID, f.asked.Add(time.Minute)))
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newEscalateFixture(t, twoOptions())
			tc.setup(t, f)
			before := rowSnapshot(t, f.database, f.row)

			res := f.escalate(t, escalateReasonTimeout)

			assert.Equal(t, escalateResult{OK: true, Outcome: escalateGone}, res)
			assert.Zero(t, countAsks(t, f.database, f.pid), "nothing filed")
			assert.Equal(t, before, rowSnapshot(t, f.database, f.row), "nothing written")
		})
	}
}

// E19: four options make a Full ask (the drawer).
func TestEscalateFourOptionsIsFull(t *testing.T) {
	f := newEscalateFixture(t, db.ChatQuestion{Question: "Which one?", Options: []db.ChatQuestionOption{
		{Label: "A"}, {Label: "B"}, {Label: "C"}, {Label: "D", Recommended: true}}})

	res := f.escalate(t, escalateReasonLeft)

	require.Equal(t, escalateFiled, res.Outcome)
	assert.Equal(t, asks.LevelFull, res.Level)
	a, err := f.database.GetOwnerAsk(f.pid, res.AskID)
	require.NoError(t, err)
	assert.Equal(t, asks.LevelFull, a.Level)
}

// E18, E10e: a question with no options is a Quick ask with a free reply
// only, valid with origin chat.
func TestEscalateZeroOptionsIsQuick(t *testing.T) {
	f := newEscalateFixture(t, db.ChatQuestion{Question: "What is the staging host name?"})

	res := f.escalate(t, escalateReasonAway)

	require.Equal(t, escalateFiled, res.Outcome)
	assert.Equal(t, asks.LevelQuick, res.Level)
	a, err := f.database.GetOwnerAsk(f.pid, res.AskID)
	require.NoError(t, err)
	var p asks.Payload
	require.NoError(t, json.Unmarshal([]byte(a.Payload), &p))
	require.Len(t, p.Questions, 1)
	assert.Empty(t, p.Questions[0].Options)
	_, err = asks.Validate(asks.Input{Kind: a.Kind, Title: a.Title, Questions: p.Questions}, asks.OriginChat)
	assert.NoError(t, err)
}

// E20: at the open-ask cap nothing is filed and the question stays, so the
// Desktop can retry.
func TestEscalateAtTheOpenCapKeepsTheQuestion(t *testing.T) {
	f := newEscalateFixture(t, twoOptions())
	require.NoError(t, f.database.WithTx(func(tx *sql.Tx) error {
		for i := range asks.MaxOpenPerWorkbench {
			if _, _, err := f.database.InsertOwnerAsk(tx, db.OwnerAsk{WorkbenchID: f.pid, Kind: "question",
				Title: "Ask " + strconv.Itoa(i)}); err != nil {
				return err
			}
		}
		return nil
	}))
	before := rowSnapshot(t, f.database, f.row)

	res := f.escalate(t, escalateReasonTimeout)

	assert.False(t, res.OK)
	assert.Equal(t, escalateResult{OK: false, ErrorCode: escalateErrOpenCap, Error: "too many open asks"}, res)
	assert.Equal(t, asks.MaxOpenPerWorkbench, countAsks(t, f.database, f.pid))
	assert.Equal(t, before, rowSnapshot(t, f.database, f.row), "the question is kept")
}

// The envelope: one JSON object and exit 0 always; not_found for a missing
// workbench or session or one of another workbench, bad_args for bad flags,
// busy for a locked database, internal for a broken config; the legacy
// --project spelling works.
func TestEscalateEnvelopeShape(t *testing.T) {
	f := newEscalateFixture(t, twoOptions())
	pid, row := strconv.FormatInt(f.pid, 10), strconv.FormatInt(f.row, 10)
	other, err := f.database.CreateWorkbench("other", t.TempDir())
	require.NoError(t, err)
	shell, err := f.database.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path)
		VALUES (?, 'shell', 'sh', '/tmp/acme')`, f.pid)
	require.NoError(t, err)
	shellID, err := shell.LastInsertId()
	require.NoError(t, err)

	for _, tc := range []struct {
		name string
		args []string
		code string
	}{
		{"a missing session", []string{"--workbench", pid, "--session", "999", "--at", f.at, "--reason", "timeout"}, escalateErrNotFound},
		{"a missing workbench", []string{"--workbench", "999", "--session", row, "--at", f.at, "--reason", "timeout"}, escalateErrNotFound},
		{"another workbench's session", []string{"--workbench", strconv.FormatInt(other, 10), "--session", row, "--at", f.at, "--reason", "timeout"}, escalateErrNotFound},
		{"a shell row", []string{"--workbench", pid, "--session", strconv.FormatInt(shellID, 10), "--at", f.at, "--reason", "timeout"}, escalateErrNotFound},
		{"no session", []string{"--workbench", pid, "--at", f.at, "--reason", "timeout"}, escalateErrBadArgs},
		{"a bad session", []string{"--workbench", pid, "--session", "seven", "--at", f.at, "--reason", "timeout"}, escalateErrBadArgs},
		{"no workbench", []string{"--session", row, "--at", f.at, "--reason", "timeout"}, escalateErrBadArgs},
		{"a bad stamp", []string{"--workbench", pid, "--session", row, "--at", "2026-10-10T12:00:00Z", "--reason", "timeout"}, escalateErrBadArgs},
		{"a bad reason", []string{"--workbench", pid, "--session", row, "--at", f.at, "--reason", "bored"}, escalateErrBadArgs},
		{"an unknown flag", []string{"--workbench", pid, "--session", row, "--at", f.at, "--reason", "timeout", "--force"}, escalateErrBadArgs},
		{"a flag without its value", []string{"--workbench", pid, "--session", row, "--at", f.at, "--reason"}, escalateErrBadArgs},
		{"a positional argument", []string{"--workbench", pid, "--session", row, "--at", f.at, "--reason", "timeout", "extra"}, escalateErrBadArgs},
		{"both workbench flags", []string{"--workbench", pid, "--project", pid, "--session", row, "--at", f.at, "--reason", "timeout"}, escalateErrBadArgs},
	} {
		t.Run(tc.name, func(t *testing.T) {
			res := runEscalate(t, tc.args...)
			assert.False(t, res.OK)
			assert.Equal(t, tc.code, res.ErrorCode)
			assert.NotEmpty(t, res.Error)
			assert.Empty(t, res.Outcome)
		})
	}
	assert.Zero(t, countAsks(t, f.database, f.pid), "no failure wrote")

	t.Run("the legacy --project spelling", func(t *testing.T) {
		res := runEscalate(t, "--project", pid, "--session", row, "--at", f.at, "--reason", "timeout")
		assert.True(t, res.OK)
		assert.Equal(t, escalateFiled, res.Outcome)
	})
	t.Run("a locked database is busy", func(t *testing.T) {
		g := newEscalateFixture(t, twoOptions())
		lockDatabase(t, g.database)
		res := g.escalate(t, escalateReasonTimeout)
		assert.False(t, res.OK)
		assert.Equal(t, escalateErrBusy, res.ErrorCode)
	})
	t.Run("a migration that cannot apply is schema", func(t *testing.T) {
		g := newEscalateFixture(t, twoOptions())
		require.NoError(t, goose.DownTo(g.database.DB, "migrations", 106))
		_, err := g.database.Exec(`ALTER TABLE owner_asks ADD COLUMN level TEXT`) // 00107's column, already there
		require.NoError(t, err)
		res := g.escalate(t, escalateReasonTimeout)
		assert.False(t, res.OK)
		assert.Equal(t, escalateErrSchema, res.ErrorCode)
	})
	t.Run("a broken config is internal", func(t *testing.T) {
		brokenConfig(t)
		res := runEscalate(t, "--workbench", pid, "--session", row, "--at", f.at, "--reason", "timeout")
		assert.False(t, res.OK)
		assert.Equal(t, escalateErrInternal, res.ErrorCode)
	})
}
