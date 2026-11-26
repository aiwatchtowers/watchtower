package sessioncleanup

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"slices"
	"sync"
	"time"
)

// The repository pass (#2402 §2, owner decision in ask #1850): after the
// session applies, the automatic pass also reaches the linked worktrees no
// ended session owns — Claude Code's agent-* worktrees without a record,
// worktrees older than the session that saw them or of a session gone for
// longer than autoWindow, idle locked plan worktrees. Once per distinct
// repository of the workbenches' folders (keyed by its git common dir,
// under its cleanup lock, only tried), it plans the idle worktrees under
// the main checkout's .claude/worktrees that no session works in, in sweep
// mode (the owner's Clean Up catches, which judge a worktree without a
// session), removes those that may go by name, with their branch when it
// may go too, and prunes the build output of those it keeps for their work
// (pruneReasons) — each re-checked right before, as every removal is. It
// signals no process and writes no session row.
const (
	// sessionApplyBudget and repoPassBudget bound AutoRun's two parts, each
	// from its own start: the daemon's budget is their sum.
	sessionApplyBudget = 10 * time.Minute
	repoPassBudget     = 10 * time.Minute
	// sweepBatch is how many worktrees one repository pass removes at most
	// per repository, and how many it evaluates under one hold of the
	// repository's lock: the oldest activity first, the rest wait.
	sweepBatch = 20
)

// claudeWorktreesDir is where Watchtower's placement and Claude Code's
// `isolation: worktree` create worktrees, relative to the main checkout:
// the only folder the repository pass looks in. Elsewhere a worktree may
// be one the owner made and works in by hand.
var claudeWorktreesDir = filepath.Join(".claude", "worktrees")

// passRepo is one repository the pass covers.
type passRepo struct {
	key string // its git common dir, the cleanup lock's key
	// folder is a live bench folder in it (symlink-resolved) and
	// workbenchID that folder's workbench: the sweep evaluates through
	// them, and a re-check fails once the folder left that bench.
	folder      string
	workbenchID int64
	// benches is every workbench with a folder in it: their sessions'
	// ledgers count as owners (the sweep's W2).
	benches []int64
}

// repositoryPass is AutoRun's second part: the repository pass of every
// repository of the workbenches' folders, one after the other, counted in
// out. A workbench whose folders cannot be read is a failure that leaves
// the others alone; when ctx is done the pass stops with ctx's error and
// the next pass starts again from scratch.
func (ad AutoDeps) repositoryPass(ctx context.Context, out *AutoResult) error {
	wbs, err := ad.Workbenches(ctx)
	if err != nil {
		return fmt.Errorf("listing the workbenches for the repository pass: %w", err)
	}
	repos := ad.passRepos(ctx, wbs, out)
	for _, rp := range repos {
		if err := ctx.Err(); err != nil {
			return fmt.Errorf("the repository pass stopped: %w", err)
		}
		items, err := ad.passRepository(ctx, rp)
		switch {
		case err != nil && ctx.Err() != nil:
			ad.logPassRepo(rp, items, "")
			return fmt.Errorf("the repository pass stopped: %w", ctx.Err())
		case err != nil:
			out.RepoFailed++
			ad.logPassRepo(rp, items, err.Error())
			continue
		}
		failure := resultFailure(Result{Plan: Plan{Items: items}})
		if failure != "" {
			out.RepoFailed++
		}
		if removedSomething(items) {
			out.RepoChanged++
		}
		ad.logPassRepo(rp, items, failure)
	}
	if err := ctx.Err(); err != nil {
		return fmt.Errorf("the repository pass stopped: %w", err)
	}
	return nil
}

// logPassRepo logs one line for a repository whose pass removed something
// or failed; nothing otherwise.
func (ad AutoDeps) logPassRepo(rp passRepo, items []Item, failure string) {
	switch {
	case failure != "":
		ad.logf("session cleanup: repository %s: %s; %s", rp.key, failure, Summarize(items))
	case removedSomething(items):
		ad.logf("session cleanup: repository %s: %s", rp.key, Summarize(items))
	}
}

