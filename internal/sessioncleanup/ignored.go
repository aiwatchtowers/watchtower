package sessioncleanup

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"

	"watchtower/internal/devpack"
	"watchtower/internal/workbenchgit"
)

// topLevelBuild is a build output folder that counts as a cache only at the
// worktree's root or the workbench folder's root (`build/`, the repository's
// own output); deeper, `build` is any folder name (#1878).
const topLevelBuild = "build"

// ignoredJudge tells, for one worktree, the git-ignored paths a removal
// would lose (W10, #1878) from the ones it loses nothing of: what is inside
// a real cache folder (W9's regenerableCaches at any depth, `build` at a
// root), a regular .DS_Store, the workbench install's own files as the
// install itself judges them (devpack: an un-edited skill copy of any pack
// version; a settings file holding only our hooks, for any watchtower
// binary, and permission rule lists), and a file .worktreeinclude copied in
// that is still byte-identical to its source in the main worktree. Nothing
// is judged by its name alone.
type ignoredJudge struct {
	ctx         context.Context
	root        string
	folder      string // the workbench folder, symlink-resolved
	source      string // the checkout .worktreeinclude copies come from; "" = unknown
	sourceRead  bool
	worktrees   []worktree // the repository's listing, for baseList
	basesRead   bool
	bases       []string // the integration's folders: "" (the root) and the workbench folder's subfolder
	workbenchID int64
	git         gitCmd
	included    []string // what .worktreeinclude copies, read once when needed
	includeRead bool
	skills      map[string]bool // skill folder (rel) -> un-edited copy
	deadline    time.Time
	budget      time.Duration
	seen        int
}

// ignoredWork is the first git-ignored path in the worktree at root that a
// removal would lose, "" when there is none. git lists an ignored folder as
// one entry ("dir/"); such a folder is walked without following symlinks.
// The judgement runs under W9's budget (checked per listing entry, per
// 64 KiB compared and every nestedClockEvery walked entries); over it, or on
// any git or read failure, the result is an error, so the catch keeps the
// worktree (check_failed).
func (b *builder) ignoredWork(ctx context.Context, root string, budget time.Duration) (string, error) {
	out, err := b.repo.git.output(ctx, root, "status", "--porcelain", "-z", "--ignored=matching",
		"--untracked-files=all", "--ignore-submodules=all")
	if err != nil {
		return "", fmt.Errorf("listing the ignored files of %s: %w", root, err)
	}
	j := b.newIgnoredJudge(ctx, root, budget)
	for _, rec := range bytes.Split(out, []byte{0}) {
		entry, ok := bytes.CutPrefix(rec, []byte("!! "))
		if !ok || len(entry) == 0 {
			continue
		}
		if err := j.check(); err != nil {
			return "", err
		}
		found, err := j.entry(string(entry))
		if err != nil || found != "" {
			return found, err
		}
	}
	return "", nil
}

func (b *builder) newIgnoredJudge(ctx context.Context, root string, budget time.Duration) *ignoredJudge {
	j := &ignoredJudge{ctx: ctx, root: root, bases: []string{""}, workbenchID: b.req.WorkbenchID,
		git: b.repo.git, skills: map[string]bool{}, deadline: time.Now().Add(budget), budget: budget}
	j.folder, j.worktrees = b.repo.folder, b.repo.worktrees
	return j
}

