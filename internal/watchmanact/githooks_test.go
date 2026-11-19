package watchmanact

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// hookRepo is a working repository with a bare remote whose main has one
// commit, and a Watchman workspace.
type hookRepo struct {
	root, remote, work, ws string
}

// isolateGit keeps the developer's global and system git config (a global
// core.hooksPath, a template) out of the test, and gives commits an author.
func isolateGit(t *testing.T) {
	t.Helper()
	t.Setenv("GIT_CONFIG_GLOBAL", filepath.Join(t.TempDir(), "gitconfig"))
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	for _, k := range []string{"GIT_AUTHOR", "GIT_COMMITTER"} {
		t.Setenv(k+"_NAME", "Acme Dev")
		t.Setenv(k+"_EMAIL", "dev@example.com")
	}
}

func newHookRepo(t *testing.T) hookRepo {
	t.Helper()
	isolateGit(t)
	root := t.TempDir()
	r := hookRepo{root: root, remote: filepath.Join(root, "remote.git"), work: filepath.Join(root, "work"), ws: filepath.Join(root, "ws")}
	gitT(t, root, "init", "-q", "--bare", "-b", "main", r.remote)
	gitT(t, root, "init", "-q", "-b", "main", r.work)
	gitT(t, r.work, "commit", "-q", "--allow-empty", "-m", "init")
	gitT(t, r.work, "remote", "add", "origin", r.remote)
	gitT(t, r.work, "push", "-q", "origin", "main")
	return r
}

// gitT runs git in dir and returns its trimmed stdout; a failure fails the test.
func gitT(t *testing.T, dir string, args ...string) string {
	t.Helper()
	out, err := gitOut(dir, args...)
	require.NoError(t, err, "git %v: %s", args, out)
	return strings.TrimSpace(out)
}

