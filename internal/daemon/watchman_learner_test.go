package daemon

import (
	"context"
	"errors"
	"strconv"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/watchman"
)

// batchSource offers one review precedent per Next (a category set, so no
// label call), total batches in all; after, when set, runs after batch i
// (1-based) is returned. Its cursor is the next row's index.
type batchSource struct {
	total int
	stuck bool  // offers nothing and never finishes
	err   error // every Next fails with it
	calls atomic.Int32
	after func(batch int)
}

func (s *batchSource) Name() string { return watchman.SourceReview }

func (s *batchSource) Next(_ context.Context, _ *db.DB, wb int64, cursor string, _ int) ([]db.WatchmanPrecedent, string, bool, error) {
	i := 0
	if cursor != "" {
		var err error
		if i, err = strconv.Atoi(cursor); err != nil {
			return nil, "", false, err
		}
	}
	s.calls.Add(1)
	if s.err != nil {
		return nil, "", false, s.err
	}
	if s.stuck {
		return nil, cursor, false, nil // no progress: the pass ends, the workbench still learning
	}
	if i >= s.total {
		return nil, cursor, true, nil // caught up
	}
	if s.after != nil {
		defer s.after(i + 1)
	}
	p := db.WatchmanPrecedent{WorkbenchID: wb, Source: watchman.SourceReview, SourceKey: strconv.Itoa(i), Category: "design",
		Situation: "s", Choice: "c", DecidedAt: time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC), Weight: 1}
	return []db.WatchmanPrecedent{p}, strconv.Itoa(i + 1), i+1 == s.total, nil
}

// learnerEnv is a daemon with one workbench Watchman was just turned on
// for, learning from src only, background AI allowed.
func learnerEnv(t *testing.T, batches int) (*Daemon, *db.DB, int64, *batchSource, *fakeConsent) {
	t.Helper()
	d, database, _ := newBackfillDaemon(t)
	stubWatchman(t)
	src := &batchSource{total: batches}
	prev := watchmanSources
	watchmanSources = func(context.Context, *Daemon, int64) []watchman.Source { return []watchman.Source{src} }
	t.Cleanup(func() { watchmanSources = prev })
	fc := newFakeConsent(consentAllowed)
	d.SetConsent(fc.read)
	wb, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	require.NoError(t, database.EnableWatchmanWorkbench(wb, time.Now(), batches))
	return d, database, wb, src, fc
}

func precedentsOf(t *testing.T, database *db.DB, wb int64) int {
	t.Helper()
	var n int
	require.NoError(t, database.QueryRow(`SELECT COUNT(*) FROM watchman_precedents WHERE workbench_id = ?`, wb).Scan(&n))
	return n
}

func stillLearning(t *testing.T, database *db.DB, wb int64) bool {
	t.Helper()
	l, err := database.WatchmanStillLearning(wb)
	require.NoError(t, err)
	return l
}

// One pass learns every batch, with no time budget, marks the workbench
// learned and nudges the twin.
func TestLearner_RunsToEndWithoutBudget(t *testing.T) {
	d, database, wb, src, _ := learnerEnv(t, 7)
	d.watchmanTwinCycle = make(chan struct{}, 1)
	d.runWatchmanLearner(context.Background(), true)
	assert.Equal(t, int32(7), src.calls.Load())
	assert.Equal(t, 7, precedentsOf(t, database, wb))
	assert.False(t, stillLearning(t, database, wb), "learned_through set")
	assert.Len(t, d.watchmanTwinCycle, 1, "the twin is nudged")
	assert.Equal(t, []string{"watchman-learn"}, pipelineRunNames(t, database))

	// Learned: the next pass leaves it to the cycle phase.
	d.runWatchmanLearner(context.Background(), true)
	assert.Equal(t, int32(7), src.calls.Load())
}

// A shutdown mid-learning keeps the batches written; the next start
// resumes from the cursor without duplicates.
func TestLearner_StopsOnShutdownAndResumes(t *testing.T) {
	d, database, wb, src, _ := learnerEnv(t, 7)
	ctx, cancel := context.WithCancel(context.Background())
	src.after = func(batch int) {
		if batch == 3 {
			cancel()
		}
	}
	d.runWatchmanLearner(ctx, true)
	assert.Equal(t, 3, precedentsOf(t, database, wb))
	assert.True(t, stillLearning(t, database, wb))

	src.after = nil
	d.runWatchmanLearner(context.Background(), true)
	assert.Equal(t, 7, precedentsOf(t, database, wb), "every row once")
	assert.False(t, stillLearning(t, database, wb))
}

// Background AI paused: no pass starts, and a pause between batches stops
// the pass; the next allowed pass resumes (BGAI-01).
func TestLearner_PausedByConsent(t *testing.T) {
	d, database, wb, src, fc := learnerEnv(t, 5)
	fc.set(consentPausedByOwner)
	d.runWatchmanLearner(context.Background(), true)
	assert.Zero(t, src.calls.Load(), "nothing read while paused")
	assert.Empty(t, pipelineRunNames(t, database))

	fc.set(consentAllowed)
	src.after = func(batch int) {
		if batch == 2 {
			fc.set(consentPausedByOwner)
		}
	}
	d.runWatchmanLearner(context.Background(), true)
	assert.Equal(t, 2, precedentsOf(t, database, wb), "stopped between batches")
	assert.True(t, stillLearning(t, database, wb))

	src.after = nil
	fc.set(consentAllowed)
	d.runWatchmanLearner(context.Background(), true)
	assert.Equal(t, 5, precedentsOf(t, database, wb))
	assert.False(t, stillLearning(t, database, wb))
}

