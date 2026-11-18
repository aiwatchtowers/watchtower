package workbenchgit

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"watchtower/internal/gitbin"
)

// FolderScope is where a requested folder sits relative to the workbench's
// repository.
type FolderScope string

const (
	// ScopeMain: the workbench folder, inside it, or inside the worktree
	// that holds it.
	ScopeMain FolderScope = "main"
	// ScopeWorktree: inside another (linked) worktree of the repository.
	ScopeWorktree FolderScope = "worktree"
	// ScopeOutside: under no listed worktree, or the workbench folder is
	// not in a repository.
	ScopeOutside FolderScope = "outside"
	// ScopeMissing: the requested folder does not exist.
	ScopeMissing FolderScope = "missing"
	// ScopeUnresolved: the worktrees could not be listed — git is
	// unavailable, the listing failed, the workbench folder did not
	// resolve, or the requested folder failed to resolve for a reason
	// other than not existing (permission denied, ErrFolderUnreadable). No
	// verdict: a caller keeps the last known place.
	ScopeUnresolved FolderScope = ""
)

// ErrFolderUnreadable wraps the OS error of a requested folder that failed
// to resolve for a reason other than not existing (a parent that cannot be
// read); no git ran. Its text reads "reading the folder: <OS error>".
var ErrFolderUnreadable = errors.New("reading the folder")

// ResolvedFolder is a requested folder resolved against the workbench
// repository's worktrees. Its fields are the folder keys of the status
// envelope.
type ResolvedFolder struct {
	Requested string      `json:"folder_requested"`
	Scope     FolderScope `json:"folder_scope"`
	// Root is the folder git runs in: the workbench folder for main,
	// outside, missing and unresolved; for a worktree, the worktree's top level joined
	// with the workbench folder's path relative to its own top level when
	// that exists there, else the worktree's top level.
	Root string `json:"folder_root"`
	// WorktreeName is the linked worktree top level's base name, "" for
	// any other scope.
	WorktreeName string `json:"worktree_name"`
	// MainTopLevel is the top level of the worktree holding the workbench
	// folder, "" when git was not asked.
	MainTopLevel string `json:"-"`
	// FolderPath is the workbench folder resolved against: Options.Folder,
	// or the bench folder ResolveFolder chose from Options.Folders.
	FolderPath string `json:"workbench_folder_path"`
}

// OutsideTheRepository reports a folder no git may run in: outside the
// listed worktrees, or missing.
func (f ResolvedFolder) OutsideTheRepository() bool {
	return f.Scope == ScopeOutside || f.Scope == ScopeMissing
}

// ResolveFolder resolves requested against the worktrees of the repository
// holding o.Folder (the workbench folder). With o.Folder "" the workbench
// folder is first chosen from o.Folders without running git
// (benchFolderFor), so one folder's worktrees are listed at most. "" is the
// workbench folder itself. git runs only in o.Folder (`git worktree list`), never in
// requested, and not at all when requested is missing or not absolute, git
// is unavailable, or o.Folder is outside a repository. Without git the
// scope is unresolved and Root the workbench folder, so the caller's own
// git call reports git as unavailable. The error is git, resolving
// o.Folder, or resolving requested for a reason other than not existing
// (an unreadable parent) failing; the scope is then unresolved and Root
// the workbench folder.
func ResolveFolder(ctx context.Context, o Options, requested string) (ResolvedFolder, error) {
	if o.Folder == "" {
		o.Folder = benchFolderFor(o.Folders, requested)
	}
	res := ResolvedFolder{Requested: requested, Scope: ScopeOutside, Root: o.Folder, FolderPath: o.Folder}
	if requested == "" {
		res.Scope = ScopeMain
		return res, nil
	}
	reqReal, scope, err := realRequested(requested)
	if reqReal == "" {
		res.Scope = scope
		return res, err
	}
	r, err := open(o)
	if r == nil { // no git or no repository: no git runs
		res.Scope = scopeWithoutRepo(err)
		return res, nil
	}
	wbReal, err := filepath.EvalSymlinks(o.Folder)
	if err != nil {
		res.Scope = ScopeUnresolved
		return res, err
	}
	out, err := r.git(ctx, "worktree", "list", "--porcelain", "-z")
	if err != nil {
		res.Scope = ScopeUnresolved
		return res, err
	}
	tops := worktreeTops(out)
	reqTop, wbTop := longestContaining(tops, reqReal), longestContaining(tops, wbReal)
	res.MainTopLevel = wbTop
	switch {
	case reqTop != "" && !samePath(reqTop, wbTop):
		res.Scope, res.WorktreeName = ScopeWorktree, filepath.Base(reqTop)
		res.Root = mappedRoot(reqTop, wbTop, wbReal)
	case reqTop != "":
		res.Scope = ScopeMain
	case within(reqReal, wbReal):
		// The listing left out the workbench's own worktree (its entry no
		// longer resolves): the workbench folder is still main.
		res.Scope = ScopeMain
	}
	return res, nil
}

