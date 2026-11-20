package media

import (
	"bytes"
	"context"
	"log"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/company"
	"watchtower/internal/companybundle"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/media/linkrule"
)

// fetchable reports whether Fetchable accepts raw against refused.
func fetchable(raw string, refused map[string]bool) bool {
	_, ok := linkrule.Fetchable(raw, refused)
	return ok
}

// TestDenyHosts_BundleOnlyAdds pins D18: a company bundle's deny hosts join
// the refused set, and a bundle can never take a host off it.
func TestDenyHosts_BundleOnlyAdds(t *testing.T) {
	prev := BuildDenyHosts
	BuildDenyHosts = "seed.example"
	t.Cleanup(func() { BuildDenyHosts = prev })
	cfg := &config.Config{Knowledge: config.KnowledgeConfig{LinkFetchDenyHosts: []string{"cfg.example"}}}

	base := DenyHosts(cfg, nil)
	assert.Equal(t, []string{"seed.example", "cfg.example"}, base)
	assert.Equal(t, base, DenyHosts(cfg, []companybundle.Bundle{}), "an empty bundle list changes nothing")
	assert.Equal(t, base, DenyHosts(cfg, []companybundle.Bundle{{V: 1, Company: "Acme"}}), "a bundle without a deny list changes nothing")

	acme := companybundle.Bundle{V: 1, Company: "Acme", LinkDenyHosts: []string{"intranet.example.com", "cfg.example"}}
	other := companybundle.Bundle{V: 1, Company: "Other", LinkDenyHosts: []string{"wiki.other.example"}}
	got := DenyHosts(cfg, []companybundle.Bundle{acme, other})
	assert.Subset(t, got, base, "a bundle never drops the seed or the config list")
	set := linkrule.NormalizeHostSet(got)
	for _, raw := range []string{
		"https://intranet.example.com/a", "https://docs.intranet.example.com/", "https://wiki.other.example/p",
		"https://seed.example/", "https://cfg.example/", "https://x.cfg.example/",
	} {
		assert.False(t, fetchable(raw, set), "%s must be refused", raw)
	}
	assert.True(t, fetchable("https://example.com/post", set), "a bundle refuses only its own hosts")
}

// TestDenyHosts_InvalidPunycodeKeptRefused: a deny host that companybundle
// accepts but IDNA refuses (an invalid xn-- label) stays in the refused set as
// given instead of being dropped, and no link on or under it is fetched.
func TestDenyHosts_InvalidPunycodeKeptRefused(t *testing.T) {
	b, err := companybundle.ParseJSON([]byte(`{"v":1,"company":"Acme","link_deny_hosts":["xn--a.example.com"]}`), companybundle.OriginLink)
	require.NoError(t, err)
	set := linkrule.NormalizeHostSet(DenyHosts(nil, []companybundle.Bundle{b}))
	assert.True(t, set["xn--a.example.com"], "kept refused as given: %v", set)
	for _, raw := range []string{"https://xn--a.example.com/", "https://www.xn--a.example.com/x"} {
		assert.False(t, fetchable(raw, set), raw)
	}
	assert.True(t, fetchable("https://example.com/", set), "the parent domain is not refused by it")
}

// writeCompany stores b as a confirmed company under ws.
func writeCompany(t *testing.T, ws string, b companybundle.Bundle) {
	t.Helper()
	s := company.NewStore(ws)
	slug, err := s.SlugFor(b.Company, "")
	require.NoError(t, err)
	require.NoError(t, s.Save(slug, b))
}

