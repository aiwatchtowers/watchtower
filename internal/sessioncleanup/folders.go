package sessioncleanup

import (
	"context"
	"errors"
	"fmt"
	"slices"

	"watchtower/internal/gitbin"
)

// detailFolderLeft is the keep detail of what a session cleanup leaves in a
// folder that left the bench: only the worktrees the session's own ledger
// recorded can go there (PROJ-18, multi-folder amendment #2003).
const detailFolderLeft = "its folder left the bench"

// evaluationBuilders are the evaluations of one request: a session's one,
// over its folder's repository, or a sweep's one per repository of the
// bench (sweepBuilders).
func evaluationBuilders(ctx context.Context, d Deps, r Request) ([]*builder, error) {
	if r.Sweep && r.folder == "" && d.DB != nil {
		return sweepBuilders(ctx, d, r)
	}
	b, err := newBuilder(ctx, d, r)
	if err != nil {
		return nil, err
	}
	return []*builder{b}, nil
}

// sweepBuilders are the owner's sweep over every live folder of the bench
// (spec 2026-11-18 §6.9): the home folder's part first, with the keys it
// always had, then one part per other repository, its branch keys carrying
// its folder (branchKey). A folder over a repository already covered adds
// only its stale LaunchServices entries to that part; a folder other than
// home that is in no repository has nothing to clean up and is skipped.
// Any other failure fails the sweep, as for one folder.
func sweepBuilders(ctx context.Context, d Deps, r Request) ([]*builder, error) {
	if r.WorkbenchID == 0 {
		return nil, errors.New("session cleanup: a sweep needs a workbench")
	}
	folders, err := d.DB.BenchFolders(ctx, r.WorkbenchID)
	if err != nil {
		return nil, fmt.Errorf("reading workbench %d folders: %w", r.WorkbenchID, err)
	}
	var parts []*builder
	byRepo := map[string]*builder{}
	for i, f := range folders {
		folder := resolvePath(f)
		if i > 0 && !gitbin.InsideRepository(folder) {
			continue
		}
		sub := r
		sub.folder = folder
		if i > 0 {
			sub.keyFolder = folder
		}
		b, err := newBuilder(ctx, d, sub)
		if err != nil {
			return nil, err
		}
		if first, ok := byRepo[b.repo.commonDir]; ok {
			first.req.staleUnder = append(first.req.staleUnder, folder)
			continue
		}
		if len(parts) > 0 {
			b.report = parts[0].report // one Observer, called by one part at a time
		}
		byRepo[b.repo.commonDir] = b
		parts = append(parts, b)
	}
	if len(parts) == 0 {
		return nil, fmt.Errorf("session cleanup: workbench %d has no folder", r.WorkbenchID)
	}
	return parts, nil
}

// reportListing reports the candidates of every part as one Listed: the
// Desktop takes a Listed as the whole list.
func reportListing(parts []*builder) {
	if parts[0].report.obs == nil {
		return
	}
	var items []Item
	for _, b := range parts {
		items = append(items, b.listing()...)
	}
	if items == nil {
		items = []Item{}
	}
	parts[0].report.listed(items)
}

// branchKey is a branch item's key: "branch:<name>", or in a sweep part of
// a folder other than home "branch:<folder>:<name>" (a refname has no ':',
// an absolute folder starts with '/', so the two never meet).
func (b *builder) branchKey(name string) string {
	if b.req.keyFolder == "" {
		return "branch:" + name
	}
	return "branch:" + b.req.keyFolder + ":" + name
}

// mergePlans is the parts' plans as one: their items in part order, the
// home part's default branch, every note once.
func mergePlans(plans []Plan) Plan {
	out := Plan{Items: []Item{}, Notes: []string{}}
	for i, p := range plans {
		if i == 0 {
			out.DefaultBranch = p.DefaultBranch
		}
		out.Items = append(out.Items, p.Items...)
		for _, n := range p.Notes {
			if !slices.Contains(out.Notes, n) {
				out.Notes = append(out.Notes, n)
			}
		}
	}
	return out
}

// dropForeignNotInPlan: each part of a sweep's apply lists the named keys
// it does not have as not_in_plan; a key another part has is not one, and
// a key no part has is listed once.
func dropForeignNotInPlan(items []Item) []Item {
	have := map[string]bool{}
	for _, it := range items {
		if it.Reason != ReasonNotInPlan {
			have[it.Key] = true
		}
	}
	out := items[:0]
	for _, it := range items {
		if it.Reason == ReasonNotInPlan {
			if have[it.Key] {
				continue
			}
			have[it.Key] = true
		}
		out = append(out, it)
	}
	return out
}
