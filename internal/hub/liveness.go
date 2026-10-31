package hub

import (
	"context"
	"log"
	"maps"
	"sync"
	"time"

	"watchtower/internal/hub/slices"
	"watchtower/internal/hub/slices/sources"
)

// livenessEvery is how often the hub lists session-host for the sources'
// liveness (a write in the database kicks a list sooner).
const livenessEvery = 3 * time.Second

// livenessKinds are the kinds a change of the running sessions republishes.
var livenessKinds = []slices.Kind{"terminal_session", "session_timeline", "permission_request", slices.KindSessionChat, slices.KindAskAlert}

// runLister is a session port that can list this workspace's running
// sessions in one call (sessionstart.Port.Runs): the same host list the
// handlers' Live reads.
type runLister interface {
	Runs(ctx context.Context) (map[int64]time.Time, error)
}

// liveness is the sources' view of the running sessions: the last list of
// session-host, refreshed every livenessEvery and on a kick. Settled stays
// false until the first list succeeded; a failed list keeps the last one.
type liveness struct {
	list     func(context.Context) (map[int64]time.Time, error)
	every    time.Duration
	onChange func()
	kickc    chan struct{}

	mu  sync.Mutex
	cur sources.Liveness
}

func newLiveness(l runLister, every time.Duration, onChange func()) *liveness {
	if every <= 0 {
		every = livenessEvery
	}
	return &liveness{list: l.Runs, every: every, onChange: onChange, kickc: make(chan struct{}, 1)}
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

// refresh lists the host once; onChange runs when the running set or a run's
// start changed, or the first list settled.
func (l *liveness) refresh(ctx context.Context) {
	runs, err := l.list(ctx)
	if err != nil {
		if ctx.Err() == nil {
			log.Printf("hub: listing the running sessions failed (%s)", errClass(err))
		}
		return
	}
	l.mu.Lock()
	changed := !l.cur.Settled || !maps.EqualFunc(l.cur.Runs, runs, func(a, b time.Time) bool { return a.Equal(b) })
	l.cur = sources.Liveness{Runs: runs, Settled: true}
	l.mu.Unlock()
	if changed && l.onChange != nil {
		l.onChange()
	}
}

// run refreshes until ctx ends.
func (l *liveness) run(ctx context.Context) {
	t := time.NewTicker(l.every)
	defer t.Stop()
	for {
		l.refresh(ctx)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		case <-l.kickc:
		}
	}
}
