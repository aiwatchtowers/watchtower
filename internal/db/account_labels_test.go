package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// must fails the test on a read error, so a zero struct never passes an
// empty-label assertion by accident.
func must[T any](v T, err error) func(*testing.T) T {
	return func(t *testing.T) T {
		t.Helper()
		require.NoError(t, err)
		return v
	}
}

func TestSlackAccountLabel(t *testing.T) {
	assert.Equal(t, "Acme Corp", SlackAccountLabel("  Acme Corp ", "acme"))
	assert.Equal(t, "acme", SlackAccountLabel("", "Acme"), "no team name falls back to the domain")
	assert.Equal(t, "acme", SlackAccountLabel("   ", " acme "))
	assert.Equal(t, "", SlackAccountLabel("", ""))
}

func TestJiraAccountLabel(t *testing.T) {
	assert.Equal(t, "acme", JiraAccountLabel("https://acme.atlassian.net", "Acme"))
	assert.Equal(t, "acme", JiraAccountLabel("https://ACME.Atlassian.NET/", ""), "host is lowercased before the suffix is cut")
	assert.Equal(t, "acme", JiraAccountLabel("acme.atlassian.net", ""), "a URL without a scheme still yields its host")
	assert.Equal(t, "jira.example.com", JiraAccountLabel("https://jira.example.com/jira", ""), "a custom domain stays whole")
	assert.Equal(t, "Acme Site", JiraAccountLabel("", " Acme Site "))
	assert.Equal(t, "Acme", JiraAccountLabel("https://.atlassian.net", "Acme"), "an empty site part falls back to the name")
	assert.Equal(t, "", JiraAccountLabel("", ""))
}

func TestMailAccountLabel(t *testing.T) {
	assert.Equal(t, "example.com", MailAccountLabel("colleague-a@example.com", ""))
	assert.Equal(t, "example.com", MailAccountLabel("Colleague-A@EXAMPLE.COM.", ""), "domain lowercased, trailing dot dropped")
	assert.Equal(t, "someone@gmail.com", MailAccountLabel("someone@GMail.com", ""), "a public domain names the whole address") // leak-check:allow
	assert.Equal(t, "someone@outlook.com", MailAccountLabel("someone@outlook.com", "")) // leak-check:allow
	assert.Equal(t, "пример.рф", MailAccountLabel("user@xn--e1afmkfd.xn--p1ai", ""), "an IDN domain shows in Unicode") // leak-check:allow
	assert.Equal(t, "пример.рф", MailAccountLabel("user@ПРИМЕР.РФ", ""), "a Unicode domain is lowercased") // leak-check:allow
	assert.Equal(t, "example.com", MailAccountLabel("a@b@example.com", ""), "the last @ splits the domain")
	assert.Equal(t, "imap.example.com", MailAccountLabel("login-name", "IMAP.example.com"), "no address falls back to the host")
	assert.Equal(t, "imap.example.com", MailAccountLabel("user@", "imap.example.com"))
	assert.Equal(t, "", MailAccountLabel("@example.com", ""), "no local part is not an address")
	assert.Equal(t, "", MailAccountLabel("", ""))
}

func TestCalendarAccountLabels(t *testing.T) {
	assert.Equal(t, "caldav.example.com", CalDAVAccountLabel("https://CalDAV.example.com:8443/dav/", "user"))
	assert.Equal(t, "example.com", CalDAVAccountLabel("https://www.example.com", "user"), "www. is dropped")
	assert.Equal(t, "user", CalDAVAccountLabel("", " user "))
	assert.Equal(t, "", CalDAVAccountLabel("", ""))

	assert.Equal(t, "Team calendar", ICSAccountLabel(" Team calendar ", "https://cal.example.com/secret/basic.ics"))
	assert.Equal(t, "cal.example.com", ICSAccountLabel("", "https://cal.example.com/secret/basic.ics"), "only the host of the secret URL")
	assert.Equal(t, "", ICSAccountLabel("", ""))
	assert.Equal(t, "", ICSAccountLabel("", "::not a url"))
}

