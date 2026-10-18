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

// SweepStalePrivateTemp removes only old files carrying the prefix: a fresh
// one (a call still running), another prefix and a directory stay.
func TestSweepStalePrivateTemp(t *testing.T) {
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

	n, err := SweepStalePrivateTemp(SystemPromptTempPrefix, 10*time.Minute, now)
	if err != nil || n != 1 {
		t.Fatalf("SweepStalePrivateTemp = %d, %v; want 1, nil", n, err)
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
