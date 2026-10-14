// Package automationstest holds the fakes automation tests share across
// packages (P1–P6): a settable clock, a recording generator and, later, the
// registry fake and the seed helper.
package automationstest

import (
	"sync"
	"time"
)

// FakeClock is a settable automations.Clock. The zero value starts at the
// zero time; Set or NewFakeClock gives it a start. After channels fire when
// Advance or Set moves the clock to or past their deadline. It is safe for
// concurrent use.
type FakeClock struct {
	mu      sync.Mutex
	now     time.Time
	waiters []fakeWaiter
}

type fakeWaiter struct {
	at time.Time
	ch chan time.Time
}

// NewFakeClock returns a FakeClock reading now.
func NewFakeClock(now time.Time) *FakeClock { return &FakeClock{now: now} }

// Now returns the clock's current time.
func (c *FakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

// After returns a channel that receives the clock's time once it reaches
// Now()+d; d ≤ 0 fires at once.
func (c *FakeClock) After(d time.Duration) <-chan time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	ch := make(chan time.Time, 1)
	at := c.now.Add(d)
	if !at.After(c.now) {
		ch <- c.now
		return ch
	}
	c.waiters = append(c.waiters, fakeWaiter{at: at, ch: ch})
	return ch
}

// Advance moves the clock forward by d (a negative d moves it back).
func (c *FakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.setLocked(c.now.Add(d))
}

// Set moves the clock to t, forwards or backwards.
func (c *FakeClock) Set(t time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.setLocked(t)
}

func (c *FakeClock) setLocked(t time.Time) {
	c.now = t
	kept := c.waiters[:0]
	for _, w := range c.waiters {
		if t.Before(w.at) {
			kept = append(kept, w)
			continue
		}
		w.ch <- t
	}
	c.waiters = kept
}
