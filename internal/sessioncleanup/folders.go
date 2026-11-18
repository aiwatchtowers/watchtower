package sessioncleanup

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"slices"
	"strings"

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
// (spec 2026-11-18 §6.9): one part per repository, the home folder's first.
// A bench of one folder keeps the keys it always had and fails as before
// when that folder is in no repository. On a bench of several folders every
// branch key carries its part's folder (branchKey), home included, so a key
// is bound to one repository: a selection from an older plan never matches
// a branch of another repository (the home moved, a folder left). There a
// folder that is missing or in no repository is skipped with a plan note,
// and the sweep fails only when no repository is left. A folder over a
// repository already covered adds only its stale LaunchServices entries to
// that part. Any other failure fails the sweep, as for one folder.
func sweepBuilders(ctx context.Context, d Deps, r Request) ([]*builder, error) {
	if r.WorkbenchID == 0 {
		return nil, errors.New("session cleanup: a sweep needs a workbench")
	}
	folders, err := d.DB.BenchFolders(ctx, r.WorkbenchID)
	if err != nil {
		return nil, fmt.Errorf("reading workbench %d folders: %w", r.WorkbenchID, err)
	}
	if len(folders) <= 1 {
		// The home folder is pinned, so the apply's re-checks read the
		// repository its deletes run in (benchFolderGone); the keys stay
		// unqualified.
		if len(folders) == 1 {
			r.folder = resolvePath(folders[0])
		}
		b, err := newBuilder(ctx, d, r)
		if err != nil {
			return nil, err
		}
		return []*builder{b}, nil
	}
	var parts []*builder
	var notes []string
	byRepo := map[string]*builder{}
	for _, f := range folders {
		folder := resolvePath(f)
		if note := unsweptNote(folder); note != "" {
			notes = append(notes, note)
			continue
		}
		sub := r
		sub.folder, sub.keyFolder = folder, folder
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
		return nil, fmt.Errorf("session cleanup: no folder of workbench %d is in a git repository: %s",
			r.WorkbenchID, strings.Join(notes, "; "))
	}
	parts[0].notes = append(parts[0].notes, notes...)
	return parts, nil
}

// benchFolderGone fails a sweep's re-check whose pinned folder is no longer
// a live folder of the bench (it left, or another folder became the home of
// a one-folder bench): the evaluation read that folder's repository, so
// nothing is acted on against another one (fail closed). A session's
// re-check, and a request with no pinned folder, pass.
func benchFolderGone(ctx context.Context, d Deps, r Request) error {
	if !r.Sweep || r.folder == "" {
		return nil
	}
	folders, err := d.DB.BenchFolders(ctx, r.WorkbenchID)
	if err != nil {
		return fmt.Errorf("reading workbench %d folders: %w", r.WorkbenchID, err)
	}
	for _, f := range folders {
		if resolvePath(f) == r.folder {
			return nil
		}
	}
	return fmt.Errorf("%s is no longer a folder of workbench %d", r.folder, r.WorkbenchID)
}

// unsweptNote is the plan note of a bench folder the sweep skips: missing
// on disk, or in no git repository; "" when it is swept.
func unsweptNote(folder string) string {
	if _, err := os.Stat(folder); errors.Is(err, fs.ErrNotExist) {
		return folder + ": missing, not swept"
	}
	if !gitbin.InsideRepository(folder) {
		return folder + ": not a repository, not swept"
	}
	return ""
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
// a bench of several folders "branch:<folder>:<name>" (a refname has no ':',
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
