package builtin

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/config"
	"watchtower/internal/db"
)

// TestMain installs the db schema template cache (see the automations
// package's TestMain).
func TestMain(m *testing.M) {
	if err := db.InitTestFileTemplate(); err != nil {
		fmt.Fprintf(os.Stderr, "testmain: %v\n", err)
		os.Exit(1)
	}
	os.Exit(m.Run())
}

const mbID = "morning-brief"

// testStart is the tests' fake now.
var testStart = time.Date(2026, 10, 22, 9, 0, 0, 0, time.UTC)

// fakePrimitive records its calls and answers with res/err.
type fakePrimitive struct {
	mu    sync.Mutex
	calls []automations.PrimitiveCall
	res   automations.PrimitiveResult
	err   error
	// during runs inside each call (a call made while the run is active).
	during func()
}

func (p *fakePrimitive) fn(_ context.Context, c automations.PrimitiveCall) (automations.PrimitiveResult, error) {
	p.mu.Lock()
	p.calls = append(p.calls, c)
	during, res, err := p.during, p.res, p.err
	p.mu.Unlock()
	if during != nil {
		during()
	}
	return res, err
}

func (p *fakePrimitive) snapshot() []automations.PrimitiveCall {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]automations.PrimitiveCall(nil), p.calls...)
}

// fakeGate answers due and counts its calls.
type fakeGate struct {
	mu    sync.Mutex
	due   bool
	calls int
}

func (g *fakeGate) Due(context.Context, Entry, time.Time) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.calls++
	return g.due
}

func (g *fakeGate) count() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.calls
}

// fixture is a database, a workspace, a config with both Morning brief
// features on, a real slot executor over fake primitives, a fake gate and
// the runner.
type fixture struct {
	d      *db.DB
	ws     string
	cfg    *config.Config
	clock  *automationstest.FakeClock
	brief  *fakePrimitive
	plan   *fakePrimitive
	asked  *promptLog
	gate   *fakeGate
	exec   *automations.Executor
	runner *Runner
}

// promptLog records the names builtin.defaultPrompt was asked for.
type promptLog struct {
	mu    sync.Mutex
	names []string
}

func (l *promptLog) add(name string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.names = append(l.names, name)
}

func (l *promptLog) all() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return append([]string(nil), l.names...)
}

func testConfig(t *testing.T) *config.Config {
	t.Helper()
	cfg, err := config.Load(filepath.Join(t.TempDir(), "absent.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	cfg.Briefing.Enabled, cfg.DayPlan.Enabled = true, true
	return cfg
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	f := &fixture{
		d: db.OpenTestDB(t), ws: t.TempDir(), cfg: testConfig(t), clock: automationstest.NewFakeClock(testStart),
		brief: &fakePrimitive{res: automations.PrimitiveResult{Status: "done"}},
		plan:  &fakePrimitive{res: automations.PrimitiveResult{Status: "done"}},
		asked: &promptLog{}, gate: &fakeGate{due: true},
	}
	b := automations.Backends{DB: f.d, Clock: f.clock,
		Primitives: map[string]automations.PrimitiveFunc{"brief.compose": f.brief.fn, "plan.compose": f.plan.fn},
		DefaultPrompt: func(builtinID, name, role string) (string, error) {
			f.asked.add(name)
			return DefaultPromptFunc(builtinID, name, role)
		},
	}
	f.exec = automations.NewExecutor(f.d, b, automations.ExecutorOptions{Logger: log.New(io.Discard, "", 0)})
	f.runner = NewRunner(f.d, f.exec, map[string]Gate{mbID: f.gate}, f.cfg, f.clock, log.New(io.Discard, "", 0))
	return f
}

func (f *fixture) sync(t *testing.T) SyncReport {
	t.Helper()
	rep, err := Sync(context.Background(), f.d, f.ws, f.cfg, f.clock.Now())
	if err != nil {
		t.Fatalf("Sync: %v", err)
	}
	return rep
}

func (f *fixture) row(t *testing.T) *db.Automation {
	t.Helper()
	a, err := f.d.GetBuiltinAutomation(mbID)
	if err != nil {
		t.Fatal(err)
	}
	return a
}

func (f *fixture) runs(t *testing.T) []db.AutomationRun {
	t.Helper()
	runs, err := f.d.ListAutomationRuns(f.row(t).ID, 0)
	if err != nil {
		t.Fatal(err)
	}
	return runs
}

// writeCopy writes the owner's copy of the Morning brief.
func (f *fixture) writeCopy(t *testing.T, data []byte) {
	t.Helper()
	path := OwnerCopyPath(f.ws, mbID)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
}

// editedCopy is the Morning brief rendered with an edited brief prompt.
func editedCopy(t *testing.T, e Entry, brief string) []byte {
	t.Helper()
	plan, err := e.DefaultPrompt("plan", "")
	if err != nil {
		t.Fatal(err)
	}
	data, err := RenderOwnerCopy(e, map[string]string{"brief": brief, "plan": plan})
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func mustEntry(t *testing.T) Entry {
	t.Helper()
	e, ok := Lookup(mbID)
	if !ok {
		t.Fatal("no morning-brief entry")
	}
	return e
}

// withShipped replaces the Morning brief's shipped bytes for the test (a
// release with other text).
func withShipped(t *testing.T, data []byte) {
	t.Helper()
	for i := range registry {
		if registry[i].ID == mbID {
			old := registry[i].Recipe
			registry[i].Recipe = data
			t.Cleanup(func() { registry[i].Recipe = old })
			return
		}
	}
	t.Fatal("no morning-brief entry")
}

func isNotRunnable(err error) bool { return errors.Is(err, automations.ErrNotRunnable) }
