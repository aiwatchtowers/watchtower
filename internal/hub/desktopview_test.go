package hub

import (
	"context"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/db"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/slices/sources"
	"watchtower/internal/hub/state"
	"watchtower/internal/logcanary"
)

// viewRig is a supervisor over a fresh sidecar with a settable clock, a
// stand-in running hub whose publishSoon calls are recorded, and a
// watchtower.db with one workbench.
type viewRig struct {
	s       *supervisor
	d       *db.DB
	project int64
	mu      sync.Mutex
	now     time.Time
	kinds   [][]hubslices.Kind
}

func newViewRig(t *testing.T) *viewRig {
	t.Helper()
	st, err := state.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	d, project := fileDB(t)
	r := &viewRig{d: d, project: project, now: time.Unix(1_800_000_000, 0)}
	r.s = &supervisor{o: Options{Clock: r.clock, published: r.record}, st: st}
	r.s.hub = &hubRuntime{sup: r.s}
	t.Cleanup(r.s.stopStaleCheck)
	return r
}

func (r *viewRig) clock() time.Time {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.now
}

func (r *viewRig) advance(d time.Duration) {
	r.mu.Lock()
	r.now = r.now.Add(d)
	r.mu.Unlock()
}

func (r *viewRig) record(kinds []hubslices.Kind) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.kinds = append(r.kinds, slices.Clone(kinds))
}

// viewPublishes counts the publishSoon calls of exactly viewKinds.
func (r *viewRig) viewPublishes() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	n := 0
	for _, k := range r.kinds {
		if slices.Equal(k, viewKinds) {
			n++
		}
	}
	return n
}

func (r *viewRig) beat(t *testing.T) ControlAnswer {
	t.Helper()
	a := r.s.handle(ControlRequest{Op: OpDesktopHeartbeat}, nil)
	if !a.OK {
		t.Fatalf("heartbeat: %+v", a)
	}
	return a
}

func (r *viewRig) setView(t *testing.T, req ControlRequest) {
	t.Helper()
	req.Op = OpDesktopView
	if a := r.s.handle(req, nil); !a.OK {
		t.Fatalf("desktop_view: %+v", a)
	}
}

func (r *viewRig) session(t *testing.T) int64 {
	t.Helper()
	res, err := r.d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, last_active_at)
