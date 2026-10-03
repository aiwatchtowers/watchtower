// Package workbenchgit reads a workbench folder's git state — the current
// branch, its changes, the local branches, the files git does not ignore —
// and switches or creates a branch for the Desktop's workbench header. git
// is located through internal/gitbin, never the macOS /usr/bin/git shim, and
// no git process runs outside a repository. A switch never forces,
// discards, resets or cleans, and never swaps the owner's uncommitted work
// or a running agent's files without the caller's explicit confirmation
// (PROJ-10, docs/inventory/workbench.md).
package workbenchgit

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"

	"watchtower/internal/gitbin"
	"watchtower/internal/workbenchcheck"
)

// errorLimit caps the git stderr handed back in an envelope.
const errorLimit = 300

var errNotRepository = errors.New("the folder is not a git work tree")

// Options configures one call.
type Options struct {
	Folder string
	// Run runs the located git binary (its absolute path is the name
	// argument). nil = a real process.
	Run workbenchcheck.Runner
	// Locate finds git. nil = gitbin.Locate.
	Locate func() (string, bool)
}

// runError carries git's stderr apart from the rest of the failure, so an
// envelope can show git's own words.
type runError struct {
	args   []string
	err    error
	stderr string
}

func (e *runError) Error() string {
	sub := ""
	if len(e.args) > 0 {
		sub = e.args[0]
	}
	switch {
	case errors.Is(e.err, context.DeadlineExceeded):
		return "git " + sub + " timed out"
	case errors.Is(e.err, context.Canceled):
		return "git " + sub + " was canceled"
	case e.stderr == "":
		return fmt.Sprintf("git %s: %v", strings.Join(e.args, " "), e.err)
	}
	return fmt.Sprintf("git %s: %v: %s", strings.Join(e.args, " "), e.err, e.stderr)
}

func (e *runError) Unwrap() error { return e.err }

// execRunner runs a real process through gitbin.Exec (non-interactive, no
// inherited repository variables) and keeps git's stderr apart in a
// runError.
func execRunner(ctx context.Context, dir string, stdin []byte, name string, args ...string) ([]byte, int, error) {
	stdout, stderr, err := gitbin.Exec(ctx, dir, stdin, name, args...)
	var exitErr *exec.ExitError
	switch {
	case err != nil && ctx.Err() != nil: // killed or never started: say why
		return stdout, -1, &runError{args: args, err: ctx.Err()}
	case err == nil:
		return stdout, 0, nil
	case errors.As(err, &exitErr):
		return stdout, exitErr.ExitCode(), &runError{args: args, err: err, stderr: string(stderr)}
	default:
		return nil, -1, err
	}
}

// repo is a folder whose git binary was found and which sits inside a
// repository; every git call goes through it.
type repo struct {
	o   Options
	bin string
}

// open resolves git and checks the folder; no process runs. The error is
// gitbin.ErrUnavailable or errNotRepository.
func open(o Options) (*repo, error) {
	if o.Run == nil {
		o.Run = execRunner
	}
	locate := o.Locate
	if locate == nil {
		locate = gitbin.Locate
	}
	bin, ok := locate()
	if !ok {
		return nil, gitbin.ErrUnavailable
	}
	if !gitbin.InsideRepository(o.Folder) {
		return nil, errNotRepository
	}
	return &repo{o: o, bin: bin}, nil
}

func (r *repo) git(ctx context.Context, args ...string) ([]byte, error) {
	out, _, err := r.run(ctx, args...)
	return out, err
}

// run is git with its exit code.
func (r *repo) run(ctx context.Context, args ...string) ([]byte, int, error) {
	return r.o.Run(ctx, r.o.Folder, nil, r.bin, args...)
}

// paths is where the folder's repository lives.
type paths struct {
	topLevel, gitDir, commonDir string
}

// locatePaths reads the work tree's top level, its git dir and the common
// dir shared by every worktree. It fails in a folder inside a repository
// but outside its work tree (a .git directory itself, a bare repository).
func (r *repo) locatePaths(ctx context.Context) (paths, error) {
	out, err := r.git(ctx, "rev-parse", "--absolute-git-dir", "--git-common-dir", "--show-toplevel")
	if err != nil {
		return paths{}, err
	}
	lines := strings.Split(strings.TrimRight(string(out), "\n"), "\n")
	if len(lines) != 3 {
		return paths{}, fmt.Errorf("git rev-parse: unexpected output %q", out)
	}
	p := paths{gitDir: lines[0], commonDir: lines[1], topLevel: lines[2]}
	// --git-common-dir is relative to the folder unless git made it absolute.
	if !filepath.IsAbs(p.commonDir) {
		abs, err := filepath.Abs(r.o.Folder)
		if err != nil {
			return paths{}, err
		}
		p.commonDir = filepath.Join(abs, p.commonDir)
	}
	p.commonDir = filepath.Clean(p.commonDir)
	return p, nil
}

// gitError is the failure as the envelope shows it: git's stderr when
// there is one, trimmed and capped at errorLimit characters.
func gitError(err error) string {
	msg := err.Error()
	var re *runError
	if errors.As(err, &re) && re.stderr != "" {
		msg = re.stderr
	}
	return clip(strings.TrimSpace(msg))
}

// clip caps msg at errorLimit characters.
func clip(msg string) string {
	if r := []rune(msg); len(r) > errorLimit {
		return string(r[:errorLimit-1]) + "…"
	}
	return msg
}