// passRepos are the distinct repositories of the workbenches' live
// folders, in workbench order: a folder missing or in no repository is
// left out (it has no worktree the pass could reach); one whose repository
// git cannot read, and a workbench whose folders cannot be read, are left
// out as failures.
func (ad AutoDeps) passRepos(ctx context.Context, wbs []int64, out *AutoResult) []passRepo {
	var repos []passRepo
	byKey := map[string]int{}
	for _, wb := range wbs {
		folders, err := ad.Deps.DB.BenchFolders(ctx, wb)
		if err != nil {
			out.RepoFailed++
			ad.logf("session cleanup: workbench %d: reading its folders: %v", wb, err)
			continue
		}
		for _, f := range folders {
			keys, unlocked := lockKeys(ctx, ad.Deps, []string{f})
			if len(keys) != 1 {
				// Missing or in no repository: nothing to reach. A repository
				// git could not read is a failure of the pass.
				folder := resolvePath(f)
				if note, ok := unlocked[folder]; ok && unsweptNote(folder) == "" {
					out.RepoFailed++
					ad.logf("session cleanup: workbench %d: %s", wb, note)
				}
				continue
			}
			if i, ok := byKey[keys[0]]; ok {
				if !slices.Contains(repos[i].benches, wb) {
					repos[i].benches = append(repos[i].benches, wb)
				}
				continue
			}
			byKey[keys[0]] = len(repos)
			repos = append(repos, passRepo{key: keys[0], folder: resolvePath(f), workbenchID: wb, benches: []int64{wb}})
		}
	}
	return repos
}

// passState is one repository's pass across its batches.
type passState struct {
	order    []string // the candidates, the oldest activity first
	measured bool     // order was read (the first batch, under the lock)
	next     int      // order[:next] were taken by a batch
	removed  int      // worktrees removed so far
}

// passRepository runs one repository's pass: batches of at most sweepBatch
// candidates, each under its own try of the repository's lock, until none
// is left, sweepBatch worktrees were removed, or the pass must stop. The
// session host's live runs are read right before each batch and again
// before each removal and prune; unreadable, the repository is skipped for
// this pass (an error). The lock busy — another cleanup runs, the owner's
// Clean Up included — leaves the rest for the next pass, with no error.
func (ad AutoDeps) passRepository(ctx context.Context, rp passRepo) ([]Item, error) {
	st := &passState{}
	var items []Item
	for {
		if err := ctx.Err(); err != nil {
			return items, err //nolint:wrapcheck // repositoryPass says the pass stopped
		}
		live, err := ad.liveIDs(ctx)
		if err != nil {
			return items, fmt.Errorf("listing the live sessions: %w", err)
		}
		batch, more, err := ad.passBatch(ctx, rp, live, st)
		items = append(items, batch...)
		switch {
		case errors.Is(err, errCleanupBusy):
			return items, nil
		case err != nil:
			return items, err
		case !more:
			return items, nil
		}
	}
}

// passBatch is one batch under the repository's lock: undo an interrupted
// unlock first (restoreScope), read the facts, take the next candidates,
// plan them in sweep mode, remove the ones that may go (up to what is left
// of sweepBatch) with their branches, and prune the builds of those kept
// for their work. more = candidates are left and the pass may go on.
func (ad AutoDeps) passBatch(ctx context.Context, rp passRepo, live []int64, st *passState) ([]Item, bool, error) {
	d := ad.tryingDeps()
	r := Request{Sweep: true, WorkbenchID: rp.workbenchID, LiveSessions: live, NoSize: true, NoTerminate: true,
		PruneBuilds: true, repoPass: true, folder: rp.folder, ownerBenches: rp.benches, liveNow: ad.liveIDs,
		scope: &repoScope{bench: []string{rp.folder}}}
	unlock, err := lockRepositories(ctx, d, r)
	if err != nil {
		return nil, false, err
	}
	defer unlock()
	for _, note := range restoreScope(ctx, d, r) {
		ad.logf("session cleanup: repository %s: %s", rp.key, note)
	}
	b, err := newBuilder(ctx, d, r)
	if err != nil {
		return nil, false, err
	}
	if !st.measured {
		st.order, st.measured = b.passCandidates(ctx), true
	}
	roots := st.take(b)
	if len(roots) == 0 {
		return nil, false, ctx.Err()
	}
	b.req.onlyRoots = map[string]bool{}
	for _, root := range roots {
		b.req.onlyRoots[root] = true
	}
	b.walked = map[string]string{}
	p := b.evaluate(ctx)
	only := passSelection(p.Items, roots, sweepBatch-st.removed)
	a := newApplier(b, p, only)
	if len(only) > 0 {
		a.run(ctx)
	}
	a.pruneBuilds(ctx)
	for _, it := range a.items {
		if it.Kind == KindWorktree && it.Done {
			st.removed++
		}
	}
	if a.halt != nil {
		return a.items, false, fmt.Errorf("stopped: %w", a.halt)
	}
	return a.items, st.next < len(st.order) && st.removed < sweepBatch, ctx.Err()
}

