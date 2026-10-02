package cmd

import (
	"context"
	"errors"
	"os"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/caldav"
	"watchtower/internal/calendar"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/gmail"
	"watchtower/internal/imap"
	"watchtower/internal/jira"
)

// wiringTestConfig points the workspace (and so every per-account token and
// credential file) at a fresh temp HOME.
func wiringTestConfig(t *testing.T) *config.Config {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	return &config.Config{ActiveWorkspace: "test", Workspaces: map[string]*config.WorkspaceConfig{"test": {}}}
}

// stubGoogleClients replaces the calendar/gmail client constructors for the
// test. Each stub fails with its service's ErrAuthRevoked for the refresh
// tokens in revoked, succeeds otherwise, and records the tokens it saw.
func stubGoogleClients(t *testing.T, calRevoked, gmRevoked map[string]bool) (calSeen, gmSeen *[]string) {
	t.Helper()
	origCal, origGm := newCalendarClient, newGmailClient
	t.Cleanup(func() { newCalendarClient, newGmailClient = origCal, origGm })
	calSeen, gmSeen = &[]string{}, &[]string{}
	newCalendarClient = func(_ context.Context, rt string, _ calendar.GoogleOAuthConfig) (*calendar.Client, error) {
		*calSeen = append(*calSeen, rt)
		if calRevoked[rt] {
			return nil, calendar.ErrAuthRevoked
		}
		return &calendar.Client{}, nil
	}
	newGmailClient = func(_ context.Context, rt string, _ gmail.GoogleOAuthConfig) (*gmail.Client, error) {
		*gmSeen = append(*gmSeen, rt)
		if gmRevoked[rt] {
			return nil, gmail.ErrAuthRevoked
		}
		return &gmail.Client{}, nil
	}
	return calSeen, gmSeen
}

func newGoogleAccount(t *testing.T, database *db.DB, cfg *config.Config, label, refreshToken string) int64 {
	t.Helper()
	id, err := database.CreateGoogleAccount(db.GoogleAccount{Label: label, CalendarEnabled: true, GmailEnabled: true})
	require.NoError(t, err)
	if refreshToken != "" {
		require.NoError(t, calendar.NewAccountTokenStore(cfg.WorkspaceDir(), id).Save(&calendar.OAuthToken{RefreshToken: refreshToken}))
	}
	return id
}

func googleStatus(t *testing.T, database *db.DB, id int64) (string, string) {
	t.Helper()
	acct, err := database.GetGoogleAccount(id)
	require.NoError(t, err)
	return acct.Status, acct.Error
}

