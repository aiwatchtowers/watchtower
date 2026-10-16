package authoring

import (
	"context"
	"encoding/json"
	"errors"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/db"
	"watchtower/internal/digest"
	"watchtower/internal/tools"
)

var draftNow = time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC)

// guardTables are the tables a draft must never write (AGENT-06).
var guardTables = []string{
	"automations", "automation_runs", "automation_run_steps", "automation_state", "automation_outputs", "agent_actions",
}

type draftFixture struct {
	d       *db.DB
	gen     *automationstest.FakeGenerator
	reg     automations.ToolRegistry
	fakeReg *automationstest.FakeRegistry
	enabled bool
}

// newDraftFixture opens a temp file database with a fake generator replying
// "done" (10+5 tokens) and a fake registry with list_targets (read) and
// create_target (write).
func newDraftFixture(t *testing.T) *draftFixture {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "watchtower.db"))
	if err != nil {
		t.Fatalf("db.Open: %v", err)
	}
	t.Cleanup(func() { _ = d.Close() })
	reg := &automationstest.FakeRegistry{
		Tools: map[string]*tools.Tool{
			"list_targets":  {Name: "list_targets", Access: tools.AccessRead},
			"create_target": {Name: "create_target", Access: tools.AccessWrite},
		},
		ReadResults: map[string]any{"list_targets": []map[string]any{{"id": 7, "title": "Ship it"}}},
	}
	return &draftFixture{
		d:       d,
		gen:     &automationstest.FakeGenerator{Replies: []string{"done"}, Usage: []digest.Usage{{InputTokens: 10, OutputTokens: 5}}},
		reg:     reg,
		fakeReg: reg,
		enabled: true,
	}
}

func (f *draftFixture) tool() *tools.Tool {
	return NewDraftAutomation(Deps{
		DB:       f.d,
		Backends: func() automations.Backends { return automations.Backends{Generator: f.gen, Registry: f.reg} },
		Enabled:  func() bool { return f.enabled },
		Clock:    automationstest.NewFakeClock(draftNow),
	})
}

// call runs draft_automation and returns its result and its JSON.
func (f *draftFixture) call(t *testing.T, args map[string]any) (DraftResult, string) {
	t.Helper()
	out, err := f.callErr(args)
	if err != nil {
		t.Fatalf("draft_automation: %v", err)
	}
	raw, err := json.Marshal(out)
	if err != nil {
		t.Fatal(err)
	}
	var res DraftResult
	if err := json.Unmarshal(raw, &res); err != nil {
		t.Fatal(err)
	}
	return res, string(raw)
}

func (f *draftFixture) callErr(args map[string]any) (any, error) {
	raw, err := json.Marshal(args)
	if err != nil {
		return nil, err
	}
	return f.tool().Execute(context.Background(), f.d, tools.Call{Args: raw})
}

func (f *draftFixture) counts(t *testing.T) map[string]int {
	t.Helper()
	out := map[string]int{}
	for _, table := range guardTables {
		var n int
		if err := f.d.QueryRow(`SELECT COUNT(*) FROM ` + table).Scan(&n); err != nil {
			t.Fatal(err)
		}
		out[table] = n
	}
	return out
}

func (f *draftFixture) assertNoRowWritten(t *testing.T, before map[string]int) {
	t.Helper()
	for table, n := range f.counts(t) {
		if n != before[table] {
			t.Errorf("%s rows %d → %d; want unchanged", table, before[table], n)
		}
	}
}

// recipeText builds a manual recipe; extra is more frontmatter lines.
func recipeText(perms []string, extra, script string) string {
	var b strings.Builder
	b.WriteString("---\nname: Draft test\ntrigger:\n  manual: true\n")
	if len(perms) > 0 {
		b.WriteString("permissions:\n")
		for _, p := range perms {
			b.WriteString("  - " + p + "\n")
		}
	}
	b.WriteString(extra)
	b.WriteString("---\nA draft test recipe.\n\n```js\n" + script + "\n```\n")
	return b.String()
}

func stepStatuses(steps []DraftStep) string {
	parts := make([]string, len(steps))
	for i, s := range steps {
		parts[i] = s.Kind + ":" + s.Status
	}
	return strings.Join(parts, ",")
}

