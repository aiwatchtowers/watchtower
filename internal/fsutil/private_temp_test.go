package fsutil

import (
	"os"
	"path/filepath"
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
