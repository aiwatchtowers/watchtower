package cmd

import (
	"bytes"
	"path/filepath"
	"testing"

	"watchtower/internal/db"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestAccountRename_RenamesAndRefusesEmpty(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	writeLegacyConfig(t, "")

	dbPath := filepath.Join(home, ".local", "share", "watchtower", "test", "watchtower.db")
	database, err := db.Open(dbPath)
	require.NoError(t, err)
	id, err := database.CreateEmailAccount(db.EmailAccount{Provider: "outlook", EmailAddress: "a@example.com", Security: "ssl"})
	require.NoError(t, err)
	require.NoError(t, database.Close())

	run := func(args ...string) (string, error) {
		cmd := newAccountRenameCmd("email_accounts", "mailbox")
		var out bytes.Buffer
		cmd.SetOut(&out)
		cmd.SetErr(&bytes.Buffer{})
		cmd.SetArgs(args)
		err := cmd.Execute()
		return out.String(), err
	}

	out, err := run("1", "Work mail")
	require.NoError(t, err)
	assert.Contains(t, out, "Renamed account 1")

	// The Desktop passes "--" so a name starting with "-" is not a flag.
	_, err = run("--", "1", "-Work mail")
	require.NoError(t, err)

	_, err = run("1", "  ")
	require.Error(t, err, "an empty name is refused")
	_, err = run("x", "Name")
	require.Error(t, err, "a non-numeric id is refused")
	_, err = run("42", "Name")
	require.Error(t, err, "a missing account is refused")

	database, err = db.Open(dbPath)
	require.NoError(t, err)
	defer database.Close()
	acct, err := database.GetEmailAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "-Work mail", acct.Label)
}

// Each source's rename touches its own table only: account ids start at 1 in
// every table, so a wrong binding would quietly rename another source's
// account.
func TestAccountRename_EachSourceRenamesItsOwnTable(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	writeLegacyConfig(t, "")

	dbPath := filepath.Join(home, ".local", "share", "watchtower", "test", "watchtower.db")
	database, err := db.Open(dbPath)
	require.NoError(t, err)
	_, err = database.Exec(`INSERT INTO slack_accounts (id, label) VALUES (1, 'orig');
        INSERT INTO jira_accounts (id, label) VALUES (1, 'orig');
        INSERT INTO google_accounts (id, label) VALUES (1, 'orig');
        INSERT INTO email_accounts (id, provider, label) VALUES (1, 'imap', 'orig');
        INSERT INTO calendar_accounts (id, provider, label) VALUES (1, 'caldav', 'orig')`)
	require.NoError(t, err)
	require.NoError(t, database.Close())

	tables := map[string]string{
		"slack": "slack_accounts", "jira": "jira_accounts", "google": "google_accounts",
		"imap": "email_accounts", "outlook": "email_accounts", "caldav": "calendar_accounts",
	}
	for source, table := range tables {
		rootCmd.SetOut(&bytes.Buffer{})
		rootCmd.SetErr(&bytes.Buffer{})
		rootCmd.SetArgs([]string{source, "rename", "--", "1", source + "-name"})
		err := rootCmd.Execute()
		rootCmd.SetArgs(nil)
		require.NoError(t, err, source)

		database, err := db.Open(dbPath)
		require.NoError(t, err)
		for _, other := range []string{"slack_accounts", "jira_accounts", "google_accounts", "email_accounts", "calendar_accounts"} {
			var label string
			require.NoError(t, database.QueryRow(`SELECT label FROM `+other+` WHERE id = 1`).Scan(&label))
			if other == table {
				assert.Equal(t, source+"-name", label, "%s rename → %s", source, other)
			} else {
				assert.NotEqual(t, source+"-name", label, "%s rename must not touch %s", source, other)
			}
		}
		require.NoError(t, database.Close())
	}
}
