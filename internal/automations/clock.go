package automations

import "time"

// Clock is the time source of the indexer, scheduler and executor; tests pass
// a fake one (spec §7.2).
type Clock interface {
	Now() time.Time
	After(d time.Duration) <-chan time.Time
}

// RealClock is the wall clock.
type RealClock struct{}

// Now returns time.Now().
func (RealClock) Now() time.Time { return time.Now() }

// After returns time.After(d).
func (RealClock) After(d time.Duration) <-chan time.Time { return time.After(d) }
