package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// companyFixture creates one account per company source; every account is
// left on the shared client (empty company_slug).
func companyFixture(t *testing.T, d *DB) map[string]int64 {
	t.Helper()
	ids := map[string]int64{}
	var err error
	ids["slack"], err = d.CreateSlackAccount(SlackAccount{TeamID: "T1", TeamName: "Acme"})
	require.NoError(t, err)
	ids["google"], err = d.CreateGoogleAccount(GoogleAccount{Email: "a@example.com"})
	require.NoError(t, err)
	ids["jira"], err = d.CreateJiraAccount(JiraAccount{CloudID: "c1", SiteURL: "https://acme.atlassian.net"})
	require.NoError(t, err)
	ids["linear"], err = d.CreateLinearAccount("Acme")
	require.NoError(t, err)
	ids["outlook"], err = d.CreateEmailAccount(EmailAccount{Provider: "outlook", EmailAddress: "a@example.com", Security: "ssl"})
	require.NoError(t, err)
	return ids
}

func TestCompanySlug_DefaultsEmpty(t *testing.T) {
	d := openTestDB(t)
	ids := companyFixture(t, d)

	for _, table := range []string{"slack_accounts", "google_accounts", "jira_accounts", "linear_accounts", "email_accounts"} {
		var slug string
		require.NoError(t, d.QueryRow(`SELECT company_slug FROM `+table+` LIMIT 1`).Scan(&slug), table)
		assert.Empty(t, slug, table)
	}

	s, err := d.GetSlackAccount(ids["slack"])
	require.NoError(t, err)
	assert.Empty(t, s.CompanySlug)
	g, err := d.GetGoogleAccount(ids["google"])
	require.NoError(t, err)
	assert.Empty(t, g.CompanySlug)
	j, err := d.GetJiraAccount(ids["jira"])
	require.NoError(t, err)
	assert.Empty(t, j.CompanySlug)
	assert.Equal(t, "oauth", j.AuthKind)
	assert.Empty(t, j.LastPDRAt)
	l, err := d.GetLinearAccount(ids["linear"])
	require.NoError(t, err)
	assert.Empty(t, l.CompanySlug)
	e, err := d.GetEmailAccount(ids["outlook"])
	require.NoError(t, err)
	assert.Empty(t, e.CompanySlug)
}

func TestCreateAccounts_StoreCompanySlug(t *testing.T) {
	d := openTestDB(t)

	sid, err := d.CreateSlackAccount(SlackAccount{TeamID: "T1", CompanySlug: "acme"})
	require.NoError(t, err)
	s, err := d.GetSlackAccount(sid)
	require.NoError(t, err)
	assert.Equal(t, "acme", s.CompanySlug)

	gid, err := d.CreateGoogleAccount(GoogleAccount{Email: "a@example.com", CompanySlug: "acme"})
	require.NoError(t, err)
	g, err := d.GetGoogleAccount(gid)
	require.NoError(t, err)
	assert.Equal(t, "acme", g.CompanySlug)

	lid, err := d.CreateLinearAccountForCompany("Acme", "acme")
	require.NoError(t, err)
	l, err := d.GetLinearAccount(lid)
	require.NoError(t, err)
	assert.Equal(t, "acme", l.CompanySlug)

	eid, err := d.CreateEmailAccount(EmailAccount{Provider: "outlook", EmailAddress: "a@example.com", Security: "ssl", CompanySlug: "acme"})
	require.NoError(t, err)
	e, err := d.GetEmailAccount(eid)
	require.NoError(t, err)
	assert.Equal(t, "acme", e.CompanySlug)
}

func TestCreateJiraAccount_StoresCompanyAndAuthKind(t *testing.T) {
	d := openTestDB(t)

	id, err := d.CreateJiraAccount(JiraAccount{CloudID: "c1", CompanySlug: "acme", AuthKind: "api_token"})
	require.NoError(t, err)
	a, err := d.GetJiraAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "acme", a.CompanySlug)
	assert.Equal(t, "api_token", a.AuthKind)

	// An unset AuthKind is the OAuth default, not an empty string the CHECK refuses.
	id2, err := d.CreateJiraAccount(JiraAccount{CloudID: "c2"})
	require.NoError(t, err)
	b, err := d.GetJiraAccount(id2)
	require.NoError(t, err)
	assert.Equal(t, "oauth", b.AuthKind)
}

