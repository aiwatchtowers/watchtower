package automations_test

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"watchtower/internal/aiconsent"
	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/llmusage"
)

// consentSwitch is an injected aiconsent.Reader the test flips.
type consentSwitch struct{ paused atomic.Bool }

func newConsent(paused bool) *consentSwitch {
	c := &consentSwitch{}
	c.paused.Store(paused)
	return c
}

func (c *consentSwitch) read() aiconsent.State {
	if c.paused.Load() {
		return aiconsent.Resolve(aiconsent.AnswerPaused, nil)
	}
	return aiconsent.Resolve(aiconsent.AnswerAllowed, nil)
}

// daemonProcess makes this test process's default origin background, as in
// the daemon that runs the executor, so only a ctx mark makes a call owner.
func daemonProcess(t *testing.T) {
	t.Helper()
	none := func(string) string { return "" }
	aiconsent.InitProcess("daemon", none)
	t.Cleanup(func() { aiconsent.InitProcess("", none) })
}

// originCall is what one model call's ctx said.
type originCall struct {
	origin   aiconsent.Origin
	admitted bool
}

// consentGen is a generator behind the per-call backstop: it refuses a call
// aiconsent.CheckWith refuses under reader, and records each call's origin.
type consentGen struct {
	reader aiconsent.Reader
	mu     sync.Mutex
	calls  []originCall
	denied int
}

func (g *consentGen) Generate(ctx context.Context, _, _, sessionID string) (string, *digest.Usage, string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if err := aiconsent.CheckWith(ctx, g.reader); err != nil {
		g.denied++
		return "", nil, sessionID, err
	}
	o, admitted := aiconsent.OriginOf(ctx)
	g.calls = append(g.calls, originCall{origin: o, admitted: admitted})
	return "done", &digest.Usage{Tokens: llmusage.Tokens{Input: 10, Output: 5}}, sessionID, nil
}

func (g *consentGen) snapshot() (calls []originCall, denied int) {
	g.mu.Lock()
	defer g.mu.Unlock()
	return append([]originCall(nil), g.calls...), g.denied
}

// --- UsesAI ---

// TestManifest_UsesAIFixtureCoversEveryPrimitive: the shared fixture has a
// builtin:<p> row for every PrimitiveUsesAI key with its answer, so the
// Desktop's hand-kept twin (AutomationAIUse) is pinned to each one.
func TestManifest_UsesAIFixtureCoversEveryPrimitive(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "uses_ai_cases.json"))
	if err != nil {
		t.Fatal(err)
	}
	var rows []struct {
		Permissions []string `json:"permissions"`
		UsesAI      bool     `json:"uses_ai"`
	}
	if err := json.Unmarshal(raw, &rows); err != nil {
		t.Fatal(err)
	}
	single := map[string]bool{}
	for _, row := range rows {
		if len(row.Permissions) == 1 {
			single[row.Permissions[0]] = row.UsesAI
		}
	}
	for name, ai := range automations.PrimitiveUsesAI {
		got, ok := single["builtin:"+name]
		if !ok {
			t.Errorf("uses_ai_cases.json has no [\"builtin:%s\"] row", name)
			continue
		}
		if got != ai {
			t.Errorf("uses_ai_cases.json builtin:%s uses_ai = %v; PrimitiveUsesAI says %v", name, got, ai)
		}
	}
}

