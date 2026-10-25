package daemon

import (
	"bytes"
	"context"
	"log"
	"os"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/ideas"
)

// forBothIdeaFinderModes runs body once with the Idea finder on its legacy
// phase and once on the built-in, each over a fresh daemon (ideas on, a
// real ideas pipeline with a nil generator, a clean no-op) logging to
// logger(t).
func forBothIdeaFinderModes(t *testing.T, logger func(t *testing.T) *log.Logger, body func(t *testing.T, d *Daemon, cfg *config.Config)) {
	for _, active := range []bool{false, true} {
		t.Run(map[bool]string{false: "legacy", true: "builtin"}[active], func(t *testing.T) {
			orch, cfg, _ := testDaemonWithTempHome(t)
			cfg.Ideas.Enabled = true

			database := db.OpenTestDB(t)

			d := newDaemon(orch, cfg)
			d.SetLogger(logger(t))
			d.SetDB(database)
			d.SetIdeasPipeline(ideas.New(database, cfg, nil, log.New(os.Stderr, "[test-ideas-pipe] ", 0)))
			wireTestBuiltins(t, d, database, cfg, automations.RealClock{})
			d.builtinActive[ideaFinderID] = active
			body(t, d, cfg)
		})
	}
}

func stderrIdeasLogger(*testing.T) *log.Logger { return log.New(os.Stderr, "[test-ideas] ", 0) }

// TestDaemon_PhaseIdeas_SkipsWhileBackfillLockFresh pins GB7's bidirectional
// lock (spec §5's mutual-exclusion promise, now enforced both ways): with a
// CLI `ideas mine --from` backfill holding a fresh lock, phaseIdeas's own
// AcquireBackfillLock attempt must fail and the phase must not run at all —
// not even far enough to advance the throttle timestamp — so the two never
// interleave consumption of the same floors. Driven through the Idea finder
// slot (phaseIdeaFinder) on the legacy phase and on the built-in, whose gate
// probes the lock.
func TestDaemon_PhaseIdeas_SkipsWhileBackfillLockFresh(t *testing.T) {
	forBothIdeaFinderModes(t, stderrIdeasLogger, func(t *testing.T, d *Daemon, cfg *config.Config) {
		release, err := ideas.AcquireBackfillLock(cfg.WorkspaceDir(), "CLI backfill")
		require.NoError(t, err)
		defer release()

		d.phaseIdeaFinder(context.Background())

		assert.True(t, d.lastIdeas.IsZero(), "phaseIdeas must skip entirely — never even run the pipeline — while a fresh CLI backfill lock exists")
		assertNoAutomationRuns(t, d.db)
	})
}

// TestDaemon_PhaseIdeas_ThrottlesLockSkipLog pins GB7's log throttle: while
// a backfill lock stays held across repeated poll ticks, phaseIdeas must
// still skip on EVERY tick (the daemon's own lastIdeas throttle never
// advances, since the pipeline never actually runs), but must not repeat
// the skip log line more than once per ideasLockSkipLogThrottle window —
// otherwise a long CLI backfill would flood the log with an identical line
// on every single poll tick for its entire duration.
func TestDaemon_PhaseIdeas_ThrottlesLockSkipLog(t *testing.T) {
	var logBuf bytes.Buffer
	logger := func(*testing.T) *log.Logger {
		logBuf.Reset()
		return log.New(&logBuf, "", 0)
	}
	forBothIdeaFinderModes(t, logger, func(t *testing.T, d *Daemon, cfg *config.Config) {
		release, err := ideas.AcquireBackfillLock(cfg.WorkspaceDir(), "CLI backfill")
		require.NoError(t, err)
		defer release()

		d.phaseIdeaFinder(context.Background())
		d.phaseIdeaFinder(context.Background())
		d.phaseIdeaFinder(context.Background())

		out := logBuf.String()
		assert.Equal(t, 1, strings.Count(out, "mining right now"),
			"the skip log line must be throttled, not repeated on every poll tick within the window")
	})
}

// TestDaemon_PhaseIdeas_RunsWhenLockAbsent is the control: with no lock file
// at all, phaseIdeas proceeds past the guard and runs normally (a nil
// generator makes the pipeline itself a clean no-op, so this only proves the
// guard didn't false-positive).
func TestDaemon_PhaseIdeas_RunsWhenLockAbsent(t *testing.T) {
	forBothIdeaFinderModes(t, stderrIdeasLogger, func(t *testing.T, d *Daemon, _ *config.Config) {
		d.phaseIdeaFinder(context.Background())

		assert.False(t, d.lastIdeas.IsZero(), "phaseIdeas must run (and advance the throttle) when no backfill lock exists")
	})
}
