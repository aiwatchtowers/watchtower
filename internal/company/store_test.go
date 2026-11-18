package company

import (
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/companybundle"
)

// sample is a full bundle of made-up ids for company.
func sample(company string) companybundle.Bundle {
	return companybundle.Bundle{
		V: 1, Company: company,
		Slack:     &companybundle.Slack{TeamID: "T0000", ClientID: "000.000"},
		Google:    &companybundle.Google{ClientID: "1234-abcd.apps.googleusercontent.com", ClientSecret: "sample-secret", Domain: "example.com"},
		Atlassian: &companybundle.Atlassian{ClientID: "acmeClientId01", ClientSecret: "acme-secret", Site: "https://acme.atlassian.net", Confluence: true},
		Linear:    &companybundle.Linear{ClientID: "acmelinear01"},
		Microsoft: &companybundle.Microsoft{ClientID: "00000000-0000-0000-0000-000000000001", TenantID: "00000000-0000-0000-0000-0000000000aa"},
	}
}

func wire(t *testing.T, b companybundle.Bundle) string {
	t.Helper()
	w, err := companybundle.Encode(b)
	require.NoError(t, err)
	return w
}

func newStore(t *testing.T) Store { return NewStore(t.TempDir()) }

func TestCompanyStore_ModesAndRoundTrip(t *testing.T) {
	s := newStore(t)
	b := sample("Acme")
	require.NoError(t, s.Save("acme", b))

	di, err := os.Stat(s.Dir)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o700), di.Mode().Perm())
	fi, err := os.Stat(filepath.Join(s.Dir, "acme.json"))
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), fi.Mode().Perm())

	got, ok, err := s.Get("acme", "")
	require.NoError(t, err)
	require.True(t, ok)
	assert.Equal(t, Entry{Slug: "acme", Bundle: b}, got)

	// A personal bundle is a stored file's to carry.
	p := companybundle.Bundle{V: 1, Company: "Me", Personal: true, Google: sample("Me").Google}
	require.NoError(t, s.Save("me", p))
	got, ok, err = s.Get("me", "")
	require.NoError(t, err)
	require.True(t, ok)
	assert.True(t, got.Bundle.Personal)
}

func TestCompanyStore_DirNarrowed(t *testing.T) {
	s := newStore(t)
	require.NoError(t, os.MkdirAll(s.Dir, 0o755)) //nolint:gosec // the test widens it on purpose
	require.NoError(t, s.Save("acme", sample("Acme")))
	di, err := os.Stat(s.Dir)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o700), di.Mode().Perm())
}

func TestSlug_ClashGetsSuffix(t *testing.T) {
	s := newStore(t)
	for i, c := range []struct{ company, want string }{
		{"Acme Inc", "acme-inc"},
		{"acme-inc", "acme-inc-2"},
		{"ACME INC", "acme-inc-3"},
	} {
		slug, err := s.SlugFor(c.company, "")
		require.NoError(t, err)
		assert.Equal(t, c.want, slug, i)
		require.NoError(t, s.Save(slug, companybundle.Bundle{V: 1, Company: c.company}))
	}
	entries, errs, err := s.LoadAll("")
	require.NoError(t, err)
	assert.Empty(t, errs)
	got := map[string]string{}
	for _, e := range entries {
		got[e.Slug] = e.Bundle.Company
	}
	assert.Equal(t, map[string]string{"acme-inc": "Acme Inc", "acme-inc-2": "acme-inc", "acme-inc-3": "ACME INC"}, got)
}

func TestSlug_ReservedAndNonASCII(t *testing.T) {
	s := newStore(t)
	slug, err := s.SlugFor("Draft", "")
	require.NoError(t, err)
	assert.Equal(t, "draft-company", slug)
	slug, err = s.SlugFor("Ачме", "")
	require.NoError(t, err)
	assert.Equal(t, "company", slug)
	assert.Error(t, s.Save("draft", companybundle.Bundle{V: 1, Company: "Draft"}))
	assert.Error(t, s.Save("../acme", sample("Acme")))
	assert.Error(t, s.Save("", sample("Acme")))
}

