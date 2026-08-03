package cmd

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"watchtower/internal/calendar"
	"watchtower/internal/db"

	"github.com/spf13/cobra"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// setupTempWorkspace points the test at a temp HOME + minimal config so that
// commands relying on Config.WorkspaceDir / Config.DBPath / token store hit
// disposable directories. Returns the workspace dir and a teardown the caller
// can ignore (t.Cleanup handles file teardown).
func setupTempWorkspace(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)

	cfgDir := filepath.Join(home, ".config", "watchtower")
	require.NoError(t, os.MkdirAll(cfgDir, 0o700))
	cfgPath := filepath.Join(cfgDir, "config.yaml")
	require.NoError(t, os.WriteFile(cfgPath, []byte("active_workspace: test\n"), 0o600))

	wsDir := filepath.Join(home, ".local", "share", "watchtower", "test")
	require.NoError(t, os.MkdirAll(wsDir, 0o700))

	prevConfig, prevWS := flagConfig, flagWorkspace
	flagConfig = cfgPath
	flagWorkspace = ""
	t.Cleanup(func() {
		flagConfig = prevConfig
		flagWorkspace = prevWS
	})

	// Pre-create DB so commands that open it succeed.
	dbPath := filepath.Join(wsDir, "watchtower.db")
	database, err := db.Open(dbPath)
	require.NoError(t, err)
	require.NoError(t, database.Close())

	return wsDir
}

func TestRunCalendarStatus_NotConnected(t *testing.T) {
	setupTempWorkspace(t)

	c := &cobra.Command{}
	var buf bytes.Buffer
	c.SetOut(&buf)
	c.SetErr(&buf)

	require.NoError(t, runCalendarStatus(c, nil))
	out := buf.String()
	assert.Contains(t, out, "not connected")
	assert.Contains(t, out, "calendar login")
}

func TestRunCalendarStatus_Connected(t *testing.T) {
	wsDir := setupTempWorkspace(t)

	dbPath := filepath.Join(wsDir, "watchtower.db")
	database, err := db.Open(dbPath)
	require.NoError(t, err)
	id, err := database.CreateGoogleAccount(db.GoogleAccount{CalendarEnabled: true})
	require.NoError(t, err)
	require.NoError(t, database.Close())

	// Create the per-account token file so the status check sees it as connected.
	tokenPath := calendar.NewAccountTokenStore(wsDir, id).Path()
	require.NoError(t, os.WriteFile(tokenPath, []byte(`{"access_token":"x"}`), 0o600))

	c := &cobra.Command{}
	var buf bytes.Buffer
	c.SetOut(&buf)

	require.NoError(t, runCalendarStatus(c, nil))
	out := buf.String()
	assert.Contains(t, out, "connected")
	assert.Contains(t, out, tokenPath)
}

func TestRunCalendarList_Empty(t *testing.T) {
	setupTempWorkspace(t)

	c := &cobra.Command{}
	var buf bytes.Buffer
	c.SetOut(&buf)

	require.NoError(t, runCalendarList(c, nil))
	assert.Contains(t, buf.String(), "No calendars synced")
}

func TestRunCalendarList_WithCalendars(t *testing.T) {
	wsDir := setupTempWorkspace(t)

	dbPath := filepath.Join(wsDir, "watchtower.db")
	database, err := db.Open(dbPath)
	require.NoError(t, err)
	defer database.Close()

	require.NoError(t, database.UpsertCalendar(0, db.CalendarCalendar{
		ID: "primary", Name: "Main", IsPrimary: true, IsSelected: true, SyncedAt: "2026-04-01T00:00:00Z",
	}))
	require.NoError(t, database.UpsertCalendar(0, db.CalendarCalendar{
		ID: "work@x.com", Name: "Work", IsSelected: false, SyncedAt: "2026-04-01T00:00:00Z",
	}))

	c := &cobra.Command{}
	var buf bytes.Buffer
	c.SetOut(&buf)

	require.NoError(t, runCalendarList(c, nil))
	out := buf.String()
	assert.Contains(t, out, "Main")
	assert.Contains(t, out, "(primary)")
	assert.Contains(t, out, "Work")
	// Selection markers
	assert.Contains(t, out, "[*]")
	assert.Contains(t, out, "[ ]")
}

