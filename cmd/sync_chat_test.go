package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/chatengine"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/hub"
	"watchtower/internal/policy/policytest"
	"watchtower/internal/tower"
)

// TestSyncDaemon_StartsChatEngineBeforeHub: the daemon starts the chat
// engine, then the hub with that engine; it stops the hub first and the
// engine after it. With the hub off (hub.Resolve refuses), chat.sock is
// still served.
func TestSyncDaemon_StartsChatEngineBeforeHub(t *testing.T) {
	t.Run("order", func(t *testing.T) {
		var steps []string
		eng := &chatengine.Engine{}
		origChat, origHub := startChatEngineFn, startGoHubFn
		t.Cleanup(func() { startChatEngineFn, startGoHubFn = origChat, origHub })
		startChatEngineFn = func(context.Context, *config.Config, *log.Logger) (*chatengine.Engine, func()) {
			steps = append(steps, "chat start")
			return eng, func() { steps = append(steps, "chat stop") }
		}
		startGoHubFn = func(_ context.Context, _ *config.Config, _ *db.DB, _ *tower.Tower, got *chatengine.Engine, _ *log.Logger) func() {
			assert.Same(t, eng, got, "the hub gets the daemon's engine")
			steps = append(steps, "hub start")
			return func() { steps = append(steps, "hub stop") }
		}
		err := withChatAndHub(context.Background(), &config.Config{}, nil, nil, log.New(&bytes.Buffer{}, "", 0),
			func() error { steps = append(steps, "run"); return nil })
		require.NoError(t, err)
		assert.Equal(t, []string{"chat start", "hub start", "run", "hub stop", "chat stop"}, steps)
	})

	t.Run("hub off, chat served", func(t *testing.T) {
		policytest.Set(t, nil)
		base, err := os.MkdirTemp("/tmp", "chd") // a short path: chat.sock lives in the workspace
		require.NoError(t, err)
		t.Cleanup(func() { _ = os.RemoveAll(base) })
		t.Setenv("HOME", base)
		t.Setenv(hub.EnvHubDir, filepath.Join(base, "h"))
		t.Setenv(hub.EnvTestWorkspace, "acme")
		cfg := &config.Config{ActiveWorkspace: "acme"}
		database, err := db.Open(cfg.DBPath())
		require.NoError(t, err)
		t.Cleanup(func() { _ = database.Close() })
		var buf bytes.Buffer
		logger := log.New(&buf, "", 0)
		sock := chatengine.SocketPath(cfg.WorkspaceDir(), os.TempDir())

		err = withChatAndHub(context.Background(), cfg, database, nil, logger, func() error {
			conn, r, err := chatengine.Dial(context.Background(), sock) // waits for the greeting
			if err != nil {
				return err
			}
			defer func() { _ = conn.Close() }()
			if _, err := conn.Write([]byte(`{"id":"h","op":"hello","params":{"protocol":1,"client":"mac"}}` + "\n")); err != nil {
				return err
			}
			line, err := r.ReadBytes('\n')
			if err != nil {
				return err
			}
			// This test binary is not the signed app: a development CLI
			// peer on macOS (hello ok), forbidden where codesign is absent.
			var a struct {
				ID string `json:"id"`
			}
			if err := json.Unmarshal(line, &a); err != nil || a.ID != "h" {
				return errors.New("no answer to hello: " + string(line))
			}
			return nil
		})
		require.NoError(t, err)
		assert.Contains(t, buf.String(), "hub: off (not_test_workspace)")
		assert.Contains(t, buf.String(), "chat: serving chat.sock")
		_, err = os.Stat(sock)
		assert.True(t, errors.Is(err, fs.ErrNotExist), "chat.sock outlived the daemon: %v", err)
	})
}