// baseList is where the integration lives: the root, and the workbench
// folder's subfolder of its checkout. The checkout is the longest listed
// worktree root holding the folder (independent of the include probe, so a
// failed probe never turns those files into work), confirmed by
// `git rev-parse --show-toplevel` in the folder through the cleanup's own
// runner: a stale entry (its .git gone, kept by a lock) is not taken. When
// it cannot be confirmed no subfolder is added, and subfolder files count
// as work. Read once per worktree, when first needed.
func (j *ignoredJudge) baseList() []string {
	if j.basesRead || j.folder == "" {
		return j.bases
	}
	j.basesRead = true
	holder := ""
	for _, w := range j.worktrees {
		if !w.Prunable && pathWithin(j.folder, w.Root) && len(w.Root) > len(holder) {
			holder = w.Root
		}
	}
	if holder == "" {
		return j.bases
	}
	ctx, cancel := context.WithDeadline(j.ctx, j.deadline)
	defer cancel()
	out, err := j.git.output(ctx, j.folder, "rev-parse", "--show-toplevel")
	if err != nil || resolvePath(strings.TrimSpace(string(out))) != resolvePath(holder) {
		return j.bases
	}
	if rel, err := filepath.Rel(holder, j.folder); err == nil && rel != "." && !strings.HasPrefix(rel, "..") {
		j.bases = append(j.bases, filepath.ToSlash(rel))
	}
	return j.bases
}

// check is the budget and the context, now.
func (j *ignoredJudge) check() error { return nestedWalkLimit(j.ctx, j.deadline, j.budget) }

// tick counts a walked entry and checks every nestedClockEvery, as W9 does.
func (j *ignoredJudge) tick() error {
	j.seen++
	if j.seen%nestedClockEvery == 0 {
		return j.check()
	}
	return nil
}

// entry judges one line of git's listing.
func (j *ignoredJudge) entry(rel string) (string, error) {
	if !strings.HasSuffix(rel, "/") {
		return j.file(rel)
	}
	rel = strings.TrimSuffix(rel, "/")
	info, err := os.Lstat(j.abs(rel))
	if err != nil {
		return "", fmt.Errorf("reading the ignored folder %s: %w", rel, err)
	}
	if !info.IsDir() {
		return j.file(rel)
	}
	cached, err := j.cached(rel, true)
	if err != nil || cached {
		return "", err
	}
	var found string
	var fileErr error
	err = filepath.WalkDir(j.abs(rel), func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if err := j.tick(); err != nil {
			return err
		}
		r, err := filepath.Rel(j.root, p)
		if err != nil {
			return err
		}
		r = filepath.ToSlash(r)
		if d.IsDir() {
			if j.cacheName(r) {
				return fs.SkipDir
			}
			return nil
		}
		if found, fileErr = j.file(r); fileErr != nil || found != "" {
			return errStopWalk
		}
		return nil
	})
	switch {
	case errors.Is(err, errStopWalk):
		return found, fileErr
	case err != nil:
		return "", fmt.Errorf("reading the ignored folder %s: %w", rel, err)
	}
	return "", nil
}

// includeSource is the checkout session worktrees of the workbench folder
// get their .worktreeinclude copies from: workbenchgit.IncludeSource, the
// same probe worktree creation makes, run through the cleanup's own git
// runner (gitCmd: its binary, its per-call timeout) and within the judge's
// budget; symlink-resolved. Read once per worktree, when a copy is first
// in question. A probe that fails leaves it "" (no ignored file passes as
// a copy); one that ran out of the budget is an error (check_failed).
func (j *ignoredJudge) includeSource() (string, error) {
	if j.sourceRead {
		return j.source, nil
	}
	j.sourceRead = true
	ctx, cancel := context.WithDeadline(j.ctx, j.deadline)
	defer cancel()
	g := j.git
	top, err := workbenchgit.IncludeSource(ctx, workbenchgit.Options{
		Folder: j.folder,
		Locate: func() (string, bool) { return g.bin, g.bin != "" },
		Run: func(ctx context.Context, dir string, _ []byte, _ string, args ...string) ([]byte, int, error) {
			ctx, cancel := context.WithTimeout(ctx, gitTimeout)
			defer cancel()
			return g.run.RunGit(ctx, dir, g.bin, args...)
		},
	})
	resolved := ""
	if err == nil {
		resolved = resolvePath(top)
	}
	// The budget counts whatever the probe answered: an overrun is a failed
	// judgement (check_failed), even after a probe that succeeded.
	if budgetErr := j.check(); budgetErr != nil {
		return "", fmt.Errorf("locating the %s source: %w", workbenchgit.IncludeFile, budgetErr)
	}
	j.source = resolved
	return j.source, nil
}

