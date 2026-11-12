package automations_test

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"

	"watchtower/internal/automations"
	"watchtower/internal/db"
)

const slackWindowKey = automations.WindowStateKeyPrefix + "slack"

// windowFake is a slack.window primitive that records its calls and answers
// through next (the call → its result).
type windowFake struct {
	mu    sync.Mutex
	calls []automations.PrimitiveCall
	next  func(c automations.PrimitiveCall) automations.PrimitiveResult
}

func (w *windowFake) fn(_ context.Context, c automations.PrimitiveCall) (automations.PrimitiveResult, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.calls = append(w.calls, c)
	return w.next(c), nil
}

func (w *windowFake) call(t *testing.T, i int) automations.PrimitiveCall {
	t.Helper()
	w.mu.Lock()
	defer w.mu.Unlock()
	if i >= len(w.calls) {
		t.Fatalf("call %d of %d", i, len(w.calls))
	}
	return w.calls[i]
}

// windowAt answers every call with NextCursor next, Behind behind.
func windowAt(next int64, behind bool) func(automations.PrimitiveCall) automations.PrimitiveResult {
	return func(automations.PrimitiveCall) automations.PrimitiveResult {
		return automations.PrimitiveResult{Status: "done", NextCursor: next, Behind: behind}
	}
}

func windowFixture(t *testing.T, w *windowFake) *exFixture {
	t.Helper()
	return newExFixture(t, exOpts{backends: func(_ *exFixture, b *automations.Backends) {
		b.Primitives = map[string]automations.PrimitiveFunc{automations.PrimitiveSlackWindow: w.fn}
	}})
}

func (f *exFixture) seedWindow(t *testing.T, script string) db.Automation {
	t.Helper()
	return f.seedBuiltin(t, builtinRecipeText(script, "", "builtin:"+automations.PrimitiveSlackWindow), true)
}

// windowCursor reads the committed slack cursor of a.
func (f *exFixture) windowCursor(t *testing.T, a db.Automation) (int64, bool) {
	t.Helper()
	state, err := f.d.GetAutomationState(a.ID)
	if err != nil {
		t.Fatal(err)
	}
	after, behind, err := automations.WindowCursorOf(state, slackWindowKey)
	if err != nil {
		t.Fatalf("WindowCursorOf(%s): %v", state, err)
	}
	return after, behind
}

// TestAuto04_RawWindowCursorOnlyOnSuccess: the cursor a window call stages
// is committed with a succeeded run only; a run that fails after the call
// leaves it, so the next run reads from the previous cursor again.
func TestAuto04_RawWindowCursorOnlyOnSuccess(t *testing.T) {
	w := &windowFake{next: windowAt(42, true)}
	f := windowFixture(t, w)
	a := f.seedWindow(t, `const r = slack.window(); if (r.fail) { throw new Error("boom"); } return r.status;`)
	if r := f.runBuiltin(t, a, db.TriggerSync, ""); r.Status != db.RunSucceeded {
		t.Fatalf("run 1 = %s (%s)", r.Status, r.Error)
	}
	state, err := f.d.GetAutomationState(a.ID)
	if err != nil || string(state) != `{"__window:slack":{"v":1,"after_rowid":42,"behind":true}}` {
		t.Fatalf("state = %s, %v", state, err)
	}

	w.next = func(automations.PrimitiveCall) automations.PrimitiveResult {
		return automations.PrimitiveResult{Status: "done", NextCursor: 99, Fields: map[string]any{"fail": true}}
	}
	if r := f.runBuiltin(t, a, db.TriggerSync, ""); r.Status != db.RunFailed {
		t.Fatalf("run 2 = %s (%s); want failed", r.Status, r.Error)
	}
	if after, behind := f.windowCursor(t, a); after != 42 || !behind {
		t.Errorf("after a failed run: cursor %d behind %v; want 42 true", after, behind)
	}

	w.next = windowAt(43, false)
	if r := f.runBuiltin(t, a, db.TriggerSync, ""); r.Status != db.RunSucceeded {
		t.Fatalf("run 3 = %s (%s)", r.Status, r.Error)
	}
	if c := w.call(t, 2); c.Cursor != 42 {
		t.Errorf("run 3 Cursor = %d; want 42", c.Cursor)
	}
	if after, behind := f.windowCursor(t, a); after != 43 || behind {
		t.Errorf("after run 3: cursor %d behind %v; want 43 false", after, behind)
	}
}

