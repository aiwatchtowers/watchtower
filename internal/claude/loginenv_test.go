package claude

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// The dump is read only after the marker (whatever the startup files print
// before it), NUL-separated, values with '=' and newlines kept.
func TestParseLoginShellEnv(t *testing.T) {
	out := []byte("welcome banner\nKEY=noise\n" + loginEnvMarker + "\nA=1\x00B=x=y\x00C=line1\nline2\x00\x00=bad\x00")
	got := parseLoginShellEnv(out)
	want := map[string]string{"A": "1", "B": "x=y", "C": "line1\nline2"}
	if len(got) != len(want) {
		t.Fatalf("env = %q, want %q", got, want)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %q, want %q", k, got[k], v)
		}
	}
	if parseLoginShellEnv([]byte("A=1\x00")) != nil {
		t.Error("no marker must read as no environment")
	}
}

// A real login shell's environment carries a variable this process set.
func TestReadLoginShellEnv(t *testing.T) {
	t.Setenv("WT_LOGIN_ENV_TEST", "acme value=1")
	got := readLoginShellEnv("/bin/sh", 10*time.Second)
	if got["WT_LOGIN_ENV_TEST"] != "acme value=1" {
		t.Fatalf("WT_LOGIN_ENV_TEST = %q", got["WT_LOGIN_ENV_TEST"])
	}
}

// A shell that hangs yields no environment once the timeout passes, and its
// process group is killed (nothing is left running).
func TestReadLoginShellEnv_Timeout(t *testing.T) {
	dir := t.TempDir()
	pidFile := filepath.Join(dir, "pid")
	shell := filepath.Join(dir, "hang-shell")
	if err := os.WriteFile(shell, []byte("#!/bin/sh\necho $$ > '"+pidFile+"'\nexec sleep 30\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if b, err := os.ReadFile(pidFile); err == nil {
			if pid, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil {
				_ = syscall.Kill(-pid, syscall.SIGKILL)
			}
		}
	})
	start := time.Now()
	if got := readLoginShellEnv(shell, 2*time.Second); got != nil {
		t.Fatalf("env = %v, want none", got)
	}
	if d := time.Since(start); d > 5*time.Second {
		t.Fatalf("took %v", d)
	}
	b, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatal(err)
	}
	pid, _ := strconv.Atoi(strings.TrimSpace(string(b)))
	if err := syscall.Kill(pid, 0); !errors.Is(err, syscall.ESRCH) {
		t.Errorf("the shell (pid %d) is still running: %v", pid, err)
	}
}
