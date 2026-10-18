package gitbin

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
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

// plantedFilterRepo is a repository whose own config names a filter driver
// (and an lfs extension) for a file edited to the same size since its
// commit — only hashing the content, the clean filter's moment, tells — and
// whose owner's global config names the lfs driver. marker appears when the
// planted driver runs.
func plantedFilterRepo(t *testing.T, bin string) (dir, marker string) {
	t.Helper()
	global := filepath.Join(t.TempDir(), "gitconfig")
	mustNoErr(t, os.WriteFile(global, []byte("[filter \"lfs\"]\n\tclean = git-lfs clean -- %f\n"), 0o644))
	t.Setenv("GIT_CONFIG_GLOBAL", global)
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	dir = t.TempDir()
	mustGit(t, bin, dir, "init", "-q")
	mustNoErr(t, os.WriteFile(filepath.Join(dir, "a.txt"), []byte("a\n"), 0o644))
	mustGit(t, bin, dir, "add", "a.txt")
	mustGit(t, bin, dir, "-c", "user.email=a@example.com", "-c", "user.name=a", "commit", "-qm", "i")
	marker = plantFilter(t, bin, dir)
	mustGit(t, bin, dir, "config", "lfs.extension.planted.clean", "planted %f")
	mustNoErr(t, os.WriteFile(filepath.Join(dir, "a.txt"), []byte("b\n"), 0o644))
	return dir, marker
}