func TestManifest_UsesAISharedFixture(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "uses_ai_cases.json"))
	if err != nil {
		t.Fatal(err)
	}
	var rows []struct {
		Permissions []string `json:"permissions"`
		UsesAI      bool     `json:"uses_ai"`
	}
	if err := json.Unmarshal(raw, &rows); err != nil {
		t.Fatal(err)
	}
	if len(rows) == 0 {
		t.Fatal("the fixture has no rows")
	}
	scopes := []automations.Scope{
		{Kind: automations.ScopePersonal},
		{Kind: automations.ScopeWorkbench, WorkbenchID: 1},
		{Kind: automations.ScopePersonal, BuiltinID: "morning-brief"},
	}
	for _, row := range rows {
		if got := automations.PermissionsUseAI(row.Permissions); got != row.UsesAI {
			t.Errorf("PermissionsUseAI(%q) = %v; want %v", row.Permissions, got, row.UsesAI)
		}
		// The parsed manifest agrees wherever the entries parse.
		for _, sc := range scopes {
			m, err := automations.ParseManifest(row.Permissions, nil, sc)
			if err != nil {
				continue
			}
			if got := m.UsesAI(); got != row.UsesAI {
				t.Errorf("Manifest(%q).UsesAI() = %v; want %v", row.Permissions, got, row.UsesAI)
			}
			break
		}
	}
}

func TestAutomationUsesAI_UndecodablePermissionsFailClosed(t *testing.T) {
	for raw, want := range map[string]bool{
		`["llm:light"]`: true, `["tool:list_targets"]`: false, `[]`: false, `not json`: true, ``: true,
	} {
		if got := automations.AutomationUsesAI(&db.Automation{PermissionsJSON: raw}); got != want {
			t.Errorf("AutomationUsesAI(%q) = %v; want %v", raw, got, want)
		}
	}
}

func TestRunMarkerEnv_MatchesAiconsent(t *testing.T) {
	if automations.RunEnvMarker != aiconsent.RunMarkerEnv {
		t.Fatalf("RunEnvMarker = %q; aiconsent.RunMarkerEnv = %q", automations.RunEnvMarker, aiconsent.RunMarkerEnv)
	}
	if automations.BackgroundAIPausedMessage != aiconsent.ErrPaused.Error() {
		t.Fatalf("BackgroundAIPausedMessage = %q; aiconsent.ErrPaused = %q",
			automations.BackgroundAIPausedMessage, aiconsent.ErrPaused)
	}
}

// --- Scheduler (AUTO-10, paused window) ---

func TestScheduler_PausedAdvancesWithoutRun(t *testing.T) {
	f := newSchedFixture(t, time.Time{})
	f.clock.Set(f.at(14, 8, 0))
	a := f.seed(t, "morning", "0 9 * * *", "run_once")
	f.s.SetConsent(newConsent(true).read)
	f.tick(t, f.at(14, 9, 0))
	wantRunCount(t, f.runs(t, a.ID), 0)
	got := f.get(t, a.ID)
	wantTime(t, "last_scheduled_for", got.LastScheduledFor, f.at(14, 9, 0))
	wantTime(t, "next_run_at", got.NextRunAt, f.at(15, 9, 0))
	if f.wakeCount() != 0 {
		t.Errorf("wake calls = %d, want 0", f.wakeCount())
	}
}

func TestScheduler_AllowAfterPauseDoesNotCatchUp(t *testing.T) {
	f := newSchedFixture(t, time.Time{})
	f.clock.Set(f.at(14, 8, 30))
	a := f.seed(t, "hourly", "0 * * * *", "run_once")
	consent := newConsent(true)
	f.s.SetConsent(consent.read)
	for _, h := range []int{9, 10, 11} {
		f.tick(t, f.at(14, h, 0))
	}
	wantRunCount(t, f.runs(t, a.ID), 0)
	consent.paused.Store(false)
	f.tick(t, f.at(14, 11, 30))
	wantRunCount(t, f.runs(t, a.ID), 0)
	f.tick(t, f.at(14, 12, 0))
	rs := f.runs(t, a.ID)
	wantRunCount(t, rs, 1)
	wantRun(t, rs[0], db.TriggerSchedule, f.at(14, 12, 0))
}

// shellSchedRecipe is a workbench schedule recipe with no AI permission.
const shellSchedRecipe = "---\nname: Nightly make\ntrigger:\n  schedule: \"0 9 * * *\"\nmissed: run_once\n" +
	"permissions:\n  - shell:\"make\"\n---\nRuns make.\n\n```js\nshell(\"make\")\n```\n"

