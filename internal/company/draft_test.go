package company

import (
	"os"
	"path/filepath"
	"strings"
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

	// No services yet is an empty list, never null.
	require.NoError(t, s.SaveDraft(Draft{Company: "Acme"}))
	raw, err := os.ReadFile(filepath.Join(s.Dir, "draft.json"))
	require.NoError(t, err)
	assert.Contains(t, string(raw), `"services": []`)

	// The draft is never taken for a company file.
	entries, errs, err := s.LoadAll("")
	require.NoError(t, err)
	assert.Empty(t, entries)
	assert.Empty(t, errs)
}

func TestCompanyDraft_NeverStoresSlackToken(t *testing.T) {
	for name, raw := range map[string]string{
		"token field":       `{"company":"Acme","services":["slack"],"step":"slack","slack":{"app_id":"A0ACME","config_token":"abc"}}`,
		"top-level token":   `{"company":"Acme","services":[],"step":"","token":"abc"}`,
		"token as a value":  `{"company":"Acme","services":[],"step":"","google":{"client_id":"xoxe.xoxp-1-abc","client_secret":""}}`,
		"spaced token":      `{"company":"Acme","services":[],"step":"","google":{"client_id":"x","client_secret":"  xoxe-1-abc"}}`,
		"escaped token":     `{"company":"Acme","services":[],"step":"","deny_hosts":["xoxe.xoxp-1"]}`,
		"other Slack token": `{"company":"Acme","services":[],"step":"","linear":{"client_id":"xoxb-1-abc"}}`,
	} {
		_, err := ParseDraftJSON([]byte(raw))
		assert.ErrorIs(t, err, ErrSlackTokenInDraft, name)
	}
	_, err := ParseDraftJSON([]byte(`{"company":"Xoxe Labs","services":[],"step":""}`))
	assert.NoError(t, err, "a name is not a token")

	s := NewStore(t.TempDir())
	d := sampleDraft()
	d.Atlassian.ClientSecret = "xoxe-1-sample" // pasted into the wrong field
	assert.ErrorIs(t, s.SaveDraft(d), ErrSlackTokenInDraft)
	_, err = os.Stat(filepath.Join(s.Dir, "draft.json"))
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

	// An unknown service, a null, trailing data and an oversized file are
	// unreadable too.
	for i, raw := range []string{`{"company":"Acme","services":["notion"],"step":""}`, `null`, `{"company":"Acme"}]`, "{" + strings.Repeat(" ", maxFileBytes) + "}"} {
		writeRawDraft(t, s, raw)
		_, state, _, err = s.LoadDraft(draftT0.Add(time.Duration(i+2) * time.Hour))
		require.NoError(t, err)
		assert.Equal(t, DraftUnreadable, state, raw)
	}

	// A save never overwrites a damaged draft (its typed secrets).
	writeRawDraft(t, s, "broken")
	assert.Error(t, s.SaveDraft(sampleDraft()))
	raw, err = os.ReadFile(filepath.Join(s.Dir, "draft.json"))
	require.NoError(t, err)
	assert.Equal(t, "broken", string(raw))
}

// TestCompanyDraft_LinkIsNotFollowed: a draft.json that is a symlink is
// removed, never renamed with its target's mode changed.
func TestCompanyDraft_LinkIsNotFollowed(t *testing.T) {
	s := NewStore(t.TempDir())
	require.NoError(t, os.MkdirAll(s.Dir, 0o700))
	target := filepath.Join(t.TempDir(), "elsewhere")
	require.NoError(t, os.WriteFile(target, []byte("x"), 0o644))
	require.NoError(t, os.Symlink(target, filepath.Join(s.Dir, "draft.json")))

	_, state, _, err := s.LoadDraft(draftT0)
	require.NoError(t, err)
	assert.Equal(t, DraftNone, state)
	assert.Equal(t, os.FileMode(0o644), fileMode(t, target), "the target is untouched")
	_, err = os.Lstat(filepath.Join(s.Dir, "draft.json"))
	assert.ErrorIs(t, err, os.ErrNotExist)
}