func TestRefusedHosts_IncludesForcedBundleHosts(t *testing.T) {
	d := db.OpenTestDB(t)
	ws := t.TempDir()
	writeCompany(t, ws, companybundle.Bundle{V: 1, Company: "Acme", LinkDenyHosts: []string{"stored.example.com"}})
	forcedAcme, err := companybundle.Encode(companybundle.Bundle{V: 1, Company: "Acme", LinkDenyHosts: []string{"forced.example.com"}})
	require.NoError(t, err)
	forcedOther, err := companybundle.Encode(companybundle.Bundle{V: 1, Company: "Globex", LinkDenyHosts: []string{"globex.example.org"}})
	require.NoError(t, err)
	var logs bytes.Buffer
	cfg := &config.Config{Knowledge: config.KnowledgeConfig{LinkFetchDenyHosts: []string{"cfg.example"}}}

	for _, c := range []struct {
		name, forced string
		refused      []string
		fetched      []string
	}{
		{"no forced bundle", "", []string{"https://stored.example.com/", "https://cfg.example/"}, []string{"https://forced.example.com/"}},
		// Deny hosts only add: a forced bundle of the same company joins the
		// stored file's list, it never takes a host off it.
		{"forced same company", forcedAcme, []string{"https://forced.example.com/", "https://stored.example.com/", "https://cfg.example/"}, nil},
		{"forced other company", forcedOther, []string{"https://globex.example.org/", "https://stored.example.com/", "https://cfg.example/"}, nil},
	} {
		t.Run(c.name, func(t *testing.T) {
			src := DenySource(cfg, ws, func() string { return c.forced }, log.New(&logs, "", 0))
			refused, err := RefusedHosts(context.Background(), d, src())
			require.NoError(t, err)
			for _, raw := range c.refused {
				assert.False(t, fetchable(raw, refused), "%s must be refused", raw)
			}
			for _, raw := range c.fetched {
				assert.True(t, fetchable(raw, refused), raw)
			}
		})
	}
	assert.Empty(t, logs.String())
}

// TestDenyHosts_ForcedSurvivesUnreadableCompanyDir: a company directory that
// cannot be read (here a file in its place) costs the stored bundles, never
// the forced MDM bundle's deny hosts.
func TestDenyHosts_ForcedSurvivesUnreadableCompanyDir(t *testing.T) {
	ws := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(ws, "company"), []byte("x"), 0o600))
	forced, err := companybundle.Encode(companybundle.Bundle{V: 1, Company: "Acme", LinkDenyHosts: []string{"forced.example.com"}})
	require.NoError(t, err)
	var logs bytes.Buffer
	src := DenySource(nil, ws, func() string { return forced }, log.New(&logs, "", 0))

	assert.Equal(t, []string{"forced.example.com"}, src())
	assert.Contains(t, logs.String(), "company directory")
}

func TestDenySource_ReadsCompaniesAfresh(t *testing.T) {
	ws := t.TempDir()
	src := DenySource(nil, ws, nil, log.New(&bytes.Buffer{}, "", 0))
	assert.NotContains(t, src(), "later.example.com")
	writeCompany(t, ws, companybundle.Bundle{V: 1, Company: "Acme", LinkDenyHosts: []string{"later.example.com"}})
	assert.Contains(t, src(), "later.example.com", "a company confirmed after the source was built applies at the next read")
}

func TestDenyHosts_DamagedBundleAddsNothing(t *testing.T) {
	ws := t.TempDir()
	writeCompany(t, ws, companybundle.Bundle{V: 1, Company: "Acme", LinkDenyHosts: []string{"good.example.com"}})
	dir := filepath.Join(ws, "company")
	require.NoError(t, os.WriteFile(filepath.Join(dir, "broken.json"), []byte(`{"v":1,"company":"Broken","link_deny_hosts":["*"]}`), 0o600))
	var logs bytes.Buffer
	src := DenySource(nil, ws, func() string { return "not-a-bundle" }, log.New(&logs, "", 0))

	assert.Equal(t, []string{"good.example.com"}, src(), "the damaged file and forced bundle add nothing; the good file still does")
	assert.Contains(t, logs.String(), "broken.json")
	assert.Contains(t, logs.String(), "CompanyBundle")
	first := logs.String()
	src()
	assert.Equal(t, first, logs.String(), "a load problem that stays is logged once, not at every read")

	require.NoError(t, os.WriteFile(filepath.Join(dir, "broken.json"), []byte(`{`), 0o600))
	src()
	assert.NotEqual(t, first, logs.String(), "a changed load problem is logged again")
}

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
