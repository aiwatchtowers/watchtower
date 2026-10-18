package gittest

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// TestDisableBackgroundGit_AppendsAndGitSeesIt checks that an entry already
// in GIT_CONFIG_COUNT survives and that git reads the added keys, and that
// core.fsmonitor is not among them.
func TestDisableBackgroundGit_AppendsAndGitSeesIt(t *testing.T) {
	bin, err := exec.LookPath("git")
	if err != nil {
		t.Skip("git is not available")
	}
	t.Setenv("GIT_CONFIG_COUNT", "1")
	t.Setenv("GIT_CONFIG_KEY_0", "core.splitIndex")
	t.Setenv("GIT_CONFIG_VALUE_0", "false")
	t.Setenv("GIT_TEMPLATE_DIR", "")
	// t.Setenv restores the keys DisableBackgroundGit writes.
	for i := range len(quietConfig) {
		n := strconv.Itoa(i + 1)
		t.Setenv("GIT_CONFIG_KEY_"+n, "")
		t.Setenv("GIT_CONFIG_VALUE_"+n, "")
	}
	DisableBackgroundGit()

	want := map[string]string{
		"core.splitindex":        "false",
		"maintenance.auto":       "false",
		"gc.auto":                "0",
		"gc.autodetach":          "false",
		"maintenance.autodetach": "false",
	}
	out, err := exec.Command(bin, "config", "--list", "--show-scope").Output()
	if err != nil {
		t.Fatalf("git config --list: %v", err)
	}
	got := map[string]string{}
	for line := range strings.SplitSeq(strings.TrimSpace(string(out)), "\n") {
		scope, kv, _ := strings.Cut(line, "\t")
		if scope != "command" {
			continue
		}
		k, v, _ := strings.Cut(kv, "=")
		got[k] = v
	}
	if v, ok := got["core.fsmonitor"]; ok {
		t.Errorf("git sees core.fsmonitor=%q in the command scope: it would mask a repository's planted fsmonitor", v)
	}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("git sees %s=%q in the command scope, want %q (all: %v)", k, got[k], v, got)
		}
	}
}

// TestDisableBackgroundGit_ReachesAPushedToBareRepository: a local push
// runs receive-pack with GIT_CONFIG_COUNT stripped (git's local_repo_env),
// so the environment config never reaches the bare remote, whose
// receive.autogc then starts a detached gc/maintenance writing into it
// while t.TempDir's cleanup removes it (#684). The remote's own config must
// carry the quiet keys: a pre-receive hook reports what receive-pack sees.
func TestDisableBackgroundGit_ReachesAPushedToBareRepository(t *testing.T) {
	bin, err := exec.LookPath("git")
	if err != nil {
		t.Skip("git is not available")
	}
	// t.Setenv restores everything DisableBackgroundGit writes.
	for _, k := range []string{"GIT_CONFIG_COUNT", "GIT_TEMPLATE_DIR"} {
		t.Setenv(k, "")
	}
	for i := range len(quietConfig) {
		n := strconv.Itoa(i)
		t.Setenv("GIT_CONFIG_KEY_"+n, "")
		t.Setenv("GIT_CONFIG_VALUE_"+n, "")
	}
	for k, v := range map[string]string{
		"GIT_CONFIG_GLOBAL": os.DevNull, "GIT_CONFIG_NOSYSTEM": "1",
		"GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
		"GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
	} {
		t.Setenv(k, v)
	}
	DisableBackgroundGit()

	base := t.TempDir()
	run := func(dir string, args ...string) {
		t.Helper()
		c := exec.Command(bin, args...)
		c.Dir = dir
		if out, err := c.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	run(base, "init", "-q", "--bare", "-b", "main", "remote.git")
	run(base, "init", "-q", "-b", "main", "repo")
	repo := filepath.Join(base, "repo")
	if err := os.WriteFile(filepath.Join(repo, "a.txt"), []byte("a\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	run(repo, "add", "a.txt")
	run(repo, "commit", "-q", "-m", "a")
	seen := filepath.Join(base, "seen")
	hook := "#!/bin/sh\nfor k in receive.autogc gc.auto maintenance.auto gc.autodetach maintenance.autodetach; do\n" +
		"  echo \"$k=$(git config --get $k)\" >> '" + seen + "'\ndone\n"
	hooks := filepath.Join(base, "remote.git", "hooks")
	if err := os.MkdirAll(hooks, 0o750); err != nil {
		t.Fatal(err)
	}
	// #nosec G306 -- a test hook must be executable.
	if err := os.WriteFile(filepath.Join(hooks, "pre-receive"), []byte(hook), 0o700); err != nil {
		t.Fatal(err)
	}
	run(repo, "push", "-q", filepath.Join(base, "remote.git"), "main")

	out, err := os.ReadFile(seen) // #nosec G304 -- the hook's output file under t.TempDir.
	if err != nil {
		t.Fatalf("the pre-receive hook did not run: %v", err)
	}
	got := strings.Join(strings.Fields(string(out)), " ")
	want := "receive.autogc=false gc.auto=0 maintenance.auto=false gc.autodetach=false maintenance.autodetach=false"
	if got != want {
		t.Errorf("receive-pack in the bare remote sees %q, want %q", got, want)
	}
}
