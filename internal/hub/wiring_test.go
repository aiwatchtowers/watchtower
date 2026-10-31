package hub

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/actions/handlers"
	"watchtower/internal/hub/identity"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/slices/sources"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/policy"
	"watchtower/internal/policy/policytest"
)

// TestMain seeds new database files from the migrated template.
func TestMain(m *testing.M) {
	if err := db.InitTestFileTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}

// fileDB is a watchtower.db file with one workbench.
func fileDB(t *testing.T) (*db.DB, int64) {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "watchtower.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })
	res, err := d.Exec(`INSERT INTO projects (name, folder_path) VALUES ('acme', '/tmp/hubtest-acme')`)
	if err != nil {
		t.Fatal(err)
	}
	project, _ := res.LastInsertId()
	return d, project
}

func addTarget(t *testing.T, d *db.DB, project int64, text string) {
	t.Helper()
	if _, err := d.Exec(`INSERT INTO targets (text, level, custom_label, period_start, period_end, status, priority, ownership, source_type, project_id)
VALUES (?, 'custom', 'project', '2026-09-29', '2026-09-29', 'todo', 'medium', 'mine', 'chat', ?)`, text, project); err != nil {
		t.Fatal(err)
	}
}

// TestHubPublishesTheDatabaseSourcesOnChange: the running hub publishes the
// sources.All set, sees another connection's write through the
// data_version watch, swept the crash leftovers at start, and keeps the
// transcripts' stale-asset sweep inside their own directory.
func TestHubPublishesTheDatabaseSourcesOnChange(t *testing.T) {
	policytest.Set(t, map[string]any{"MobileSync": policy.MobileAllowed})
	dir := shortDir(t)
	setMeta(t, dir, state.MetaEnabled, "1")
	linkPhoneDirectly(t, dir)
	d, project := fileDB(t)
	addTarget(t, d, project, "First")

	assets := filepath.Join(dir, assetDirName)
	recordings := filepath.Join(dir, "recordings")
	leftovers := []string{
		filepath.Join(assets, ".asset-crash"),
		filepath.Join(recordings, ".upload.sealed"),
		filepath.Join(assets, transcriptAssetDir, "stale.asset"),
	}
	kept := filepath.Join(assets, "other.asset") // not the transcripts' dir
	for _, p := range append(leftovers, kept) {
		if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	r := newRig(t, dir)
	o := r.options()
	o.DB, o.RecordingsDir = d, recordings
	var mu sync.Mutex
	var steps []string
	o.trace = func(s string) { mu.Lock(); steps = append(steps, s); mu.Unlock() }
	r.start(o)
	r.waitState(StateRunning, "")

	s, err := ReadStatus(dir)
	if err != nil {
		t.Fatal(err)
	}
	data := transport.DataZone(s.RelayDeviceID)
	count := func() int { return len(liveRecords(t, r.fake, data)) }
	eventually(t, 10*time.Second, "the target published", func() bool { return count() >= 4 }) // grant, heartbeat, workbench, target
	before := count()
	addTarget(t, d, project, "Second")
	eventually(t, 10*time.Second, "the second target published by the watch", func() bool { return count() == before+1 })

	for _, p := range leftovers {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Errorf("%s survived the start (stat: %v)", filepath.Base(p), err)
		}
	}
	if _, err := os.Stat(kept); err != nil {
		t.Errorf("an asset outside the transcripts' dir was removed: %v", err)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(steps) < 2 || steps[0] != "seeded" || steps[1] != "publisher" {
		t.Fatalf("start steps %v, want the report seeded before the publisher", steps)
	}
}

// TestReportIsSeededBeforeTheTimelineFirstObserves pins T8's ordering: the
// report runner's Seed reads the newest stored milestone before anything
// observes the timeline (the publisher's start cycle reads its Items, the
// lane observes only after its baseline read).
func TestReportIsSeededBeforeTheTimelineFirstObserves(t *testing.T) {
	policytest.Set(t, nil)
	dir := shortDir(t)
	setMeta(t, dir, state.MetaEnabled, "1")
	d, _ := fileDB(t)
	r := newRig(t, dir)
	o := r.options()
	o.DB = d
	var mu sync.Mutex
	var steps []string
	o.trace = func(s string) { mu.Lock(); steps = append(steps, s); mu.Unlock() }
	r.start(o)
	r.waitState(StateRunning, "")
	mu.Lock()
	defer mu.Unlock()
	if !slices.Equal(steps, []string{"seeded", "publisher"}) {
		t.Fatalf("start steps %v, want [seeded publisher]", steps)
	}
}

// Every Deps field the runner-fed requests need is set: a nil Windows,
// ChatWatches or Reports would answer applied and do nothing.
func TestHandlerDepsCarryTheRunnerSeams(t *testing.T) {
	d, _ := fileDB(t)
	st, err := state.Open(filepath.Join(t.TempDir(), "hub"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	id, err := identity.New()
	if err != nil {
		t.Fatal(err)
	}
	kr, err := identity.NewKeyring(id, st, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	watches := handlers.NewChatWatchRegistry()
	set, err := sources.All(sources.Config{DB: d, Store: st, Watches: watches, Sealer: kr, Mode: policy.MobileWorkbenchOnly})
	if err != nil {
		t.Fatal(err)
	}
	late := func(context.Context, actions.Request, actions.Outcome) error { return nil }
	deps := handlerDeps(Options{DB: d, RecordingsDir: t.TempDir()}, st, set, watches, kr, noSessionHost{}, late)
	if deps.Windows == nil || deps.ChatWatches == nil || deps.Reports == nil {
		t.Fatalf("runner seams: windows %v, watches %v, reports %v", deps.Windows != nil, deps.ChatWatches != nil, deps.Reports != nil)
	}
	if deps.Sealer == nil || deps.LateEcho == nil || deps.Sessions == nil || deps.DB == nil || deps.Store == nil {
		t.Fatal("held lines need the sealer and the late echo")
	}
}

// laneCalls records what a lane told.
type laneCalls struct {
	mu        sync.Mutex
	observed  int
	changed   []int64
	nudged    [][]hubslices.Kind
	delivered int
}

func TestStateLaneTellsTheRunnersAndDeliversHeld(t *testing.T) {
	d, project := fileDB(t)
	res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path) VALUES (?, 'shell', 'Session', '/tmp/hubtest-acme')`, project)
	if err != nil {
		t.Fatal(err)
	}
	session, _ := res.LastInsertId()
	c := &laneCalls{}
	l := newStateLane(d.DB, time.Now)
	l.observe = func(context.Context, time.Time) error { c.mu.Lock(); c.observed++; c.mu.Unlock(); return nil }
	l.changed = []func(int64){func(wb int64) { c.mu.Lock(); c.changed = append(c.changed, wb); c.mu.Unlock() }}
	l.nudge = func(k ...hubslices.Kind) { c.mu.Lock(); c.nudged = append(c.nudged, k); c.mu.Unlock() }
	l.held = func(context.Context) { c.mu.Lock(); c.delivered++; c.mu.Unlock() }
	ctx := context.Background()

	l.once(ctx) // the baseline
	if c.observed != 0 || len(c.changed) != 0 || len(c.nudged) != 0 || c.delivered != 1 {
		t.Fatalf("baseline told %+v", c)
	}
	l.once(ctx) // nothing changed
	if c.observed != 0 || c.delivered != 2 {
		t.Fatalf("an unchanged read told %+v", c)
	}
	if _, err := d.Exec(`UPDATE terminal_sessions SET agent_state = 'waiting', agent_state_at = '2026-10-31T10:00:00.000Z' WHERE id = ?`, session); err != nil {
		t.Fatal(err)
	}
	l.once(ctx)
	if c.observed != 1 || !slices.Equal(c.changed, []int64{project}) || len(c.nudged) != 1 || c.delivered != 3 {
		t.Fatalf("a state change told %+v", c)
	}
	if !slices.Equal(c.nudged[0], stateChangeKinds) {
		t.Fatalf("nudged %v", c.nudged[0])
	}
}

// The workbench_only filter is the sources' list plus the hub's own kinds.
func TestWorkbenchOnlyIsTheSourcesList(t *testing.T) {
	for _, k := range hubslices.AllKinds {
		want := k == hubslices.KindHeartbeat || k == hubslices.KindDeviceGrant || slices.Contains(sources.WorkbenchOnlyKinds, k)
		if workbenchOnly(k) != want {
			t.Errorf("%s: workbenchOnly = %v", k, !want)
		}
	}
}