// TestWireGoogleSyncers_PerAccountIsolation pins the fan-out contract: each
// broken account records only its own status, an already-flagged account is
// not churned, and a failure on one account (or one service of an account)
// never keeps the others from being wired.
func TestWireGoogleSyncers_PerAccountIsolation(t *testing.T) {
	cfg := wiringTestConfig(t)
	cfg.Calendar.Enabled, cfg.Gmail.Enabled = true, true
	database := db.OpenTestDB(t)

	noToken := newGoogleAccount(t, database, cfg, "no token", "")
	revokedNoToken := newGoogleAccount(t, database, cfg, "already revoked", "")
	require.NoError(t, database.SetGoogleAccountAuthState(revokedNoToken, "revoked", "user revoked access"))
	corrupt := newGoogleAccount(t, database, cfg, "corrupt token", "")
	require.NoError(t, os.MkdirAll(cfg.WorkspaceDir(), 0o700))
	require.NoError(t, os.WriteFile(calendar.NewAccountTokenStore(cfg.WorkspaceDir(), corrupt).Path(), []byte("{not json"), 0o600))
	calRevoked := newGoogleAccount(t, database, cfg, "calendar revoked", "rt-cal-revoked")
	healthy := newGoogleAccount(t, database, cfg, "healthy", "rt-healthy")

	calSeen, gmSeen := stubGoogleClients(t, map[string]bool{"rt-cal-revoked": true}, nil)
	cal, gm := wireGoogleSyncers(context.Background(), cfg, database, quietTestLogger())

	assert.Len(t, cal, 1, "only the healthy account gets a calendar syncer")
	assert.Len(t, gm, 2, "a calendar failure must not cost the same account its gmail syncer")
	assert.Equal(t, []string{"rt-cal-revoked", "rt-healthy"}, *calSeen, "accounts after a failing one are still wired")
	assert.Equal(t, []string{"rt-cal-revoked", "rt-healthy"}, *gmSeen)

	status, msg := googleStatus(t, database, noToken)
	assert.Equal(t, "error", status)
	assert.Contains(t, msg, "no token file")
	status, msg = googleStatus(t, database, revokedNoToken)
	assert.Equal(t, "revoked", status, "wiring must not overwrite an existing non-ok status")
	assert.Equal(t, "user revoked access", msg)
	status, msg = googleStatus(t, database, corrupt)
	assert.Equal(t, "error", status, "an unreadable token file must surface, not leave a silently dead ok account")
	assert.Contains(t, msg, "unreadable token file")
	status, _ = googleStatus(t, database, calRevoked)
	assert.Equal(t, "revoked", status, "ErrAuthRevoked records revoked, not a plain error")
	status, _ = googleStatus(t, database, healthy)
	assert.Equal(t, "ok", status)
}

// TestWireGoogleSyncers_GlobalTogglesGateEachKind pins that the global
// cfg.Calendar/cfg.Gmail switches gate their syncer kind for every account,
// without even building the disabled client.
func TestWireGoogleSyncers_GlobalTogglesGateEachKind(t *testing.T) {
	cfg := wiringTestConfig(t)
	cfg.Calendar.Enabled, cfg.Gmail.Enabled = false, true
	database := db.OpenTestDB(t)
	newGoogleAccount(t, database, cfg, "a", "rt-a")

	calSeen, _ := stubGoogleClients(t, nil, nil)
	cal, gm := wireGoogleSyncers(context.Background(), cfg, database, quietTestLogger())
	assert.Empty(t, cal)
	assert.Len(t, gm, 1)
	assert.Empty(t, *calSeen, "a disabled calendar phase must not build a calendar client")
}

// TestBuildAtlassianClients_StatusWriter pins wireJiraSyncers' status writer:
// a missing token or cloud_id flips only a currently-ok account to "error",
// an account already flagged keeps its status, and a broken account never
// keeps a healthy one from getting its client.
func TestBuildAtlassianClients_StatusWriter(t *testing.T) {
	cfg := wiringTestConfig(t)
	database := db.OpenTestDB(t)
	create := func(cloudID, label string, token bool) int64 {
		id, err := database.CreateJiraAccount(db.JiraAccount{CloudID: cloudID, Label: label})
		require.NoError(t, err)
		if token {
			require.NoError(t, jira.NewTokenStore(cfg.WorkspaceDir(), id).Save(&jira.OAuthToken{RefreshToken: "rt"}))
		}
		return id
	}
	noToken := create("cloud-a", "no token", false)
	noCloud := create("", "no cloud id", true)
	revoked := create("cloud-c", "already revoked", false)
	require.NoError(t, database.SetJiraAccountAuthState(revoked, "revoked", "grant revoked"))
	healthy := create("cloud-d", "healthy", true)

	accounts, clients := buildAtlassianClients(cfg, database, quietTestLogger())

	assert.Len(t, accounts, 4)
	assert.Len(t, clients, 1)
	assert.NotNil(t, clients[healthy], "the healthy account after the broken ones must get its client")

	for _, id := range []int64{noToken, noCloud} {
		acct, err := database.GetJiraAccount(id)
		require.NoError(t, err)
		assert.Equal(t, "error", acct.Status, "account %d", id)
		assert.Contains(t, acct.Error, "re-login required")
	}
	acct, err := database.GetJiraAccount(revoked)
	require.NoError(t, err)
	assert.Equal(t, "revoked", acct.Status, "only a currently-ok account may be flipped")
	assert.Equal(t, "grant revoked", acct.Error)
	acct, err = database.GetJiraAccount(healthy)
	require.NoError(t, err)
	assert.Equal(t, "ok", acct.Status)
}

