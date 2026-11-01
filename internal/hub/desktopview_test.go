package hub

import (
	"context"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/hub/slices/sources"
	"watchtower/internal/hub/state"
	"watchtower/internal/logcanary"
)

// viewRig is a supervisor over a fresh sidecar with a settable clock, and a
// watchtower.db with one workbench.
type viewRig struct {
	s       *supervisor
	d       *db.DB
	project int64
	mu      sync.Mutex
	now     time.Time
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
	r.s = &supervisor{o: Options{Clock: r.clock}, st: st}
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
// heartbeat does not bring the old view back.
func TestDesktopViewClearsWhenHeartbeatGoesStale(t *testing.T) {
	r := newViewRig(t)
	kept, hidden := r.session(t), r.session(t)
	if err := r.s.st.Heartbeat(r.clock()); err != nil {
		t.Fatal(err)
	}
	r.s.storeDesktopView(DesktopView{Hidden: idSet([]int64{hidden}), At: r.clock()}, nil)
	keptID, hiddenID := strconv.FormatInt(kept, 10), strconv.FormatInt(hidden, 10)

	r.advance(89 * time.Second)
	if got := r.published(t); !got[keptID] || got[hiddenID] {
		t.Fatalf("fresh heartbeat: published %v, want only %s", got, keptID)
	}
	r.advance(2 * time.Second)
	if got := r.published(t); !got[keptID] || !got[hiddenID] {
		t.Fatalf("stale heartbeat (91 s): published %v, want both", got)
	}
	if err := r.s.st.Heartbeat(r.clock()); err != nil {
		t.Fatal(err)
	}
	if got := r.published(t); !got[hiddenID] {
		t.Errorf("a new heartbeat brought back the view the Desktop sent before it went away: %v", got)
	}
}

// TestDesktopViewIsKeptWhileNoHubRuns: desktop_view on a supervisor whose
// hub is off is stored, so the next hub's sources read it.
func TestDesktopViewIsKeptWhileNoHubRuns(t *testing.T) {
	r := newViewRig(t)
	if err := r.s.st.Heartbeat(r.clock()); err != nil {
		t.Fatal(err)
	}
	if a := r.s.handle(ControlRequest{Op: OpDesktopView, Hidden: []int64{4}, DisplayOver: []int64{5, 6}}, nil); !a.OK {
		t.Fatalf("desktop_view: %+v", a)
	}
	hidden, over := r.s.desktopView()
	if !hidden[4] || len(hidden) != 1 || !over[5] || !over[6] || len(over) != 2 {
		t.Errorf("view = %v, %v", hidden, over)
	}
}

// TestFILES01_DesktopViewLogsCountsOnly: a view change logs how many
// sessions are hidden and shown over, never which.
func TestFILES01_DesktopViewLogsCountsOnly(t *testing.T) {
	sink := logcanary.Capture(t)
	r := newViewRig(t)
	ids := []int64{918273645, 918273646}
	r.s.storeDesktopView(DesktopView{Hidden: idSet(ids[:1]), DisplayOver: idSet(ids), At: r.clock()}, nil)
	r.s.storeDesktopView(DesktopView{Hidden: idSet(ids[:1]), DisplayOver: idSet(ids), At: r.clock()}, nil) // unchanged: no line
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