func TestRunBriefingList_NoUser(t *testing.T) {
	setupTempWorkspace(t)

	c := &cobra.Command{}
	var buf bytes.Buffer
	c.SetOut(&buf)

	require.NoError(t, runBriefingList(c, nil))
	assert.Contains(t, buf.String(), "No current user set")
}

func TestRunBriefingList_NoBriefings(t *testing.T) {
	wsDir := setupTempWorkspace(t)

	dbPath := filepath.Join(wsDir, "watchtower.db")
	database, err := db.Open(dbPath)
	require.NoError(t, err)
	defer database.Close()

	_, err = database.Exec(`INSERT INTO workspace (id, name) VALUES ('T1', 'test')`)
	require.NoError(t, err)
	_, acctErr := database.CreateSlackAccount(db.SlackAccount{CurrentUserID: "U123"})
	require.NoError(t, acctErr)
	c := &cobra.Command{}
	var buf bytes.Buffer
	c.SetOut(&buf)

	require.NoError(t, runBriefingList(c, nil))
	assert.Contains(t, buf.String(), "No briefings found")
}

func TestRunBriefingList_WithBriefings(t *testing.T) {
	wsDir := setupTempWorkspace(t)

	dbPath := filepath.Join(wsDir, "watchtower.db")
	database, err := db.Open(dbPath)
	require.NoError(t, err)
	defer database.Close()

	_, err = database.Exec(`INSERT INTO workspace (id, name) VALUES ('T1', 'test')`)
	require.NoError(t, err)
	_, acctErr := database.CreateSlackAccount(db.SlackAccount{CurrentUserID: "U123"})
	require.NoError(t, acctErr)
	id, err := database.UpsertBriefing(db.Briefing{
		UserID:       "U123",
		Date:         "2026-04-02",
		Role:         "EM",
		Attention:    `[{"text":"x"}]`,
		YourDay:      "[]",
		WhatHappened: "[]",
		TeamPulse:    "[]",
		Coaching:     "[]",
		Model:        "haiku",
	})
	require.NoError(t, err)
	require.NotZero(t, id)

	c := &cobra.Command{}
	var buf bytes.Buffer
	c.SetOut(&buf)
	prev := briefingListFlagLimit
	briefingListFlagLimit = 10
	defer func() { briefingListFlagLimit = prev }()

	require.NoError(t, runBriefingList(c, nil))
	out := buf.String()
	assert.Contains(t, out, "2026-04-02")
	assert.Contains(t, out, "unread")
	assert.True(t, strings.Contains(out, "1 attention item"), "expected attention count, got: %s", out)
}

func TestRunCalendarSelect_TogglesSelection(t *testing.T) {
	wsDir := setupTempWorkspace(t)

	dbPath := filepath.Join(wsDir, "watchtower.db")
	database, err := db.Open(dbPath)
	require.NoError(t, err)
	defer database.Close()

	require.NoError(t, database.UpsertCalendar(0, db.CalendarCalendar{
		ID: "primary", Name: "Main", IsSelected: true, SyncedAt: "2026-04-01T00:00:00Z",
	}))

	c := &cobra.Command{}
	var buf bytes.Buffer
	c.SetOut(&buf)

	// First call: was selected → becomes deselected.
	require.NoError(t, runCalendarSelect(c, []string{"primary"}))
	assert.Contains(t, buf.String(), "deselected")

	// Reload from disk and toggle again.
	database.Close()
	database2, err := db.Open(dbPath)
	require.NoError(t, err)
	defer database2.Close()

	buf.Reset()
	require.NoError(t, runCalendarSelect(c, []string{"primary"}))
	assert.Contains(t, buf.String(), "selected")
	assert.NotContains(t, buf.String(), "deselected")
}

