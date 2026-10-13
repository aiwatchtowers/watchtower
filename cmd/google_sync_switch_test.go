package cmd

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// writeSyncSwitchConfig writes a config.yaml with the given body and returns
// its path plus the config loaded from it.
func writeSyncSwitchConfig(t *testing.T, body string) (string, *config.Config) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config.yaml")
	require.NoError(t, os.WriteFile(path, []byte(body), 0o600))
	cfg, err := config.Load(path)
	require.NoError(t, err)
	return path, cfg
}

// Regression for #740: a fresh install's config carries `calendar.enabled:
// false` (the default, or written explicitly by the Desktop's first Save), and
// connecting Google through the Add sheet (onboarding's Connect step, Settings)
// never flipped it — the account row said "calendar connected" while the daemon
// wired no calendar syncer at all, so the Calendar tab stayed empty forever.
func TestEnableGoogleSyncSwitches_CalendarGrantTurnsCalendarSyncOn(t *testing.T) {
	path, cfg := writeSyncSwitchConfig(t, "calendar:\n  enabled: false\ngmail:\n  enabled: false\n")

	require.NoError(t, enableGoogleSyncSwitches(path, cfg, true, false))

	reloaded, err := config.Load(path)
	require.NoError(t, err)
	assert.True(t, reloaded.Calendar.Enabled, "a granted calendar must turn the daemon's calendar phase on")
	assert.False(t, reloaded.Gmail.Enabled, "Gmail was not granted and must stay off")
}

func TestEnableGoogleSyncSwitches_MissingKeysUseDefaultsThenTurnOn(t *testing.T) {
	path, cfg := writeSyncSwitchConfig(t, "sync:\n  initial_history_days: 3\n")
	require.False(t, cfg.Calendar.Enabled, "precondition: the default is off")

	require.NoError(t, enableGoogleSyncSwitches(path, cfg, true, true))

	reloaded, err := config.Load(path)
	require.NoError(t, err)
	assert.True(t, reloaded.Calendar.Enabled)
	assert.True(t, reloaded.Gmail.Enabled)
	assert.Equal(t, 3, reloaded.Sync.InitialHistoryDays, "other keys survive the write")
}

func TestEnableGoogleSyncSwitches_NothingGrantedWritesNothing(t *testing.T) {
	body := "calendar:\n  enabled: false\n"
	path, cfg := writeSyncSwitchConfig(t, body)

	require.NoError(t, enableGoogleSyncSwitches(path, cfg, false, false))

	got, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.Equal(t, body, string(got), "a connect that granted nothing must leave the config untouched")
}

func TestEnableGoogleSyncSwitches_AlreadyOnWritesNothing(t *testing.T) {
	body := "calendar:\n  enabled: true\ngmail:\n  enabled: true\n"
	path, cfg := writeSyncSwitchConfig(t, body)

	require.NoError(t, enableGoogleSyncSwitches(path, cfg, true, true))

	got, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.Equal(t, body, string(got), "switches already on need no rewrite")
}

func TestEnableGoogleSyncSwitches_UnparseableConfigFails(t *testing.T) {
	path, cfg := writeSyncSwitchConfig(t, "calendar:\n  enabled: false\n")
	require.NoError(t, os.WriteFile(path, []byte("calendar: [unclosed\n"), 0o600))

	err := enableGoogleSyncSwitches(path, cfg, true, false)
	assert.Error(t, err, "a failed write must surface, never leave the calendar silently unsynced")
}

