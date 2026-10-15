package automations

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/google/jsonschema-go/jsonschema"

	"watchtower/internal/db"
	"watchtower/internal/tools"
)

var (
	personalScope  = Scope{Kind: ScopePersonal}
	workbenchScope = Scope{Kind: ScopeWorkbench, WorkbenchID: 1}
)

func mustManifest(t *testing.T, entries []string, outputs ...string) *Manifest {
	t.Helper()
	m, err := ParseManifest(entries, outputs, workbenchScope)
	if err != nil {
		t.Fatalf("ParseManifest(%v): %v", entries, err)
	}
	return m
}

// autoTool is a fake registry tool visible on the automation surface.
func autoTool(name string) *tools.Tool {
	return &tools.Tool{Name: name, Surfaces: []string{tools.AutomationSurface}}
}

func openManifestTestDB(t *testing.T) *db.DB {
	t.Helper()
	d := db.OpenTestDB(t)
	return d
}

func mustExec(t *testing.T, d *db.DB, q string, args ...any) {
	t.Helper()
	if _, err := d.Exec(q, args...); err != nil {
		t.Fatalf("exec %q: %v", q, err)
	}
}

// expectAdmit asserts that m admits tool t with args.
func expectAdmit(t *testing.T, d *db.DB, m *Manifest, tool *tools.Tool, args string) {
	t.Helper()
	if _, err := m.AllowTool(context.Background(), d, tool, json.RawMessage(args)); err != nil {
		t.Errorf("%s %s: want admitted, got %v", tool.Name, args, err)
	}
}

// expectDeny asserts that m denies tool t with args, needing needed.
func expectDeny(t *testing.T, d *db.DB, m *Manifest, tool *tools.Tool, args, needed string) {
	t.Helper()
	_, err := m.AllowTool(context.Background(), d, tool, json.RawMessage(args))
	var pd *PermissionDenied
	if !errors.As(err, &pd) {
		t.Errorf("%s %s: want *PermissionDenied, got %v", tool.Name, args, err)
		return
	}
	if pd.Needed != needed {
		t.Errorf("%s %s: needed = %q, want %q", tool.Name, args, pd.Needed, needed)
	}
}

func TestManifest_GrammarTable(t *testing.T) {
	valid := []string{
		"gmail:read@work", "jira:read@PAY", "jira:read@*", "tool:create_target", "tool:search_knowledge",
		"mcp:github/list_*", `shell:"make release"`, `shell:"echo \"hi\""`, "llm:strong", "agent:run",
		"ask:owner", "session:start", "session:start@codex", "targets:read", "meetings:read", "dayplan:read",
	}
	for _, s := range valid {
		if _, err := ParsePermission(s); err != nil {
			t.Errorf("ParsePermission(%q): unexpected error %v", s, err)
		}
	}
	invalid := []string{
		"gmail:read", "targets:read@x", "knowledge:read", "knowledge:write", "meetings:write", "dayplan:read@x",
		"inbox:read", "memory:read", "llm:medium", "jira:delete@PAY", "shell:make release", `shell:"unterminated`,
		"mcp:github", "mcp:*/x", "foo:read", "tool:", "",
	}
	for _, s := range invalid {
		if _, err := ParsePermission(s); err == nil {
			t.Errorf("ParsePermission(%q): want error", s)
		}
	}
}

func TestManifest_PermissionStringNormalises(t *testing.T) {
	cases := map[string]string{
		"Jira:READ@pay":                "jira:read@PAY",
		"confluence:read@eng":          "confluence:read@ENG",
		"GMAIL:read@Owner@Example.com": "gmail:read@owner@example.com",
		`shell:"echo <hi>"`:            `shell:"echo <hi>"`,
		"mcp:github/list_*":            "mcp:github/list_*",
		"session:start@CODEX":          "session:start@codex",
	}
	for in, want := range cases {
		p, err := ParsePermission(in)
		if err != nil {
			t.Fatalf("ParsePermission(%q): %v", in, err)
		}
		if got := p.String(); got != want {
			t.Errorf("ParsePermission(%q).String() = %q, want %q", in, got, want)
		}
		if p.Raw != in {
			t.Errorf("Raw = %q, want %q", p.Raw, in)
		}
	}
}

