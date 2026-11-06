package fsutil

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestWritePrivateTemp(t *testing.T) {
	path, err := WritePrivateTemp("fsutil-test-*.txt", "payload")
	if err != nil {
		t.Fatalf("WritePrivateTemp: %v", err)
	}
	t.Cleanup(func() { os.Remove(path) })

	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("mode = %v, want 0600", info.Mode().Perm())
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if string(data) != "payload" {
		t.Errorf("content = %q, want %q", data, "payload")
	}
}

// SweepStaleTemp removes only old files carrying the prefix: a fresh
// one (a call still running), another prefix and a directory stay.
func TestSweepStaleTemp_OnlyOldPrefixed(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("TMPDIR", dir)
	now := time.Now()
	old := now.Add(-time.Hour)
	write := func(name string, mod time.Time) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(p, mod, mod); err != nil {
			t.Fatal(err)
		}
		return p
	}
	stale := write(SystemPromptTempPrefix+"1.txt", old)
	fresh := write(SystemPromptTempPrefix+"2.txt", now)
	other := write("other-1.txt", old)
	subdir := filepath.Join(dir, SystemPromptTempPrefix+"dir")
	if err := os.Mkdir(subdir, 0o700); err != nil {
		t.Fatal(err)
	}

	n, err := SweepStaleTemp(10*time.Minute, now)
	if err != nil || n != 1 {
		t.Fatalf("SweepStaleTemp = %d, %v; want 1, nil", n, err)
	}
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Errorf("stale file still there: %v", err)
	}
	for _, p := range []string{fresh, other, subdir} {
		if _, err := os.Stat(p); err != nil {
			t.Errorf("%s must stay: %v", p, err)
		}
	}
}

func TestSweepStaleTemp_AllPrefixes(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("TMPDIR", dir)
	now := time.Now()
	old := now.Add(-11 * time.Minute)
	write := func(name string, at time.Time) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Chtimes(p, at, at); err != nil {
			t.Fatal(err)
		}
		return p
	}
	stale := []string{
		write(SystemPromptTempPrefix+"a.txt", old),
		write("wt-chat-prompt-a.txt", old),
		write("wt-chat-mcp-a.json", old),
		write("wt-chat-image-a.png", old), // a killed codex turn's --image copy
		write("wt-mcp-a.json", old),
	}
	fresh := write(SystemPromptTempPrefix+"fresh.txt", now)
	turn := write("wt-chat-turn-x.txt", old)     // lives for a whole session
	status := write("wt-mcp-status-1.json", old) // session-long, though wt-mcp-*.json matches
	other := write("other-old.txt", old)

	n, err := SweepStaleTemp(10*time.Minute, now)
	if err != nil || n != len(stale) {
		t.Fatalf("SweepStaleTemp = %d, %v; want %d, nil", n, err, len(stale))
	}
	for _, p := range stale {
		if _, err := os.Stat(p); !os.IsNotExist(err) {
			t.Errorf("%s survived", p)
		}
	}
	for _, p := range []string{fresh, turn, status, other} {
		if _, err := os.Stat(p); err != nil {
			t.Errorf("%s was removed: %v", p, err)
		}
	}
}

func TestSweepStaleDir(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "extract")
	if n, err := SweepStaleDir(dir, time.Minute, time.Now()); n != 0 || err != nil {
		t.Fatalf("missing dir: %d, %v", n, err)
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	oldFile := filepath.Join(dir, "att-old.pdf")
	freshFile := filepath.Join(dir, "att-new.pdf")
	for _, p := range []string{oldFile, freshFile} {
		if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	old := now.Add(-11 * time.Minute)
	if err := os.Chtimes(oldFile, old, old); err != nil {
		t.Fatal(err)
	}
	n, err := SweepStaleDir(dir, 10*time.Minute, now)
	if err != nil || n != 1 {
		t.Fatalf("SweepStaleDir = %d, %v", n, err)
	}
	if _, err := os.Stat(freshFile); err != nil {
		t.Errorf("fresh file removed: %v", err)
	}
}

// A child that reads a held file, writes output and reads it again (codex
// re-reads its model_instructions_file for every model request) gets the
// content each time; the file goes only on release, and a second release
// is a no-op.
func TestHoldTempFile_KeepsTheFileUntilRelease(t *testing.T) {
	t.Setenv("TMPDIR", t.TempDir())
	path, err := WritePrivateTemp(SystemPromptTempPrefix+"*.txt", "body")
	if err != nil {
		t.Fatal(err)
	}
	release, err := HoldTempFile(path)
	if err != nil {
		t.Fatalf("hold: %v", err)
	}
	if held, perr := mayBeHeld(path); !held || perr != nil {
		t.Fatalf("mayBeHeld = %v, %v; want held by the flock", held, perr)
	}
	out, err := exec.Command("/bin/sh", "-c", `cat "$0"; cat "$0"`, path).Output()
	if err != nil {
		t.Fatal(err)
	}
	if string(out) != "bodybody" {
		t.Fatalf("child read %q", out)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("a held file must stay until release: %v", err)
	}
	release()
	release()
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("file still there: %v", err)
	}
	noop, err := HoldTempFile("")
	if err != nil {
		t.Fatalf("hold of \"\": %v", err)
	}
	noop()
}

// A file the hold cannot open is still removed on release, and the error
// says it is unshielded without naming it (it reaches a log).
func TestHoldTempFile_UnshieldedStillRemoved(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root opens a 0000 file")
	}
	t.Setenv("TMPDIR", t.TempDir())
	path, err := WritePrivateTemp(SystemPromptTempPrefix+"*.txt", "body")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0); err != nil {
		t.Fatal(err)
	}
	release, err := HoldTempFile(path)
	if err == nil {
		t.Fatal("want an unshielded error for a file the hold cannot open")
	}
	if strings.Contains(err.Error(), filepath.Base(path)) {
		t.Errorf("error names the file: %v", err)
	}
	release()
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("file still there: %v", err)
	}
}

