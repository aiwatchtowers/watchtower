package automations

import (
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/tools"
)

func TestManifest_LinearCapability(t *testing.T) {
	m, err := ParseManifest([]string{"linear:read@eng"}, nil, personalScope)
	if err != nil {
		t.Fatalf("linear:read@eng: %v", err)
	}
	if got := m.entries[0].String(); got != "linear:read@ENG" {
		t.Errorf("normalised = %q, want linear:read@ENG", got)
	}
	if _, err := ParseManifest([]string{"linear:read"}, nil, personalScope); err == nil {
		t.Error("linear:read without a scope: want parse error")
	}
	if _, err := ParseManifest([]string{"linear:read@<TEAM>"}, nil, personalScope); err == nil {
		t.Error("linear:read@<TEAM>: want parse error")
	}
}

func TestLinearScope_MovedIssueUsesCurrentTeam(t *testing.T) {
	d := openManifestTestDB(t)
	acct, err := d.CreateLinearAccount("acme")
	if err != nil {
		t.Fatal(err)
	}
	if err := d.UpsertLinearIssue(db.LinearIssue{AccountID: acct, ID: "i1", Key: "NEW-4", PreviousKeys: []string{"OLD-1"},
		TeamID: "t-new", TeamKey: "NEW", Title: "moved"}); err != nil {
		t.Fatal(err)
	}
	newTeam := mustManifest(t, []string{"linear:read@new"})
	oldTeam := mustManifest(t, []string{"linear:read@old"})
	get := tools.NewGetLinearIssue()
	expectAdmit(t, d, newTeam, get, `{"key":"OLD-1"}`)
	expectAdmit(t, d, newTeam, get, `{"key":"new-4"}`)
	expectDeny(t, d, oldTeam, get, `{"key":"OLD-1"}`, "linear:read@NEW")
	// A key absent from the mirror falls back to its prefix.
	abc := mustManifest(t, []string{"linear:read@ABC"})
	expectAdmit(t, d, abc, get, `{"key":"ABC-9"}`)
	expectDeny(t, d, newTeam, get, `{"key":"ABC-9"}`, "linear:read@ABC")

	hist := tools.NewGetLinearStatusHistory()
	expectAdmit(t, d, newTeam, hist, `{"keys":["OLD-1","NEW-4"]}`)
	expectDeny(t, d, newTeam, hist, `{"keys":["OLD-1","ABC-9"]}`, "linear:read@ABC")
}

func TestLinearScope_TeamArgsAndTeamsList(t *testing.T) {
	d := openManifestTestDB(t)
	eng := mustManifest(t, []string{"linear:read@ENG"})
	expectAdmit(t, d, eng, tools.NewListLinearIssues(), `{"team":"eng"}`)
	expectAdmit(t, d, eng, tools.NewListLinearCycles(), `{"team":"ENG"}`)
	expectDeny(t, d, eng, tools.NewListLinearIssues(), `{"team":"OPS"}`, "linear:read@OPS")
	expectDeny(t, d, eng, tools.NewListLinearIssues(), `{}`, "linear:read@*")
	expectDeny(t, d, eng, tools.NewListLinearIssues(), `{"team":"ENG","TEAM":"OPS"}`, "linear:read@*")
	expectDeny(t, d, eng, tools.NewListLinearTeams(), `{}`, "linear:read@*")
	expectAdmit(t, d, mustManifest(t, []string{"linear:read@*"}), tools.NewListLinearTeams(), `{}`)
}

func TestLinearScope_RowsWithoutTeamKeyAreAbsentScope(t *testing.T) {
	d := openManifestTestDB(t)
	acct, err := d.CreateLinearAccount("acme")
	if err != nil {
		t.Fatal(err)
	}
	if err := d.UpsertLinearIssue(db.LinearIssue{AccountID: acct, ID: "i1", Key: "ENG-1", Title: "no team"}); err != nil {
		t.Fatal(err)
	}
	get := tools.NewGetLinearIssue()
	expectDeny(t, d, mustManifest(t, []string{"linear:read@ENG"}), get, `{"key":"ENG-1"}`, "linear:read@*")
	expectAdmit(t, d, mustManifest(t, []string{"linear:read@*"}), get, `{"key":"ENG-1"}`)
}