// benchFolderFor is the bench folder requested belongs to: the deepest
// folder holding it; else, for a requested folder in a linked worktree (its
// .git file naming <repository>/.git/worktrees/<name>), the first folder
// inside that repository; else folders[0] (the home folder). A sole folder
// is taken as is; "" for none. No git runs: the caller's one listing, in
// the folder chosen, decides the scope.
func benchFolderFor(folders []string, requested string) string {
	if len(folders) == 0 {
		return ""
	}
	if len(folders) == 1 || !filepath.IsAbs(requested) {
		return folders[0]
	}
	reqReal, err := filepath.EvalSymlinks(requested)
	if err != nil {
		return folders[0]
	}
	reals := make([]string, len(folders))
	best := -1
	for i, f := range folders {
		reals[i] = f
		if r, err := filepath.EvalSymlinks(f); err == nil {
			reals[i] = r
		}
		if within(reqReal, reals[i]) && (best < 0 || len(reals[i]) > len(reals[best])) {
			best = i
		}
	}
	if best >= 0 {
		return folders[best]
	}
	if top := linkedMainTop(reqReal); top != "" {
		for i, f := range folders {
			if within(reals[i], top) {
				return f
			}
		}
	}
	return folders[0]
}

// gitdirFileLimit caps how much of a .git file is read.
const gitdirFileLimit = 4096

// linkedMainTop is the main work tree of the repository whose linked
// worktree holds path, read from the nearest .git entry at or above path;
// "" when that entry is a directory (a main work tree), cannot be read, or
// names no worktree of a .git directory. It reads files only.
func linkedMainTop(path string) string {
	for dir := path; ; {
		entry := filepath.Join(dir, ".git")
		if fi, err := os.Lstat(entry); err == nil {
			if !fi.Mode().IsRegular() {
				return ""
			}
			return mainTopFromGitdirFile(dir, entry)
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return ""
		}
		dir = parent
	}
}

// mainTopFromGitdirFile reads a linked worktree's .git file in dir —
// "gitdir: <top>/.git/worktrees/<name>" — and returns <top> resolved, or "".
func mainTopFromGitdirFile(dir, entry string) string {
	f, err := os.Open(entry)
	if err != nil {
		return ""
	}
	defer f.Close()
	buf := make([]byte, gitdirFileLimit)
	n, _ := io.ReadFull(f, buf) // a short file is the normal case
	line, _, _ := strings.Cut(string(buf[:n]), "\n")
	gitdir, ok := strings.CutPrefix(strings.TrimSpace(line), "gitdir: ")
	if !ok || gitdir == "" {
		return ""
	}
	if !filepath.IsAbs(gitdir) {
		gitdir = filepath.Join(dir, gitdir)
	}
	worktrees := filepath.Dir(filepath.Clean(gitdir))
	common := filepath.Dir(worktrees)
	if filepath.Base(worktrees) != "worktrees" || filepath.Base(common) != ".git" {
		return ""
	}
	top, err := filepath.EvalSymlinks(filepath.Dir(common))
	if err != nil {
		return ""
	}
	return top
}

// scopeWithoutRepo is the scope when open refused: unresolved without git
// (no verdict; the caller's own git call says git is unavailable), outside
// for a workbench folder outside a repository.
func scopeWithoutRepo(openErr error) FolderScope {
	if errors.Is(openErr, gitbin.ErrUnavailable) {
		return ScopeUnresolved
	}
	return ScopeOutside
}