func TestManifest_PersonalRefusesShellSessionAsk(t *testing.T) {
	for _, e := range []string{`shell:"make release"`, "session:start", "session:start@claude", "ask:owner"} {
		if _, err := ParseManifest([]string{e}, nil, personalScope); err == nil {
			t.Errorf("%s in a personal recipe: want error", e)
		}
		if _, err := ParseManifest([]string{e}, nil, workbenchScope); err != nil {
			t.Errorf("%s in workbench:1: unexpected error %v", e, err)
		}
	}
}

func TestManifest_ScopeMatching(t *testing.T) {
	d := openManifestTestDB(t)
	list := tools.NewListJiraIssues()
	m := mustManifest(t, []string{"jira:read@PAY"})
	expectAdmit(t, d, m, list, `{"project":"pay"}`)
	expectDeny(t, d, m, list, `{"project":"OPS"}`, "jira:read@OPS")
	expectDeny(t, d, m, list, `{}`, "jira:read@*")

	star := mustManifest(t, []string{"jira:read@*"})
	for _, a := range []string{`{"project":"pay"}`, `{"project":"OPS"}`, `{}`} {
		expectAdmit(t, d, star, list, a)
	}
	glob := mustManifest(t, []string{"jira:read@P*"})
	expectAdmit(t, d, glob, list, `{"project":"PAY"}`)
	expectDeny(t, d, glob, list, `{}`, "jira:read@*")
}

func TestManifest_ToolPermissionAdmitsWithoutCapability(t *testing.T) {
	m := mustManifest(t, []string{"tool:list_jira_issues"})
	by, err := m.AllowTool(context.Background(), nil, tools.NewListJiraIssues(), json.RawMessage(`{"project":"OPS"}`))
	if err != nil || by != "tool:list_jira_issues" {
		t.Fatalf("admittedBy = %q, err = %v", by, err)
	}
}

func TestManifest_JiraScopeFromRealArgs(t *testing.T) {
	d := openManifestTestDB(t)
	m := mustManifest(t, []string{"jira:read@PAY"})
	get := tools.NewGetJiraIssue()
	expectAdmit(t, d, m, get, `{"key":"PAY-1"}`)
	expectDeny(t, d, m, get, `{"key":"OPS-1"}`, "jira:read@OPS")
	expectDeny(t, d, m, get, `{"key":"nodash"}`, "jira:read@*")
	expectDeny(t, nil, m, tools.NewGetJiraStatusHistory(), `{"keys":["PAY-1","OPS-2"]}`, "jira:read@OPS")
	tis := tools.NewGetJiraTimeInStatus()
	expectAdmit(t, nil, m, tis, `{"issue_keys":["PAY-3"]}`)
	expectDeny(t, nil, m, tis, `{"board_id":4}`, "jira:read@*")
	expectAdmit(t, nil, m, tis, `{"project":"pay","issue_keys":["OPS-1"]}`)

	w := mustManifest(t, []string{"jira:write@PAY"})
	create, comment := autoTool("create_jira_issue"), autoTool("add_jira_comment")
	expectAdmit(t, nil, w, create, `{"project_key":"pay"}`)
	expectAdmit(t, nil, w, comment, `{"key":"PAY-7"}`)
	expectDeny(t, nil, w, create, `{"project_key":"OPS"}`, "jira:write@OPS")
	expectDeny(t, nil, w, comment, `{"key":"OPS-1"}`, "jira:write@OPS")
	expectDeny(t, nil, w, comment, `{"key":"nodash"}`, "jira:write@*")
	// The read entry never admits a write tool.
	expectDeny(t, nil, m, comment, `{"key":"PAY-7"}`, "jira:write@PAY")
}

func TestManifest_SlackWriteScopeByAccountLabel(t *testing.T) {
	d := openManifestTestDB(t)
	mustExec(t, d, `INSERT INTO slack_accounts (id, label, team_domain) VALUES (1, 'work', 'acme-work'), (2, 'home', 'acme-home')`)
	send := autoTool("send_slack_message")
	work := mustManifest(t, []string{"slack:write@work"})
	expectAdmit(t, d, work, send, `{"account_id":1}`)
	expectDeny(t, d, work, send, `{"account_id":2}`, "slack:write@home")
	expectDeny(t, d, work, send, `{}`, "slack:write@*")
	expectAdmit(t, d, mustManifest(t, []string{"slack:write@*"}), send, `{}`)
	// The team domain is a second name of the same account.
	expectAdmit(t, d, mustManifest(t, []string{"slack:write@acme-work"}), send, `{"account_id":1}`)

	mustExec(t, d, `UPDATE slack_accounts SET enabled = 0 WHERE id = 2`)
	expectAdmit(t, d, work, send, `{}`)
}