// gitOut runs git in dir and returns its combined output.
func gitOut(dir string, args ...string) (string, error) {
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// arm writes the sidecar with the given worktrees armed.
func (r hookRepo) arm(t *testing.T, worktrees ...string) {
	t.Helper()
	var sessions []db.ArmedSession
	for i, wt := range worktrees {
		sessions = append(sessions, db.ArmedSession{SessionID: int64(i + 1), WorkbenchID: 1, Folder: wt})
	}
	require.NoError(t, WriteSidecar(SidecarPath(r.ws), sessions, false))
}

func (r hookRepo) remoteRef(t *testing.T, ref string) string {
	t.Helper()
	out, err := gitOut(r.remote, "rev-parse", "--verify", "-q", ref)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(out)
}

// writeHook writes an executable hook script into dir.
func writeHook(t *testing.T, dir, name, body string) {
	t.Helper()
	require.NoError(t, os.MkdirAll(dir, 0o755))
	require.NoError(t, os.WriteFile(filepath.Join(dir, name), []byte("#!/bin/sh\n"+body), 0o755)) // #nosec G306 -- a test hook must be executable
}

func TestPrePush_RefusesMainFromNestedScript(t *testing.T) {
	if _, err := exec.LookPath("make"); err != nil {
		t.Skip("make is not installed: ", err)
	}
	r := newHookRepo(t)
	require.NoError(t, EnsureHooks(context.Background(), r.work, r.ws))
	r.arm(t, r.work)
	before := r.remoteRef(t, "refs/heads/main")
	gitT(t, r.work, "commit", "-q", "--allow-empty", "-m", "agent work")

	require.NoError(t, os.WriteFile(filepath.Join(r.work, "M"), []byte("push:\n\tgit push origin HEAD:main\n"), 0o600))
	require.NoError(t, os.WriteFile(filepath.Join(r.work, "push.sh"), []byte("make -f M push\n"), 0o600))
	cmd := exec.Command("sh", "push.sh")
	cmd.Dir = r.work
	out, err := cmd.CombinedOutput()
	require.Error(t, err, "the push went through: %s", out)
	assert.Contains(t, string(out), "Parked for the owner: a push to main")
	assert.Equal(t, before, r.remoteRef(t, "refs/heads/main"), "the remote's main moved")
}

func TestPrePush_RefusesTagDeleteAndNonFastForward(t *testing.T) {
	r := newHookRepo(t)
	require.NoError(t, EnsureHooks(context.Background(), r.work, r.ws))
	r.arm(t, r.work)
	gitT(t, r.work, "checkout", "-q", "-b", "feature/x")
	gitT(t, r.work, "commit", "-q", "--allow-empty", "-m", "one")
	gitT(t, r.work, "push", "-q", "origin", "feature/x") // a feature branch is fine
	pushed := r.remoteRef(t, "refs/heads/feature/x")
	require.NotEmpty(t, pushed)

	cases := []struct {
		name string
		args []string
		why  string
	}{
		{"master", []string{"push", "origin", "HEAD:master"}, "a push to master"},
		{"tag", []string{"push", "origin", "v1"}, "a tag push (refs/tags/v1)"},
		{"delete", []string{"push", "origin", ":feature/x"}, "deleting refs/heads/feature/x"},
		{"non-fast-forward", []string{"push", "-f", "origin", "feature/x"}, "a non-fast-forward push to refs/heads/feature/x"},
	}
	gitT(t, r.work, "tag", "v1")
	gitT(t, r.work, "commit", "-q", "--amend", "--allow-empty", "-m", "one, rewritten")
	for _, c := range cases {
		out, err := gitOut(r.work, c.args...)
		require.Error(t, err, "%s went through: %s", c.name, out)
		assert.Contains(t, out, "Parked for the owner: "+c.why, c.name)
	}
	assert.Equal(t, pushed, r.remoteRef(t, "refs/heads/feature/x"))
	assert.Empty(t, r.remoteRef(t, "refs/heads/master"))
	assert.Empty(t, r.remoteRef(t, "refs/tags/v1"))
}

func TestPrePush_AllowsFeatureBranchAndChainsPrevious(t *testing.T) {
	r := newHookRepo(t)
	got := filepath.Join(r.root, "pre-push.out")
	// The repository's own hooks path, relative as scripts/git-hooks is.
	gitT(t, r.work, "config", "core.hooksPath", "repo-hooks")
	writeHook(t, filepath.Join(r.work, "repo-hooks"), "pre-push", `{ echo "args: $*"; cat; } > '`+got+"'\nexit ${PREV_EXIT:-0}\n")
	require.NoError(t, EnsureHooks(context.Background(), r.work, r.ws))
	r.arm(t, r.work)

	gitT(t, r.work, "checkout", "-q", "-b", "feature/x")
	gitT(t, r.work, "commit", "-q", "--allow-empty", "-m", "one")
	sha := gitT(t, r.work, "rev-parse", "HEAD")
	gitT(t, r.work, "push", "-q", "origin", "feature/x")
	assert.Equal(t, sha, r.remoteRef(t, "refs/heads/feature/x"))
	raw, err := os.ReadFile(got)
	require.NoError(t, err, "the previous pre-push did not run")
	zero := strings.Repeat("0", len(sha))
	assert.Equal(t, "args: origin "+r.remote+"\nrefs/heads/feature/x "+sha+" refs/heads/feature/x "+zero+"\n", string(raw))

	// The previous hook's failure fails the push.
	t.Setenv("PREV_EXIT", "1")
	gitT(t, r.work, "commit", "-q", "--allow-empty", "-m", "two")
	out, err := gitOut(r.work, "push", "origin", "feature/x")
	require.Error(t, err, "pushed past a failing previous hook: %s", out)
	assert.Equal(t, sha, r.remoteRef(t, "refs/heads/feature/x"))
}

func TestPrePush_UnarmedPassesThrough(t *testing.T) {
	r := newHookRepo(t)
	ran := filepath.Join(r.root, "ran")
	writeHook(t, filepath.Join(r.work, ".git", "hooks"), "pre-push", "cat > /dev/null; touch '"+ran+"'\n")
	require.NoError(t, EnsureHooks(context.Background(), r.work, r.ws))
	r.arm(t, filepath.Join(r.root, "some-other-worktree"))

	gitT(t, r.work, "commit", "-q", "--allow-empty", "-m", "owner work")
	sha := gitT(t, r.work, "rev-parse", "HEAD")
	gitT(t, r.work, "push", "-q", "origin", "HEAD:main")
	assert.Equal(t, sha, r.remoteRef(t, "refs/heads/main"))
	assert.FileExists(t, ran, "the previous pre-push did not run")
}

func TestHooks_ProxyReturnsExitCode(t *testing.T) {
	r := newHookRepo(t)
	prev := filepath.Join(r.root, "owner-hooks")
	writeHook(t, prev, "commit-msg", "grep -q allowed \"$1\"\n")
	gitT(t, r.work, "config", "core.hooksPath", prev)
	require.NoError(t, EnsureHooks(context.Background(), r.work, r.ws))

	out, err := gitOut(r.work, "commit", "--allow-empty", "-m", "nope")
	require.Error(t, err, "the commit-msg hook's exit 1 did not fail the commit: %s", out)
	gitT(t, r.work, "commit", "-q", "--allow-empty", "-m", "allowed")
}

func TestHooks_MissingPreviousExitsZero(t *testing.T) {
	r := newHookRepo(t)
	require.NoError(t, EnsureHooks(context.Background(), r.work, r.ws))
	gitT(t, r.work, "checkout", "-q", "-b", "feature/y")
	gitT(t, r.work, "commit", "-q", "--allow-empty", "-m", "no hooks anywhere")
	gitT(t, r.work, "push", "-q", "origin", "feature/y") // unarmed: pre-push too

	for _, name := range ClientHookNames {
		if name == "push-to-checkout" {
			continue // without a previous hook it does git's own checkout
		}
		path := filepath.Join(HooksDir(r.ws), name)
		st, err := os.Stat(path)
		require.NoError(t, err, name)
		assert.Equal(t, os.FileMode(0o755), st.Mode().Perm(), name)
		cmd := exec.Command(path, "arg")
		cmd.Dir = r.work
		cmd.Stdin = strings.NewReader("")
		out, err := cmd.CombinedOutput()
		assert.NoError(t, err, "%s: %s", name, out)
	}
}

func TestHooks_PushToCheckoutWithoutPreviousChecksOut(t *testing.T) {
	r := newHookRepo(t)
	gitT(t, r.work, "config", "receive.denyCurrentBranch", "updateInstead")
	require.NoError(t, EnsureHooks(context.Background(), r.work, r.ws))
	other := filepath.Join(r.root, "other")
	gitT(t, r.root, "clone", "-q", r.work, other)
	require.NoError(t, os.WriteFile(filepath.Join(other, "f.txt"), []byte("pushed\n"), 0o600))
	gitT(t, other, "add", "f.txt")
	gitT(t, other, "commit", "-q", "-m", "f")
	gitT(t, other, "push", "-q", "origin", "main")
	raw, err := os.ReadFile(filepath.Join(r.work, "f.txt"))
	require.NoError(t, err, "the pushed commit was not checked out")
	assert.Equal(t, "pushed\n", string(raw))
}

// snapshot is each file's content and modification time.
func snapshot(t *testing.T, paths ...string) map[string]string {
	t.Helper()
	m := map[string]string{}
	for _, p := range paths {
		st, err := os.Stat(p)
		require.NoError(t, err, p)
		raw, err := os.ReadFile(p)
		require.NoError(t, err, p)
		m[p] = st.ModTime().Format(time.RFC3339Nano) + "\n" + string(raw)
	}
	return m
}

func TestEnsureHooks_WorktreeOnlyNeverSharedConfig(t *testing.T) {
	r := newHookRepo(t)
	gitT(t, r.work, "config", "core.hooksPath", "scripts/git-hooks")
	wt := filepath.Join(r.root, "wt")
	gitT(t, r.work, "worktree", "add", "-q", "-b", "feature/wt", wt)
	ctx := context.Background()
	require.NoError(t, EnsureHooks(ctx, wt, r.ws))

	assert.Equal(t, "scripts/git-hooks", gitT(t, r.work, "config", "--local", "--get", "core.hooksPath"), "the shared config changed")
	assert.Equal(t, HooksDir(r.ws), gitT(t, wt, "config", "--worktree", "--get", "core.hooksPath"))
	_, err := gitOut(r.work, "config", "--worktree", "--get", "core.hooksPath")
	assert.Error(t, err, "the main worktree got a hooks path too")
	assert.Equal(t, "scripts/git-hooks", gitT(t, r.work, "config", "--get", "core.hooksPath"), "the main worktree's effective hooks path changed")

	top, err := filepath.EvalSymlinks(wt)
	require.NoError(t, err)
	rec, err := readRecord(recordPath(r.ws, top))
	require.NoError(t, err)
	gitDir, err := filepath.EvalSymlinks(filepath.Join(r.work, ".git", "worktrees", "wt"))
	require.NoError(t, err)
	// The shared value is read when a hook runs, not recorded.
	assert.Equal(t, hooksRecord{Worktree: top, GitDir: gitDir}, rec)

	files := []string{
		filepath.Join(r.work, ".git", "config"),
		filepath.Join(r.work, ".git", "worktrees", "wt", "config.worktree"),
		recordPath(r.ws, top),
	}
	for _, name := range ClientHookNames {
		files = append(files, filepath.Join(HooksDir(r.ws), name))
	}
	before := snapshot(t, files...)
	require.NoError(t, EnsureHooks(ctx, wt, r.ws))
	assert.Equal(t, before, snapshot(t, files...), "a second EnsureHooks changed something")
}

func TestRestoreHooks_KeepsOwnerLaterChange(t *testing.T) {
	r := newHookRepo(t)
	ctx := context.Background()
	require.NoError(t, EnsureHooks(ctx, r.work, r.ws))
	gitT(t, r.work, "config", "--worktree", "core.hooksPath", "/opt/acme/hooks")
	require.NoError(t, RestoreHooks(ctx, r.work, r.ws))
	assert.Equal(t, "/opt/acme/hooks", gitT(t, r.work, "config", "--worktree", "--get", "core.hooksPath"))
	entries, err := os.ReadDir(hooksPrevDir(r.ws))
	require.NoError(t, err)
	assert.Empty(t, entries, "the stale record stayed")
}

func TestRestoreHooks_UnsetsWhenNoPrevious(t *testing.T) {
	r := newHookRepo(t)
	gitT(t, r.work, "config", "core.hooksPath", "repo-hooks")
	ctx := context.Background()
	require.NoError(t, EnsureHooks(ctx, r.work, r.ws))
	require.NoError(t, RestoreHooks(ctx, r.work, r.ws))
	_, err := gitOut(r.work, "config", "--worktree", "--get", "core.hooksPath")
	assert.Error(t, err, "the worktree value is still set")
	assert.Equal(t, "repo-hooks", gitT(t, r.work, "config", "--get", "core.hooksPath"))
}

func TestRestoreHooks_PutsBackPreviousWorktreeValue(t *testing.T) {
	r := newHookRepo(t)
	gitT(t, r.work, "config", "extensions.worktreeConfig", "true")
	gitT(t, r.work, "config", "--worktree", "core.hooksPath", "my-hooks")
	ran := filepath.Join(r.root, "ran")
	writeHook(t, filepath.Join(r.work, "my-hooks"), "post-commit", "touch '"+ran+"'\n")
	ctx := context.Background()
	require.NoError(t, EnsureHooks(ctx, r.work, r.ws))
	gitT(t, r.work, "commit", "-q", "--allow-empty", "-m", "x")
	assert.FileExists(t, ran, "the worktree's own hook did not run through Watchman's")
	require.NoError(t, RestoreHooks(ctx, r.work, r.ws))
	assert.Equal(t, "my-hooks", gitT(t, r.work, "config", "--worktree", "--get", "core.hooksPath"))
}

func TestRestoreHooks_UnreadableRecordLeavesHook(t *testing.T) {
	r := newHookRepo(t)
	ctx := context.Background()
	require.NoError(t, EnsureHooks(ctx, r.work, r.ws))
	top, err := filepath.EvalSymlinks(r.work)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(recordPath(r.ws, top), []byte("garbage\n"), 0o600))
	err = RestoreHooks(ctx, r.work, r.ws)
	require.ErrorIs(t, err, ErrHooksRecordUnreadable)
	assert.Equal(t, HooksDir(r.ws), gitT(t, r.work, "config", "--worktree", "--get", "core.hooksPath"))
}

