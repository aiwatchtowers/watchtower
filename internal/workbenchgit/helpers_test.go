package workbenchgit

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"watchtower/internal/gitbin"
)

// gitBin is the located git, or the test is skipped. The environment keeps
// the owner's own git configuration out of the test repositories.
func gitBin(t *testing.T) string {
	t.Helper()
	bin, ok := gitbin.Locate()
	if !ok {
		t.Skip("git is not available")
	}
	for k, v := range map[string]string{
		"GIT_CONFIG_GLOBAL": os.DevNull, "GIT_CONFIG_NOSYSTEM": "1",
		"GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
		"GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
	} {
		t.Setenv(k, v)
	}
	return bin
}

// gitIn runs git in dir for the test's own setup and returns its trimmed
// stdout.
func gitIn(t *testing.T, dir string, args ...string) string {
	t.Helper()
	c := exec.Command(gitBin(t), args...)
	c.Dir = dir
	out, err := c.Output()
	if err != nil {
		stderr := ""
		if ee, ok := err.(*exec.ExitError); ok {
			stderr = string(ee.Stderr)
		}
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, stderr)
	}
	return strings.TrimSpace(string(out))
}

func writeFile(t *testing.T, dir, name, content string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func readFile(t *testing.T, dir, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func commit(t *testing.T, dir, name, content, msg string) {
	t.Helper()
	writeFile(t, dir, name, content)
	gitIn(t, dir, "add", name)
	gitIn(t, dir, "commit", "-q", "-m", msg)
}

// newRepo is a repository on main with one commit and a branch "feature"
// holding one more; its path has symlinks resolved, as git prints it.
func newRepo(t *testing.T) string {
	t.Helper()
	gitBin(t)
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	gitIn(t, dir, "init", "-q", "-b", "main")
	commit(t, dir, "README.md", "hello\n", "init")
	gitIn(t, dir, "switch", "-q", "-c", "feature")
	commit(t, dir, "feature.txt", "feature\n", "feature")
	gitIn(t, dir, "switch", "-q", "main")
	return dir
}

// recorder wraps the real runner and records every git argv; fail makes a
// call whose first argument matches fail without running.
type recorder struct {
	mu    sync.Mutex
	calls [][]string
	fail  string
}

func (r *recorder) run(ctx context.Context, dir string, stdin []byte, name string, args ...string) ([]byte, int, error) {
	r.mu.Lock()
	r.calls = append(r.calls, append([]string(nil), args...))
	r.mu.Unlock()
	if r.fail != "" && len(args) > 0 && args[0] == r.fail {
		return nil, 128, &runError{args: args, err: os.ErrInvalid, stderr: "fatal: simulated " + r.fail + " failure"}
	}
	return execRunner(ctx, dir, stdin, name, args...)
}

func (r *recorder) argv() [][]string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([][]string(nil), r.calls...)
}

// ran reports whether a call with this first argument was recorded.
func (r *recorder) ran(sub string) bool {
	for _, c := range r.argv() {
		if len(c) > 0 && c[0] == sub {
			return true
		}
	}
	return false
}

func options(dir string, r *recorder) Options {
	return Options{Folder: dir, Run: r.run}
}

func sameDir(t *testing.T, a, b string) bool {
	t.Helper()
	ra, errA := filepath.EvalSymlinks(a)
	rb, errB := filepath.EvalSymlinks(b)
	return errA == nil && errB == nil && ra == rb
}
