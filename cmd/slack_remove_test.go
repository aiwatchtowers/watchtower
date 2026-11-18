package cmd

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"testing"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	watchtowerslack "watchtower/internal/slack"
)

// revokeFake is a Slack server that records auth.revoke calls and whether the
// token file still existed when each one arrived.
type revokeFake struct {
	mu          sync.Mutex
	auths       []string
	fileExisted []bool
}

func (f *revokeFake) serve(t *testing.T, tokenPath string, status int, body string) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, statErr := os.Stat(tokenPath)
		f.mu.Lock()
		if r.URL.Path == "/auth.revoke" {
			f.auths = append(f.auths, r.Header.Get("Authorization"))
			f.fileExisted = append(f.fileExisted, statErr == nil)
		}
		f.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	old := slackRevokeAPIURL
	slackRevokeAPIURL = srv.URL + "/"
	t.Cleanup(func() { slackRevokeAPIURL = old })
}

func setupSlackRemove(t *testing.T) (*config.Config, *watchtowerslack.TokenStore, int64) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	writeLegacyConfig(t, "")
	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	id, err := database.CreateSlackAccount(db.SlackAccount{TeamID: "T1", Label: "Acme", CurrentUserID: "1:U1", Enabled: true})
	require.NoError(t, err)
	require.NoError(t, database.Close())
	store := watchtowerslack.NewTokenStore(cfg.WorkspaceDir(), id)
	require.NoError(t, store.Save(&watchtowerslack.Token{AccessToken: "xoxp-acme", TeamID: "T1"}))
	return cfg, store, id
}

func accountStatus(t *testing.T, cfg *config.Config, id int64) string {
	t.Helper()
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	defer database.Close()
	a, err := database.GetSlackAccount(id)
	require.NoError(t, err)
	return a.Status
}

func TestSlackRemove_RevokesBeforeDelete(t *testing.T) {
	cfg, store, id := setupSlackRemove(t)
	fake := &revokeFake{}
	fake.serve(t, store.Path(), http.StatusOK, `{"ok":true,"revoked":true}`)

	out := &bytes.Buffer{}
	cmd := &cobra.Command{}
	cmd.SetOut(out)
	require.NoError(t, runSlackRemove(cmd, []string{"1"}))

	assert.Equal(t, []string{"Bearer xoxp-acme"}, fake.auths, "exactly one auth.revoke with the account's token")
	assert.Equal(t, []bool{true}, fake.fileExisted, "the token file was still there when Slack was called")
	assert.False(t, store.Exists())
	assert.Equal(t, "removed", accountStatus(t, cfg, id))
	assert.NotContains(t, out.String(), "did not confirm")
}

func TestSlackRemove_RevokeFailureStillRemoves(t *testing.T) {
	for name, tc := range map[string]struct {
		status int
		body   string
	}{
		"server error": {http.StatusInternalServerError, `{}`},
		"not revoked":  {http.StatusOK, `{"ok":true,"revoked":false}`},
		"invalid_auth": {http.StatusOK, `{"ok":false,"error":"invalid_auth"}`},
	} {
		t.Run(name, func(t *testing.T) {
			cfg, store, id := setupSlackRemove(t)
			fake := &revokeFake{}
			fake.serve(t, store.Path(), tc.status, tc.body)

			out := &bytes.Buffer{}
			cmd := &cobra.Command{}
			cmd.SetOut(out)
			require.NoError(t, runSlackRemove(cmd, []string{"1"}))

			assert.Len(t, fake.auths, 1)
			assert.False(t, store.Exists())
			assert.Equal(t, "removed", accountStatus(t, cfg, id))
			assert.Contains(t, out.String(), "Slack did not confirm the token was revoked; it may stay valid until a workspace admin removes the app")
		})
	}
}

func TestSlackRemove_UnreadableTokenFileWarnsAndRemoves(t *testing.T) {
	cfg, store, id := setupSlackRemove(t)
	require.NoError(t, os.WriteFile(store.Path(), []byte("{not json"), 0o600))

	out := &bytes.Buffer{}
	cmd := &cobra.Command{}
	cmd.SetOut(out)
	require.NoError(t, runSlackRemove(cmd, []string{"1"}))

	assert.False(t, store.Exists())
	assert.Equal(t, "removed", accountStatus(t, cfg, id))
	assert.Contains(t, out.String(), "Slack did not confirm the token was revoked")
}

func TestSlackRemove_NoTokenFileIsSilent(t *testing.T) {
	cfg, store, id := setupSlackRemove(t)
	require.NoError(t, store.Delete())

	out := &bytes.Buffer{}
	cmd := &cobra.Command{}
	cmd.SetOut(out)
	require.NoError(t, runSlackRemove(cmd, []string{"1"}))

	assert.Equal(t, "removed", accountStatus(t, cfg, id))
	assert.NotContains(t, out.String(), "did not confirm")
}

// #1769 final review: a remove cancels a lease row scheduled while the
// workspace was live, so the purge gives the full 72 h notice from the pass
// that sees the remove instead of running at the old due date.
func TestSlackRemove_CancelsScheduledPurge(t *testing.T) {
	cfg, store, id := setupSlackRemove(t)
	fake := &revokeFake{}
	fake.serve(t, store.Path(), http.StatusOK, `{"ok":true,"revoked":true}`)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	_, err = database.ScheduleAccountPurge("slack", id, "lease", "2026-10-24T12:00:00Z")
	require.NoError(t, err)
	require.NoError(t, database.Close())

	cmd := &cobra.Command{}
	cmd.SetOut(&bytes.Buffer{})
	require.NoError(t, runSlackRemove(cmd, []string{"1"}))

	database, err = db.Open(cfg.DBPath())
	require.NoError(t, err)
	defer database.Close()
	open, err := database.ListAccountPurges(true)
	require.NoError(t, err)
	assert.Empty(t, open, "the live lease row is cancelled by the remove")
}

// #1769 final review: the output says when the kept data goes, and a failed
// revoke is also logged (to stderr, with the cause).
func TestSlackRemove_SaysWhenDataGoesAndLogsRevokeFailure(t *testing.T) {
	_, store, _ := setupSlackRemove(t)
	fake := &revokeFake{}
	fake.serve(t, store.Path(), http.StatusOK, `{"ok":true,"revoked":false}`)

	out, errOut := &bytes.Buffer{}, &bytes.Buffer{}
	cmd := &cobra.Command{}
	cmd.SetOut(out)
	cmd.SetErr(errOut)
	require.NoError(t, runSlackRemove(cmd, []string{"1"}))

	assert.Contains(t, out.String(), "Removed account 1. Its synced data was kept. "+
		"With account data deletion on, it is deleted 72 hours after Watchtower's next pass.")
	assert.Contains(t, errOut.String(), "revoking slack account 1")
	assert.Contains(t, errOut.String(), "did not revoke the token")
}

// The Desktop finds the warning in the CLI output by its exact text
// (SlackRevokeNotice.cliWarning); the two must not drift apart.
func TestSlackRevokeWarning_MatchesDesktopModel(t *testing.T) {
	src, err := os.ReadFile("../WatchtowerDesktop/Sources/WatchtowerCore/Models/SlackRevokeNotice.swift")
	require.NoError(t, err)
	assert.Contains(t, string(src), `"`+slackRevokeWarning+`"`)
}
