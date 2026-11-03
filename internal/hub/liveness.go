package hub

import (
	"context"
	"errors"
	"log"
	"maps"
	"sync"
	"time"

	"watchtower/internal/hub/slices"
	"watchtower/internal/hub/slices/sources"
	"watchtower/internal/sessionstart"
)

// livenessEvery is how often the hub lists session-host for the sources'
// liveness; livenessGap is the least time between two lists (a database
// write kicks one sooner, at most once per gap).
const (
	livenessEvery = 3 * time.Second
	livenessGap   = time.Second
)

// livenessKinds are the kinds a change of the running sessions republishes.
var livenessKinds = []slices.Kind{"terminal_session", "session_timeline", "permission_request", slices.KindSessionChat, slices.KindAskAlert}

// runLister is a session port that can list this workspace's running
// sessions in one call without starting a host (sessionstart.Port.Runs): the
// same host list the handlers' Live reads.
type runLister interface {
	Runs(ctx context.Context) (map[int64]time.Time, error)
}

// liveness is the sources' view of the running sessions: the last list of
// session-host, refreshed every livenessEvery and on a kick, only while a
// phone is linked (active). A failed list — no host answering included —
// clears the view at once: nothing live, not settled (no expiry is decided on
// a list that did not happen); no phone linked is the same empty view.
type liveness struct {
	list     func(context.Context) (map[int64]time.Time, error)
	active   func() bool
	every    time.Duration
	gap      time.Duration
	onChange func()
	kickc    chan struct{}

	mu      sync.Mutex
	cur     sources.Liveness
	failing string // the class of the failure logged last ("" = none)
}

func newLiveness(l runLister, active func() bool, every time.Duration, onChange func()) *liveness {
	if every <= 0 {
		every = livenessEvery
	}
	if active == nil {
		active = func() bool { return true }
	}
	return &liveness{list: l.Runs, active: active, every: every, gap: min(livenessGap, every), onChange: onChange,
		kickc: make(chan struct{}, 1)}
}

// get is the current liveness (a copy: the sources may keep it).
func (l *liveness) get() sources.Liveness {
	l.mu.Lock()
	defer l.mu.Unlock()
	return sources.Liveness{Runs: maps.Clone(l.cur.Runs), Settled: l.cur.Settled}
}

// kick asks for a list soon.
func (l *liveness) kick() {
	select {
	case l.kickc <- struct{}{}:
	default:
	}
}

// refresh lists the host once (or clears the view with no phone linked);
// onChange runs when the view changed.
func (l *liveness) refresh(ctx context.Context) {
	if !l.active() {
		l.set(sources.Liveness{})
		return
	}
	runs, err := l.list(ctx)
	if err != nil && ctx.Err() != nil {
		return
	}
	next := sources.Liveness{Runs: runs, Settled: true}
	class := ""
	switch {
	case errors.Is(err, sessionstart.ErrHostNotRunning):
		next, class = sources.Liveness{}, "host_not_running"
	case err != nil:
		next, class = sources.Liveness{}, errClass(err)
	}
	l.note(class)
	l.set(next)
}

// note logs a failure class once per transition, and the recovery.
func (l *liveness) note(class string) {
	l.mu.Lock()
	prev := l.failing
	l.failing = class
	l.mu.Unlock()
	switch {
	case class == prev:
	case class == "":
		log.Printf("hub: the session host lists again")
	default:
		log.Printf("hub: listing the running sessions failed (%s); nothing is live until it lists", class)
	}
}

func (l *liveness) set(next sources.Liveness) {
	l.mu.Lock()
	changed := next.Settled != l.cur.Settled ||
		!maps.EqualFunc(l.cur.Runs, next.Runs, func(a, b time.Time) bool { return a.Equal(b) })
	l.cur = next
	l.mu.Unlock()
	if changed && l.onChange != nil {
		l.onChange()
	}
}

// run refreshes until ctx ends, at most once per gap.
func (l *liveness) run(ctx context.Context) {
	t := time.NewTicker(l.every)
	defer t.Stop()
	for {
		l.refresh(ctx)
		pause := time.NewTimer(l.gap)
		select {
		case <-ctx.Done():
			pause.Stop()
			return
		case <-pause.C:
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		case <-l.kickc:
		}
	}
}