// errStopWalk ends a walk at the first unsaved file or failed judgement.
var errStopWalk = errors.New("stop")

func (j *ignoredJudge) abs(rel string) string { return filepath.Join(j.root, filepath.FromSlash(rel)) }

// cacheAt reports whether parts[i] names a cache: one of W9's at any depth,
// a DerivedData folder of any name by its content within derivedDataDepth
// of the root (#2402 §4), or `build` directly at a root.
func (j *ignoredJudge) cacheAt(parts []string, i int) bool {
	if regenerableCaches[parts[i]] {
		return true
	}
	if i < derivedDataDepth && derivedDataAt(j.abs(strings.Join(parts[:i+1], "/"))) {
		return true
	}
	if parts[i] != topLevelBuild {
		return false
	}
	parent := strings.Join(parts[:i], "/")
	for _, base := range j.baseList() {
		if parent == base {
			return true
		}
	}
	return false
}

// cacheName: some component of rel names a cache (the walk only meets real
// folders, so a name is enough there).
func (j *ignoredJudge) cacheName(rel string) bool {
	parts := strings.Split(rel, "/")
	for i := range parts {
		if j.cacheAt(parts, i) {
			return true
		}
	}
	return false
}

// cached reports whether rel lies in a real cache folder: a component that
// names a cache is a directory, not a symlink or a file (an ancestor checked
// by Lstat; rel itself by selfIsDir, its own Lstat).
func (j *ignoredJudge) cached(rel string, selfIsDir bool) (bool, error) {
	parts := strings.Split(rel, "/")
	for i := range parts {
		if !j.cacheAt(parts, i) {
			continue
		}
		if i == len(parts)-1 {
			return selfIsDir, nil
		}
		info, err := os.Lstat(j.abs(strings.Join(parts[:i+1], "/")))
		if err != nil {
			return false, fmt.Errorf("reading %s: %w", rel, err)
		}
		if info.IsDir() {
			return true, nil
		}
	}
	return false, nil
}

// file returns rel when the ignored entry at rel (not a real folder) is
// unsaved work, "" when a removal loses nothing of it. Only a regular file
// can be ours; a symlink or special file always counts.
func (j *ignoredJudge) file(rel string) (string, error) {
	info, err := os.Lstat(j.abs(rel))
	if err != nil {
		return "", fmt.Errorf("reading the ignored file %s: %w", rel, err)
	}
	if cached, err := j.cached(rel, false); err != nil || cached {
		return "", err
	}
	if !info.Mode().IsRegular() {
		return rel, nil
	}
	if path.Base(rel) == ".DS_Store" {
		return "", nil
	}
	if ok, err := j.integration(rel); err != nil || ok {
		return "", err
	}
	if ok, err := j.includedCopy(rel, info); err != nil || ok {
		return "", err
	}
	return rel, nil
}

// integration: rel is one of the workbench install's files at a base, as
// the install judges it — a skill folder of an exact workbench skill name
// holding an un-edited copy, or a settings.local.json holding only our
// hooks and permission rule lists.
func (j *ignoredJudge) integration(rel string) (bool, error) {
	for _, base := range j.baseList() {
		r, ok := under(base, rel)
		if !ok {
			continue
		}
		if r == ".claude/settings.local.json" {
			ours, err := devpack.SettingsOnlyOurs(j.abs(rel), j.workbenchID)
			if err != nil {
				return false, fmt.Errorf("reading %s: %w", rel, err)
			}
			if ours {
				return true, nil
			}
			continue
		}
		for _, skills := range []string{".claude/skills/", ".agents/skills/"} {
			name, file, ok := strings.Cut(strings.TrimPrefix(r, skills), "/")
			if !strings.HasPrefix(r, skills) || !ok || strings.Contains(file, "/") || !devpack.IsWorkbenchSkillName(name) {
				continue
			}
			dir := strings.TrimSuffix(rel, "/"+file)
			unedited, seen := j.skills[dir]
			if !seen {
				var err error
				if unedited, err = devpack.WorkbenchSkillCopyUnedited(j.abs(dir)); err != nil {
					return false, err
				}
				j.skills[dir] = unedited
			}
			if unedited {
				return true, nil
			}
		}
	}
	return false, nil
}

