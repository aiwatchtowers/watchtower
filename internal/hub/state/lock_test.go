package state

import (
	"bufio"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// lockHelperEnv makes the test binary a child that holds the hub lock of
// the named dir until its stdin closes.
const lockHelperEnv = "WATCHTOWER_HUBSTATE_LOCK_HELPER"

func TestMain(m *testing.M) {
	if dir := os.Getenv(lockHelperEnv); dir != "" {
		os.Exit(holdLockForParent(dir))
	}
	os.Exit(m.Run())
}

func holdLockForParent(dir string) int {
	l, err := AcquireLock(dir)
	if err != nil {
		_, _ = os.Stdout.WriteString("error " + err.Error() + "\n")
		return 1
	}
	_, _ = os.Stdout.WriteString("locked\n")
	_, _ = bufio.NewReader(os.Stdin).ReadString('\n')
	_ = l.Release()
	return 0
}

func TestSecondLockRefused(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "hub")
	l, err := AcquireLock(dir)
	if err != nil {
		t.Fatalf("AcquireLock: %v", err)
	}
	assertMode(t, dir, 0o700)
	assertMode(t, filepath.Join(dir, "hub.lock"), 0o600)
	raw, err := os.ReadFile(filepath.Join(dir, "hub.lock"))
	if err != nil || strings.TrimSpace(string(raw)) != strconv.Itoa(os.Getpid()) {
		t.Fatalf("hub.lock = %q %v, want our pid", raw, err)
	}
	if _, err := AcquireLock(dir); !errors.Is(err, ErrLocked) {
		t.Fatalf("second AcquireLock = %v, want ErrLocked", err)
	}
	if err := l.Release(); err != nil {
		t.Fatalf("Release: %v", err)
	}
	l2, err := AcquireLock(dir)
	if err != nil {
		t.Fatalf("AcquireLock after Release: %v", err)
	}
	if err := l2.Release(); err != nil {
		t.Fatal(err)
	}

	// Another process holding it refuses this one; its exit frees it.
	cmd := exec.Command(os.Args[0], "-test.run=^$")
	cmd.Env = append(os.Environ(), lockHelperEnv+"="+dir)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = stdin.Close()
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		_ = cmd.Wait()
	})
	line, err := bufio.NewReader(stdout).ReadString('\n')
	if err != nil || line != "locked\n" {
		t.Fatalf("child = %q %v", line, err)
	}
	if _, err := AcquireLock(dir); !errors.Is(err, ErrLocked) {
		t.Fatalf("AcquireLock while a child holds it = %v, want ErrLocked", err)
	}
	_ = stdin.Close()
	if err := cmd.Wait(); err != nil {
		t.Fatalf("child exit: %v", err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		l3, err := AcquireLock(dir)
		if err == nil {
			_ = l3.Release()
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("lock not freed after the child exited: %v", err)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestRelease_Twice(t *testing.T) {
	l, err := AcquireLock(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := l.Release(); err != nil {
		t.Fatal(err)
	}
	if err := l.Release(); err != nil {
		t.Fatalf("second Release = %v", err)
	}
}
