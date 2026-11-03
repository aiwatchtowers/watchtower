// Package measure keeps the hub's content-free latency samples (Go hub plan
// 4 Task 6, RC §10): a phone action read → applied → the slice that shows it
// saved, per active transport. The processor stamps an action applied on its
// first read (Applied), the publisher stamps each kind it saved (Saved); a
// waiting apply resolves at the first save of one of its slice kinds whose
// source read for that kind began after it was applied. Samples are buffered in memory and
// written by Flush (once a second) outside any pass or cycle transaction;
// nothing leaves the device.
package measure

import (
	"slices"
	"sync"
	"time"

	"watchtower/internal/hub/state"
)

// Window is how long samples are kept; MaxRows caps the table; SaveWait is
// how long an applied action waits for its slice save before it is dropped
// with no applied_saved or read_saved sample.
const (
	Window   = 7 * 24 * time.Hour
	MaxRows  = 20000
	SaveWait = 60 * time.Second
)

// maxWaiting caps the applies waiting for a save (the oldest dropped);
// maxBuffered caps the samples between two flushes (newer ones dropped).
const (
	maxWaiting  = 256
	maxBuffered = 4096
)

// waiting is an applied action whose slice save has not been seen yet.
type waiting struct {
	transport         string
	readAt, appliedAt time.Time
	kinds             []string
}

// Recorder buffers the samples. A nil *Recorder records nothing.
type Recorder struct {
	store *state.Store
	clock func() time.Time

	mu      sync.Mutex
	waiting []waiting
	buf     []state.LatencySample
}

// New returns a recorder writing to store; clock (nil = time.Now) dates the
// expiry of waiting applies and the prune window.
func New(store *state.Store, clock func() time.Time) *Recorder {
	if clock == nil {
		clock = time.Now
	}
	return &Recorder{store: store, clock: clock}
}

// measured reports whether transport is one the table keeps.
func measured(transport string) bool { return transport == "cloudkit" || transport == "relay" }

func ms(d time.Duration) int64 { return max(0, d.Milliseconds()) }

// Applied stamps an action applied on its first read: readAt is when the
// transport handed the processor the record's batch, appliedAt when its
// outcome committed, kinds the slice kinds its apply nudged (none: no save
// to wait for). A zero readAt (a held action drained later) records nothing.
func (r *Recorder) Applied(transport string, readAt, appliedAt time.Time, kinds []string) {
	if r == nil || readAt.IsZero() || !measured(transport) {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.add(state.LatencySample{At: appliedAt, Transport: transport, Step: state.StepReadApplied, MS: ms(appliedAt.Sub(readAt))})
	if len(kinds) == 0 {
		return
	}
	if len(r.waiting) >= maxWaiting {
		r.waiting = slices.Delete(r.waiting, 0, len(r.waiting)-maxWaiting+1)
	}
	r.waiting = append(r.waiting, waiting{transport: transport, readAt: readAt, appliedAt: appliedAt, kinds: slices.Clone(kinds)})
}

// Saved stamps a successful save of kind whose source read began at readAt
// and whose write finished at doneAt. Every waiting apply of that kind and
// transport applied before readAt (so the read saw it), and within SaveWait
// of doneAt, resolves: applied_saved and read_saved are written together.
func (r *Recorder) Saved(transport, kind string, readAt, doneAt time.Time) {
	if r == nil || !measured(transport) {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	kept := r.waiting[:0]
	for _, w := range r.waiting {
		switch {
		case doneAt.Sub(w.appliedAt) > SaveWait:
			continue // too late: no sample
		case w.transport != transport || !slices.Contains(w.kinds, kind) || !readAt.After(w.appliedAt):
			kept = append(kept, w)
			continue
		}
		r.add(state.LatencySample{At: doneAt, Transport: transport, Step: state.StepAppliedSaved, MS: ms(doneAt.Sub(w.appliedAt))})
		r.add(state.LatencySample{At: doneAt, Transport: transport, Step: state.StepReadSaved, MS: ms(doneAt.Sub(w.readAt))})
	}
	clear(r.waiting[len(kept):])
	r.waiting = kept
}

// add buffers x; r.mu is held.
func (r *Recorder) add(x state.LatencySample) {
	if len(r.buf) < maxBuffered {
		r.buf = append(r.buf, x)
	}
}

// Flush drops the applies that waited past SaveWait and writes the buffered
// samples in one short transaction. Samples a failed write held are dropped
// (a timing lost, never retried into a growing buffer).
func (r *Recorder) Flush() error {
	if r == nil {
		return nil
	}
	now := r.clock()
	r.mu.Lock()
	r.waiting = slices.DeleteFunc(r.waiting, func(w waiting) bool { return now.Sub(w.appliedAt) > SaveWait })
	buf := r.buf
	r.buf = nil
	r.mu.Unlock()
	return r.store.AddLatencySamples(buf)
}

// Prune keeps the samples of the last Window, at most MaxRows of them.
func (r *Recorder) Prune() error {
	if r == nil {
		return nil
	}
	return r.store.PruneLatency(r.clock().Add(-Window), MaxRows)
}