func TestWindowCursorOf(t *testing.T) {
	for _, state := range []string{"", "{}", "null", `{"other":1}`} {
		after, behind, err := automations.WindowCursorOf(json.RawMessage(state), slackWindowKey)
		if after != 0 || behind || err != nil {
			t.Errorf("%q: %d %v %v; want 0 false nil", state, after, behind, err)
		}
	}
	after, behind, err := automations.WindowCursorOf(json.RawMessage(`{"__window:slack":{"v":1,"after_rowid":9,"behind":true}}`), slackWindowKey)
	if after != 9 || !behind || err != nil {
		t.Errorf("v1: %d %v %v; want 9 true nil", after, behind, err)
	}
	for _, state := range []string{
		`{"__window:slack":{"v":2,"after_rowid":9}}`,
		`{"__window:slack":{"after_rowid":9}}`,
		`{"__window:slack":"x"}`,
		`{"__window:slack":{"v":1,"after_rowid":-1}}`,
		`{"__window:slack":`,
		`[1]`,
	} {
		if _, _, err := automations.WindowCursorOf(json.RawMessage(state), slackWindowKey); err == nil {
			t.Errorf("%s: want an error", state)
		}
	}
}

// slack.window passes the run's buffered cursor and the floor.
func TestSlackWindowCall_PassesCursorAndFloor(t *testing.T) {
	w := &windowFake{next: windowAt(7, false)}
	f := windowFixture(t, w)
	a := f.seedWindow(t, `slack.window(); slack.window({}); return slack.window({floor: "today"}).status;`)
	if r := f.runBuiltin(t, a, db.TriggerSync, ""); r.Status != db.RunSucceeded || r.Summary != "done" {
		t.Fatalf("run 1 = %s %q (%s)", r.Status, r.Summary, r.Error)
	}
	for i, want := range []string{"", "", "today"} {
		if c := w.call(t, i); c.Floor != want || c.Name != automations.PrimitiveSlackWindow || c.BuiltinID != testBuiltinID {
			t.Errorf("call %d = %+v; want Floor %q", i, c, want)
		}
	}
	if c := w.call(t, 0); c.Cursor != 0 {
		t.Errorf("first call Cursor = %d; want 0 (no cursor yet)", c.Cursor)
	}
	if r := f.runBuiltin(t, a, db.TriggerSync, ""); r.Status != db.RunSucceeded {
		t.Fatalf("run 2 = %s (%s)", r.Status, r.Error)
	}
	if c := w.call(t, 3); c.Cursor != 7 || c.Floor != "" {
		t.Errorf("run 2's first call = %+v; want Cursor 7", c)
	}
}

// A second call in one run reads past the first call's cursor.
func TestSlackWindowCall_SecondCallReadsPastFirst(t *testing.T) {
	w := &windowFake{next: func(c automations.PrimitiveCall) automations.PrimitiveResult {
		return automations.PrimitiveResult{Status: "done", NextCursor: c.Cursor + 10}
	}}
	f := windowFixture(t, w)
	a := f.seedWindow(t, `slack.window(); return slack.window().status;`)
	if r := f.runBuiltin(t, a, db.TriggerSync, ""); r.Status != db.RunSucceeded {
		t.Fatalf("run = %s (%s)", r.Status, r.Error)
	}
	if c := w.call(t, 1); c.Cursor != 10 {
		t.Errorf("second call Cursor = %d; want 10", c.Cursor)
	}
	if after, _ := f.windowCursor(t, a); after != 20 {
		t.Errorf("committed cursor = %d; want 20", after)
	}
}

func TestSlackWindowCall_BadArgument(t *testing.T) {
	w := &windowFake{next: windowAt(1, false)}
	f := windowFixture(t, w)
	a := f.seedWindow(t, `const out = [];
for (const arg of [{floor: "week"}, {x: 1}, "a", {floor: "today", x: 1}, null]) {
  try { slack.window(arg); out.push("ok"); } catch (e) { out.push(e.name + ": " + e.message); }
}
return out.join("|");`)
	r := f.runBuiltin(t, a, db.TriggerSync, "")
	v := automations.ErrNameValidation + ": "
	want := strings.Join([]string{
		v + `slack.window({floor}): floor must be "today"`,
		v + "slack.window() takes only {floor}",
		v + "slack.window() takes only {floor}",
		v + "slack.window() takes only {floor}",
		"ok",
	}, "|")
	if r.Status != db.RunSucceeded || r.Summary != want {
		t.Fatalf("run = %s %q (%s);\nwant %q", r.Status, r.Summary, r.Error, want)
	}
	if len(w.calls) != 1 {
		t.Errorf("calls = %d; want only the null argument's", len(w.calls))
	}
}

