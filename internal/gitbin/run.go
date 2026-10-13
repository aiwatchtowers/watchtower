package gitbin

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"slices"
	"strings"
	"time"
)

// repositoryEnv are the variables that point git at a repository other than
// the one dir is in; an inherited one (a hook's or another tool's shell)
// is dropped.
var repositoryEnv = []string{
	"GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
	"GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE", "GIT_PREFIX",
}

// The workbench folder is the owner's to bind, not ours to trust: its
// .git/config may name commands git runs on its own (core.fsmonitor on
// every status-like read, core.hooksPath, a gpg.program behind
// log.showSignature). A command-line -c outranks the repository's config
// and reaches git's own child processes (submodules) too.
var (
	ownerConfig = []string{"-c", "core.fsmonitor=false"}
	readConfig  = []string{"-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "log.showSignature=false"}
)

// ReadArgs is a background read's argv: no fsmonitor command, no hook, no
// signature check. Callers producing a diff also pass --no-ext-diff and
// --no-textconv themselves.
func ReadArgs(args ...string) []string { return append(slices.Clone(readConfig), args...) }

// OwnerArgs is the argv of a command the owner asked for (a branch switch):
// the repository's hooks run, as they would from a terminal; the fsmonitor
// command, which no command needs, never does.
func OwnerArgs(args ...string) []string { return append(slices.Clone(ownerConfig), args...) }

// Exec runs name (git at the path Locate found, or another tool such as gh
// from PATH) in dir, feeding it stdin (nil = none), and returns its stdout,
// its trimmed stderr and exec's error (an *exec.ExitError for a non-zero exit). The process is
// kept non-interactive: no optional locks, no credential or gh prompt, no
// editor, C locale, and no inherited repository variables. Exec does not
// locate git: a bare "git" would be a PATH lookup that can find the shim,
// so callers pass Locate's path.
func Exec(ctx context.Context, dir string, stdin []byte, name string, args ...string) (stdout, stderr []byte, err error) {
	c := exec.CommandContext(ctx, name, args...)
	c.Dir = dir
	env := slices.DeleteFunc(os.Environ(), func(kv string) bool {
		key, _, _ := strings.Cut(kv, "=")
		return slices.Contains(repositoryEnv, key)
	})
	c.Env = append(env, "GIT_OPTIONAL_LOCKS=0", "GIT_TERMINAL_PROMPT=0", "GIT_EDITOR=true", "GH_PROMPT_DISABLED=1", "LC_ALL=C")
	c.WaitDelay = time.Second
	if stdin != nil {
		c.Stdin = bytes.NewReader(stdin)
	}
	var out, errOut bytes.Buffer
	c.Stdout, c.Stderr = &out, &errOut
	err = c.Run()
	return out.Bytes(), bytes.TrimSpace(errOut.Bytes()), err
}