// mustNoErr fails the test on err.
func mustNoErr(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

// mustGit runs git in dir and fails the test on an error.
func mustGit(t *testing.T, bin, dir string, args ...string) {
	t.Helper()
	if _, stderr, err := Exec(context.Background(), dir, nil, bin, args...); err != nil {
		t.Fatalf("git %v: %v %s", args, err, stderr)
	}
}

// A read through ReadArgsIn runs no filter driver the folder's config names
// (clean, process; `required` lifted so the read still answers), while a
// driver from the owner's global config is left alone.
func TestReadArgsIn_BlanksTheFoldersFilterDrivers(t *testing.T) {
	bin, ok := Locate()
	if !ok {
		t.Skip("no git")
	}
	dir, marker := plantedFilterRepo(t, bin)

	argv, err := ReadArgsIn(context.Background(), bin, dir, "status", "--porcelain")
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(argv, " ")
	for _, want := range []string{
		"-c filter.planted.clean=", "-c filter.planted.process=", "-c filter.planted.required=false",
		"-c lfs.extension.planted.clean=",
	} {
		if !strings.Contains(joined, want) {
			t.Errorf("argv %q lacks %q", joined, want)
		}
	}
	if strings.Contains(joined, "filter.lfs") || strings.Contains(joined, "lfs.extension.planted.required") {
		t.Errorf("argv %q blanks the owner's global lfs driver or lifts an extension", joined)
	}
	if !strings.HasSuffix(joined, " status --porcelain") {
		t.Errorf("argv %q does not end with the subcommand", joined)
	}
	for _, args := range [][]string{{"status", "--porcelain"}, {"diff", "--stat"}, {"ls-files", "-z", "--cached", "--others", "--modified"}} {
		read, err := ReadArgsIn(context.Background(), bin, dir, args...)
		if err != nil {
			t.Fatal(err)
		}
		mustGit(t, bin, dir, read...)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("a filter driver from the folder's config ran")
	}

	// A subcommand that reads no file content lists nothing.
	plain, err := ReadArgsIn(context.Background(), bin, dir, "rev-parse", "HEAD")
	if err != nil {
		t.Fatal(err)
	}
	if got, want := strings.Join(plain, " "), strings.Join(ReadArgs("rev-parse", "HEAD"), " "); got != want {
		t.Errorf("rev-parse argv = %q, want %q", got, want)
	}
}

func TestReadsContent(t *testing.T) {
	for args, want := range map[string]bool{
		"status --porcelain": true, "ls-files -z": true, "check-ignore --stdin": true, "diff a b": true,
		"log -p a..b": true, "log -1 --format=%ct": false, "rev-parse HEAD": false, "branch --list": false,
		"remote get-url origin": false, "": false,
	} {
		if got := readsContent(strings.Fields(args)); got != want {
			t.Errorf("readsContent(%q) = %v, want %v", args, got, want)
		}
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

func TestReadsContent_AddAndPatchDiffTree(t *testing.T) {
	for _, tc := range []struct {
		args []string
		want bool
	}{
		{[]string{"add", "-A"}, true},
		{[]string{"write-tree"}, true},
		{[]string{"diff-tree", "-r", "-p", "a", "b"}, true},
		{[]string{"diff-tree", "-r", "--name-status", "a", "b"}, false},
		{[]string{"read-tree", "HEAD"}, false},
	} {
		if got := readsContent(tc.args); got != tc.want {
			t.Errorf("readsContent(%v) = %v, want %v", tc.args, got, tc.want)
		}
	}
}

// apply reads and writes work-tree files and hash-object hashes one, both
// through the folder's filter drivers (REVIEW-05).
func TestReadsContent_ApplyAndHashObject(t *testing.T) {
	for _, args := range [][]string{{"apply", "--check", "-R", "p"}, {"apply", "-R", "p"}, {"hash-object", "--", "a"}} {
		if !readsContent(args) {
			t.Errorf("readsContent(%v) = false, want true", args)
		}
	}
}

func TestExecEnv_KeepsCallerIndexDropsInherited(t *testing.T) {
	t.Setenv("GIT_INDEX_FILE", "/inherited/index")
	out, _, err := ExecEnv(context.Background(), t.TempDir(), []string{"GIT_INDEX_FILE=/caller/index"}, nil,
		"/bin/sh", "-c", `printf %s "$GIT_INDEX_FILE"`)
	if err != nil {
		t.Fatal(err)
	}
	if string(out) != "/caller/index" {
		t.Fatalf("GIT_INDEX_FILE = %q, want the caller's", out)
	}
	out, _, err = Exec(context.Background(), t.TempDir(), nil, "/bin/sh", "-c", `printf %s "${GIT_INDEX_FILE-unset}"`)
	if err != nil {
		t.Fatal(err)
	}
	if string(out) != "unset" {
		t.Fatalf("Exec leaked the inherited GIT_INDEX_FILE: %q", out)
	}
}

// ExecFetch keeps the network side of a fetch from asking anyone, on top of
// Exec's environment, and FetchArgs clears every credential helper.
func TestExecFetch_NoPromptEnvironment(t *testing.T) {
	t.Setenv("GIT_ASKPASS", "/inherited/askpass")
	t.Setenv("SSH_ASKPASS", "/inherited/askpass")
	t.Setenv("GIT_DIR", "/elsewhere")
	script := `printf '%s|%s|%s|%s|%s|%s|%s|%s' "$GIT_SSH_COMMAND" "${GIT_ASKPASS-unset}" "${SSH_ASKPASS-unset}" ` +
		`"$SSH_ASKPASS_REQUIRE" "${GIT_PROXY_COMMAND-unset}" "$GIT_ALLOW_PROTOCOL" "$GIT_TERMINAL_PROMPT" "${GIT_DIR-unset}"`
	out, _, err := ExecFetch(context.Background(), t.TempDir(), "/bin/sh", "-c", script)
	if err != nil {
		t.Fatal(err)
	}
	want := "ssh -o BatchMode=yes -o ConnectTimeout=10|||never||file:git:http:https:ssh|0|unset"
	if got := string(out); got != want {
		t.Fatalf("env = %q, want %q", got, want)
	}
	args := FetchArgs("fetch", "origin")
	if got := strings.Join(args, " "); !strings.Contains(got, "-c credential.helper= ") || !strings.HasSuffix(got, " fetch origin") {
		t.Fatalf("FetchArgs = %q", got)
	}
}

// A fetch cut off by its context is killed with its whole process group:
// a child it started does not outlive it.
func TestExecFetch_KillsTheProcessGroup(t *testing.T) {
	pidFile := filepath.Join(t.TempDir(), "child")
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	_, _, err := ExecFetch(ctx, t.TempDir(), "/bin/sh", "-c", `sleep 30 & echo $! > '`+pidFile+`'; wait`)
	if err == nil {
		t.Fatal("want the cut-off run to fail")
	}
	b, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = syscall.Kill(pid, syscall.SIGKILL) })
	deadline := time.Now().Add(2 * time.Second)
	for syscall.Kill(pid, 0) == nil {
		if time.Now().After(deadline) {
			t.Fatalf("child %d outlived the fetch", pid)
		}
		time.Sleep(20 * time.Millisecond)
	}
}
