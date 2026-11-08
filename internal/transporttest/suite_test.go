// Package transporttest is the transport contract suite (spec
// 2026-11-05-llm-transport-independence §4): one scenario table run against
// every LLM transport adapter at the batch, stream and chat levels, and
// against the Workbench session agents. Each adapter × level × scenario cell
// resolves to pass, unsupported (the capability is absent and its own
// assertion holds) or gap:<id> (an open parity gap of the spec's §2.2: the
// cell fails today and the gap's task flips it). The resolved matrix is
// testdata/matrix.golden; `go test ./internal/transporttest -update`
// rewrites it. t.Skip is forbidden in this package except behind the live
// gate (TestTransportSuite_NoSkip).
package transporttest

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"watchtower/internal/ai"
	"watchtower/internal/gittest"
	"watchtower/internal/llmusage"
)

// bins are the binaries TestMain builds: the fake CLI under the names claude
// and codex, and the watchtower binary the session hooks run.
var bins struct {
	dir, claude, codex, watchtower string
}

func TestMain(m *testing.M) {
	os.Exit(runMain(m))
}

func runMain(m *testing.M) int {
	gittest.DisableBackgroundGit()
	dir, err := os.MkdirTemp("", "transporttest-")
	if err != nil {
		fmt.Fprintln(os.Stderr, "transporttest:", err)
		return 1
	}
	defer func() { _ = os.RemoveAll(dir) }()
	bins.dir = filepath.Join(dir, "bin")
	bins.claude = filepath.Join(bins.dir, "claude")
	bins.codex = filepath.Join(bins.dir, "codex")
	bins.watchtower = filepath.Join(bins.dir, "watchtower")
	// Built before HOME moves: go build keeps its own build and module
	// caches.
	for _, b := range []struct{ out, pkg string }{
		{bins.claude, "watchtower/internal/transporttest/fakecli"},
		{bins.watchtower, "watchtower"},
	} {
		cmd := exec.Command("go", "build", "-o", b.out, b.pkg)
		if out, err := cmd.CombinedOutput(); err != nil {
			fmt.Fprintf(os.Stderr, "transporttest: building %s: %v\n%s", b.pkg, err, out)
			return 1
		}
	}
	if err := os.Link(bins.claude, bins.codex); err != nil {
		fmt.Fprintln(os.Stderr, "transporttest:", err)
		return 1
	}
	// No child of the suite reads or writes the owner's real home.
	home := filepath.Join(dir, "home")
	if err := os.MkdirAll(home, 0o700); err != nil {
		fmt.Fprintln(os.Stderr, "transporttest:", err)
		return 1
	}
	realHome, realCodexHome = os.Getenv("HOME"), os.Getenv("CODEX_HOME")
	for _, env := range []string{"WATCHTOWER_LIVE_CLAUDE", "WATCHTOWER_LIVE_CODEX", "WATCHTOWER_LIVE_OLLAMA"} {
		liveOptIns[env] = strings.TrimSpace(os.Getenv(env)) != ""
	}
	// A WATCHTOWER_* variable of the developer's shell (a config path, an
	// agent marker) must not reach the adapters or their children.
	for _, kv := range os.Environ() {
		if name, _, _ := strings.Cut(kv, "="); strings.HasPrefix(name, "WATCHTOWER_") {
			_ = os.Unsetenv(name)
		}
	}
	_ = os.Setenv("HOME", home)
	_ = os.Setenv("CODEX_HOME", filepath.Join(home, ".codex"))
	llmusage.SetSink(ledger)
	return m.Run()
}

// realHome and realCodexHome are the environment's before TestMain
// isolates it; only the live job uses them.
var realHome, realCodexHome string

// liveOptIns are the live job's switches, read before TestMain strips the
// WATCHTOWER_* variables.
var liveOptIns = map[string]bool{}

// ledger captures the llm_calls rows the adapters record (LLMUSAGE-01).
var ledger = &captureSink{}

type captureSink struct {
	mu    sync.Mutex
	calls []llmusage.Call
}

func (s *captureSink) Write(c llmusage.Call) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls = append(s.calls, c)
	return nil
}

func (s *captureSink) take() []llmusage.Call {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := s.calls
	s.calls = nil
	return out
}

// pidGone reports whether pid no longer exists, polling kill(pid, 0) until
// ESRCH for at most wait. A fake the adapter started but never waited for
// stays a zombie and reads as not gone.
func pidGone(pid int, wait time.Duration) bool {
	deadline := time.Now().Add(wait)
	for {
		if err := syscall.Kill(pid, 0); errors.Is(err, syscall.ESRCH) {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// reapAll kills every process group and pid a cell's fakes logged and waits
// for each to be gone (the house rule for tests that spawn processes).
func reapAll(t *testing.T, launches []launch) {
	t.Helper()
	for _, l := range launches {
		if l.PGID > 1 && l.PGID != syscall.Getpgrp() {
			_ = syscall.Kill(-l.PGID, syscall.SIGKILL)
		}
		for _, pid := range append([]int{l.PID}, l.Grandchildren...) {
			if pid > 1 {
				_ = syscall.Kill(pid, syscall.SIGKILL)
			}
		}
	}
	for _, l := range launches {
		for _, pid := range append([]int{l.PID}, l.Grandchildren...) {
			if pid > 1 && !pidGone(pid, 5*time.Second) {
				t.Errorf("fake pid %d survived the cleanup", pid)
			}
		}
	}
}

// TestFakeCLI_GroupReaped pins the harness's own guarantee: a fake run in
// its own process group with a grandchild holding stdout is gone, grandchild
// included, after its context is cancelled.
func TestFakeCLI_GroupReaped(t *testing.T) {
	dir := t.TempDir()
	fixture := filepath.Join(dir, "hang.jsonl")
	writeFile(t, fixture, "#! ignore-sigint\n#! spawn-grandchild\n{\"type\":\"started\"}\n#! hang\n")
	log := filepath.Join(dir, "fake.log")
	ctx, cancel := context.WithCancel(context.Background())
	cmd := exec.CommandContext(ctx, bins.claude)
	cmd.Env = append(os.Environ(), "WT_FAKECLI_FIXTURE="+fixture, "WT_FAKECLI_LOG="+log)
	reap := ai.ConfigureChild(cmd)
	defer reap()
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { reapAll(t, readLaunches(t, log)) })
	buf := make([]byte, 64)
	if _, err := stdout.Read(buf); err != nil {
		t.Fatalf("no first line: %v", err)
	}
	launches := readLaunches(t, log)
	if len(launches) != 1 || len(launches[0].Grandchildren) != 1 {
		t.Fatalf("want one launch with one grandchild, got %+v", launches)
	}
	cancel()
	_ = cmd.Wait()
	for _, pid := range []int{launches[0].PID, launches[0].Grandchildren[0]} {
		if !pidGone(pid, 5*time.Second) {
			t.Errorf("pid %d survived the group kill", pid)
		}
	}
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

// skipLive is the only t.Skip of the package: the live job runs only with
// its environment variable set.
func skipLive(t *testing.T, env string) {
	t.Helper()
	if !liveOptIns[env] {
		t.Skip("live: set " + env + "=1") // the live gate
	}
}
