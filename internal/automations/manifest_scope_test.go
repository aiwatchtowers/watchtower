package automations

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
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

func TestManifest_JiraProjectGrantCoversLinkedData(t *testing.T) {
	// Owner, ask #287: a project grant covers what the tool returns with that
	// project's issues, linked issues of other projects included.
	d := openManifestTestDB(t)
	acct := db.SeedTestJiraAccount(t, d)
	seedJiraIssue(t, d, acct, "PAY-1", "PAY",
		`{"key":"PAY-1","fields":{"issuelinks":[{"id":"1","outwardIssue":{"key":"OPS-9"}}],"parent":{"key":"EPC-3"}}}`)
	seedJiraIssue(t, d, acct, "PAY-3", "PAY", `not json`)
	pay := mustManifest(t, []string{"jira:read@PAY"})
	expectAdmit(t, d, pay, tools.NewGetJiraIssue(), `{"key":"PAY-1"}`)
	expectAdmit(t, d, pay, tools.NewGetJiraIssue(), `{"key":"PAY-3"}`)
	expectAdmit(t, d, pay, tools.NewListJiraIssues(), `{"project":"PAY"}`)
	tis := tools.NewGetJiraTimeInStatus()
	for _, args := range []string{`{"project":"PAY"}`, `{"project":"PAY","include_linked":true}`, `{"issue_keys":["PAY-1"]}`} {
		expectAdmit(t, d, pay, tis, args)
	}
	expectDeny(t, d, pay, tis, `{"issue_keys":["PAY-1","OPS-9"]}`, "jira:read@OPS")
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
	if errors.Unwrap(err) != pd.Cause { //nolint:errorlint // asserts Unwrap returns the cause itself, not a wrapper of it
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

func TestManifest_DigestsAndFindExpertsByCapability(t *testing.T) {
	digests := mustManifest(t, []string{"digests:read"})
	for _, tool := range []*tools.Tool{tools.NewGetTodayBriefing(), tools.NewListDigests(), tools.NewGetDigest()} {
		expectAdmit(t, nil, digests, tool, `{}`)
		expectDeny(t, nil, mustManifest(t, []string{"people:read"}), tool, `{}`, "digests:read")
	}
	people := mustManifest(t, []string{"people:read"})
	for _, tool := range []*tools.Tool{tools.NewFindExperts(), tools.NewListPeople(), tools.NewGetPerson()} {
		expectAdmit(t, nil, people, tool, `{}`)
	}
	expectDeny(t, nil, digests, tools.NewFindExperts(), `{}`, "people:read")
}

func TestManifest_ScopeWhitespaceRefused(t *testing.T) {
	for _, e := range []string{"jira:read@PAY X", "gmail:read@ work", "slack:read@a\tb", "gmail:read@work\u00a0x"} {
		if _, err := ParsePermission(e); err == nil {
			t.Errorf("ParsePermission(%q): want error", e)
		}
	}
}
