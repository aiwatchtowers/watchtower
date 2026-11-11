package digest

import (
	"bufio"
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

// A cancelled isolated child is killed with its whole process group (a
// grandchild included), and the dropped variables never reach it. The test
// waits on process events only: the group holds a FIFO open, so its "ready"
// line says the grandchild runs and EOF says the whole group has exited.
func TestIsolateChildKillsTheGroupAndDropsEnv(t *testing.T) {
	dir := t.TempDir()
	fifo := filepath.Join(dir, "group")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(dir, "child.sh")
	if err := os.WriteFile(script, []byte("#!/bin/sh\n"+
		"exec 3>'"+fifo+"'\n"+
		"env > '"+dir+"/env'\n"+
		"sleep 60 &\n"+
		"echo ready >&3\n"+
		"wait\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	cmd := exec.CommandContext(ctx, script)
	cmd.Env = append(os.Environ(), "WT_DROP_ME=1", "WT_KEEP_ME=1")
	IsolateChild(cmd, []string{"WT_DROP_ME"})
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		_ = cmd.Wait()
	})
	group, err := os.Open(fifo) // blocks until the child opens its end
	if err != nil {
		t.Fatal(err)
	}
	defer group.Close()
	if line, err := bufio.NewReader(group).ReadString('\n'); err != nil || line != "ready\n" {
		t.Fatalf("the child never started its grandchild: %q, %v", line, err)
	}

	cancel()
	_ = cmd.Wait()

	// EOF once every holder — the grandchild included — has exited.
	if _, err := io.Copy(io.Discard, group); err != nil {
		t.Fatal(err)
	}
	env, err := os.ReadFile(filepath.Join(dir, "env"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(env), "WT_DROP_ME=") || !strings.Contains(string(env), "WT_KEEP_ME=1") {
		t.Fatalf("env = %q: WT_DROP_ME must be gone, WT_KEEP_ME kept", env)
	}
}

// A nil cmd.Env means this process's environment: the dropped variables are
// filtered out of it, never left in by an empty list.
func TestIsolateChildNilEnvStartsFromTheProcessEnvironment(t *testing.T) {
	t.Setenv("WT_DROP_ME", "1")
	t.Setenv("WT_KEEP_ME", "1")
	cmd := exec.Command("true")
	IsolateChild(cmd, []string{"WT_DROP_ME"})
	joined := strings.Join(cmd.Env, "\n")
	if strings.Contains(joined, "WT_DROP_ME=") || !strings.Contains(joined, "WT_KEEP_ME=1") {
		t.Fatalf("env = %q: WT_DROP_ME must be gone, WT_KEEP_ME kept", cmd.Env)
	}
}

// A cancel after the child was waited for kills nothing and says so.
func TestIsolateChildCancelAfterTheWaitKillsNothing(t *testing.T) {
	cmd := exec.CommandContext(context.Background(), "true")
	IsolateChild(cmd, nil)
	if err := cmd.Run(); err != nil {
		t.Fatal(err)
	}
	if err := cmd.Cancel(); !errors.Is(err, os.ErrProcessDone) {
		t.Fatalf("cancel after the wait = %v, want os.ErrProcessDone", err)
	}
}