func TestManifest_ScopeOfErrorIsADeniedNotAPanic(t *testing.T) {
	d := openManifestTestDB(t)
	m := mustManifest(t, []string{"slack:write@work"})
	expectDeny(t, d, m, autoTool("send_slack_message"), `{"account_id":99}`, "slack:write@*")
	// Arguments that are not an object are denied the same way.
	expectDeny(t, d, m, autoTool("send_slack_message"), `[1]`, "slack:write@*")
}

func TestManifest_EmailScopeMatchesLabelOrAddress(t *testing.T) {
	d := openManifestTestDB(t)
	mustExec(t, d, `INSERT INTO google_accounts (id, email, label, gmail_enabled) VALUES (1, 'owner@example.com', 'work', 1)`)
	list := autoTool("list_emails")
	for _, entry := range []string{"gmail:read@work", "gmail:read@owner@example.com"} {
		m := mustManifest(t, []string{entry})
		expectAdmit(t, d, m, list, `{"account":"owner@example.com"}`)
		expectAdmit(t, d, m, list, `{"account":"work"}`)
	}
	expectDeny(t, d, mustManifest(t, []string{"gmail:read@home"}), list, `{"account":"work"}`, "gmail:read@work")
	// An unknown account has an absent scope: only @* admits (the tool then refuses it).
	expectDeny(t, d, mustManifest(t, []string{"gmail:read@work"}), list, `{"account":"nobody"}`, "gmail:read@*")

	mustExec(t, d, `INSERT INTO email_accounts (id, provider, email_address, label) VALUES (1, 'imap', 'me@example.org', 'home')`)
	expectAdmit(t, d, mustManifest(t, []string{"gmail:read@home"}), autoTool("get_email"), `{"account":"me@example.org","id":"x"}`)
}

func TestManifest_UnscopedSourceReadsNeedStar(t *testing.T) {
	msgs := tools.NewListMessages()
	expectDeny(t, nil, mustManifest(t, []string{"slack:read@work"}), msgs, `{"channel":"releases"}`, "slack:read@*")
	expectAdmit(t, nil, mustManifest(t, []string{"slack:read@*"}), msgs, `{"channel":"releases"}`)
	expectAdmit(t, nil, mustManifest(t, []string{"tool:list_messages"}), msgs, `{"channel":"releases"}`)
	ev := tools.NewListUpcomingEvents()
	expectDeny(t, nil, mustManifest(t, []string{"calendar:read@work"}), ev, `{}`, "calendar:read@*")
	expectAdmit(t, nil, mustManifest(t, []string{"calendar:read@*"}), ev, `{}`)
}

// everyCapability is a manifest holding every capability entry, so a denial
// can only come from the tool being tool:-only.
var everyCapability = []string{
	"slack:read@*", "slack:write@*", "gmail:read@*", "gmail:write@*", "jira:read@*", "jira:write@*",
	"calendar:read@*", "calendar:write@*", "confluence:read@*", "confluence:write@*",
	"targets:read", "targets:write", "tracks:read", "tracks:write", "ideas:read", "ideas:write",
	"digests:read", "digests:write", "people:read", "people:write", "transcripts:read", "transcripts:write",
	"meetings:read", "dayplan:read", "llm:strong", "agent:run",
}

