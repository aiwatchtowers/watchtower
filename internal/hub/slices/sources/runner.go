package sources

// The shared parts of the runner-fed sources (session chat, session report
// and its summaries, the git refresher): the wait between passes, the
// bounded run, and the per-workbench cadence of the git refresher and the
// summary runner. The Swift hub runs the CLI for each; the Go hub calls the
// same Go functions in-process (spec §9).

import (
	"context"
	"errors"
	"slices"
	"sync"
	"time"
)

// runnerMinimumGap is HubRunnerWake.standardMinimumGap: the least time from
// the end of a pass to the next one a signal starts.
const runnerMinimumGap = 5 * time.Second

// errRunTimedOut is a bounded run that did not return within its timeout.
var errRunTimedOut = errors.New("the run timed out")

// runnerWake is HubRunnerWake: the wait between two passes of a runner. A
// signal — a session state change, a phone request — ends the wait; one sent
// during a pass ends the next wait, so none is lost. A signalled wait still
// lasts minimumGap from its start, so a burst of signals costs one pass per
// gap. With no signal a wait lasts its full duration; a cancelled ctx ends it.
type runnerWake struct {
	ch         chan struct{}
	minimumGap time.Duration
}

func newRunnerWake() *runnerWake {
	return &runnerWake{ch: make(chan struct{}, 1), minimumGap: runnerMinimumGap}
}

// signal ends the wait in progress, or the next one.
func (w *runnerWake) signal() {
	select {
	case w.ch <- struct{}{}:
	default:
	}
}

// wait returns after d, on a signal (no sooner than minimumGap after the
// call, capped at d), or when ctx ends.
func (w *runnerWake) wait(ctx context.Context, d time.Duration) {
	if d <= 0 || ctx.Err() != nil {
		return
	}
	start := time.Now()
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return
	case <-t.C:
		return
	case <-w.ch:
	}
	if rest := min(w.minimumGap, d) - time.Since(start); rest > 0 {
		gap := time.NewTimer(rest)
		defer gap.Stop()
		select {
		case <-ctx.Done():
			return
		case <-gap.C:
		}
	}
	// The pass that follows covers every signal sent during the gap.
	select {
	case <-w.ch:
	default:
	}
}

// waitUntil is HubRunnerWake.duration: the wait until due (a deferred run's
// earliest time; past means at once), never longer than idle; idle when due
// is zero.
func waitUntil(due, now time.Time, idle time.Duration) time.Duration {
	if due.IsZero() {
		return idle
	}
	return min(max(due.Sub(now), 0), idle)
}

// bounded runs fn under ctx with a deadline of timeout (MobileHubService
// .bounded): errRunTimedOut when fn did not return in time. fn's ctx ends at
// the deadline, so a git or gh child under it is killed (gitbin
// .WithProcessGroup); a fn that ignores its ctx is abandoned and its result
// dropped.
func bounded[T any](ctx context.Context, timeout time.Duration, fn func(context.Context) (T, error)) (T, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	type result struct {
		v   T
		err error
	}
	done := make(chan result, 1)
	go func() {
		v, err := fn(ctx)
		done <- result{v, err}
	}()
	var zero T
	select {
	case r := <-done:
		if r.err != nil && errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return zero, errRunTimedOut
		}
		return r.v, r.err
	case <-ctx.Done():
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return zero, errRunTimedOut
		}
		return zero, ctx.Err()
	}
}

// cadence is the per-workbench state of the git refresher and the summary
// runner (WorkbenchGitRefresher / SessionReportSummaryRunner): each
// workbench's last good value, its last attempt and a pending
// session-change request.
type cadence[T any] struct {
	every, minSpacing time.Duration

	mu      sync.Mutex
	entries map[int64]*cadenceEntry[T]
	// nextDue is when the earliest request the last pass deferred (inside
	// minSpacing) is due; zero when it deferred none.
	nextDue time.Time
}

type cadenceEntry[T any] struct {
	value     T
	hasValue  bool
	last      time.Time // zero = never attempted
	requested bool
}