// includedCopy: rel is a path .worktreeinclude copies (workbenchgit's own
// matcher, run in the source checkout — the one worktree creation copies
// from, workbenchgit.IncludeSource) and the source holds a regular file
// there with the same bytes: a copy nobody changed. Any other ignored file,
// even one equal to another checkout's, is work; so is every one when the
// source cannot be told.
func (j *ignoredJudge) includedCopy(rel string, info fs.FileInfo) (bool, error) {
	source, err := j.includeSource()
	if err != nil || source == "" || source == j.root {
		return false, err
	}
	covered, err := j.includeCovers(rel)
	if err != nil || !covered {
		return false, err
	}
	src := filepath.Join(j.source, filepath.FromSlash(rel))
	sinfo, err := os.Lstat(src)
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("reading %s in the main worktree: %w", rel, err)
	}
	if !sinfo.Mode().IsRegular() || sinfo.Size() != info.Size() {
		return false, nil
	}
	return j.sameBytes(j.abs(rel), src)
}

func (j *ignoredJudge) includeCovers(rel string) (bool, error) {
	if !j.includeRead {
		j.includeRead = true
		list := filepath.Join(j.source, workbenchgit.IncludeFile)
		if _, err := os.Lstat(list); err == nil {
			matched, err := j.lsFiles("--exclude-from=" + list)
			if err != nil {
				return false, err
			}
			ignored, err := j.lsFiles("--exclude-standard")
			if err != nil {
				return false, err
			}
			j.included = workbenchgit.IncludedPaths(matched, ignored)
		} else if !errors.Is(err, fs.ErrNotExist) {
			return false, fmt.Errorf("reading %s: %w", workbenchgit.IncludeFile, err)
		}
	}
	return workbenchgit.IncludeCovers(j.included, rel), nil
}

func (j *ignoredJudge) lsFiles(rule string) ([]string, error) {
	out, err := j.git.output(j.ctx, j.source, workbenchgit.IncludeListArgs(rule)...)
	if err != nil {
		return nil, fmt.Errorf("listing what %s copies: %w", workbenchgit.IncludeFile, err)
	}
	var paths []string
	for _, p := range bytes.Split(out, []byte{0}) {
		if len(p) > 0 {
			paths = append(paths, string(p))
		}
	}
	return paths, nil
}

// sameBytes compares two files 64 KiB at a time, checking the budget
// before each chunk.
func (j *ignoredJudge) sameBytes(a, b string) (bool, error) {
	fa, err := os.Open(a)
	if err != nil {
		return false, err
	}
	defer func() { _ = fa.Close() }()
	fb, err := os.Open(b)
	if err != nil {
		return false, err
	}
	defer func() { _ = fb.Close() }()
	ba, bb := make([]byte, 64<<10), make([]byte, 64<<10)
	for {
		if err := j.check(); err != nil {
			return false, err
		}
		na, ea := io.ReadFull(fa, ba)
		nb, eb := io.ReadFull(fb, bb)
		if na != nb || !bytes.Equal(ba[:na], bb[:nb]) {
			return false, nil
		}
		doneA := errors.Is(ea, io.EOF) || errors.Is(ea, io.ErrUnexpectedEOF)
		doneB := errors.Is(eb, io.EOF) || errors.Is(eb, io.ErrUnexpectedEOF)
		switch {
		case doneA && doneB:
			return true, nil
		case doneA != doneB:
			return false, nil
		case ea != nil:
			return false, ea
		case eb != nil:
			return false, eb
		}
	}
}

// under is rel relative to base ("" = the root), and whether it is inside.
func under(base, rel string) (string, bool) {
	if base == "" {
		return rel, true
	}
	if r, ok := strings.CutPrefix(rel, base+"/"); ok {
		return r, true
	}
	return "", false
}
