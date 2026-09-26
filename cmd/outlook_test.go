package cmd

import (
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/imap"
)

func TestOutlookCommandRegistered(t *testing.T) {
	found := false
	for _, c := range rootCmd.Commands() {
		if c.Name() == "outlook" {
			found = true
			names := map[string]bool{}
			for _, sub := range c.Commands() {
				names[sub.Name()] = true
			}
			for _, want := range []string{"login", "logout"} {
				if !names[want] {
					t.Errorf("missing subcommand %s", want)
				}
			}
		}
	}
	if !found {
		t.Fatal("outlook command not registered")
	}
}

func TestOutlookLogoutRequiresAccountIDArg(t *testing.T) {
	assert.Error(t, outlookLogoutCmd.Args(outlookLogoutCmd, nil))
	assert.Error(t, outlookLogoutCmd.Args(outlookLogoutCmd, []string{"1", "2"}))
	assert.NoError(t, outlookLogoutCmd.Args(outlookLogoutCmd, []string{"1"}))
}

// TestOutlookLogout_CallsThroughToDeleteEmailAccount covers fix #5:
// `outlook logout` must actually delete the email_accounts row, not just
// exit 0.
func TestOutlookLogout_CallsThroughToDeleteEmailAccount(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	defer database.Close()

	id, err := database.CreateEmailAccount(db.EmailAccount{
		Provider: "outlook", EmailAddress: "me@outlook.com",
		Host: outlookIMAPHost, Port: outlookIMAPPort, Security: "ssl", Folder: "INBOX",
	})
	require.NoError(t, err)

	buf := new(strings.Builder)
	outlookLogoutCmd.SetOut(buf)

	err = outlookLogoutCmd.RunE(outlookLogoutCmd, []string{strconv.FormatInt(id, 10)})
	require.NoError(t, err)

	_, err = database.GetEmailAccount(id)
	assert.Error(t, err, "account row must actually be deleted, not just report success")
}

// TestFinishOutlookLogin_ScopeRejectedNeverPersists proves the composition a
// unit test on ValidateGrantedScopes alone can't: a token whose granted scope
// is missing IMAP access must never reach createEmailAccountWithCredentials,
// so no email_accounts row is created for it.
func TestFinishOutlookLogin_ScopeRejectedNeverPersists(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	defer database.Close()

	token := &imap.MicrosoftOAuthToken{RefreshToken: "rt", Scope: "openid email offline_access"}
	_, err = finishOutlookLogin(database, cfg.WorkspaceDir(), "me@outlook.com", token, "", &strings.Builder{})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "IMAP")

	accounts, err := database.ListEmailAccounts()
	require.NoError(t, err)
	assert.Empty(t, accounts, "a scope-rejected token must not persist an account row")
}

// TestFinishOutlookLogin_GrantedScopePersists is the positive counterpart:
// a token with the IMAP scope (and no scope field validation to fail on)
// does persist a real row.
func TestFinishOutlookLogin_GrantedScopePersists(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	defer database.Close()

	token := &imap.MicrosoftOAuthToken{RefreshToken: "rt", Scope: "openid email offline_access https://outlook.office.com/IMAP.AccessAsUser.All"}
	id, err := finishOutlookLogin(database, cfg.WorkspaceDir(), "me@outlook.com", token, "", &strings.Builder{})
	require.NoError(t, err)

	acct, err := database.GetEmailAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "me@outlook.com", acct.EmailAddress)
}

func TestOutlookLogout_InvalidAccountID(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	err := outlookLogoutCmd.RunE(outlookLogoutCmd, []string{"not-a-number"})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "invalid account id")
}