// cadenceTaken is one due run and what takeDue changed, so a pass that did
// not finish it can put it back.
type cadenceTaken struct {
	id            int64
	prevLast      time.Time
	prevRequested bool
	stamp         time.Time
}

func newCadence[T any](every, minSpacing time.Duration) *cadence[T] {
	return &cadence[T]{every: every, minSpacing: minSpacing, entries: map[int64]*cadenceEntry[T]{}}
}

// value is id's last good value.
func (c *cadence[T]) value(id int64) (T, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if e, ok := c.entries[id]; ok && e.hasValue {
		return e.value, true
	}
	var zero T
	return zero, false
}

// ids is every workbench with an entry.
func (c *cadence[T]) ids() []int64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]int64, 0, len(c.entries))
	for id := range c.entries {
		out = append(out, id)
	}
	return out
}

// request marks id for a run no sooner than minSpacing after its last one;
// known only requests a workbench a pass has already listed.
func (c *cadence[T]) request(id int64, knownOnly bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.entries[id]
	if !ok {
		if knownOnly {
			return
		}
		e = &cadenceEntry[T]{}
		c.entries[id] = e
	}
	e.requested = true
}

// takeDue forgets the workbenches not in keep, then stamps the due ones of
// candidates in keep (in order) as attempted at now: one never attempted when
// first(id, requested) says so, an attempted one every `every` when
// regular(id), and a requested one minSpacing after its last attempt. It
// notes when the earliest deferred request is due.
func (c *cadence[T]) takeDue(candidates []int64, keep map[int64]bool, now time.Time,
	first func(id int64, requested bool) bool, regular func(id int64) bool,
) []cadenceTaken {
	c.mu.Lock()
	defer c.mu.Unlock()
	for id := range c.entries {
		if !keep[id] {
			delete(c.entries, id)
		}
	}
	c.nextDue = time.Time{}
	var due []cadenceTaken
	for _, id := range candidates {
		if !keep[id] {
			continue
		}
		e, ok := c.entries[id]
		if !ok {
			e = &cadenceEntry[T]{}
		}
		var isDue bool
		if e.last.IsZero() {
			isDue = first(id, e.requested)
		} else {
			elapsed := now.Sub(e.last)
			isDue = (regular(id) && elapsed >= c.every) || (e.requested && elapsed >= c.minSpacing)
		}
		switch {
		case isDue:
			due = append(due, cadenceTaken{id: id, prevLast: e.last, prevRequested: e.requested, stamp: now})
			e.last, e.requested = now, false
		case e.requested && !e.last.IsZero():
			if at := e.last.Add(c.minSpacing); c.nextDue.IsZero() || at.Before(c.nextDue) {
				c.nextDue = at
			}
		}
		c.entries[id] = e
	}
	return due
}

// restore puts back the cadence state of runs a pass did not finish, unless
// a later pass stamped them since.
func (c *cadence[T]) restore(unfinished []cadenceTaken) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for _, t := range unfinished {
		e, ok := c.entries[t.id]
		if !ok || !e.last.Equal(t.stamp) {
			continue
		}
		e.last = t.prevLast
		e.requested = e.requested || t.prevRequested
	}
}

// store keeps v as id's last good value, unless the workbench was forgotten
// while the run was out.
func (c *cadence[T]) store(id int64, v T) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if e, ok := c.entries[id]; ok {
		e.value, e.hasValue = v, true
	}
}

// nextWait is the wait before the next pass: until the earliest request the
// last pass deferred, else idle; taken once.
func (c *cadence[T]) nextWait(now time.Time, idle time.Duration) time.Duration {
	c.mu.Lock()
	due := c.nextDue
	c.nextDue = time.Time{}
	c.mu.Unlock()
	return waitUntil(due, now, idle)
}

// sortedUnion is a ∪ b in ascending order.
func sortedUnion(a []int64, b map[int64]bool) []int64 {
	set := map[int64]bool{}
	for _, id := range a {
		set[id] = true
	}
	for id := range b {
		set[id] = true
	}
	out := make([]int64, 0, len(set))
	for id := range set {
		out = append(out, id)
	}
	slices.Sort(out)
	return out
}
