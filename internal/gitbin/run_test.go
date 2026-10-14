package gitbin

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
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

// plantFilter makes every *.txt of the repository at dir go through a
// filter driver named in its own config whose commands leave a marker
// file; it returns the marker's path. A filter driver is a command a
// background status or ls-files would otherwise run.
func plantFilter(t *testing.T, bin, dir string) string {
	t.Helper()
	marker := filepath.Join(t.TempDir(), "filter-ran")
	script := filepath.Join(t.TempDir(), "planted")
	if err := os.WriteFile(script, []byte("#!/bin/sh\ntouch '"+marker+"'\ncat\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, kv := range [][2]string{{"filter.planted.clean", script}, {"filter.planted.process", script}, {"filter.planted.required", "true"}} {
		if out, _, err := Exec(context.Background(), dir, nil, bin, "config", kv[0], kv[1]); err != nil {
			t.Fatalf("git config %s: %v %s", kv[0], err, out)
		}
	}
	if err := os.WriteFile(filepath.Join(dir, ".gitattributes"), []byte("*.txt filter=planted\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return marker
}

// A read through ReadArgsIn runs no filter driver the folder's config names
// (clean, process; `required` lifted so the read still answers), while a
// driver from the owner's global config is left alone.
func TestReadArgsIn_BlanksTheFoldersFilterDrivers(t *testing.T) {
	bin, ok := Locate()
	if !ok {
		t.Skip("no git")
	}
	global := filepath.Join(t.TempDir(), "gitconfig")
	if err := os.WriteFile(global, []byte("[filter \"lfs\"]\n\tclean = git-lfs clean -- %f\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("GIT_CONFIG_GLOBAL", global)
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	dir := t.TempDir()
	if _, stderr, err := Exec(context.Background(), dir, nil, bin, "init", "-q"); err != nil {
		t.Fatalf("git init: %v %s", err, stderr)
	}
	marker := plantFilter(t, bin, dir)
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("a\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	argv, err := ReadArgsIn(context.Background(), bin, dir, "status", "--porcelain")
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(argv, " ")
	for _, want := range []string{"-c filter.planted.clean=", "-c filter.planted.process=", "-c filter.planted.required=false"} {
		if !strings.Contains(joined, want) {
			t.Errorf("argv %q lacks %q", joined, want)
		}
	}
	if strings.Contains(joined, "filter.lfs") {
		t.Errorf("the owner's global lfs driver was blanked: %q", joined)
	}
	if !strings.HasSuffix(joined, " status --porcelain") {
		t.Errorf("argv %q does not end with the subcommand", joined)
	}
	// add stages the file: the clean filter's moment.
	for _, args := range [][]string{{"add", "a.txt"}, {"status", "--porcelain"}, {"ls-files", "-z", "--cached", "--others"}} {
		read, err := ReadArgsIn(context.Background(), bin, dir, args...)
		if err != nil {
			t.Fatal(err)
		}
		if _, stderr, err := Exec(context.Background(), dir, nil, bin, read...); err != nil {
			t.Fatalf("git %v: %v %s", args, err, stderr)
		}
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("a filter driver from the folder's config ran")
	}
}

// No filter configured: ReadArgsIn is ReadArgs.
func TestReadArgsIn_NoFilterIsReadArgs(t *testing.T) {
	bin, ok := Locate()
	if !ok {
		t.Skip("no git")
	}
	t.Setenv("GIT_CONFIG_GLOBAL", "/dev/null")
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	dir := t.TempDir()
	if _, stderr, err := Exec(context.Background(), dir, nil, bin, "init", "-q"); err != nil {
		t.Fatalf("git init: %v %s", err, stderr)
	}
	argv, err := ReadArgsIn(context.Background(), bin, dir, "status")
	if err != nil {
		t.Fatal(err)
	}
	if got, want := strings.Join(argv, " "), strings.Join(ReadArgs("status"), " "); got != want {
		t.Fatalf("argv = %q, want %q", got, want)
	}
}
