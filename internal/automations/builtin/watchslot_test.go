package builtin

import (
	"context"
	"errors"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/automations/watch"
	"watchtower/internal/config"
	"watchtower/internal/customtracks"
	"watchtower/internal/db"
	"watchtower/internal/digest"
)

// scanGenerator is the custom-track scan's model: it records each prompt and
// fails a prompt that contains failOn.
type scanGenerator struct {
	mu      sync.Mutex
	prompts []string
	failOn  string
	out     string
	// in and outTokens are the usage each call reports.
	in, outTokens int
}

func (g *scanGenerator) Generate(_ context.Context, _, user, _ string) (string, *digest.Usage, string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.prompts = append(g.prompts, user)
	if g.failOn != "" && strings.Contains(user, g.failOn) {
		return "", nil, "", errors.New("model down")
	}
	out := g.out
	if out == "" {
		out = `{"events":[]}`
	}
	return out, &digest.Usage{InputTokens: g.in, OutputTokens: g.outTokens}, "", nil
}

func (g *scanGenerator) all() []string {
	g.mu.Lock()
	defer g.mu.Unlock()
	return append([]string(nil), g.prompts...)
}

// recScanner is the real custom-track pipeline, recording each ScanBound's
// options and each RecordFailure.
type recScanner struct {
	p        *customtracks.Pipeline
	mu       sync.Mutex
	scans    []customtracks.ScanOptions
	failures []int
}

func (s *recScanner) ScanBound(ctx context.Context, t db.Track, o customtracks.ScanOptions) ([]db.TrackEvent, error) {
	s.mu.Lock()
	s.scans = append(s.scans, o)
	s.mu.Unlock()
	return s.p.ScanBound(ctx, t, o)
}

func (s *recScanner) Due(t db.Track, now time.Time) bool { return s.p.Due(t, now) }

func (s *recScanner) RecordFailure(trackID int, now time.Time, err error) {
	s.mu.Lock()
	s.failures = append(s.failures, trackID)
	s.mu.Unlock()
	s.p.RecordFailure(trackID, now, err)
}

func (s *recScanner) AccumulatedUsage() (int, int, float64, int) { return s.p.AccumulatedUsage() }

func (s *recScanner) scanCalls() []customtracks.ScanOptions {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]customtracks.ScanOptions(nil), s.scans...)
}

func (s *recScanner) failed() []int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]int(nil), s.failures...)
}

// watchFixture is a database with an owner, a workspace, the real slot
// executor with track.scan over the real custom-track pipeline (a fake
// model), and the runner. Its clock is the wall clock's second: the scan
// windows are the pipeline's, read from time.Now.
type watchFixture struct {
	d      *db.DB
	ws     string
	clock  *automationstest.FakeClock
	ix     *automations.Indexer
	gen    *scanGenerator
	scan   *recScanner
	exec   *automations.Executor
	runner *Runner
}

func newWatchFixture(t *testing.T) *watchFixture {
	t.Helper()
	d := db.OpenTestDB(t)
	if _, err := d.Exec(`INSERT INTO slack_accounts (id, team_id, current_user_id) VALUES (1, 'T1', '1:U1')`); err != nil {
		t.Fatal(err)
	}
	ws := t.TempDir()
	clock := automationstest.NewFakeClock(time.Now().UTC().Truncate(time.Second))
	gen := &scanGenerator{}
	logger := log.New(io.Discard, "", 0)
	scan := &recScanner{p: customtracks.New(d, gen, "", logger)}
	b := automations.Backends{DB: d, Clock: clock, Primitives: WatchPrimitives(d, scan, d.ResolveOwner, clock.Now)}
	exec := automations.NewExecutor(d, b, automations.ExecutorOptions{Logger: logger})
	cfg, err := config.Load(filepath.Join(t.TempDir(), "absent.yaml"))
	if err != nil {
		t.Fatal(err)
	}
	return &watchFixture{d: d, ws: ws, clock: clock, ix: automations.NewIndexer(d, ws, clock), gen: gen, scan: scan,
		exec: exec, runner: NewRunner(d, exec, nil, cfg, clock, logger)}
}

// recipePath is where watch recipe slug lives.
func (f *watchFixture) recipePath(t *testing.T, slug string) (dir, path string) {
	t.Helper()
	dir, err := automations.CanonicalDir(automations.PersonalDir(f.ws))
	if err != nil {
		t.Fatal(err)
	}
	return dir, filepath.Join(dir, slug+".md")
}