func TestScheduler_NonAIRecipeRunsWhilePaused(t *testing.T) {
	f := newSchedFixture(t, time.Time{})
	f.clock.Set(f.at(14, 8, 0))
	wb, folder := newWorkbench(t, f.d)
	writeWorkbenchRecipe(t, folder, "nightly", shellSchedRecipe)
	rescanWorkbench(t, f.ix, wb, folder)
	a := workbenchRow(t, f.d, wb, "nightly")
	if a.ParseError != "" {
		t.Fatalf("recipe does not parse: %s", a.ParseError)
	}
	if err := f.d.ConfirmAutomation(a.ID, a.ApprovalHash, f.clock.Now()); err != nil {
		t.Fatal(err)
	}
	if err := f.d.SetAutomationEnabled(a.ID, true, f.clock.Now()); err != nil {
		t.Fatal(err)
	}
	f.s.SetConsent(newConsent(true).read)
	f.tick(t, f.at(14, 9, 1))
	rs := f.runs(t, a.ID)
	wantRunCount(t, rs, 1)
	wantRun(t, rs[0], db.TriggerSchedule, f.at(14, 9, 0))
}

// --- Event bus ---

func TestBus_PausedSkipsAIRecipes(t *testing.T) {
	f := newBusFixture(t)
	ai := f.seed(t, "ai", automations.SlackReactionAdded, "{}", automationstest.SeedOptions{})
	mcpText := strings.Replace(busRecipeText(automations.SlackReactionAdded, "{}"), "  - llm:light\n", "  - mcp:github/list_*\n", 1)
	plain := automationstest.SeedAutomation(t, f.d, mcpText, automationstest.SeedOptions{Slug: "plain", Now: exStart})
	f.bus.SetConsent(newConsent(true).read)
	f.begin(t)
	if !f.bus.Wants(automations.SlackReactionAdded) {
		t.Fatal("Wants = false; want true (the mcp: recipe listens)")
	}
	f.bus.Publish(automations.ReactionEvent("work", "C0001", "1.0", "eyes"))
	if rep := f.flush(t, busCycleA); rep.Queued != 1 {
		t.Fatalf("report = %+v; want 1 queued", rep)
	}
	if runs := f.runs(t, ai); len(runs) != 0 {
		t.Errorf("AI recipe has %d runs; want none", len(runs))
	}
	if r := f.onlyRun(t, plain); r.Trigger != db.TriggerEvent {
		t.Errorf("plain run trigger = %q; want event", r.Trigger)
	}
}

// --- Executor ---

func TestExecutor_PausedCancelsBackgroundAIRun(t *testing.T) {
	for _, trigger := range []string{db.TriggerSchedule, db.TriggerCatchUp, db.TriggerEvent, db.TriggerSync} {
		t.Run(trigger, func(t *testing.T) {
			gen := &automationstest.FakeGenerator{Replies: []string{"done"}}
			reg := fakeTools()
			f := newExFixture(t, exOpts{gen: gen, consent: newConsent(true).read,
				registry: func(*db.DB) automations.ToolRegistry { return reg }})
			a := f.seed(t, "digest", `tool("list_targets", {}); return llm("x")`, false)
			id := f.enqueue(t, a, trigger)
			f.step(t, 0)
			r := f.wantRun(t, id, db.RunCancelled, db.ErrKindCancelled)
			if r.Error != automations.BackgroundAIPausedMessage || r.FinishedAt == nil {
				t.Fatalf("run = %q, finished %v; want %q", r.Error, r.FinishedAt, automations.BackgroundAIPausedMessage)
			}
			if n := gen.CallCount(); n != 0 {
				t.Fatalf("generator calls = %d; want 0", n)
			}
			if n := len(reg.ReadCalls()); n != 0 {
				t.Fatalf("tool reads = %d; want 0", n)
			}
		})
	}
}

