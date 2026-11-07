package reviewdiff

import (
	"context"
	"strings"
)

type Base struct {
	SHA   string `json:"base_sha"`
	Label string `json:"base_label"`
}

// NoCommonBase is a base's Label when the base branches exist but share no
// history with the reviewed commit: the base is the empty tree, so every
// file reads as added. An empty Label with the empty tree means there was
// no commit or no base branch to measure against.
const NoCommonBase = "no common base"

// Base is the merge-base of HEAD with the default branch, found as
// workbenchcheck finds it: origin/HEAD's target, else main, else master,
// each tried as refs/remotes/origin/<n> then refs/heads/<n>. No commit or no
// default branch → the empty tree, Label ""; no merge-base → the empty tree,
// Label NoCommonBase. A done context or a failing git is an error, never
// the empty tree.
func (r *Repo) Base(ctx context.Context) (Base, error) {
	return r.HeadBase(ctx, "")
}

// HeadBase is Base measured first against branch baseName (origin's, else
// the local one) when it resolves — the base rule of a branch tip
// (BranchBase), for a folder checked out on the task branch (board #1012).
// baseName "" = the default branch only.
func (r *Repo) HeadBase(ctx context.Context, baseName string) (Base, error) {
	head, err := r.hasHead(ctx)
	if err != nil {
		return Base{}, err
	}
	if !head {
		return Base{SHA: EmptyTree}, nil
	}
	return r.baseOf(ctx, "HEAD", baseName)
}

// baseOf is commit's merge-base with the first of baseName's refs and the
// default refs that shares history with it.
func (r *Repo) baseOf(ctx context.Context, commit, baseName string) (Base, error) {
	var refs []string
	if baseName != "" && !strings.HasPrefix(baseName, "-") {
		for _, ref := range []string{"refs/remotes/origin/" + baseName, "refs/heads/" + baseName} {
			_, ok, err := r.revParse(ctx, ref+"^{commit}")
			if err != nil {
				return Base{}, err
			}
			if ok {
				refs = append(refs, ref)
			}
		}
	}
	defaults, err := r.defaultRefs(ctx)
	if err != nil {
		return Base{}, err
	}
	refs = append(refs, defaults...)
	for _, ref := range refs {
		sha, ok, err := r.mergeBase(ctx, commit, ref)
		if err != nil {
			return Base{}, err
		}
		if ok {
			return Base{SHA: sha, Label: refLabel(ref)}, nil
		}
	}
	if len(refs) == 0 {
		return Base{SHA: EmptyTree}, nil
	}
	return Base{SHA: EmptyTree, Label: NoCommonBase}, nil
}

// mergeBase is a and b's merge-base; ok false only when git says they share
// no history (exit 1). A done context is an error.
func (r *Repo) mergeBase(ctx context.Context, a, b string) (string, bool, error) {
	out, err := r.git(ctx, nil, "merge-base", a, b)
	if ctxErr := ctx.Err(); ctxErr != nil {
		return "", false, ctxErr
	}
	if exitedWith(err, 1) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return strings.TrimSpace(string(out)), true, nil
}

// defaultNames are the default branch's candidate names, best first:
// origin/HEAD's target, then main, then master.
func (r *Repo) defaultNames(ctx context.Context) ([]string, error) {
	var names []string
	out, err := r.git(ctx, nil, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD")
	if ctxErr := ctx.Err(); ctxErr != nil {
		return nil, ctxErr
	}
	switch {
	case err == nil:
		names = append(names, strings.TrimPrefix(strings.TrimSpace(string(out)), "refs/remotes/origin/"))
	case !exitedWith(err, 1): // 1: origin/HEAD is missing or not symbolic
		return nil, err
	}
	return append(names, "main", "master"), nil
}

// defaultRefs are the default branch's refs that exist, best first, each
// name tried as origin's then the local branch.
func (r *Repo) defaultRefs(ctx context.Context) ([]string, error) {
	names, err := r.defaultNames(ctx)
	if err != nil {
		return nil, err
	}
	var refs []string
	for _, n := range names {
		for _, ref := range []string{"refs/remotes/origin/" + n, "refs/heads/" + n} {
			_, ok, err := r.revParse(ctx, ref+"^{commit}")
			if err != nil {
				return nil, err
			}
			if ok {
				refs = append(refs, ref)
			}
		}
	}
	return refs, nil
}

// DefaultBranch is the name of the default branch as Base finds it — the
// first of origin/HEAD's target, main and master that exists on origin or
// locally; "" when none does.
func (r *Repo) DefaultBranch(ctx context.Context) (string, error) {
	refs, err := r.defaultRefs(ctx)
	if err != nil || len(refs) == 0 {
		return "", err
	}
	return strings.TrimPrefix(refLabel(refs[0]), "origin/"), nil
}
