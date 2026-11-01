package hub

import (
	"log"
	"maps"
	"sync"
	"time"

	"watchtower/internal/hub/slices"
	"watchtower/internal/hub/state"
)

// Desktop's view inputs (Go hub plan 3 Task 5, spec §8 p. 4a): what only the
// Desktop knows about the sessions it shows — the sessions waiting in its
// Undo batch (PROJ-17), never published, and the background counts it shows
// over after two failed staleness probes (#411). Desktop sends the whole
// view on the control socket (desktop_view) whenever it changes; the hub
// keeps it in memory only, and only while the Desktop heartbeat is fresh.

// viewKinds are the slices that read the published sessions: the sessions
// themselves, the workbench counts, the timeline and the work alerts.
var viewKinds = []slices.Kind{"terminal_session", "workbench", "session_timeline", slices.KindAskAlert}

// DesktopView is one desktop_view report: the hidden and shown-over session
// ids, and when the hub got it. In memory only; empty once the Desktop
// heartbeat is stale (> state.DesktopFreshFor).
type DesktopView struct {
	Hidden, DisplayOver map[int64]bool
	At                  time.Time
}

// desktopViewBox is the supervisor's copy of the last view, so a hub restart
// (a rename, a policy change) keeps it.
type desktopViewBox struct {
	mu sync.Mutex
	v  DesktopView
}

// set stores v and reports whether its ids differ from the stored ones.
func (b *desktopViewBox) set(v DesktopView) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	changed := !maps.Equal(b.v.Hidden, v.Hidden) || !maps.Equal(b.v.DisplayOver, v.DisplayOver)
	b.v = v
	return changed
}

func (b *desktopViewBox) get() DesktopView {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.v
}

// clearIfOlder drops the view when it was reported before cutoff.
func (b *desktopViewBox) clearIfOlder(cutoff time.Time) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.v.At.Before(cutoff) {
		b.v = DesktopView{}
	}
}

// idSet is a request's ids as a set (nil for none).
func idSet(ids []int64) map[int64]bool {
	if len(ids) == 0 {
		return nil
	}
	out := make(map[int64]bool, len(ids))
	for _, id := range ids {
		out[id] = true
	}
	return out
}

// storeDesktopView stores the view for the sources and, when its ids
// changed, republishes what reads them on h (nil = no hub runs: the next hub
// reads it at its start). The log line carries counts only.
func (s *supervisor) storeDesktopView(v DesktopView, h *hubRuntime) {
	if !s.view.set(v) {
		return
	}
	log.Printf("hub: desktop view: %d hidden, %d shown over", len(v.Hidden), len(v.DisplayOver))
	if h != nil {
		h.publishSoon(viewKinds...)
	}
}

// SetDesktopView stores v for the running hub's sources and republishes the
// sessions, the workbench counts, the timeline and the alerts when it
// changed.
func (h *hubRuntime) SetDesktopView(v DesktopView) { h.sup.storeDesktopView(v, h) }

// desktopView is the sources' View: the stored ids while the Desktop
// heartbeat is fresh, else none (an unreadable heartbeat counts as stale, so
// a hidden session is published rather than lost). A view older than the
// heartbeat's freshness is dropped once the heartbeat went stale, so a later
// heartbeat never brings back what the Desktop showed before it went away.
func (s *supervisor) desktopView() (hidden, displayOver map[int64]bool) {
	v := s.view.get()
	if len(v.Hidden) == 0 && len(v.DisplayOver) == 0 {
		return nil, nil
	}
	now := s.o.Clock()
	fresh, _, err := s.st.DesktopHost(now)
	if err != nil || !fresh {
		s.view.clearIfOlder(now.Add(-state.DesktopFreshFor))
		return nil, nil
	}
	return maps.Clone(v.Hidden), maps.Clone(v.DisplayOver)
}