func TestJiraAuthKind_CheckRefusesOther(t *testing.T) {
	d := openTestDB(t)

	_, err := d.CreateJiraAccount(JiraAccount{CloudID: "c1", AuthKind: "basic"})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "CHECK constraint failed")

	id, err := d.CreateJiraAccount(JiraAccount{CloudID: "c2"})
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE jira_accounts SET auth_kind = 'basic' WHERE id = ?`, id)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "CHECK constraint failed")
}

func TestSetJiraLastPDR(t *testing.T) {
	d := openTestDB(t)
	id, err := d.CreateJiraAccount(JiraAccount{CloudID: "c1"})
	require.NoError(t, err)

	require.NoError(t, d.SetJiraLastPDR(id, "2026-11-18T10:00:00Z"))
	a, err := d.GetJiraAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "2026-11-18T10:00:00Z", a.LastPDRAt)

	require.Error(t, d.SetJiraLastPDR(id+100, "2026-11-18T10:00:00Z"))
}

func TestSetAccountCompany(t *testing.T) {
	d := openTestDB(t)
	ids := companyFixture(t, d)

	for _, source := range CompanyAccountSources {
		require.NoError(t, d.SetAccountCompany(source, ids[source], "acme"), source)
	}
	refs, err := d.AccountsByCompany("acme")
	require.NoError(t, err)
	assert.Len(t, refs, len(CompanyAccountSources))

	// Clearing the tie is a write like any other.
	require.NoError(t, d.SetAccountCompany("jira", ids["jira"], ""))
	j, err := d.GetJiraAccount(ids["jira"])
	require.NoError(t, err)
	assert.Empty(t, j.CompanySlug)

	assert.Error(t, d.SetAccountCompany("teams", ids["slack"], "acme"), "unknown source")
	assert.Error(t, d.SetAccountCompany("slack", ids["slack"]+100, "acme"), "missing row")

	// An IMAP mailbox is not an Outlook account, even though both live in
	// email_accounts: it is never created with a company, nor tied to one.
	_, err = d.CreateEmailAccount(EmailAccount{Provider: "imap", EmailAddress: "c@example.com", Security: "ssl", CompanySlug: "acme"})
	assert.Error(t, err)
	imapID, err := d.CreateEmailAccount(EmailAccount{Provider: "imap", EmailAddress: "b@example.com", Host: "imap.example.com", Security: "ssl"})
	require.NoError(t, err)
	assert.Error(t, d.SetAccountCompany("outlook", imapID, "acme"))
	e, err := d.GetEmailAccount(imapID)
	require.NoError(t, err)
	assert.Empty(t, e.CompanySlug)
}

func TestAccountsByCompany(t *testing.T) {
	d := openTestDB(t)
	ids := companyFixture(t, d)

	refs, err := d.AccountsByCompany("acme")
	require.NoError(t, err)
	assert.Empty(t, refs)

	require.NoError(t, d.SetAccountCompany("jira", ids["jira"], "acme"))
	require.NoError(t, d.SetAccountCompany("slack", ids["slack"], "acme"))
	require.NoError(t, d.SetAccountCompany("google", ids["google"], "other"))
	require.NoError(t, d.SetJiraAccountAuthState(ids["jira"], "error", "invalid_client"))

	refs, err = d.AccountsByCompany("acme")
	require.NoError(t, err)
	assert.Equal(t, []CompanyAccountRef{
		{Source: "slack", ID: ids["slack"], Status: "ok", Error: ""},
		{Source: "jira", ID: ids["jira"], Status: "error", Error: "invalid_client"},
	}, refs)

	_, err = d.AccountsByCompany("")
	assert.Error(t, err, "'' is the shared client, not a company")
}

func TestMarkCompanyAccounts_OneTxOnlyThatSlug(t *testing.T) {
	d := openTestDB(t)
	acme := companyFixture(t, d)
	other := companyFixture(t, d)
	for _, source := range CompanyAccountSources {
		require.NoError(t, d.SetAccountCompany(source, acme[source], "acme"))
		require.NoError(t, d.SetAccountCompany(source, other[source], "other"))
	}
	// A second acme Slack account that is revoked: marking must not turn it
	// into 'error' (that would cancel its PURGE-01 purge clock).
	revokedID, err := d.CreateSlackAccount(SlackAccount{TeamID: "T9", CompanySlug: "acme"})
	require.NoError(t, err)
	require.NoError(t, d.SetSlackAccountAuthState(revokedID, "revoked", "token_revoked"))

	// Removed and purged rows stay as they are too.
	removedID, err := d.CreateJiraAccount(JiraAccount{CloudID: "c9", CompanySlug: "acme"})
	require.NoError(t, err)
	require.NoError(t, d.SetJiraAccountRemoved(removedID))
	purgedID, err := d.CreateGoogleAccount(GoogleAccount{Email: "p@example.com", CompanySlug: "acme"})
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE google_accounts SET status = 'purged' WHERE id = ?`, purgedID)
	require.NoError(t, err)
	// An account already in error gets the new code.
	require.NoError(t, d.SetJiraAccountAuthState(acme["jira"], "error", "invalid_client"))

	marked, err := d.MarkCompanyAccounts("acme", []string{"jira", "google"}, "company_changed_app")
	require.NoError(t, err)
	assert.Equal(t, []CompanyAccountRef{
		{Source: "google", ID: acme["google"], Status: "error", Error: "company_changed_app"},
		{Source: "jira", ID: acme["jira"], Status: "error", Error: "company_changed_app"},
	}, marked)

	refs, err := d.AccountsByCompany("acme")
	require.NoError(t, err)
	for _, r := range refs {
		switch {
		case r.Source == "jira" && r.ID == removedID:
			assert.Equal(t, "removed", r.Status)
		case r.Source == "google" && r.ID == purgedID:
			assert.Equal(t, "purged", r.Status)
		case r.Source == "slack" && r.ID == revokedID:
			assert.Equal(t, "revoked", r.Status)
		case r.Source == "google" || r.Source == "jira":
			assert.Equal(t, "error", r.Status, r.Source)
			assert.Equal(t, "company_changed_app", r.Error, r.Source)
		default:
			assert.Equal(t, "ok", r.Status, r.Source)
		}
	}
	others, err := d.AccountsByCompany("other")
	require.NoError(t, err)
	for _, r := range others {
		assert.Equal(t, "ok", r.Status, "another company's %s account", r.Source)
	}

	// "outlook" marks Outlook rows only, never an IMAP mailbox in the same table.
	imapID, err := d.CreateEmailAccount(EmailAccount{Provider: "imap", EmailAddress: "i@example.com", Host: "imap.example.com", Security: "ssl"})
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE email_accounts SET company_slug = 'acme' WHERE id = ?`, imapID)
	require.NoError(t, err)
	marked, err = d.MarkCompanyAccounts("acme", []string{"outlook"}, "company_changed_app")
	require.NoError(t, err)
	assert.Equal(t, []CompanyAccountRef{{Source: "outlook", ID: acme["outlook"], Status: "error", Error: "company_changed_app"}}, marked)
	imap, err := d.GetEmailAccount(imapID)
	require.NoError(t, err)
	assert.Equal(t, "ok", imap.Status)

	// All or nothing: an unknown source anywhere in the list marks nothing.
	_, err = d.MarkCompanyAccounts("acme", []string{"slack", "teams"}, "company_changed_app")
	require.Error(t, err)
	s, err := d.GetSlackAccount(acme["slack"])
	require.NoError(t, err)
	assert.Equal(t, "ok", s.Status)

	_, err = d.MarkCompanyAccounts("", []string{"slack"}, "company_changed_app")
	assert.Error(t, err, "an empty slug would mark every shared-client account")
	_, err = d.MarkCompanyAccounts("acme", []string{"slack"}, "")
	assert.Error(t, err)
}

// Every purge source is a company source, so a new account table added to one
// map cannot be forgotten in the other.
func TestCompanyAccountSources_CoverPurgeSources(t *testing.T) {
	for source, table := range accountTables {
		assert.Contains(t, CompanyAccountSources, source)
		assert.Equal(t, table, companyAccountTables[source].table, source)
	}
	assert.Len(t, companyAccountTables, len(CompanyAccountSources))
}