// TestWireImapSyncers_BrokenMailboxDoesNotBlockOthers pins that a mailbox
// whose credentials cannot be loaded (imap or outlook) records its own error
// and the rest are still wired.
func TestWireImapSyncers_BrokenMailboxDoesNotBlockOthers(t *testing.T) {
	cfg := wiringTestConfig(t)
	database := db.OpenTestDB(t)
	create := func(provider, addr string) int64 {
		id, err := database.CreateEmailAccount(db.EmailAccount{
			Provider: provider, EmailAddress: addr, Host: "imap.example.com", Port: 993, Security: "ssl", Folder: "INBOX",
		})
		require.NoError(t, err)
		return id
	}
	brokenImap := create("imap", "a@example.com")
	brokenOutlook := create("outlook", "b@example.com")
	healthyImap := create("imap", "c@example.com")
	require.NoError(t, imap.NewCredentialStore(cfg.WorkspaceDir(), healthyImap).Save(&imap.Credentials{Password: "pw"}))
	healthyOutlook := create("outlook", "d@example.com")
	require.NoError(t, imap.NewCredentialStore(cfg.WorkspaceDir(), healthyOutlook).Save(&imap.Credentials{RefreshToken: "rt"}))

	syncers := wireImapSyncers(cfg, database, quietTestLogger())
	assert.Len(t, syncers, 2)

	for _, id := range []int64{brokenImap, brokenOutlook} {
		acct, err := database.GetEmailAccount(id)
		require.NoError(t, err)
		assert.Equal(t, "error", acct.Status, "account %d", id)
	}
	for _, id := range []int64{healthyImap, healthyOutlook} {
		acct, err := database.GetEmailAccount(id)
		require.NoError(t, err)
		assert.Equal(t, "ok", acct.Status, "account %d", id)
	}
}

// TestWireCalDAVSyncers_BrokenAccountDoesNotBlockOthers is the CalDAV analog.
func TestWireCalDAVSyncers_BrokenAccountDoesNotBlockOthers(t *testing.T) {
	cfg := wiringTestConfig(t)
	database := db.OpenTestDB(t)
	broken, err := database.CreateCalendarAccount(db.CalendarAccount{Provider: "caldav", Username: "a", URL: "https://dav.example.com"})
	require.NoError(t, err)
	healthy, err := database.CreateCalendarAccount(db.CalendarAccount{Provider: "caldav", Username: "b", URL: "https://dav.example.com"})
	require.NoError(t, err)
	require.NoError(t, caldav.NewCredentialStore(cfg.WorkspaceDir(), healthy).Save(&caldav.Credentials{Password: "pw"}))

	syncers := wireCalDAVSyncers(cfg, database, quietTestLogger())
	assert.Len(t, syncers, 1)

	acct, err := database.GetCalendarAccount(broken)
	require.NoError(t, err)
	assert.Equal(t, "error", acct.Status)
	acct, err = database.GetCalendarAccount(healthy)
	require.NoError(t, err)
	assert.Equal(t, "ok", acct.Status)
}

