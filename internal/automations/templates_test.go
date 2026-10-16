package automations_test

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"watchtower/internal/automations"
	"watchtower/internal/db"
)

// wantTemplateRecipe is one gallery recipe's frontmatter as spec §15 pins it.
type wantTemplateRecipe struct {
	trigger     automations.Trigger
	permissions []string
	outputs     []string
}

func buttonTrigger(label string) automations.Trigger {
	return automations.Trigger{Kind: automations.TriggerButton, Button: &automations.ButtonTrigger{Label: label, Confirm: true}}
}

func scheduleTrigger(expr string) automations.Trigger {
	return automations.Trigger{Kind: automations.TriggerSchedule, Schedule: expr}
}

type specTemplate struct {
	name    string
	scope   automations.ScopeKind
	files   []string
	recipes map[string]wantTemplateRecipe
}

// specTemplates is spec §15, in gallery order: template name → scope and its
// recipes (slug → frontmatter).
var specTemplates = []specTemplate{
	{"new-mail-summary", automations.ScopePersonal, []string{"new-mail-summary"}, map[string]wantTemplateRecipe{
		"new-mail-summary": {
			trigger:     automations.Trigger{Kind: automations.TriggerEvent, Event: &automations.EventTrigger{Type: "gmail.new_messages"}},
			permissions: []string{"gmail:read@*", "llm:light"},
			outputs:     []string{"inbox"},
		},
	}},
	{"pr-review-rounds", automations.ScopeWorkbench, []string{"pr-review-rounds"}, map[string]wantTemplateRecipe{
		"pr-review-rounds": {
			trigger:     scheduleTrigger("0 10,16 * * 1-5"),
			permissions: []string{`shell:"gh pr list --state open --json number,title,url,author,updatedAt"`, "session:start", "llm:light"},
			outputs:     []string{"report"},
		},
	}},
	{"jira-state-report", automations.ScopePersonal, []string{"jira-state-report"}, map[string]wantTemplateRecipe{
		"jira-state-report": {
			trigger:     scheduleTrigger("0 9 * * 1"),
			permissions: []string{"jira:read@PAY", "llm:strong"},
			outputs:     []string{"report", "briefing"},
		},
	}},
	{"team-performance-report", automations.ScopePersonal, []string{"team-performance-report"}, map[string]wantTemplateRecipe{
		"team-performance-report": {
			trigger:     scheduleTrigger("0 17 * * 5"),
			permissions: []string{"jira:read@*", "people:read", "slack:read@*", "llm:strong"},
			outputs:     []string{"report"},
		},
	}},
	{"release-buttons", automations.ScopeWorkbench, []string{"release", "deploy-test", "deploy-stage"}, map[string]wantTemplateRecipe{
		"release":      {trigger: buttonTrigger("Release"), permissions: []string{`shell:"make release"`, "session:start"}, outputs: []string{"report"}},
		"deploy-test":  {trigger: buttonTrigger("Deploy to test"), permissions: []string{`shell:"make deploy-test"`, "session:start"}, outputs: []string{"report"}},
		"deploy-stage": {trigger: buttonTrigger("Deploy to stage"), permissions: []string{`shell:"make deploy-stage"`, "session:start"}, outputs: []string{"report"}},
	}},
}

func templateScope(kind automations.ScopeKind) automations.Scope {
	if kind == automations.ScopeWorkbench {
		return automations.Scope{Kind: automations.ScopeWorkbench, WorkbenchID: 1}
	}
	return automations.Scope{Kind: automations.ScopePersonal}
}

func exampleParams(tpl automations.Template) map[string]string {
	params := map[string]string{}
	for _, p := range tpl.Params {
		params[p.Key] = p.Example
	}
	return params
}

func TestTemplates_AllParseAndValidate(t *testing.T) {
	got := automations.Templates()
	if len(got) != len(specTemplates) {
		t.Fatalf("Templates() = %d entries; want %d", len(got), len(specTemplates))
	}
	for i, want := range specTemplates {
		checkTemplateEntry(t, i, got[i], want)
	}
	checkTemplateIndex(t)
	checkJiraWithoutParams(t)
}

