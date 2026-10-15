package gitbin

import (
	"bytes"
	"context"
	"errors"
	"fmt"
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
// signature check. It does not stop the folder's filter drivers — a read of
// file content (status, ls-files, diff) uses ReadArgsIn. Callers producing a
// diff also pass --no-ext-diff and --no-textconv themselves.
func ReadArgs(args ...string) []string { return append(slices.Clone(readConfig), args...) }

// filterDriverKeys matches the config keys that name a command run on file
// content: a filter driver's (a .gitattributes `filter=<x>` makes status,
// ls-files or a diff run filter.<x>.clean or .process on the folder's
// files), and a git-lfs extension's, which the owner's own git-lfs reads
// from the repository's config.
const filterDriverKeys = `^(filter\..*\.(clean|smudge|process)|lfs\.extension\..*\.(clean|smudge))$`

// ErrFilterGuard is what ReadArgsIn wraps when it cannot switch the
// folder's filter drivers off — the listing failed, or a key -c cannot
// override — so the read is refused rather than run unprotected.
var ErrFilterGuard = errors.New("the folder's filter drivers could not be switched off")

// ReadArgsIn is ReadArgs for a read in dir. When the subcommand reads file
// content (contentReads), it also blanks every filter driver and git-lfs
// extension command the folder's config names (lifting a driver's
// `required`, so the read still answers), each key read fresh for this
// call. Only the global and system scopes are the owner's and left alone;
// everything else — the repository's config and its includes, an
// inherited -c — is the folder's. So a repository-local `filter.lfs.*`
// (`git lfs install --local`) is blanked too, and in such a repository an
// lfs file whose stat changed may read as modified. Listing config runs no
// filter. An error fails the read rather than run it unprotected.
func ReadArgsIn(ctx context.Context, bin, dir string, args ...string) ([]string, error) {
	if !readsContent(args) {
		return ReadArgs(args...), nil
	}
	overrides, err := filterOverrides(ctx, bin, dir)
	if err != nil {
		return nil, err
	}
	argv := append(slices.Clone(readConfig), overrides...)
	return append(argv, args...), nil
}

// contentReads are the subcommands that can run a filter driver on the
// folder's files (add runs clean filters while it stages); log, show and
// diff-tree only with a patch.
var contentReads = []string{"status", "ls-files", "check-ignore", "diff", "diff-files", "diff-index", "add"}

// readsContent: args (subcommand first) may run a filter driver.
func readsContent(args []string) bool {
	if len(args) == 0 {
		return false
	}
	switch args[0] {
	case "log", "show", "diff-tree":
		return slices.ContainsFunc(args[1:], func(a string) bool { return a == "-p" || a == "--patch" || a == "-u" })
	}
	return slices.Contains(contentReads, args[0])
}

// filterOverrides lists the filter driver and lfs extension keys outside
// the global and system scopes as `-c <key>=` pairs, plus
// `-c filter.<x>.required=false` per filter driver.
func filterOverrides(ctx context.Context, bin, dir string) ([]string, error) {
	stdout, stderr, err := Exec(ctx, dir, nil, bin,
		ReadArgs("config", "--show-scope", "-z", "--name-only", "--get-regexp", filterDriverKeys)...)
	var exitErr *exec.ExitError
	switch {
	case errors.As(err, &exitErr) && exitErr.ExitCode() == 1:
		return nil, nil // no filter driver configured
	case err != nil:
		return nil, fmt.Errorf("%w: listing them: %w: %s", ErrFilterGuard, err, stderr)
	}
	// -z: scope NUL key NUL, per entry.
	return overridesFor(strings.Split(strings.TrimSuffix(string(stdout), "\x00"), "\x00"))
}

// overridesFor turns `git config --show-scope -z --name-only` fields (scope,
// key, scope, key, …) into the `-c` pairs that blank every key set outside
// the owner's global and system config.
func overridesFor(fields []string) ([]string, error) {
	var out []string
	lifted := map[string]bool{}
	for i := 0; i+1 < len(fields); i += 2 {
		scope, key := fields[i], fields[i+1]
		if scope == "global" || scope == "system" {
			continue
		}
		// -c splits at the first '=': a key holding one could not be blanked.
		isFilter := strings.HasPrefix(key, "filter.")
		if strings.ContainsAny(key, "=\n") || !isFilter && !strings.HasPrefix(key, "lfs.extension.") {
			return nil, fmt.Errorf("%w: the folder's git config names a filter driver key git -c cannot override: %q", ErrFilterGuard, key)
		}
		out = append(out, "-c", key+"=")
		name := key[:strings.LastIndex(key, ".")]
		if isFilter && !lifted[name] {
			lifted[name] = true
			out = append(out, "-c", name+".required=false")
		}
	}
	return out, nil
}

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
	return ExecEnv(ctx, dir, nil, stdin, name, args...)
}

// ExecEnv is Exec with extraEnv appended after the inherited repository
// variables are dropped: a caller's own GIT_INDEX_FILE (the reviewer's
// temporary index) reaches git, an inherited one never does.
func ExecEnv(ctx context.Context, dir string, extraEnv []string, stdin []byte, name string, args ...string) (stdout, stderr []byte, err error) {
	c := exec.CommandContext(ctx, name, args...)
	c.Dir = dir
	env := slices.DeleteFunc(os.Environ(), func(kv string) bool {
		key, _, _ := strings.Cut(kv, "=")
		return slices.Contains(repositoryEnv, key)
	})
	env = append(env, "GIT_OPTIONAL_LOCKS=0", "GIT_TERMINAL_PROMPT=0", "GIT_EDITOR=true", "GH_PROMPT_DISABLED=1", "LC_ALL=C")
	c.Env = append(env, extraEnv...)
	c.WaitDelay = time.Second
	if stdin != nil {
		c.Stdin = bytes.NewReader(stdin)
	}
	var out, errOut bytes.Buffer
	c.Stdout, c.Stderr = &out, &errOut
	err = c.Run()
	return out.Bytes(), bytes.TrimSpace(errOut.Bytes()), err
}
