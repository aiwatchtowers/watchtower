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
	// managed are the folders (relative to the build folder) whose every
	// child is the tool's own git clone or mirror of a package — SwiftPM's
	// checkouts (a clone, with its submodules' gitfiles) and repositories
	// (bare mirrors). SwiftPM resets them on the next resolve, and an
	// edited package lives in Packages/ (`swift package edit`), outside the
	// build folder, so they are build output. A `.git` anywhere else in the
	// folder keeps it (holdsForeignGit).
	managed []string
}

// buildKinds are the build folders a prune deletes: SwiftPM's .build (its
// workspace-state.json) and an Xcode DerivedData folder a build was pointed
// at inside the worktree with -derivedDataPath (its info.plist and Build).
var buildKinds = []buildKind{
	{name: ".build", files: []string{"workspace-state.json"}, managed: []string{"checkouts", "repositories"}},
	{name: "DerivedData", files: []string{"info.plist"}, dirs: []string{"Build"},
		managed: []string{filepath.Join("SourcePackages", "checkouts"), filepath.Join("SourcePackages", "repositories")}},
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

// sessionFinished: the planned session's finish still stands (finished_at
// set, not cleared by a resume) and it is not being deleted (the Desktop's
// background cleanup owns it then): what an automatic apply needs
// (Request.RequireEnded).
func (b *builder) sessionFinished() bool {
	a, ok := b.activity[b.req.SessionID]
	return ok && a.Finished && !a.DeleteRequested
}

// sessionEnded: the planned session finished (finish_session) or is being
// deleted, or quiet for 24 h (Request.Quiet) — the end of the session the
// prune waits for. The one place that honours Request.Quiet.
func (b *builder) sessionEnded() bool {
	a, ok := b.activity[b.req.SessionID]
	return ok && (a.Finished || a.DeleteRequested || b.req.Quiet)
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

// pruneWorktreeBuilds finds the worktree's build folders, drops those a
// repository or checkout lives in outside the tool's own clones
// (holdsForeignGit), re-checks the worktree on fresh facts (mayPrune)
// right before deleting each of the rest, keeps any folder a
// listed worktree lives in (worktreeInside), and deletes the rest; any
// doubt leaves them. The walks come first, so the re-check is as close to
// the removal as it can be, and a worktree with no build costs no
// re-check. A root the request names in BuildsChecked (an earlier
// automatic apply checked it since the session's finish) is not walked
// again. BuildsChecked is set once nothing is left to delete: no build
// found, or every one found deleted or kept for certain.
func (a *applier) pruneWorktreeBuilds(ctx context.Context, it *Item) {
	root := strings.TrimPrefix(it.Key, "worktree:")
	if slices.Contains(a.req.BuildsChecked, root) {
		it.BuildsChecked = true
		return
	}
	if fi, err := os.Lstat(root); err != nil || !fi.IsDir() {
		return // a prunable worktree: its directory, and any build, is gone
	}
	all, err := findBuildDirs(ctx, root, nestedScanBudget)
	if err != nil {
		it.BuildError = err.Error()
		return
	}
	doubt := false
	var found []foundBuild
	for _, f := range all {
		switch holds, err := holdsForeignGit(ctx, f, nestedScanBudget); {
		case err != nil:
			doubt = true // unreadable or over budget: kept, quietly
		case !holds:
			found = append(found, f)
		}
	}
	if len(found) == 0 {
		it.BuildsChecked = !doubt
		return
	}
	for _, f := range found {
		// Fresh facts right before each folder: deleting the one before
		// may have taken long enough for a process, a session or a
		// worktree to appear.
		b, ok, err := a.mayPrune(ctx, root)
		if err != nil {
			it.BuildError = err.Error()
			return
		}
		if !ok {
			return
		}
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
	it.BuildsChecked = !doubt
}

// holdsForeignGit walks a find without following symlinks for a `.git`
// entry of any kind (a directory, a gitfile of a linked worktree or
// submodule checkout, anything of that name) outside its kind's managed
// folders, whose children it does not enter: true keeps the find, whose
// .git could be anyone's work. Over budget, or on an unreadable entry, it
// fails, and the find is kept.
func holdsForeignGit(ctx context.Context, f foundBuild, budget time.Duration) (bool, error) {
	deadline := time.Now().Add(budget)
	n := 0
	errFound := errors.New("found")
	err := filepath.WalkDir(f.path, func(path string, d fs.DirEntry, err error) error {
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
		if path == f.path {
			return nil
		}
		if d.IsDir() && f.managedChild(path) {
			return filepath.SkipDir // the tool's own clone or mirror of a package
		}
		if d.Name() == ".git" {
			return errFound
		}
		return nil
	})
	switch {
	case errors.Is(err, errFound):
		return true, nil
	case err != nil:
		return false, fmt.Errorf("looking for repositories in %s: %w", f.path, err)
	}
	return false, nil
}

// managedChild: path is a direct child of one of the find's managed
// folders (for a trash leftover, of the build folder moved into it).
func (f foundBuild) managedChild(path string) bool {
	content := f.path
	if f.trash {
		content = filepath.Join(f.path, f.kind.name)
	}
	rel, err := filepath.Rel(content, path)
	if err != nil {
		return false
	}
	return slices.Contains(f.kind.managed, filepath.Dir(rel))
}

// mayPrune re-reads every fact (a fresh evaluation) and says whether root's
// build may go now: the session ended (and, for RequireEnded, its finish
// stands), root is still a listed linked worktree, and it passes every
// pruneCatches check. The fresh builder comes back for the per-folder
// checks; err is a check that could not be made.
func (a *applier) mayPrune(ctx context.Context, root string) (*builder, bool, error) {
	b, err := a.fresh(ctx)
	if err != nil {
		return nil, false, err
	}
	if !b.sessionEnded() || (a.req.RequireEnded && !b.sessionFinished()) {
		return nil, false, nil
	}
	w, ok := b.listedWorktree(root)
	if !ok {
		return nil, false, nil
	}
	for _, c := range pruneCatches() {
		reason, _, err := c(ctx, b, w)
		if err != nil {
			return nil, false, err
		}
		if reason != "" {
			return nil, false, nil
		}
	}
	return b, true, nil
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

// foundBuild is a build folder, or a marked trash leftover, of a walk,
// and its kind.
type foundBuild struct {
	path  string
	trash bool
	kind  buildKind
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
	// --cached --others --exclude-standard: a tracked file, or an untracked
	// one git does not ignore, is the owner's work, not build output; a
	// build folder the repository does not ignore therefore always stays.
	// A marked trash leftover passed this check before it was moved (the
	// marker is written only then), and an anchored ignore rule such as
	// "/.build/" no longer matches it inside the trash folder: only a
	// tracked file keeps it.
	args := []string{"ls-files", "-z", "--cached", "--others", "--exclude-standard"}
	if f.trash {
		args = []string{"ls-files", "-z", "--cached"}
	}
	out, err := b.repo.git.output(ctx, root, append(args, "--", ":(literal)"+rel)...)
	if err != nil {
		return false, fmt.Errorf("reading what git tracks in %s: %w", f.path, err)
	}
	if len(out) > 0 {
		return false, nil
	}
	if f.trash {
		return true, finishTrash(f.path, f.kind.name, os.RemoveAll)
	}
	return true, removeBuildDir(f.path, os.RemoveAll)
}

// removeBuildDir makes a fresh trash folder beside dir
// (<name><trashInfix><random>, created by the prune itself, so never an
// existing folder of someone else's), marks it (trashMarker), moves dir
// into it in one rename and deletes it (finishTrash, with rm). A crash
// after the mark leaves a marked trash folder a later prune finishes; one
// before it leaves an empty folder at worst, and the build folder
// untouched.
func removeBuildDir(dir string, rm func(string) error) error {
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
	return finishTrash(trash, filepath.Base(dir), rm)
}

// finishTrash deletes a marked trash folder in an order that keeps it
// recognisable until the build in it is gone: the moved build folder
// (<trash>/<name>, with rm) first, then the marker, then the now empty
// trash folder. An interrupted delete leaves the marker, so a later prune
// finishes it.
func finishTrash(trash, name string, rm func(string) error) error {
	if err := rm(filepath.Join(trash, name)); err != nil {
		return fmt.Errorf("deleting %s: %w", trash, err)
	}
	if err := os.Remove(filepath.Join(trash, trashMarker)); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("deleting %s: %w", trash, err)
	}
	if err := os.Remove(trash); err != nil {
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
		if name == ".git" {
			return filepath.SkipDir
		}
		if k, ok := isBuildDir(path, name); ok {
			found = append(found, foundBuild{path: path, kind: k})
			return filepath.SkipDir
		}
		if k, ok := isTrashLeftover(path, name); ok {
			found = append(found, foundBuild{path: path, trash: true, kind: k})
			return filepath.SkipDir
		}
		if regenerableCaches[name] || hasGitEntry(path) {
			return filepath.SkipDir // a cache, or a nested worktree or repository: not ours
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("looking for build folders in %s: %w", root, err)
	}
	return found, nil
}

// isBuildDir: dir (named name, a real directory) is one of buildKinds,
// returned —
// it holds no .git entry (a repository or worktree of that name is never
// build output) and every marker of its kind.
func isBuildDir(dir, name string) (buildKind, bool) {
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
			return k, true
		}
	}
	return buildKind{}, false
}

// isTrashLeftover: dir is a folder an interrupted prune moved aside —
// named <build kind><trashInfix>…, with no .git entry, and carrying
// trashMarker with trashMarkerBody as a regular file. A folder of that
// name without the marker is someone else's and stays.
func isTrashLeftover(dir, name string) (buildKind, bool) {
	var kind buildKind
	named := false
	for _, k := range buildKinds {
		if strings.HasPrefix(name, k.name+trashInfix) {
			kind, named = k, true
		}
	}
	if !named || hasGitEntry(dir) {
		return buildKind{}, false
	}
	marker := filepath.Join(dir, trashMarker)
	fi, err := os.Lstat(marker)
	if err != nil || !fi.Mode().IsRegular() || fi.Size() != int64(len(trashMarkerBody)) {
		return buildKind{}, false
	}
	body, err := os.ReadFile(marker)
	return kind, err == nil && bytes.Equal(body, []byte(trashMarkerBody))
}

// hasGitEntry: dir holds a .git file or directory (or anything of that
// name), or whether it does cannot be told (fail closed).
func hasGitEntry(dir string) bool {
	_, err := os.Lstat(filepath.Join(dir, ".git"))
	return err == nil || !errors.Is(err, fs.ErrNotExist)
}