// realRequested is requested with its symlinks resolved, or "" and the
// scope that refuses it: outside when it is not absolute, missing when it
// does not exist. Any other resolution failure (a parent that cannot be
// read) is unresolved with the error: no verdict, since a caller maps
// outside to the main folder.
func realRequested(requested string) (string, FolderScope, error) {
	if !filepath.IsAbs(requested) {
		return "", ScopeOutside, nil
	}
	resolved, err := filepath.EvalSymlinks(requested)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return "", ScopeMissing, nil
	case err != nil:
		return "", ScopeUnresolved, fmt.Errorf("%w: %w", ErrFolderUnreadable, err)
	}
	return resolved, "", nil
}

// worktreeTops reads `git worktree list --porcelain -z` and returns the
// realpath of every worktree that has a work tree on disk: bare and
// prunable entries, and paths that no longer resolve, are left out.
func worktreeTops(porcelainZ []byte) []string {
	var tops []string
	path, usable := "", false
	flush := func() {
		if usable {
			if resolved, err := filepath.EvalSymlinks(path); err == nil {
				tops = append(tops, resolved)
			}
		}
		path, usable = "", false
	}
	for field := range bytes.SplitSeq(porcelainZ, []byte{0}) {
		f := string(field)
		switch {
		case strings.HasPrefix(f, "worktree "):
			flush()
			path, usable = strings.TrimPrefix(f, "worktree "), true
		case f == "bare", f == "prunable", strings.HasPrefix(f, "prunable "):
			usable = false
		}
	}
	flush()
	return tops
}

// longestContaining is the longest top that is path or one of its
// parents, "" for none.
func longestContaining(tops []string, path string) string {
	best := ""
	for _, top := range tops {
		if within(path, top) && len(top) > len(best) {
			best = top
		}
	}
	return best
}

// within reports whether path is base or below it; both are clean
// absolute paths, compared as the file system does (samePath).
func within(path, base string) bool {
	if samePath(path, base) {
		return true
	}
	if !strings.HasSuffix(base, string(filepath.Separator)) {
		base += string(filepath.Separator)
	}
	return len(path) > len(base) && samePath(path[:len(base)], base)
}

// samePath compares two paths the way the file system does: equal
// strings are the same path; strings that differ only in case are the same
// path only when both name one directory on disk (a case-insensitive
// volume, the macOS default). On a case-sensitive volume /x/WT and /x/wt
// are two folders, and any doubt (either fails to stat) answers no.
func samePath(a, b string) bool {
	if a == b {
		return true
	}
	return strings.EqualFold(a, b) && sameDirectory(a, b)
}

// sameDirectory reports whether a and b name one existing file; a seam for
// the tests, which cannot make a case-sensitive volume.
var sameDirectory = func(a, b string) bool {
	fa, err := os.Stat(a)
	if err != nil {
		return false
	}
	fb, err := os.Stat(b)
	return err == nil && os.SameFile(fa, fb)
}

// mappedRoot maps a workbench in a repository subfolder into the worktree
// at top: top joined with the workbench's path below its own top level
// when that directory exists there, else top.
func mappedRoot(top, wbTop, wbReal string) string {
	if wbTop == "" || samePath(wbTop, wbReal) {
		return top
	}
	// within(wbReal, wbTop) holds: the rest of wbReal is the path below it,
	// whatever case either is spelt in.
	rel := strings.TrimPrefix(wbReal[len(wbTop):], string(filepath.Separator))
	if fi, err := os.Stat(filepath.Join(top, rel)); err == nil && fi.IsDir() {
		return filepath.Join(top, rel)
	}
	return top
}

// FolderRefusal is why a branches, switch or create call may not use the
// folder asked for: a folder that could not be read, a failed worktree
// listing or a folder outside the repository's worktrees. "" = go ahead.
func FolderRefusal(folder ResolvedFolder, resolveErr error) (refused, detail string) {
	switch {
	case errors.Is(resolveErr, ErrFolderUnreadable):
		return RefusedFolderUnreadable, resolveErr.Error()
	case resolveErr != nil:
		return RefusedGitFailed, "listing the worktrees: " + resolveErr.Error()
	case folder.OutsideTheRepository():
		return RefusedFolderNotAWorktree, string(folder.Scope)
	}
	return "", ""
}
