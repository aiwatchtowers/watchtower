package slackmode

import (
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/auth"
	"watchtower/internal/db"
)

// Placeholder client ids, not real Slack apps.
const (
	sharedID   = "1000.0001" // the retired public shared app
	corpID     = "2000.0002" // a company app a build bakes
	setupID    = "3000.0003" // a workspace app made by setup
	mdmID      = "4000.0004" // an id from MDM SlackApps or a link
	testSecret = "test-secret"
)

// withBuild sets the build's baked app and retired id for one test, with the
// env overrides cleared.
func withBuild(t *testing.T, bakedID, bakedSecret, retiredID string) {
	t.Helper()
	t.Setenv("WATCHTOWER_OAUTH_CLIENT_ID", "")
	t.Setenv("WATCHTOWER_OAUTH_CLIENT_SECRET", "")
	oldID, oldSecret, oldRetired := auth.DefaultClientID, auth.DefaultClientSecret, auth.RetiredSharedClientID
	auth.DefaultClientID, auth.DefaultClientSecret, auth.RetiredSharedClientID = bakedID, bakedSecret, retiredID
	t.Cleanup(func() {
		auth.DefaultClientID, auth.DefaultClientSecret, auth.RetiredSharedClientID = oldID, oldSecret, oldRetired
	})
}

func TestSlackAccountSharedApp_RetiredIDOnly(t *testing.T) {
	cases := []struct {
		name      string
		clientID  string
		retiredID string
		want      bool
	}{
		{"retired shared id", sharedID, sharedID, true},
		{"setup app", setupID, sharedID, false},
		{"MDM or link id", mdmID, sharedID, false},
		{"corp-baked company app", corpID, sharedID, false},
		{"no client id", "", sharedID, false},
		{"no retired id: shared id is not shared", sharedID, "", false},
		{"no retired id: empty client id is not shared", "", "", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := SharedApp(db.SlackAccount{ClientID: tc.clientID, Status: "ok"}, tc.retiredID)
			assert.Equal(t, tc.want, got)
		})
	}
}

func TestSlackAccountRelogin_FirstMatchWins(t *testing.T) {
	cases := []struct {
		name      string
		clientID  string
		builtinID string
		want      string
	}{
		{"shared id while baked", sharedID, sharedID, ReloginBuiltin},
		{"shared id after nothing is baked", sharedID, "", ReloginMove},
		{"shared id while another app is baked", sharedID, corpID, ReloginMove},
		{"empty client id", "", corpID, ReloginBuiltin},
		{"corp-baked id while baked", corpID, corpID, ReloginBuiltin},
		{"corp-baked id after nothing is baked", corpID, "", ReloginConnect},
		{"company app", setupID, corpID, ReloginConnect},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			assert.Equal(t, tc.want, Relogin(db.SlackAccount{ClientID: tc.clientID}, sharedID, tc.builtinID))
		})
	}
}

func openBackfillDB(t *testing.T) (*db.DB, int64) {
	t.Helper()
	d, err := db.Open(filepath.Join(t.TempDir(), "watchtower.db"))
	require.NoError(t, err)
	t.Cleanup(func() { d.Close() })
	id, err := d.CreateSlackAccount(db.SlackAccount{TeamID: "T0ACME", TeamName: "acme"})
	require.NoError(t, err)
	return d, id
}

func backfilledClientID(t *testing.T, d *db.DB, id int64) string {
	t.Helper()
	_, err := BackfillClientIDs(d)
	require.NoError(t, err)
	a, err := d.GetSlackAccount(id)
	require.NoError(t, err)
	return a.ClientID
}

func TestBackfillSlackClientIDs_FromBakedID(t *testing.T) {
	t.Run("public before retirement: empty rows get the shared id and are shared", func(t *testing.T) {
		withBuild(t, sharedID, testSecret, sharedID)
		d, id := openBackfillDB(t)
		got := backfilledClientID(t, d, id)
		assert.Equal(t, sharedID, got)
		assert.True(t, SharedApp(db.SlackAccount{ClientID: got}, auth.RetiredSharedClientID))
	})
	t.Run("corp: empty rows get the corp id and are not shared", func(t *testing.T) {
		withBuild(t, corpID, testSecret, "")
		d, id := openBackfillDB(t)
		got := backfilledClientID(t, d, id)
		assert.Equal(t, corpID, got)
		assert.False(t, SharedApp(db.SlackAccount{ClientID: got}, auth.RetiredSharedClientID))
	})
	t.Run("env id wins over the baked id", func(t *testing.T) {
		withBuild(t, corpID, testSecret, "")
		t.Setenv("WATCHTOWER_OAUTH_CLIENT_ID", mdmID)
		assert.Equal(t, mdmID, BackfillSource())
	})
	t.Run("a set client id is never overwritten", func(t *testing.T) {
		withBuild(t, corpID, testSecret, sharedID)
		d, id := openBackfillDB(t)
		require.NoError(t, d.SetSlackAccountClientID(id, setupID))
		assert.Equal(t, setupID, backfilledClientID(t, d, id))
	})
}

func TestBackfillSlackClientIDs_AfterRetirement(t *testing.T) {
	t.Run("nothing baked: empty rows get the retired id", func(t *testing.T) {
		withBuild(t, "", "", sharedID)
		d, id := openBackfillDB(t)
		got := backfilledClientID(t, d, id)
		assert.Equal(t, sharedID, got)
		assert.True(t, SharedApp(db.SlackAccount{ClientID: got}, auth.RetiredSharedClientID))
	})
	t.Run("nothing baked and no retired id: rows stay empty", func(t *testing.T) {
		withBuild(t, "", "", "")
		assert.Empty(t, BackfillSource())
		d, id := openBackfillDB(t)
		assert.Empty(t, backfilledClientID(t, d, id))
	})
}