// The workbench's learn lock held (`watchman learn --start` learning it):
// the learner skips it with no Learn call.
func TestLearner_LockSkipsSecond(t *testing.T) {
	d, database, wb, src, _ := learnerEnv(t, 3)
	unlock, ok, err := watchman.TryLearnLock(d.config.WorkspaceDir(), wb)
	require.NoError(t, err)
	require.True(t, ok)
	d.runWatchmanLearner(context.Background(), true)
	assert.Zero(t, src.calls.Load())
	assert.Empty(t, pipelineRunNames(t, database))

	unlock()
	d.runWatchmanLearner(context.Background(), true)
	assert.False(t, stillLearning(t, database, wb))
}

// The cycle phase leaves a workbench still learning to the learner.
func TestPhaseWatchmanLearn_SkipsUnlearned(t *testing.T) {
	d, database, wb, src, _ := learnerEnv(t, 3)
	d.phaseWatchmanLearn(context.Background())
	assert.Zero(t, src.calls.Load())
	assert.Empty(t, pipelineRunNames(t, database))
	assert.True(t, stillLearning(t, database, wb))

	// Learned (and every precedent flagged): the phase reads its new decisions.
	require.NoError(t, database.MarkWatchmanLearned(wb, time.Now()))
	d.phaseWatchmanLearn(context.Background())
	assert.Equal(t, int32(3), src.calls.Load())

	// Its lock held: skipped.
	unlock, ok, err := watchman.TryLearnLock(d.config.WorkspaceDir(), wb)
	require.NoError(t, err)
	require.True(t, ok)
	defer unlock()
	d.phaseWatchmanLearn(context.Background())
	assert.Equal(t, int32(3), src.calls.Load())
}

// The learner runs a pass at start, on every Watchman wake (forwarded
// with the twin's) and on each cycle's nudge; stop waits for the pass.
func TestWatchmanLearner_WakeAndCycleRunPasses(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		d, _, _, src, _ := learnerEnv(t, 1)
		// A source that never finishes: one Next per pass.
		src.stuck = true
		wakes := make(chan struct{})
		d.automationWakeCh = wakes
		stopWakes := d.startWakeForwarder(context.Background())
		stop := d.startWatchmanLearner(context.Background())
		synctest.Wait()
		require.Equal(t, int32(1), src.calls.Load(), "a pass at start")

		wakes <- struct{}{}
		synctest.Wait()
		require.Equal(t, int32(2), src.calls.Load(), "a Watchman wake runs a pass")
		require.Len(t, d.watchmanWakeCh, 1, "the twin gets the wake too")

		d.nudgeWatchmanLearner()
		synctest.Wait()
		require.Equal(t, int32(3), src.calls.Load(), "a cycle's nudge runs a pass")

		stop()
		stopWakes()
	})
}

// failingLabelGen fails every label call while fail is set.
type failingLabelGen struct {
	fail  atomic.Bool
	calls atomic.Int32
}

func (g *failingLabelGen) Generate(context.Context, string, string, string) (string, *digest.Usage, string, error) {
	g.calls.Add(1)
	if g.fail.Load() {
		return "", nil, "", errors.New("provider limit")
	}
	return `[{"category": "scope", "decision": true, "parked": false}]`, &digest.Usage{}, "", nil
}

// A relabel batch that fails (Learn only logs it) is a failed pass too: a
// wake skips the workbench, the next cycle retries the relabel.
func TestLearner_RelabelFailureRetriedOnNextCycleOnly(t *testing.T) {
	d, database, wb, src, _ := learnerEnv(t, 1)
	gen := &failingLabelGen{}
	gen.fail.Store(true)
	prev := watchmanGeneratorFactory
	watchmanGeneratorFactory = func(*config.Config) digest.Generator { return gen }
	t.Cleanup(func() { watchmanGeneratorFactory = prev })
	seedDesignPrecedents(t, database, wb) // five unflagged asks for the relabel pass

	d.runWatchmanLearner(context.Background(), true)
	require.Equal(t, int32(1), src.calls.Load(), "the sources are done")
	failed := gen.calls.Load()
	require.Positive(t, failed, "the relabel pass called the labeller")
	require.True(t, stillLearning(t, database, wb), "relabel still pending")

	d.runWatchmanLearner(context.Background(), false) // a wake
	assert.Equal(t, failed, gen.calls.Load(), "a wake skips the workbench")

	gen.fail.Store(false)
	d.runWatchmanLearner(context.Background(), true) // the next cycle
	assert.False(t, stillLearning(t, database, wb), "relabelled on the cycle")
}

// A workbench whose pass failed is retried on the next cycle, not on a
// Watchman wake.
func TestLearner_FailedRetriedOnNextCycleOnly(t *testing.T) {
	d, database, wb, src, _ := learnerEnv(t, 2)
	src.err = errors.New("source down")
	d.runWatchmanLearner(context.Background(), true)
	require.Equal(t, int32(1), src.calls.Load())

	d.runWatchmanLearner(context.Background(), false) // a wake
	assert.Equal(t, int32(1), src.calls.Load(), "a wake skips the failed workbench")

	src.err = nil
	d.runWatchmanLearner(context.Background(), true) // the next cycle
	assert.False(t, stillLearning(t, database, wb), "retried on the cycle")
}