// serverHookNames are githooks(5)'s hooks of the receiving repository.
var serverHookNames = []string{"pre-receive", "update", "proc-receive", "post-receive", "post-update"}

func TestClientHookNames_CoverInstalledGit(t *testing.T) {
	cmd := exec.Command("git", "help", "hooks")
	cmd.Env = append(os.Environ(), "MANPAGER=cat", "GIT_PAGER=cat", "PAGER=cat", "MANWIDTH=80")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Skipf("the installed git ships no githooks documentation (git help hooks: %v): %s", err, out)
	}
	text := regexp.MustCompile(".\x08").ReplaceAllString(string(out), "")
	text = regexp.MustCompile("\x1b\\[[0-9;]*m").ReplaceAllString(text, "")
	heading := regexp.MustCompile(`^ {2,4}([a-z0-9]+(?:-[a-z0-9]+)*)\s*$`) // a subsection; body text sits deeper
	var names []string
	in := false
	for _, line := range strings.Split(text, "\n") {
		switch {
		case strings.TrimSpace(line) == "HOOKS" && !strings.HasPrefix(line, " "):
			in = true
		case in && line != "" && !strings.HasPrefix(line, " "):
			in = false
		case in:
			if m := heading.FindStringSubmatch(line); m != nil {
				names = append(names, m[1])
			}
		}
	}
	require.NotEmpty(t, names, "no hook names found in git help hooks:\n%s", text)
	for _, n := range names {
		if slices.Contains(serverHookNames, n) {
			continue
		}
		assert.Contains(t, ClientHookNames, n, "git runs the %s hook; ClientHookNames lacks it", n)
	}
	for _, n := range serverHookNames {
		assert.NotContains(t, ClientHookNames, n)
	}
}

