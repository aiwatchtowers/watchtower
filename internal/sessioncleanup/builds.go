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
	derivedDataKind,
}

// derivedDataKind is Xcode's DerivedData. A folder of another name a build
// was pointed at (-derivedDataPath .derived, .build-mobile-dd, …) is one by
// its content (derivedDataByContent, #2402 §4), at the worktree's root or
// one level below (derivedDataDepth).
var derivedDataKind = buildKind{name: "DerivedData", files: []string{"info.plist"}, dirs: []string{"Build"},
	managed: []string{filepath.Join("SourcePackages", "checkouts"), filepath.Join("SourcePackages", "repositories")}}

// derivedDataLogs are the folders, one of which a DerivedData folder of any
// name holds besides its kind's info.plist and Build.
var derivedDataLogs = []string{"Logs", "Index.noindex", "ModuleCache.noindex"}

// derivedDataDepth is how deep below a worktree's root a DerivedData folder
// of another name is recognised: 1 at the root, 2 one level below.
const derivedDataDepth = 2

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
// in it, or for its lock (#2402 §4): its build output can go. Every other
// reason (in use, an operation in progress, not the session's, a folder, a
// failed check) leaves the worktree untouched.
var pruneReasons = map[string]bool{
	ReasonUncommittedChanges: true,
	ReasonUnpushedCommits:    true,
	ReasonIgnoredFiles:       true,
	ReasonContainsWorktree:   true,
	ReasonLocked:             true,
}

// pruneCatches are the checks a kept worktree passes again, on fresh
// facts, before its build output goes: it is under no ~/.claude and no
// workbench folder, it is the session's own, nothing runs in it (orphans
// included: a binary of the build itself), no session works in it, no git
// operation is in progress, and — locked, or in the repository pass — it
// has been idle for idleFor (catchPruneIdle).
func pruneCatches() []worktreeCatch {
	return []worktreeCatch{catchClaudeHome, catchFolders, catchOwnWorktree, catchAnyProcess,
		catchSessionInIt, catchOperation, catchPruneIdle}
}

// reasonNotIdle is catchPruneIdle's keep: the prune alone reads it.
const reasonNotIdle = "not_idle"

// catchPruneIdle keeps the build of a locked worktree (its lock, or an
// unlock of ours not undone yet, read afresh), and in a sweep — the
// repository pass — of any worktree, until the worktree has been idle for
// idleFor (#2402 §4): a build used in the last idleFor stays, so the next
// build is not slowed down. The prune at a session's end of a worktree
// kept for its work alone (#2131) does not wait. A lock that cannot be
// read is an error, an idleness that cannot be measured is not idle.
func catchPruneIdle(ctx context.Context, b *builder, w worktree) (string, string, error) {
	admin := b.repo.adminDirs[w.Root]
	st, err := readLock(w, admin)
	if err != nil {
		return "", "", err
	}
	if !st.locked && !st.marked && !b.req.Sweep {
		return "", "", nil
	}
	if admin == "" || !isIdle(ctx, b.deps, w.Root, admin) {
		return reasonNotIdle, "", nil
	}
	return "", "", nil
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

// endStands: the end the apply was started for still stands on the facts b
// holds: the finish for RequireEnded; for a Quiet request the session is
// not being deleted and is finished or still quiet (Request.QuietBefore);
// anything else has nothing to re-check.
func (b *builder) endStands() bool {
	switch {
	case b.req.RequireEnded:
		return b.sessionFinished()
	case b.req.Quiet:
		a, ok := b.activity[b.req.SessionID]
		return quietStands(b.req, a, ok)
	}
	return true
}

// quietStands: a quiet request's session is known, not being deleted, and
// finished or still quiet. closed_at, which the listing also reads, is not
// re-read: it is legacy (no Close action writes it since 2026-10-01), so
// nothing moves it after the listing.
func quietStands(r Request, a SessionActivity, known bool) bool {
	if !known || a.DeleteRequested {
		return false
	}
	return a.Finished || (!a.ReportedAt.After(r.QuietBefore) && !a.LastActive.After(r.QuietBefore))
}

// quietStillStands re-reads the activity of the request's session right now
// (the Desktop writes last_active_at without the repository lock, so a
// builder's snapshot can be stale after its expensive checks) — for a quiet
// request, right before a destructive step. Other requests: true. A read
// that fails is an error: the caller keeps the work.
func (a *applier) quietStillStands(ctx context.Context) (bool, error) {
	if !a.req.Quiet {
		return true, nil
	}
	s, ok, err := a.deps.DB.SessionActivityOf(ctx, a.req.SessionID)
	if err != nil {
		return false, fmt.Errorf("re-reading the session's activity: %w", err)
	}
	return quietStands(a.req, s, ok), nil
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
// found, or every one found deleted or kept for certain — never when a
// quiet session reopened part-way (pruneStopped).
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
		switch foreign, err := holdsForeignGit(ctx, f, nestedScanBudget); {
		case err != nil:
			doubt = true // unreadable or over budget: kept, quietly
		case foreign == "":
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
		outcome, err := b.pruneBuildDir(ctx, root, f, a.quietStillStands)
		if err != nil {
			it.BuildError = err.Error()
			return
		}
		switch outcome {
		case pruneKept:
			// kept for good (git tracks a file in it): on to the next folder
		case pruneRemoved:
			it.BuildsRemoved = append(it.BuildsRemoved, f.path)
		case pruneStopped:
			// The session is no longer quiet: the rest is left, and the
			// root not marked checked, so the pass after it goes quiet
			// again walks it.
			return
		}
	}
	it.BuildsChecked = !doubt
}

// holdsForeignGit walks a find without following symlinks for the first `.git`
// entry of any kind (a directory, a gitfile of a linked worktree or
// submodule checkout, anything of that name) outside its kind's managed
// folders, whose children it does not enter: true keeps the find, whose
// .git could be anyone's work. Over budget, or on an unreadable entry, it
// fails, and the find is kept.
func holdsForeignGit(ctx context.Context, f foundBuild, budget time.Duration) (string, error) {
	deadline := time.Now().Add(budget)
	n := 0
	errFound := errors.New("found")
	found := ""
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
			found = path
			return errFound
		}
		return nil
	})
	switch {
	case errors.Is(err, errFound):
		return found, nil
	case err != nil:
		return "", fmt.Errorf("looking for repositories in %s: %w", f.path, err)
	}
	return "", nil
}

