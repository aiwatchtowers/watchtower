package cmd

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/spf13/pflag"

	"watchtower/internal/sessionhost"
)

func TestSessionHostCmd_RequiresSocket(t *testing.T) {
	old := flagSessionHostSocket
	t.Cleanup(func() { flagSessionHostSocket = old })
	flagSessionHostSocket = ""
	t.Setenv(sessionhost.SocketEnv, "")
	if err := runSessionHost(sessionHostCmd, nil); err == nil {
		t.Fatal("runSessionHost without --socket: want an error")
	}
}

// The production command's idle exit is the fixed 60 s (PROJ-20): the
// Options `watchtower session-host` hands NewServer carry IdleExit == 60 s,
// and the command has no flag that could change it. The Linux smoke test runs
// its host in-process with IdleExit 0 instead; this pins that the command
// itself never does.
func TestSessionHostCommandUsesTheFixed60sIdleExit(t *testing.T) {
	dir, err := os.MkdirTemp("", "wt-sh") // short: unix socket paths are capped
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	oldSocket, oldSetsid, oldNew, oldCtx := flagSessionHostSocket, sessionHostSetsid, newSessionHostServer, sessionHostCmd.Context()
	t.Cleanup(func() {
		flagSessionHostSocket, sessionHostSetsid, newSessionHostServer = oldSocket, oldSetsid, oldNew
		sessionHostCmd.SetContext(oldCtx)
	})
	flagSessionHostSocket = filepath.Join(dir, "h.sock")
	sessionHostSetsid = func() (int, error) { return 0, nil } // keep the test process in its session
	var got []sessionhost.Options
	newSessionHostServer = func(o sessionhost.Options) *sessionhost.Server {
		got = append(got, o)
		return sessionhost.NewServer(o)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // Serve returns at once
	sessionHostCmd.SetContext(ctx)

	if err := runSessionHost(sessionHostCmd, nil); err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].IdleExit != 60*time.Second {
		t.Fatalf("session-host options: %+v, want one with IdleExit 60s", got)
	}
	var flags []string
	sessionHostCmd.Flags().VisitAll(func(f *pflag.Flag) { flags = append(flags, f.Name) })
	if len(flags) != 1 || flags[0] != "socket" {
		t.Fatalf("session-host flags: %v, want only --socket", flags)
	}
}