// slack.window is one tool step under builtin:slack.window, outside the
// meter: what the primitive reports is never debited.
func TestSlackWindowCall_ToolStepOutsideMeter(t *testing.T) {
	w := &windowFake{next: func(automations.PrimitiveCall) automations.PrimitiveResult {
		return automations.PrimitiveResult{Status: "done", NextCursor: 3, Fields: map[string]any{"count": 2},
			Usage: automations.PrimitiveUsage{InputTokens: 100, OutputTokens: 20}}
	}}
	f := windowFixture(t, w)
	a := f.seedWindow(t, `const r = slack.window(); return r.status + ":" + r.count;`)
	r := f.runBuiltin(t, a, db.TriggerSync, "")
	if r.Status != db.RunSucceeded || r.Summary != "done:2" {
		t.Fatalf("run = %s %q (%s)", r.Status, r.Summary, r.Error)
	}
	steps := f.steps(t, r.ID)
	if len(steps) != 1 {
		t.Fatalf("steps = %+v; want one", steps)
	}
	if s := steps[0]; s.Kind != automations.StepKindTool || s.Name != automations.PrimitiveSlackWindow ||
		s.Permission != "builtin:slack.window" || s.InputTokens != 0 || s.OutputTokens != 0 {
		t.Errorf("step = %+v", s)
	}
	if r.InputTokens != 0 || r.OutputTokens != 0 {
		t.Errorf("run usage = %d/%d; want none", r.InputTokens, r.OutputTokens)
	}
}

// A dry run reads the window from the committed cursor but never commits
// the cursor it stages.
func TestSlackWindowCall_DryRunReadsButNeverCommits(t *testing.T) {
	w := &windowFake{next: windowAt(7, false)}
	f := windowFixture(t, w)
	a := f.seedWindow(t, `return slack.window().status;`)
	if r := f.runBuiltin(t, a, db.TriggerSync, ""); r.Status != db.RunSucceeded {
		t.Fatalf("run = %s (%s)", r.Status, r.Error)
	}
	w.next = windowAt(50, true)
	id := f.enqueueReq(t, db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerDryRun})
	dry, err := f.e.ExecuteInline(context.Background(), id)
	if err != nil {
		t.Fatal(err)
	}
	if dry.Status != db.RunSucceeded || dry.Summary != "done" {
		t.Fatalf("dry run = %s %q (%s)", dry.Status, dry.Summary, dry.Error)
	}
	if c := w.call(t, 1); c.Cursor != 7 {
		t.Errorf("dry run Cursor = %d; want 7", c.Cursor)
	}
	if after, behind := f.windowCursor(t, a); after != 7 || behind {
		t.Errorf("after the dry run: cursor %d behind %v; want 7 false", after, behind)
	}
}

// A primitive error or a status other than done/skipped fails the run as
// PrimitiveFailed and stages no cursor.
func TestSlackWindowCall_FailureStagesNoCursor(t *testing.T) {
	w := &windowFake{next: func(automations.PrimitiveCall) automations.PrimitiveResult {
		return automations.PrimitiveResult{Status: "maybe", NextCursor: 5}
	}}
	f := windowFixture(t, w)
	a := f.seedWindow(t, `try { slack.window(); } catch (e) { return e.name + ":" + JSON.stringify(state.all()); }`)
	r := f.runBuiltin(t, a, db.TriggerSync, "")
	if r.Status != db.RunSucceeded || r.Summary != automations.ErrNamePrimitiveFailed+":{}" {
		t.Errorf("run = %s %q (%s)", r.Status, r.Summary, r.Error)
	}
}

func TestStateSet_ReservedWindowKeyRefused(t *testing.T) {
	f := newExFixture(t, exOpts{})
	a := f.seed(t, "plain", `try { state.set("__window:slack", {v: 1, after_rowid: 1}); return "set"; } catch (e) { return e.name + ": " + e.message; }`, false)
	id := f.enqueue(t, a, db.TriggerManual)
	f.step(t, 1)
	want := automations.ErrNameValidation + `: state.set("__window:slack"): keys starting with "__window:" belong to the raw window`
	if r := f.wantRun(t, id, db.RunSucceeded, ""); r.Summary != want {
		t.Errorf("summary = %q; want %q", r.Summary, want)
	}
	if state, err := f.d.GetAutomationState(a.ID); err != nil || len(state) != 0 && string(state) != "{}" {
		t.Errorf("state = %s, %v; want nothing set", state, err)
	}
}
