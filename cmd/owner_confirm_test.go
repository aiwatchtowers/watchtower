package cmd

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/ownerconfirm"
)

// withOwnerDesktop stands in for the Desktop round trip: it answers rep and
// err and returns the requests it was sent.
func withOwnerDesktop(t *testing.T, rep ownerconfirm.Reply, err error) *[]ownerconfirm.Request {
	t.Helper()
	orig := askOwnerDesktop
	t.Cleanup(func() { askOwnerDesktop = orig })
	var got []ownerconfirm.Request
	askOwnerDesktop = func(_ context.Context, _ string, req ownerconfirm.Request) (ownerconfirm.Reply, error) {
		got = append(got, req)
		return rep, err
	}
	return &got
}

// AGENT-07 (board #568, owner decision ask #357, variant A): under an agent
// marker the gesture is refused outright, as before; without one it runs only
// when the owner confirms it in the running Desktop, whose signature the CLI
// checked. Unsetting the markers (`env -u CLAUDECODE …`) therefore no longer
// lets a command through on its own.
func TestAgent07_OwnerGestureNeedsTheDesktopsConfirmation(t *testing.T) {
	setup := func(t *testing.T) (*db.DB, string) {
		database := writeActionsConfig(t)
		id, err := database.InsertAgentAction(db.AgentAction{Tool: "create_target",
			ArgsJSON: `{"text":"` + strings.Repeat("x", 3000) + `","reason":"r"}`, Reason: "r", Surface: "main"})
		require.NoError(t, err)
		return database, strconv.FormatInt(id, 10)
	}
	status := func(t *testing.T, database *db.DB, id string) string {
		n, err := strconv.ParseInt(id, 10, 64)
		require.NoError(t, err)
		row, err := database.GetAgentAction(n)
		require.NoError(t, err)
		return row.Status
	}
	confirmed := ownerconfirm.Reply{Decision: ownerconfirm.Confirmed}

	t.Run("no marker, no Desktop: refused", func(t *testing.T) {
		database, id := setup(t)
		withOwnerDesktop(t, ownerconfirm.Reply{}, fmt.Errorf("%w: test", ownerconfirm.ErrNoDesktop))
		_, err := runActions(t, "approve", id, "--json")
		require.Error(t, err)
		assert.Contains(t, err.Error(), "open Watchtower to confirm this")
		assert.Equal(t, "pending", status(t, database, id))
	})
	t.Run("no marker, the peer fails the signature check: refused", func(t *testing.T) {
		database, id := setup(t)
		withOwnerDesktop(t, ownerconfirm.Reply{}, fmt.Errorf("%w: test", ownerconfirm.ErrUntrustedPeer))
		_, err := runActions(t, "approve", id, "--json")
		require.Error(t, err)
		assert.Contains(t, err.Error(), "not the signed Watchtower app")
		assert.Equal(t, "pending", status(t, database, id))
	})
	t.Run("no marker, the owner denies: refused", func(t *testing.T) {
		database, id := setup(t)
		withOwnerDesktop(t, ownerconfirm.Reply{Decision: ownerconfirm.Denied}, nil)
		_, err := runActions(t, "approve", id, "--json")
		require.Error(t, err)
		assert.Contains(t, err.Error(), "did not confirm")
		assert.Equal(t, "pending", status(t, database, id))
	})
	t.Run("no marker, the owner confirms: approved, the window saw the whole args", func(t *testing.T) {
		database, id := setup(t)
		got := withOwnerDesktop(t, confirmed, nil)
		_, err := runActions(t, "approve", id, "--json")
		require.NoError(t, err)
		assert.NotEqual(t, "pending", status(t, database, id))
		require.Len(t, *got, 1)
		assert.Equal(t, "approve an action", (*got)[0].Verb)
		assert.Contains(t, (*got)[0].Detail, strings.Repeat("x", 3000), "nothing clipped")
	})
	t.Run("a marker: refused without asking the Desktop", func(t *testing.T) {
		database, id := setup(t)
		got := withOwnerDesktop(t, confirmed, nil)
		t.Setenv("CLAUDECODE", "1")
		_, err := runActions(t, "approve", id, "--json")
		require.Error(t, err)
		assert.Contains(t, err.Error(), "CLAUDECODE")
		assert.Empty(t, *got, "no window is opened for an agent")
		assert.Equal(t, "pending", status(t, database, id))
	})
}

// F13: the Desktop recognises its own launch by the exact argv it passed
// (OwnerConfirmGrants); the CLI must send os.Args[1:] unchanged. A real
// subprocess talks to a real socket server here.
func TestOwnerConfirmRequestArgsAreTheProcessArgv(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("the peer pid is read on macOS only")
	}
	home, err := os.MkdirTemp("/tmp", "oc") // short: sun_path is 104 bytes
	require.NoError(t, err)
	t.Cleanup(func() { _ = os.RemoveAll(home) })
	cfgDir := filepath.Join(home, ".config", "watchtower")
	wsDir := filepath.Join(home, ".local", "share", "watchtower", "t")
	require.NoError(t, os.MkdirAll(cfgDir, 0o700))
	require.NoError(t, os.MkdirAll(wsDir, 0o700))
	require.NoError(t, os.WriteFile(filepath.Join(cfgDir, "config.yaml"), []byte("active_workspace: t\n"), 0o600))
	l, err := net.Listen("unix", filepath.Join(wsDir, ownerconfirm.FileName))
	require.NoError(t, err)
	t.Cleanup(func() { _ = l.Close() })
	got := make(chan ownerconfirm.Request, 1)
	go func() {
		c, err := l.Accept()
		if err != nil {
			return
		}
		defer func() { _ = c.Close() }()
		line, err := bufio.NewReader(c).ReadBytes('\n')
		if err != nil {
			return
		}
		var req ownerconfirm.Request
		_ = json.Unmarshal(line, &req)
		got <- req
		_, _ = c.Write([]byte(`{"decision":"denied"}` + "\n"))
	}()

	argv := []string{"actions", "approve", "7", "--args-sha256", "a b", "--patch", `{"text":"hi there"}`, "--json"}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	c := exec.CommandContext(ctx, os.Args[0], argv...)
	c.Env = append(slices.DeleteFunc(os.Environ(), func(kv string) bool {
		name, _, _ := strings.Cut(kv, "=")
		return name == "HOME" || slices.Contains(agentEnvMarkers, name)
	}), "HOME="+home, runCLIEnv+"=1", ownerconfirm.DevTrustUnsignedEnv+"=1")
	c.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	t.Cleanup(func() {
		if c.Process != nil {
			_ = syscall.Kill(-c.Process.Pid, syscall.SIGKILL)
		}
	})
	out, err := c.CombinedOutput()
	require.Error(t, err, "denied → non-zero exit: %s", out)
	select {
	case req := <-got:
		assert.Equal(t, argv, req.Args)
		assert.Equal(t, "approve an action", req.Verb)
	default:
		t.Fatalf("the Desktop got no request: %s", out)
	}
}
