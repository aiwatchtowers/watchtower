package cmd

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/caldav"
	"watchtower/internal/config"
	"watchtower/internal/db"
)

func TestCalDAVCommandRegistered(t *testing.T) {
	found := false
	for _, c := range rootCmd.Commands() {
		if c.Name() == "caldav" {
			found = true
			names := map[string]bool{}
			for _, sub := range c.Commands() {
				names[sub.Name()] = true
			}
			for _, want := range []string{"add", "add-ics", "remove", "list"} {
				if !names[want] {
					t.Errorf("missing subcommand %s", want)
				}
			}
		}
	}
	if !found {
		t.Fatal("caldav command not registered")
	}
}

func TestCalDAVRemoveRequiresAccountIDArg(t *testing.T) {
	assert.Error(t, caldavRemoveCmd.Args(caldavRemoveCmd, nil))
	assert.Error(t, caldavRemoveCmd.Args(caldavRemoveCmd, []string{"1", "2"}))
	assert.NoError(t, caldavRemoveCmd.Args(caldavRemoveCmd, []string{"1"}))
}

func TestCalDAVAddRequiresURLAndUsername(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	oldURL, oldUsername := caldavAddFlagURL, caldavAddFlagUsername
	defer func() { caldavAddFlagURL, caldavAddFlagUsername = oldURL, oldUsername }()

	caldavAddFlagURL = ""
	caldavAddFlagUsername = ""
	err := caldavAddCmd.RunE(caldavAddCmd, nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "--url and --username are required")

	caldavAddFlagURL = "https://caldav.example.com"
	caldavAddFlagUsername = ""
	err = caldavAddCmd.RunE(caldavAddCmd, nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "--url and --username are required")
}

// testICSBody is a minimal valid feed with one event tomorrow, so the
// add-ics connection test both fetches and parses successfully.
func testICSBody() string {
	tomorrow := time.Now().UTC().Add(24 * time.Hour)
	return strings.ReplaceAll(fmt.Sprintf(`BEGIN:VCALENDAR
VERSION:2.0
PRODID:-//Watchtower Test//EN
BEGIN:VEVENT
UID:cli-test-uid
DTSTAMP:20260101T000000Z
DTSTART:%s
DTEND:%s
SUMMARY:CLI test
END:VEVENT
END:VCALENDAR
`, tomorrow.Format("20060102T150405Z"), tomorrow.Add(time.Hour).Format("20060102T150405Z")), "\n", "\r\n")
}

// TestCalDAVAddICS_ReadsFeedURLFromStdin covers the add-ics contract: the
// secret feed URL arrives via stdin (never argv), the feed is test-fetched,
// the account row is created with provider='ics' and an EMPTY url column,
// and the feed URL lands only in the credential file.
func TestCalDAVAddICS_ReadsFeedURLFromStdin(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(testICSBody()))
	}))
	defer srv.Close()

	caldavAddICSCmd.SetIn(strings.NewReader(srv.URL + "\n"))
	defer caldavAddICSCmd.SetIn(nil)
	out := new(strings.Builder)
	caldavAddICSCmd.SetOut(out)
	caldavAddICSCmd.SetErr(io.Discard)

	require.NoError(t, caldavAddICSCmd.RunE(caldavAddICSCmd, nil))
	assert.Contains(t, out.String(), "Connected ICS feed (account id ")
	assert.Contains(t, out.String(), "Restart the daemon")

	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	defer database.Close()

	accounts, err := database.ListCalendarAccounts()
	require.NoError(t, err)
	require.Len(t, accounts, 1)
	acct := accounts[0]
	assert.Equal(t, "ics", acct.Provider)
	assert.Empty(t, acct.URL, "the secret feed URL must never land in the DB url column")

	creds, err := caldav.NewCredentialStore(cfg.WorkspaceDir(), acct.ID).Load()
	require.NoError(t, err)
	assert.Equal(t, srv.URL, creds.FeedURL)
	assert.Empty(t, creds.Password)
}

func TestCalDAVAddICS_RejectsEmptyFeedURL(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	caldavAddICSCmd.SetIn(strings.NewReader("\n"))
	defer caldavAddICSCmd.SetIn(nil)
	caldavAddICSCmd.SetOut(io.Discard)

	err := caldavAddICSCmd.RunE(caldavAddICSCmd, nil)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "feed URL must not be empty")
}

// TestCalDAVRemove_DeletesAccountCalendarAndEvents covers the remove
// contract: the calendar_accounts row, its calendar_calendars row, its
// calendar_events, and the credential file must all be gone — no ghost
// events from removed accounts.
func TestCalDAVRemove_DeletesAccountCalendarAndEvents(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	defer database.Close()

	id, err := database.CreateCalendarAccount(db.CalendarAccount{Provider: "ics"})
	require.NoError(t, err)
	calID := db.CalendarAccountCalendarID("ics", id)
	require.NoError(t, database.UpsertCalendar(0, db.CalendarCalendar{ID: calID, Name: "Feed"}))
	require.NoError(t, database.UpsertCalendarEvent(db.CalendarEvent{
		ID: calID + ":evt-1", CalendarID: calID, Title: "Ghost-to-be",
		StartTime: "2026-07-27T09:00:00Z", EndTime: "2026-07-27T10:00:00Z",
	}))
	store := caldav.NewCredentialStore(cfg.WorkspaceDir(), id)
	require.NoError(t, store.Save(&caldav.Credentials{FeedURL: "https://example.com/secret.ics"}))

	buf := new(strings.Builder)
	caldavRemoveCmd.SetOut(buf)
	caldavRemoveCmd.SetErr(io.Discard)
	require.NoError(t, caldavRemoveCmd.RunE(caldavRemoveCmd, []string{strconv.FormatInt(id, 10)}))

	_, err = database.GetCalendarAccount(id)
	assert.Error(t, err, "account row must actually be deleted")
	events, err := database.GetCalendarEvents(db.CalendarEventFilter{CalendarID: calID})
	require.NoError(t, err)
	assert.Empty(t, events, "the account's events must be deleted with it")
	cals, err := database.GetCalendars()
	require.NoError(t, err)
	for _, c := range cals {
		assert.NotEqual(t, calID, c.ID, "the account's calendar_calendars row must be deleted with it")
	}
	assert.False(t, store.Exists(), "credential file must be removed")
}

// TestCreateCalendarAccountWithCredentials_RollsBackOnSaveFailure mirrors
// the imap analog: a credential-save failure after the row was created must
// roll the row back rather than leave an orphaned ghost account.
func TestCreateCalendarAccountWithCredentials_RollsBackOnSaveFailure(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()

	cfg, err := config.Load(flagConfig)
	require.NoError(t, err)
	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	defer database.Close()

	blockerFile := filepath.Join(t.TempDir(), "blocker")
	require.NoError(t, os.WriteFile(blockerFile, []byte("x"), 0o600))
	badWorkspaceDir := filepath.Join(blockerFile, "sub")

	before, err := database.ListCalendarAccounts()
	require.NoError(t, err)

	_, err = createCalendarAccountWithCredentials(database, badWorkspaceDir, db.CalendarAccount{
		Provider: "caldav", Username: "me@example.com", URL: "https://caldav.example.com",
	}, &caldav.Credentials{Password: "secret"}, io.Discard)
	require.Error(t, err)

	after, err := database.ListCalendarAccounts()
	require.NoError(t, err)
	assert.Equal(t, len(before), len(after), "the orphaned account row must be rolled back on credential-save failure")
}