// addWatch writes and indexes a watch recipe, then confirms and enables it
// as asked.
func (f *watchFixture) addWatch(t *testing.T, slug, instruction string, confirm, enable bool) *db.Automation {
	t.Helper()
	data, err := watch.Render("Watch "+slug, instruction)
	if err != nil {
		t.Fatal(err)
	}
	dir, path := f.recipePath(t, slug)
	a, err := f.ix.WriteRecipe(context.Background(), automations.Scope{Kind: automations.ScopePersonal}, dir, path, data)
	if err != nil {
		t.Fatal(err)
	}
	if confirm {
		if err := f.d.ConfirmAutomation(a.ID, a.ApprovalHash, f.clock.Now()); err != nil {
			t.Fatal(err)
		}
	}
	if enable {
		if err := f.d.SetAutomationEnabled(a.ID, true, f.clock.Now()); err != nil {
			t.Fatal(err)
		}
	}
	return f.automation(t, a.ID)
}

func (f *watchFixture) automation(t *testing.T, id int64) *db.Automation {
	t.Helper()
	a, err := f.d.GetAutomation(id)
	if err != nil {
		t.Fatal(err)
	}
	return a
}

func (f *watchFixture) runsOf(t *testing.T, id int64) []db.AutomationRun {
	t.Helper()
	runs, err := f.d.ListAutomationRuns(id, 0)
	if err != nil {
		t.Fatal(err)
	}
	return runs
}

// trackOf is watch recipe id's bound track (nil when none).
func (f *watchFixture) trackOf(t *testing.T, id int64) *db.Track {
	t.Helper()
	tr, err := f.d.GetWatchTrack(id)
	if err != nil {
		t.Fatal(err)
	}
	return tr
}

