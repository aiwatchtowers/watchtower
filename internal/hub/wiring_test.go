package hub

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"sync"
	"testing"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/actions/handlers"
	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/link"
	"watchtower/internal/hub/secure"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/slices/sources"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/wire"
	"watchtower/internal/policy"
	"watchtower/internal/policy/policytest"
	"watchtower/internal/sessionreport"
	"watchtower/internal/workbenchgit"
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
	if len(steps) == 0 || steps[0] != "seeded" || steps[len(steps)-1] != "publisher" {
		t.Fatalf("start steps %v, want the report seeded before the publisher", steps)
	}
}

// TestReportIsSeededBeforeTheTimelineFirstObserves pins T8's ordering: the
// report runner's Seed reads the newest stored milestone before the
// runners, the lane, the watch and the publisher start (the publisher's
// start cycle reads the timeline's Items; the lane observes only after its
// baseline read).
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
	if want := []string{"seeded", "runners", "lane", "watch", "publisher"}; !slices.Equal(steps, want) {
		t.Fatalf("start steps %v, want %v", steps, want)
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

// wiringRig is a hub runtime with just enough to build and start the wiring
// over d: a sidecar, a keyring and o.
func wiringRig(t *testing.T, o Options) (*hubRuntime, *wiring) {
	t.Helper()
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
	if o.Clock == nil {
		o.Clock = time.Now
	}
	if o.Dir == "" {
		o.Dir = t.TempDir()
	}
	h := &hubRuntime{sup: &supervisor{o: o}, st: st, kr: kr}
	late := func(context.Context, actions.Request, actions.Outcome) error { return nil }
	w, err := h.buildWiring(o, st, policy.MobileWorkbenchOnly, actions.NewDispatcher(), late)
	if err != nil {
		t.Fatal(err)
	}
	return h, w
}

// runWiring starts w (and the publisher, when h has one) until the test ends.
func runWiring(t *testing.T, h *hubRuntime, w *wiring) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	h.startWiring(ctx, w)
	if h.pub != nil {
		h.wg.Add(1)
		go func() {
			defer h.wg.Done()
			_ = h.pub.Run(ctx)
		}()
	}
	t.Cleanup(func() {
		cancel()
		h.wg.Wait()
		w.close()
	})
}

// gate is a fetch that blocks until released.
type gate struct {
	release chan struct{}
	once    sync.Once
}

func newGate() *gate { return &gate{release: make(chan struct{})} }

func (g *gate) open() { g.once.Do(func() { close(g.release) }) }

