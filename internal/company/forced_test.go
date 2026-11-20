package company

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/companybundle"
	"watchtower/internal/db"
)

// forcedAccounts creates a Jira and a Google account of slug and a Jira
// account of another company; it returns their ids.
func forcedAccounts(t *testing.T, d *db.DB, slug string) (jira, google, otherJira int64) {
	t.Helper()
	var err error
	jira, err = d.CreateJiraAccount(db.JiraAccount{CloudID: "c1", SiteURL: "https://acme.atlassian.net", CompanySlug: slug})
	require.NoError(t, err)
	google, err = d.CreateGoogleAccount(db.GoogleAccount{Email: "a@example.com", CompanySlug: slug})
	require.NoError(t, err)
	otherJira, err = d.CreateJiraAccount(db.JiraAccount{CloudID: "c2", SiteURL: "https://other.atlassian.net", CompanySlug: "other"})
	require.NoError(t, err)
	return jira, google, otherJira
}

func jiraState(t *testing.T, d *db.DB, id int64) (status, code string) {
	t.Helper()
	a, err := d.GetJiraAccount(id)
	require.NoError(t, err)
	return a.Status, a.Error
}

func googleState(t *testing.T, d *db.DB, id int64) (status, code string) {
	t.Helper()
	a, err := d.GetGoogleAccount(id)
	require.NoError(t, err)
	return a.Status, a.Error
}

// withAtlassianClient is sample(company) with another Atlassian client.
func withAtlassianClient(company, clientID string) companybundle.Bundle {
	b := sample(company)
	a := *b.Atlassian
	a.ClientID = clientID
	b.Atlassian = &a
	return b
}

func seenFile(s Store, slug string) string { return filepath.Join(s.Dir, ".forced-"+slug+".seen") }

func TestForcedBundleFirstSight_MarksNothing(t *testing.T) {
	d := db.OpenTestDB(t)
	s := newStore(t)
	jira, google, _ := forcedAccounts(t, d, "acme")

	changes, err := ApplyForcedChanges(d, s, wire(t, sample("Acme")))
	require.NoError(t, err)
	assert.Empty(t, changes)

	st, _ := jiraState(t, d, jira)
	assert.Equal(t, "ok", st)
	st, _ = googleState(t, d, google)
	assert.Equal(t, "ok", st)
	fi, err := os.Stat(seenFile(s, "acme"))
	require.NoError(t, err, ".seen is written at first sight")
	assert.Equal(t, os.FileMode(0o600), fi.Mode().Perm())
	got, err := readSeen(s.Dir, "acme")
	require.NoError(t, err)
	assert.Equal(t, sample("Acme"), got)
}

func TestForcedBundleFirstSight_ComparesStored(t *testing.T) {
	d := db.OpenTestDB(t)
	s := newStore(t)
	require.NoError(t, s.Save("acme", sample("Acme")))
	jira, google, other := forcedAccounts(t, d, "acme")

	changes, err := ApplyForcedChanges(d, s, wire(t, withAtlassianClient("Acme", "acmeClientId02")))
	require.NoError(t, err)
	assert.Equal(t, []Change{{Vendor: "atlassian", Field: "client_id", Old: "acmeClientId01", New: "acmeClientId02"}}, changes)

	st, code := jiraState(t, d, jira)
	assert.Equal(t, "error", st)
	assert.Equal(t, ChangedAppCode, code)
	st, _ = googleState(t, d, google)
	assert.Equal(t, "ok", st, "an unchanged vendor is untouched")
	st, _ = jiraState(t, d, other)
	assert.Equal(t, "ok", st, "another company's account is untouched")

	got, ok, err := s.Get("acme", "")
	require.NoError(t, err)
	require.True(t, ok)
	assert.Equal(t, sample("Acme"), got.Bundle, "MDM never writes the stored file")
}

func TestForcedBundleChange_MarksChangedVendorsRelogin(t *testing.T) {
	d := db.OpenTestDB(t)
	s := newStore(t)
	jira, google, other := forcedAccounts(t, d, "acme")
	_, err := ApplyForcedChanges(d, s, wire(t, sample("Acme")))
	require.NoError(t, err)

	changed := wire(t, withAtlassianClient("Acme", "acmeClientId02"))
	changes, err := ApplyForcedChanges(d, s, changed)
	require.NoError(t, err)
	require.Len(t, changes, 1)

	// "Your company changed its Atlassian app — sign in again", never the
	// invalid_client "open the new link".
	st, code := jiraState(t, d, jira)
	assert.Equal(t, "error", st)
	assert.Equal(t, "company_changed_app", code)
	st, _ = googleState(t, d, google)
	assert.Equal(t, "ok", st)
	st, _ = jiraState(t, d, other)
	assert.Equal(t, "ok", st)

	// The record now holds the new bundle: the next start marks nothing, so
	// an account signed in again stays signed in.
	_, err = d.Exec(`UPDATE jira_accounts SET status = 'ok', error = '' WHERE id = ?`, jira)
	require.NoError(t, err)
	changes, err = ApplyForcedChanges(d, s, changed)
	require.NoError(t, err)
	assert.Empty(t, changes)
	st, _ = jiraState(t, d, jira)
	assert.Equal(t, "ok", st)
}

func TestForcedBundle_NoneTouchesNothing(t *testing.T) {
	d := db.OpenTestDB(t)
	s := newStore(t)
	changes, err := ApplyForcedChanges(d, s, "")
	require.NoError(t, err)
	assert.Empty(t, changes)
	_, err = os.Stat(s.Dir)
	assert.True(t, os.IsNotExist(err), "no forced bundle writes nothing")
}

