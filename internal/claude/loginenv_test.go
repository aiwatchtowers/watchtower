package claude

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
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
	got := readLoginShellEnvUntil(context.Background(), "/bin/sh") // no time limit of the test's own
	if got["WT_LOGIN_ENV_TEST"] != "acme value=1" {
		t.Fatalf("WT_LOGIN_ENV_TEST = %q", got["WT_LOGIN_ENV_TEST"])
	}
}

// A shell that hangs yields no environment once its time is up (here the
// context ends once the shell is running), and its process group is killed:
// nothing is left running. A group left alive would hang the read until go
// test -timeout.
func TestReadLoginShellEnv_Timeout(t *testing.T) {
	dir := t.TempDir()
	fifo := filepath.Join(dir, "pid")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	shell := filepath.Join(dir, "hang-shell")
	if err := os.WriteFile(shell, []byte("#!/bin/sh\necho $$ > '"+fifo+"'\nexec sleep 1000000\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	got := make(chan map[string]string, 1)
	go func() { got <- readLoginShellEnvUntil(ctx, shell) }()
	b, err := os.ReadFile(fifo) // the shell is up once it wrote its pid
	if err != nil {
		t.Fatal(err)
	}
	pid, _ := strconv.Atoi(strings.TrimSpace(string(b)))
	t.Cleanup(func() { _ = syscall.Kill(-pid, syscall.SIGKILL) })
	cancel()
	if env := <-got; env != nil {
		t.Fatalf("env = %v, want none", env)
	}
	if err := syscall.Kill(pid, 0); !errors.Is(err, syscall.ESRCH) {
		t.Errorf("the shell (pid %d) is still running: %v", pid, err)
	}
}