func TestRunCalendarSelect_NotFound(t *testing.T) {
	setupTempWorkspace(t)

	c := &cobra.Command{}
	var buf bytes.Buffer
	c.SetOut(&buf)

	err := runCalendarSelect(c, []string{"nonexistent"})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "not found")
}

func TestRunJiraLogout_NoToken(t *testing.T) {
	setupTempWorkspace(t)

	c := &cobra.Command{}
	var buf bytes.Buffer
	c.SetOut(&buf)

	// Logout is idempotent — works even without a saved token. With no
	// accounts (multi-account model) it reports nothing to disconnect.
	require.NoError(t, runJiraLogout(c, nil))
	assert.Contains(t, buf.String(), "No Jira site connected")
}

// Logout is now non-destructive: the token file is removed and the account row
// marked removed, but synced data is kept.
func TestRunJiraLogout_RemovesTokenKeepsData(t *testing.T) {
	wsDir := setupTempWorkspace(t)

	tokenPath := filepath.Join(wsDir, "jira_token.json")
	require.NoError(t, os.WriteFile(tokenPath, []byte(`{"access_token":"x"}`), 0o600))

	c := &cobra.Command{}
	var buf bytes.Buffer
	c.SetOut(&buf)

	// Seed a synced issue: the headline of this change is that logout stops
	// wiping jira_* (ClearJiraData is deleted), so the test must actually
	// prove the data survives — otherwise reinstating the wipe passes.
	database, err := db.Open(filepath.Join(wsDir, "watchtower.db"))
	require.NoError(t, err)
	acctID := db.SeedTestJiraAccount(t, database)
	require.NoError(t, database.UpsertJiraIssue(db.JiraIssue{
		AccountID: acctID, Key: "OPS-1", ProjectKey: "OPS", Summary: "keep me",
		Status: "Open", StatusCategory: "todo",
		CreatedAt: "2026-01-01", UpdatedAt: "2026-01-01", SyncedAt: "2026-01-01",
	}))
	require.NoError(t, database.Close())

	require.NoError(t, runJiraLogout(c, nil))
	assert.Contains(t, buf.String(), "disconnected")

	_, err = os.Stat(tokenPath)
	assert.True(t, os.IsNotExist(err), "token file should be removed")

	reopened, err := db.Open(filepath.Join(wsDir, "watchtower.db"))
	require.NoError(t, err)
	defer reopened.Close()

	issue, err := reopened.GetJiraIssueByKey("OPS-1")
	require.NoError(t, err)
	require.NotNil(t, issue, "logout must keep synced issues (it is no longer a purge)")
	assert.Equal(t, "keep me", issue.Summary)

	acct, err := reopened.GetJiraAccount(acctID)
	require.NoError(t, err)
	assert.Equal(t, "removed", acct.Status)
	assert.False(t, acct.Enabled)
}

func TestRunDigestResetContext_AllChannels(t *testing.T) {
	setupTempWorkspace(t)

	c := &cobra.Command{}
	var buf bytes.Buffer
	c.SetOut(&buf)

	require.NoError(t, runDigestResetContext(c, nil))
	assert.Contains(t, buf.String(), "all channels")
}

func TestRunDigestResetContext_UnknownChannel(t *testing.T) {
	setupTempWorkspace(t)

	c := &cobra.Command{}
	var buf bytes.Buffer
	c.SetOut(&buf)

	err := runDigestResetContext(c, []string{"#nonexistent"})
	require.Error(t, err)
	assert.Contains(t, err.Error(), "not found")
}

