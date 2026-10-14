package automations_test

import (
	"bytes"
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/dop251/goja"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// exStart is the executor tests' fake now: noon UTC, so the daily cap's day
// (the zone is pinned to UTC) is unambiguous.
var exStart = time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC)

// exRecipe is a manual recipe; SCRIPT and EXTRA (more frontmatter lines) are
// replaced.
const exRecipe = "---\nname: Executor test\ntrigger:\n  manual: true\npermissions:\n  - llm:light\n" +
	"  - tool:list_targets\noutputs: [inbox, report]\nEXTRA---\nAn executor test recipe.\n\n```js\nSCRIPT\n```\n"

func exRecipeText(script, extra string) string {
	return strings.NewReplacer("SCRIPT", script, "EXTRA", extra).Replace(exRecipe)
}

// exOpts configures an executor fixture.
type exOpts struct {
	gen           digest.Generator // nil = a FakeGenerator replying "done" with 10+5 tokens
	maxConcurrent int
	modules       func(f *exFixture) []automations.Module // appended to DefaultModules
}

type exFixture struct {
	d     *db.DB
	clock *automationstest.FakeClock
	gen   digest.Generator
	reg   *automationstest.FakeRegistry
	ix    *automations.Indexer
	dir   string
	e     *automations.Executor
	logs  *syncBuffer
}

// syncBuffer is a log sink safe for the executor's goroutines.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func newExFixture(t *testing.T, o exOpts) *exFixture {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "watchtower.db"))
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	t.Cleanup(func() { _ = d.Close() })
	if o.gen == nil {
		o.gen = &automationstest.FakeGenerator{Replies: []string{"done"}, Usage: []digest.Usage{{InputTokens: 10, OutputTokens: 5}}}
	}
	ws := t.TempDir()
	f := &exFixture{d: d, clock: automationstest.NewFakeClock(exStart), gen: o.gen, reg: fakeTools(),
		dir: automations.PersonalDir(ws), logs: &syncBuffer{}}
	f.ix = automations.NewIndexer(d, ws, f.clock)
	f.e = automations.NewExecutor(d, automations.Backends{DB: d, Generator: o.gen, Registry: f.reg, Clock: f.clock},
		automations.ExecutorOptions{
			MaxConcurrent: o.maxConcurrent,
			Modules: func(b automations.Backends) []automations.Module {
				mods := automations.DefaultModules(b)
				if o.modules != nil {
					mods = append(mods, o.modules(f)...)
				}
				return mods
			},
			Logger: log.New(f.logs, "", 0),
		})
	automations.SetExecutorZone(f.e, func() *time.Location { return time.UTC })
	return f
}