func TestManifest_D23ToolScopes(t *testing.T) {
	d := openManifestTestDB(t)
	mustExec(t, d, `INSERT INTO google_accounts (id, email, label, calendar_enabled) VALUES (1, 'owner@example.com', 'work', 1)`)
	mustExec(t, d, `INSERT INTO calendar_accounts (id, provider, label) VALUES (1, 'caldav', 'team')`)
	acct := db.SeedTestJiraAccount(t, d)
	mustExec(t, d, `INSERT INTO jira_boards (account_id, id, name, project_key) VALUES (?, 7, 'Pay board', 'PAY'), (?, 9, 'Mixed', '')`, acct, acct)

	cal := mustManifest(t, []string{"calendar:read@work"})
	events := autoTool("list_calendar_events")
	expectAdmit(t, d, cal, events, `{"account":"work"}`)
	expectAdmit(t, d, cal, events, `{"account":"owner@example.com"}`)
	expectDeny(t, d, cal, events, `{"account":"team"}`, "calendar:read@team")
	expectDeny(t, d, cal, events, `{}`, "calendar:read@*")
	// The scope matches with SQLite's ASCII-only NOCASE, as the tool does:
	// "ſales" (long s) names no account, so its scope is absent.
	mustExec(t, d, `INSERT INTO google_accounts (id, email, label, calendar_enabled) VALUES (2, 'sales@example.com', 'sales', 1)`)
	sales := mustManifest(t, []string{"calendar:read@sales"})
	expectAdmit(t, d, sales, events, `{"account":"SALES"}`)
	expectDeny(t, d, sales, events, `{"account":"ſales"}`, "calendar:read@*")

	jira := mustManifest(t, []string{"jira:read@PAY"})
	sprints, releases := autoTool("list_jira_sprints"), autoTool("list_jira_releases")
	expectAdmit(t, d, jira, sprints, `{"board_id":7}`)
	expectAdmit(t, d, jira, sprints, `{"project":"pay"}`)
	expectAdmit(t, d, jira, releases, `{"project":"PAY"}`)
	expectDeny(t, d, jira, sprints, `{}`, "jira:read@*")
	expectDeny(t, d, jira, releases, `{}`, "jira:read@*")
	expectDeny(t, d, jira, sprints, `{"board_id":9}`, "jira:read@*")
	expectDeny(t, d, jira, sprints, `{"board_id":404}`, "jira:read@*")

	meetings := mustManifest(t, []string{"meetings:read"})
	for _, n := range []string{"list_meeting_recaps", "get_meeting_recap", "list_meeting_notes"} {
		expectAdmit(t, d, meetings, autoTool(n), `{}`)
	}
	dayplan := mustManifest(t, []string{"dayplan:read"})
	for _, n := range []string{"list_day_plans", "get_day_plan"} {
		expectAdmit(t, d, dayplan, autoTool(n), `{}`)
		expectDeny(t, d, meetings, autoTool(n), `{}`, "dayplan:read")
	}
	expectAdmit(t, d, mustManifest(t, []string{"targets:read"}), autoTool("list_reminders"), `{}`)

	all := mustManifest(t, everyCapability)
	toolOnly := []string{"list_inbox", "memory_recall", "memory_open", "memory_map", "get_writing_style"}
	for _, n := range toolOnly {
		expectDeny(t, d, all, autoTool(n), `{}`, "tool:"+n)
		own := mustManifest(t, []string{"tool:" + n})
		expectAdmit(t, d, own, autoTool(n), `{}`)
		for _, other := range toolOnly {
			if other != n {
				expectDeny(t, d, own, autoTool(other), `{}`, "tool:"+other)
			}
		}
	}
}

func TestManifest_MeetingsAndDayplanReadOnly(t *testing.T) {
	for _, e := range []string{"meetings:write", "dayplan:write"} {
		if _, err := ParseManifest([]string{e}, nil, personalScope); err == nil {
			t.Errorf("%s: want parse error", e)
		}
	}
	if got := Covers([]string{"meetings:read"}, []string{"dayplan:read"}); !reflect.DeepEqual(got, []string{"dayplan:read"}) {
		t.Errorf("Covers = %v", got)
	}
}