func checkTemplateEntry(t *testing.T, i int, tpl automations.Template, want specTemplate) {
	t.Helper()
	if tpl.Name != want.name || tpl.Scope != want.scope || !slices.Equal(tpl.Files, want.files) {
		t.Errorf("template %d = %s %s %v; want %s %s %v", i, tpl.Name, tpl.Scope, tpl.Files, want.name, want.scope, want.files)
		return
	}
	if tpl.Title == "" || tpl.Description == "" || tpl.TriggerText == "" {
		t.Errorf("%s: title, description and trigger text must be set: %+v", tpl.Name, tpl)
	}
	files, err := automations.RenderTemplate(tpl.Name, exampleParams(tpl))
	if err != nil {
		t.Fatalf("RenderTemplate(%s): %v", tpl.Name, err)
	}
	if len(files) != len(want.files) {
		t.Errorf("%s renders %d files; want %d", tpl.Name, len(files), len(want.files))
	}
	for slug, w := range want.recipes {
		checkTemplateRecipe(t, tpl.Name, slug, files[slug], want.scope, w)
	}
	// The gallery's permissions and outputs are the first recipe's, as written.
	first := want.recipes[want.files[0]]
	wantPerms := first.permissions
	if tpl.Name == "jira-state-report" {
		wantPerms = []string{"jira:read@<PROJECT>", "llm:strong"}
	}
	if !slices.Equal(tpl.Permissions, wantPerms) || !slices.Equal(tpl.Outputs, first.outputs) {
		t.Errorf("%s gallery permissions/outputs = %q %q; want %q %q", tpl.Name, tpl.Permissions, tpl.Outputs, wantPerms, first.outputs)
	}
}

func checkTemplateRecipe(t *testing.T, tplName, slug string, file []byte, scope automations.ScopeKind, w wantTemplateRecipe) {
	t.Helper()
	r, err := automations.ParseRecipe(slug, file, templateScope(scope))
	if err != nil {
		t.Errorf("%s/%s does not parse: %v", tplName, slug, err)
		return
	}
	if !triggersEqual(r.Trigger, w.trigger) {
		t.Errorf("%s trigger = %+v; want %+v", slug, r.Trigger, w.trigger)
	}
	if !slices.Equal(r.Permissions, w.permissions) {
		t.Errorf("%s permissions = %q; want %q", slug, r.Permissions, w.permissions)
	}
	if !slices.Equal(r.Outputs, w.outputs) {
		t.Errorf("%s outputs = %q; want %q", slug, r.Outputs, w.outputs)
	}
}

func checkTemplateIndex(t *testing.T) {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("templates", "index.json"))
	if err != nil {
		t.Fatal(err)
	}
	var index []struct {
		Files []string `json:"files"`
	}
	if err := json.Unmarshal(raw, &index); err != nil {
		t.Fatal(err)
	}
	var indexed []string
	for _, e := range index {
		indexed = append(indexed, e.Files...)
	}
	md, err := filepath.Glob(filepath.Join("templates", "*.md"))
	if err != nil {
		t.Fatal(err)
	}
	var onDisk []string
	for _, p := range md {
		onDisk = append(onDisk, strings.TrimSuffix(filepath.Base(p), ".md"))
	}
	slices.Sort(indexed)
	slices.Sort(onDisk)
	want := []string{"deploy-stage", "deploy-test", "jira-state-report", "new-mail-summary", "pr-review-rounds", "release", "team-performance-report"}
	if !slices.Equal(indexed, want) || !slices.Equal(onDisk, want) {
		t.Errorf("index.json names %v and templates/ holds %v; want exactly %v", indexed, onDisk, want)
	}
}

func checkJiraWithoutParams(t *testing.T) {
	t.Helper()
	// Without its param, jira-state-report keeps <PROJECT> and does not parse.
	files, err := automations.RenderTemplate("jira-state-report", nil)
	if err != nil {
		t.Fatal(err)
	}
	_, err = automations.ParseRecipe("jira-state-report", files["jira-state-report"], automations.Scope{Kind: automations.ScopePersonal})
	var pe *automations.ParseError
	if !errors.As(err, &pe) || !strings.Contains(pe.Error(), "<PROJECT>") {
		t.Errorf("jira-state-report without params: err = %v; want a parse error naming <PROJECT>", err)
	}
}

func triggersEqual(a, b automations.Trigger) bool {
	if a.Kind != b.Kind || a.Schedule != b.Schedule {
		return false
	}
	if (a.Button == nil) != (b.Button == nil) || a.Button != nil && *a.Button != *b.Button {
		return false
	}
	if (a.Event == nil) != (b.Event == nil) {
		return false
	}
	return a.Event == nil || a.Event.Type == b.Event.Type && len(a.Event.Where) == 0 && len(b.Event.Where) == 0
}

