package daemon

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentlogdb"
	"watchtower/internal/coach"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/fsutil"
)

type coachCalls struct{ judge, propose int }

func stubCoach(t *testing.T, proposeErr error) *coachCalls {
	t.Helper()
	c := &coachCalls{}
	oj, op := runCoachJudge, runCoachProposer
	runCoachJudge = func(*db.DB, *agentlogdb.DB, time.Time) (int, int, error) { c.judge++; return 0, 0, nil }
	runCoachProposer = func(context.Context, *coach.Proposer, coach.Inputs) (int, *digest.Usage, error) {
		c.propose++
		return 1, &digest.Usage{InputTokens: 5}, proposeErr
	}
	t.Cleanup(func() { runCoachJudge, runCoachProposer = oj, op })
	return c
}

// coachDaemon is a daemon with an open agentlog.db, as in production.
func coachDaemon(t *testing.T) (*Daemon, *db.DB) {
	d, database, _ := newBackfillDaemon(t)
	al, err := agentlogdb.Open(t.TempDir() + "/agentlog.db")
	require.NoError(t, err)
	t.Cleanup(func() { _ = al.Close() })
	d.SetAgentLogDB(al, "")
	return d, database
}

func TestPhaseCoach_WeeklyStamp(t *testing.T) {
	d, database := coachDaemon(t)
	c := stubCoach(t, nil)

	d.phaseCoach(context.Background())
	d.phaseCoach(context.Background())
	assert.Equal(t, coachCalls{1, 1}, *c)
	assert.Equal(t, []string{"coach"}, pipelineRunNames(t, database))
	assert.FileExists(t, d.lastCoachPath())

	d.lastCoach = time.Now().Add(-6 * 24 * time.Hour)
	d.phaseCoach(context.Background())
	assert.Equal(t, 1, c.propose, "six days is too early")

	d.lastCoach = time.Now().Add(-8 * 24 * time.Hour)
	d.phaseCoach(context.Background())
	assert.Equal(t, coachCalls{2, 2}, *c)
}

func TestPhaseCoach_ModelErrorRetriesTomorrow(t *testing.T) {
	d, _ := coachDaemon(t)
	c := stubCoach(t, errors.New("boom"))

	d.phaseCoach(context.Background())
	assert.True(t, d.lastCoach.IsZero(), "a failed propose does not burn the week")
	assert.NoFileExists(t, d.lastCoachPath())
	assert.FileExists(t, d.lastCoachFailedPath())
	d.phaseCoach(context.Background())
	assert.Equal(t, 1, c.propose, "not retried in the next cycle")

	// The failure stamp survives a restart.
	d.lastCoachFailed = time.Time{}
	d.loadLastCoach()
	d.phaseCoach(context.Background())
	assert.Equal(t, 1, c.propose, "nor after a restart the same day")

	runCoachProposer = func(context.Context, *coach.Proposer, coach.Inputs) (int, *digest.Usage, error) {
		c.propose++
		return 0, nil, nil
	}
	d.lastCoachFailed = time.Now().Add(-coachRetryAfter - time.Minute)
	d.phaseCoach(context.Background())
	assert.Equal(t, 2, c.propose, "retried a day later")
	assert.False(t, d.lastCoach.IsZero(), "a completed propose stamps the week")
	assert.FileExists(t, d.lastCoachPath())
	assert.NoFileExists(t, d.lastCoachFailedPath(), "and clears the failure")
	d.phaseCoach(context.Background())
	assert.Equal(t, 2, c.propose)
}

func TestPhaseCoach_JudgeErrorStillStamps(t *testing.T) {
	d, _ := coachDaemon(t)
	c := stubCoach(t, nil)
	runCoachJudge = func(*db.DB, *agentlogdb.DB, time.Time) (int, int, error) {
		c.judge++
		return 0, 0, errors.New("judge boom")
	}

	d.phaseCoach(context.Background())
	assert.Equal(t, coachCalls{1, 1}, *c, "proposing goes on after a judging error")
	assert.FileExists(t, d.lastCoachPath())
}

func TestPhaseCoach_NoCatchUp(t *testing.T) {
	d, _ := coachDaemon(t)
	c := stubCoach(t, nil)
	d.lastCoach = time.Now().AddDate(0, 0, -30)

	d.phaseCoach(context.Background())
	d.phaseCoach(context.Background())
	assert.Equal(t, coachCalls{1, 1}, *c, "a month-old stamp gives exactly one run")
}

func TestPhaseCoach_NoAgentLogSkipsJudge(t *testing.T) {
	d, _, buf := newBackfillDaemon(t)
	c := stubCoach(t, nil)

	d.phaseCoach(context.Background())
	assert.Equal(t, coachCalls{0, 1}, *c)
	assert.Contains(t, buf.String(), "judging skipped")
}