func TestManifest_KnowledgeToolsOnlyByToolEntry(t *testing.T) {
	all := mustManifest(t, everyCapability)
	knowledge := []*tools.Tool{tools.NewSearchKnowledge(), tools.NewGetKnowledgeDocument(), tools.NewGetTaskContext()}
	for _, k := range knowledge {
		expectDeny(t, nil, all, k, `{}`, "tool:"+k.Name)
		if _, ok := ToolCapabilities[k.Name]; ok {
			t.Errorf("ToolCapabilities has an entry for %s", k.Name)
		}
	}
	search := mustManifest(t, []string{"tool:search_knowledge"})
	expectAdmit(t, nil, search, knowledge[0], `{"query":"x"}`)
	expectDeny(t, nil, search, knowledge[1], `{}`, "tool:get_knowledge_document")
	expectDeny(t, nil, search, knowledge[2], `{}`, "tool:get_task_context")

	_, err := ParseManifest([]string{"knowledge:read"}, nil, personalScope)
	if err == nil {
		t.Fatal("knowledge:read: want parse error")
	}
	for _, want := range []string{"tool:search_knowledge", "tool:get_knowledge_document", "tool:get_task_context"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q does not name %s", err, want)
		}
	}
}

func TestClampListLimit(t *testing.T) {
	withLimit := &tools.Tool{Name: "x", InputSchema: &jsonschema.Schema{
		Type:       "object",
		Properties: map[string]*jsonschema.Schema{"limit": {Type: "integer"}, "q": {Type: "string"}},
	}}
	limitOf := func(raw json.RawMessage) float64 {
		var m map[string]any
		if err := json.Unmarshal(raw, &m); err != nil {
			t.Fatalf("unmarshal %s: %v", raw, err)
		}
		n, _ := m["limit"].(float64)
		return n
	}
	cases := []struct {
		in   string
		want float64
	}{{`{}`, 50}, {``, 50}, {`null`, 50}, {`{"limit":0}`, 50}, {`{"limit":-3}`, 50}, {`{"limit":1000}`, 200}, {`{"limit":30,"q":"a"}`, 30}}
	for _, c := range cases {
		if got := limitOf(ClampListLimit(withLimit, json.RawMessage(c.in))); got != c.want {
			t.Errorf("ClampListLimit(%s) limit = %v, want %v", c.in, got, c.want)
		}
	}
	keep := json.RawMessage(`{"limit":30,"q":"a"}`)
	if got := ClampListLimit(withLimit, keep); string(got) != string(keep) {
		t.Errorf("an in-range limit changed the args: %s", got)
	}
	without := &tools.Tool{Name: "y", InputSchema: &jsonschema.Schema{Type: "object", Properties: map[string]*jsonschema.Schema{"q": {Type: "string"}}}}
	for _, raw := range []string{`{"limit":1000}`, `{}`, ``} {
		if got := ClampListLimit(without, json.RawMessage(raw)); string(got) != raw {
			t.Errorf("schema without limit: %s changed to %s", raw, got)
		}
	}
	if got := ClampListLimit(&tools.Tool{Name: "z"}, json.RawMessage(`{"limit":1000}`)); string(got) != `{"limit":1000}` {
		t.Errorf("schema-less tool: args changed to %s", got)
	}
}

func TestManifest_ToolNotOnAutomationSurfaceDenied(t *testing.T) {
	m := mustManifest(t, []string{"tool:get_confluence_page", "confluence:read@*"})
	page := tools.NewGetConfluencePage(nil)
	_, err := m.AllowTool(context.Background(), nil, page, json.RawMessage(`{}`))
	var pd *PermissionDenied
	if !errors.As(err, &pd) || pd.Needed != "" || pd.Reason == "" {
		t.Fatalf("err = %#v, want a PermissionDenied with a Reason and no Needed", err)
	}
}

func TestManifest_LLMStrongImpliesLight(t *testing.T) {
	strong := mustManifest(t, []string{"llm:strong"})
	for _, tier := range []string{"light", "strong"} {
		if _, err := strong.AllowLLM(tier); err != nil {
			t.Errorf("llm:strong, tier %s: %v", tier, err)
		}
	}
	light := mustManifest(t, []string{"llm:light"})
	if _, err := light.AllowLLM("light"); err != nil {
		t.Errorf("llm:light, tier light: %v", err)
	}
	var pd *PermissionDenied
	if _, err := light.AllowLLM("strong"); !errors.As(err, &pd) || pd.Needed != "llm:strong" {
		t.Errorf("llm:light, tier strong: %v", err)
	}
	none := mustManifest(t, nil)
	if _, err := none.AllowLLM("light"); !errors.As(err, &pd) || pd.Needed != "llm:light" {
		t.Errorf("no llm entry: %v", err)
	}
}

