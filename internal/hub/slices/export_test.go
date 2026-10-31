package slices

import (
	"context"
	"time"
)

// The seams the external tests (change_sources_test.go, over the real
// database sources) drive.

// FakeTime is a test clock with timers.
type FakeTime = fakeTime

// NewFakeTime starts a FakeTime.
func NewFakeTime() *FakeTime { return newFakeTime() }

// Advance moves the clock and fires the timers due; true when one fired.
func (f *fakeTime) Advance(d time.Duration) bool { return f.advance(d) }

// Armed is how many timers were ever armed.
func (f *fakeTime) Armed() int { return f.armedCount() }

// SetRunClock puts Run's monotonic clock and timers on a test clock.
func SetRunClock(p *Publisher, mono func() time.Time, timer func(time.Duration) (<-chan time.Time, func())) {
	p.mono, p.timer = mono, timer
}

// SetWatchTimer puts the watch's wait between polls on a test clock.
func SetWatchTimer(w *ChangeWatch, timer func(time.Duration) (<-chan time.Time, func())) {
	w.timer = timer
}

// PollOnce is one data_version read.
func (w *ChangeWatch) PollOnce(ctx context.Context) (bool, error) { return w.poll(ctx) }
