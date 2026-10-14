package automations

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// seedJiraIssue inserts a jira_issues row with the given raw JSON.
func seedJiraIssue(t *testing.T, d *db.DB, acct int64, key, project, raw string) {
	t.Helper()
	mustExec(t, d, `INSERT INTO jira_issues (account_id, key, project_key, summary, status, status_category, raw_json, created_at, updated_at, synced_at)
		VALUES (?, ?, ?, 's', 'Open', 'new', ?, '', '', '')`, acct, key, project, raw)
}

func TestManifest_JiraLinkedIssuesWidenScope(t *testing.T) {
	d := openManifestTestDB(t)
	acct := db.SeedTestJiraAccount(t, d)
	seedJiraIssue(t, d, acct, "PAY-1", "PAY",
		`{"key":"PAY-1","fields":{"issuelinks":[{"id":"1","outwardIssue":{"key":"OPS-9"}}]}}`)
	seedJiraIssue(t, d, acct, "PAY-2", "PAY",
		`{"key":"PAY-2","fields":{"issuelinks":[{"id":"2","inwardIssue":{"key":"PAY-1"}}],"parent":{"key":"EPC-3"}}}`)
	seedJiraIssue(t, d, acct, "PAY-3", "PAY", `not json`)
	seedJiraIssue(t, d, acct, "PAY-4", "PAY", ``)
	seedJiraIssue(t, d, acct, "PAY-5", "PAY", `{"key":"PAY-5","fields":{}}`)
	mustExec(t, d, `UPDATE jira_issues SET custom_fields_json = '{"customfield_1":{"key":"RSK-4"}}' WHERE key = 'PAY-5'`)

	pay := mustManifest(t, []string{"jira:read@PAY"})
	payOps := mustManifest(t, []string{"jira:read@PAY", "jira:read@OPS"})
	get, list := tools.NewGetJiraIssue(), tools.NewListJiraIssues()

	// get_jira_issue returns raw_json: a cross-project link needs that project too.
	expectDeny(t, d, pay, get, `{"key":"PAY-1"}`, "jira:read@OPS")
	expectAdmit(t, d, payOps, get, `{"key":"PAY-1"}`)
	expectDeny(t, d, payOps, get, `{"key":"PAY-2"}`, "jira:read@EPC")
	// Unreadable or empty raw JSON fails closed: only @* admits.
	star := mustManifest(t, []string{"jira:read@*"})
	for _, k := range []string{"PAY-3", "PAY-4"} {
		expectDeny(t, d, payOps, get, `{"key":"`+k+`"}`, "jira:read@*")
		expectAdmit(t, d, star, get, `{"key":"`+k+`"}`)
	}
	// An issue key in the custom fields needs its project too.
	expectDeny(t, d, payOps, get, `{"key":"PAY-5"}`, "jira:read@RSK")
	expectAdmit(t, d, mustManifest(t, []string{"jira:read@PAY", "jira:read@RSK"}), get, `{"key":"pay-5"}`)

	// list_jira_issues: every project its issues reference.
	// The project holds an unreadable row, so only @* admits the list.
	expectDeny(t, d, mustManifest(t, []string{"jira:read@PAY", "jira:read@OPS", "jira:read@EPC", "jira:read@RSK"}), list, `{"project":"PAY"}`, "jira:read@*")
	expectAdmit(t, d, star, list, `{"project":"pay"}`)

	// get_jira_time_in_status adds linked issues of any project unless include_linked is false.
	tis := tools.NewGetJiraTimeInStatus()
	expectDeny(t, d, pay, tis, `{"project":"PAY"}`, "jira:read@*")
	expectDeny(t, d, pay, tis, `{"project":"PAY","include_linked":true}`, "jira:read@*")
	expectDeny(t, d, pay, tis, `{"issue_keys":["PAY-1"]}`, "jira:read@*")
	expectAdmit(t, d, pay, tis, `{"project":"PAY","include_linked":false}`)

	// get_jira_status_history returns only its keys' issues, never their links.
	expectAdmit(t, d, pay, tools.NewGetJiraStatusHistory(), `{"keys":["PAY-1"]}`)
}