VALUES (?, 'codex', 'Session', '/tmp/hubtest-acme', ?)`, r.project, time.Now().UTC().Format("2006-01-02T15:04:05Z"))
	if err != nil {
		t.Fatal(err)
	}
	id, _ := res.LastInsertId()
	return id
}

func (r *viewRig) published(t *testing.T) map[string]bool {
	t.Helper()
	src := sources.TerminalSessions(r.d, sources.TerminalSessionOptions{Now: r.clock, View: r.s.desktopView})
	items, err := src.Items(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]bool{}
	for _, it := range items {
		out[it.ID] = true
	}
	return out
}

// TestDesktopViewClearsWhenHeartbeatGoesStale: a session in the Desktop's
// Undo batch is not published while the Desktop heartbeat is fresh (89 s);
// at 91 s the view is empty and the session is published again, and a later
// heartbeat does not bring the old view back (it asks for a new one).
func TestDesktopViewClearsWhenHeartbeatGoesStale(t *testing.T) {
	r := newViewRig(t)
	kept, hidden := r.session(t), r.session(t)
	r.beat(t)
	r.setView(t, ControlRequest{Hidden: []int64{hidden}})
	keptID, hiddenID := strconv.FormatInt(kept, 10), strconv.FormatInt(hidden, 10)

	r.advance(89 * time.Second)
	if got := r.published(t); !got[keptID] || got[hiddenID] {
		t.Fatalf("fresh heartbeat: published %v, want only %s", got, keptID)
	}
	r.advance(2 * time.Second)
	if got := r.published(t); !got[keptID] || !got[hiddenID] {
		t.Fatalf("stale heartbeat (91 s): published %v, want both", got)
	}
	if a := r.beat(t); !a.ViewNeeded {
		t.Error("the heartbeat after the view was dropped does not ask for a view")
	}
	if got := r.published(t); !got[hiddenID] {
		t.Errorf("a new heartbeat brought back the view the Desktop sent before it went away: %v", got)
	}
}

// TestHeartbeatAnswerSaysViewNeeded: view_needed until Desktop sent a view
// (an empty one counts), then not while it is current.
func TestHeartbeatAnswerSaysViewNeeded(t *testing.T) {
	r := newViewRig(t)
	if a := r.beat(t); !a.ViewNeeded {
		t.Error("no view ever sent: view_needed must be set")
	}
	r.setView(t, ControlRequest{})
	r.advance(30 * time.Second)
	if a := r.beat(t); a.ViewNeeded {
		t.Error("an empty view is a current view")
	}
	r.setView(t, ControlRequest{Hidden: []int64{4}})
	r.advance(30 * time.Second)
	if a := r.beat(t); a.ViewNeeded {
		t.Error("a current view: view_needed must be unset")
	}
}

// TestAViewSentBeforeTheFirstHeartbeatAppliesWhenItTurnsFresh: the stale →
// fresh transition republishes the view's slices and the view sent just
// before it applies.
func TestAViewSentBeforeTheFirstHeartbeatAppliesWhenItTurnsFresh(t *testing.T) {
	r := newViewRig(t)
	hidden := r.session(t)
	r.setView(t, ControlRequest{Hidden: []int64{hidden}})
	if got := r.published(t); !got[strconv.FormatInt(hidden, 10)] {
		t.Fatal("no heartbeat yet: the view must not apply")
	}
	before := r.viewPublishes()
	r.advance(time.Second)
	if a := r.beat(t); a.ViewNeeded {
		t.Error("the view sent a second ago was dropped")
	}
	if r.viewPublishes() != before+1 {
		t.Errorf("the stale → fresh heartbeat did not republish the view's slices (%d → %d)", before, r.viewPublishes())
	}
	if got := r.published(t); got[strconv.FormatInt(hidden, 10)] {
		t.Error("the fresh heartbeat did not apply the view")
	}
	r.advance(30 * time.Second)
	r.beat(t)
	if r.viewPublishes() != before+1 {
		t.Error("a fresh → fresh heartbeat republished")
	}
}

// TestAHeartbeatGoingStaleRepublishesTheView: no heartbeat after the stale
// check's delay republishes the view's slices, so hidden sessions reappear
// when Desktop died.
func TestAHeartbeatGoingStaleRepublishesTheView(t *testing.T) {
	r := newViewRig(t)
	r.s.o.staleAfter = 20 * time.Millisecond
	r.beat(t)
	r.setView(t, ControlRequest{Hidden: []int64{4}})
	n := r.viewPublishes()
	eventually(t, 5*time.Second, "the stale check republished", func() bool { return r.viewPublishes() > n })
}

// TestAHeartbeatDuringAFreshnessReadIsNotCachedOver: a heartbeat that lands
// between the freshness read and its caching wins: the stale value read
// before it is not cached.
func TestAHeartbeatDuringAFreshnessReadIsNotCachedOver(t *testing.T) {
	r := newViewRig(t)
	var once sync.Once
	r.s.o.afterFreshRead = func() { once.Do(func() { r.beat(t) }) }
	if r.s.desktopFresh(r.clock()) {
		t.Fatal("the read before the heartbeat was fresh")
	}
	if !r.s.desktopFresh(r.clock()) {
		t.Error("the stale read from before the heartbeat was cached over it")
	}
}

// TestNoStaleCheckIsArmedAfterRunStopped: a heartbeat answered after Run's
// end arms no stale-check timer.
func TestNoStaleCheckIsArmedAfterRunStopped(t *testing.T) {
	r := newViewRig(t)
	r.s.stopStaleCheck()
	r.beat(t)
	r.s.view.mu.Lock()
	defer r.s.view.mu.Unlock()
	if r.s.view.staleChk != nil {
		t.Error("a stale check was armed after Run stopped")
	}
}

// TestDesktopViewPublishesTheViewKinds:a changed view republishes the
// sessions, the workbench counts, the timeline and the alerts; the same
// view again does not.
func TestDesktopViewPublishesTheViewKinds(t *testing.T) {
	r := newViewRig(t)
	r.setView(t, ControlRequest{Hidden: []int64{4}})
	r.setView(t, ControlRequest{Hidden: []int64{4}})
	if n := r.viewPublishes(); n != 1 {
		t.Errorf("view publishes %d, want 1", n)
	}
}

// TestDesktopViewRefusesTooManyIDs: each list is capped at MaxViewIDs.
func TestDesktopViewRefusesTooManyIDs(t *testing.T) {
	r := newViewRig(t)
	many := make([]int64, MaxViewIDs+1)
	for i := range many {
		many[i] = int64(i + 1)
	}
	if a := r.s.handle(ControlRequest{Op: OpDesktopView, Hidden: many}, nil); a.Error != ErrClassTooManyIDs {
		t.Errorf("hidden over the cap: %+v", a)
	}
	over := make([]ShownOverWire, MaxViewIDs+1)
	if a := r.s.handle(ControlRequest{Op: OpDesktopView, DisplayOver: over}, nil); a.Error != ErrClassTooManyIDs {
		t.Errorf("display_over over the cap: %+v", a)
	}
	if a := r.s.handle(ControlRequest{Op: OpDesktopView, Hidden: many[:MaxViewIDs]}, nil); !a.OK {
		t.Errorf("hidden at the cap: %+v", a)
	}
}

// TestDesktopViewIsKeptWhileNoHubRuns: desktop_view on a supervisor whose
// hub is off is stored, so the next hub's sources read it; a shown-over
// count keeps its run and report stamp.
func TestDesktopViewIsKeptWhileNoHubRuns(t *testing.T) {
	r := newViewRig(t)
	r.s.hub = nil
	r.beat(t)
	run := time.Unix(1_799_999_000, 0).UTC()
	stamp := db.AgentStateStamp(run.Add(time.Second))
	r.setView(t, ControlRequest{Hidden: []int64{4}, DisplayOver: []ShownOverWire{{ID: 5, Run: &run, ReportedAt: &stamp}, {ID: 6}}})
	hidden, over := r.s.desktopView()
	if !hidden[4] || len(hidden) != 1 || len(over) != 2 ||
		!over[5].Run.Equal(run) || over[5].ReportedAt != stamp || !over[6].Run.IsZero() || over[6].ReportedAt != "" {
		t.Errorf("view = %v, %v", hidden, over)
	}
	if r.viewPublishes() != 0 {
		t.Error("published with no hub running")
	}
}

// TestWiringPassesTheDesktopView: the running hub's sources read the
// supervisor's view (wiring View: h.sup.desktopView).
func TestWiringPassesTheDesktopView(t *testing.T) {
	d, project := fileDB(t)
	res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, last_active_at)
VALUES (?, 'codex', 'Session', '/tmp/hubtest-acme', ?)`, project, time.Now().UTC().Format("2006-01-02T15:04:05Z"))
	if err != nil {
		t.Fatal(err)
	}
	hidden, _ := res.LastInsertId()
	h, w := wiringRig(t, Options{DB: d})
	h.sup.st = h.st
	t.Cleanup(h.sup.stopStaleCheck)
	if a := h.sup.handle(ControlRequest{Op: OpDesktopHeartbeat}, nil); !a.OK {
		t.Fatalf("heartbeat: %+v", a)
	}
	if a := h.sup.handle(ControlRequest{Op: OpDesktopView, Hidden: []int64{hidden}}, nil); !a.OK {
		t.Fatalf("desktop_view: %+v", a)
	}
	for _, src := range w.set.Sources {
		if src.Kind() != "terminal_session" {
			continue
		}
		items, err := src.Items(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		if len(items) != 0 {
			t.Errorf("the hidden session was published: %d items", len(items))
		}
		return
	}
	t.Fatal("no terminal_session source")
}

// TestFILES01_DesktopViewLogsCountsOnly: a view change logs how many
// sessions are hidden and shown over, never which.
func TestFILES01_DesktopViewLogsCountsOnly(t *testing.T) {
	sink := logcanary.Capture(t)
	r := newViewRig(t)
	ids := []int64{918273645, 918273646}
	req := ControlRequest{Hidden: ids[:1], DisplayOver: []ShownOverWire{{ID: ids[0]}, {ID: ids[1]}}}
	r.setView(t, req)
	r.setView(t, req) // unchanged: no line
	sink.AssertClean(t)
	out := sink.String()
	if strings.Count(out, "hub: desktop view: 1 hidden, 2 shown over") != 1 {
		t.Errorf("want one counts line, got %q", out)
	}
	for _, id := range ids {
		if strings.Contains(out, strconv.FormatInt(id, 10)) {
			t.Errorf("session id %d reached the log", id)
		}
	}
}
