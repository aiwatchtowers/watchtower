package automations

import (
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