// write puts slug's recipe file in the personal folder (no rescan).
func (f *exFixture) write(t *testing.T, slug, text string) {
	t.Helper()
	if err := os.MkdirAll(f.dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(f.dir, slug+".md"), []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

// rescan indexes the personal folder and returns slug's row.
func (f *exFixture) rescan(t *testing.T, slug string) db.Automation {
	t.Helper()
	if _, err := f.ix.RescanPersonal(context.Background()); err != nil {
		t.Fatalf("rescan: %v", err)
	}
	a, err := f.d.GetAutomationBySlug("personal", 0, slug)
	if err != nil {
		t.Fatalf("get %s: %v", slug, err)
	}
	return *a
}

// seed indexes a recipe with script and, unless unconfirmed, confirms and
// enables it.
func (f *exFixture) seed(t *testing.T, slug, script string, unconfirmed bool) db.Automation {
	t.Helper()
	return f.seedText(t, slug, exRecipeText(script, ""), unconfirmed)
}

func (f *exFixture) seedText(t *testing.T, slug, text string, unconfirmed bool) db.Automation {
	t.Helper()
	f.write(t, slug, text)
	a := f.rescan(t, slug)
	if unconfirmed {
		return a
	}
	if a.ParseError != "" {
		t.Fatalf("%s does not parse: %s", slug, a.ParseError)
	}
	if err := f.d.ConfirmAutomation(a.ID, a.ApprovalHash, exStart); err != nil {
		t.Fatalf("confirm %s: %v", slug, err)
	}
	if err := f.d.SetAutomationEnabled(a.ID, true, exStart); err != nil {
		t.Fatalf("enable %s: %v", slug, err)
	}
	return f.rescan(t, slug)
}

func (f *exFixture) enqueue(t *testing.T, a db.Automation, trigger string) int64 {
	t.Helper()
	return f.enqueueReq(t, db.EnqueueRequest{AutomationID: a.ID, Trigger: trigger})
}

func (f *exFixture) enqueueReq(t *testing.T, r db.EnqueueRequest) int64 {
	t.Helper()
	if r.Now.IsZero() {
		r.Now = f.clock.Now()
	}
	id, coalesced, err := f.d.EnqueueAutomationRun(r)
	if err != nil || coalesced {
		t.Fatalf("enqueue %+v = (%d, %v, %v)", r, id, coalesced, err)
	}
	return id
}

// step runs one poll, checks how many runs it started, and waits for them.
func (f *exFixture) step(t *testing.T, wantStarted int) {
	t.Helper()
	f.stepNoWait(t, wantStarted)
	f.e.Wait()
}

func (f *exFixture) stepNoWait(t *testing.T, wantStarted int) {
	t.Helper()
	started, err := f.e.Step(context.Background())
	if err != nil {
		t.Fatalf("Step: %v", err)
	}
	if started != wantStarted {
		t.Fatalf("Step started %d runs; want %d", started, wantStarted)
	}
}

func (f *exFixture) run(t *testing.T, id int64) *db.AutomationRun {
	t.Helper()
	r, err := f.d.GetAutomationRun(id)
	if err != nil {
		t.Fatalf("get run %d: %v", id, err)
	}
	return r
}

// wantRun fails unless run id has status and error kind.
func (f *exFixture) wantRun(t *testing.T, id int64, status, kind string) *db.AutomationRun {
	t.Helper()
	r := f.run(t, id)
	if r.Status != status || r.ErrorKind != kind {
		t.Fatalf("run %d = %s/%s (%s); want %s/%s", id, r.Status, r.ErrorKind, r.Error, status, kind)
	}
	return r
}

// waitStatus waits (real time) until run id has status.
func (f *exFixture) waitStatus(t *testing.T, id int64, status string) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for f.run(t, id).Status != status {
		if time.Now().After(deadline) {
			t.Fatalf("run %d never reached %s (is %s)", id, status, f.run(t, id).Status)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func (f *exFixture) steps(t *testing.T, id int64) []db.AutomationRunStep {
	t.Helper()
	steps, err := f.d.ListAutomationRunSteps(id)
	if err != nil {
		t.Fatal(err)
	}
	return steps
}

func (f *exFixture) count(t *testing.T, table string) int {
	t.Helper()
	var n int
	if err := f.d.QueryRow(`SELECT COUNT(*) FROM ` + table).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// dump renders automation_state and automation_outputs byte for byte.
func (f *exFixture) dump(t *testing.T) string {
	t.Helper()
	var out strings.Builder
	for _, q := range []string{
		`SELECT automation_id || '|' || state_json || '|' || IFNULL(run_id, '') || '|' || updated_at FROM automation_state ORDER BY automation_id`,
		`SELECT id || '|' || automation_id || '|' || run_id || '|' || kind || '|' || title || '|' || body || '|' ||
			priority || '|' || created_at FROM automation_outputs ORDER BY id`,
	} {
		rows, err := f.d.Query(q)
		if err != nil {
			t.Fatal(err)
		}
		for rows.Next() {
			var s string
			if err := rows.Scan(&s); err != nil {
				t.Fatal(err)
			}
			out.WriteString(s + "\n")
		}
		if err := rows.Err(); err != nil {
			t.Fatal(err)
		}
		_ = rows.Close()
	}
	return out.String()
}

// commitPrior gives the automation a committed state {"k":1} and one inbox output through
// a finished run, as an earlier successful run would.
func (f *exFixture) commitPrior(t *testing.T, a db.Automation) {
	t.Helper()
	id := f.enqueueReq(t, db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerCatchUp, Now: exStart.Add(-time.Hour)})
	if ok, err := f.d.ClaimAutomationRun(id, a.ApprovalHash, a.RecipeText, 50000, 5, exStart.Add(-time.Hour)); err != nil || !ok {
		t.Fatalf("claim prior = (%v, %v)", ok, err)
	}
	err := f.d.FinishAutomationRun(id, db.RunFinish{Status: db.RunSucceeded, Now: exStart.Add(-time.Hour)},
		&db.RunCommit{StateJSON: []byte(`{"k":1}`), Outputs: []db.AutomationOutput{{Kind: "inbox", Title: "prior", Body: "b"}}})
	if err != nil {
		t.Fatal(err)
	}
}

// priorTokens records a finished run of a started at started that spent
// tokens (input only).
func (f *exFixture) priorTokens(t *testing.T, a db.Automation, started time.Time, tokens int64) {
	t.Helper()
	id := f.enqueueReq(t, db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerCatchUp, Now: started})
	if ok, err := f.d.ClaimAutomationRun(id, a.ApprovalHash, a.RecipeText, 50000, 5, started); err != nil || !ok {
		t.Fatalf("claim prior = (%v, %v)", ok, err)
	}
	if err := f.d.AddAutomationRunUsage(id, db.RunUsage{InputTokens: tokens}); err != nil {
		t.Fatal(err)
	}
	if err := f.d.FinishAutomationRun(id, db.RunFinish{Status: db.RunSucceeded, Now: started}, nil); err != nil {
		t.Fatal(err)
	}
}

// blockingGen blocks every Generate until release is closed or the call's
// context ends; entered receives once per call.
type blockingGen struct {
	entered chan struct{}
	release chan struct{}
	usage   digest.Usage
}

func newBlockingGen() *blockingGen {
	return &blockingGen{entered: make(chan struct{}, 16), release: make(chan struct{}),
		usage: digest.Usage{InputTokens: 10, OutputTokens: 5}}
}

func (g *blockingGen) Generate(ctx context.Context, _, _, sessionID string) (string, *digest.Usage, string, error) {
	g.entered <- struct{}{}
	select {
	case <-g.release:
		u := g.usage
		return "done", &u, sessionID, nil
	case <-ctx.Done():
		return "", nil, sessionID, ctx.Err()
	}
}

func (g *blockingGen) waitEntered(t *testing.T) {
	t.Helper()
	select {
	case <-g.entered:
	case <-time.After(10 * time.Second):
		t.Fatal("the generator was never called")
	}
}

// exModule is a test SDK module.
type exModule struct {
	name string
	fns  map[string]automations.SDKFunc
}

func (m exModule) Name() string { return m.name }

func (m exModule) Install(def automations.Definer) {
	for p, fn := range m.fns {
		def.Define(p, fn)
	}
}

// pastDeadlineModule defines jump(): the fake clock moves past the run's
// 5-minute deadline and the meter's watcher is re-armed, so the deadline
// fires at once in real time; it then sleeps for sleep (a native call that
// ignores the interrupt, as a stuck builtin would).
func pastDeadlineModule(clock *automationstest.FakeClock, sleep time.Duration) automations.Module {
	return exModule{name: "jump", fns: map[string]automations.SDKFunc{
		"jump": func(env *automations.Env, _ goja.FunctionCall, _ *goja.Runtime) (any, error) {
			clock.Advance(6 * time.Minute)
			env.Meter.PauseActive()
			env.Meter.ResumeActive()
			time.Sleep(sleep)
			return nil, nil
		},
	}}
}

func fakeGenCalls(t *testing.T, g digest.Generator) int {
	t.Helper()
	fg, ok := g.(*automationstest.FakeGenerator)
	if !ok {
		t.Fatalf("generator %T is not a FakeGenerator", g)
	}
	return fg.CallCount()
}

func usageGen(in, out int) *automationstest.FakeGenerator {
	return &automationstest.FakeGenerator{Replies: []string{"done"}, Usage: []digest.Usage{{InputTokens: in, OutputTokens: out}}}
}

func mustContain(t *testing.T, what, got, want string) {
	t.Helper()
	if !strings.Contains(got, want) {
		t.Fatalf("%s = %q; want it to contain %q", what, got, want)
	}
}

func stepStatusesOf(steps []db.AutomationRunStep) string {
	parts := make([]string, len(steps))
	for i, s := range steps {
		parts[i] = fmt.Sprintf("%s:%s", s.Kind, s.Status)
	}
	return strings.Join(parts, ",")
}