func TestManifest_OutputGate(t *testing.T) {
	m := mustManifest(t, nil, "inbox", "report", "inbox")
	if !reflect.DeepEqual(m.Outputs(), []string{"inbox", "report"}) {
		t.Errorf("Outputs = %v", m.Outputs())
	}
	if _, err := m.AllowOutput("inbox"); err != nil {
		t.Errorf("inbox: %v", err)
	}
	var pd *PermissionDenied
	if _, err := m.AllowOutput("slack"); !errors.As(err, &pd) || pd.Needed != "output:slack" {
		t.Errorf("slack: %v", err)
	}
	if _, err := ParseManifest(nil, []string{"email"}, personalScope); err == nil {
		t.Error("unknown output kind: want error")
	}
	for _, k := range []string{"inbox", "briefing", "report", "target", "slack"} {
		if _, err := ParseManifest(nil, []string{k}, personalScope); err != nil {
			t.Errorf("output %s: %v", k, err)
		}
	}
}

func TestManifest_CapabilityChecks(t *testing.T) {
	m := mustManifest(t, []string{"agent:run", "ask:owner", "session:start@codex"})
	for _, c := range [][3]string{{"agent", "run", ""}, {"ask", "owner", ""}, {"session", "start", "codex"}} {
		if _, err := m.AllowCapability(c[0], c[1], c[2]); err != nil {
			t.Errorf("%v: %v", c, err)
		}
	}
	var pd *PermissionDenied
	if _, err := m.AllowCapability("session", "start", "claude"); !errors.As(err, &pd) || pd.Needed != "session:start@claude" {
		t.Errorf("session:start@claude: %v", err)
	}
	both := mustManifest(t, []string{"session:start"})
	for _, kind := range []string{"claude", "codex"} {
		if _, err := both.AllowCapability("session", "start", kind); err != nil {
			t.Errorf("session:start admits %s: %v", kind, err)
		}
	}
}

func TestManifest_MCPGlob(t *testing.T) {
	m := mustManifest(t, []string{"mcp:github/list_*"})
	if by, err := m.AllowMCP("github", "list_prs"); err != nil || by != "mcp:github/list_*" {
		t.Errorf("github/list_prs: %q %v", by, err)
	}
	var pd *PermissionDenied
	if _, err := m.AllowMCP("github", "create_pr"); !errors.As(err, &pd) || pd.Needed != "mcp:github/create_pr" {
		t.Errorf("github/create_pr: %v", err)
	}
	if _, err := m.AllowMCP("gitlab", "list_prs"); err == nil {
		t.Error("gitlab/list_prs: want denied")
	}
}

func TestManifest_ShellExactOnly(t *testing.T) {
	m := mustManifest(t, []string{`shell:"make release"`})
	if _, err := m.AllowShell("make release"); err != nil {
		t.Errorf("make release: %v", err)
	}
	for _, cmd := range []string{"make release ", " make release", "make  release", "make release && rm -rf x", "make", "make releases"} {
		var pd *PermissionDenied
		if _, err := m.AllowShell(cmd); !errors.As(err, &pd) {
			t.Errorf("%q: want denied, got %v", cmd, err)
		}
	}
}

func TestManifest_CoversWidening(t *testing.T) {
	cases := []struct {
		old, new, want []string
	}{
		{[]string{"jira:read@PAY"}, []string{"jira:read@*"}, []string{"jira:read@*"}},
		{[]string{"jira:read@*"}, []string{"jira:read@PAY"}, []string{}},
		{[]string{"llm:strong"}, []string{"llm:light"}, []string{}},
		{[]string{"llm:light"}, []string{"llm:strong"}, []string{"llm:strong"}},
		{[]string{`shell:"make release"`}, []string{`shell:"make release"`}, []string{}},
		{[]string{`shell:"make release"`}, []string{`shell:"make  release"`}, []string{`shell:"make  release"`}},
		{[]string{"jira:read@pay"}, []string{"jira:read@PAY", "tool:x"}, []string{"tool:x"}},
		{[]string{"session:start"}, []string{"session:start@codex"}, []string{}},
		{[]string{"session:start@codex"}, []string{"session:start"}, []string{"session:start"}},
		{[]string{"tool:a"}, []string{"tool:b"}, []string{"tool:b"}},
		{[]string{"mcp:github/*"}, []string{"mcp:github/list_*", "mcp:gitlab/x"}, []string{"mcp:gitlab/x"}},
		{nil, nil, []string{}},
	}
	for _, c := range cases {
		got := Covers(c.old, c.new)
		if got == nil || !reflect.DeepEqual(got, c.want) {
			t.Errorf("Covers(%v, %v) = %#v, want %v", c.old, c.new, got, c.want)
		}
	}
}

