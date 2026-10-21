package daemon

import (
	"context"
	"time"
)

// wakeCheckInterval is how often the wake watcher compares the two clocks.
// It is measured on the monotonic clock, so it counts only awake time: the
// first check after a wake comes within this much awake time.
const wakeCheckInterval = 5 * time.Second

// sleepGapThreshold is how much more wall-clock than monotonic time must pass
// between two checks before the watcher reports a sleep. Well above any
// scheduling jitter, well below a real sleep.
const sleepGapThreshold = time.Minute

// sleepClock reads both clocks at one instant: the wall clock, which keeps
// running while the machine sleeps, and the monotonic elapsed time since an
// arbitrary fixed base, which on macOS (mach_absolute_time) does not.
type sleepClock func() (wall time.Time, mono time.Duration)

// systemSleepClock is the process's real sleepClock.
func systemSleepClock() sleepClock {
	base := time.Now()
	return func() (time.Time, time.Duration) {
		now := time.Now()
		// Round(0) strips the monotonic reading, so the wall subtraction the
		// watcher makes is a true wall-clock difference.
		return now.Round(0), now.Sub(base)
	}
}

// WatchWake returns a channel that fires when the machine has slept, carrying
// roughly how long it slept. Go's timers and its monotonic clock stop while a
// Mac sleeps, so wall-clock time running ahead of monotonic time between two
// checks by more than sleepGapThreshold is the sleep; the event fires on the
// first check after the wake. Sends are non-blocking (a wake already queued
// absorbs the next — the WatchTrigger contract), and the channel is closed
// once ctx is cancelled. A wall clock set forward by hand by more than the
// threshold reads as a sleep too; one set back never fires.
func WatchWake(ctx context.Context) <-chan time.Duration {
	ticker := time.NewTicker(wakeCheckInterval)
	ch := watchWake(ctx, ticker.C, systemSleepClock())
	go func() {
		<-ctx.Done()
		ticker.Stop()
	}()
	return ch
}

// watchWake is WatchWake over an injected check tick and clock.
func watchWake(ctx context.Context, ticks <-chan time.Time, clock sleepClock) <-chan time.Duration {
	ch := make(chan time.Duration, 1)
	go func() {
		defer close(ch)
		lastWall, lastMono := clock()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticks:
				wall, mono := clock()
				gap := wall.Sub(lastWall) - (mono - lastMono)
				lastWall, lastMono = wall, mono
				if gap > sleepGapThreshold {
					select {
					case ch <- gap:
					default:
					}
				}
			}
		}
	}()
	return ch
}
