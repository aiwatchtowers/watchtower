package workbenchgit

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// RefusedUnborn is the refusal for a repository with no commit to cut a
// worktree branch from.
const RefusedUnborn = "unborn"

// worktreesDir is where session worktrees live, relative to the top level;
// worktreeExcludeLine keeps them out of the main folder's git status.
const (
	worktreesDir        = ".claude/worktrees"
	worktreeExcludeLine = "/.claude/worktrees/"
	worktreeBranchRoot  = "wt/"
	maxSlug             = 40
)

var slugPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*$`)

// WorktreeRequest is one `workbench worktree create`.
type WorktreeRequest struct {
	Slug string // already ASCII-folded by the caller; validated here
	// Taken are wt/… branch names a session row still holds: never handed
	// out again, even once their branch and directory are gone, so a resume
	// of that row never lands in another session's worktree.
	Taken []string
}

// WorktreeResult is the `workbench worktree create` and `ensure` envelope.
type WorktreeResult struct {
	WorkbenchID     int64    `json:"workbench_id"`
	Created         bool     `json:"created"`
	Path            string   `json:"path"`        // the worktree's top level
	Cwd             string   `json:"cwd"`         // Path + the workbench folder's prefix
	Branch          string   `json:"branch"`      // wt/<slug>
	Base            string   `json:"base"`        // full commit id
	BaseBranch      string   `json:"base_branch"` // "" when detached
	BaseDirty       bool     `json:"base_dirty"`
	Included        []string `json:"included"`
	IncludeWarnings []string `json:"include_warnings"`
	Refused         string   `json:"refused"`
	RefusedDetail   string   `json:"refused_detail"`
	Error           string   `json:"error"`
	Warning         string   `json:"warning"`
}

// CreateWorktree checks out a new branch wt/<slug> from the folder's HEAD
// in <top level>/.claude/worktrees/<slug> (a taken name — an existing
// branch or directory, or one in req.Taken — gets -2, -3, …),
// keeps that directory out of the main folder's status, and copies the
// .worktreeinclude paths into it. A failure after the worktree exists is a
// Warning: the worktree is returned and usable (spec §5).
func CreateWorktree(ctx context.Context, o Options, req WorktreeRequest) (res WorktreeResult) {
	res = WorktreeResult{Included: []string{}, IncludeWarnings: []string{}}
	if !slugPattern.MatchString(req.Slug) || len(req.Slug) > maxSlug {
		res.Refused, res.RefusedDetail = RefusedInvalidName, "a slug is lowercase letters, digits and dashes, at most 40"
		return res
	}
	st, r := readStatus(ctx, o)
	switch {
	case !st.GitAvailable:
		res.Refused = RefusedGitUnavailable
		return res
	case r == nil:
		res.Refused = RefusedNotGit
		return res
	case !st.StatusOK:
		res.Refused, res.Error = RefusedGitFailed, st.StatusError
		return res
	case st.Unborn:
		res.Refused = RefusedUnborn
		return res
	}
	p := paths{topLevel: st.TopLevel, gitDir: st.GitDir, commonDir: st.CommonDir}
	base, err := r.git(ctx, "rev-parse", "--verify", "HEAD^{commit}")
	if err != nil {
		res.Refused, res.Error = RefusedGitFailed, gitError(err)
		return res
	}
	prefix, err := r.git(ctx, "rev-parse", "--show-prefix")
	if err != nil {
		res.Refused, res.Error = RefusedGitFailed, gitError(err)
		return res
	}
	res.Base, res.BaseBranch, res.BaseDirty = strings.TrimSpace(string(base)), st.Branch, st.Dirty
	slug, err := r.freeSlug(ctx, p.topLevel, req.Slug, req.Taken)
	if err != nil {
		res.Refused, res.Error = RefusedGitFailed, gitError(err)
		return res
	}
	res.Branch = worktreeBranchRoot + slug
	res.Path = filepath.Join(p.topLevel, filepath.FromSlash(worktreesDir), slug)
	if err := ensureExcludeLine(p.commonDir, worktreeExcludeLine); err != nil {
		res.Warning = clip("adding the exclude line: " + err.Error())
	}
	if _, err := r.git(ctx, "worktree", "add", "-b", res.Branch, res.Path, res.Base); err != nil {
		res.Error = gitError(err)
		return res
	}
	res.Created = true
	rel := strings.TrimSuffix(strings.TrimSpace(string(prefix)), "/")
	res.Cwd = filepath.Join(res.Path, filepath.FromSlash(rel))
	if _, err := os.Lstat(res.Cwd); errors.Is(err, fs.ErrNotExist) {
		// A subfolder workbench whose folder holds no committed file: the
		// session still needs its cwd.
		if mkErr := os.MkdirAll(res.Cwd, 0o755); mkErr != nil {
			res.Warning = joinWarning(res.Warning, "creating the workbench folder "+rel+": "+mkErr.Error())
		} else {
			res.Warning = joinWarning(res.Warning, "the workbench folder "+rel+" is not in the commit; created it empty")
		}
	}
	res.Included, res.IncludeWarnings = includeInto(ctx, r, p, res.Path)
	return res
}

// joinWarning appends next to an earlier warning.
func joinWarning(prev, next string) string {
	if prev == "" {
		return clip(next)
	}
	return clip(prev + "; " + next)
}

// freeSlug is slug, or slug-2, slug-3, … (the base trimmed so the name
// stays within maxSlug) — the first whose branch and directory are both
// free and whose branch no session row holds (taken).
func (r *repo) freeSlug(ctx context.Context, top, slug string, taken []string) (string, error) {
	held := make(map[string]bool, len(taken))
	for _, b := range taken {
		held[b] = true
	}
	for n := 1; n < 1000; n++ {
		cand := slug
		if n > 1 {
			suffix := fmt.Sprintf("-%d", n)
			cand = strings.TrimRight(slug[:min(len(slug), maxSlug-len(suffix))], "-") + suffix
		}
		if held[worktreeBranchRoot+cand] {
			continue
		}
		_, code, err := r.run(ctx, "show-ref", "--verify", "--quiet", "refs/heads/"+worktreeBranchRoot+cand)
		if err != nil && code != 1 {
			return "", err
		}
		if code == 0 {
			continue
		}
		if _, statErr := os.Lstat(filepath.Join(top, filepath.FromSlash(worktreesDir), cand)); statErr == nil {
			continue
		}
		return cand, nil
	}
	return "", fmt.Errorf("no free name for %s", slug)
}

// ensureExcludeLine appends line to <commonDir>/info/exclude unless a line
// equal to it is already there; the owner's lines are never rewritten.
func ensureExcludeLine(commonDir, line string) error {
	file := filepath.Join(commonDir, "info", "exclude")
	raw, err := os.ReadFile(file)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	for _, l := range strings.Split(string(raw), "\n") {
		if strings.TrimSpace(l) == line {
			return nil
		}
	}
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(file, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	prefix := ""
	if len(raw) > 0 && !strings.HasSuffix(string(raw), "\n") {
		prefix = "\n"
	}
	_, werr := f.WriteString(prefix + "# watchtower: session worktrees\n" + line + "\n")
	if cerr := f.Close(); werr == nil {
		werr = cerr
	}
	return werr
}

// EnsureWorktree puts a placed session's worktree back at path from its
// branch — a resume after #535's cleanup removed it, or after the owner
// deleted the directory (spec §7) — and copies the include paths again. An
// existing directory at path is left alone (Created false, no error); a
// missing branch is RefusedUnknownBranch. It writes nothing but the new
// worktree: no remove, reset or checkout, and no force flag.
func EnsureWorktree(ctx context.Context, o Options, path, branch string) (res WorktreeResult) {
	res = WorktreeResult{Path: path, Branch: branch, Included: []string{}, IncludeWarnings: []string{}}
	st, r := readStatus(ctx, o)
	switch {
	case !st.GitAvailable:
		res.Refused = RefusedGitUnavailable
		return res
	case r == nil:
		res.Refused = RefusedNotGit
		return res
	case !st.StatusOK:
		res.Refused, res.Error = RefusedGitFailed, st.StatusError
		return res
	}
	root := filepath.Join(st.TopLevel, filepath.FromSlash(worktreesDir))
	if filepath.Dir(filepath.Clean(path)) != root || !strings.HasPrefix(branch, worktreeBranchRoot) {
		res.Refused, res.RefusedDetail = RefusedInvalidName, "not a session worktree: "+path
		return res
	}
	if _, err := os.Lstat(path); err == nil {
		return res
	}
	if _, code, err := r.run(ctx, "show-ref", "--verify", "--quiet", "refs/heads/"+branch); code == 1 {
		res.Refused, res.RefusedDetail = RefusedUnknownBranch, branch
		return res
	} else if err != nil {
		res.Refused, res.Error = RefusedGitFailed, gitError(err)
		return res
	}
	// A directory deleted by hand leaves its admin entry, and `worktree add`
	// refuses a registered path (--force is never used), so stale entries go
	// first. `worktree prune` drops every prunable entry, not only ours, which
	// is acceptable here only because a prunable entry is one whose directory
	// is already gone: nothing on disk is touched.
	if _, err := r.git(ctx, "worktree", "prune"); err != nil {
		res.Error = gitError(err)
		return res
	}
	if _, err := r.git(ctx, "worktree", "add", path, branch); err != nil {
		res.Error = gitError(err)
		return res
	}
	res.Created = true
	p := paths{topLevel: st.TopLevel, gitDir: st.GitDir, commonDir: st.CommonDir}
	res.Included, res.IncludeWarnings = includeInto(ctx, r, p, path)
	return res
}