func TestUniqueAccountLabel(t *testing.T) {
	assert.Equal(t, "acme", UniqueAccountLabel("acme", nil))
	assert.Equal(t, "acme 2", UniqueAccountLabel("acme", []string{"ACME"}), "clash is case-insensitive")
	assert.Equal(t, "acme 3", UniqueAccountLabel("acme", []string{"acme", "acme 2", "other"}))
	assert.Equal(t, "acme", UniqueAccountLabel(" acme ", []string{"acme 2"}))
	assert.Equal(t, "", UniqueAccountLabel("  ", []string{""}), "an empty base stays empty")
}

func TestAccountLabel_FilledAtConnectWithClashSuffix(t *testing.T) {
	d := openTestDB(t)

	s1, err := d.CreateSlackAccount(SlackAccount{})
	require.NoError(t, err)
	s2, err := d.CreateSlackAccount(SlackAccount{})
	require.NoError(t, err)
	require.NoError(t, d.UpdateSlackAccountConnection(s1, "T1", "Acme", "acme", "1:U1"))
	require.NoError(t, d.UpdateSlackAccountConnection(s2, "T2", "Acme", "acme-eu", "2:U1"))
	a1 := must(d.GetSlackAccount(s1))(t)
	a2 := must(d.GetSlackAccount(s2))(t)
	assert.Equal(t, "Acme", a1.Label)
	assert.Equal(t, "Acme 2", a2.Label)

	// A later resolve (every sync) keeps the label, even after a team rename.
	require.NoError(t, d.UpdateSlackAccountConnection(s1, "T1", "Acme Renamed", "acme", "1:U1"))
	a1 = must(d.GetSlackAccount(s1))(t)
	assert.Equal(t, "Acme", a1.Label)

	// An owner-given label is never replaced.
	s3, err := d.CreateSlackAccount(SlackAccount{Label: "Community"})
	require.NoError(t, err)
	require.NoError(t, d.UpdateSlackAccountConnection(s3, "T3", "Beta", "beta", "3:U1"))
	a3 := must(d.GetSlackAccount(s3))(t)
	assert.Equal(t, "Community", a3.Label)

	// No team name or domain yet: the label stays empty for the display fallback.
	s4, err := d.CreateSlackAccount(SlackAccount{})
	require.NoError(t, err)
	require.NoError(t, d.UpdateSlackAccountConnection(s4, "", "", "", ""))
	a4 := must(d.GetSlackAccount(s4))(t)
	assert.Equal(t, "", a4.Label)
}

func TestAccountLabel_RemovedAccountDoesNotBlockTheName(t *testing.T) {
	d := openTestDB(t)

	j1, err := d.CreateJiraAccount(JiraAccount{})
	require.NoError(t, err)
	require.NoError(t, d.UpdateJiraAccountConnection(j1, "c1", "https://acme.atlassian.net", "Acme"))
	require.NoError(t, d.SetJiraAccountRemoved(j1))

	j2, err := d.CreateJiraAccount(JiraAccount{})
	require.NoError(t, err)
	require.NoError(t, d.UpdateJiraAccountConnection(j2, "c1", "https://acme.atlassian.net", "Acme"))
	a2 := must(d.GetJiraAccount(j2))(t)
	assert.Equal(t, "acme", a2.Label)
}

func TestAccountLabel_GoogleEmailAndCalendar(t *testing.T) {
	d := openTestDB(t)

	g1, err := d.CreateGoogleAccount(GoogleAccount{})
	require.NoError(t, err)
	require.NoError(t, d.UpdateGoogleAccountConnection(g1, "someone@gmail.com", true, false)) // leak-check:allow
	g := must(d.GetGoogleAccount(g1))(t)
	assert.Equal(t, "someone@gmail.com", g.Label) // leak-check:allow

	// Clashes are per kind: a mailbox may share a Google account's name.
	e1, err := d.CreateEmailAccount(EmailAccount{Provider: "outlook", EmailAddress: "a@example.com", Host: "outlook.office365.com", Security: "ssl"})
	require.NoError(t, err)
	e2, err := d.CreateEmailAccount(EmailAccount{Provider: "imap", EmailAddress: "b@Example.com", Host: "imap.example.com", Security: "ssl"})
	require.NoError(t, err)
	m1 := must(d.GetEmailAccount(e1))(t)
	m2 := must(d.GetEmailAccount(e2))(t)
	assert.Equal(t, "example.com", m1.Label)
	assert.Equal(t, "example.com 2", m2.Label)

	c1, err := d.CreateCalendarAccount(CalendarAccount{Provider: "caldav", Username: "u", URL: "https://dav.example.com/"})
	require.NoError(t, err)
	c2, err := d.CreateCalendarAccount(CalendarAccount{Provider: "ics", LabelHint: "dav.example.com"})
	require.NoError(t, err)
	c3, err := d.CreateCalendarAccount(CalendarAccount{Provider: "ics", Label: "Mine", LabelHint: "ignored"})
	require.NoError(t, err)
	ca1 := must(d.GetCalendarAccount(c1))(t)
	ca2 := must(d.GetCalendarAccount(c2))(t)
	ca3 := must(d.GetCalendarAccount(c3))(t)
	assert.Equal(t, "dav.example.com", ca1.Label)
	assert.Equal(t, "dav.example.com 2", ca2.Label)
	assert.Equal(t, "Mine", ca3.Label)
}