// take is the next batch of st.order: at most sweepBatch roots still
// listed as linked worktrees, with their directory, that no session works
// in by b's facts (read under this batch's lock).
func (st *passState) take(b *builder) []string {
	var roots []string
	for st.next < len(st.order) && len(roots) < sweepBatch {
		root := st.order[st.next]
		st.next++
		if w, ok := b.listedWorktree(root); ok && !b.sessionWorksIn(w) {
			roots = append(roots, root)
		}
	}
	return roots
}

// sessionWorksIn is W6's rule: a session live in the session host, or a
// row not ended that reported from inside within inUseWindow, works in w.
func (b *builder) sessionWorksIn(w worktree) bool {
	reason, _, _ := catchSessionInIt(context.Background(), b, w) // it reads b's facts only: never an error
	return reason != ""
}

// passCandidates are the linked worktrees under the main checkout's
// .claude/worktrees that no session works in and that have been idle for
// idleFor, the oldest activity first. A worktree whose activity cannot be
// measured is not idle (left out); one whose directory is gone (prunable)
// has none to measure and is left out too. The measures run checkWorkers
// at a time; when ctx is done nothing is a candidate.
func (b *builder) passCandidates(ctx context.Context) []string {
	under := b.claudeWorktrees()
	if under == "" {
		return nil
	}
	var list []worktree
	for _, w := range b.repo.worktrees {
		if w.Bare || w.Main || w.Prunable || w.Root == under || !pathWithin(w.Root, under) ||
			b.repo.adminDirs[w.Root] == "" || b.sessionWorksIn(w) {
			continue
		}
		list = append(list, w)
	}
	at := make([]time.Time, len(list))
	idle := make([]bool, len(list))
	now := clockNow(b.deps)
	var wg sync.WaitGroup
	slots := make(chan struct{}, checkWorkers)
	for i, w := range list {
		slots <- struct{}{}
		wg.Go(func() {
			defer func() { <-slots }()
			t, err := lastActivity(ctx, b.deps, w.Root, b.repo.adminDirs[w.Root])
			at[i], idle[i] = t, err == nil && now.Sub(t) >= idleFor
		})
	}
	wg.Wait()
	if ctx.Err() != nil {
		return nil
	}
	var roots []string
	idx := make([]int, 0, len(list))
	for i := range list {
		if idle[i] {
			idx = append(idx, i)
		}
	}
	slices.SortStableFunc(idx, func(x, y int) int { return at[x].Compare(at[y]) })
	for _, i := range idx {
		roots = append(roots, list[i].Root)
	}
	return roots
}

// claudeWorktrees is <main checkout>/.claude/worktrees as a path, not
// resolved: a symlinked .claude or worktrees folder leads elsewhere, and
// worktrees reached through it (whose listed roots are resolved) are not
// under it. "" when the repository has no main worktree (a bare one).
func (b *builder) claudeWorktrees() string {
	for _, w := range b.repo.worktrees {
		if w.Main && !w.Bare {
			return filepath.Join(w.Root, claudeWorktreesDir)
		}
	}
	return ""
}

// passSelection are the keys a batch applies: the worktrees of the plan
// that may go, in the order of roots (the oldest activity first), at most
// limit of them, and the branch of each when that branch item may go too.
func passSelection(items []Item, roots []string, limit int) []string {
	byKey := map[string]Item{}
	branchKey := map[string]string{}
	for _, it := range items {
		byKey[it.Key] = it
		if it.Kind == KindBranch && it.Action == ActionRemove {
			branchKey[it.Name] = it.Key
		}
	}
	var only []string
	for _, root := range roots {
		if limit <= 0 {
			break
		}
		it, ok := byKey["worktree:"+root]
		if !ok || it.Action != ActionRemove {
			continue
		}
		only = append(only, it.Key)
		limit--
		if k, ok := branchKey[it.Branch]; ok && it.Branch != "" {
			only = append(only, k)
		}
	}
	return only
}