func TestManifest_NormalizedIsSortedAndDeduped(t *testing.T) {
	m := mustManifest(t, []string{"llm:light", "jira:read@pay", "Jira:Read@PAY", "agent:run", "llm:light"})
	want := []string{"agent:run", "jira:read@PAY", "llm:light"}
	if got := m.Normalized(); !reflect.DeepEqual(got, want) {
		t.Errorf("Normalized = %v, want %v", got, want)
	}
	if got := mustManifest(t, nil).Normalized(); got == nil || len(got) != 0 {
		t.Errorf("empty manifest Normalized = %#v, want []", got)
	}
}

func TestManifest_ErrorNamesEntry(t *testing.T) {
	_, err := ParseManifest([]string{"llm:light", "foo:read"}, nil, personalScope)
	var me *ManifestError
	if !errors.As(err, &me) || me.Field != "permissions" || me.Index != 1 {
		t.Fatalf("err = %#v", err)
	}
	if !strings.Contains(err.Error(), "foo:read") {
		t.Errorf("error %q does not name the entry", err)
	}
}

func TestRecipe_ManifestValidatedWithLine(t *testing.T) {
	src := "---\nname: A\ntrigger:\n  manual: true\npermissions:\n  - llm:light\n  - foo:read\n---\n```js\nx\n```\n"
	_, err := ParseRecipe("a", []byte(src), personalScope)
	var pe *ParseError
	if !errors.As(err, &pe) || pe.Line != 7 {
		t.Fatalf("err = %v, want a ParseError at line 7", err)
	}
	src = "---\nname: A\ntrigger:\n  manual: true\noutputs: [inbox, email]\n---\n```js\nx\n```\n"
	if _, err := ParseRecipe("a", []byte(src), personalScope); !errors.As(err, &pe) || pe.Line != 5 {
		t.Fatalf("err = %v, want a ParseError at line 5", err)
	}
}

func TestApprovalHash_UsesNormalisedPermissions(t *testing.T) {
	a := &Recipe{Scope: personalScope, Script: "x", Permissions: []string{"jira:read@PAY", "llm:light"}}
	b := &Recipe{Scope: personalScope, Script: "x", Permissions: []string{"Jira:READ@pay", "llm:light", "LLM:light"}}
	if ApprovalHash(a) != ApprovalHash(b) {
		t.Error("case and duplicate variants of the same entries hash differently")
	}
}

// autoWriteTool is a fake registry write tool visible on the automation
// surface (the real write tools join the surface in P2 Task 4).
func autoWriteTool(name string) *tools.Tool {
	t := autoTool(name)
	t.Access = tools.AccessWrite
	return t
}

// admitsCase is one AdmitsTool/AdmitsWrite row: a manifest (entries and
// outputs), a tool, and the expected verdict.
type admitsCase struct {
	name    string
	entries []string
	outputs []string
	tool    *tools.Tool
	want    bool
}

func runAdmitsCases(t *testing.T, cases []admitsCase, admits func(*Manifest, *tools.Tool) bool) {
	t.Helper()
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			m := mustManifest(t, c.entries, c.outputs...)
			if got := admits(m, c.tool); got != c.want {
				t.Errorf("%v outputs %v, %s: got %v, want %v", c.entries, c.outputs, c.tool.Name, got, c.want)
			}
		})
	}
}

