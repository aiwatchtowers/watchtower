package cmd

import (
	"testing"

	"watchtower/internal/db"
	"watchtower/internal/jira"

	"github.com/stretchr/testify/assert"
)

// TestPDR_SharedAppAccountsRunToo (wiring): every account with an OAuth
// client reports, the shared app's included; an API-token account and an
// account without a client do not.
func TestAtlassianPDRAccounts_SharedAppAccountsRunToo(t *testing.T) {
	accounts := []db.JiraAccount{
		{ID: 1, CompanySlug: "", AuthKind: "oauth"},
		{ID: 2, CompanySlug: "acme", AuthKind: "oauth"},
		{ID: 3, CompanySlug: "acme", AuthKind: "api_token"},
		{ID: 4, CompanySlug: "acme", AuthKind: "oauth"},
	}
	c := &jira.Client{}
	clients := map[int64]*jira.Client{1: c, 2: c, 3: c}
	var ids []int64
	for _, a := range atlassianPDRAccounts(accounts, clients) {
		ids = append(ids, a.ID)
	}
	assert.Equal(t, []int64{1, 2}, ids)
}