// managedChild: path is a direct child of one of the find's managed
// folders (for a trash leftover, of the build folder moved into it).
func (f foundBuild) managedChild(path string) bool {
	content := f.path
	if f.trash {
		content = filepath.Join(f.path, f.name)
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
	if !b.sessionEnded() || !b.endStands() {
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
// and its kind. name is the build folder's own name (for a leftover, of
// the build folder moved into it).
type foundBuild struct {
	path  string
	name  string
	trash bool
	kind  buildKind
}

// pruneOutcome is what pruneBuildDir did with one find.
type pruneOutcome int

const (
	// pruneKept: the folder stays for good (git tracks a file in it).
	pruneKept pruneOutcome = iota
	// pruneRemoved: the folder was deleted.
	pruneRemoved
	// pruneStopped: the folder stays because the session no longer
	// qualifies (lastCheck said so); the prune stops and the root is not
	// marked checked.
	pruneStopped
)

// pruneBuildDir deletes one find of root and says what it did: a folder
// git tracks a file in (its path matched literally) stays (it is the repository's, not build output); a
// build folder is moved aside and deleted (removeBuildDir), a marked trash
// leftover deleted as it is; a session lastCheck no longer lets go stops it.
func (b *builder) pruneBuildDir(ctx context.Context, root string, f foundBuild,
	lastCheck func(context.Context) (bool, error)) (pruneOutcome, error) {
	rel, err := filepath.Rel(root, f.path)
	if err != nil {
		return pruneKept, fmt.Errorf("locating %s: %w", f.path, err)
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
		return pruneKept, fmt.Errorf("reading what git tracks in %s: %w", f.path, err)
	}
	if len(out) > 0 {
		return pruneKept, nil
	}
	// The last thing before the move or the delete: the session's activity
	// read afresh (the ls-files above can take long). It stays on a
	// failed read.
	switch ok, err := lastCheck(ctx); {
	case err != nil:
		return pruneKept, err
	case !ok:
		return pruneStopped, nil
	}
	if f.trash {
		return pruneRemoved, finishTrash(f.path, f.name, os.RemoveAll)
	}
	return pruneRemoved, removeBuildDir(f.path, f.kind, os.RemoveAll)
}

// removeBuildDir makes a fresh trash folder beside dir
// (<name><trashInfix><random>, created by the prune itself, so never an
// existing folder of someone else's), marks it (trashMarker), moves dir
// into it in one rename and deletes it (finishTrash, with rm). A crash
// after the mark leaves a marked trash folder a later prune finishes; one
// before it leaves an empty folder at worst, and the build folder
// untouched.
func removeBuildDir(dir string, kind buildKind, rm func(string) error) error {
	trash, err := os.MkdirTemp(filepath.Dir(dir), filepath.Base(dir)+trashInfix)
	if err != nil {
		return fmt.Errorf("making room to move %s aside: %w", dir, err)
	}
	if err := os.WriteFile(filepath.Join(trash, trashMarker), []byte(trashMarkerOf(kind)), 0o600); err != nil {
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
	// Only a direct child of the trash folder is ever deleted: never the
	// trash folder itself or its parent (a name "." or "..").
	if !movedName(name) || filepath.Dir(filepath.Join(trash, name)) != filepath.Clean(trash) {
		return fmt.Errorf("deleting %s: %q is not a folder moved into it", trash, name)
	}
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

// movedName: name can be a build folder's own name — one path element,
// not "." or "..".
func movedName(name string) bool {
	return name != "" && name != "." && name != ".." && !strings.ContainsRune(name, filepath.Separator) &&
		filepath.Base(name) == name
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
	return findBuilds(ctx, root, budget, false)
}

// findBuilds is findBuildDirs; strict makes a directory whose .git entry
// cannot be looked at (a permission error) an error instead of a directory
// to leave alone. The prune wants the lenient reading (what it cannot see
// it does not delete); the activity measure wants the strict one (what it
// cannot see it cannot call quiet).
func findBuilds(ctx context.Context, root string, budget time.Duration, strict bool) ([]foundBuild, error) {
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
		k, ok, err := buildDirKind(path, name, strict)
		if err != nil {
			return err
		}
		// A cache W9 skips is never probed for content near the root (it
		// may be unreadable); a folder of a build kind's name that is not
		// that kind — a .build an Xcode build was pointed at — is, at any
		// depth (fix round 1, F8).
		shallow := withinDerivedDataDepth(root, path) && !regenerableCaches[name]
		if !ok && (shallow || buildKindName(name)) {
			if ok, err = derivedDataByContent(path, strict); err != nil {
				return err
			}
			k = derivedDataKind
		}
		if ok {
			found = append(found, foundBuild{path: path, name: name, kind: k})
			return filepath.SkipDir
		}
		if k, moved, ok := isTrashLeftover(path, name, shallow); ok {
			found = append(found, foundBuild{path: path, name: moved, trash: true, kind: k})
			return filepath.SkipDir
		}
		if regenerableCaches[name] {
			return filepath.SkipDir // a cache: never entered, so never probed
		}
		_, gitErr := os.Lstat(filepath.Join(path, ".git"))
		if gitErr == nil || !errors.Is(gitErr, fs.ErrNotExist) {
			if strict && gitErr != nil {
				return gitErr // cannot tell: the caller measuring activity must not guess
			}
			return filepath.SkipDir // a nested worktree or repository: not ours
		}
		return nil
	})
	if err == nil && strict {
		err = ctx.Err()
		if err == nil && time.Now().After(deadline) {
			err = errBuildScanBudget
		}
	}
	if err != nil {
		return nil, fmt.Errorf("looking for build folders in %s: %w", root, err)
	}
	return found, nil
}

// buildDirKind: dir (named name, a real directory) is one of buildKinds,
// returned — it holds no .git entry (a repository or worktree of that name
// is never build output) and every marker of its kind. Lenient (the
// prune's reading), a lookup that fails for any reason is "not a build
// folder"; strict (the activity measure's), only an absent or wrongly
// typed entry is, and any other failure is an error: a build folder that
// cannot be recognised must not be taken for a plain directory.
func buildDirKind(dir, name string, strict bool) (buildKind, bool, error) {
	for _, k := range buildKinds {
		if k.name != name {
			continue
		}
		if strict {
			if _, err := os.Lstat(filepath.Join(dir, ".git")); err == nil {
				continue
			} else if !errors.Is(err, fs.ErrNotExist) {
				return buildKind{}, false, err
			}
		} else if hasGitEntry(dir) {
			continue
		}
		ok := true
		check := func(sub string, want func(fs.FileInfo) bool) error {
			fi, err := os.Lstat(filepath.Join(dir, sub))
			if strict && err != nil && !errors.Is(err, fs.ErrNotExist) {
				return err
			}
			ok = ok && err == nil && want(fi)
			return nil
		}
		for _, f := range k.files {
			if err := check(f, func(fi fs.FileInfo) bool { return fi.Mode().IsRegular() }); err != nil {
				return buildKind{}, false, err
			}
		}
		for _, sub := range k.dirs {
			if err := check(sub, fs.FileInfo.IsDir); err != nil {
				return buildKind{}, false, err
			}
		}
		if ok {
			return k, true, nil
		}
	}
	return buildKind{}, false, nil
}

// buildKindName: name is one of buildKinds' names.
func buildKindName(name string) bool {
	return slices.ContainsFunc(buildKinds, func(k buildKind) bool { return k.name == name })
}

// withinDerivedDataDepth: dir is at root's top level or one level below
// (derivedDataDepth).
func withinDerivedDataDepth(root, dir string) bool {
	rel, err := filepath.Rel(root, dir)
	return err == nil && rel != "." && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) &&
		relDepth(rel) <= derivedDataDepth
}

// derivedDataByContent: dir, a real directory of any name, is an Xcode
// DerivedData folder by its content — no .git entry, a regular info.plist,
// and the directories Build and one of derivedDataLogs. Strict and lenient
// as buildDirKind: lenient, a lookup that fails is "not one" and no error
// is returned.
func derivedDataByContent(dir string, strict bool) (bool, error) {
	_, err := os.Lstat(filepath.Join(dir, ".git"))
	switch {
	case err == nil:
		return false, nil
	case !errors.Is(err, fs.ErrNotExist):
		if strict {
			return false, err
		}
		return false, nil
	}
	is := func(sub string, want func(fs.FileInfo) bool) (bool, error) {
		fi, err := os.Lstat(filepath.Join(dir, sub))
		switch {
		case err == nil:
			return want(fi), nil
		case strict && !errors.Is(err, fs.ErrNotExist):
			return false, err
		}
		return false, nil
	}
	if ok, err := is("info.plist", func(fi fs.FileInfo) bool { return fi.Mode().IsRegular() }); err != nil || !ok {
		return false, err
	}
	if ok, err := is("Build", fs.FileInfo.IsDir); err != nil || !ok {
		return false, err
	}
	for _, logs := range derivedDataLogs {
		if ok, err := is(logs, fs.FileInfo.IsDir); err != nil || ok {
			return ok, err
		}
	}
	return false, nil
}

// derivedDataAt is derivedDataByContent's lenient reading, which never
// fails: what cannot be read is not a DerivedData folder (so it is walked
// and judged).
func derivedDataAt(dir string) bool {
	ok, err := derivedDataByContent(dir, false)
	return ok && err == nil
}

// isTrashLeftover: dir is a folder an interrupted prune moved aside —
// named <build folder><trashInfix>…, with no .git entry, and carrying
// trashMarker as a regular file (trashMarkerOf, whose kind it is
// recovered as; the bare trashMarkerBody of an older prune gives the
// name's kind); moved is the build folder's name. That name is a build
// kind's or — shallow, within
// derivedDataDepth of the root — any name (a DerivedData folder recognised
// by its content, which a half-finished delete may have taken). A folder
// of such a name without the marker is someone else's and stays.
func isTrashLeftover(dir, name string, shallow bool) (kind buildKind, moved string, ok bool) {
	moved, _, found := strings.Cut(name, trashInfix)
	if !found || !movedName(moved) {
		return buildKind{}, "", false
	}
	kind, named := derivedDataKind, false
	for _, k := range buildKinds {
		if moved == k.name {
			kind, named = k, true
		}
	}
	if (!named && !shallow) || hasGitEntry(dir) {
		return buildKind{}, "", false
	}
	marker := filepath.Join(dir, trashMarker)
	fi, err := os.Lstat(marker)
	if err != nil || !fi.Mode().IsRegular() || fi.Size() > trashMarkerMax {
		return buildKind{}, "", false
	}
	body, err := os.ReadFile(marker)
	if err != nil {
		return buildKind{}, "", false
	}
	if bytes.Equal(body, []byte(trashMarkerBody)) {
		return kind, moved, true // a marker from before the kind was written: the name's
	}
	for _, k := range buildKinds {
		if bytes.Equal(body, []byte(trashMarkerOf(k))) {
			return k, moved, true
		}
	}
	return buildKind{}, "", false
}

// trashMarkerMax bounds a marker the prune reads: its body and a kind line.
const trashMarkerMax = 256

// trashMarkerOf is the marker body of a trash folder of kind k: the fixed
// body, then the kind the build folder was found as (fix round 2, R2-5), so
// a leftover is recovered as that kind — a .build found as DerivedData by
// its content keeps its package clones managed.
func trashMarkerOf(k buildKind) string {
	return trashMarkerBody + "kind: " + k.name + "\n"
}

// hasGitEntry: dir holds a .git file or directory (or anything of that
// name), or whether it does cannot be told (fail closed).
func hasGitEntry(dir string) bool {
	_, err := os.Lstat(filepath.Join(dir, ".git"))
	return err == nil || !errors.Is(err, fs.ErrNotExist)
}
