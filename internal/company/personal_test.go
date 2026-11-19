package company

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/companybundle"
	"watchtower/internal/db"
)

// A company forced before keeps its pinned slug (its accounts carry it): a
// person named like it gets a suffixed personal bundle, never that slug.
func TestSavePersonal_FormerForcedCompanyKeepsItsSlug(t *testing.T) {
	s := newStore(t)
	require.NoError(t, os.MkdirAll(s.Dir, 0o700))
	require.NoError(t, writeSeen(s.Dir, "acme", sample("Acme")))

	slug, err := SavePersonal(s, "", "Acme", ownClient("1"))
	require.NoError(t, err)
	assert.NotEqual(t, "acme", slug)
	e, _, err := s.Get(slug, "")
	require.NoError(t, err)
	assert.Equal(t, "Acme (2)", e.Bundle.Company)
}

func ownClient(n string) companybundle.Google {
	return companybundle.Google{ClientID: n + "-own.apps.googleusercontent.com", ClientSecret: "own-secret-" + n}
}

// TestSavePersonal_StoresPersonalBundle: the own project is stored as a
// personal bundle with only a google block, named after its owner.
func TestSavePersonal_StoresPersonalBundle(t *testing.T) {
	s := newStore(t)
	slug, err := SavePersonal(s, "", "bob@example.org", ownClient("1"))
	require.NoError(t, err)
	assert.Equal(t, "bob-example-org", slug)

	e, ok, err := s.Get(slug, "")
	require.NoError(t, err)
	require.True(t, ok)
	g := ownClient("1")
	assert.Equal(t, companybundle.Bundle{V: 1, Company: "bob@example.org", Personal: true, Google: &g}, e.Bundle)
}

func TestSavePersonal_UnknownOwnerUsesFallbackName(t *testing.T) {
	s := newStore(t)
	slug, err := SavePersonal(s, "", "  ", ownClient("1"))
	require.NoError(t, err)
	e, _, err := s.Get(slug, "")
	require.NoError(t, err)
	assert.Equal(t, personalFallbackName, e.Bundle.Company)
}

// An owner name the bundle refuses (a control character) falls back to the
// fallback name instead of failing the sign-in.
func TestSavePersonal_InvalidOwnerNameFallsBack(t *testing.T) {
	s := newStore(t)
	slug, err := SavePersonal(s, "", "Bob\u0000", ownClient("1"))
	require.NoError(t, err)
	e, _, err := s.Get(slug, "")
	require.NoError(t, err)
	assert.Equal(t, personalFallbackName, e.Bundle.Company)
}

// The same client again is the same project: one file, the same slug.
func TestSavePersonal_SameClientReused(t *testing.T) {
	s := newStore(t)
	a, err := SavePersonal(s, "", "bob@example.org", ownClient("1"))
	require.NoError(t, err)
	b, err := SavePersonal(s, "", "other@example.org", ownClient("1"))
	require.NoError(t, err)
	assert.Equal(t, a, b)
	entries, _, err := s.LoadAll("")
	require.NoError(t, err)
	assert.Len(t, entries, 1)
}

// A second project of the same person never overwrites the first (whose
// accounts would then need a re-login), nor a company of the same name.
func TestSavePersonal_NeverOverwritesAnotherBundle(t *testing.T) {
	s := newStore(t)
	require.NoError(t, s.Save("acme", sample("Acme")))
	first, err := SavePersonal(s, "", "Acme", ownClient("1"))
	require.NoError(t, err)
	assert.NotEqual(t, "acme", first)
	second, err := SavePersonal(s, "", "Acme", ownClient("2"))
	require.NoError(t, err)
	assert.NotEqual(t, first, second)

	company, _, err := s.Get("acme", "")
	require.NoError(t, err)
	assert.Equal(t, sample("Acme"), company.Bundle, "the company's file is untouched")
	e1, _, err := s.Get(first, "")
	require.NoError(t, err)
	assert.Equal(t, "Acme (2)", e1.Bundle.Company)
	assert.Equal(t, ownClient("1").ClientID, e1.Bundle.Google.ClientID)
	e2, _, err := s.Get(second, "")
	require.NoError(t, err)
	assert.Equal(t, "Acme (3)", e2.Bundle.Company)
	assert.True(t, e2.Bundle.Personal)
}