func TestPrePush_ArmedByGitDirNotCwd(t *testing.T) {
	r := newHookRepo(t)
	require.NoError(t, EnsureHooks(context.Background(), r.work, r.ws))
	r.arm(t, r.work)
	before := r.remoteRef(t, "refs/heads/main")
	gitT(t, r.work, "commit", "-q", "--allow-empty", "-m", "agent work")
	elsewhere := t.TempDir()

	out, err := gitOut(r.work, "--work-tree="+elsewhere, "push", "origin", "HEAD:main")
	require.Error(t, err, "a --work-tree push went through: %s", out)
	assert.Contains(t, out, "Parked for the owner: a push to main")

	cmd := exec.Command("git", "push", "origin", "HEAD:main")
	cmd.Dir = elsewhere
	cmd.Env = append(os.Environ(), "GIT_DIR="+filepath.Join(r.work, ".git"))
	raw, err := cmd.CombinedOutput()
	require.Error(t, err, "a GIT_DIR push from another cwd went through: %s", raw)
	assert.Contains(t, string(raw), "Parked for the owner: a push to main")
	assert.Equal(t, before, r.remoteRef(t, "refs/heads/main"))
}

func TestEnsureHooks_RefusesSharedWorktreeOrBare(t *testing.T) {
	ctx := context.Background()
	t.Run("core.worktree", func(t *testing.T) {
		r := newHookRepo(t)
		gitT(t, r.work, "config", "core.worktree", r.work)
		err := EnsureHooks(ctx, r.work, r.ws)
		var unsupported *GuardUnsupportedError
		require.True(t, errors.As(err, &unsupported), "got %v", err)
		top, _ := filepath.EvalSymlinks(r.work)
		assert.Equal(t, "Watchman's git guard cannot be installed in "+top+": shared core.worktree/core.bare — the other layers still apply", err.Error())
		require.ErrorAs(t, CheckGuardLayout(ctx, r.work), &unsupported)
		_, gerr := gitOut(r.work, "config", "--get", "extensions.worktreeConfig")
		assert.Error(t, gerr, "the extension was enabled")
		_, gerr = gitOut(r.work, "config", "--get", "core.hooksPath")
		assert.Error(t, gerr, "a hooks path was set")
	})
	t.Run("core.bare", func(t *testing.T) {
		r := newHookRepo(t)
		bare := filepath.Join(r.root, "bare.git")
		gitT(t, r.root, "clone", "-q", "--bare", r.remote, bare)
		wt := filepath.Join(r.root, "bwt")
		gitT(t, bare, "worktree", "add", "-q", "-b", "feature/b", wt)
		err := EnsureHooks(ctx, wt, r.ws)
		var unsupported *GuardUnsupportedError
		require.ErrorAs(t, err, &unsupported)
		want, _ := filepath.EvalSymlinks(bare)
		assert.Equal(t, want, unsupported.Repo)
		_, gerr := gitOut(bare, "config", "--get", "extensions.worktreeConfig")
		assert.Error(t, gerr, "the extension was enabled")
	})
	t.Run("an ordinary repository is fine", func(t *testing.T) {
		r := newHookRepo(t)
		assert.NoError(t, CheckGuardLayout(ctx, r.work))
	})
}