func TestCompanyStore_SameCompanyKeepsSlug(t *testing.T) {
	s := newStore(t)
	require.NoError(t, s.Save("acme", sample("Acme")))
	slug, err := s.SlugFor("Acme", "")
	require.NoError(t, err)
	assert.Equal(t, "acme", slug)

	b := sample("Acme")
	b.Google.Domain = "acme.example.com"
	require.NoError(t, s.Save(slug, b))
	got, _, err := s.Get("acme", "")
	require.NoError(t, err)
	assert.Equal(t, "acme.example.com", got.Bundle.Google.Domain)
}

func TestCompanyStore_SaveRefusesAnotherCompany(t *testing.T) {
	s := newStore(t)
	require.NoError(t, s.Save("acme", sample("Acme")))
	err := s.Save("acme", sample("ACME"))
	assert.True(t, errors.Is(err, ErrSlugTaken), "%v", err)
	got, _, err := s.Get("acme", "")
	require.NoError(t, err)
	assert.Equal(t, "Acme", got.Bundle.Company)
}

func TestCompanyStore_DamagedFileIsLoadError(t *testing.T) {
	s := newStore(t)
	require.NoError(t, s.Save("beta", sample("Beta")))
	require.NoError(t, os.WriteFile(filepath.Join(s.Dir, "acme.json"), []byte(`{"v":1,"company":`), 0o600))

	entries, errs, err := s.LoadAll("")
	require.NoError(t, err)
	require.Len(t, entries, 1)
	assert.Equal(t, "beta", entries[0].Slug)
	require.Len(t, errs, 1)
	assert.Equal(t, "acme.json", errs[0].File)
	assert.NotEmpty(t, errs[0].Err)

	// The damaged file's slug is never handed out, nor written over.
	slug, err := s.SlugFor("Acme", "")
	require.NoError(t, err)
	assert.Equal(t, "acme-2", slug)
	assert.True(t, errors.Is(s.Save("acme", sample("Acme")), ErrSlugTaken))
	_, _, err = s.Get("acme", "")
	assert.ErrorContains(t, err, "acme.json")
}

func TestCompanyStore_IgnoresDraftLocksAndTemps(t *testing.T) {
	s := newStore(t)
	require.NoError(t, s.Save("acme", sample("Acme")))
	for _, name := range []string{"draft.json", "draft.json.bad-20261118T000000Z", "acme.json.tmp-123", ".forced-acme.seen"} {
		require.NoError(t, os.WriteFile(filepath.Join(s.Dir, name), []byte("x"), 0o600))
	}
	entries, errs, err := s.LoadAll("")
	require.NoError(t, err)
	assert.Empty(t, errs)
	require.Len(t, entries, 1)
	assert.Equal(t, "acme", entries[0].Slug)
}

func TestCompanyStore_MissingDirIsNoCompany(t *testing.T) {
	entries, errs, err := newStore(t).LoadAll("")
	require.NoError(t, err)
	assert.Empty(t, entries)
	assert.Empty(t, errs)
}

func TestCompanyStore_ForcedOverlayWins(t *testing.T) {
	s := newStore(t)
	stored := sample("Acme")
	require.NoError(t, s.Save("acme", stored))
	require.NoError(t, s.Save("beta", sample("Beta")))
	before, err := os.ReadFile(filepath.Join(s.Dir, "acme.json"))
	require.NoError(t, err)

	forced := sample("Acme")
	forced.Atlassian.ClientID = "acmeClientId02"
	entries, errs, err := s.LoadAll(wire(t, forced))
	require.NoError(t, err)
	assert.Empty(t, errs)
	require.Len(t, entries, 2)
	assert.Equal(t, Entry{Slug: "acme", Bundle: forced, Forced: true}, entries[0])
	assert.False(t, entries[1].Forced)

	after, err := os.ReadFile(filepath.Join(s.Dir, "acme.json"))
	require.NoError(t, err)
	assert.Equal(t, before, after)

	got, ok, err := s.Get("acme", wire(t, forced))
	require.NoError(t, err)
	require.True(t, ok)
	assert.True(t, got.Forced)
	assert.Equal(t, "acmeClientId02", got.Bundle.Atlassian.ClientID)
}