// TestCompanyDraft_IOErrorIsNotSetAside: a draft that cannot be read now
// (no permission) is an error and stays where it is.
func TestCompanyDraft_IOErrorIsNotSetAside(t *testing.T) {
	s := NewStore(t.TempDir())
	writeRawDraft(t, s, `{"company":"Acme","services":[],"step":""}`)
	path := filepath.Join(s.Dir, "draft.json")
	require.NoError(t, os.Chmod(path, 0o000))
	t.Cleanup(func() { _ = os.Chmod(path, 0o600) })

	_, _, _, err := s.LoadDraft(draftT0)
	assert.Error(t, err)
	bad, err := s.badDrafts()
	require.NoError(t, err)
	assert.Empty(t, bad)
	_, err = os.Lstat(path)
	assert.NoError(t, err)
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
		"scopes":    func(d *Draft) { d.Atlassian.Confluence = !d.Atlassian.Confluence },
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

	// The new values are checked; a late result for the old ones changes
	// nothing.
	require.NoError(t, s.MarkDraftChecked("atlassian", CheckHash("atlassian", got)))
	assert.ErrorIs(t, s.MarkDraftChecked("atlassian", CheckHash("atlassian", d)), ErrDraftValuesChanged)
	got, _, _, err = s.LoadDraft(draftT0)
	require.NoError(t, err)
	assert.True(t, got.IsChecked("atlassian"))
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

// A passed check writes the company slug and the Google domain into the
// draft in the same write as its mark; a later wizard save that leaves them
// out keeps them (the wizard's draft predates the check).
func TestCompanyDraft_RecordCheckKeepsSlugAndDomain(t *testing.T) {
	s := NewStore(t.TempDir())
	d := sampleDraft()
	require.NoError(t, s.SaveDraft(d))
	require.NoError(t, s.RecordDraftCheck(DraftCheck{Vendor: "google", Hash: CheckHash("google", d), Slug: "acme", GoogleDomain: "example.com"}))

	got, _, _, err := s.LoadDraft(draftT0)
	require.NoError(t, err)
	assert.True(t, got.IsChecked("google"))
	assert.Equal(t, "acme", got.Slug)
	assert.Equal(t, "example.com", got.Google.Domain)

	again := sampleDraft()
	again.Step = "linear"
	require.NoError(t, s.SaveDraft(again))
	got, _, _, err = s.LoadDraft(draftT0)
	require.NoError(t, err)
	assert.Equal(t, "acme", got.Slug)
	assert.Equal(t, "example.com", got.Google.Domain)
	assert.True(t, got.IsChecked("google"), "a domain is not a checked value")

	// Another Google client drops the old client's domain.
	other := sampleDraft()
	other.Google = &companybundle.Google{ClientID: "5678-efgh.apps.googleusercontent.com", ClientSecret: "s"}
	require.NoError(t, s.SaveDraft(other))
	got, _, _, err = s.LoadDraft(draftT0)
	require.NoError(t, err)
	assert.Empty(t, got.Google.Domain)
}

// A check whose values were edited while it ran still names the company it
// stored (the bundle exists under that slug) but marks nothing.
func TestCompanyDraft_LateCheckKeepsOnlySlug(t *testing.T) {
	s := NewStore(t.TempDir())
	d := sampleDraft()
	require.NoError(t, s.SaveDraft(d))
	stale := CheckHash("google", d)
	edited := sampleDraft()
	edited.Google = &companybundle.Google{ClientID: "5678-efgh.apps.googleusercontent.com", ClientSecret: "s"}
	require.NoError(t, s.SaveDraft(edited))

	err := s.RecordDraftCheck(DraftCheck{Vendor: "google", Hash: stale, Slug: "acme", GoogleDomain: "example.com"})
	require.ErrorIs(t, err, ErrDraftValuesChanged)
	got, _, _, err := s.LoadDraft(draftT0)
	require.NoError(t, err)
	assert.Equal(t, "acme", got.Slug)
	assert.False(t, got.IsChecked("google"))
	assert.Empty(t, got.Google.Domain)

	assert.ErrorIs(t, s.RecordDraftCheck(DraftCheck{Vendor: "google", Hash: stale, Slug: "acme"}), ErrDraftValuesChanged,
		"nothing new to write")
}

// A check for one company that ends after the draft was discarded and
// started again for another leaves the new draft alone, even with the same
// values.
func TestCompanyDraft_CheckOfAnotherCompanyIgnored(t *testing.T) {
	s := NewStore(t.TempDir())
	d := sampleDraft()
	d.Company = "Initech"
	require.NoError(t, s.SaveDraft(d))

	err := s.RecordDraftCheck(DraftCheck{Vendor: "google", Hash: CheckHash("google", d), Company: "Acme", Slug: "acme"})
	require.ErrorIs(t, err, ErrDraftValuesChanged)
	got, _, _, err := s.LoadDraft(draftT0)
	require.NoError(t, err)
	assert.Empty(t, got.Slug)
	assert.False(t, got.IsChecked("google"))
}
