package cmd

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
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

func TestEnableGoogleSyncSwitches_UnwritableConfigFails(t *testing.T) {
	path, cfg := writeSyncSwitchConfig(t, "calendar:\n  enabled: false\n")
	require.NoError(t, os.WriteFile(path, []byte("calendar: [unclosed\n"), 0o600))

	err := enableGoogleSyncSwitches(path, cfg, true, false)
	assert.Error(t, err, "a failed write must surface, never leave the calendar silently unsynced")
}