func TestManifest_AdmitsTool(t *testing.T) {
	jiraRead := []string{"jira:read@PAY"}
	allReads := everyCapability
	cases := []admitsCase{
		{"jira read admits list_jira_issues", jiraRead, nil, autoTool("list_jira_issues"), true},
		{"jira read admits get_jira_issue", jiraRead, nil, autoTool("get_jira_issue"), true},
		{"jira read does not admit create_jira_issue", jiraRead, nil, autoWriteTool("create_jira_issue"), false},
		{"jira read admits list_jira_sprints by name", jiraRead, nil, autoTool("list_jira_sprints"), true},
		{"targets read admits list_targets", []string{"targets:read"}, nil, autoTool("list_targets"), true},
		{"targets read does not admit create_target", []string{"targets:read"}, nil, autoWriteTool("create_target"), false},
		{"meetings read admits get_meeting_recap", []string{"meetings:read"}, nil, autoTool("get_meeting_recap"), true},
		{"tool entry off the surface", []string{"tool:get_confluence_page"}, nil, tools.NewGetConfluencePage(nil), false},
		{"outputs slack admits no tool() send_slack_message", nil, []string{"slack"}, autoWriteTool("send_slack_message"), false},
		{"outputs target admits no tool() create_target", nil, []string{"target"}, autoWriteTool("create_target"), false},
		{"unscoped call: slack read of one account", []string{"slack:read@work"}, nil, autoTool("list_messages"), false},
		{"unscoped call: slack read star", []string{"slack:read@*"}, nil, autoTool("list_messages"), true},
		{"unscoped call: calendar read of one account", []string{"calendar:read@work"}, nil, autoTool("list_upcoming_events"), false},
		{"unscoped call: jira read star", []string{"jira:read@*"}, nil, autoTool("list_jira_projects"), true},
		{"unscoped call: jira read of one project", jiraRead, nil, autoTool("list_jira_projects"), false},
		{"unscoped call: tool entry", []string{"tool:list_messages"}, nil, autoTool("list_messages"), true},
		{"empty manifest", nil, nil, autoTool("list_targets"), false},
		{"every capability: search_knowledge", allReads, nil, tools.NewSearchKnowledge(), false},
		{"every capability: get_knowledge_document", allReads, nil, tools.NewGetKnowledgeDocument(), false},
		{"every capability: get_task_context", allReads, nil, tools.NewGetTaskContext(), false},
		{"tool:search_knowledge admits it", []string{"tool:search_knowledge"}, nil, tools.NewSearchKnowledge(), true},
		{"tool:search_knowledge admits no sibling", []string{"tool:search_knowledge"}, nil, tools.NewGetKnowledgeDocument(), false},
	}
	runAdmitsCases(t, cases, (*Manifest).AdmitsTool)
}

func TestManifest_AdmitsWrite(t *testing.T) {
	alwaysAsk := autoWriteTool("dismiss_tracks")
	alwaysAsk.AlwaysAsk = true
	cases := []admitsCase{
		{"tool:create_target", []string{"tool:create_target"}, nil, autoWriteTool("create_target"), true},
		{"outputs target", nil, []string{"target"}, autoWriteTool("create_target"), true},
		{"outputs slack", nil, []string{"slack"}, autoWriteTool("send_slack_message"), true},
		{"outputs slack does not cover create_target", nil, []string{"slack"}, autoWriteTool("create_target"), false},
		{"outputs inbox report briefing cover no tool", nil, []string{"inbox", "report", "briefing"}, autoWriteTool("create_target"), false},
		{"outputs target, tool off the surface", nil, []string{"target"}, &tools.Tool{Name: "create_target", Access: tools.AccessWrite, Surfaces: []string{"chat"}}, false},
		{"jira write admits create_jira_issue", []string{"jira:write@PAY"}, nil, autoWriteTool("create_jira_issue"), true},
		{"jira read star does not admit create_jira_issue", []string{"jira:read@*"}, nil, autoWriteTool("create_jira_issue"), false},
		{"real dismiss_tracks: AlwaysAsk, not on the surface", []string{"tool:dismiss_tracks"}, nil, tools.NewDismissTracks(), false},
		{"AlwaysAsk on the surface", []string{"tool:dismiss_tracks"}, nil, alwaysAsk, false},
		{"read tool admitted by name is not a write", []string{"tool:list_targets", "targets:read"}, nil, autoTool("list_targets"), false},
		{"write tool not admitted", []string{"targets:read"}, nil, autoWriteTool("create_target"), false},
	}
	runAdmitsCases(t, cases, (*Manifest).AdmitsWrite)
}
