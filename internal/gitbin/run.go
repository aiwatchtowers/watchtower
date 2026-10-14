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

// filterDriverKeys matches the config keys that name a filter driver's
// command; a .gitattributes `filter=<x>` makes status, ls-files or a diff
// run filter.<x>.clean (or .process) on the folder's files.
const filterDriverKeys = `^filter\..*\.(clean|smudge|process)$`

// ReadArgsIn is ReadArgs for a read in dir that may touch file content: it
// also blanks every filter driver command the folder's config names (and
// lifts its `required`, so the read still answers), each key read fresh
// for this call. The owner's global and system config are left alone —
// their drivers (git-lfs) are the owner's own; anything else (the
// repository's config, its includes, an inherited -c) is the folder's.
// Listing config runs no filter. An error fails the read rather than run
// it unprotected.
func ReadArgsIn(ctx context.Context, bin, dir string, args ...string) ([]string, error) {
	overrides, err := filterOverrides(ctx, bin, dir)
	if err != nil {
		return nil, err
	}
	argv := append(slices.Clone(readConfig), overrides...)
	return append(argv, args...), nil
}

// filterOverrides lists the filter driver keys outside the global and
// system scopes as `-c <key>=` and `-c filter.<x>.required=false` pairs.
func filterOverrides(ctx context.Context, bin, dir string) ([]string, error) {
	stdout, stderr, err := Exec(ctx, dir, nil, bin,
		ReadArgs("config", "--show-scope", "-z", "--name-only", "--get-regexp", filterDriverKeys)...)
	var exitErr *exec.ExitError
	switch {
	case errors.As(err, &exitErr) && exitErr.ExitCode() == 1:
		return nil, nil // no filter driver configured
	case err != nil:
		return nil, fmt.Errorf("listing the folder's filter drivers: %w: %s", err, stderr)
	}
	// -z: scope NUL key NUL, per entry.
	fields := strings.Split(strings.TrimSuffix(string(stdout), "\x00"), "\x00")
	var out []string
	lifted := map[string]bool{}
	for i := 0; i+1 < len(fields); i += 2 {
		scope, key := fields[i], fields[i+1]
		if scope == "global" || scope == "system" {
			continue
		}
		// -c splits at the first '=': a key holding one could not be blanked.
		if strings.ContainsAny(key, "=\n") || !strings.HasPrefix(key, "filter.") {
			return nil, fmt.Errorf("the folder's git config names a filter driver key git -c cannot override: %q", key)
		}
		out = append(out, "-c", key+"=")
		name := key[:strings.LastIndex(key, ".")]
		if !lifted[name] {
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
