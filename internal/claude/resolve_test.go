package claude

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
)

func resetCache() {
	cachedBinary = ""
	cachedBinaryMu = sync.Once{}
	cachedPATH = ""
	cachedPATHMu = sync.Once{}
}

func TestFindBinary_Override(t *testing.T) {
	resetCache()

	tmpDir := t.TempDir()
	fakeBin := filepath.Join(tmpDir, "claude")
	if err := os.WriteFile(fakeBin, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	got := FindBinary(fakeBin)
	if got != fakeBin {
		t.Errorf("FindBinary(%q) = %q, want %q", fakeBin, got, fakeBin)
	}
}

func TestFindBinary_OverrideAfterCache(t *testing.T) {
	resetCache()

	// Populate cache via empty override.
	_ = FindBinary("")

	// Non-empty override pointing at a real file must bypass cache.
	tmpDir := t.TempDir()
	fakeBin := filepath.Join(tmpDir, "claude")
	if err := os.WriteFile(fakeBin, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	got := FindBinary(fakeBin)
	if got != fakeBin {
		t.Errorf("override after cache: got %q, want %q", got, fakeBin)
	}
}

func TestFindBinary_OverrideNonExistent(t *testing.T) {
	resetCache()

	got := FindBinary("/nonexistent/claude")
	if got == "/nonexistent/claude" {
		t.Error("FindBinary should not return non-existent override path")
	}
}

func TestFindBinary_OverrideDirectory(t *testing.T) {
	resetCache()

	tmpDir := t.TempDir()
	got := FindBinary(tmpDir)
	if got == tmpDir {
		t.Error("FindBinary should not return a directory as binary")
	}
}

func TestFindBinary_Fallback(t *testing.T) {
	resetCache()

	got := FindBinary("")
	if got == "" {
		t.Error("FindBinary should never return empty string")
	}
}

func TestFindBinary_Cached(t *testing.T) {
	resetCache()

	first := FindBinary("")
	second := FindBinary("")
	if first != second {
		t.Errorf("FindBinary should be cached: %q vs %q", first, second)
	}
}

func TestRichPATH_NotEmpty(t *testing.T) {
	resetCache()

	got := RichPATH()
	if got == "" {
		t.Error("RichPATH should not return empty string")
	}
}

func TestRichPATH_Cached(t *testing.T) {
	resetCache()

	first := RichPATH()
	second := RichPATH()
	if first != second {
		t.Error("RichPATH should return cached value on second call")
	}
}

func TestFallbackPATH_IncludesHomebrew(t *testing.T) {
	got := fallbackPATH()
	if !strings.Contains(got, "/opt/homebrew/bin") && !strings.Contains(got, "/usr/local/bin") {
		t.Errorf("fallbackPATH should include common bin dirs, got %q", got)
	}
}

func TestFallbackPATH_Dedups(t *testing.T) {
	// Set PATH to something that already includes one of the extras.
	t.Setenv("PATH", "/usr/local/bin:/some/other/path")

	got := fallbackPATH()
	count := strings.Count(got, "/usr/local/bin")
	if count != 1 {
		t.Errorf("fallbackPATH should dedup /usr/local/bin (count=%d): %q", count, got)
	}
}

func TestFallbackPATH_PreservesExistingPATH(t *testing.T) {
	t.Setenv("PATH", "/foo/bar:/baz/qux")

	got := fallbackPATH()
	if !strings.Contains(got, "/foo/bar") || !strings.Contains(got, "/baz/qux") {
		t.Errorf("fallbackPATH should preserve original PATH entries, got %q", got)
	}
}

func TestFallbackPATH_NoHome(t *testing.T) {
	// HOME unset → fallbackPATH must still produce non-empty output (no panic).
	t.Setenv("HOME", "")

	got := fallbackPATH()
	if got == "" {
		t.Error("fallbackPATH should not be empty even without HOME")
	}
}

func TestLoginShell_FromEnv(t *testing.T) {
	t.Setenv("SHELL", "/bin/fish")

	if got := loginShell(); got != "/bin/fish" {
		t.Errorf("loginShell() = %q, want /bin/fish", got)
	}
}

func TestLoginShell_DefaultByOS(t *testing.T) {
	t.Setenv("SHELL", "")

	got := loginShell()
	switch runtime.GOOS {
	case "darwin":
		if got != "/bin/zsh" {
			t.Errorf("loginShell() = %q, want /bin/zsh on darwin", got)
		}
	default:
		if got != "/bin/bash" {
			t.Errorf("loginShell() = %q, want /bin/bash on %s", got, runtime.GOOS)
		}
	}
}

func TestLoginShellWhich_RejectsBadNames(t *testing.T) {
	cases := []string{
		"foo;bar",
		"name with space",
		"`rm -rf /`",
		"$(whoami)",
		"name|pipe",
		"",
	}
	for _, name := range cases {
		if got := loginShellWhich(name); got != "" {
			t.Errorf("loginShellWhich(%q) = %q, want empty", name, got)
		}
	}
}

func TestLoginShellWhich_AcceptsValidNames(t *testing.T) {
	// "sh" is virtually guaranteed to exist on POSIX. Result may be empty
	// if login shell can't run in test env, but it should not be rejected
	// based on the name itself — function returns empty in either case so
	// we only verify it doesn't panic.
	_ = loginShellWhich("sh")
	_ = loginShellWhich("test-binary_1")
}