func TestManifest_ListJiraIssuesReferencedProjectsInKeyOrder(t *testing.T) {
	d := openManifestTestDB(t)
	acct := db.SeedTestJiraAccount(t, d)
	seedJiraIssue(t, d, acct, "PAY-1", "PAY",
		`{"key":"PAY-1","fields":{"issuelinks":[{"id":"1","outwardIssue":{"key":"OPS-9"}}]}}`)
	seedJiraIssue(t, d, acct, "PAY-2", "PAY", `{"key":"PAY-2","fields":{"parent":{"key":"EPC-3"}}}`)
	list := tools.NewListJiraIssues()
	expectDeny(t, d, mustManifest(t, []string{"jira:read@PAY"}), list, `{"project":"PAY"}`, "jira:read@EPC")
	expectDeny(t, d, mustManifest(t, []string{"jira:read@PAY", "jira:read@EPC"}), list, `{"project":"PAY"}`, "jira:read@OPS")
	expectAdmit(t, d, mustManifest(t, []string{"jira:read@PAY", "jira:read@OPS", "jira:read@EPC"}), list, `{"project":"pay"}`)
}

func TestManifest_CaseVariantScopeArgRefused(t *testing.T) {
	d := openManifestTestDB(t)
	star := mustManifest(t, []string{"jira:read@PAY"})
	expectDeny(t, d, star, tools.NewListJiraIssues(), `{"project":"PAY","PROJECT":"OPS"}`, "jira:read@*")
	expectDeny(t, d, star, tools.NewGetJiraIssue(), `{"Key":"PAY-1"}`, "jira:read@*")
	expectDeny(t, d, mustManifest(t, []string{"gmail:read@work"}), autoTool("list_emails"), `{"Account":"work"}`, "gmail:read@*")
	// A non-scope key in any case is fine.
	expectAdmit(t, d, star, tools.NewListJiraIssues(), `{"project":"PAY","Status":"Open"}`)
}

func TestManifest_DeniedCarriesCause(t *testing.T) {
	d := openManifestTestDB(t)
	m := mustManifest(t, []string{"slack:write@work"})
	_, err := m.AllowTool(context.Background(), d, autoTool("send_slack_message"), json.RawMessage(`{"account_id":99}`))
	var pd *PermissionDenied
	if !errors.As(err, &pd) || pd.Cause == nil || pd.Needed != "slack:write@*" {
		t.Fatalf("err = %#v, want a PermissionDenied with a Cause", err)
	}
	if errors.Unwrap(err) != pd.Cause {
		t.Error("Unwrap does not return the Cause")
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err = m.AllowTool(ctx, d, autoTool("send_slack_message"), json.RawMessage(`{"account_id":1}`))
	if !errors.As(err, &pd) || !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled context: err = %v, want a PermissionDenied wrapping context.Canceled", err)
	}
}

func TestManifest_TwoEntriesJointlyAdmit(t *testing.T) {
	history := tools.NewGetJiraStatusHistory()
	args := `{"keys":["PAY-1","OPS-2"]}`
	by, err := mustManifest(t, []string{"jira:read@PAY", "jira:read@OPS"}).AllowTool(context.Background(), nil, history, json.RawMessage(args))
	if err != nil || by != "jira:read@PAY, jira:read@OPS" {
		t.Fatalf("admittedBy = %q, err = %v", by, err)
	}
	expectDeny(t, nil, mustManifest(t, []string{"jira:read@PAY"}), history, args, "jira:read@OPS")
	expectDeny(t, nil, mustManifest(t, []string{"jira:read@OPS"}), history, args, "jira:read@PAY")
}

func TestManifest_ShellEscapedEntry(t *testing.T) {
	m := mustManifest(t, []string{`shell:"echo \"hi\""`})
	if by, err := m.AllowShell(`echo "hi"`); err != nil || by != `shell:"echo \"hi\""` {
		t.Fatalf("admittedBy = %q, err = %v", by, err)
	}
	var pd *PermissionDenied
	if _, err := m.AllowShell(`echo \"hi\"`); !errors.As(err, &pd) {
		t.Errorf("the still-escaped form: want denied, got %v", err)
	}
}