func TestFillEmptyAccountLabels_BackfillsOldestFirstAndIsIdempotent(t *testing.T) {
	d := openTestDB(t)

	// Rows as an install from before automatic labels has them.
	_, err := d.Exec(`INSERT INTO slack_accounts (team_id, team_name, team_domain) VALUES
        ('T1','Acme','acme'), ('T2','Acme','acme2'), ('T3','Gone','gone')`)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE slack_accounts SET status = 'removed' WHERE team_id = 'T3'`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO jira_accounts (cloud_id, site_url, site_name, label) VALUES
        ('c0','https://other.atlassian.net','Other','acme'),
        ('c1','https://acme.atlassian.net','Acme',''), ('c2','https://beta.atlassian.net','Beta','Client')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO google_accounts (email) VALUES ('a@example.com'), ('')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO email_accounts (provider, email_address, host) VALUES ('imap','login','imap.example.com')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO calendar_accounts (provider, username, url) VALUES ('caldav','u','https://dav.example.com'), ('ics','','')`)
	require.NoError(t, err)

	require.NoError(t, d.FillEmptyAccountLabels())
	require.NoError(t, d.FillEmptyAccountLabels(), "a second run changes nothing")

	labels := func(table string) []string {
		rows, err := d.Query(`SELECT label FROM ` + table + ` ORDER BY id`)
		require.NoError(t, err)
		defer rows.Close()
		var out []string
		for rows.Next() {
			var l string
			require.NoError(t, rows.Scan(&l))
			out = append(out, l)
		}
		require.NoError(t, rows.Err())
		return out
	}
	assert.Equal(t, []string{"Acme", "Acme 2", ""}, labels("slack_accounts"), "a removed workspace is left alone")
	assert.Equal(t, []string{"acme", "acme 2", "Client"}, labels("jira_accounts"), "a name the owner already gave another site is not reused")
	assert.Equal(t, []string{"example.com", ""}, labels("google_accounts"), "a never-consented row has nothing to name it by")
	assert.Equal(t, []string{"imap.example.com"}, labels("email_accounts"))
	assert.Equal(t, []string{"dav.example.com", ""}, labels("calendar_accounts"), "an old ICS feed has no name in the database")
}

func TestFillEmptyAccountLabels_NoAccounts(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, d.FillEmptyAccountLabels())
}

func TestRenameAccount(t *testing.T) {
	d := openTestDB(t)
	id, err := d.CreateSlackAccount(SlackAccount{})
	require.NoError(t, err)
	require.NoError(t, d.UpdateSlackAccountConnection(id, "T1", "Acme", "acme", "1:U1"))

	require.NoError(t, d.RenameAccount("slack_accounts", id, "  Work "))
	a := must(d.GetSlackAccount(id))(t)
	assert.Equal(t, "Work", a.Label)

	require.Error(t, d.RenameAccount("slack_accounts", id, "   "), "an empty name is refused")
	a = must(d.GetSlackAccount(id))(t)
	assert.Equal(t, "Work", a.Label)

	require.Error(t, d.RenameAccount("slack_accounts", 999, "X"), "a missing account is an error")
	require.Error(t, d.RenameAccount("users", id, "X"), "only account tables")
}
