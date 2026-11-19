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

func TestCompanyStore_NameHolder(t *testing.T) {
	s := newStore(t)
	require.NoError(t, s.Save("acme", sample("Acme")))
	personal := sample("Initech")
	personal.Personal = true
	personal.Slack, personal.Atlassian, personal.Linear, personal.Microsoft = nil, nil, nil, nil
	require.NoError(t, s.Save("initech", personal))

	_, _, ok, err := s.NameHolder("Acme", "acme", "")
	require.NoError(t, err)
	assert.False(t, ok, "its own name")
	holder, isPersonal, ok, err := s.NameHolder("Initech", "acme", "")
	require.NoError(t, err)
	assert.True(t, ok)
	assert.True(t, isPersonal)
	assert.Equal(t, "initech", holder)
	holder, _, ok, err = s.NameHolder("Globex", "acme", wire(t, sample("Globex")))
	require.NoError(t, err)
	assert.True(t, ok, "the forced company")
	assert.Equal(t, "globex", holder)
	_, _, ok, err = s.NameHolder("Umbrella", "acme", "")
	require.NoError(t, err)
	assert.False(t, ok)
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
	assert.ErrorIs(t, s.SetDraftCompany("Acme", "Acme Corp"), fs.ErrNotExist, "no draft")

	d := sampleDraft()
	d.Slug = "acme"
	require.NoError(t, s.SaveDraft(d))
	require.NoError(t, s.RecordDraftCheck(DraftCheck{Vendor: "google", Hash: CheckHash("google", d)}))
	before, _, _, err := s.LoadDraft(draftT0)
	require.NoError(t, err)

	require.NoError(t, s.SetDraftCompany("Acme", "Acme Corp"))
	got, _, _, err := s.LoadDraft(draftT0)
	require.NoError(t, err)
	want := before
	want.Company = "Acme Corp"
	assert.Equal(t, want, got, "only the name changes; the check marks hold")
	assert.True(t, got.IsChecked("google"))

	require.NoError(t, s.SetDraftCompany("Acme", "Acme Corp"), "a rerun finds it named")
	assert.ErrorIs(t, s.SetDraftCompany("Globex", "Acme Two"), ErrDraftValuesChanged, "a draft of another name is not touched")
	got, _, _, err = s.LoadDraft(draftT0)
	require.NoError(t, err)
	assert.Equal(t, "Acme Corp", got.Company)
}
