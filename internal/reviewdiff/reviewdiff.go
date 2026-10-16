// Package reviewdiff snapshots a workbench folder's work tree into a git
// tree object and diffs trees for the Desktop's diff reviewer (spec
// docs/superpowers/specs/2026-10-16-workbench-diff-reviewer-design.md §4).
// It never writes a ref, the owner's index or a work-tree file (REVIEW-01),
// and every git call runs with gitbin's background-read hardening
// (REVIEW-05).
package reviewdiff

import (
	"context"
	"errors"
	"fmt"
	"os/exec"

	"watchtower/internal/gitbin"
)

const EmptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

var ErrNotRepository = errors.New("the folder is not a git work tree")

// Runner runs the located git binary (name) in dir with extra environment.
type Runner func(ctx context.Context, dir string, env []string, name string, args ...string) ([]byte, error)

type Repo struct {
	dir, bin string
	run      Runner
}

// Open checks that folder is inside a work tree. run nil = real git.
func Open(folder string, run Runner) (*Repo, error) {
	bin, ok := gitbin.Locate()
	if !ok {
		return nil, gitbin.ErrUnavailable
	}
	if !gitbin.InsideRepository(folder) {
		return nil, ErrNotRepository
	}
	if run == nil {
		run = execRunner
	}
	return &Repo{dir: folder, bin: bin, run: run}, nil
}

// execRunner args start at the subcommand (readsContent looks at args[0]).
func execRunner(ctx context.Context, dir string, env []string, name string, args ...string) ([]byte, error) {
	argv, err := gitbin.ReadArgsIn(ctx, name, dir, args...)
	if err != nil {
		return nil, err
	}
	out, stderr, err := gitbin.ExecEnv(ctx, dir, env, nil, name, argv...)
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return out, fmt.Errorf("git %s: exit %d: %s", subcommand(args), exitErr.ExitCode(), clip(stderr))
		}
		return out, fmt.Errorf("git %s: %w", subcommand(args), err)
	}
	return out, nil
}

// subcommand is the first argument that is not an option or a -c value.
func subcommand(args []string) string {
	for i := 0; i < len(args); i++ {
		if args[i] == "-c" {
			i++
			continue
		}
		if len(args[i]) > 0 && args[i][0] != '-' {
			return args[i]
		}
	}
	return "?"
}

func (r *Repo) git(ctx context.Context, env []string, args ...string) ([]byte, error) {
	return r.run(ctx, r.dir, env, r.bin, args...)
}

func clip(b []byte) string {
	if len(b) > 300 {
		return string(b[:300])
	}
	return string(b)
}
