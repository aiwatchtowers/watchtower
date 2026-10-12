package workbenchgit

import (
	"bytes"
	"context"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
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
	// not in a repository (or git is unavailable).
	ScopeOutside FolderScope = "outside"
	// ScopeMissing: the requested folder does not exist.
	ScopeMissing FolderScope = "missing"
)

// ResolvedFolder is a requested folder resolved against the workbench
// repository's worktrees. Its fields are the folder keys of the status
// envelope.
type ResolvedFolder struct {
	Requested string      `json:"folder_requested"`
	Scope     FolderScope `json:"folder_scope"`
	// Root is the folder git runs in: the workbench folder for main,
	// outside and missing; for a worktree, the worktree's top level joined
	// with the workbench folder's path relative to its own top level when
	// that exists there, else the worktree's top level.
	Root string `json:"folder_root"`
	// WorktreeName is the linked worktree top level's base name, "" for
	// any other scope.
	WorktreeName string `json:"worktree_name"`
	// MainTopLevel is the top level of the worktree holding the workbench
	// folder, "" when git was not asked.
	MainTopLevel string `json:"-"`
}

// OutsideTheRepository reports a folder no git may run in: outside the
// listed worktrees, or missing.
func (f ResolvedFolder) OutsideTheRepository() bool {
	return f.Scope == ScopeOutside || f.Scope == ScopeMissing
}

// ResolveFolder resolves requested against the worktrees of the repository
// holding o.Folder (the workbench folder). "" is the workbench folder
// itself. git runs only in o.Folder (`git worktree list`), never in
// requested, and not at all when requested is missing or not absolute, or
// o.Folder is outside a repository. The error is git itself failing;
// the result's Root is then the workbench folder.
func ResolveFolder(ctx context.Context, o Options, requested string) (ResolvedFolder, error) {
	res := ResolvedFolder{Requested: requested, Scope: ScopeOutside, Root: o.Folder}
	if requested == "" {
		res.Scope = ScopeMain
		return res, nil
	}
	reqReal, scope := realRequested(requested)
	if reqReal == "" {
		res.Scope = scope
		return res, nil
	}
	r, _ := open(o)
	if r == nil { // git unavailable or no repository: no git runs
		return res, nil
	}
	wbReal, err := filepath.EvalSymlinks(o.Folder)
	if err != nil {
		return res, err
	}
	out, err := r.git(ctx, "worktree", "list", "--porcelain", "-z")
	if err != nil {
		res.Scope = ""
		return res, err
	}
	tops := worktreeTops(out)
	reqTop, wbTop := longestContaining(tops, reqReal), longestContaining(tops, wbReal)
	res.MainTopLevel = wbTop
	switch {
	case reqTop != "" && reqTop != wbTop:
		res.Scope, res.WorktreeName = ScopeWorktree, filepath.Base(reqTop)
		res.Root = mappedRoot(reqTop, wbTop, wbReal)
	case reqTop != "" || within(reqReal, wbReal):
		res.Scope = ScopeMain
	}
	return res, nil
}

// realRequested is requested with its symlinks resolved, or "" and the
// scope that refuses it: missing when it does not exist, outside when it is
// not absolute or cannot be resolved.
func realRequested(requested string) (string, FolderScope) {
	if !filepath.IsAbs(requested) {
		return "", ScopeOutside
	}
	resolved, err := filepath.EvalSymlinks(requested)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return "", ScopeMissing
	case err != nil:
		return "", ScopeOutside
	}
	return resolved, ""
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
	for _, field := range bytes.Split(porcelainZ, []byte{0}) {
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
// absolute paths.
func within(path, base string) bool {
	if path == base {
		return true
	}
	if !strings.HasSuffix(base, string(filepath.Separator)) {
		base += string(filepath.Separator)
	}
	return strings.HasPrefix(path, base)
}

// mappedRoot maps a workbench in a repository subfolder into the worktree
// at top: top joined with the workbench's path below its own top level
// when that directory exists there, else top.
func mappedRoot(top, wbTop, wbReal string) string {
	if wbTop == "" {
		return top
	}
	rel, err := filepath.Rel(wbTop, wbReal)
	if err != nil || rel == "." {
		return top
	}
	if fi, err := os.Stat(filepath.Join(top, rel)); err == nil && fi.IsDir() {
		return filepath.Join(top, rel)
	}
	return top
}
