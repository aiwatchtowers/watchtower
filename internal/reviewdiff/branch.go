package reviewdiff

import (
	"context"
	"strings"
)

// BranchTip is a branch's committed tip (board #1012): what a round reviews
// when the session's folder is not checked out on the task's branch.
type BranchTip struct {
	Name   string // the branch name as the target carries it
	Ref    string // refs/heads/<name>, else refs/remotes/origin/<name>
	Commit string
	Tree   string
}

// HeadBranch is the branch the folder has checked out; "" when HEAD is
// detached or names no branch. A done context is an error.
func (r *Repo) HeadBranch(ctx context.Context) (string, error) {
	out, err := r.git(ctx, nil, "symbolic-ref", "--quiet", "--short", "HEAD")
	if ctxErr := ctx.Err(); ctxErr != nil {
		return "", ctxErr
	}
	if err != nil {
		return "", nil //nolint:nilerr // a detached HEAD is "no branch", not a failure
	}
	return strings.TrimSpace(string(out)), nil
}

// Branch finds branch name as a local branch, else as origin's; ok false
// when neither exists (or the name could be read as an option). A done
// context is an error, never "missing".
func (r *Repo) Branch(ctx context.Context, name string) (BranchTip, bool, error) {
	if name == "" || strings.HasPrefix(name, "-") {
		return BranchTip{}, false, nil
	}
	for _, ref := range []string{"refs/heads/" + name, "refs/remotes/origin/" + name} {
		commit, ok, err := r.revParse(ctx, ref+"^{commit}")
		if err != nil {
			return BranchTip{}, false, err
		}
		if !ok {
			continue
		}
		tree, ok, err := r.revParse(ctx, commit+"^{tree}")
		if err != nil || !ok {
			return BranchTip{}, false, err
		}
		return BranchTip{Name: name, Ref: ref, Commit: commit, Tree: tree}, true, nil
	}
	return BranchTip{}, false, nil
}

// BranchBase is tip's base: the merge-base with branch baseName (origin's,
// else the local one) when it resolves, else with the default branch as
// Base finds it. No merge-base anywhere → the empty tree, Label "".
func (r *Repo) BranchBase(ctx context.Context, tip BranchTip, baseName string) (Base, error) {
	var refs []string
	if baseName != "" && !strings.HasPrefix(baseName, "-") {
		for _, ref := range []string{"refs/remotes/origin/" + baseName, "refs/heads/" + baseName} {
			if _, ok, err := r.revParse(ctx, ref+"^{commit}"); err != nil {
				return Base{}, err
			} else if ok {
				refs = append(refs, ref)
			}
		}
	}
	refs = append(refs, r.defaultRefs(ctx)...)
	for _, ref := range refs {
		out, err := r.git(ctx, nil, "merge-base", tip.Commit, ref)
		if err == nil {
			return Base{SHA: strings.TrimSpace(string(out)), Label: refLabel(ref)}, nil
		}
	}
	if err := ctx.Err(); err != nil {
		return Base{}, err
	}
	return Base{SHA: EmptyTree}, nil
}

// revParse resolves spec; ok false when it names nothing. A done context is
// an error.
func (r *Repo) revParse(ctx context.Context, spec string) (string, bool, error) {
	out, err := r.git(ctx, nil, "rev-parse", "--verify", "--quiet", spec)
	if ctxErr := ctx.Err(); ctxErr != nil {
		return "", false, ctxErr
	}
	if err != nil {
		return "", false, nil //nolint:nilerr // --verify --quiet fails only for a name that resolves to nothing
	}
	return strings.TrimSpace(string(out)), true, nil
}

func refLabel(ref string) string {
	return strings.TrimPrefix(strings.TrimPrefix(ref, "refs/remotes/"), "refs/heads/")
}
