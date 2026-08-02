package cmd

import (
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/imap"
)

func TestImapCommandRegistered(t *testing.T) {
	found := false
	for _, c := range rootCmd.Commands() {
		if c.Name() == "imap" {
			found = true
			names := map[string]bool{}
			for _, sub := range c.Commands() {
				names[sub.Name()] = true
			}
			for _, want := range []string{"add", "remove", "list"} {
				if !names[want] {
					t.Errorf("missing subcommand %s", want)
				}
			}
		}
	}
	if !found {
		t.Fatal("imap command not registered")
	}
}

func TestImapRemoveRequiresAccountIDArg(t *testing.T) {
	assert.Error(t, imapRemoveCmd.Args(imapRemoveCmd, nil))
	assert.Error(t, imapRemoveCmd.Args(imapRemoveCmd, []string{"1", "2"}))
	assert.NoError(t, imapRemoveCmd.Args(imapRemoveCmd, []string{"1"}))
}

func TestImapAddRequiresHostAndUsername(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	oldHost, oldUsername := imapAddFlagHost, imapAddFlagUsername
	defer func() { imapAddFlagHost, imapAddFlagUsername = oldHost, oldUsername }()

	imapAddFlagHost = ""
	imapAddFlagUsername = ""
	err := imapAddCmd.RunE(imapAddCmd, nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "--host and --username are required")

	imapAddFlagHost = "imap.example.com"
	imapAddFlagUsername = ""
	err = imapAddCmd.RunE(imapAddCmd, nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "--host and --username are required")
}

func TestImapAddRejectsInvalidSecurity(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	oldHost, oldUsername, oldSecurity := imapAddFlagHost, imapAddFlagUsername, imapAddFlagSecurity
	defer func() {
		imapAddFlagHost, imapAddFlagUsername, imapAddFlagSecurity = oldHost, oldUsername, oldSecurity
	}()

	imapAddFlagHost = "imap.example.com"
	imapAddFlagUsername = "me@example.com"
	imapAddFlagSecurity = "bogus"

	err := imapAddCmd.RunE(imapAddCmd, nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "--security must be one of")
}

// TestReadPassword_PipedStdin covers readPassword's non-interactive path: a
// piped (non-terminal) stdin is read in full and trimmed, never prompted for.
func TestReadPassword_PipedStdin(t *testing.T) {
	c := imapAddCmd
	c.SetIn(strings.NewReader("hunter2\n"))
	defer c.SetIn(nil)

	got, err := readPassword(c)
	require.NoError(t, err)
	assert.Equal(t, "hunter2", got)
}

func TestReadPassword_TrimsWhitespace(t *testing.T) {
	c := imapAddCmd
	c.SetIn(strings.NewReader("  spaced-secret  \n"))
	defer c.SetIn(nil)

	got, err := readPassword(c)
	require.NoError(t, err)
	assert.Equal(t, "spaced-secret", got)
}

// TestImapRemove_CallsThroughToDeleteEmailAccount covers fix #5: `imap
// remove` must actually delete the email_accounts row, not just exit 0.
func TestImapRemove_CallsThroughToDeleteEmailAccount(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	defer database.Close()

	id, err := database.CreateEmailAccount(db.EmailAccount{
		Provider: "imap", EmailAddress: "me@example.com",
		Host: "imap.example.com", Port: 993, Security: "ssl", Folder: "INBOX",
	})
	require.NoError(t, err)

	buf := new(strings.Builder)
	imapRemoveCmd.SetOut(buf)
	imapRemoveCmd.SetErr(io.Discard)

	err = imapRemoveCmd.RunE(imapRemoveCmd, []string{strconv.FormatInt(id, 10)})
	require.NoError(t, err)

	_, err = database.GetEmailAccount(id)
	assert.Error(t, err, "account row must actually be deleted, not just report success")
}

// TestCreateEmailAccountWithCredentials_RollsBackOnSaveFailure covers fix #3:
// if store.Save fails after the email_accounts row was already created, the
// row must be rolled back rather than left as an orphaned "ok"-status ghost
// account that can never actually sync (no credentials were ever persisted).
func TestCreateEmailAccountWithCredentials_RollsBackOnSaveFailure(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	defer database.Close()

	// Force store.Save to fail: point the credentials directory underneath a
	// path component that is a regular file, so MkdirAll can't create it.
	blockerFile := filepath.Join(t.TempDir(), "blocker")
	require.NoError(t, os.WriteFile(blockerFile, []byte("x"), 0o600))
	badWorkspaceDir := filepath.Join(blockerFile, "sub")

	before, err := database.ListEmailAccounts()
	require.NoError(t, err)

	_, err = createEmailAccountWithCredentials(database, badWorkspaceDir, db.EmailAccount{
		Provider: "imap", EmailAddress: "me@example.com",
		Host: "imap.example.com", Port: 993, Security: "ssl", Folder: "INBOX",
	}, &imap.Credentials{Password: "secret"}, io.Discard)
	require.Error(t, err)

	after, err := database.ListEmailAccounts()
	require.NoError(t, err)
	assert.Equal(t, len(before), len(after), "the orphaned account row must be rolled back on credential-save failure")
}
