package automations

import (
	"context"
	"time"

	"watchtower/internal/db"
)

// SetSchedulerZone replaces the scheduler's per-tick zone lookup (tests).
func SetSchedulerZone(s *Scheduler, zone func() *time.Location) { s.zone = zone }

// SetSchedulerBeforeWrite installs a hook run between reading a row and
// writing its schedule (tests simulate a concurrent writer there).
func SetSchedulerBeforeWrite(s *Scheduler, hook func(db.Automation)) { s.beforeWrite = hook }

// ZoneNameFromLink exposes zoneNameFromLink to the external tests.
var ZoneNameFromLink = zoneNameFromLink

// SetExecutorAbandoned replaces the executor's AbandonedRuns count (tests).
func SetExecutorAbandoned(e *Executor, count func() int) { e.abandoned = count }

// ExecutorReadyWaits is how many ready waits wait for a running slot (tests).
func ExecutorReadyWaits(e *Executor) int64 { return e.readyWaits.Load() }

// SetSchedulerProtected replaces the scheduler's privacy-protected folder
// predicate (tests).
func SetSchedulerProtected(s *Scheduler, protected func(string) bool) { s.protected = protected }

// SetIndexerProbe installs a recorder called with every path the indexer is
// about to touch on disk for the scheduler (tests).
func SetIndexerProbe(ix *Indexer, probe func(path string)) { ix.probe = probe }

// SessionReady is one check of a fresh session() wait on step stepID of
// run runID (tests drive it without the executor's poll).
func SessionReady(d *db.DB, runID, stepID int64) (bool, error) {
	w := &sessionWait{db: d, runID: runID, stepID: stepID}
	return w.ready(context.Background())
}

// SetBusBeforeMerge installs a hook run between Flush's enqueue and its merge
// into the coalesced run (tests claim the run there).
func SetBusBeforeMerge(b *Bus, hook func(runID int64)) { b.beforeMerge = hook }