// The forced MDM company keeps its name: a person named like it gets a
// suffixed personal bundle, and the forced company's slug stays its own.
func TestSavePersonal_ForcedCompanyNameTaken(t *testing.T) {
	s := newStore(t)
	forced := wire(t, sample("Acme"))
	slug, err := SavePersonal(s, forced, "Acme", ownClient("1"))
	require.NoError(t, err)
	assert.NotEqual(t, "acme", slug)
	e, _, err := s.Get(slug, forced)
	require.NoError(t, err)
	assert.True(t, e.Bundle.Personal)
	assert.False(t, e.Forced)
}

func TestSavePersonal_RefusesBadClient(t *testing.T) {
	s := newStore(t)
	_, err := SavePersonal(s, "", "Bob", companybundle.Google{ClientID: "not a client", ClientSecret: "x"})
	require.Error(t, err)
	entries, _, err := s.LoadAll("")
	require.NoError(t, err)
	assert.Empty(t, entries, "nothing stored")
}

// Two concurrent saves of the same client end on one file.
func TestSavePersonal_ConcurrentSameClientOneFile(t *testing.T) {
	s := newStore(t)
	var wg sync.WaitGroup
	slugs := make([]string, 4)
	errs := make([]error, 4)
	for i := range slugs {
		wg.Add(1)
		go func() {
			defer wg.Done()
			slugs[i], errs[i] = SavePersonal(s, "", "Bob", ownClient("1"))
		}()
	}
	wg.Wait()
	for i := range slugs {
		require.NoError(t, errs[i])
		assert.Equal(t, slugs[0], slugs[i])
	}
	entries, _, err := s.LoadAll("")
	require.NoError(t, err)
	assert.Len(t, entries, 1)
}

// TestPersonalNeverFromLinkMDMCode: personal is a stored file's only; the
// same bundle arriving by link, MDM or a code is refused.
func TestPersonalNeverFromLinkMDMCode(t *testing.T) {
	s := newStore(t)
	slug, err := SavePersonal(s, "", "Bob", ownClient("1"))
	require.NoError(t, err)
	e, _, err := s.Get(slug, "")
	require.NoError(t, err)
	raw, err := json.Marshal(e.Bundle)
	require.NoError(t, err)
	wireForm := base64.RawURLEncoding.EncodeToString(raw)
	for _, origin := range []companybundle.Origin{companybundle.OriginLink, companybundle.OriginMDM, companybundle.OriginCode} {
		_, err := companybundle.Parse(wireForm, origin)
		var pe *companybundle.ParseError
		require.True(t, errors.As(err, &pe), "origin %d", origin)
		assert.Equal(t, companybundle.RefusalPersonal, pe.Reason)
	}
	_, err = companybundle.ParseJSON(raw, companybundle.OriginLocal)
	require.NoError(t, err)
}

func TestIsOwnProject_Table(t *testing.T) {
	personal := companybundle.Bundle{V: 1, Company: "Bob", Personal: true, Google: &companybundle.Google{ClientID: "1-own.apps.googleusercontent.com", ClientSecret: "s"}}
	entries := []Entry{
		{Slug: "acme", Bundle: sample("Acme")},
		{Slug: "bob", Bundle: personal},
	}
	for _, tc := range []struct {
		name   string
		slug   string
		legacy bool
		want   bool
	}{
		{"personal bundle", "bob", false, true},
		{"personal bundle with its credentials file", "bob", true, true},
		{"company bundle", "acme", true, false},
		{"bridged corp account (company + legacy file)", "acme", true, false},
		{"untied legacy credentials", "", true, true},
		{"shared client", "", false, false},
		{"unknown company slug", "gone", true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := IsOwnProject(db.GoogleAccount{ID: 1, CompanySlug: tc.slug}, entries, tc.legacy)
			assert.Equal(t, tc.want, got)
		})
	}
}
