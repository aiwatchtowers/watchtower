package company

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/companybundle"
)

// draftT0 is a fixed clock: tests never read the wall clock.
var draftT0 = time.Date(2026, 11, 17, 9, 30, 0, 0, time.UTC)

func sampleDraft() Draft {
	return Draft{
		Company: "Acme", Services: []string{"slack", "google", "atlassian"}, Step: "atlassian", StartedAt: draftT0,
		Slack:     DraftSlack{AppID: "A0ACME"},
		Google:    &companybundle.Google{ClientID: "1234-abcd.apps.googleusercontent.com", ClientSecret: "sample-secret"},
		Atlassian: &companybundle.Atlassian{ClientID: "acmeClientId01", ClientSecret: "acme-secret", Site: "https://acme.atlassian.net"},
		DenyHosts: []string{"intranet.example.com"}, Skipped: []string{"slack"},
	}
}

func fileMode(t *testing.T, path string) os.FileMode {
	t.Helper()
	fi, err := os.Stat(path)
	require.NoError(t, err)
	return fi.Mode().Perm()
}

func TestCompanyDraft_RoundTrip(t *testing.T) {
	s := NewStore(t.TempDir())
	_, state, bad, err := s.LoadDraft(draftT0)
	require.NoError(t, err)
	assert.Equal(t, DraftNone, state)
	assert.Empty(t, bad)

	d := sampleDraft()
	require.NoError(t, s.SaveDraft(d))
	assert.Equal(t, os.FileMode(0o600), fileMode(t, filepath.Join(s.Dir, "draft.json")))
	assert.Equal(t, os.FileMode(0o700), fileMode(t, s.Dir))

	got, state, _, err := s.LoadDraft(draftT0)
	require.NoError(t, err)
	assert.Equal(t, DraftOK, state)
	assert.Equal(t, d, got, "every field, the typed secrets included, survives")

	// A later save keeps the first start time.
	d.StartedAt = draftT0.Add(48 * time.Hour)
	d.Step = "publish"
	require.NoError(t, s.SaveDraft(d))
	got, _, _, err = s.LoadDraft(draftT0)
	require.NoError(t, err)
	assert.Equal(t, draftT0, got.StartedAt)
	assert.Equal(t, "publish", got.Step)

	// The draft is never taken for a company file.
	entries, errs, err := s.LoadAll("")
	require.NoError(t, err)
	assert.Empty(t, entries)
	assert.Empty(t, errs)
}

func TestCompanyDraft_NeverStoresSlackToken(t *testing.T) {
	for name, raw := range map[string]string{
		"token field":      `{"company":"Acme","services":["slack"],"step":"slack","slack":{"app_id":"A0ACME","config_token":"abc"}}`,
		"top-level token":  `{"company":"Acme","services":[],"step":"","token":"abc"}`,
		"token as a value": `{"company":"Acme","services":[],"step":"","google":{"client_id":"xoxe.xoxp-1-abc","client_secret":""}}`,
	} {
		_, err := ParseDraftJSON([]byte(raw))
		assert.ErrorIs(t, err, ErrSlackTokenInDraft, name)
	}

	s := NewStore(t.TempDir())
	d := sampleDraft()
	d.Atlassian.ClientSecret = "xoxe-1-sample" // pasted into the wrong field
	assert.ErrorIs(t, s.SaveDraft(d), ErrSlackTokenInDraft)
	_, err := os.Stat(filepath.Join(s.Dir, "draft.json"))
	assert.ErrorIs(t, err, os.ErrNotExist, "nothing written")
}

func writeRawDraft(t *testing.T, s Store, content string) {
	t.Helper()
	require.NoError(t, os.MkdirAll(s.Dir, 0o700))
	require.NoError(t, os.WriteFile(filepath.Join(s.Dir, "draft.json"), []byte(content), 0o644))
}

func TestCompanyDraft_CorruptRenamed(t *testing.T) {
	s := NewStore(t.TempDir())
	writeRawDraft(t, s, `{"company":"Acme","google":{"client_secret":"typed-secret"`)

	_, state, bad, err := s.LoadDraft(draftT0)
	require.NoError(t, err)
	assert.Equal(t, DraftUnreadable, state)
	assert.Equal(t, "draft.json.bad-20261117T093000Z", bad)
	_, err = os.Stat(filepath.Join(s.Dir, "draft.json"))
	assert.ErrorIs(t, err, os.ErrNotExist, "the original is renamed")
	raw, err := os.ReadFile(filepath.Join(s.Dir, bad))
	require.NoError(t, err)
	assert.Equal(t, `{"company":"Acme","google":{"client_secret":"typed-secret"`, string(raw), "content intact")
	assert.Equal(t, os.FileMode(0o600), fileMode(t, filepath.Join(s.Dir, bad)))

	// Never folded into "no draft": the next load still reports it.
	_, state, again, err := s.LoadDraft(draftT0.Add(time.Hour))
	require.NoError(t, err)
	assert.Equal(t, DraftUnreadable, state)
	assert.Equal(t, bad, again)

	// An unknown service is unreadable too.
	writeRawDraft(t, s, `{"company":"Acme","services":["notion"],"step":""}`)
	_, state, _, err = s.LoadDraft(draftT0.Add(2 * time.Hour))
	require.NoError(t, err)
	assert.Equal(t, DraftUnreadable, state)
}

