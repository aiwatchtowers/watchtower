package sessioncleanup

import (
	"bytes"
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
// uncommitted work — still loses its build folders, which hold 7–15 GB each
// and are rebuilt by the next build. Only folders that are certainly build
// output go (buildKinds): a real, untracked directory that is not a nested
// repository and holds its tool's marker. Sources, untracked files and every
// other ignored file stay.

// buildKind is one kind of build folder: its name and the entries that
// prove it is that tool's output.
type buildKind struct {
	name string
	// files must be regular files and dirs real directories inside it.
	files, dirs []string
}

// buildKinds are the build folders a prune deletes: SwiftPM's .build (its
// workspace-state.json) and an Xcode DerivedData folder a build was pointed
// at inside the worktree with -derivedDataPath (its info.plist and Build).
var buildKinds = []buildKind{
	{name: ".build", files: []string{"workspace-state.json"}},
	{name: "DerivedData", files: []string{"info.plist"}, dirs: []string{"Build"}},
}

const (
	// trashInfix names where a build folder is moved before it is deleted:
	// <name><trashInfix><random>, a fresh directory the prune made itself,
	// so a crash part-way never leaves a half-deleted build folder its
	// tool would read.
	trashInfix = ".removing-by-watchtower-"
	// trashMarker is the file a prune writes into its trash folder before
	// it moves the build folder in: a later prune deletes a leftover trash
	// folder only when it carries it, with trashMarkerBody.
	trashMarker     = ".watchtower-build-trash"
	trashMarkerBody = "a build folder Watchtower's session cleanup is deleting\n"
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
// worktree on fresh facts (pruneCatches) right before deleting them, keeps
// any folder a listed worktree lives in (worktreeInside), and deletes the
// rest; any doubt leaves them. The walk comes first, so the
// re-check is as close to the removal as it can be, and a worktree with no
// build costs no re-check. BuildsChecked is set once nothing is left to
// delete: no build found, or every one found deleted or tracked.
func (a *applier) pruneWorktreeBuilds(ctx context.Context, it *Item) {
	root := strings.TrimPrefix(it.Key, "worktree:")
	if fi, err := os.Lstat(root); err != nil || !fi.IsDir() {
		return // a prunable worktree: its directory, and any build, is gone
	}
	found, err := findBuildDirs(ctx, root, nestedScanBudget)
	if err != nil {
		it.BuildError = err.Error()
		return
	}
	if len(found) == 0 {
		it.BuildsChecked = true
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
	for _, f := range found {
		if holder := b.worktreeInside(f.path); holder != "" {
			continue // a linked worktree lives in it: its work is not build output
		}
		removed, err := b.pruneBuildDir(ctx, root, f)
		if err != nil {
			it.BuildError = err.Error()
			return
		}
		if removed {
			it.BuildsRemoved = append(it.BuildsRemoved, f.path)
		}
	}
	it.BuildsChecked = true
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

// worktreeInside is a worktree of the repository, as the fresh `git
// worktree list` gives it, whose root is dir or lies inside it, "" for
// none. The walk never enters a build folder, so a linked worktree placed
// inside one (whose files the outer ls-files cannot see) is found only
// here. A git clone inside (SwiftPM's .build/checkouts/*) is no worktree of
// the repository and does not count.
func (b *builder) worktreeInside(dir string) string {
	dir = resolvePath(dir)
	for _, w := range b.repo.worktrees {
		if pathWithin(resolvePath(w.Root), dir) {
			return w.Root
		}
	}
	return ""
}

// foundBuild is a build folder, or a marked trash leftover, of a walk.
type foundBuild struct {
	path  string
	trash bool
}

// pruneBuildDir deletes one find of root and says whether it did: a folder
// git tracks a file in (its path matched literally) stays (it is the repository's, not build output); a
// build folder is moved aside and deleted (removeBuildDir), a marked trash
// leftover deleted as it is.
func (b *builder) pruneBuildDir(ctx context.Context, root string, f foundBuild) (bool, error) {
	rel, err := filepath.Rel(root, f.path)
	if err != nil {
		return false, fmt.Errorf("locating %s: %w", f.path, err)
	}
	// ":(literal)": the folder's path is a path, never pathspec magic or a
	// glob (a folder named ":(literal)x" or "a*" must still match itself).
	out, err := b.repo.git.output(ctx, root, "ls-files", "-z", "--", ":(literal)"+rel)
	if err != nil {
		return false, fmt.Errorf("reading what git tracks in %s: %w", f.path, err)
	}
	if len(out) > 0 {
		return false, nil
	}
	if f.trash {
		if err := os.RemoveAll(f.path); err != nil {
			return false, fmt.Errorf("deleting %s: %w", f.path, err)
		}
		return true, nil
	}
	return true, removeBuildDir(f.path)
}

// removeBuildDir makes a fresh trash folder beside dir
// (<name><trashInfix><random>, created by the prune itself, so never an
// existing folder of someone else's), marks it (trashMarker), moves dir
// into it in one rename and deletes it. A crash after the mark leaves a
// marked trash folder a later prune deletes; one before it leaves an empty
// folder at worst, and the build folder untouched.
func removeBuildDir(dir string) error {
	trash, err := os.MkdirTemp(filepath.Dir(dir), filepath.Base(dir)+trashInfix)
	if err != nil {
		return fmt.Errorf("making room to move %s aside: %w", dir, err)
	}
	if err := os.WriteFile(filepath.Join(trash, trashMarker), []byte(trashMarkerBody), 0o600); err != nil {
		_ = os.RemoveAll(trash) // our own folder; the build stays
		return fmt.Errorf("marking %s: %w", trash, err)
	}
	if err := os.Rename(dir, filepath.Join(trash, filepath.Base(dir))); err != nil {
		_ = os.RemoveAll(trash) // still only our marker; the build stays
		return fmt.Errorf("moving %s aside: %w", dir, err)
	}
	if err := os.RemoveAll(trash); err != nil {
		return fmt.Errorf("deleting %s: %w", trash, err)
	}
	return nil
}

// errBuildScanBudget: the walk for build folders ran over its budget.
var errBuildScanBudget = errors.New("looking for build folders took too long")

// findBuildDirs walks root without following symlinks and returns every
// build folder (isBuildDir) and every trash leftover of an interrupted
// prune (isTrashLeftover). It never descends into .git, a nested worktree
// or repository (a directory holding a .git entry), or a cache W9 skips
// (regenerableCaches), and never into what it found. Over budget it fails,
// and nothing is deleted.
func findBuildDirs(ctx context.Context, root string, budget time.Duration) ([]foundBuild, error) {
	deadline := time.Now().Add(budget)
	var found []foundBuild
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
		name := d.Name()
		switch {
		case name == ".git":
			return filepath.SkipDir
		case isBuildDir(path, name):
			found = append(found, foundBuild{path: path})
			return filepath.SkipDir
		case isTrashLeftover(path, name):
			found = append(found, foundBuild{path: path, trash: true})
			return filepath.SkipDir
		case regenerableCaches[name] || hasGitEntry(path):
			return filepath.SkipDir // a cache, or a nested worktree or repository: not ours
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("looking for build folders in %s: %w", root, err)
	}
	return found, nil
}

// isBuildDir: dir (named name, a real directory) is one of buildKinds —
// it holds no .git entry (a repository or worktree of that name is never
// build output) and every marker of its kind.
func isBuildDir(dir, name string) bool {
	for _, k := range buildKinds {
		if k.name != name || hasGitEntry(dir) {
			continue
		}
		ok := true
		for _, f := range k.files {
			fi, err := os.Lstat(filepath.Join(dir, f))
			ok = ok && err == nil && fi.Mode().IsRegular()
		}
		for _, sub := range k.dirs {
			fi, err := os.Lstat(filepath.Join(dir, sub))
			ok = ok && err == nil && fi.IsDir()
		}
		if ok {
			return true
		}
	}
	return false
}

// isTrashLeftover: dir is a folder an interrupted prune moved aside —
// named <build kind><trashInfix>…, with no .git entry, and carrying
// trashMarker with trashMarkerBody as a regular file. A folder of that
// name without the marker is someone else's and stays.
func isTrashLeftover(dir, name string) bool {
	named := false
	for _, k := range buildKinds {
		named = named || strings.HasPrefix(name, k.name+trashInfix)
	}
	if !named || hasGitEntry(dir) {
		return false
	}
	marker := filepath.Join(dir, trashMarker)
	fi, err := os.Lstat(marker)
	if err != nil || !fi.Mode().IsRegular() || fi.Size() != int64(len(trashMarkerBody)) {
		return false
	}
	body, err := os.ReadFile(marker)
	return err == nil && bytes.Equal(body, []byte(trashMarkerBody))
}

// hasGitEntry: dir holds a .git file or directory (or anything of that
// name), or whether it does cannot be told (fail closed).
func hasGitEntry(dir string) bool {
	_, err := os.Lstat(filepath.Join(dir, ".git"))
	return err == nil || !errors.Is(err, fs.ErrNotExist)
}
