package automations_test

import (
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"testing"

	"watchtower/internal/automations"
	"watchtower/internal/db"
)

// Inbox card fields of output.inbox: link and actions (spec B2).

func cardCase() sdkCase {
	return sdkCase{perms: []string{"inbox:reply"}, outputs: []string{"inbox"}}
}

// cardCall wraps an output.inbox argument in a script that returns "ok" or
// the error's name and message.
func cardCall(arg string) string {
	return `try { output.inbox(` + arg + `); return "ok" } catch (e) { return e.name + ": " + e.message }`
}

// wantCardError runs output.inbox(arg) and wants a ValidationError whose
// message contains each of want, with nothing buffered.
func wantCardError(t *testing.T, arg string, want ...string) {
	t.Helper()
	r := runSDK(t, cardCall(arg), cardCase())
	if r.err != nil {
		t.Fatalf("Run: %v", r.err)
	}
	got := fmt.Sprint(r.out)
	if !strings.HasPrefix(got, "ValidationError: ") {
		t.Fatalf("output.inbox(%.120s) = %q; want a ValidationError", arg, got)
	}
	for _, w := range want {
		if !strings.Contains(got, w) {
			t.Fatalf("output.inbox(%.120s) = %q; want it to name %q", arg, got, w)
		}
	}
	if n := len(r.env.Buffer.Outputs()); n != 0 {
		t.Fatalf("buffered %d outputs; want none", n)
	}
}

const fourActions = `[{label: "Open", open: "watchtower-nav://automations"}, {label: "Ask", chat: "Draft replies"},
	{label: "Fix", agent: {task: "Fix it", workbench: 3}}, {label: "Backlog", reply: "backlog", data: {id: "A-1"}}]`

func TestOutput_InboxCardRoundTrip(t *testing.T) {
	r := mustReturn(t, cardCall(`{title: "t", body: "b", link: "https://example.com/x", actions: `+fourActions+`}`), cardCase(), "ok")
	outs := r.env.Buffer.Outputs()
	if len(outs) != 1 {
		t.Fatalf("buffered %d outputs; want 1", len(outs))
	}
	o := outs[0]
	if o.Link != "https://example.com/x" || len(o.Actions) != 4 {
		t.Fatalf("link = %q, actions = %+v", o.Link, o.Actions)
	}
	var kinds []string
	var primary []bool
	for _, a := range o.Actions {
		kinds = append(kinds, a.Kind)
		primary = append(primary, a.Primary)
	}
	if fmt.Sprint(kinds) != "[link chat agent reply]" || !slices.Equal(primary, []bool{true, false, false, false}) {
		t.Fatalf("kinds = %v, primary = %v", kinds, primary)
	}
	a := o.Actions
	if a[0].Open != "watchtower-nav://automations" || a[1].Chat != "Draft replies" ||
		a[2].Agent == nil || a[2].Agent.Task != "Fix it" || string(a[2].Agent.Workbench) != "3" ||
		a[3].Reply != "backlog" || string(a[3].Data) != `{"id":"A-1"}` || a[0].Label != "Open" {
		t.Fatalf("actions = %+v", a)
	}
	// The stored form is what the db layer writes (actions_json).
	if b, err := json.Marshal(a[3]); err != nil || !strings.Contains(string(b), `"data":{"id":"A-1"}`) {
		t.Fatalf("reply action JSON = %s, %v", b, err)
	}
	// A workbench by name is kept as a string.
	r = mustReturn(t, cardCall(`{title: "t", body: "b", actions: [{label: "Fix", agent: {task: "x", workbench: "acme"}}]}`), cardCase(), "ok")
	if got := string(r.env.Buffer.Outputs()[0].Actions[0].Agent.Workbench); got != `"acme"` {
		t.Fatalf("workbench = %s; want \"acme\"", got)
	}
	// No card fields: no link and an empty action list.
	r = mustReturn(t, cardCall(`{title: "t", body: "b"}`), cardCase(), "ok")
	if o := r.env.Buffer.Outputs()[0]; o.Link != "" || len(o.Actions) != 0 {
		t.Fatalf("plain card = %+v", o)
	}
}