// newOutlookAuthFixture wires one Outlook mailbox holding refresh token
// "rt-old" and returns its RefreshFunc plus the credential store.
func newOutlookAuthFixture(t *testing.T) (*db.DB, int64, func(context.Context) (string, error), *imap.CredentialStore) {
	t.Helper()
	cfg := wiringTestConfig(t)
	database := db.OpenTestDB(t)
	id, err := database.CreateEmailAccount(db.EmailAccount{Provider: "outlook", EmailAddress: "a@example.com", Security: "ssl"})
	require.NoError(t, err)
	acct, err := database.GetEmailAccount(id)
	require.NoError(t, err)
	store := imap.NewCredentialStore(cfg.WorkspaceDir(), id)
	require.NoError(t, store.Save(&imap.Credentials{RefreshToken: "rt-old"}))

	auth := outlookAuthenticator(cfg, database, acct, quietTestLogger())
	ra, ok := auth.(imap.RefreshingXOAUTH2Auth)
	require.True(t, ok, "outlookAuthenticator returned %T", auth)
	return database, id, ra.RefreshFunc, store
}

func stubOutlookRefresh(t *testing.T, fn func(rt string) (string, string, error)) {
	t.Helper()
	orig := refreshOutlookAccessToken
	t.Cleanup(func() { refreshOutlookAccessToken = orig })
	refreshOutlookAccessToken = func(_ context.Context, _ imap.MicrosoftOAuthConfig, rt string) (string, string, error) {
		return fn(rt)
	}
}

// TestOutlookAuthenticator_PersistsRotatedRefreshToken pins that a refresh
// token Microsoft rotates is saved, and the next refresh sends the new one —
// otherwise the account breaks once the old token expires.
func TestOutlookAuthenticator_PersistsRotatedRefreshToken(t *testing.T) {
	_, _, refresh, store := newOutlookAuthFixture(t)
	var sent []string
	stubOutlookRefresh(t, func(rt string) (string, string, error) {
		sent = append(sent, rt)
		return "access-" + rt, "rt-new", nil
	})

	at, err := refresh(context.Background())
	require.NoError(t, err)
	assert.Equal(t, "access-rt-old", at)
	creds, err := store.Load()
	require.NoError(t, err)
	assert.Equal(t, "rt-new", creds.RefreshToken, "the rotated refresh token must be persisted")

	_, err = refresh(context.Background())
	require.NoError(t, err)
	assert.Equal(t, []string{"rt-old", "rt-new"}, sent, "the next refresh must use the rotated token")
}

// TestOutlookAuthenticator_NoRotationKeepsToken pins that an empty refresh
// token in the response (no rotation) leaves the stored one intact.
func TestOutlookAuthenticator_NoRotationKeepsToken(t *testing.T) {
	_, _, refresh, store := newOutlookAuthFixture(t)
	stubOutlookRefresh(t, func(string) (string, string, error) { return "access", "", nil })

	_, err := refresh(context.Background())
	require.NoError(t, err)
	creds, err := store.Load()
	require.NoError(t, err)
	assert.Equal(t, "rt-old", creds.RefreshToken)
}

// TestOutlookAuthenticator_RefreshFailureRecordsError pins that a failed
// token exchange surfaces on the account row and keeps the stored token.
func TestOutlookAuthenticator_RefreshFailureRecordsError(t *testing.T) {
	database, id, refresh, store := newOutlookAuthFixture(t)
	stubOutlookRefresh(t, func(string) (string, string, error) { return "", "", errors.New("invalid_grant") })

	_, err := refresh(context.Background())
	require.Error(t, err)
	acct, err := database.GetEmailAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "error", acct.Status)
	assert.Contains(t, acct.Error, "invalid_grant")
	creds, err := store.Load()
	require.NoError(t, err)
	assert.Equal(t, "rt-old", creds.RefreshToken)
}

// TestRunSyncNow_NoDaemonFails pins that `sync --now` without a running
// daemon fails with a hint instead of syncing in-process (the daemon's flock
// exists to keep a second syncer out).
func TestRunSyncNow_NoDaemonFails(t *testing.T) {
	cfg, pidPath := syncStopTestConfig(t)
	_, statErr := os.Stat(pidPath)
	require.True(t, os.IsNotExist(statErr), "fixture must start without a pid file")

	err := runSyncNow(cfg)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "no daemon is running")
}
