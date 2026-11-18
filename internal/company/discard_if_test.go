package company

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestCompanyDraft_DiscardIfOnlyThePublishedDraft(t *testing.T) {
	now := time.Date(2026, 11, 17, 9, 30, 0, 0, time.UTC)
	s := Store{Dir: filepath.Join(t.TempDir(), "company")}
	load := func() Draft {
		t.Helper()
		d, st, _, err := s.LoadDraft(now)
		require.NoError(t, err)
		require.Equal(t, DraftOK, st)
		return d
	}
	require.NoError(t, s.SaveDraft(Draft{Company: "Acme", Services: []string{"linear"}, StartedAt: now}))
	published := load()

	// Saved again meanwhile: kept.
	require.NoError(t, s.SaveDraft(Draft{Company: "Acme", Services: []string{"linear", "microsoft"}, StartedAt: now}))
	deleted, err := s.DiscardDraftIf(published)
	require.NoError(t, err)
	assert.False(t, deleted)
	assert.Equal(t, []string{"linear", "microsoft"}, load().Services)

	// Unchanged: deleted with the set-aside drafts.
	published = load()
	bad := filepath.Join(s.Dir, "draft.json.bad-20261101T000000Z")
	require.NoError(t, os.WriteFile(bad, []byte("{"), 0o600))
	deleted, err = s.DiscardDraftIf(published)
	require.NoError(t, err)
	assert.True(t, deleted)
	_, err = os.Lstat(filepath.Join(s.Dir, "draft.json"))
	assert.ErrorIs(t, err, os.ErrNotExist)
	_, err = os.Lstat(bad)
	assert.ErrorIs(t, err, os.ErrNotExist)

	// Gone or unreadable now: kept, not an error.
	deleted, err = s.DiscardDraftIf(published)
	require.NoError(t, err)
	assert.False(t, deleted)
	require.NoError(t, os.WriteFile(filepath.Join(s.Dir, "draft.json"), []byte("{"), 0o600))
	deleted, err = s.DiscardDraftIf(published)
	require.NoError(t, err)
	assert.False(t, deleted)
	_, err = os.Lstat(filepath.Join(s.Dir, "draft.json"))
	assert.NoError(t, err, "an unreadable draft is never deleted by Publish")
}