func TestRunDigestResetContext_KnownChannel(t *testing.T) {
	wsDir := setupTempWorkspace(t)

	dbPath := filepath.Join(wsDir, "watchtower.db")
	database, err := db.Open(dbPath)
	require.NoError(t, err)
	defer database.Close()

	require.NoError(t, database.UpsertChannel(db.Channel{ID: "C1", Name: "general", Type: "public"}))
	database.Close()

	c := &cobra.Command{}
	var buf bytes.Buffer
	c.SetOut(&buf)

	require.NoError(t, runDigestResetContext(c, []string{"#general"}))
	assert.Contains(t, buf.String(), "general")
}

func TestRunDayPlanCheckConflicts_NoUser(t *testing.T) {
	setupTempWorkspace(t)

	c := &cobra.Command{}
	var buf bytes.Buffer
	c.SetOut(&buf)
	c.SetErr(&buf)

	require.NoError(t, runDayPlanCheckConflicts(c, nil))
	assert.Contains(t, buf.String(), "No current user")
}

func TestRunDayPlanCheckConflicts_NoPlan(t *testing.T) {
	wsDir := setupTempWorkspace(t)

	dbPath := filepath.Join(wsDir, "watchtower.db")
	database, err := db.Open(dbPath)
	require.NoError(t, err)
	defer database.Close()

	_, err = database.Exec(`INSERT INTO workspace (id, name) VALUES ('T1', 'test')`)
	require.NoError(t, err)
	_, acctErr := database.CreateSlackAccount(db.SlackAccount{CurrentUserID: "U123"})
	require.NoError(t, acctErr)
	c := &cobra.Command{}
	var buf bytes.Buffer
	c.SetOut(&buf)
	c.SetErr(&buf)

	require.NoError(t, runDayPlanCheckConflicts(c, nil))
	assert.Contains(t, buf.String(), "No day plan")
}

func TestRunBriefing_NoUser(t *testing.T) {
	setupTempWorkspace(t)

	c := &cobra.Command{}
	var buf bytes.Buffer
	c.SetOut(&buf)

	require.NoError(t, runBriefing(c, nil))
	assert.Contains(t, buf.String(), "No current user")
}

func TestRunBriefing_NoBriefingForToday(t *testing.T) {
	wsDir := setupTempWorkspace(t)

	dbPath := filepath.Join(wsDir, "watchtower.db")
	database, err := db.Open(dbPath)
	require.NoError(t, err)
	defer database.Close()

	_, err = database.Exec(`INSERT INTO workspace (id, name) VALUES ('T1', 'test')`)
	require.NoError(t, err)
	_, acctErr := database.CreateSlackAccount(db.SlackAccount{CurrentUserID: "U1"})
	require.NoError(t, acctErr)
	c := &cobra.Command{}
	var buf bytes.Buffer
	c.SetOut(&buf)

	require.NoError(t, runBriefing(c, nil))
	assert.Contains(t, buf.String(), "No briefing for today")
}

func TestRunJiraStatus_NotConnected(t *testing.T) {
	setupTempWorkspace(t)

	c := &cobra.Command{}
	var buf bytes.Buffer
	c.SetOut(&buf)

	require.NoError(t, runJiraStatus(c, nil))
	out := buf.String()
	assert.Contains(t, out, "not connected")
	assert.Contains(t, out, "jira add")
}

func TestRunJiraStatus_Connected(t *testing.T) {
	wsDir := setupTempWorkspace(t)

	tokenPath := filepath.Join(wsDir, "jira_token.json")
	require.NoError(t, os.WriteFile(tokenPath, []byte(`{"access_token":"x"}`), 0o600))

	c := &cobra.Command{}
	var buf bytes.Buffer
	c.SetOut(&buf)

	require.NoError(t, runJiraStatus(c, nil))
	out := buf.String()
	assert.Contains(t, out, "account(s) connected")
	assert.Contains(t, out, "[1]")
	assert.Contains(t, out, "Issues synced:")
	// The legacy token was migrated to the per-account store (account #1).
	assert.FileExists(t, filepath.Join(wsDir, "jira_token_1.json"))
	assert.NoFileExists(t, tokenPath)
}
