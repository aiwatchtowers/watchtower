package daemon

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentlogdb"
	"watchtower/internal/coach"
	"watchtower/internal/db"
	"watchtower/internal/digest"
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