func TestOutput_FirstActionPrimaryFalse(t *testing.T) {
	arg := strings.Replace(fourActions, `{label: "Open",`, `{label: "Open", primary: false,`, 1)
	r := mustReturn(t, cardCall(`{title: "t", body: "b", actions: `+arg+`}`), cardCase(), "ok")
	for i, a := range r.env.Buffer.Outputs()[0].Actions {
		if a.Primary {
			t.Fatalf("action %d is primary; want none", i)
		}
	}
	arg = strings.Replace(fourActions, `{label: "Fix",`, `{label: "Fix", primary: true,`, 1)
	wantCardError(t, `{title: "t", body: "b", actions: `+arg+`}`, "primary may only be set to false on the first action")
}

func TestOutput_CardLinkSchemes(t *testing.T) {
	for _, ok := range []string{"HTTPS://example.com", "WATCHTOWER-NAV://home", "http://example.com/a?b=1"} {
		mustReturn(t, cardCall(`{title: "t", body: "b", link: "`+ok+`", actions: [{label: "Go", open: "`+ok+`"}]}`), cardCase(), "ok")
	}
	long := "https://example.com/" + strings.Repeat("a", automations.MaxInboxLinkBytes-len("https://example.com/")+1)
	for _, bad := range []string{"file:///etc", "smb://x", "javascript:alert(1)", "mailto:a@example.com", "slack://x", "https://", "", long} {
		t.Run(bad[:min(len(bad), 30)], func(t *testing.T) {
			wantCardError(t, `{title: "t", body: "b", link: "`+bad+`"}`, "link")
			wantCardError(t, `{title: "t", body: "b", actions: [{label: "Go", chat: "x"}, {label: "Go", open: "`+bad+`"}]}`, "actions[1].open")
		})
	}
	wantCardError(t, `{title: "t", body: "b", link: 7}`, "link")
}

func TestOutput_CardActionLimits(t *testing.T) {
	five := `[{label: "a", chat: "x"}, {label: "b", chat: "x"}, {label: "c", chat: "x"}, {label: "d", chat: "x"}, {label: "e", chat: "x"}]`
	cases := map[string]string{
		"5 actions":            five,
		"41-char label":        `[{label: "x".repeat(41), chat: "x"}]`,
		"empty label":          `[{label: "", chat: "x"}]`,
		"no label":             `[{chat: "x"}]`,
		"blank label":          `[{label: " \n\t", chat: "x"}]`,
		"blank reply":          `[{label: "a", reply: "  "}]`,
		"4097-byte chat":       `[{label: "a", chat: "x".repeat(4097)}]`,
		"empty task":           `[{label: "a", agent: {task: ""}}]`,
		"4097-byte task":       `[{label: "a", agent: {task: "x".repeat(4097)}}]`,
		"8193-byte data":       `[{label: "a", reply: "v", data: {k: "x".repeat(8193 - 8)}}]`,
		"101-char reply":       `[{label: "a", reply: "x".repeat(101)}]`,
		"empty workbench":      `[{label: "a", agent: {task: "x", workbench: ""}}]`,
		"-1 workbench":         `[{label: "a", agent: {task: "x", workbench: -1}}]`,
		"bool workbench":       `[{label: "a", agent: {task: "x", workbench: true}}]`,
		"actions object":       `{label: "a", chat: "x"}`,
		"action not an object": `["a"]`,
	}
	for name, actions := range cases {
		t.Run(name, func(t *testing.T) {
			wantCardError(t, `{title: "t", body: "b", actions: `+actions+`}`)
		})
	}
	// The boundaries themselves are accepted.
	mustReturn(t, cardCall(`{title: "t", body: "b", actions: [{label: "é".repeat(40), chat: "x".repeat(4096)},
		{label: "a", agent: {task: "x".repeat(4096)}}, {label: "a", reply: "é".repeat(100), data: {k: "x".repeat(8192 - 8)}}]}`),
		cardCase(), "ok")
}

