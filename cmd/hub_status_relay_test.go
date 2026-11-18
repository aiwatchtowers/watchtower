package cmd

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/hub"
)

// A running hub whose relay is not connected says since when and its last
// save in the text form (#1873); the JSON form already carries relay.
func TestHubStatusShowsAnUnavailableRelay(t *testing.T) {
	dir := hubTestDir(t)
	hubTestConfig(t, "hubtest-x")
	t.Setenv(hub.EnvTestWorkspace, "hubtest-x")
	now := time.Now()
	since := now.Add(-time.Hour).UTC().Truncate(time.Minute)
	saved := since.Add(-2 * time.Minute)
	raw := fmt.Sprintf(`{"state":%q,"transport":"relay","phones":1,"relay":{"state":"unavailable","since":%q,"last_saved_at":%q},"pid":%d,"run":"r"}`,
		hub.StateRunning, since.Format(time.RFC3339), saved.Format(time.RFC3339), os.Getpid())
	require.NoError(t, os.MkdirAll(dir, 0o700))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "status.json"), []byte(raw), 0o600))

	out, err := runHub(t, "status")
	require.NoError(t, err)
	assert.Contains(t, out, "hub: running, relay unavailable since "+hubClock(since, now)+
		" (last saved "+hubClock(saved, now)+"), 1 phone(s)")

	out, err = runHub(t, "status", "--json")
	require.NoError(t, err)
	relay, ok := decodeKeys(t, out)["relay"].(map[string]any)
	require.True(t, ok, "relay object in the JSON form")
	assert.Equal(t, "unavailable", relay["state"])
	assert.Equal(t, saved.Format(time.RFC3339), relay["last_saved_at"])
}

func TestHubRelayNote(t *testing.T) {
	now := time.Date(2026, 11, 16, 16, 0, 0, 0, time.UTC)
	cases := []struct {
		name string
		r    *hub.RelayHealth
		want string
	}{
		{"no relay", nil, ""},
		{"connected", &hub.RelayHealth{State: "connected", Since: "2026-11-16T14:22:00Z"}, ""},
		{"unavailable", &hub.RelayHealth{State: "unavailable", Since: "2026-11-16T14:22:00Z", LastSavedAt: "2026-11-16T14:20:00Z"},
			" unavailable since 14:22 (last saved 14:20)"},
		{"another day", &hub.RelayHealth{State: "unavailable", Since: "2026-11-15T23:50:00Z", LastSavedAt: "2026-11-15T23:40:00Z"},
			" unavailable since Nov 15 23:50 (last saved Nov 15 23:40)"},
		{"never saved", &hub.RelayHealth{State: "connecting", Since: "2026-11-16T15:59:30Z"},
			" connecting since 15:59 (never saved since the hub started)"},
		{"unreadable times", &hub.RelayHealth{State: "unavailable", Since: "soon", LastSavedAt: "later"}, " unavailable"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			assert.Equal(t, c.want, hubRelayNote(c.r, now))
		})
	}
}