// The sweep never takes a held file, however old (a long codex run, or a
// Mac that slept through one): the holder's flock marks it live. Once the
// hold is gone without a remove — the holder was killed, and the kernel
// dropped its lock — the stale file is a leftover and goes.
func TestHoldTempFile_SweepSkipsAHeldFile(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("TMPDIR", dir)
	path, err := WritePrivateTemp(SystemPromptTempPrefix+"*.txt", "body")
	if err != nil {
		t.Fatal(err)
	}
	stale := time.Now().Add(-time.Hour)
	if err := os.Chtimes(path, stale, stale); err != nil {
		t.Fatal(err)
	}
	release, err := HoldTempFile(path)
	if err != nil {
		t.Fatal(err)
	}
	defer release()
	if n, err := SweepStaleTemp(10*time.Minute, time.Now()); err != nil || n != 0 {
		t.Fatalf("sweep removed %d (%v), want the held file kept", n, err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("held file swept: %v", err)
	}

	// A holder that died: its descriptor (and so its lock) is gone, the file
	// stays. Simulated with a lock taken and dropped by a second open.
	orphan, err := WritePrivateTemp(SystemPromptTempPrefix+"*.txt", "body")
	if err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(orphan)
	if err != nil {
		t.Fatal(err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_SH); err != nil {
		t.Fatal(err)
	}
	_ = f.Close()
	if err := os.Chtimes(orphan, stale, stale); err != nil {
		t.Fatal(err)
	}
	if n, err := SweepStaleTemp(10*time.Minute, time.Now()); err != nil || n != 1 {
		t.Fatalf("sweep removed %d (%v), want the orphan only", n, err)
	}
	if _, err := os.Stat(orphan); !os.IsNotExist(err) {
		t.Fatalf("orphan still there: %v", err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("held file swept: %v", err)
	}
}

// The probe fails closed: a stale prompt file the sweep cannot open (so
// cannot tell whether a live process holds it) is kept, not removed, and
// the sweep reports the probe failure.
func TestSweepStaleTemp_KeepsAFileItCannotProbe(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root opens a 0000 file")
	}
	dir := t.TempDir()
	t.Setenv("TMPDIR", dir)
	path, err := WritePrivateTemp(SystemPromptTempPrefix+"*.txt", "body")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(path, 0o600) })
	stale := time.Now().Add(-time.Hour)
	if err := os.Chtimes(path, stale, stale); err != nil {
		t.Fatal(err)
	}
	n, err := SweepStaleTemp(10*time.Minute, time.Now())
	if n != 0 {
		t.Fatalf("sweep removed %d, want the unprobeable file kept", n)
	}
	if err == nil || !strings.Contains(err.Error(), "probing") {
		t.Fatalf("err = %v, want the probe failure reported", err)
	}
	if strings.Contains(err.Error(), filepath.Base(path)) {
		t.Errorf("error names the file: %v", err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("file swept: %v", err)
	}
}

// A codex run's private temp home holds its rollout: the sweep removes a
// killed run's stale home (its hold dropped), keeps a live run's held one
// and a fresh one, and never follows the auth link out of the home.
func TestSweepStaleTemp_RemovesUnheldCodexHomes(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("TMPDIR", dir)
	owner := filepath.Join(t.TempDir(), "auth.json")
	if err := os.WriteFile(owner, []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	stale := time.Now().Add(-time.Hour)
	home := func(name string, hold bool) (string, func()) {
		p := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Join(p, "sessions"), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(p, "sessions", "rollout.jsonl"), []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(owner, filepath.Join(p, "auth.json")); err != nil {
			t.Fatal(err)
		}
		release, err := HoldTempHome(p)
		if err != nil {
			t.Fatal(err)
		}
		if !hold {
			release = func() {}
			mustDropHold(t, filepath.Join(p, tempHomeHold))
		}
		if err := os.Chtimes(p, stale, stale); err != nil {
			t.Fatal(err)
		}
		return p, release
	}
	killed, _ := home("wt-agent-codex-home-1", false)
	reviewer, _ := home("wt-review-codex-home-1", false)
	live, release := home("wt-agent-codex-home-2", true)
	defer release()
	fresh := filepath.Join(dir, "wt-review-codex-home-2")
	if err := os.Mkdir(fresh, 0o700); err != nil {
		t.Fatal(err)
	}
	other := filepath.Join(dir, "other-codex-home-1")
	if err := os.Mkdir(other, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(other, stale, stale); err != nil {
		t.Fatal(err)
	}

	if n, err := SweepStaleTemp(10*time.Minute, time.Now()); err != nil || n != 2 {
		t.Fatalf("SweepStaleTemp = %d, %v; want the two unheld stale homes", n, err)
	}
	for _, p := range []string{killed, reviewer} {
		if _, err := os.Lstat(p); !os.IsNotExist(err) {
			t.Errorf("%s still there: %v", filepath.Base(p), err)
		}
	}
	for _, p := range []string{live, fresh, other, owner} {
		if _, err := os.Stat(p); err != nil {
			t.Errorf("%s must stay: %v", filepath.Base(p), err)
		}
	}
}

// mustDropHold stands in for a dead holder: the hold file stays, unlocked.
// Replacing it leaves this process's lock on the old, unlinked inode.
func mustDropHold(t *testing.T, path string) {
	t.Helper()
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
}
