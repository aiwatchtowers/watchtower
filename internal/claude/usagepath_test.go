package claude

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"testing/synctest"
)

func pathOf(t *testing.T, env []string) string {
	t.Helper()
	for i := len(env) - 1; i >= 0; i-- {
		if v, ok := strings.CutPrefix(env[i], "PATH="); ok {
			return v
		}
	}
	t.Fatal("no PATH in env")
	return ""
}

// A configured CLI never starts the login shell.
func TestUsageCommand_OverrideRunsNoShell(t *testing.T) {
	dir := t.TempDir()
	cli := filepath.Join(dir, "claude-cli")
	if err := os.WriteFile(cli, []byte("#!/bin/sh\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	var calls atomic.Int32
	c := &usagePathCache{fallback: func() string { return "/usr/bin:/bin" },
		shell: func(context.Context) (string, bool) { calls.Add(1); return "", true }}
	bin, env := c.command(t.Context(), cli)
	if bin != cli {
		t.Fatalf("bin = %q, want %q", bin, cli)
	}
	if got := filepath.SplitList(pathOf(t, env)); !slices.Contains(got, dir) {
		t.Errorf("PATH %v lacks the CLI's folder", got)
	}
	if calls.Load() != 0 {
		t.Errorf("login shell ran %d times for a configured CLI", calls.Load())
	}
}

// A hung login shell costs at most usageShellBudget (or the poll's ctx), is
// not cached, and is asked again next time.
func TestUsageCommand_HungShellIsBounded(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var calls atomic.Int32
		c := &usagePathCache{fallback: func() string { return "" },
			shell: func(ctx context.Context) (string, bool) { calls.Add(1); <-ctx.Done(); return "", false }}
		bin, _ := c.command(context.Background(), "")
		if bin != "claude" {
			t.Fatalf("bin = %q, want bare claude", bin)
		}
		// The poll's own cancellation ends discovery too (daemon shutdown).
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan struct{})
		go func() { defer close(done); c.command(ctx, "") }()
		synctest.Wait()
		cancel()
		<-done
		if calls.Load() != 2 {
			t.Fatalf("shell calls = %d, want 2 (a failed discovery is not cached)", calls.Load())
		}
	})
}

// spec §11: a CLI installed after the daemon started is found on the next
// poll, through the login shell's PATH (not the daemon's minimal one).
func TestUsageCommand_FindsCLIInstalledLater(t *testing.T) {
	dir := t.TempDir()
	var calls atomic.Int32
	c := &usagePathCache{fallback: func() string { return "" },
		shell: func(context.Context) (string, bool) { calls.Add(1); return dir, true }}
	if bin, _ := c.command(t.Context(), ""); bin != "claude" {
		t.Fatalf("bin = %q before install, want bare claude", bin)
	}
	cli := filepath.Join(dir, "claude")
	if err := os.WriteFile(cli, []byte("#!/bin/sh\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	bin, env := c.command(t.Context(), "")
	if bin != cli {
		t.Fatalf("bin = %q after install, want %q", bin, cli)
	}
	if pathOf(t, env) != dir {
		t.Errorf("PATH = %q, want %q", pathOf(t, env), dir)
	}
	if calls.Load() != 1 {
		t.Errorf("shell calls = %d, want 1 (an answer is cached)", calls.Load())
	}
}

// A login shell that hangs with a child holding its stdout returns as soon as
// ctx ends: the whole group is killed.
func TestLoginShellPATHUntil_CancelKillsGroup(t *testing.T) {
	dir := t.TempDir()
	fifo := filepath.Join(dir, "ready")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	shell := filepath.Join(dir, "shell")
	script := "#!/bin/sh\n/bin/sleep 600 &\necho $$ > '" + fifo + "'\nwait\n"
	if err := os.WriteFile(shell, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	type result struct {
		path string
		ok   bool
	}
	res := make(chan result, 1)
	go func() { p, ok := loginShellPATHUntil(ctx, shell); res <- result{p, ok} }()
	b, err := os.ReadFile(fifo) // blocks until the shell is up
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil || pid <= 0 {
		t.Fatalf("pid %q: %v", b, err)
	}
	t.Cleanup(func() {
		if err := syscall.Kill(-pid, syscall.SIGKILL); err != nil && !errors.Is(err, syscall.ESRCH) && !errors.Is(err, syscall.EPERM) {
			t.Errorf("kill group %d: %v", pid, err)
		}
	})
	cancel()
	if r := <-res; r.ok || r.path != "" {
		t.Fatalf("result = %+v, want no answer", r)
	}
	if err := syscall.Kill(pid, 0); !errors.Is(err, syscall.ESRCH) {
		t.Errorf("shell %d still there after return (kill err %v)", pid, err)
	}
}