func TestManifest_NilDBDeniedNotPanic(t *testing.T) {
	cases := []struct {
		entry, tool, args, needed string
	}{
		{"slack:write@work", "send_slack_message", `{"account_id":1}`, "slack:write@*"},
		{"gmail:read@work", "list_emails", `{"account":"work"}`, "gmail:read@*"},
		{"jira:read@PAY", "list_jira_sprints", `{"board_id":7}`, "jira:read@*"},
		{"jira:read@PAY", "get_jira_issue", `{"key":"PAY-1"}`, "jira:read@*"},
	}
	for _, c := range cases {
		m := mustManifest(t, []string{c.entry})
		_, err := m.AllowTool(context.Background(), nil, autoTool(c.tool), json.RawMessage(c.args))
		var pd *PermissionDenied
		if !errors.As(err, &pd) || pd.Needed != c.needed || !errors.Is(err, errNoDB) {
			t.Errorf("%s: err = %v, want denied %s caused by errNoDB", c.tool, err, c.needed)
		}
	}
}

func TestManifest_CoversGlobsBothWays(t *testing.T) {
	cases := []struct {
		old, new, want []string
	}{
		{[]string{"jira:read@P*"}, []string{"jira:read@PAY"}, []string{}},
		{[]string{"jira:read@PAY"}, []string{"jira:read@P*"}, []string{"jira:read@P*"}},
		{[]string{"jira:read@P*"}, []string{"jira:read@OPS"}, []string{"jira:read@OPS"}},
		{[]string{"mcp:github/list_*"}, []string{"mcp:github/list_prs"}, []string{}},
		{[]string{"mcp:github/list_prs"}, []string{"mcp:github/list_*"}, []string{"mcp:github/list_*"}},
		// MCP tool globs are case-sensitive, as in AllowMCP.
		{[]string{"mcp:github/list_*"}, []string{"mcp:github/List_Prs"}, []string{"mcp:github/List_Prs"}},
	}
	for _, c := range cases {
		if got := Covers(c.old, c.new); !reflect.DeepEqual(got, c.want) {
			t.Errorf("Covers(%v, %v) = %v, want %v", c.old, c.new, got, c.want)
		}
	}
	if _, err := mustManifest(t, []string{"mcp:github/list_*"}).AllowMCP("github", "List_Prs"); err == nil {
		t.Error("AllowMCP: List_Prs must not match list_*")
	}
}

func TestManifest_DigestToolsAndFindExpertsToolOnly(t *testing.T) {
	all := mustManifest(t, everyCapability)
	for _, tool := range []*tools.Tool{tools.NewFindExperts(), tools.NewGetTodayBriefing(), tools.NewListDigests(), tools.NewGetDigest()} {
		expectDeny(t, nil, all, tool, `{}`, "tool:"+tool.Name)
		expectAdmit(t, nil, mustManifest(t, []string{"tool:" + tool.Name}), tool, `{}`)
	}
	// people:read still admits the people cards.
	expectAdmit(t, nil, mustManifest(t, []string{"people:read"}), tools.NewListPeople(), `{}`)
	_, err := ParseManifest([]string{"digests:read"}, nil, personalScope)
	if err == nil {
		t.Fatal("digests:read: want parse error")
	}
	for _, want := range []string{"tool:list_digests", "tool:get_digest", "tool:get_today_briefing"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q does not name %s", err, want)
		}
	}
}

func TestManifest_ScopeWhitespaceRefused(t *testing.T) {
	for _, e := range []string{"jira:read@PAY X", "gmail:read@ work", "slack:read@a\tb", "gmail:read@work\u00a0x"} {
		if _, err := ParsePermission(e); err == nil {
			t.Errorf("ParsePermission(%q): want error", e)
		}
	}
}