// TestRunnerResultsPublishWithoutTheFullDiff: a stored report (the first
// run, then a phone's request) and a new git status reach the publisher
// through the runners' OnChange, within the debounce, long before the 60 s
// full diff; the publisher's start cycle ran before either existed.
func TestRunnerResultsPublishWithoutTheFullDiff(t *testing.T) {
	d, project := fileDB(t)
	res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
VALUES (?, 'claude', 'Session', '/tmp/hubtest-acme', '00000000-0000-4000-8000-000000000002')`, project)
	if err != nil {
		t.Fatal(err)
	}
	session, _ := res.LastInsertId()

	reportGate, gitGate := newGate(), newGate()
	var mu sync.Mutex
	networkRuns := 0
	o := Options{
		DB: d,
		reportFetch: func(ctx context.Context, _, sessionID int64, network bool) (sessionreport.Report, error) {
			select {
			case <-reportGate.release:
			case <-ctx.Done():
				return sessionreport.Report{}, ctx.Err()
			}
			mu.Lock()
			defer mu.Unlock()
			rep := sessionreport.Report{Session: sessionreport.Session{ID: sessionID, Title: "Session"}}
			if network {
				networkRuns++
				rep.PRNote = "fetched"
			}
			return rep, nil
		},
		gitFetch: func(ctx context.Context, _ int64) (workbenchgit.Status, error) {
			select {
			case <-gitGate.release:
			case <-ctx.Done():
				return workbenchgit.Status{}, ctx.Err()
			}
			st := workbenchgit.Status{StatusOK: true, Git: true, GitAvailable: true}
			st.Branch, st.Changes = "feature/acme", 2
			return st, nil
		},
	}
	h, w := wiringRig(t, o)
	// The runners work only while a phone is linked.
	p, err := hubtest.New(hubtest.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := h.st.WithTx(context.Background(), func(tx *sql.Tx) error { return state.LinkDevice(tx, p.Device()) }); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(reportGate.open)
	t.Cleanup(gitGate.open)
	h.pub = hubslices.NewPublisher(hubslices.Config{
		Store: h.st, Transport: memfake.New(transport.KindRelay, nil), Sealer: secure.NewSealer(h.kr),
		DataZone: "data/hubtest-acme", Sources: w.set.Sources,
	})
	runWiring(t, h, w)
	eventually(t, 5*time.Second, "the start cycle", func() bool { _, ok := h.pub.LastPublishAt(); return ok })
	hashes := func(kind string) map[string]state.SliceRecord {
		got, err := h.st.SliceHashes(kind)
		if err != nil {
			t.Fatal(err)
		}
		return got
	}
	if n := len(hashes("session_report")); n != 0 {
		t.Fatalf("a report published before any run: %d", n)
	}
	workbench := hashes("workbench")
	if len(workbench) != 1 {
		t.Fatalf("workbench records %d", len(workbench))
	}

	// The runners keep a 5 s minimum gap between two passes (the Swift
	// HubRunnerWake), so a request right after a pass runs ≤ 5 s later; the
	// publish then follows within the debounce — far under the 60 s
	// hubslices.FullDiffEvery the result waited for before.
	const prompt = 10 * time.Second
	reportGate.open()
	eventually(t, prompt, "the first report published", func() bool { return len(hashes("session_report")) == 1 })
	first := hashes("session_report")

	if !w.set.Report.RequestReport(session) {
		t.Fatal("the request was refused")
	}
	eventually(t, prompt, "the requested report published", func() bool {
		for name, r := range hashes("session_report") {
			if r.Hash != first[name].Hash {
				return true
			}
		}
		return false
	})
	mu.Lock()
	if networkRuns != 1 {
		t.Errorf("network runs %d, want the phone's one", networkRuns)
	}
	mu.Unlock()

	gitGate.open()
	eventually(t, prompt, "the workbench republished with its git status", func() bool {
		for name, r := range hashes("workbench") {
			if r.Hash != workbench[name].Hash {
				return true
			}
		}
		return false
	})
}

// A Seed that fails at start gates the timeline (its Items fail and the lane
// does not observe) until a retry succeeds; the rest starts at once.
func TestAFailedSeedGatesTheTimelineUntilARetrySucceeds(t *testing.T) {
	d, _ := fileDB(t)
	var mu sync.Mutex
	var steps []string
	o := Options{DB: d, trace: func(s string) { mu.Lock(); steps = append(steps, s); mu.Unlock() }}
	h, w := wiringRig(t, o)
	report := w.seed
	fails := 1
	w.seed = func(ctx context.Context) error {
		mu.Lock()
		defer mu.Unlock()
		if fails > 0 {
			fails--
			return errors.New("sidecar busy")
		}
		return report(ctx)
	}
	var timeline hubslices.Source
	for _, src := range w.set.Sources {
		if src.Kind() == "session_timeline" {
			timeline = src
		}
	}
	observed := 0
	inner := w.lane.observe
	w.lane.observe = func(ctx context.Context, at time.Time) error {
		mu.Lock()
		observed++
		mu.Unlock()
		return inner(ctx, at)
	}
	runWiring(t, h, w)
	mu.Lock()
	if len(steps) == 0 || steps[0] != "seed_failed" {
		t.Fatalf("steps %v", steps)
	}
	mu.Unlock()
	if _, err := timeline.Items(context.Background()); !errors.Is(err, errNotSeeded) {
		t.Fatalf("timeline Items before the seed = %v", err)
	}
	if err := w.lane.observe(context.Background(), time.Now()); err != nil {
		t.Fatal(err)
	}
	eventually(t, 5*time.Second, "the retried seed", w.isSeeded)
	if _, err := timeline.Items(context.Background()); err != nil {
		t.Fatalf("timeline Items after the seed = %v", err)
	}
}

// revokePort is a session host with one live run that holds every line
// (Deliver is never reached for a busy session).
type revokePort struct{ noSessionHost }

func (revokePort) Live(_ context.Context, id int64) (handlers.LiveRun, bool, error) {
	return handlers.LiveRun{SessionID: id, Run: 1, Agent: "claude", StartedAt: time.Now().Add(-time.Minute)}, true, nil
}

func (revokePort) Deliver(context.Context, handlers.DeliverRequest) (handlers.DeliverResult, error) {
	return handlers.DeliverResult{Outcome: handlers.DeliverHeld, Reason: "prompt_has_text"}, nil
}

// TestRevokingTypingFailsAHeldLineAtOnce: the runtime registers
// handlers.Revoked on the link center, so a phone's held line fails
// device_not_allowed as soon as its typing is taken away — not at the next
// session-state read (pushed out to an hour here).
func TestRevokingTypingFailsAHeldLineAtOnce(t *testing.T) {
	d, project := fileDB(t)
	res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, folder_path, claude_session_id)
VALUES (?, 'claude', 'Session', '/tmp/hubtest-acme', '00000000-0000-4000-8000-000000000001')`, project)
	if err != nil {
		t.Fatal(err)
	}
	session, _ := res.LastInsertId()
	e := runEndToEnd(t, "", func(o *Options) {
		o.DB, o.Sessions, o.laneBackstop = d, revokePort{}, time.Hour
	})
	c, err := Dial(e.dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = c.Close() }()
	allow := func(on bool) {
		t.Helper()
		a, err := c.Do(ControlRequest{Op: OpAllow, Device: e.phone.ID().String(), Grant: string(link.GrantTyping), On: on})
		if err != nil || !a.OK {
			t.Fatalf("allow typing %v: %+v, %v", on, a, err)
		}
	}
	allow(true)
	a := e.phone.NewAction("session_input")
	id := strconv.FormatInt(session, 10)
	a.EntityID = &id
	a.Params["text"] = json.RawMessage(`"hello"`)
	seq, err := e.phone.Queue(a)
	if err != nil {
		t.Fatal(err)
	}
	if err := e.phone.Send(seq); err != nil {
		t.Fatal(err)
	}
	echo := func() wire.ActionRequest {
		if _, err := e.phone.Sync(); err != nil {
			t.Fatal(err)
		}
		return e.phone.Echoes[seq]
	}
	eventually(t, 15*time.Second, "the line held", func() bool { return echo().Status == wire.StatusHeld })
	allow(false)
	eventually(t, 5*time.Second, "the held line failed device_not_allowed", func() bool {
		got := echo()
		return got.Status == wire.StatusFailed && got.Reason != nil && *got.Reason == "device_not_allowed"
	})
}
