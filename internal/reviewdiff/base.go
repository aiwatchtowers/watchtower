package reviewdiff

import (
	"context"
	"strings"
)

type Base struct {
	SHA   string `json:"base_sha"`
	Label string `json:"base_label"`
}

// Base is the merge-base of HEAD with the default branch, found as
// workbenchcheck finds it: origin/HEAD's target, else main, else master,
// each tried as refs/remotes/origin/<n> then refs/heads/<n>. No commit, no
// default branch or no merge-base → the empty tree, Label "". A done context
// is an error, never the empty tree.
func (r *Repo) Base(ctx context.Context) (Base, error) {
	head, err := r.hasHead(ctx)
	if err != nil {
		return Base{}, err
	}
	if !head {
		return Base{SHA: EmptyTree}, nil
	}
	for _, ref := range r.defaultRefs(ctx) {
		out, err := r.git(ctx, nil, "merge-base", "HEAD", ref)
		if err == nil {
			label := strings.TrimPrefix(strings.TrimPrefix(ref, "refs/remotes/"), "refs/heads/")
			return Base{SHA: strings.TrimSpace(string(out)), Label: label}, nil
		}
	}
	if err := ctx.Err(); err != nil {
		return Base{}, err
	}
	return Base{SHA: EmptyTree}, nil
}

func (r *Repo) defaultRefs(ctx context.Context) []string {
	var names []string
	if out, err := r.git(ctx, nil, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"); err == nil {
		names = append(names, strings.TrimPrefix(strings.TrimSpace(string(out)), "refs/remotes/origin/"))
	}
	names = append(names, "main", "master")
	var refs []string
	for _, n := range names {
		for _, ref := range []string{"refs/remotes/origin/" + n, "refs/heads/" + n} {
			if _, err := r.git(ctx, nil, "rev-parse", "--verify", "--quiet", ref+"^{commit}"); err == nil {
				refs = append(refs, ref)
			}
		}
	}
	return refs
}