func TestRenderTemplate_Params(t *testing.T) {
	files, err := automations.RenderTemplate("jira-state-report", map[string]string{"PROJECT": "PAY"})
	if err != nil {
		t.Fatal(err)
	}
	text := string(files["jira-state-report"])
	if strings.Contains(text, "<PROJECT>") || !strings.Contains(text, "jira:read@PAY") {
		t.Errorf("PROJECT=PAY not substituted everywhere:\n%s", text)
	}
	refused := []struct {
		name   string
		params map[string]string
		names  string
	}{
		{"unknown template", nil, "no-such"},
		{"undeclared param", map[string]string{"X": "1"}, "X"},
		{"empty value", map[string]string{"PROJECT": ""}, "PROJECT"},
		{"whitespace", map[string]string{"PROJECT": "a b"}, "PROJECT"},
		{"newline", map[string]string{"PROJECT": "A\nB"}, "PROJECT"},
		{"quote", map[string]string{"PROJECT": `A"`}, "PROJECT"},
		{"at", map[string]string{"PROJECT": "A@B"}, "PROJECT"},
		{"angle", map[string]string{"PROJECT": "<A>"}, "PROJECT"},
	}
	for _, tc := range refused {
		name := "jira-state-report"
		if tc.name == "unknown template" {
			name = "no-such"
		}
		if _, err := automations.RenderTemplate(name, tc.params); err == nil || !strings.Contains(err.Error(), tc.names) {
			t.Errorf("%s: err = %v; want an error naming %s", tc.name, err, tc.names)
		}
	}
	if _, err := automations.RenderTemplate("new-mail-summary", map[string]string{"PROJECT": "PAY"}); err == nil {
		t.Error("a param the template does not declare must be refused")
	}
}

// new-mail-summary on two sync events: the first run sums up the new mail of
// the event's mailbox and stores its cursor; the second, given the same
// messages, sums up nothing (spec §15 #1: the per-account since cursor).
func TestTemplate_NewMailSummaryKeepsPerAccountCursor(t *testing.T) {
	f := newExFixture(t, exOpts{fileDB: true})
	f.reg.ReadResults["list_emails"] = map[string]any{"account": "work", "messages": []map[string]any{
		{"id": "m2", "from": "colleague A <a@example.com>", "subject": "Deploy", "snippet": "today?", "date": "2026-10-14T11:00:00Z"},
		{"id": "m1", "from": "colleague B <b@example.com>", "subject": "Lunch", "snippet": "at 1", "date": "2026-10-14T10:00:00Z"},
	}}
	files, err := automations.RenderTemplate("new-mail-summary", nil)
	if err != nil {
		t.Fatal(err)
	}
	a := f.seedText(t, "new-mail-summary", string(files["new-mail-summary"]), false)
	event := func(cycle string) int64 {
		return f.enqueueReq(t, db.EnqueueRequest{AutomationID: a.ID, Trigger: db.TriggerEvent, EventCycle: cycle,
			EventJSON: `{"cycles":["` + cycle + `"],"events":[{"type":"gmail.new_messages","account":"work","count":2}],"count":1,"truncated":false}`})
	}

	first := event("c1")
	f.step(t, 1)
	f.wantRun(t, first, db.RunSucceeded, "")
	if n := f.count(t, "automation_outputs"); n != 1 {
		t.Fatalf("outputs after the first run = %d; want 1", n)
	}
	var state string
	if err := f.d.QueryRow(`SELECT state_json FROM automation_state WHERE automation_id = ?`, a.ID).Scan(&state); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(state, `"work":"2026-10-14T11:00:00Z"`) {
		t.Fatalf("state = %s; want the work cursor at the newest message", state)
	}

	second := event("c2")
	f.step(t, 1)
	f.wantRun(t, second, db.RunSucceeded, "")
	if n := f.count(t, "automation_outputs"); n != 1 {
		t.Fatalf("outputs after the second run = %d; want still 1", n)
	}
	reads := f.reg.ReadCalls()
	if last := string(reads[len(reads)-1].Args); !strings.Contains(last, `"since":"2026-10-14T11:00:00Z"`) {
		t.Fatalf("second list_emails args = %s; want since = the cursor", last)
	}
}
