package digest

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// A cancelled isolated child is killed with its whole process group (a
// grandchild included), and the dropped variables never reach it.
func TestIsolateChildKillsTheGroupAndDropsEnv(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "child.sh")
	if err := os.WriteFile(script, []byte("#!/bin/sh\n"+
		"env > '"+dir+"/env'\n"+
		"sleep 60 &\n"+
		"echo $! > '"+dir+"/grandchild.tmp' && mv '"+dir+"/grandchild.tmp' '"+dir+"/grandchild'\n"+
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
	var grandchild int
	deadline := time.Now().Add(10 * time.Second)
	for grandchild == 0 {
		if b, err := os.ReadFile(filepath.Join(dir, "grandchild")); err == nil {
			grandchild, _ = strconv.Atoi(strings.TrimSpace(string(b)))
		} else if time.Now().After(deadline) {
			t.Fatal("the child never started its grandchild")
		} else {
			time.Sleep(20 * time.Millisecond)
		}
	}

	cancel()
	_ = cmd.Wait()
	ReapChild(cmd)

	for syscall.Kill(grandchild, 0) == nil {
		if time.Now().After(deadline) {
			t.Fatalf("grandchild %d outlived the cancelled child", grandchild)
		}
		time.Sleep(20 * time.Millisecond)
	}
	env, err := os.ReadFile(filepath.Join(dir, "env"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(env), "WT_DROP_ME=") || !strings.Contains(string(env), "WT_KEEP_ME=1") {
		t.Fatalf("env = %q: WT_DROP_ME must be gone, WT_KEEP_ME kept", env)
	}
}
