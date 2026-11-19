package company

import (
	"io/fs"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// SaveRenamed changes only the company name of the file under slug (ask
// #1613): the file name stays, the slug of the new name is the old one.
func TestCompanyStore_SaveRenamedKeepsSlug(t *testing.T) {
	s := newStore(t)
	a := sample("Acme")
	require.NoError(t, s.Save("acme", a))
	b := sample("Acme Corp")
	require.NoError(t, s.SaveRenamed("acme", a, b, ""))

	entries, errs, err := s.LoadAll("")
	require.NoError(t, err)
	require.Empty(t, errs)
	require.Len(t, entries, 1)
	assert.Equal(t, Entry{Slug: "acme", Bundle: b}, entries[0])
	slug, err := s.SlugFor("Acme Corp", "")
	require.NoError(t, err)
	assert.Equal(t, "acme", slug, "the new name finds its file")
	_, err = os.Stat(filepath.Join(s.Dir, "acme-corp.json"))
	assert.ErrorIs(t, err, fs.ErrNotExist)

	// Save keeps refusing another company's file: only SaveRenamed renames.
	assert.ErrorIs(t, s.Save("acme", sample("Globex")), ErrSlugTaken)
}

func TestCompanyStore_SaveRenamedRefusals(t *testing.T) {
	t.Run("the file changed since it was read", func(t *testing.T) {
		s := newStore(t)
		a := sample("Acme")
		require.NoError(t, s.Save("acme", a))
		newer := sample("Acme")
		newer.Linear.ClientID = "acmelinear02"
		require.NoError(t, s.Save("acme", newer))
		assert.ErrorIs(t, s.SaveRenamed("acme", a, sample("Acme Corp"), ""), ErrStoredChanged)
		assertStoredName(t, s, "Acme")
	})
	t.Run("no file to rename", func(t *testing.T) {
		s := newStore(t)
		assert.ErrorIs(t, s.SaveRenamed("acme", sample("Acme"), sample("Acme Corp"), ""), ErrStoredChanged)
	})
	t.Run("another file holds the name", func(t *testing.T) {
		s := newStore(t)
		require.NoError(t, s.Save("acme", sample("Acme")))
		require.NoError(t, s.Save("acme-corp", sample("Acme Corp")))
		assert.ErrorIs(t, s.SaveRenamed("acme", sample("Acme"), sample("Acme Corp"), ""), ErrNameTaken)
		assertStoredName(t, s, "Acme")
	})
	t.Run("the forced bundle holds the name", func(t *testing.T) {
		s := newStore(t)
		require.NoError(t, s.Save("acme", sample("Acme")))
		assert.ErrorIs(t, s.SaveRenamed("acme", sample("Acme"), sample("Acme Corp"), wire(t, sample("Acme Corp"))), ErrNameTaken)
		assertStoredName(t, s, "Acme")
	})
	t.Run("a once-forced company pins the name", func(t *testing.T) {
		s := newStore(t)
		require.NoError(t, s.Save("acme", sample("Acme")))
		require.NoError(t, writeSeen(s.Dir, "acme-corp", sample("Acme Corp")))
		assert.ErrorIs(t, s.SaveRenamed("acme", sample("Acme"), sample("Acme Corp"), ""), ErrNameTaken)
		assertStoredName(t, s, "Acme")
	})
	t.Run("the forced bundle names the company", func(t *testing.T) {
		s := newStore(t)
		require.NoError(t, s.Save("acme", sample("Acme")))
		assert.ErrorIs(t, s.SaveRenamed("acme", sample("Acme"), sample("Acme Corp"), wire(t, sample("Acme"))), ErrCompanyForced)
		assertStoredName(t, s, "Acme")
	})
}

func TestCompanyStore_CheckRename(t *testing.T) {
	s := newStore(t)
	require.NoError(t, s.Save("acme", sample("Acme")))
	personal := sample("Initech")
	personal.Personal = true
	personal.Slack, personal.Atlassian, personal.Linear, personal.Microsoft = nil, nil, nil, nil
	require.NoError(t, s.Save("initech", personal))

	require.NoError(t, s.CheckRename("acme", "Acme", "Umbrella", ""))
	assert.ErrorIs(t, s.CheckRename("acme", "Acme", "Initech", ""), ErrNameTaken, "a personal Google project")
	assert.ErrorIs(t, s.CheckRename("acme", "Acme", "Globex", wire(t, sample("Globex"))), ErrNameTaken, "the forced company")
	assert.ErrorIs(t, s.CheckRename("acme", "Acme", "Umbrella", wire(t, sample("Acme"))), ErrCompanyForced)
}

func assertStoredName(t *testing.T, s Store, want string) {
	t.Helper()
	e, ok, err := s.Get("acme", "")
	require.NoError(t, err)
	require.True(t, ok)
	assert.Equal(t, want, e.Bundle.Company)
}

func TestCompanyDraft_SetDraftCompany(t *testing.T) {
	s := NewStore(t.TempDir())
	assert.ErrorIs(t, s.SetDraftCompany(sampleDraft(), "Acme Corp"), fs.ErrNotExist, "no draft")

	d := sampleDraft()
	d.Slug = "acme"
	require.NoError(t, s.SaveDraft(d))
	require.NoError(t, s.RecordDraftCheck(DraftCheck{Vendor: "google", Hash: CheckHash("google", d)}))
	before, _, _, err := s.LoadDraft(draftT0)
	require.NoError(t, err)

	require.NoError(t, s.SetDraftCompany(before, "Acme Corp"))
	got, _, _, err := s.LoadDraft(draftT0)
	require.NoError(t, err)
	want := before
	want.Company = "Acme Corp"
	assert.Equal(t, want, got, "only the name changes; the check marks hold")
	assert.True(t, got.IsChecked("google"))

	// A draft that changed since it was read (same name or not) is not touched.
	assert.ErrorIs(t, s.SetDraftCompany(before, "Acme Two"), ErrDraftValuesChanged)
	stale := got
	stale.DenyHosts = []string{"other.example.com"}
	assert.ErrorIs(t, s.SetDraftCompany(stale, "Acme Two"), ErrDraftValuesChanged)
	got, _, _, err = s.LoadDraft(draftT0)
	require.NoError(t, err)
	assert.Equal(t, "Acme Corp", got.Company)
}
