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
	"time"
)

// testPathCache is a usagePathCache with no inherited or well-known PATH
// and a fixed clock.
func testPathCache(shell func(context.Context) (string, bool)) *usagePathCache {
	now := time.Date(2026, 11, 18, 10, 0, 0, 0, time.UTC)
	return &usagePathCache{shell: shell, fallback: func() string { return "" },
		inherited: func() string { return "" }, now: func() time.Time { return now }}
}

func writeCLI(t *testing.T, dir string) string {
	t.Helper()
	cli := filepath.Join(dir, "claude")
	if err := os.WriteFile(cli, []byte("#!/bin/sh\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	return cli
}

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
	c := testPathCache(func(context.Context) (string, bool) { calls.Add(1); return "/x", true })
	c.fallback = func() string { return "/usr/bin:/bin" }
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
		c := testPathCache(func(ctx context.Context) (string, bool) { calls.Add(1); <-ctx.Done(); return "", false })
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
	c := testPathCache(func(context.Context) (string, bool) { calls.Add(1); return dir, true })
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
		t.Errorf("shell calls = %d, want 1 (an answer is cached, a miss within usageShellRetry does not re-ask)", calls.Load())
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

// The poll runs the claude the AI calls run: FindBinary's order, inherited
// PATH first.
func TestUsageCommand_InheritedPATHFirst(t *testing.T) {
	inherited, login := t.TempDir(), t.TempDir()
	want := writeCLI(t, inherited)
	writeCLI(t, login)
	c := testPathCache(func(context.Context) (string, bool) { return login, true })
	c.inherited = func() string { return inherited }
	if bin, _ := c.command(t.Context(), ""); bin != want {
		t.Fatalf("bin = %q, want the inherited PATH's %q", bin, want)
	}
}

// An installer that adds a new folder to the login profile is picked up: a
// miss re-asks the shell, at most once per usageShellRetry.
func TestUsageCommand_MissRefreshesLoginPATH(t *testing.T) {
	old, added := t.TempDir(), t.TempDir()
	var calls atomic.Int32
	answer := old
	c := testPathCache(func(context.Context) (string, bool) { calls.Add(1); return answer, true })
	now := time.Date(2026, 11, 18, 10, 0, 0, 0, time.UTC)
	c.now = func() time.Time { return now }
	if bin, _ := c.command(t.Context(), ""); bin != "claude" {
		t.Fatalf("bin = %q, want bare claude", bin)
	}
	answer = old + ":" + added
	want := writeCLI(t, added)
	now = now.Add(time.Minute)
	if bin, _ := c.command(t.Context(), ""); bin != "claude" {
		t.Fatalf("bin = %q within the retry interval, want bare claude", bin)
	}
	if calls.Load() != 1 {
		t.Fatalf("shell calls = %d within the retry interval, want 1", calls.Load())
	}
	now = now.Add(usageShellRetry)
	bin, env := c.command(t.Context(), "")
	if bin != want {
		t.Fatalf("bin = %q after the retry interval, want %q", bin, want)
	}
	if pathOf(t, env) != old+":"+added {
		t.Errorf("PATH = %q, want the refreshed login PATH", pathOf(t, env))
	}
	if calls.Load() != 2 {
		t.Errorf("shell calls = %d, want 2", calls.Load())
	}
	// Found: no more shell runs.
	now = now.Add(usageShellRetry)
	c.command(t.Context(), "")
	if calls.Load() != 2 {
		t.Errorf("shell calls = %d after a hit, want 2", calls.Load())
	}
}

// An empty answer is a miss, not a cached success.
func TestUsageCommand_EmptyAnswerNotCached(t *testing.T) {
	var calls atomic.Int32
	c := testPathCache(func(context.Context) (string, bool) { calls.Add(1); return "", true })
	c.command(t.Context(), "")
	c.command(t.Context(), "")
	if calls.Load() != 2 {
		t.Fatalf("shell calls = %d, want 2", calls.Load())
	}
}

func TestParseUsagePATH(t *testing.T) {
	for name, tc := range map[string]struct {
		out, want string
		ok        bool
	}{
		"banner":    {"Welcome /opt/banner/bin\nlast login\n\n" + usagePATHMarker + "\n/a:/b\n", "/a:/b", true},
		"no marker": {"/a:/b\n", "", false},
		"empty":     {"\n" + usagePATHMarker + "\n\n", "", false},
	} {
		got, ok := parseUsagePATH([]byte(tc.out))
		if got != tc.want || ok != tc.ok {
			t.Errorf("%s: got %q %v, want %q %v", name, got, ok, tc.want, tc.ok)
		}
	}
}

// A real shell whose profile prints a banner: only the marked PATH counts.
func TestLoginShellPATHUntil_BannerIgnored(t *testing.T) {
	dir := t.TempDir()
	shell := filepath.Join(dir, "shell")
	// Stands in for `$SHELL -l -c <cmd>`: prints a banner, then runs <cmd>.
	script := "#!/bin/sh\necho 'Welcome /opt/banner/bin'\nexec /bin/sh -c \"$3\"\n"
	if err := os.WriteFile(shell, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", "/usr/bin:/bin:/wt-test/bin")
	got, ok := loginShellPATHUntil(t.Context(), shell)
	if !ok || got != "/usr/bin:/bin:/wt-test/bin" {
		t.Fatalf("got %q %v", got, ok)
	}
}