func TestDraftAutomation_WritesNothing(t *testing.T) {
	f := newDraftFixture(t)
	before := f.counts(t)
	text := recipeText([]string{"llm:light", "tool:list_targets", "tool:create_target"}, "outputs: [inbox]\n",
		`var s = llm("x"); tool("list_targets", {}); var w = tool("create_target", {text: "t"});
state.set("k", 1); output.inbox({title: "t", body: s}); log("done"); return w.status`)
	res, _ := f.call(t, map[string]any{"recipe_text": text})
	if !res.OK || res.DryRun == nil {
		t.Fatalf("result = %+v; want ok with a dry run", res)
	}
	if res.DryRun.Status != db.RunSucceeded {
		t.Fatalf("dry run status %s (%s); want succeeded", res.DryRun.Status, res.DryRun.Error)
	}
	if got := stepStatuses(res.DryRun.Steps); got != "llm:ok,tool:ok,tool:dry_run,state:dry_run,output:dry_run,log:ok" {
		t.Fatalf("steps = %s", got)
	}
	if n := len(f.fakeReg.ProposedCalls()); n != 0 {
		t.Fatalf("proposals = %d; want 0 (a dry-run write never proposes)", n)
	}
	if len(res.DryRun.Outputs) != 1 || res.DryRun.Outputs[0].Kind != "inbox" || res.DryRun.Tokens != 15 {
		t.Fatalf("dry run = %+v; want one would-be inbox output and 15 tokens", res.DryRun)
	}
	f.assertNoRowWritten(t, before)
}

func TestDraftAutomation_BoundsMinOfRecipeAnd50k5min(t *testing.T) {
	for _, tc := range []struct {
		recipe, want automations.Budget
	}{
		{automations.Budget{Tokens: 2000000, Minutes: 60}, automations.Budget{Tokens: 50000, Minutes: 5}},
		{automations.Budget{Tokens: 1000, Minutes: 1}, automations.Budget{Tokens: 1000, Minutes: 1}},
		{automations.Budget{Tokens: 50000, Minutes: 5}, automations.Budget{Tokens: 50000, Minutes: 5}},
	} {
		if got := draftBudget(tc.recipe); got != tc.want {
			t.Errorf("draftBudget(%+v) = %+v; want %+v", tc.recipe, got, tc.want)
		}
	}
	// End to end, the token bound reaches the dry run: 30000 tokens a call
	// under a 2M recipe budget stops after two calls (50000), under a 1000
	// one after one.
	for _, tc := range []struct {
		budget    string
		in, out   int
		wantCalls int
	}{
		{"budget:\n  tokens: 2000000\n  minutes: 60\n", 20000, 10000, 2},
		{"budget:\n  tokens: 1000\n  minutes: 1\n", 600, 600, 1},
	} {
		f := newDraftFixture(t)
		f.gen.Usage = []digest.Usage{{InputTokens: tc.in, OutputTokens: tc.out}}
		res, _ := f.call(t, map[string]any{"recipe_text": recipeText([]string{"llm:light"}, tc.budget, `llm("a"); llm("b"); llm("c"); return 1`)})
		if res.DryRun == nil || res.DryRun.Status != db.RunBudgetExceeded {
			t.Fatalf("%q: dry run = %+v; want budget_exceeded", tc.budget, res.DryRun)
		}
		if n := f.gen.CallCount(); n != tc.wantCalls {
			t.Fatalf("%q: generator calls = %d; want %d", tc.budget, n, tc.wantCalls)
		}
	}
}

func TestDraftAutomation_ParseErrorNoModelCall(t *testing.T) {
	f := newDraftFixture(t)
	text := recipeText([]string{"llm:light"}, "", `llm("a"); return 1`) + "\n```js\nreturn 2\n```\n"
	res, raw := f.call(t, map[string]any{"recipe_text": text})
	if res.OK || len(res.Errors) != 1 || !strings.Contains(res.Errors[0], "exactly one") {
		t.Fatalf("result = %+v; want ok:false naming \"exactly one\"", res)
	}
	if !strings.Contains(raw, `"dry_run":null`) {
		t.Fatalf("JSON %s; want dry_run null", raw)
	}
	if n := f.gen.CallCount(); n != 0 {
		t.Fatalf("generator calls = %d; want 0", n)
	}
}

func TestDraftAutomation_WideningAgainstSaved(t *testing.T) {
	f := newDraftFixture(t)
	automationstest.SeedAutomation(t, f.d, recipeText([]string{"jira:read@PAY"}, "", `return 1`), automationstest.SeedOptions{Slug: "jira-digest", Now: draftNow})
	widenTo := func(slug string, perms ...string) []string {
		args := map[string]any{"recipe_text": recipeText(perms, "", `return 1`)}
		if slug != "" {
			args["slug"] = slug
		}
		res, _ := f.call(t, args)
		if !res.OK {
			t.Fatalf("draft %v: %v", perms, res.Errors)
		}
		return res.Widening
	}
	if got := widenTo("jira-digest", "jira:read@*"); !slices.Equal(got, []string{"jira:read@*"}) {
		t.Errorf("widening to @* = %v; want [jira:read@*]", got)
	}
	if got := widenTo("jira-digest", "jira:read@PAY"); len(got) != 0 {
		t.Errorf("same permission = %v; want []", got)
	}
	if got := widenTo("", "jira:read@PAY", "llm:light"); !slices.Equal(got, []string{"jira:read@PAY", "llm:light"}) {
		t.Errorf("no slug = %v; want every permission", got)
	}
	if got := widenTo("never-saved", "llm:light"); !slices.Equal(got, []string{"llm:light"}) {
		t.Errorf("unknown slug = %v; want every permission", got)
	}
}

