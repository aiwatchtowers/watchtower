package cmd

import (
	"bytes"
	"context"
	"errors"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/hub"
	"watchtower/internal/hub/hostkind"
	"watchtower/internal/hub/state"
	"watchtower/internal/policy/policytest"
)

// TestSyncDaemon_GoHubStartsOnlyInATestWorkspace: the daemon starts the Go
// hub only behind WATCHTOWER_HUB_DIR in a hubtest-* workspace, logs a
// refusal by its class and stops the hub when it stops.
func TestSyncDaemon_GoHubStartsOnlyInATestWorkspace(t *testing.T) {
	policytest.Set(t, nil)
	base, err := os.MkdirTemp("/tmp", "hubd") // a short path: the hub's unix socket lives there
	require.NoError(t, err)
	t.Cleanup(func() { _ = os.RemoveAll(base) })
	dir := filepath.Join(base, "h")
	t.Setenv(hub.EnvHubDir, dir)
	t.Setenv(hub.EnvRelayOrigin, "http://127.0.0.1:1")

	var buf bytes.Buffer
	logger := log.New(&buf, "", 0)

	t.Setenv(hub.EnvTestWorkspace, "acme")
	startGoHub(context.Background(), &config.Config{ActiveWorkspace: "acme"}, nil, logger)()
	assert.Contains(t, buf.String(), "hub: off (not_test_workspace)")
	_, err = os.Stat(dir)
	assert.True(t, errors.Is(err, fs.ErrNotExist), "a refused hub creates nothing")

	// No hub dir: the live mode, off on a headless host until enabled.
	buf.Reset()
	t.Setenv(hub.EnvHubDir, "")
	t.Setenv("HOME", base)
	setGoHubProbe(t, hostkind.Probe{GOOS: "linux", Stat: os.Stat, ReadFile: os.ReadFile})
	startGoHub(context.Background(), &config.Config{ActiveWorkspace: "hubtest-a"}, nil, logger)()
	assert.Contains(t, buf.String(), "hub: off (disabled)")
	live, err := hub.DefaultDir()
	require.NoError(t, err)
	_, err = os.Stat(live)
	assert.True(t, errors.Is(err, fs.ErrNotExist), "an off live hub creates nothing")

	buf.Reset()
	t.Setenv(hub.EnvHubDir, dir)
	t.Setenv(hub.EnvTestWorkspace, "hubtest-a")
	stop := startGoHub(context.Background(), &config.Config{ActiveWorkspace: "hubtest-a"}, nil, logger)
	assert.Contains(t, buf.String(), "hub: started (test workspace)")
	deadline := time.Now().Add(10 * time.Second)
	for {
		s, err := hub.ReadStatus(dir)
		require.NoError(t, err)
		if s.State == hub.StateOff && s.Reason == hub.ReasonDisabled {
			break
		}
		require.True(t, time.Now().Before(deadline), "the hub never reported off/disabled: %+v", s)
		time.Sleep(20 * time.Millisecond)
	}
	stop()
	s, err := hub.ReadStatus(dir)
	require.NoError(t, err)
	assert.Equal(t, hub.StateOff, s.State)
	assert.Empty(t, s.Reason, "a stopped hub reads off with no reason")
}

func setGoHubProbe(t *testing.T, p hostkind.Probe) {
	t.Helper()
	orig := goHubProbe
	goHubProbe = func() hostkind.Probe { return p }
	t.Cleanup(func() { goHubProbe = orig })
}

// TestSyncDaemon_GoHubLiveOnAHeadlessHostOnly: with no hub dir the daemon
// starts the live hub on a headless host once it is enabled and has a relay
// origin, and never on a desktop host.
func TestSyncDaemon_GoHubLiveOnAHeadlessHostOnly(t *testing.T) {
	policytest.Set(t, nil)
	base, err := os.MkdirTemp("/tmp", "hubd")
	require.NoError(t, err)
	t.Cleanup(func() { _ = os.RemoveAll(base) })
	t.Setenv("HOME", base)
	t.Setenv(hub.EnvHubDir, "")
	t.Setenv(hub.EnvRelayOrigin, "http://127.0.0.1:1")
	live, err := hub.DefaultDir()
	require.NoError(t, err)
	st, err := state.Open(live)
	require.NoError(t, err)
	require.NoError(t, st.SetMeta(state.MetaEnabled, "1"))
	require.NoError(t, st.Close())
	var buf bytes.Buffer
	logger := log.New(&buf, "", 0)

	setGoHubProbe(t, hostkind.Probe{GOOS: "darwin", Home: base, Stat: os.Stat, ReadFile: func(p string) ([]byte, error) {
		if p == "/Applications/Watchtower.app/Contents/Info.plist" {
			return []byte("<key>CFBundleIdentifier</key><string>" + hostkind.BundleID + "</string>"), nil
		}
		return nil, fs.ErrNotExist
	}})
	startGoHub(context.Background(), &config.Config{}, nil, logger)()
	assert.Contains(t, buf.String(), "hub: off (desktop_host)")

	buf.Reset()
	setGoHubProbe(t, hostkind.Probe{GOOS: "linux", Stat: os.Stat, ReadFile: os.ReadFile})
	stop := startGoHub(context.Background(), &config.Config{}, nil, logger)
	assert.Contains(t, buf.String(), "hub: started (live, headless)")
	deadline := time.Now().Add(10 * time.Second)
	for {
		s, err := hub.ReadStatus(live)
		require.NoError(t, err)
		if s.State == hub.StateStarting && s.Mode == string(hub.ModeLive) && s.Host == string(hostkind.Headless) {
			break
		}
		require.True(t, time.Now().Before(deadline), "the live hub never reported starting: %+v", s)
		time.Sleep(20 * time.Millisecond)
	}
	stop()
}
