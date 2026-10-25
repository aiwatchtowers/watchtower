package media

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/media/linkrule"
)

func TestOrgDomains_NoAccountsNothing(t *testing.T) {
	d := db.OpenTestDB(t)
	got, err := OrgDomains(context.Background(), d)
	require.NoError(t, err)
	assert.Empty(t, got)
}

func TestOrgDomains_FromOwnerAccounts(t *testing.T) {
	d := db.OpenTestDB(t)
	ctx := context.Background()
	_, err := d.CreateGoogleAccount(db.GoogleAccount{Email: "Alice@EU.Corp.Example", Label: "work"})
	require.NoError(t, err)
	_, err = d.CreateGoogleAccount(db.GoogleAccount{Email: "alice@gmail.com", Label: "home"}) // leak-check:allow
	require.NoError(t, err)
	_, err = d.CreateEmailAccount(db.EmailAccount{Provider: "imap", EmailAddress: "me@mail.second.example",
		Host: "imap.second.example", Port: 993, Security: "ssl", Folder: "INBOX"})
	require.NoError(t, err)
	_, err = d.CreateEmailAccount(db.EmailAccount{Provider: "outlook", EmailAddress: "me@hotmail.co.uk", // leak-check:allow
		Security: "ssl", Folder: "INBOX"})
	require.NoError(t, err)
	_, err = d.ExecContext(ctx, `INSERT INTO jira_accounts (cloud_id, site_url, owner_email, status) VALUES
		('c1', 'https://acme.atlassian.net', 'bob@jira-co.example', 'ok'),
		('c2', 'https://old.atlassian.net', 'bob@gone.example', 'removed')`)
	require.NoError(t, err)
	_, err = d.ExecContext(ctx, `INSERT INTO linear_accounts (org_id, owner_email) VALUES ('o1', 'carol@yandex.ru'), ('o2', 'carol@corp.example')`) // leak-check:allow
	require.NoError(t, err)

	got, err := OrgDomains(ctx, d)
	require.NoError(t, err)
	assert.Equal(t, []string{"corp.example", "jira-co.example", "second.example"}, got,
		"registrable domains, deduplicated; public providers and removed accounts left out")

	refused, err := RefusedHosts(ctx, d, nil)
	require.NoError(t, err)
	for _, raw := range []string{"https://corp.example/a", "https://wiki.eu.corp.example/x", "https://intranet.second.example/"} {
		_, ok := linkrule.Fetchable(raw, refused)
		assert.False(t, ok, "%s is on the owner's company domain", raw)
	}
	for _, raw := range []string{"https://gmail.com/x", "https://blog.example.net/post", "https://gone.example/"} {
		_, ok := linkrule.Fetchable(raw, refused)
		assert.True(t, ok, raw)
	}
}

func TestOrgDomain_PublicProvidersAndJunk(t *testing.T) {
	for _, addr := range []string{
		"a@gmail.com", "a@googlemail.com", "a@outlook.com", "a@live.com", "a@icloud.com", "a@proton.me", // leak-check:allow
		"a@gmx.de", "a@gmx.net", "a@yandex.ru", "a@yandex.com", "a@yahoo.co.uk", "a@mail.ru", "a@ukr.net", // leak-check:allow
		"no-at-sign", "a@", "a@localhost", "a@co.uk", // leak-check:allow
	} {
		_, ok := orgDomain(addr)
		assert.False(t, ok, addr)
	}
	d, ok := orgDomain("x@Sub.Bücher.example")
	assert.True(t, ok)
	assert.Equal(t, "xn--bcher-kva.example", d)
	d, ok = orgDomain("x@team.corp.co.uk") // leak-check:allow
	assert.True(t, ok)
	assert.Equal(t, "corp.co.uk", d)
}

func TestOrgDomain_IPLiteralIgnored(t *testing.T) {
	for _, addr := range []string{"a@1.2.3.4", "a@[::1]", "a@::1"} {
		if got, ok := orgDomain(addr); ok {
			t.Fatalf("orgDomain(%q) = %q, want no domain", addr, got)
		}
	}
}