func TestExecutor_PausedRunsNonAIRecipe(t *testing.T) {
	f := newExFixture(t, exOpts{consent: newConsent(true).read})
	text := strings.Replace(exRecipeText(`tool("list_targets", {}); return 1`, ""), "  - llm:light\n", "", 1)
	a := f.seedText(t, "plain", text, false)
	id := f.enqueue(t, a, db.TriggerSchedule)
	f.step(t, 1)
	f.wantRun(t, id, db.RunSucceeded, "")
}

func TestBGAI02_ManualRunWhilePaused(t *testing.T) {
	daemonProcess(t)
	consent := newConsent(true)
	gen := &consentGen{reader: consent.read}
	f := newExFixture(t, exOpts{gen: gen, consent: consent.read})
	a := f.seedText(t, "triage", replyRecipeText(`return llm("x")`), false)

	for _, trigger := range []string{db.TriggerManual, db.TriggerButton} {
		id := f.enqueue(t, a, trigger)
		f.step(t, 1)
		f.wantRun(t, id, db.RunSucceeded, "")
	}
	raw, err := json.Marshal(db.ReplyPayload{Reply: db.ReplyTrigger{OutputID: 99999, Value: "later", Data: json.RawMessage(`null`)}})
	if err != nil {
		t.Fatal(err)
	}
	reply := f.enqueueReq(t, db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerReply, EventJSON: string(raw)})
	f.step(t, 1)
	f.wantRun(t, reply, db.RunSucceeded, "")
	dry := f.enqueue(t, a, db.TriggerDryRun)
	if r, err := f.e.ExecuteInline(context.Background(), dry); err != nil || r.Status != db.RunSucceeded {
		t.Fatalf("dry run = %+v, %v; want succeeded", r, err)
	}

	calls, denied := gen.snapshot()
	if len(calls) != 4 || denied != 0 {
		t.Fatalf("model calls = %d (denied %d); want 4 passed", len(calls), denied)
	}
	for i, c := range calls {
		if c.origin != aiconsent.OriginOwner {
			t.Errorf("call %d origin = %v; want owner", i, c.origin)
		}
	}
}

// ownerPrimitive records whether each call's ctx passes the backstop.
type ownerPrimitive struct {
	reader aiconsent.Reader
	mu     sync.Mutex
	origin []aiconsent.Origin
}

func (p *ownerPrimitive) fn(ctx context.Context, _ automations.PrimitiveCall) (automations.PrimitiveResult, error) {
	if err := aiconsent.CheckWith(ctx, p.reader); err != nil {
		return automations.PrimitiveResult{}, err
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	o, _ := aiconsent.OriginOf(ctx)
	p.origin = append(p.origin, o)
	return automations.PrimitiveResult{Status: "done"}, nil
}

func newOwnerPrimitiveFixture(t *testing.T, consent *consentSwitch) (*exFixture, *ownerPrimitive, db.Automation) {
	t.Helper()
	prim := &ownerPrimitive{reader: consent.read}
	f := newExFixture(t, exOpts{consent: consent.read, backends: func(_ *exFixture, b *automations.Backends) {
		b.Primitives = map[string]automations.PrimitiveFunc{"brief.compose": prim.fn}
	}})
	a := f.seedBuiltin(t, builtinRecipeText(`brief.compose({prompt: "P"}); return 1`, "", "builtin:brief.compose"), true)
	return f, prim, a
}

// A reaction command's sync run (D3) comes with an owner-started ctx.
func TestExecutor_OwnerStartedSyncRunPasses(t *testing.T) {
	daemonProcess(t)
	f, prim, a := newOwnerPrimitiveFixture(t, newConsent(true))
	id := f.enqueueReq(t, db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerSync})
	run, err := f.e.ExecuteBuiltinInline(aiconsent.WithOwnerStarted(context.Background()), id)
	if err != nil || run.Status != db.RunSucceeded {
		t.Fatalf("run = %+v, %v; want succeeded", run, err)
	}
	if len(prim.origin) != 1 || prim.origin[0] != aiconsent.OriginOwner {
		t.Fatalf("primitive origins = %v; want one owner call", prim.origin)
	}
}