// The fix point every connect surface shares: a consent that granted Calendar
// to an account that did not have it turns calendar sync on — and only what
// was GRANTED, never what was merely asked for (a partial grant leaves Gmail
// unapproved, so gmail.enabled must stay off).
func TestRecordGoogleConnection_NewGrantTurnsItsSwitchOn(t *testing.T) {
	path, cfg := writeSyncSwitchConfig(t, "calendar:\n  enabled: false\ngmail:\n  enabled: false\n")
	database := db.OpenTestDB(t)
	id, err := database.CreateGoogleAccount(db.GoogleAccount{})
	require.NoError(t, err)

	err = recordGoogleConnection(&bytes.Buffer{}, &bytes.Buffer{}, path, cfg, database, id,
		googleConnectResult{wantCalendar: true, wantGmail: true, calEnabled: true, gmEnabled: false})
	require.NoError(t, err)

	reloaded, err := config.Load(path)
	require.NoError(t, err)
	assert.True(t, reloaded.Calendar.Enabled, "a newly granted calendar must sync")
	assert.False(t, reloaded.Gmail.Enabled, "Gmail was asked for but not granted")
	acct, err := database.GetGoogleAccount(id)
	require.NoError(t, err)
	assert.True(t, acct.CalendarEnabled)
	assert.False(t, acct.GmailEnabled)
}

// A reconnect re-requests every service the account already had; it must not
// turn back on a sync the owner switched off in Settings.
func TestRecordGoogleConnection_ReconsentKeepsAnOwnerOff(t *testing.T) {
	body := "calendar:\n  enabled: false\ngmail:\n  enabled: false\n"
	path, cfg := writeSyncSwitchConfig(t, body)
	database := db.OpenTestDB(t)
	id, err := database.CreateGoogleAccount(db.GoogleAccount{CalendarEnabled: true, GmailEnabled: true})
	require.NoError(t, err)

	err = recordGoogleConnection(&bytes.Buffer{}, &bytes.Buffer{}, path, cfg, database, id,
		googleConnectResult{wantCalendar: true, wantGmail: true, calEnabled: true, gmEnabled: true})
	require.NoError(t, err)

	got, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.Equal(t, body, string(got), "services the account already had keep their switches")
}

// Widening an existing account (Gmail-only, now also Calendar) turns on only
// the gained service.
func TestRecordGoogleConnection_WideningTurnsOnOnlyTheGainedService(t *testing.T) {
	path, cfg := writeSyncSwitchConfig(t, "calendar:\n  enabled: false\ngmail:\n  enabled: false\n")
	database := db.OpenTestDB(t)
	id, err := database.CreateGoogleAccount(db.GoogleAccount{GmailEnabled: true})
	require.NoError(t, err)

	err = recordGoogleConnection(&bytes.Buffer{}, &bytes.Buffer{}, path, cfg, database, id,
		googleConnectResult{wantCalendar: true, wantGmail: true, calEnabled: true, gmEnabled: true})
	require.NoError(t, err)

	reloaded, err := config.Load(path)
	require.NoError(t, err)
	assert.True(t, reloaded.Calendar.Enabled)
	assert.False(t, reloaded.Gmail.Enabled, "Gmail was already granted; its off switch is the owner's")
}

// The account is connected once its row is written: a failed switch write
// warns and still exits 0, so the Desktop refreshes and restarts the daemon
// instead of reporting a failed connect (and inviting a duplicate add).
func TestRecordGoogleConnection_SwitchWriteFailureWarnsButSucceeds(t *testing.T) {
	path, cfg := writeSyncSwitchConfig(t, "calendar:\n  enabled: false\n")
	require.NoError(t, os.WriteFile(path, []byte("calendar: [unclosed\n"), 0o600))
	database := db.OpenTestDB(t)
	id, err := database.CreateGoogleAccount(db.GoogleAccount{})
	require.NoError(t, err)

	var errOut bytes.Buffer
	err = recordGoogleConnection(&bytes.Buffer{}, &errOut, path, cfg, database, id,
		googleConnectResult{wantCalendar: true, calEnabled: true})
	require.NoError(t, err)
	assert.Contains(t, errOut.String(), "turning its sync on failed")
	acct, err := database.GetGoogleAccount(id)
	require.NoError(t, err)
	assert.True(t, acct.CalendarEnabled, "the connection is recorded regardless")
}