func TestDraftAutomation_EmptyArraysNotNull(t *testing.T) {
	f := newDraftFixture(t)
	res, raw := f.call(t, map[string]any{"recipe_text": recipeText(nil, "", `return 1`)})
	if !res.OK {
		t.Fatalf("errors = %v", res.Errors)
	}
	for _, want := range []string{`"errors":[]`, `"widening":[]`, `"permissions":[]`, `"outputs":[]`, `"steps":[]`} {
		if !strings.Contains(raw, want) {
			t.Errorf("JSON %s; want %s", raw, want)
		}
	}
	// A parse error keeps the arrays too.
	_, raw = f.call(t, map[string]any{"recipe_text": "not a recipe"})
	for _, want := range []string{`"widening":[]`, `"permissions":[]`, `"outputs":[]`} {
		if !strings.Contains(raw, want) {
			t.Errorf("parse-error JSON %s; want %s", raw, want)
		}
	}
}

func TestDraftAutomation_ApprovalHashMatchesParser(t *testing.T) {
	f := newDraftFixture(t)
	text := recipeText([]string{"llm:light", "tool:list_targets"}, "budget:\n  tokens: 9000\n", `return 1`)
	for _, wb := range []int64{0, 4} {
		args := map[string]any{"recipe_text": text, "slug": "digest"}
		scope := automations.Scope{Kind: automations.ScopePersonal}
		if wb > 0 {
			args["workbench_id"] = wb
			scope = automations.Scope{Kind: automations.ScopeWorkbench, WorkbenchID: wb}
		}
		res, _ := f.call(t, args)
		parsed, err := automations.ParseRecipe("digest", []byte(text), scope)
		if err != nil {
			t.Fatal(err)
		}
		if want := automations.ApprovalHash(parsed); res.Manifest.ApprovalHash != want {
			t.Errorf("workbench %d: approval_hash = %s; want %s", wb, res.Manifest.ApprovalHash, want)
		}
		if res.Manifest.Scope != scope.String() || res.Manifest.BudgetTokens != 9000 || res.Manifest.BudgetMinutes != 5 {
			t.Errorf("workbench %d: manifest = %+v", wb, res.Manifest)
		}
	}
}

func TestDraftAutomation_FeatureOffRefused(t *testing.T) {
	f := newDraftFixture(t)
	f.enabled = false
	_, err := f.callErr(map[string]any{"recipe_text": recipeText(nil, "", `return 1`)})
	var ve *tools.ValidationError
	if !errors.As(err, &ve) || ve.Msg != "Automations are turned off in Settings → Features" {
		t.Fatalf("err = %v; want the feature-off ValidationError", err)
	}
	if n := f.gen.CallCount(); n != 0 {
		t.Fatalf("generator calls = %d; want 0", n)
	}
}

// TestDraftAutomation_RefusesDryRunOfUnconfirmedRecipe pins ask #271 (spec
// §20.1 D16, AUTO-06): a draft equal to an indexed unconfirmed recipe is
// validated but not dry-run.
func TestDraftAutomation_RefusesDryRunOfUnconfirmedRecipe(t *testing.T) {
	f := newDraftFixture(t)
	script := "var s = llm(\"x\");\ntool(\"list_targets\", {});\nreturn s"
	text := recipeText([]string{"llm:light", "tool:list_targets"}, "", script)
	a := automationstest.SeedAutomation(t, f.d, text, automationstest.SeedOptions{Slug: "digest", Now: draftNow, Unconfirmed: true})

	before := f.counts(t)
	res, _ := f.call(t, map[string]any{"recipe_text": text})
	if !res.OK || res.DryRun == nil || res.DryRun.Status != "refused" || len(res.DryRun.Steps) != 0 ||
		res.DryRun.Error != "This recipe is not confirmed yet; only you can dry-run it, from its card in Automations" {
		t.Fatalf("result = %+v (dry run %+v); want ok with a refused dry run", res, res.DryRun)
	}
	if g, r := f.gen.CallCount(), len(f.fakeReg.ReadCalls())+len(f.fakeReg.ProposedCalls()); g != 0 || r != 0 {
		t.Fatalf("generator calls %d, registry calls %d; want 0 and 0", g, r)
	}
	f.assertNoRowWritten(t, before)

	// One changed script line: the chat's own text, dry-run.
	edited := recipeText([]string{"llm:light", "tool:list_targets"}, "", strings.Replace(script, `"x"`, `"y"`, 1))
	if res, _ := f.call(t, map[string]any{"recipe_text": edited}); res.DryRun == nil || res.DryRun.Status != db.RunSucceeded {
		t.Fatalf("edited draft dry run = %+v; want succeeded", res.DryRun)
	}

	// Once the owner confirmed it, the same text dry-runs.
	if err := f.d.ConfirmAutomation(a.ID, a.ApprovalHash, draftNow); err != nil {
		t.Fatal(err)
	}
	if res, _ := f.call(t, map[string]any{"recipe_text": text}); res.DryRun == nil || res.DryRun.Status != db.RunSucceeded {
		t.Fatalf("confirmed recipe dry run = %+v; want succeeded", res.DryRun)
	}
}

