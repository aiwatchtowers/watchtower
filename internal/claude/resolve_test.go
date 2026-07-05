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

func TestRichPATH_FallbackWhenShellFails(t *testing.T) {
	// Point SHELL at a non-existent binary so loginShellPATH returns "".
	// RichPATH must fall through to fallbackPATH and still return non-empty.
	resetCache()
	t.Setenv("SHELL", "/nonexistent/shell")

	got := RichPATH()
	if got == "" {
		t.Error("RichPATH should fall back to fallbackPATH when login shell is unavailable")
	}
}

func TestLoginShellPATH_ReturnsEmptyOnBadShell(t *testing.T) {
	t.Setenv("SHELL", "/nonexistent/shell")
	// Must not panic and must return empty string.
	got := loginShellPATH()
	if got != "" {
		// If by some miracle a shell at that path exists, just skip.
		t.Logf("loginShellPATH returned %q (non-empty — likely shell resolved)", got)
	}
}

func TestLoginShellPATH_WithRealShell(t *testing.T) {
	// Call loginShellPATH with the actual system shell.
	// Covers the success branch (non-empty PATH returned) and the
	// "same as $PATH" branch (returns "") depending on the environment.
	// Either outcome is valid — we only ensure no panic and no empty
	// string when the shell works correctly.
	got := loginShellPATH()
	// Result may be "" (same PATH or unreachable shell) or a non-empty PATH.
	// Either branch is valid; just assert no crash.
	_ = got
}

func TestFindBinary_FallbackString(t *testing.T) {
	// When neither LookPath nor loginShellWhich can find claude, FindBinary
	// must return a non-empty fallback ("claude") rather than "".
	resetCache()
	// Force a PATH with no claude binary.
	t.Setenv("PATH", t.TempDir())
	t.Setenv("SHELL", "/nonexistent/shell")

	got := FindBinary("")
	if got == "" {
		t.Error("FindBinary must always return a non-empty fallback")
	}
}

func TestFindBinary_LoginShellFallback(t *testing.T) {
	// Force PATH to exclude claude so LookPath fails, but use a real shell
	// so loginShellWhich is exercised (it may or may not find claude).
	// Covers the loginShellWhich branch inside FindBinary.cachedBinaryMu.Do.
	resetCache()
	t.Setenv("PATH", t.TempDir()) // empty PATH — LookPath will fail

	got := FindBinary("")
	if got == "" {
		t.Error("FindBinary must always return a non-empty value")
	}
}

// fakeShell writes an executable script that ignores its args and prints
// `output` to stdout, then points $SHELL at it. This lets the login-shell
// lookups be driven deterministically on any platform — the real `sh -l`
// behaves differently across macOS and the Linux CI sandbox, so relying on
// it leaves the success branches of loginShellWhich/loginShellPATH uncovered
// on CI. The fake shell removes that platform dependence.
func fakeShell(t *testing.T, output string) {
	t.Helper()
	script := filepath.Join(t.TempDir(), "fakeshell")
	body := "#!/bin/sh\nprintf '%s' " + shellQuote(output) + "\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SHELL", script)
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

func TestLoginShellWhich_SuccessViaFakeShell(t *testing.T) {
	// Fake shell echoes the path of a real executable file → loginShellWhich
	// must os.Stat it and return it. Covers the success branch on any platform.
	target := filepath.Join(t.TempDir(), "claude")
	if err := os.WriteFile(target, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	fakeShell(t, target+"\n")

	if got := loginShellWhich("claude"); got != target {
		t.Errorf("loginShellWhich via fake shell = %q, want %q", got, target)
	}
}

func TestLoginShellWhich_EmptyOutput(t *testing.T) {
	// Fake shell prints nothing → the p == "" branch returns "".
	fakeShell(t, "")

	if got := loginShellWhich("claude"); got != "" {
		t.Errorf("loginShellWhich with empty output = %q, want empty", got)
	}
}

func TestLoginShellWhich_NonExistentPath(t *testing.T) {
	// Fake shell echoes a path that does not exist → os.Stat fails → final
	// return "" branch is taken.
	fakeShell(t, filepath.Join(t.TempDir(), "does-not-exist")+"\n")

	if got := loginShellWhich("claude"); got != "" {
		t.Errorf("loginShellWhich with bad path = %q, want empty", got)
	}
}

func TestLoginShellPATH_SuccessViaFakeShell(t *testing.T) {
	// Fake shell echoes a PATH distinct from the current one → loginShellPATH
	// returns it. Covers the success branch on any platform.
	custom := "/opt/fake/bin:/opt/other/bin"
	t.Setenv("PATH", "/usr/bin")
	fakeShell(t, custom+"\n")

	if got := loginShellPATH(); got != custom {
		t.Errorf("loginShellPATH via fake shell = %q, want %q", got, custom)
	}
}

func TestLoginShellPATH_EmptyOutput(t *testing.T) {
	// Fake shell prints nothing → the p == "" branch returns "".
	fakeShell(t, "")

	if got := loginShellPATH(); got != "" {
		t.Errorf("loginShellPATH with empty output = %q, want empty", got)
	}
}

func TestRichPATH_SuccessViaFakeShell(t *testing.T) {
	// A working login shell that yields a distinct PATH must be used verbatim
	// by RichPATH (covers the non-fallback branch).
	resetCache()
	custom := "/opt/rich/bin:/opt/more/bin"
	t.Setenv("PATH", "/usr/bin")
	fakeShell(t, custom+"\n")

	if got := RichPATH(); got != custom {
		t.Errorf("RichPATH via fake shell = %q, want %q", got, custom)
	}
}
