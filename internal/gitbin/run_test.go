package gitbin

import (
	"context"
	"errors"
	"os/exec"
	"strings"
	"testing"
)

// Exec drops the inherited repository variables, keeps the process
// non-interactive, feeds stdin, and hands back stdout and trimmed stderr
// apart, with the exit code in an *exec.ExitError.
func TestExec_EnvironmentStdinAndExitCode(t *testing.T) {
	for _, key := range repositoryEnv {
		t.Setenv(key, "/elsewhere")
	}
	t.Setenv("WT_KEPT", "kept")
	script := `for k in ` + strings.Join(repositoryEnv, " ") + `; do eval "v=\${$k-unset}"; printf '%s|' "$v"; done; ` +
		`printf '%s|%s|%s|%s|%s|%s|' "$WT_KEPT" "$GIT_OPTIONAL_LOCKS" "$GIT_TERMINAL_PROMPT" "$GIT_EDITOR" "$GH_PROMPT_DISABLED" "$LC_ALL"; cat; echo '  oops  ' >&2; exit 3`
	out, stderr, err := Exec(context.Background(), t.TempDir(), []byte("in"), "/bin/sh", "-c", script)
	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) || exitErr.ExitCode() != 3 {
		t.Fatalf("want exit 3, got %v", err)
	}
	if got, want := string(out), strings.Repeat("unset|", len(repositoryEnv))+"kept|0|0|true|1|C|in"; got != want {
		t.Fatalf("stdout = %q, want %q", got, want)
	}
	if got := string(stderr); got != "oops" {
		t.Fatalf("stderr = %q, want trimmed %q", got, "oops")
	}
	if _, _, err := Exec(context.Background(), t.TempDir(), nil, "/bin/sh", "-c", "exit 0"); err != nil {
		t.Fatalf("clean run: %v", err)
	}
	if _, _, err := Exec(context.Background(), t.TempDir(), nil, "/nonexistent/git"); err == nil || strings.Contains(err.Error(), "exit status") {
		t.Fatalf("a binary that cannot start is not an exit status: %v", err)
	}
	// A tool missing from PATH stays exec.ErrNotFound (the check's "gh CLI
	// not found" note depends on it).
	if _, _, err := Exec(context.Background(), t.TempDir(), nil, "wt-no-such-binary"); !errors.Is(err, exec.ErrNotFound) {
		t.Fatalf("a missing tool must be exec.ErrNotFound, got %v", err)
	}
}