func TestDraftAutomation_RemovedUnconfirmedRecipeDoesNotBlock(t *testing.T) {
	f := newDraftFixture(t)
	text := recipeText([]string{"llm:light"}, "", `return llm("x")`)
	automationstest.SeedAutomation(t, f.d, text, automationstest.SeedOptions{Slug: "digest", Now: draftNow, Unconfirmed: true})
	if _, err := f.d.MarkAutomationsRemovedExcept(string(automations.ScopePersonal), 0, nil, draftNow); err != nil {
		t.Fatal(err)
	}
	if res, _ := f.call(t, map[string]any{"recipe_text": text}); res.DryRun == nil || res.DryRun.Status != db.RunSucceeded {
		t.Fatalf("dry run = %+v; want succeeded (a removed recipe does not block)", res.DryRun)
	}
}

// TestDraftAutomation_EmailStepsReachTheChatClipped pins ask #272 (spec
// §20.1 D18): a draft's list_emails/get_email steps come back to the chat
// model, each result clipped by the journal.
func TestDraftAutomation_EmailStepsReachTheChatClipped(t *testing.T) {
	f := newDraftFixture(t)
	gid, err := f.d.CreateGoogleAccount(db.GoogleAccount{Email: "owner@example.com", Label: "work", GmailEnabled: true})
	if err != nil {
		t.Fatal(err)
	}
	at := draftNow.Add(-time.Hour).Format(time.RFC3339)
	if err := f.d.UpsertGmailMessage(gid, db.GmailMessage{
		ID: "m1", ThreadID: "t-m1", FromEmail: "colleague@example.com", FromName: "Colleague A",
		ToJSON: `["owner@example.com"]`, CcJSON: `[]`, Subject: "quarterly numbers", Snippet: "see inside",
		BodyText: strings.Repeat("a", 40*1024), InternalDate: at, LabelsJSON: `["INBOX"]`, IsUnread: true,
		Permalink: "https://mail.example.com/m1", SyncedAt: at,
	}); err != nil {
		t.Fatal(err)
	}
	reg := tools.New(f.d)
	for _, tl := range []*tools.Tool{tools.NewListEmails(), tools.NewGetEmail()} {
		if err := reg.Register(tl); err != nil {
			t.Fatal(err)
		}
	}
	f.reg = reg
	before := f.counts(t)
	res, _ := f.call(t, map[string]any{"recipe_text": recipeText([]string{"gmail:read@work"}, "",
		`var l = tool("list_emails", {account: "work"});
var m = tool("get_email", {account: "work", id: l.messages[0].id});
return m.subject`)})
	if res.DryRun == nil || res.DryRun.Status != db.RunSucceeded {
		t.Fatalf("dry run = %+v; want succeeded", res.DryRun)
	}
	if got := stepStatuses(res.DryRun.Steps); got != "tool:ok,tool:ok" {
		t.Fatalf("steps = %s", got)
	}
	get := res.DryRun.Steps[1]
	if get.Name != "get_email" || len(get.Result) > automations.StepClipBytes {
		t.Fatalf("get_email step = %s, result %d bytes; want ≤ %d", get.Name, len(get.Result), automations.StepClipBytes)
	}
	if !strings.HasPrefix(get.Result, `{"account":"work","id":"m1"`) || !strings.Contains(get.Result, "quarterly numbers") {
		t.Fatalf("get_email result starts %.120q; want the message's fields", get.Result)
	}
	f.assertNoRowWritten(t, before)
}

func TestDraftAutomation_NotInReadTools(t *testing.T) {
	for _, rt := range tools.ReadTools() {
		if rt.Name == "draft_automation" {
			t.Fatal("draft_automation is in tools.ReadTools()")
		}
	}
	tl := NewDraftAutomation(Deps{})
	if tl.Access != tools.AccessRead {
		t.Fatalf("access = %s; want read", tl.Access)
	}
	for surface, want := range map[string]bool{"main": true, "automation_editor": true, "automation": false} {
		if got := tl.VisibleOn(surface); got != want {
			t.Errorf("VisibleOn(%q) = %v; want %v", surface, got, want)
		}
	}
}
