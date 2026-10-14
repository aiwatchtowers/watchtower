package cmd

import (
	"bytes"
	"go/ast"
	"go/parser"
	"go/token"
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

// Owner decision 2026-10-14: a reconnect is a request to sync too — a
// re-consent turns back on a switch the owner had turned off.
func TestRecordGoogleConnection_ReconsentTurnsTheSwitchesBackOn(t *testing.T) {
	path, cfg := writeSyncSwitchConfig(t, "calendar:\n  enabled: false\ngmail:\n  enabled: false\n")
	database := db.OpenTestDB(t)
	id, err := database.CreateGoogleAccount(db.GoogleAccount{CalendarEnabled: true, GmailEnabled: true})
	require.NoError(t, err)

	err = recordGoogleConnection(&bytes.Buffer{}, &bytes.Buffer{}, path, cfg, database, id,
		googleConnectResult{wantCalendar: true, wantGmail: true, calEnabled: true, gmEnabled: true})
	require.NoError(t, err)

	reloaded, err := config.Load(path)
	require.NoError(t, err)
	assert.True(t, reloaded.Calendar.Enabled, "a reconnected calendar syncs again")
	assert.True(t, reloaded.Gmail.Enabled, "a reconnected Gmail syncs again")
}

// A re-consent that drops a service (the owner unchecked it on Google's
// consent page) leaves that service's switch as it was: only what was
// granted is turned on.
func TestRecordGoogleConnection_ReconsentLeavesAnUngrantedSwitchAlone(t *testing.T) {
	path, cfg := writeSyncSwitchConfig(t, "calendar:\n  enabled: false\ngmail:\n  enabled: false\n")
	database := db.OpenTestDB(t)
	id, err := database.CreateGoogleAccount(db.GoogleAccount{CalendarEnabled: true, GmailEnabled: true})
	require.NoError(t, err)

	err = recordGoogleConnection(&bytes.Buffer{}, &bytes.Buffer{}, path, cfg, database, id,
		googleConnectResult{wantCalendar: true, wantGmail: true, calEnabled: false, gmEnabled: true})
	require.NoError(t, err)

	reloaded, err := config.Load(path)
	require.NoError(t, err)
	assert.False(t, reloaded.Calendar.Enabled, "Calendar was not granted this time")
	assert.True(t, reloaded.Gmail.Enabled)
}

// Widening an existing account (Gmail-only, now also Calendar) turns on
// every granted service, the one it already had included.
func TestRecordGoogleConnection_WideningTurnsOnEveryGrantedService(t *testing.T) {
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
	assert.True(t, reloaded.Gmail.Enabled)
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

// TestConnectGoogleAccount_RecordsTheGrantedFlags pins the one call that
// makes #740's fix reach every connect surface: connectGoogleAccount hands
// recordGoogleConnection the GRANTED flags (calEnabled/gmEnabled, from the
// token), not the requested ones. Pinned statically because the OAuth flow
// before it has no seam.
func TestConnectGoogleAccount_RecordsTheGrantedFlags(t *testing.T) {
	file, err := parser.ParseFile(token.NewFileSet(), "google.go", nil, 0)
	require.NoError(t, err)

	var connect *ast.FuncDecl
	for _, decl := range file.Decls {
		if fd, ok := decl.(*ast.FuncDecl); ok && fd.Name.Name == "connectGoogleAccount" {
			connect = fd
		}
	}
	require.NotNil(t, connect, "connectGoogleAccount not found in google.go")

	var fields map[string]string
	ast.Inspect(connect.Body, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		if ident, ok := call.Fun.(*ast.Ident); !ok || ident.Name != "recordGoogleConnection" {
			return true
		}
		for _, arg := range call.Args {
			lit, ok := arg.(*ast.CompositeLit)
			if !ok {
				continue
			}
			fields = map[string]string{}
			for _, elt := range lit.Elts {
				kv, ok := elt.(*ast.KeyValueExpr)
				if !ok {
					continue
				}
				key, _ := kv.Key.(*ast.Ident)
				val, _ := kv.Value.(*ast.Ident)
				if key != nil && val != nil {
					fields[key.Name] = val.Name
				}
			}
		}
		return false
	})
	require.NotNil(t, fields, "connectGoogleAccount must call recordGoogleConnection with a googleConnectResult literal")
	assert.Equal(t, "calEnabled", fields["calEnabled"], "the granted calendar flag, never wantCalendar")
	assert.Equal(t, "gmEnabled", fields["gmEnabled"], "the granted Gmail flag, never wantGmail")
}
