package daemon

import (
	"context"
	"time"

	"watchtower/internal/sync"
)

// The adaptive Slack cadence (#1709). Each account's next Slack run is due
// base × 2^level after the last one started, base being the poll interval
// and the interval capped at cadenceMax. A 429 lengthens it, a busy run
// shortens it to base, a run of quiet ones lengthens it, an ordinary one
// shortens it a step. Sync Now always runs Slack, and so does a daemon's
// first cycle: the state lives in memory.
const (
	// cadenceMax caps the interval: a backed-off account is never more
	// than an hour behind.
	cadenceMax = 60 * time.Minute
	// heavyPages blanket-search pages make a clean run busy: back to base.
	heavyPages = 5
	// quietMessages or fewer make a clean run quiet; every quietRuns-th
	// quiet run in a row lengthens the interval a step.
	quietMessages = 5
	quietRuns     = 3
)

// slackCadence is one account's cadence state. Touched only by
// phaseSlackSync, which never runs twice at once.
type slackCadence struct {
	level       int
	quietStreak int
	nextDue     time.Time
	// base is the interval at level 0, kept for due's tolerance.
	base time.Duration
}

// after applies a finished run's outcome; now is when the cycle's Slack
// phase started (every account's anchor), so the next run is due a whole
// interval after the phase began, whatever this run or an earlier
// account's took.
//
// A 429 wins over everything: the level goes up and the run waits for the
// backed-off interval even with pages left (the resume position waits in
// memory), so a storm backs the account off instead of hammering. A run
// that only ran out of its fetch deadline with pages left is due next
// cycle; one that stopped on another error waits the interval, or every
// tick would ask the same failing page again.
func (c *slackCadence) after(o sync.RunOutcome, base time.Duration, now time.Time) {
	c.base = base
	switch {
	case o.RateLimited:
		c.up(base)
		c.quietStreak = 0
	case o.Pages >= heavyPages:
		c.level = 0
		c.quietStreak = 0
	case o.Messages <= quietMessages:
		c.quietStreak++
		if c.quietStreak >= quietRuns {
			c.up(base)
			c.quietStreak = 0
		}
	default:
		c.level = max(c.level-1, 0)
		c.quietStreak = 0
	}
	if o.ResumePending && o.DeadlineStopped && !o.RateLimited {
		c.nextDue = now
		return
	}
	c.nextDue = now.Add(c.interval(base))
}

// up raises the level a step unless the interval already reached the cap.
func (c *slackCadence) up(base time.Duration) {
	if base > 0 && base<<c.level < cadenceMax {
		c.level++
	}
}

// interval is base × 2^level, capped at cadenceMax.
func (c *slackCadence) interval(base time.Duration) time.Duration {
	return min(base<<c.level, cadenceMax)
}

// retryNextCycle makes the account due next cycle and keeps its level: a
// run that failed for another reason than a rate limit (the network, a
// cancelled cycle) says nothing about Slack's limits or the data volume.
func (c *slackCadence) retryNextCycle() {
	c.nextDue = time.Time{}
}

// due reports whether the account's Slack run is due at now. A manual
// trigger and the first run after the daemon starts always are. Half a base
// interval of tolerance absorbs the poll ticker firing a little before the
// due instant, so at base every tick runs.
func (c *slackCadence) due(now time.Time, manual bool) bool {
	if manual || c.nextDue.IsZero() {
		return true
	}
	return !now.Before(c.nextDue.Add(-c.base / 2))
}

// slackCadence returns the account's cadence, creating it (due at once) on
// first use.
func (d *Daemon) slackCadence(accountID int64) *slackCadence {
	if d.slackCadences == nil {
		d.slackCadences = map[int64]*slackCadence{}
	}
	c := d.slackCadences[accountID]
	if c == nil {
		c = &slackCadence{}
		d.slackCadences[accountID] = c
	}
	return c
}

// cadenceClock is the cadence's clock: d.cadenceNow, else time.Now.
func (d *Daemon) cadenceClock() time.Time {
	if d.cadenceNow != nil {
		return d.cadenceNow()
	}
	return time.Now()
}

type manualSyncKey struct{}

// withManualSync marks a cycle's fetch context as a manual trigger's (Sync
// Now), which runs every Slack account whatever its cadence.
func withManualSync(ctx context.Context) context.Context {
	return context.WithValue(ctx, manualSyncKey{}, true)
}

// isManualSync reports whether ctx belongs to a manually triggered cycle.
func isManualSync(ctx context.Context) bool {
	manual, _ := ctx.Value(manualSyncKey{}).(bool)
	return manual
}
