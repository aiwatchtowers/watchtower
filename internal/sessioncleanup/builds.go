package sessioncleanup

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"
)

// Build output of an ended session's kept worktrees (board #2131, owner
// decision in ask #1695): a worktree the cleanup must keep — unpushed or
// uncommitted work — still loses its SwiftPM build folders, which hold
// 7–15 GB each and are rebuilt by the next `swift build`. Only folders that
// are certainly build output go: a real directory named .build holding
// SwiftPM's workspace-state.json, not tracked by git, outside any nested
// repository. Sources, untracked files and every other ignored file stay.
const (
	buildDirName = ".build"
	// buildMarker is the file SwiftPM writes at the top of its build
	// folder; a .build without it is not known to be SwiftPM's.
	buildMarker = "workspace-state.json"
	// buildTrashName is where a build folder is renamed before it is
	// deleted, so a crash part-way never leaves a half-deleted .build that
	// SwiftPM would read; a later prune deletes a leftover of this name.
	buildTrashName = ".build.removing-by-watchtower"
)

// pruneReasons are the keep reasons of a worktree kept only for the work
// in it: its build output can go. Every other reason (in use, locked, an
// operation in progress, not the session's, a folder, a failed check)
// leaves the worktree untouched.
var pruneReasons = map[string]bool{
	ReasonUncommittedChanges: true,
	ReasonUnpushedCommits:    true,
	ReasonIgnoredFiles:       true,
	ReasonContainsWorktree:   true,
}

// pruneCatches are the checks a kept worktree passes again, on fresh
// facts, before its build output goes: it is under no ~/.claude and no
// workbench folder, it is the session's own, it is not locked, nothing
// runs in it (orphans included: a binary of the build itself), no session
// works in it and no git operation is in progress.
func pruneCatches() []worktreeCatch {
	return []worktreeCatch{catchClaudeHome, catchFolders, catchOwnWorktree, catchLocked, catchAnyProcess,
		catchSessionInIt, catchOperation}
}

// catchAnyProcess keeps a worktree any process works in or runs from,
// orphan or not (a prune signals nothing).
func catchAnyProcess(_ context.Context, b *builder, w worktree) (string, string, error) {
	orphans, blockers := OrphansIn(b.procs, []string{w.Root}, b.self)
	all := slices.Concat(blockers, orphans)
	if len(all) == 0 {
		return "", "", nil
	}
	return ReasonProcessRunning, "process in use: " + procText(all[0]), nil
}

// sessionEnded: the planned session finished (finish_session) or is being
// deleted — the end of the session the prune waits for.
func (b *builder) sessionEnded() bool {
	a, ok := b.activity[b.req.SessionID]
	return ok && (a.Finished || a.DeleteRequested)
}

// pruneBuilds deletes the build output of every worktree the apply kept
// only for its work, when the request asks for it (an automatic apply of an
// ended session, outside a terminal session) and the apply did not stop.
// A failure is recorded on the item's BuildError and never stops anything.
func (a *applier) pruneBuilds(ctx context.Context) {
	if !a.req.PruneBuilds || a.req.Sweep || a.req.CallerSessionID != 0 || a.halt != nil {
		return
	}
	for i := range a.items {
		it := &a.items[i]
		if it.Kind == KindWorktree && it.Action == ActionKeep && pruneReasons[it.Reason] {
			a.pruneWorktreeBuilds(ctx, it)
		}
	}
}