func TestEnsureHooks_ChainsHooksPathFromInclude(t *testing.T) {
	ctx := context.Background()
	t.Run("worktree level", func(t *testing.T) {
		r := newHookRepo(t)
		owner := filepath.Join(r.root, "owner-hooks")
		ran := filepath.Join(r.root, "ran")
		writeHook(t, owner, "post-commit", "touch '"+ran+"'\n")
		extra := filepath.Join(r.root, "extra.config")
		require.NoError(t, os.WriteFile(extra, []byte("[core]\n\thooksPath = "+owner+"\n"), 0o600))
		gitT(t, r.work, "config", "extensions.worktreeConfig", "true")
		gitT(t, r.work, "config", "--worktree", "include.path", extra)
		require.NoError(t, EnsureHooks(ctx, r.work, r.ws))
		assert.Equal(t, HooksDir(r.ws), gitT(t, r.work, "config", "--get", "core.hooksPath"))
		gitT(t, r.work, "commit", "-q", "--allow-empty", "-m", "x")
		assert.FileExists(t, ran, "the included hooks path was not chained")
		// The direct worktree value was unset: restore unsets, the include stays.
		require.NoError(t, RestoreHooks(ctx, r.work, r.ws))
		_, err := gitOut(r.work, "config", "--worktree", "--get", "core.hooksPath")
		assert.Error(t, err)
		assert.Equal(t, owner, gitT(t, r.work, "config", "--get", "core.hooksPath"))
	})
	t.Run("shared level", func(t *testing.T) {
		r := newHookRepo(t)
		owner := filepath.Join(r.root, "owner-hooks")
		ran := filepath.Join(r.root, "ran")
		writeHook(t, owner, "post-commit", "touch '"+ran+"'\n")
		extra := filepath.Join(r.root, "extra.config")
		require.NoError(t, os.WriteFile(extra, []byte("[core]\n\thooksPath = "+owner+"\n"), 0o600))
		gitT(t, r.work, "config", "include.path", extra)
		require.NoError(t, EnsureHooks(ctx, r.work, r.ws))
		gitT(t, r.work, "commit", "-q", "--allow-empty", "-m", "x")
		assert.FileExists(t, ran, "the included hooks path was not chained")
	})
}

