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

	buf.Reset()
	t.Setenv(hub.EnvHubDir, "")
	startGoHub(context.Background(), &config.Config{ActiveWorkspace: "hubtest-a"}, nil, logger)()
	assert.Empty(t, buf.String(), "no hub dir: nothing to say")

	buf.Reset()
	t.Setenv(hub.EnvHubDir, dir)
	t.Setenv(hub.EnvTestWorkspace, "hubtest-a")
	stop := startGoHub(context.Background(), &config.Config{ActiveWorkspace: "hubtest-a"}, nil, logger)
	assert.Contains(t, buf.String(), "hub: started (dir set)")
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
