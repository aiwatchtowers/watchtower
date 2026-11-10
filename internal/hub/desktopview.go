package hub

import (
	"log"
	"maps"
	"sync"
	"time"

	"watchtower/internal/hub/slices"
	"watchtower/internal/hub/slices/sources"
	"watchtower/internal/hub/state"
)

// Desktop's view inputs (Go hub plan 3 Task 5, spec §8 p. 4a): what only the
// Desktop knows about the sessions it shows — the sessions waiting in its
// Undo batch (PROJ-17), never published, and the background counts it shows
// over after two failed staleness probes (#411), each with the run and the
// report stamp it was judged for. Desktop sends the whole view on the
// control socket (desktop_view) at its start, whenever it changes and
// whenever a heartbeat answer says view_needed; the hub keeps it in memory
// only, and only while the Desktop heartbeat is fresh.

// viewKinds are the slices that read the published sessions: the sessions
// themselves, the workbench counts, the timeline and the work alerts.
var viewKinds = []slices.Kind{"terminal_session", "workbench", "session_timeline", slices.KindAskAlert}

// MaxViewIDs caps each list of a desktop_view (Hidden, DisplayOver); a
// larger request is refused ErrClassTooManyIDs.
const MaxViewIDs = 10_000

// freshCacheFor is how long one read of the Desktop heartbeat's freshness
// serves the sources: a publish pass reads it once, not once per source.
const freshCacheFor = time.Second

// staleCheckAfter is when, after a heartbeat, the hub looks whether the
// heartbeat went stale (it then republishes the view's slices).
const staleCheckAfter = state.DesktopFreshFor + time.Second

// ShownOverWire is one shown-over count of a desktop_view: the session, the
// run start the Desktop judged it for (null = the session was not live) and
// the count's agent_background_at stamp (null = none).
type ShownOverWire struct {
	ID         int64      `json:"id"`
	Run        *time.Time `json:"run"`
	ReportedAt *string    `json:"reported_at"`
}

// DesktopView is one desktop_view report: the hidden session ids, the
// shown-over counts, and when the hub got it. In memory only; empty once the
// Desktop heartbeat is stale (> state.DesktopFreshFor).
type DesktopView struct {
	Hidden      map[int64]bool
	DisplayOver map[int64]sources.ShownOver
	At          time.Time
}

// desktopViewOf is a request's view (nil maps for none).
func desktopViewOf(r ControlRequest, at time.Time) DesktopView {
	v := DesktopView{At: at}
	if len(r.Hidden) > 0 {
		v.Hidden = make(map[int64]bool, len(r.Hidden))
		for _, id := range r.Hidden {
			v.Hidden[id] = true
		}
	}
	if len(r.DisplayOver) > 0 {
		v.DisplayOver = make(map[int64]sources.ShownOver, len(r.DisplayOver))
		for _, o := range r.DisplayOver {
			var so sources.ShownOver
			if o.Run != nil {
				so.Run = *o.Run
			}
			if o.ReportedAt != nil {
				so.ReportedAt = *o.ReportedAt
			}
			v.DisplayOver[o.ID] = so
		}
	}
	return v
}

// desktopViewBox is the supervisor's copy of the last view, so a hub restart
// (a rename, a policy change) keeps it, and the cached heartbeat freshness.
type desktopViewBox struct {
	mu      sync.Mutex
	v       DesktopView
	current bool // a view was reported and not dropped since

	freshAt  time.Time // when fresh was read; zero = not cached
	fresh    bool
	gen      uint64 // bumped by every invalidation: a read begun before one is not cached
	staleChk *time.Timer
	stopped  bool // Run ended: no stale check is armed any more
}

// set stores v and reports whether it differs from the stored view.
func (b *desktopViewBox) set(v DesktopView) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	changed := !b.current || !maps.Equal(b.v.Hidden, v.Hidden) || !maps.Equal(b.v.DisplayOver, v.DisplayOver)
	b.v, b.current = v, true
	return changed
}

func (b *desktopViewBox) get() (DesktopView, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.v, b.current
}

// clearIfOlder drops the view when it was reported before cutoff.
func (b *desktopViewBox) clearIfOlder(cutoff time.Time) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.current && b.v.At.Before(cutoff) {
		b.v, b.current = DesktopView{}, false
	}
}