func TestCompanyDraft_OnlyNewestBadKept(t *testing.T) {
	s := NewStore(t.TempDir())
	writeRawDraft(t, s, "first")
	_, _, first, err := s.LoadDraft(draftT0)
	require.NoError(t, err)
	writeRawDraft(t, s, "second")
	_, _, second, err := s.LoadDraft(draftT0.Add(time.Hour))
	require.NoError(t, err)

	bad, err := s.badDrafts()
	require.NoError(t, err)
	assert.Equal(t, []string{second}, bad)
	assert.NotEqual(t, first, second)
	raw, err := os.ReadFile(filepath.Join(s.Dir, second))
	require.NoError(t, err)
	assert.Equal(t, "second", string(raw))
}

func TestCompanyDraft_StaleBadDeletedAfter30Days(t *testing.T) {
	s := NewStore(t.TempDir())
	writeRawDraft(t, s, "broken")
	_, _, bad, err := s.LoadDraft(draftT0)
	require.NoError(t, err)

	require.NoError(t, s.CleanStaleBadDrafts(draftT0.Add(29*24*time.Hour)))
	_, err = os.Stat(filepath.Join(s.Dir, bad))
	require.NoError(t, err, "29 days: kept")

	require.NoError(t, s.CleanStaleBadDrafts(draftT0.Add(31*24*time.Hour)))
	_, err = os.Stat(filepath.Join(s.Dir, bad))
	assert.ErrorIs(t, err, os.ErrNotExist, "31 days: deleted")

	// No company directory at all is nothing to do.
	require.NoError(t, NewStore(t.TempDir()).CleanStaleBadDrafts(draftT0))
}

func TestCompanyDraft_DiscardDeletesBad(t *testing.T) {
	s := NewStore(t.TempDir())
	require.NoError(t, s.Save("acme", companybundle.Bundle{V: 1, Company: "Acme"}))
	writeRawDraft(t, s, "broken")
	_, _, bad, err := s.LoadDraft(draftT0)
	require.NoError(t, err)
	require.NoError(t, s.SaveDraft(sampleDraft()))

	require.NoError(t, s.DiscardDraft())
	for _, name := range []string{"draft.json", bad} {
		_, err := os.Stat(filepath.Join(s.Dir, name))
		assert.ErrorIs(t, err, os.ErrNotExist, name)
	}
	_, ok, err := s.Get("acme", "")
	require.NoError(t, err)
	assert.True(t, ok, "the stored company stays")
	_, state, _, err := s.LoadDraft(draftT0)
	require.NoError(t, err)
	assert.Equal(t, DraftNone, state)

	require.NoError(t, NewStore(t.TempDir()).DiscardDraft(), "nothing to discard")
}

func TestCompanyDraft_CheckHashMismatchIsUnchecked(t *testing.T) {
	s := NewStore(t.TempDir())
	d := sampleDraft()
	require.NoError(t, s.SaveDraft(d))
	require.NoError(t, s.MarkDraftChecked("atlassian", CheckHash("atlassian", d)))
	got, _, _, err := s.LoadDraft(draftT0)
	require.NoError(t, err)
	assert.True(t, got.IsChecked("atlassian"))
	assert.False(t, got.IsChecked("google"), "never checked")
	assert.Equal(t, []string{"atlassian"}, got.CheckedVendors())

	for name, edit := range map[string]func(*Draft){
		"client id": func(d *Draft) { d.Atlassian.ClientID = "acmeClientId02" },
		"secret":    func(d *Draft) { d.Atlassian.ClientSecret = "other" },
		"site":      func(d *Draft) { d.Atlassian.Site = "https://beta.atlassian.net" },
		"dropped":   func(d *Draft) { d.Atlassian = nil },
	} {
		e := got
		a := *got.Atlassian
		e.Atlassian = &a
		edit(&e)
		assert.False(t, e.IsChecked("atlassian"), name)
	}

	// An edit saved by the wizard un-checks on disk too; the save cannot
	// forge a mark.
	edited := got
	edited.Atlassian = &companybundle.Atlassian{ClientID: "acmeClientId02", ClientSecret: "acme-secret", Site: "https://acme.atlassian.net"}
	edited.Checked = map[string]string{"google": CheckHash("google", edited)}
	require.NoError(t, s.SaveDraft(edited))
	got, _, _, err = s.LoadDraft(draftT0)
	require.NoError(t, err)
	assert.False(t, got.IsChecked("atlassian"))
	assert.False(t, got.IsChecked("google"), "only MarkDraftChecked writes a mark")
}

func TestCompanyDraft_SameValuesKeepCheck(t *testing.T) {
	s := NewStore(t.TempDir())
	d := sampleDraft()
	require.NoError(t, s.SaveDraft(d))
	require.NoError(t, s.MarkDraftChecked("google", CheckHash("google", d)))

	// The wizard re-enters the same values (a fresh struct) and saves.
	again := sampleDraft()
	again.Step = "linear"
	again.Google = &companybundle.Google{ClientID: d.Google.ClientID, ClientSecret: d.Google.ClientSecret}
	require.NoError(t, s.SaveDraft(again))
	got, _, _, err := s.LoadDraft(draftT0)
	require.NoError(t, err)
	assert.True(t, got.IsChecked("google"))
	assert.Equal(t, "linear", got.Step)

	assert.Empty(t, CheckHash("linear", d), "an empty step has nothing to check")
	assert.NotEqual(t, CheckHash("google", d), CheckHash("atlassian", d))
	assert.Error(t, s.MarkDraftChecked("notion", "x"))
	assert.Error(t, NewStore(t.TempDir()).MarkDraftChecked("google", "x"), "no draft")
}
