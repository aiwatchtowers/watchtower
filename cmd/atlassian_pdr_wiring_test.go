package cmd

import (
	"context"
	"io"
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/jira"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestAtlassianPDRAccounts_SharedAppAccountsRunToo: every account with a
// client reports, the shared app's included; one without a client does not.
func TestAtlassianPDRAccounts_SharedAppAccountsRunToo(t *testing.T) {
	accounts := []db.JiraAccount{
		{ID: 1, CompanySlug: ""},
		{ID: 2, CompanySlug: "acme"},
		{ID: 3, CompanySlug: "acme"},
	}
	c := &jira.Client{}
	clients := map[int64]*jira.Client{1: c, 2: c}
	var ids []int64
	for _, a := range atlassianPDRAccounts(accounts, clients) {
		ids = append(ids, a.ID)
	}
	assert.Equal(t, []int64{1, 2}, ids)
}

// TestJiraAdd_CompanyRequestsTheReportScope: a company's app has the report
// permission, so its grant asks for the scope Personal Data Reporting needs;
// another app is never asked (it would refuse the whole grant).
func TestJiraAdd_CompanyRequestsTheReportScope(t *testing.T) {
	h := newJiraAddHarness(t, nil)
	saveCompany(t, h.cfg.WorkspaceDir(), companySample("Acme"))
	cmd, out := newJiraAddCmd(t, map[string]string{"company": "acme"})
	require.NoError(t, runJiraAdd(cmd, nil), out.String())
	assert.True(t, h.loginOpts.WithPersonalDataReporting)

	t.Setenv("WATCHTOWER_JIRA_CLIENT_ID", "env-id")
	cmd, out = newJiraAddCmd(t, map[string]string{"company": "", "site": "acme"})
	require.NoError(t, runJiraAdd(cmd, nil), out.String())
	assert.False(t, h.loginOpts.WithPersonalDataReporting)
}

// TestJiraAddLogin_ReportScopeRefusalRetriesJiraOnly: a company app without
// the report permission refuses the scope; the connect still succeeds.
func TestJiraAddLogin_ReportScopeRefusalRetriesJiraOnly(t *testing.T) {
	calls := scriptLogin(t, errTestScopeRefused, nil)
	_, err := jiraAddLogin(context.Background(), jira.JiraOAuthConfig{}, io.Discard, jira.LoginOptions{WithPersonalDataReporting: true})
	require.NoError(t, err)
	require.Len(t, *calls, 2)
	assert.False(t, (*calls)[1].WithPersonalDataReporting)
}