func TestOutput_CardActionShape(t *testing.T) {
	for name, action := range map[string]string{
		"two kinds":          `{label: "a", chat: "x", open: "https://example.com"}`,
		"no kind":            `{label: "a"}`,
		"unknown key":        `{label: "a", chat: "x", color: "red"}`,
		"data on chat":       `{label: "a", chat: "x", data: {id: 1}}`,
		"agent unknown key":  `{label: "a", agent: {task: "x", repo: "y"}}`,
		"agent not object":   `{label: "a", agent: "x"}`,
		"data not object":    `{label: "a", reply: "v", data: [1]}`,
		"primary not a bool": `{label: "a", chat: "x", primary: "no"}`,
	} {
		t.Run(name, func(t *testing.T) {
			wantCardError(t, `{title: "t", body: "b", actions: [`+action+`]}`, "actions[0]")
		})
	}
}

func TestOutput_ReplyActionNeedsInboxReply(t *testing.T) {
	r := mustReturn(t, `try { output.inbox({title: "t", body: "b", actions: `+fourActions+`}); return "ok" }
		catch (e) { return e.name + "|" + e.needed }`,
		sdkCase{outputs: []string{"inbox"}}, "PermissionDenied|inbox:reply")
	if n := len(r.env.Buffer.Outputs()); n != 0 {
		t.Fatalf("buffered %d outputs; want none", n)
	}
	if steps := r.env.Journal.Steps(); len(steps) != 1 || steps[0].Status != automations.StepDenied {
		t.Fatalf("steps = %v; want one denied step", stepStatuses(steps))
	}
	// Without a reply action the card needs no inbox:reply.
	mustReturn(t, cardCall(`{title: "t", body: "b", actions: [{label: "Ask", chat: "x"}]}`), sdkCase{outputs: []string{"inbox"}}, "ok")
}

func TestOutput_ReportRefusesCardFields(t *testing.T) {
	for _, kind := range []string{"report", "briefing"} {
		for _, field := range []string{`link: "https://example.com"`, `actions: []`} {
			got := mustReturnAny(t, `try { output.`+kind+`({title: "t", body: "b", `+field+`}); return "ok" }
				catch (e) { return e.name + ": " + e.message }`, sdkCase{outputs: []string{kind}})
			name := field[:strings.Index(field, ":")]
			if !strings.Contains(got, "ValidationError") || !strings.Contains(got, `unknown field "`+name+`"`) {
				t.Fatalf("output.%s with %s = %q; want unknown field %q", kind, name, got, name)
			}
		}
	}
}

// mustReturnAny runs script and returns its result as a string.
func mustReturnAny(t *testing.T, script string, c sdkCase) string {
	t.Helper()
	r := runSDK(t, script, c)
	if r.err != nil {
		t.Fatalf("Run: %v", r.err)
	}
	return fmt.Sprint(r.out)
}

// TestAuto08_ResumeRebuildsInboxCard: a resumed run's replay re-buffers an
// inbox card with its link and actions (CallBuffered, AUTO-04), so the
// committed row carries them.
func TestAuto08_ResumeRebuildsInboxCard(t *testing.T) {
	w := newWriteFixture(t)
	a := w.seedWorkbenchOutput(t, "deploy", []string{"ask:owner", "inbox:reply"}, "inbox",
		`output.inbox({title: "filed", body: "b", link: "https://example.com/x", actions: `+fourActions+`});
		const r = `+resumeAskCall+`; return 1`)
	id := w.enqueue(t, a, db.TriggerManual)
	w.stopWhileWaiting(t, id)
	ask := w.onlyAsk(t, a.ProjectID)

	w.restart()
	stop := runExecutor(t, w.exFixture)
	defer stop()
	w.waitStatus(t, id, db.RunWaiting)
	w.answerAsk(t, ask.ID)
	w.e.Wake()
	if r := w.waitEnded(t, id); r.Status != db.RunSucceeded {
		t.Fatalf("run = %s/%s (%s); want succeeded", r.Status, r.ErrorKind, r.Error)
	}
	outs, err := w.d.ListAutomationOutputs("inbox", 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(outs) != 1 || outs[0].Link != "https://example.com/x" || len(outs[0].Actions) != 4 ||
		outs[0].Actions[3].Kind != db.InboxActionReply || string(outs[0].Actions[3].Data) != `{"id":"A-1"}` ||
		!outs[0].Actions[0].Primary {
		t.Fatalf("committed outputs = %+v; want the one card with its link and four actions", outs)
	}
}