func TestForcedBundle_RefusedIsError(t *testing.T) {
	_, err := ApplyForcedChanges(db.OpenTestDB(t), newStore(t), "not a bundle")
	require.Error(t, err)
}

// TestForcedSlug_PinnedBySeen pins a forced company's slug through its
// .forced-<slug>.seen: removing the file whose clash gave it a suffix, or the
// profile itself, never moves it (its accounts carry it).
func TestForcedSlug_PinnedBySeen(t *testing.T) {
	d := db.OpenTestDB(t)
	s := newStore(t)
	require.NoError(t, s.Save("acme-inc", sample("acme-inc")))
	forced := wire(t, sample("Acme Inc"))

	_, err := ApplyForcedChanges(d, s, forced)
	require.NoError(t, err)
	slug, err := s.SlugFor("Acme Inc", forced)
	require.NoError(t, err)
	require.Equal(t, "acme-inc-2", slug)
	require.FileExists(t, seenFile(s, "acme-inc-2"))

	require.NoError(t, os.Remove(filepath.Join(s.Dir, "acme-inc.json")))
	entries, _, err := s.LoadAll(forced)
	require.NoError(t, err)
	require.Len(t, entries, 1)
	assert.Equal(t, Entry{Slug: "acme-inc-2", Bundle: sample("Acme Inc"), Forced: true}, entries[0])

	// The profile removed: the company keeps its slug; another company
	// slugging alike never takes it.
	slug, err = s.SlugFor("Acme Inc", "")
	require.NoError(t, err)
	assert.Equal(t, "acme-inc-2", slug)
	slug, err = s.SlugFor("ACME inc", "")
	require.NoError(t, err)
	assert.Equal(t, "acme-inc", slug)
	slug, err = s.SlugFor("ACME inc", forced)
	require.NoError(t, err)
	assert.Equal(t, "acme-inc", slug)
}

// TestForcedSlug_DamagedSeenKeepsSlug pins that an unreadable record never
// moves a forced company to a new slug (its accounts carry the old one): it
// is a LoadError, the company keeps the slug, and the record is rewritten.
func TestForcedSlug_DamagedSeenKeepsSlug(t *testing.T) {
	d := db.OpenTestDB(t)
	s := newStore(t)
	forced := wire(t, sample("Acme"))
	_, err := ApplyForcedChanges(d, s, forced)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(seenFile(s, "acme"), []byte("garbage"), 0o600))

	entries, errs, err := s.LoadAll(forced)
	require.NoError(t, err)
	require.Len(t, entries, 1)
	assert.Equal(t, "acme", entries[0].Slug)
	require.Len(t, errs, 1)
	assert.Equal(t, ".forced-acme.seen", errs[0].File)
	// The profile removed, an unreadable pin stays reserved: its owner is
	// unknown, so no company takes it.
	slug, err := s.SlugFor("ACME", "")
	require.NoError(t, err)
	assert.Equal(t, "acme-2", slug)

	_, err = ApplyForcedChanges(d, s, forced)
	require.NoError(t, err)
	got, err := readSeen(s.Dir, "acme")
	require.NoError(t, err)
	assert.Equal(t, sample("Acme"), got)
	assert.NoFileExists(t, seenFile(s, "acme-2"))
}

// TestForcedBundle_StoredAfterSeenIsBaseline: the profile removed, a link
// stores another Atlassian app and the person signs in with it; the profile
// put back with its old bundle marks the Atlassian accounts, though the
// bundle equals the record.
func TestForcedBundle_StoredAfterSeenIsBaseline(t *testing.T) {
	d := db.OpenTestDB(t)
	s := newStore(t)
	jira, google, _ := forcedAccounts(t, d, "acme")
	forced := wire(t, sample("Acme"))
	_, err := ApplyForcedChanges(d, s, forced)
	require.NoError(t, err)
	past := time.Now().Add(-time.Hour)
	require.NoError(t, os.Chtimes(seenFile(s, "acme"), past, past))
	require.NoError(t, s.Save("acme", withAtlassianClient("Acme", "acmeClientId02")))

	changes, err := ApplyForcedChanges(d, s, forced)
	require.NoError(t, err)
	assert.Equal(t, []Change{{Vendor: "atlassian", Field: "client_id", Old: "acmeClientId02", New: "acmeClientId01"}}, changes)
	st, code := jiraState(t, d, jira)
	assert.Equal(t, "error", st)
	assert.Equal(t, ChangedAppCode, code)
	st, _ = googleState(t, d, google)
	assert.Equal(t, "ok", st)
}

// TestForcedSlug_OnePinPerCompany: when the forced company's slug follows a
// stored file under another slug, its old record goes.
func TestForcedSlug_OnePinPerCompany(t *testing.T) {
	d := db.OpenTestDB(t)
	s := newStore(t)
	require.NoError(t, writeSeen(s.Dir, "acme-old", sample("Acme")))
	require.NoError(t, s.Save("acme", sample("Acme")))

	_, err := ApplyForcedChanges(d, s, wire(t, sample("Acme")))
	require.NoError(t, err)
	assert.FileExists(t, seenFile(s, "acme"))
	assert.NoFileExists(t, seenFile(s, "acme-old"))
}

// TestForcedSlug_PinnedSlugNeverGivenAway pins that a pinned slug is never
// handed to another company, even while its own file is gone.
func TestForcedSlug_PinnedSlugNeverGivenAway(t *testing.T) {
	d := db.OpenTestDB(t)
	s := newStore(t)
	_, err := ApplyForcedChanges(d, s, wire(t, sample("Acme")))
	require.NoError(t, err)

	slug, err := s.SlugFor("ACME", "")
	require.NoError(t, err)
	assert.Equal(t, "acme-2", slug)
}