// invalidate forgets the cached heartbeat freshness.
func (b *desktopViewBox) invalidate() {
	b.mu.Lock()
	b.freshAt = time.Time{}
	b.gen++
	b.mu.Unlock()
}

// storeDesktopView stores the view for the sources and, when it changed,
// republishes what reads it on h (nil = no hub runs: the next hub reads it
// at its start). The log line carries counts only.
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

// desktopFresh is the heartbeat's freshness at now, read at most once per
// freshCacheFor (an unreadable heartbeat counts as stale).
func (s *supervisor) desktopFresh(now time.Time) bool {
	b := &s.view
	b.mu.Lock()
	if !b.freshAt.IsZero() && !now.Before(b.freshAt) && now.Sub(b.freshAt) < freshCacheFor {
		fresh := b.fresh
		b.mu.Unlock()
		return fresh
	}
	gen := b.gen
	b.mu.Unlock()
	fresh, _, err := s.st.DesktopHost(now)
	fresh = err == nil && fresh
	if s.o.afterFreshRead != nil {
		s.o.afterFreshRead()
	}
	b.mu.Lock()
	if b.gen == gen { // no heartbeat came between the read and here
		b.freshAt, b.fresh = now, fresh
	}
	b.mu.Unlock()
	return fresh
}

// desktopView is the sources' View: the stored view while the Desktop
// heartbeat is fresh, else none (a hidden session is then published rather
// than lost). A view older than the heartbeat's freshness is dropped once
// the heartbeat went stale, so a later heartbeat never brings back what the
// Desktop showed before it went away (the heartbeat answer then asks for a
// new view).
func (s *supervisor) desktopView() (hidden map[int64]bool, displayOver map[int64]sources.ShownOver) {
	v, current := s.view.get()
	if !current || (len(v.Hidden) == 0 && len(v.DisplayOver) == 0) {
		return nil, nil
	}
	now := s.o.Clock()
	if !s.desktopFresh(now) {
		s.view.clearIfOlder(now.Add(-state.DesktopFreshFor))
		return nil, nil
	}
	return maps.Clone(v.Hidden), maps.Clone(v.DisplayOver)
}

// desktopBeat follows a Desktop heartbeat written at now: it forgets the
// cached freshness, re-arms the stale check and, when the heartbeat was
// stale before (or never came), drops a view older than the freshness window
// and republishes the view's slices, so a view sent before this first fresh
// beat applies now. It reports whether the hub needs a view from Desktop.
func (s *supervisor) desktopBeat(now time.Time, wasFresh bool) (viewNeeded bool) {
	b := &s.view
	b.mu.Lock()
	b.freshAt = time.Time{}
	b.gen++
	if b.staleChk != nil {
		b.staleChk.Stop()
	}
	if !b.stopped {
		b.staleChk = time.AfterFunc(s.o.staleCheck(), s.desktopWentStale)
	}
	b.mu.Unlock()
	if !wasFresh {
		s.view.clearIfOlder(now.Add(-state.DesktopFreshFor))
		s.publishViewSoon()
	}
	_, current := s.view.get()
	return !current
}

// desktopWentStale runs staleCheckAfter after the last heartbeat: no newer
// beat came, so the view no longer applies; the view's slices republish
// (a hidden session reappears when Desktop died).
func (s *supervisor) desktopWentStale() {
	s.view.invalidate()
	if v, current := s.view.get(); current && (len(v.Hidden) > 0 || len(v.DisplayOver) > 0) {
		s.publishViewSoon()
	}
}

// stopStaleCheck stops the pending stale check for good (Run's end): a
// heartbeat answered after it arms none.
func (s *supervisor) stopStaleCheck() {
	s.view.mu.Lock()
	defer s.view.mu.Unlock()
	s.view.stopped = true
	if s.view.staleChk != nil {
		s.view.staleChk.Stop()
	}
}

// publishViewSoon republishes the view's slices on the running hub.
func (s *supervisor) publishViewSoon() {
	s.hubMu.RLock()
	defer s.hubMu.RUnlock()
	if s.hub != nil {
		s.hub.publishSoon(viewKinds...)
	}
}
