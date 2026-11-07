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
// detached (git's exit 1) or names no local branch. It reads the full ref,
// so a tag of the same name never makes it "heads/<name>". A done context
// or any other git failure is an error.
func (r *Repo) HeadBranch(ctx context.Context) (string, error) {
	out, err := r.git(ctx, nil, "symbolic-ref", "--quiet", "HEAD")
	if ctxErr := ctx.Err(); ctxErr != nil {
		return "", ctxErr
	}
	if exitedWith(err, 1) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	name, ok := strings.CutPrefix(strings.TrimSpace(string(out)), "refs/heads/")
	if !ok {
		return "", nil
	}
	return name, nil
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
// Base finds it. No merge-base anywhere → the empty tree, Label
// NoCommonBase; no base branch at all → the empty tree, Label "".
func (r *Repo) BranchBase(ctx context.Context, tip BranchTip, baseName string) (Base, error) {
	return r.baseOf(ctx, tip.Commit, baseName)
}

// revParse resolves spec; ok false when it names nothing (git's exit 1). A
// done context or any other git failure is an error.
func (r *Repo) revParse(ctx context.Context, spec string) (string, bool, error) {
	out, err := r.git(ctx, nil, "rev-parse", "--verify", "--quiet", spec)
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

func refLabel(ref string) string {
	return strings.TrimPrefix(strings.TrimPrefix(ref, "refs/remotes/"), "refs/heads/")
}