func TestCompanyStore_ForcedOnlyAndItsSlugReserved(t *testing.T) {
	s := newStore(t)
	forced := wire(t, sample("Acme Inc"))
	entries, _, err := s.LoadAll(forced)
	require.NoError(t, err)
	require.Len(t, entries, 1)
	assert.Equal(t, "acme-inc", entries[0].Slug)
	assert.True(t, entries[0].Forced)

	// Another company slugging the same never takes the forced one's slug.
	slug, err := s.SlugFor("acme-inc", forced)
	require.NoError(t, err)
	assert.Equal(t, "acme-inc-2", slug)
	slug, err = s.SlugFor("Acme Inc", forced)
	require.NoError(t, err)
	assert.Equal(t, "acme-inc", slug)
}

func TestCompanyStore_BadForcedIsLoadError(t *testing.T) {
	s := newStore(t)
	require.NoError(t, s.Save("acme", sample("Acme")))
	personal := base64.RawURLEncoding.EncodeToString([]byte(`{"v":1,"company":"Acme","personal":true}`))
	for _, w := range []string{"!!!", personal} {
		entries, errs, err := s.LoadAll(w)
		require.NoError(t, err)
		require.Len(t, entries, 1)
		assert.False(t, entries[0].Forced)
		require.Len(t, errs, 1)
		assert.Equal(t, ForcedSource, errs[0].File)
	}
}

func TestLoadAll_NeverWrites(t *testing.T) {
	ws := t.TempDir()
	s := NewStore(ws)
	_, _, err := s.LoadAll(wire(t, sample("Acme")))
	require.NoError(t, err)
	_, err = os.Stat(s.Dir)
	assert.True(t, os.IsNotExist(err), "LoadAll created the company directory")

	require.NoError(t, s.Save("beta", sample("Beta")))
	list := func() map[string]string {
		out := map[string]string{}
		des, err := os.ReadDir(s.Dir)
		require.NoError(t, err)
		for _, de := range des {
			raw, err := os.ReadFile(filepath.Join(s.Dir, de.Name()))
			require.NoError(t, err)
			fi, err := de.Info()
			require.NoError(t, err)
			out[de.Name()] = string(raw) + fi.ModTime().String() + fi.Mode().String()
		}
		return out
	}
	before := list()
	_, _, err = s.LoadAll(wire(t, sample("Acme")))
	require.NoError(t, err)
	_, _, err = s.Get("acme", wire(t, sample("Acme")))
	require.NoError(t, err)
	_, err = s.SlugFor("Gamma", wire(t, sample("Acme")))
	require.NoError(t, err)
	assert.Equal(t, before, list())
}

func TestCompanyStore_ConcurrentSaveSerialized(t *testing.T) {
	s := newStore(t)
	a, b := sample("Acme"), sample("Acme")
	b.Atlassian.ClientID = "acmeClientId02"
	b.Google.Domain = "acme.example.com"
	var wg sync.WaitGroup
	for i := range 20 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			v := a
			if i%2 == 1 {
				v = b
			}
			assert.NoError(t, s.Save("acme", v))
		}()
	}
	wg.Wait()
	got, ok, err := s.Get("acme", "")
	require.NoError(t, err)
	require.True(t, ok)
	if got.Bundle.Atlassian.ClientID == "acmeClientId02" {
		assert.Equal(t, b, got.Bundle)
	} else {
		assert.Equal(t, a, got.Bundle)
	}
}

func TestCleanCode(t *testing.T) {
	w := wire(t, sample("Acme"))
	wrapped := "  " + w[:20] + "\r\n" + w[20:40] + "\n\t" + w[40:60] + " " + w[60:] + " \n"
	assert.Equal(t, w, CleanCode(wrapped))
	_, err := companybundle.Parse(CleanCode(wrapped), companybundle.OriginCode)
	assert.NoError(t, err)
}