// seedActivity adds one inbox item stamped a minute ago (inside every scan
// window that opens before it).
func (f *watchFixture) seedActivity(t *testing.T, snippet string) {
	t.Helper()
	at := time.Now().UTC().Add(-time.Minute).Format("2006-01-02T15:04:05Z")
	if _, err := f.d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, snippet, created_at)
		VALUES ('C1', ?, 'U2', 'mention', ?, ?)`, snippet, snippet, at); err != nil {
		t.Fatal(err)
	}
}

func (f *watchFixture) slot(t *testing.T) []SlotOutcome {
	t.Helper()
	return f.runner.RunWatchSlot(context.Background(), NewWatchGate(f.d, f.scan, log.New(io.Discard, "", 0)))
}

// outcomeOf is the slot outcome of automation id.
func outcomeOf(t *testing.T, out []SlotOutcome, id int64) SlotOutcome {
	t.Helper()
	for _, o := range out {
		if o.AutomationID == id {
			return o
		}
	}
	t.Fatalf("no outcome for automation %d in %+v", id, out)
	return SlotOutcome{}
}

func TestWatchSlot_RunsConfirmedEnabledRecipes(t *testing.T) {
	f := newWatchFixture(t)
	on := f.addWatch(t, "on", "watch the refund", true, true)
	unconfirmed := f.addWatch(t, "unconfirmed", "watch the launch", false, true)
	off := f.addWatch(t, "off", "watch the hiring", true, false)
	queued, _, err := f.d.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: unconfirmed.ID, Trigger: db.TriggerManual,
		Now: f.clock.Now()})
	if err != nil {
		t.Fatal(err)
	}
	f.seedActivity(t, "the refund was approved")

	out := f.slot(t)
	if len(out) != 3 {
		t.Fatalf("outcomes = %+v; want one per recipe", out)
	}
	if o := outcomeOf(t, out, on.ID); o.Status != db.RunSucceeded || o.RunID == 0 {
		t.Errorf("confirmed, enabled: %+v; want a succeeded run", o)
	}
	runs := f.runsOf(t, on.ID)
	if len(runs) != 1 || runs[0].Trigger != db.TriggerSync {
		t.Fatalf("runs = %+v; want one sync run", runs)
	}
	if o := outcomeOf(t, out, unconfirmed.ID); o.Skipped != SkippedNotConfirmed || o.RunID != 0 {
		t.Errorf("unconfirmed: %+v; want not_confirmed", o)
	}
	run, err := f.d.GetAutomationRun(queued)
	if err != nil {
		t.Fatal(err)
	}
	if run.Status != db.RunCancelled || run.ErrorKind != "not_runnable" {
		t.Errorf("the unconfirmed recipe's queued run = %s/%s; want cancelled not_runnable", run.Status, run.ErrorKind)
	}
	if o := outcomeOf(t, out, off.ID); o.Skipped != SkippedOff || o.RunID != 0 {
		t.Errorf("disabled: %+v; want off", o)
	}
	if n := len(f.runsOf(t, off.ID)); n != 0 {
		t.Errorf("disabled recipe: %d runs", n)
	}
	if calls := f.scan.scanCalls(); len(calls) != 1 || calls[0].Instruction != "watch the refund" {
		t.Errorf("scans = %+v; want one, with the confirmed recipe's instruction", calls)
	}
	if tr := f.trackOf(t, on.ID); tr == nil || !tr.Enabled || tr.Text != "Watch on" || tr.AssigneeUserID != "1:U1" {
		t.Errorf("bound track = %+v; want an enabled track named after the recipe, owned by the owner", tr)
	}
}

func TestWatchSlot_NoActivityWritesNoRun(t *testing.T) {
	f := newWatchFixture(t)
	a := f.addWatch(t, "quiet", "watch the refund", true, true)

	out := f.slot(t)
	if o := outcomeOf(t, out, a.ID); o.Skipped != SkippedNotDue || o.RunID != 0 {
		t.Errorf("no activity: %+v; want not_due", o)
	}
	if n := len(f.runsOf(t, a.ID)); n != 0 {
		t.Errorf("%d runs; want none", n)
	}
	if n := len(f.gen.all()); n != 0 {
		t.Errorf("%d model calls; want none", n)
	}
	if f.trackOf(t, a.ID) == nil {
		t.Error("the slot did not ensure the recipe's track")
	}
}

func TestWatchSlot_BudgetSpentWritesNoRun(t *testing.T) {
	f := newWatchFixture(t)
	a := f.addWatch(t, "spent", "watch the refund", true, true)
	id, err := f.d.EnsureWatchTrack(a.ID, "1:U1", a.Name, "watch the refund")
	if err != nil {
		t.Fatal(err)
	}
	for range 3 {
		if _, err := f.d.RecordCustomTrackScanFailure(id, f.clock.Now()); err != nil {
			t.Fatal(err)
		}
	}
	f.seedActivity(t, "the refund was approved")

	out := f.slot(t)
	if o := outcomeOf(t, out, a.ID); o.Skipped != SkippedNotDue || o.RunID != 0 {
		t.Errorf("budget spent: %+v; want not_due", o)
	}
	if n := len(f.runsOf(t, a.ID)); n != 0 {
		t.Errorf("%d runs; want none", n)
	}
	if n := len(f.gen.all()); n != 0 {
		t.Errorf("%d model calls; want none", n)
	}
}

func TestWatchSlot_HandEditedRecipeStopsTheScan(t *testing.T) {
	f := newWatchFixture(t)
	a := f.addWatch(t, "edited", "watch the refund", true, true)
	f.seedActivity(t, "the refund was approved")
	if o := outcomeOf(t, f.slot(t), a.ID); o.Status != db.RunSucceeded {
		t.Fatalf("first slot: %+v", o)
	}

	edited, err := watch.SetInstruction([]byte(a.RecipeText), "watch everything")
	if err != nil {
		t.Fatal(err)
	}
	_, path := f.recipePath(t, "edited")
	if err := os.WriteFile(path, edited, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := f.ix.RescanPersonal(context.Background()); err != nil {
		t.Fatal(err)
	}
	if f.automation(t, a.ID).Confirmed() {
		t.Fatal("a hand-edited recipe is still confirmed")
	}
	queued, _, err := f.d.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerManual,
		Now: f.clock.Now()})
	if err != nil {
		t.Fatal(err)
	}
	f.seedActivity(t, "the refund moved")

	if o := outcomeOf(t, f.slot(t), a.ID); o.Skipped != SkippedNotConfirmed || o.RunID != 0 {
		t.Errorf("hand edited: %+v; want not_confirmed", o)
	}
	if n := len(f.scan.scanCalls()); n != 1 {
		t.Errorf("%d scans; want only the one before the edit", n)
	}
	if run, err := f.d.GetAutomationRun(queued); err != nil || run.Status != db.RunCancelled {
		t.Errorf("queued manual run = %+v, %v; want cancelled", run, err)
	}
	if tr := f.trackOf(t, a.ID); tr == nil || tr.Instruction != "watch the refund" {
		t.Errorf("track = %+v; the unconfirmed instruction must not reach it", tr)
	}
}

func TestWatchSlot_DeletedRecipeLeavesTrackUnbound(t *testing.T) {
	f := newWatchFixture(t)
	f.gen.out = `{"events":[{"summary":"the refund was approved","source_type":"inbox","source_id":"1"}]}`
	a := f.addWatch(t, "deleted", "watch the refund", true, true)
	f.seedActivity(t, "the refund was approved")
	if o := outcomeOf(t, f.slot(t), a.ID); o.Status != db.RunSucceeded {
		t.Fatalf("first slot: %+v", o)
	}
	tr := f.trackOf(t, a.ID)
	if tr == nil {
		t.Fatal("no bound track after the first scan")
	}
	before, err := f.d.GetTrackEvents(tr.ID, 100)
	if err != nil || len(before) == 0 {
		t.Fatalf("events before = %d, %v; want the first scan's", len(before), err)
	}

	_, path := f.recipePath(t, "deleted")
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if _, err := f.ix.RescanPersonal(context.Background()); err != nil {
		t.Fatal(err)
	}
	if f.automation(t, a.ID).RemovedAt == nil {
		t.Fatal("the indexer did not mark the recipe removed")
	}
	f.seedActivity(t, "the refund moved")

	for _, o := range f.slot(t) {
		if o.AutomationID == a.ID {
			t.Errorf("a removed recipe got an outcome %+v", o)
		}
	}
	if n := len(f.runsOf(t, a.ID)); n != 1 {
		t.Errorf("%d runs; want only the one before the removal", n)
	}
	got, err := f.d.GetTrackByID(tr.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.AutomationID != 0 || got.Enabled {
		t.Errorf("track automation_id=%d enabled=%v; want unbound and paused", got.AutomationID, got.Enabled)
	}
	after, err := f.d.GetTrackEvents(tr.ID, 100)
	if err != nil || len(after) != len(before) {
		t.Errorf("events after = %d, %v; want the %d kept", len(after), err, len(before))
	}
}

func TestWatchSlot_QueuedScanFromRunsBackfill(t *testing.T) {
	f := newWatchFixture(t)
	a := f.addWatch(t, "backfill", "watch the refund", true, true)
	queued, _, err := f.d.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerManual,
		EventJSON: `{"builtin":{"since":"2026-10-01T02:00:00+02:00"}}`, Now: f.clock.Now()})
	if err != nil {
		t.Fatal(err)
	}
	// No activity: the gate would say not due, but a queued run skips it.
	o := outcomeOf(t, f.slot(t), a.ID)
	if o.RunID != queued || o.Status != db.RunSucceeded {
		t.Fatalf("slot = %+v; want queued run %d succeeded", o, queued)
	}
	calls := f.scan.scanCalls()
	if len(calls) != 1 || calls[0].Since != "2026-10-01T00:00:00Z" {
		t.Fatalf("scans = %+v; want one with Since 2026-10-01T00:00:00Z", calls)
	}
	if n := len(f.runsOf(t, a.ID)); n != 1 {
		t.Errorf("%d runs; want the queued one only", n)
	}
}

func TestWatchSlot_FailureChargesBudgetAndNextRecipeRuns(t *testing.T) {
	f := newWatchFixture(t)
	f.gen.failOn = "watch the refund"
	first := f.addWatch(t, "first", "watch the refund", true, true)
	second := f.addWatch(t, "second", "watch the launch", true, true)
	f.seedActivity(t, "the refund and the launch")

	out := f.slot(t)
	if o := outcomeOf(t, out, first.ID); o.Status != db.RunFailed {
		t.Errorf("failing watch: %+v; want failed", o)
	}
	if o := outcomeOf(t, out, second.ID); o.Status != db.RunSucceeded {
		t.Errorf("next watch: %+v; want succeeded", o)
	}
	tr := f.trackOf(t, first.ID)
	if got := f.scan.failed(); len(got) != 1 || got[0] != tr.ID {
		t.Fatalf("failures = %v; want one, on track %d", got, tr.ID)
	}
	spent, err := f.d.CustomTrackScanBudgetSpent(tr.ID, f.clock.Now().UTC().Format("2006-01-02"), 1)
	if err != nil || !spent {
		t.Errorf("one attempt charged = %v, %v; want the failure on the track's budget", spent, err)
	}
}

func TestWatchSlot_InstructionMirroredToTrack(t *testing.T) {
	f := newWatchFixture(t)
	a := f.addWatch(t, "mirror", "watch the refund", true, true)
	f.seedActivity(t, "the refund was approved")
	if o := outcomeOf(t, f.slot(t), a.ID); o.Status != db.RunSucceeded {
		t.Fatalf("first slot: %+v", o)
	}
	tr := f.trackOf(t, a.ID)
	if tr == nil || tr.Instruction != "watch the refund" {
		t.Fatalf("track = %+v; want the recipe's instruction", tr)
	}
	// The first scan moved the watermark to the last second: open the window
	// again so the next activity is new.
	if err := f.d.SetTrackLastRun(tr.ID, time.Now().UTC().Add(-time.Hour).Format("2006-01-02T15:04:05Z")); err != nil {
		t.Fatal(err)
	}

	edited, err := watch.SetInstruction([]byte(a.RecipeText), "watch the refund and the chargeback")
	if err != nil {
		t.Fatal(err)
	}
	dir, path := f.recipePath(t, "mirror")
	b, err := f.ix.WriteRecipe(context.Background(), automations.Scope{Kind: automations.ScopePersonal}, dir, path, edited)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.d.ConfirmAutomation(b.ID, b.ApprovalHash, f.clock.Now()); err != nil {
		t.Fatal(err)
	}
	f.seedActivity(t, "a chargeback came in")
	if o := outcomeOf(t, f.slot(t), a.ID); o.Status != db.RunSucceeded {
		t.Fatalf("second slot: %+v", o)
	}
	if tr := f.trackOf(t, a.ID); tr == nil || tr.Instruction != "watch the refund and the chargeback" {
		t.Errorf("track = %+v; want the new instruction mirrored", tr)
	}
	prompts := f.gen.all()
	if len(prompts) == 0 || !strings.Contains(prompts[len(prompts)-1], "watch the refund and the chargeback") {
		t.Errorf("the last scan prompt does not carry the new instruction")
	}
}

func TestWatchPrimitive_NoOwnerSkipsAndDismissedNeverScans(t *testing.T) {
	f := newWatchFixture(t)
	a := f.addWatch(t, "owner", "watch the refund", true, true)
	runID, _, err := f.d.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerManual, Now: f.clock.Now()})
	if err != nil {
		t.Fatal(err)
	}
	scan := WatchPrimitives(f.d, f.scan, func() (db.Owner, error) { return db.Owner{}, nil }, f.clock.Now)["track.scan"]
	call := automations.PrimitiveCall{Name: "track.scan", Prompt: "watch the refund",
		Trigger: automations.TriggerInfo{Kind: db.TriggerManual, RunID: runID}}
	res, err := scan(context.Background(), call)
	if err != nil || res.Status != "skipped" {
		t.Errorf("no owner: %+v, %v; want skipped (OWNER-02)", res, err)
	}
	if f.trackOf(t, a.ID) != nil {
		t.Error("a track was created without an owner")
	}

	scan = WatchPrimitives(f.d, f.scan, f.d.ResolveOwner, f.clock.Now)["track.scan"]
	id, err := f.d.EnsureWatchTrack(a.ID, "1:U1", a.Name, "watch the refund")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.d.Exec(`UPDATE tracks SET dismissed_at = '2026-10-22T09:00:00Z' WHERE id = ?`, id); err != nil {
		t.Fatal(err)
	}
	res, err = scan(context.Background(), call)
	if err != nil || res.Status != "skipped" {
		t.Errorf("dismissed: %+v, %v; want skipped", res, err)
	}
	if n := len(f.scan.scanCalls()); n != 0 {
		t.Errorf("%d scans of a dismissed track", n)
	}
}

func TestWatchSlot_ScanUsageLandsOnTheRun(t *testing.T) {
	f := newWatchFixture(t)
	f.gen.in, f.gen.outTokens = 1200, 300
	a := f.addWatch(t, "usage", "watch the refund", true, true)
	f.seedActivity(t, "the refund was approved")

	o := outcomeOf(t, f.slot(t), a.ID)
	if o.Status != db.RunSucceeded {
		t.Fatalf("slot = %+v", o)
	}
	run, err := f.d.GetAutomationRun(o.RunID)
	if err != nil {
		t.Fatal(err)
	}
	if run.InputTokens != 1200 || run.OutputTokens != 300 {
		t.Errorf("run tokens = %d/%d; want the scan's 1200/300", run.InputTokens, run.OutputTokens)
	}
	steps, err := f.d.ListAutomationRunSteps(o.RunID)
	if err != nil {
		t.Fatal(err)
	}
	var found bool
	for _, st := range steps {
		if st.Name == "track.scan" {
			found = true
			if st.InputTokens != 1200 || st.OutputTokens != 300 {
				t.Errorf("step tokens = %d/%d; want 1200/300", st.InputTokens, st.OutputTokens)
			}
		}
	}
	if !found {
		t.Errorf("no track.scan step in %+v", steps)
	}
}

func TestWatchSlot_UnparsableRecipeScansNothing(t *testing.T) {
	f := newWatchFixture(t)
	a := f.addWatch(t, "broken", "watch the refund", true, true)
	f.seedActivity(t, "the refund was approved")
	if o := outcomeOf(t, f.slot(t), a.ID); o.Status != db.RunSucceeded {
		t.Fatalf("first slot: %+v", o)
	}
	tr := f.trackOf(t, a.ID)
	if tr == nil {
		t.Fatal("no bound track after the first scan")
	}
	_, path := f.recipePath(t, "broken")
	if err := os.WriteFile(path, []byte("---\nname: broken\ntrigger: {sync: custom_tracks\n---\nnot a recipe\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := f.ix.RescanPersonal(context.Background()); err != nil {
		t.Fatal(err)
	}
	if b := f.automation(t, a.ID); b.ParseError == "" {
		t.Fatalf("the broken recipe parsed: %+v", b)
	}
	if err := f.d.SetTrackLastRun(tr.ID, time.Now().UTC().Add(-time.Hour).Format("2006-01-02T15:04:05Z")); err != nil {
		t.Fatal(err)
	}

	for _, o := range f.slot(t) {
		if o.AutomationID == a.ID && (o.RunID != 0 || o.Skipped == "") {
			t.Errorf("an unparsable recipe ran: %+v", o)
		}
	}
	if n := len(f.runsOf(t, a.ID)); n != 1 {
		t.Errorf("%d runs; want only the one before the break", n)
	}
	if n := len(f.scan.scanCalls()); n != 1 {
		t.Errorf("%d scans; want only the one before the break", n)
	}
	if got := f.trackOf(t, a.ID); got == nil || got.ID != tr.ID {
		t.Errorf("track = %+v; want it still bound", got)
	}
}

// A run claimed before the recipe's instruction was changed (a Save mid-scan)
// scans with its own text but never writes it back over the new mirror.
func TestWatchSlot_StaleRunNeverOverwritesTheMirror(t *testing.T) {
	f := newWatchFixture(t)
	a := f.addWatch(t, "stale", "watch the refund", true, true)
	runID, _, err := f.d.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerManual, Now: f.clock.Now()})
	if err != nil {
		t.Fatal(err)
	}
	ok, err := f.d.ClaimAutomationRun(runID, a.ApprovalHash, a.RecipeText, a.BudgetTokens, a.BudgetMinutes, f.clock.Now())
	if err != nil || !ok {
		t.Fatalf("claim = %v, %v", ok, err)
	}
	edited, err := watch.SetInstruction([]byte(a.RecipeText), "watch the invoice")
	if err != nil {
		t.Fatal(err)
	}
	dir, path := f.recipePath(t, "stale")
	b, err := f.ix.WriteRecipe(context.Background(), automations.Scope{Kind: automations.ScopePersonal}, dir, path, edited)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.d.ConfirmAutomation(b.ID, b.ApprovalHash, f.clock.Now()); err != nil {
		t.Fatal(err)
	}
	owner, err := f.d.ResolveOwner()
	if err != nil {
		t.Fatal(err)
	}
	trackID, err := f.d.EnsureWatchTrack(a.ID, owner.ID, a.Name, "watch the invoice")
	if err != nil {
		t.Fatal(err)
	}
	if err := f.d.SetWatchInstruction(trackID, "watch the invoice"); err != nil {
		t.Fatal(err)
	}

	scan := WatchPrimitives(f.d, f.scan, f.d.ResolveOwner, f.clock.Now)["track.scan"]
	if _, err := scan(context.Background(), automations.PrimitiveCall{Name: "track.scan", Prompt: "watch the refund",
		Trigger: automations.TriggerInfo{Kind: db.TriggerManual, RunID: runID}}); err != nil {
		t.Fatalf("track.scan: %v", err)
	}
	if tr := f.trackOf(t, a.ID); tr == nil || tr.Instruction != "watch the invoice" {
		t.Errorf("track = %+v; want the new instruction kept", tr)
	}
}