// pruneWorktreeBuilds finds the worktree's build folders, re-checks the
// worktree on fresh facts (pruneCatches) right before deleting them, and
// deletes them; any doubt leaves them. The walk comes first, so the
// re-check is as close to the removal as it can be, and a worktree with no
// build costs no re-check.
func (a *applier) pruneWorktreeBuilds(ctx context.Context, it *Item) {
	root := strings.TrimPrefix(it.Key, "worktree:")
	if fi, err := os.Lstat(root); err != nil || !fi.IsDir() {
		return // a prunable worktree: its directory, and any build, is gone
	}
	dirs, err := findBuildDirs(ctx, root, nestedScanBudget)
	if err != nil {
		it.BuildError = err.Error()
		return
	}
	if len(dirs) == 0 {
		return
	}
	b, err := a.fresh(ctx)
	if err != nil {
		it.BuildError = err.Error()
		return
	}
	if !b.sessionEnded() {
		return
	}
	w, ok := b.listedWorktree(root)
	if !ok {
		return
	}
	for _, c := range pruneCatches() {
		reason, _, err := c(ctx, b, w)
		if err != nil {
			it.BuildError = err.Error()
			return
		}
		if reason != "" {
			return
		}
	}
	for _, dir := range dirs {
		removed, err := b.pruneBuildDir(ctx, root, dir)
		if err != nil {
			it.BuildError = err.Error()
			return
		}
		if removed {
			it.BuildsRemoved = append(it.BuildsRemoved, dir)
		}
	}
}

// listedWorktree is root as git lists it now, when it is a linked worktree
// whose directory exists.
func (b *builder) listedWorktree(root string) (worktree, bool) {
	for _, w := range b.repo.worktrees {
		if w.Root == root && !w.Bare && !w.Main && !w.Prunable {
			return w, true
		}
	}
	return worktree{}, false
}

// pruneBuildDir deletes one build folder of root and says whether it did:
// a folder git tracks a file in stays (it is the repository's, not build
// output); otherwise it is renamed to buildTrashName and the renamed folder
// deleted.
func (b *builder) pruneBuildDir(ctx context.Context, root, dir string) (bool, error) {
	rel, err := filepath.Rel(root, dir)
	if err != nil {
		return false, fmt.Errorf("locating %s: %w", dir, err)
	}
	out, err := b.repo.git.output(ctx, root, "ls-files", "-z", "--", rel)
	if err != nil {
		return false, fmt.Errorf("reading what git tracks in %s: %w", dir, err)
	}
	if len(out) > 0 {
		return false, nil
	}
	return true, removeBuildDir(dir)
}

// removeBuildDir renames dir to buildTrashName beside it (one atomic step:
// no half-deleted .build is ever left) and deletes that; dir named
// buildTrashName is an earlier crash's leftover and is deleted as it is.
func removeBuildDir(dir string) error {
	trash := filepath.Join(filepath.Dir(dir), buildTrashName)
	if dir != trash {
		if err := os.RemoveAll(trash); err != nil {
			return fmt.Errorf("deleting %s: %w", trash, err)
		}
		if err := os.Rename(dir, trash); err != nil {
			return fmt.Errorf("moving %s aside: %w", dir, err)
		}
	}
	if err := os.RemoveAll(trash); err != nil {
		return fmt.Errorf("deleting %s: %w", trash, err)
	}
	return nil
}

// errBuildScanBudget: the walk for build folders ran over its budget.
var errBuildScanBudget = errors.New("looking for build folders took too long")

// findBuildDirs walks root without following symlinks and returns every
// SwiftPM build folder (a real directory named .build whose
// workspace-state.json is a regular file) and every buildTrashName folder
// a crash left. It never descends into .git, a nested worktree or
// repository (a directory holding a .git entry), a build folder or
// node_modules. Over budget it fails, and nothing is deleted.
func findBuildDirs(ctx context.Context, root string, budget time.Duration) ([]string, error) {
	deadline := time.Now().Add(budget)
	var found []string
	n := 0
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if n++; n%nestedClockEvery == 0 {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			if time.Now().After(deadline) {
				return errBuildScanBudget
			}
		}
		if !d.IsDir() || path == root {
			return nil
		}
		switch d.Name() {
		case ".git", "node_modules":
			return filepath.SkipDir
		case buildTrashName:
			found = append(found, path)
			return filepath.SkipDir
		case buildDirName:
			if fi, err := os.Lstat(filepath.Join(path, buildMarker)); err == nil && fi.Mode().IsRegular() {
				found = append(found, path)
			}
			return filepath.SkipDir
		}
		if _, err := os.Lstat(filepath.Join(path, ".git")); err == nil {
			return filepath.SkipDir // a nested worktree or repository: not ours
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("looking for build folders in %s: %w", root, err)
	}
	return found, nil
}