func TestHooks_SharedHooksPathRetargetKeepsChaining(t *testing.T) {
	r := newHookRepo(t)
	a, b := filepath.Join(r.root, "ran-a"), filepath.Join(r.root, "ran-b")
	writeHook(t, filepath.Join(r.work, "hooks-a"), "post-commit", "touch '"+a+"'\n")
	writeHook(t, filepath.Join(r.work, "hooks-b"), "post-commit", "touch '"+b+"'\n")
	gitT(t, r.work, "config", "core.hooksPath", "hooks-a")
	require.NoError(t, EnsureHooks(context.Background(), r.work, r.ws))
	gitT(t, r.work, "config", "core.hooksPath", "hooks-b") // `make hooks` retargets it
	gitT(t, r.work, "commit", "-q", "--allow-empty", "-m", "x")
	assert.FileExists(t, b, "the retargeted hooks path was not chained")
	assert.NoFileExists(t, a)
}

func TestHooks_PushToCheckoutRelativeSharedPath(t *testing.T) {
	r := newHookRepo(t)
	ran := filepath.Join(r.root, "ran")
	gitT(t, r.work, "config", "receive.denyCurrentBranch", "updateInstead")
	gitT(t, r.work, "config", "core.hooksPath", "repo-hooks")
	writeHook(t, filepath.Join(r.work, "repo-hooks"), "push-to-checkout", "touch '"+ran+"'\n")
	require.NoError(t, EnsureHooks(context.Background(), r.work, r.ws))
	other := filepath.Join(r.root, "other")
	gitT(t, r.root, "clone", "-q", r.work, other)
	gitT(t, other, "commit", "-q", "--allow-empty", "-m", "y")
	gitT(t, other, "push", "-q", "origin", "main")
	assert.FileExists(t, ran, "the relative shared push-to-checkout was not found from $GIT_DIR")
}

func TestHooks_PushToCheckoutUnbornHead(t *testing.T) {
	isolateGit(t)
	root := t.TempDir()
	target, src, ws := filepath.Join(root, "target"), filepath.Join(root, "src"), filepath.Join(root, "ws")
	gitT(t, root, "init", "-q", "-b", "main", target)
	gitT(t, target, "config", "receive.denyCurrentBranch", "updateInstead")
	require.NoError(t, EnsureHooks(context.Background(), target, ws))
	gitT(t, root, "init", "-q", "-b", "main", src)
	require.NoError(t, os.WriteFile(filepath.Join(src, "f.txt"), []byte("first\n"), 0o600))
	gitT(t, src, "add", "f.txt")
	gitT(t, src, "commit", "-q", "-m", "first")
	gitT(t, src, "push", "-q", target, "main")
	raw, err := os.ReadFile(filepath.Join(target, "f.txt"))
	require.NoError(t, err, "the pushed commit was not checked out into the unborn worktree")
	assert.Equal(t, "first\n", string(raw))
}
