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
	t.Setenv("GIT_DIR", "/elsewhere/.git")
	t.Setenv("GIT_WORK_TREE", "/elsewhere")
	script := `printf '%s|%s|%s|%s|%s|%s|' "${GIT_DIR-unset}" "${GIT_WORK_TREE-unset}" "$GIT_OPTIONAL_LOCKS" "$GIT_TERMINAL_PROMPT" "$GIT_EDITOR" "$LC_ALL"; cat; echo '  oops  ' >&2; exit 3`
	out, stderr, err := Exec(context.Background(), t.TempDir(), []byte("in"), "/bin/sh", "-c", script)
	var exitErr *exec.ExitError
	if !errors.As(err, &exitErr) || exitErr.ExitCode() != 3 {
		t.Fatalf("want exit 3, got %v", err)
	}
	if got, want := string(out), "unset|unset|0|0|true|C|in"; got != want {
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
}
