package cmd

import (
	"bytes"
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

// TestJiraAddLogin_ReportScopeRefusalKeepsConfluence: a company app without
// the report permission refuses the scope; the retry drops only that scope,
// so an app with the Confluence API still connects Confluence.
func TestJiraAddLogin_ReportScopeRefusalKeepsConfluence(t *testing.T) {
	calls := scriptLogin(t, errTestScopeRefused, nil)
	_, err := jiraAddLogin(context.Background(), jira.JiraOAuthConfig{}, io.Discard, jira.LoginOptions{WithConfluence: true, WithPersonalDataReporting: true})
	require.NoError(t, err)
	require.Len(t, *calls, 2)
	assert.False(t, (*calls)[1].WithPersonalDataReporting)
	assert.True(t, (*calls)[1].WithConfluence)
}

// An app with neither permission ends Jira-only, as before.
func TestJiraAddLogin_ReportAndConfluenceRefusedEndsJiraOnly(t *testing.T) {
	calls := scriptLogin(t, errTestScopeRefused, errTestScopeRefused, nil)
	var out bytes.Buffer
	_, err := jiraAddLogin(context.Background(), jira.JiraOAuthConfig{}, &out, jira.LoginOptions{WithConfluence: true, WithPersonalDataReporting: true})
	require.NoError(t, err)
	require.Len(t, *calls, 3)
	assert.False(t, (*calls)[2].WithConfluence)
	assert.False(t, (*calls)[2].WithPersonalDataReporting)
	assert.Contains(t, out.String(), jiraOnlyRetryMarker)
}

// A company account's Re-login uses the same report-scope fallback.
func TestJiraLoginWithoutRefusedReport_RetriesOnlyThatScope(t *testing.T) {
	calls := scriptLogin(t, errTestScopeRefused, nil)
	_, err := jiraLoginWithoutRefusedReport(context.Background(), jira.JiraOAuthConfig{}, io.Discard, jira.LoginOptions{WithConfluence: true, WithPersonalDataReporting: true})
	require.NoError(t, err)
	require.Len(t, *calls, 2)
	assert.Equal(t, jira.LoginOptions{WithConfluence: true}, (*calls)[1])

	calls = scriptLogin(t, errTestScopeRefused)
	_, err = jiraLoginWithoutRefusedReport(context.Background(), jira.JiraOAuthConfig{}, io.Discard, jira.LoginOptions{WithConfluence: true})
	require.ErrorIs(t, err, jira.ErrScopeRefused)
	assert.Len(t, *calls, 1, "nothing to drop without the report scope")
}