func TestPhaseCoach_CancelledRunDoesNotStamp(t *testing.T) {
	d, _ := coachDaemon(t)
	c := stubCoach(t, nil)
	ctx, cancel := context.WithCancel(context.Background())
	runCoachProposer = func(context.Context, *coach.Proposer, coach.Inputs) (int, *digest.Usage, error) {
		c.propose++
		cancel()
		return 0, nil, ctx.Err()
	}

	d.phaseCoach(ctx)
	assert.True(t, d.lastCoach.IsZero(), "a cancelled run keeps the week")
	assert.NoFileExists(t, d.lastCoachPath())
	assert.True(t, d.lastCoachFailed.IsZero(), "a cancelled run is not a failure")
	assert.NoFileExists(t, d.lastCoachFailedPath())

	d.phaseCoach(ctx) // entry on a cancelled ctx is a no-op
	assert.Equal(t, 1, c.propose)
	d.phaseCoach(context.Background())
	assert.Equal(t, 2, c.propose, "the next cycle runs again")
}

func TestPhaseCoach_SkipsWhenLocked(t *testing.T) {
	d, _ := coachDaemon(t)
	c := stubCoach(t, nil)
	unlock, ok, err := fsutil.TryLockFile(coach.LockPath(d.config.WorkspaceDir()))
	require.NoError(t, err)
	require.True(t, ok)
	defer unlock()

	d.phaseCoach(context.Background())
	assert.Equal(t, coachCalls{}, *c, "no model call")
	assert.NoFileExists(t, d.lastCoachPath())
	assert.NoFileExists(t, d.lastCoachFailedPath())
}

// The suggestion fold runs inside the coach pass, under its lock, before
// judging and proposing.
func TestPhaseCoach_ImportsBeforeProposing(t *testing.T) {
	d, database := coachDaemon(t)
	var order []string
	oi, oj, op := runCoachImport, runCoachJudge, runCoachProposer
	t.Cleanup(func() { runCoachImport, runCoachJudge, runCoachProposer = oi, oj, op })
	runCoachImport = func(main *db.DB, lang string, now time.Time) (int, error) {
		assert.Same(t, database, main)
		_, locked, err := fsutil.TryLockFile(coach.LockPath(d.config.WorkspaceDir()))
		require.NoError(t, err)
		assert.False(t, locked, "the fold runs under the coach lock")
		order = append(order, "import")
		return coach.ImportSuggestions(main, lang, now)
	}
	runCoachJudge = func(*db.DB, *agentlogdb.DB, time.Time) (int, int, error) {
		order = append(order, "judge")
		return 0, 0, nil
	}
	runCoachProposer = func(_ context.Context, _ *coach.Proposer, in coach.Inputs) (int, *digest.Usage, error) {
		order = append(order, "propose")
		assert.Len(t, in.Open, 1, "the proposer sees the folded proposal")
		return 0, nil, nil
	}
	require.NoError(t, database.UpsertInstructionSuggestion(db.InstructionSuggestion{Text: "Run the linter first",
		Field: db.InstructionSession, SessionCount: 3, Fingerprint: "fp"}, time.Now()))

	d.phaseCoach(context.Background())
	assert.Equal(t, []string{"import", "judge", "propose"}, order)
	open, err := database.ListCoachProposals("open")
	require.NoError(t, err)
	require.Len(t, open, 1)
	assert.Equal(t, "Run the linter first", open[0].AfterText)
}

// The daily miner phase is gone: a whole cycle records the coach's run but
// no instruction-suggestions run, and writes no miner stamp.
func TestDaemon_NoInstructionSuggestionPhase(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	d, database := coachDaemon(t)
	c := stubCoach(t, nil)
	d.runSync(context.Background(), context.Background())
	require.Equal(t, 1, c.propose, "the cycle reached the coach")
	names := pipelineRunNames(t, database)
	assert.Contains(t, names, "coach")
	assert.NotContains(t, names, "instruction-suggestions")
	assert.NoFileExists(t, filepath.Join(d.config.WorkspaceDir(), "last_instruction_suggestions.txt"))
}

// The owner's text must reach the model on stdin only: a fake claude records
// its argv and stdin, and the secret must be absent from the former.
func TestCoachGenerator_IsStdinOnly(t *testing.T) {
	dir := t.TempDir()
	argvFile, stdinFile := filepath.Join(dir, "argv"), filepath.Join(dir, "stdin")
	script := filepath.Join(dir, "claude")
	body := "#!/bin/sh\nprintf '%s\\n' \"$@\" > '" + argvFile + "'\ncat > '" + stdinFile + "'\necho '{}'\n"
	require.NoError(t, os.WriteFile(script, []byte(body), 0o700))

	gen := coachGeneratorFactory(&config.Config{ClaudePath: script})
	const secret = "OWNER-SECRET-DIRECTION"
	_, _, _, _ = gen.Generate(context.Background(), "system prompt", secret, "") // output shape is irrelevant

	argv, err := os.ReadFile(argvFile)
	require.NoError(t, err)
	stdin, err := os.ReadFile(stdinFile)
	require.NoError(t, err)
	assert.NotContains(t, string(argv), secret, "owner text must never be on argv")
	assert.Contains(t, string(stdin), secret, "owner text goes on stdin")
}
