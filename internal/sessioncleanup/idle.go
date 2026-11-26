package sessioncleanup

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"time"
)

// idleFor is how long a worktree must have shown no activity before the
// automatic cleanup may take a locked or unowned one (spec §2).
const idleFor = 72 * time.Hour

// buildActivityDepth is how many directory levels below a build folder
// count as activity: a compiler writes by create-and-rename, which moves
// the containing directory's mtime, so an incremental build shows up in a
// nested directory even when the build folder's own mtime does not move.
const buildActivityDepth = 8

// fetchedPackageDirs are skipped by the activity walk: a package manager's
// fetched sources, not the worktree's own build.
var fetchedPackageDirs = map[string]bool{
	"checkouts": true, "repositories": true, "artifacts": true, "SourcePackages": true,
}

// lastActivity is the newest of: the mtimes of the worktree's admin
// HEAD, index and logs/HEAD (a missing index or logs/HEAD is no activity,
// a missing HEAD is an error), the newest ledger sighting of root in any
// session, and the directory mtimes of every build folder in root down to
// buildActivityDepth. Any failure — a stat, the database, a walk over
// W9's budget — returns now with the error: fail closed, the worktree is
// not idle (spec §2).
func lastActivity(ctx context.Context, d Deps, root, adminDir string) (time.Time, error) {
	return lastActivityWithin(ctx, d, root, adminDir, nestedScanBudget)
}

func lastActivityWithin(ctx context.Context, d Deps, root, adminDir string, budget time.Duration) (time.Time, error) {
	now := clockNow(d)
	newest, err := activityNewest(ctx, d, root, adminDir, budget)
	if err != nil {
		return now, fmt.Errorf("last activity of %s: %w", root, err)
	}
	return newest, nil
}

func activityNewest(ctx context.Context, d Deps, root, adminDir string, budget time.Duration) (time.Time, error) {
	newest, err := adminActivity(ctx, d, root, adminDir)
	if err != nil {
		return time.Time{}, err
	}
	note := func(t time.Time) {
		if t.After(newest) {
			newest = t
		}
	}
	start := time.Now()
	builds, err := findBuilds(ctx, root, budget, true)
	if err != nil {
		return time.Time{}, err
	}
	for _, b := range builds {
		left := budget - time.Since(start)
		if err := ctx.Err(); err != nil {
			return time.Time{}, err
		}
		if left <= 0 {
			return time.Time{}, fmt.Errorf("over the %s budget", budget)
		}
		t, err := buildActivity(ctx, b.path, left)
		if err != nil {
			return time.Time{}, err
		}
		note(t)
	}
	if err := ctx.Err(); err != nil {
		return time.Time{}, err
	}
	if time.Since(start) > budget {
		return time.Time{}, fmt.Errorf("over the %s budget", budget)
	}
	return newest, nil
}

// adminActivity is the newest of the mtimes of the admin dir's HEAD, index
// and logs/HEAD (only a missing index or logs/HEAD is no activity) and of
// root's newest ledger sighting: a worktree's activity without its build
// folders.
func adminActivity(ctx context.Context, d Deps, root, adminDir string) (time.Time, error) {
	var newest time.Time
	note := func(t time.Time) {
		if t.After(newest) {
			newest = t
		}
	}
	for _, name := range []string{"HEAD", "index", filepath.Join("logs", "HEAD")} {
		fi, err := os.Stat(filepath.Join(adminDir, name))
		switch {
		case err == nil:
			note(fi.ModTime())
		case errors.Is(err, fs.ErrNotExist) && name != "HEAD":
		default:
			return time.Time{}, err
		}
	}
	seen, ok, err := d.DB.WorktreeLastSeen(ctx, root)
	if err != nil {
		return time.Time{}, err
	}
	if ok {
		note(seen)
	}
	return newest, nil
}

// worktreeActivity is w's last activity (lastActivity); for a prunable
// worktree, whose directory and builds are gone, its admin dir's and the
// ledger's alone. Any failure returns now with the error (fail closed).
func worktreeActivity(ctx context.Context, d Deps, w worktree, adminDir string) (time.Time, error) {
	if !w.Prunable {
		return lastActivity(ctx, d, w.Root, adminDir)
	}
	newest, err := adminActivity(ctx, d, w.Root, adminDir)
	if err != nil {
		return clockNow(d), fmt.Errorf("last activity of %s: %w", w.Root, err)
	}
	return newest, nil
}

// worktreeIdle: w has shown no activity for idleFor (worktreeActivity);
// any failure measuring it, or no admin dir, is "not idle".
func worktreeIdle(ctx context.Context, d Deps, w worktree, adminDir string) bool {
	if adminDir == "" {
		return false
	}
	at, err := worktreeActivity(ctx, d, w, adminDir)
	return err == nil && clockNow(d).Sub(at) >= idleFor
}

// buildActivity is the newest mtime of dir and of the directories inside
// it down to buildActivityDepth, skipping fetchedPackageDirs; directories
// only, no symlink followed, under budget.
func buildActivity(ctx context.Context, dir string, budget time.Duration) (time.Time, error) {
	deadline := time.Now().Add(budget)
	var newest time.Time
	seen := 0
	err := filepath.WalkDir(dir, func(path string, e fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if seen++; seen%nestedClockEvery == 0 {
			if err := nestedWalkLimit(ctx, deadline, budget); err != nil {
				return err
			}
		}
		if !e.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(dir, path)
		if err != nil {
			return err
		}
		if path != dir && fetchedPackageDirs[e.Name()] {
			return filepath.SkipDir
		}
		fi, err := e.Info()
		if err != nil {
			return err
		}
		if fi.ModTime().After(newest) {
			newest = fi.ModTime()
		}
		if rel != "." && relDepth(rel) >= buildActivityDepth {
			return filepath.SkipDir
		}
		return nil
	})
	if err == nil {
		err = nestedWalkLimit(ctx, deadline, budget)
	}
	if err != nil {
		return time.Time{}, err
	}
	return newest, nil
}

// relDepth counts the elements of a relative path.
func relDepth(rel string) int {
	n := 1
	for _, r := range rel {
		if r == filepath.Separator {
			n++
		}
	}
	return n
}

// isIdle reports whether root has shown no activity for idleFor by the
// deps clock. Any failure measuring it is "not idle".
func isIdle(ctx context.Context, d Deps, root, adminDir string) bool {
	at, err := lastActivity(ctx, d, root, adminDir)
	if err != nil {
		return false
	}
	return clockNow(d).Sub(at) >= idleFor
}
