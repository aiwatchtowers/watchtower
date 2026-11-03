package providerhealth

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"watchtower/internal/fsutil"
	"watchtower/internal/providers"
)

// Helpers are this test binary, never a live CLI, credential reader or model.
func TestHealthProcessHelper(t *testing.T) {
	action := os.Getenv("WATCHTOWER_HEALTH_HELPER")
	if action == "" {
		return
	}
	dir := os.Getenv("WATCHTOWER_HEALTH_HELPER_DIR")
	if action == "lock" {
		unlock, err := fsutil.LockFile(context.Background(), filepath.Join(dir, "health.lock"))
		if err != nil {
			t.Fatal(err)
		}
		defer unlock()
		fmt.Println("locked")
		_, _ = bufio.NewReader(os.Stdin).ReadByte()
		return
	}
	now := time.Date(2026, 1, 1, 0, 5, 0, 0, time.UTC)
	s := New(dir, func() time.Time { return now })
	if action == "seed-a" || action == "seed-b" {
		if err := s.RecordQuota(context.Background(), AccountScope("claude", action), &providers.Failure{Provider: "claude", Category: providers.Quota}); err != nil {
			t.Fatal(err)
		}
		return
	}
	_, ok, err := s.Claim(context.Background(), AccountScope("claude", "fake-account"), ProbeRequest{PendingSafe: true, Deadline: now.Add(time.Minute)})
	if err != nil {
		t.Fatal(err)
	}
	fmt.Printf("claimed=%v\n", ok)
}

type helperProcess struct {
	cmd    *exec.Cmd
	output bytes.Buffer
	waited bool
}

func startHelper(t *testing.T, dir, action string) *helperProcess {
	t.Helper()
	p := &helperProcess{cmd: exec.Command(os.Args[0], "-test.run=^TestHealthProcessHelper$")}
	p.cmd.Env = append(os.Environ(), "WATCHTOWER_HEALTH_HELPER="+action, "WATCHTOWER_HEALTH_HELPER_DIR="+dir)
	p.cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	p.cmd.Stdout = &p.output
	p.cmd.Stderr = &p.output
	if err := p.cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = syscall.Kill(-p.cmd.Process.Pid, syscall.SIGKILL)
		if !p.waited {
			_ = p.cmd.Wait()
			p.waited = true
		}
	})
	return p
}
func waitHelper(t *testing.T, p *helperProcess) {
	t.Helper()
	done := make(chan error, 1)
	go func() { done <- p.cmd.Wait() }()
	select {
	case err := <-done:
		p.waited = true
		if err != nil {
			t.Fatalf("helper: %v %s", err, p.output.String())
		}
	case <-time.After(10 * time.Second):
		_ = syscall.Kill(-p.cmd.Process.Pid, syscall.SIGKILL)
		<-done
		p.waited = true
		t.Fatal("helper timeout")
	}
}
func TestProcessesCompeteForOneLease(t *testing.T) {
	s, _, scope := fixture(t)
	record(t, s, scope, time.Time{})
	a := startHelper(t, s.dir, "claim")
	b := startHelper(t, s.dir, "claim")
	waitHelper(t, a)
	waitHelper(t, b)
	total := bytes.Count(a.output.Bytes(), []byte("claimed=true")) + bytes.Count(b.output.Bytes(), []byte("claimed=true"))
	if total != 1 {
		t.Fatalf("expected one lease: %s / %s", a.output.String(), b.output.String())
	}
	// A third process after both holders exit must still see the persisted lease.
	c := startHelper(t, s.dir, "claim")
	waitHelper(t, c)
	if !bytes.Contains(c.output.Bytes(), []byte("claimed=false")) {
		t.Fatal(c.output.String())
	}
}
func TestProcessDeathReleasesStableLock(t *testing.T) {
	s, _, scope := fixture(t)
	record(t, s, scope, time.Time{})
	cmd := exec.Command(os.Args[0], "-test.run=^TestHealthProcessHelper$")
	cmd.Env = append(os.Environ(), "WATCHTOWER_HEALTH_HELPER=lock", "WATCHTOWER_HEALTH_HELPER_DIR="+s.dir)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	waited := false
	t.Cleanup(func() {
		_ = stdin.Close()
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		if !waited {
			_ = cmd.Wait()
		}
	})
	ready := make(chan bool, 1)
	go func() { ready <- bufio.NewScanner(stdout).Scan() }()
	select {
	case ok := <-ready:
		if !ok {
			t.Fatal("helper failed to lock")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("helper readiness timeout")
	}
	before, err := os.Stat(filepath.Join(s.dir, "health.lock"))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if _, err := s.Read(ctx, scope); err == nil {
		t.Fatal("read ignored held flock")
	}
	if err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL); err != nil {
		t.Fatal(err)
	}
	_ = cmd.Wait()
	waited = true
	ctx2, cancel2 := context.WithTimeout(context.Background(), time.Second)
	defer cancel2()
	if _, err := s.Read(ctx2, scope); err != nil {
		t.Fatal(err)
	}
	after, err := os.Stat(filepath.Join(s.dir, "health.lock"))
	if err != nil {
		t.Fatal(err)
	}
	if !os.SameFile(before, after) {
		t.Fatal("lock inode replaced")
	}
}

func TestProcessesInitializeOneSaltWithoutLostUpdates(t *testing.T) {
	dir := t.TempDir()
	a := startHelper(t, dir, "seed-a")
	b := startHelper(t, dir, "seed-b")
	waitHelper(t, a)
	waitHelper(t, b)
	s := New(dir, func() time.Time { return time.Date(2026, 1, 1, 0, 5, 0, 0, time.UTC) })
	for _, identity := range []string{"seed-a", "seed-b"} {
		if v := read(t, s, AccountScope("claude", identity)); v.State != QuotaWait {
			t.Fatalf("lost concurrent initialization: %+v", v)
		}
	}
}