// The same sync run from a background caller is held.
func TestExecutor_BackgroundSyncRunHeldInline(t *testing.T) {
	daemonProcess(t)
	f, prim, a := newOwnerPrimitiveFixture(t, newConsent(true))
	id := f.enqueueReq(t, db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerSync})
	run, err := f.e.ExecuteBuiltinInline(context.Background(), id)
	if err != nil {
		t.Fatalf("ExecuteBuiltinInline: %v", err)
	}
	if run.Status != db.RunCancelled || run.ErrorKind != db.ErrKindCancelled || run.Error != automations.BackgroundAIPausedMessage {
		t.Fatalf("run = %s/%s %q; want cancelled/cancelled %q", run.Status, run.ErrorKind, run.Error, automations.BackgroundAIPausedMessage)
	}
	if len(prim.origin) != 0 {
		t.Fatalf("primitive calls = %d; want 0", len(prim.origin))
	}
}

// An admitted ctx that is not the run's own claim (a daemon phase's, a
// slot's) does not pass the claim-time hold: the run is held while paused.
func TestExecutor_AdmittedCallerSyncRunStillHeld(t *testing.T) {
	daemonProcess(t)
	f, prim, a := newOwnerPrimitiveFixture(t, newConsent(true))
	id := f.enqueueReq(t, db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerSync})
	run, err := f.e.ExecuteBuiltinInline(aiconsent.WithAdmitted(context.Background(), "phase:tracks"), id)
	if err != nil {
		t.Fatalf("ExecuteBuiltinInline: %v", err)
	}
	if run.Status != db.RunCancelled || run.Error != automations.BackgroundAIPausedMessage || len(prim.origin) != 0 {
		t.Fatalf("run = %s %q, %d calls; want held", run.Status, run.Error, len(prim.origin))
	}
}

// flipShell is a shell() backend that pauses background AI when called.
type flipShell struct{ consent *consentSwitch }

func (s flipShell) Run(context.Context, automations.ShellCommand) (automations.ShellResult, error) {
	s.consent.paused.Store(true)
	return automations.ShellResult{Stdout: "ok\n"}, nil
}

// TestExecutor_AdmittedRunFinishesAfterPause (BGAI-01, D12): a background run
// claimed under consent keeps calling the model after the owner pauses.
func TestExecutor_AdmittedRunFinishesAfterPause(t *testing.T) {
	daemonProcess(t)
	consent := newConsent(false)
	gen := &consentGen{reader: consent.read}
	folder, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	f := newExFixture(t, exOpts{gen: gen, consent: consent.read, backends: func(_ *exFixture, b *automations.Backends) {
		b.Shell = flipShell{consent: consent}
		b.Workbench = folderWB(folder)
	}})
	wb, err := f.d.CreateWorkbench("acme", folder)
	if err != nil {
		t.Fatal(err)
	}
	text := "---\nname: Build and sum up\ntrigger:\n  manual: true\npermissions:\n  - shell:\"make\"\n  - llm:light\n" +
		"---\nBuilds, then sums up.\n\n```js\nshell(\"make\"); return llm(\"sum up\")\n```\n"
	writeWorkbenchRecipe(t, folder, "build", text)
	rescanWorkbench(t, f.ix, wb, folder)
	a := workbenchRow(t, f.d, wb, "build")
	if err := f.d.ConfirmAutomation(a.ID, a.ApprovalHash, exStart); err != nil {
		t.Fatal(err)
	}
	if err := f.d.SetAutomationEnabled(a.ID, true, exStart); err != nil {
		t.Fatal(err)
	}
	id := f.enqueue(t, a, db.TriggerSchedule)
	f.step(t, 1)
	f.wantRun(t, id, db.RunSucceeded, "")
	if !consent.paused.Load() {
		t.Fatal("the shell step did not pause background AI")
	}
	calls, denied := gen.snapshot()
	if len(calls) != 1 || denied != 0 || calls[0].origin != aiconsent.OriginBackground || !calls[0].admitted {
		t.Fatalf("model calls = %+v (denied %d); want one admitted background call", calls, denied)
	}
}
