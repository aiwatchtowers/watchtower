package sessioncleanup

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"slices"
	"strings"
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
}

// repositoryPass is AutoRun's second part: the repository pass of every
// repository of the workbenches' folders, one after the other, counted in
// out. A workbench whose folders cannot be read is a failure that leaves
// the others alone; when ctx is done the pass stops with ctx's error and
// the next pass starts again from scratch.
func (ad AutoDeps) repositoryPass(ctx context.Context, out *AutoResult) error {
	if err := ctx.Err(); err != nil {
		return fmt.Errorf("the repository pass stopped: %w", err)
	}
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
		if err != nil && ctx.Err() != nil {
			// What went, and what failed, before the stop counts; the step
			// the stop cut off does not (R2-8).
			ad.countPassRepo(out, rp, items, passFailure(items))
			return fmt.Errorf("the repository pass stopped: %w", ctx.Err())
		}
		failure := passFailure(items)
		if err != nil {
			failure = strings.Join(slices.DeleteFunc([]string{err.Error(), failure}, func(s string) bool { return s == "" }), "; ")
		}
		ad.countPassRepo(out, rp, items, failure)
	}
	if err := ctx.Err(); err != nil {
		return fmt.Errorf("the repository pass stopped: %w", err)
	}
	return nil
}

// countPassRepo counts one repository's pass in out — changed when it
// removed something (a worktree, a branch, a build folder), failed when
// failure is set — and logs one line when either holds.
func (ad AutoDeps) countPassRepo(out *AutoResult, rp passRepo, items []Item, failure string) {
	changed := removedSomething(items)
	if changed {
		out.RepoChanged++
	}
	switch {
	case failure != "":
		out.RepoFailed++
		ad.logf("session cleanup: repository %s: %s; %s", rp.key, failure, Summarize(items))
	case changed:
		ad.logf("session cleanup: repository %s: %s", rp.key, Summarize(items))
	}
}

// passFailure names what a repository's pass recorded as failed: an item's
// or a build folder's error (resultFailure), and a worktree or branch kept
// because a check could not be made or git refused its removal; "" for
// none. An item whose first failure was recorded with the pass's ctx
// already done (Item.stopped, noted when it was recorded) is the stop, not
// a failure, and is left out.
func passFailure(items []Item) string {
	kept := slices.DeleteFunc(slices.Clone(items), func(it Item) bool { return it.stopped })
	var parts []string
	if f := resultFailure(Result{Plan: Plan{Items: kept}}); f != "" {
		parts = append(parts, f)
	}
	for _, it := range kept {
		if it.Action == ActionKeep && (it.Reason == ReasonCheckFailed || it.Reason == ReasonGitRefused) {
			parts = append(parts, fmt.Sprintf("%s: %s (%s)", it.Key, it.Reason, it.Detail))
		}
	}
	return strings.Join(parts, "; ")
}

// passRepos are the distinct repositories of the workbenches' live
// folders, in workbench order: a folder missing or in no repository is
// left out (it has no worktree the pass could reach); one whose repository
// git cannot read, and a workbench whose folders cannot be read, are left
// out as failures — unless ctx is done, which is the pass stopping, not a
// failure (repositoryPass says so).
func (ad AutoDeps) passRepos(ctx context.Context, wbs []int64, out *AutoResult) []passRepo {
	var repos []passRepo
	seen := map[string]bool{}
	for _, wb := range wbs {
		folders, err := ad.Deps.DB.BenchFolders(ctx, wb)
		if ctx.Err() != nil {
			return nil
		}
		if err != nil {
			out.RepoFailed++
			ad.logf("session cleanup: workbench %d: reading its folders: %v", wb, err)
			continue
		}
		for _, f := range folders {
			keys, unlocked := lockKeys(ctx, ad.Deps, []string{f})
			if ctx.Err() != nil {
				return nil
			}
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
			if seen[keys[0]] {
				continue
			}
			seen[keys[0]] = true
			repos = append(repos, passRepo{key: keys[0], folder: resolvePath(f), workbenchID: wb})
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
		case errors.Is(err, errRepositoryMoved) && len(items) == 0:
			// Its folder left the repository found at discovery: skipped
			// this pass; the next one finds where the folder is now.
			ad.logf("session cleanup: repository %s: skipped: %v", rp.key, err)
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
	ctx = withBackgroundWrites(ctx, rp.key)
	d := ad.tryingDeps()
	r := Request{Sweep: true, WorkbenchID: rp.workbenchID, LiveSessions: live, NoSize: true, NoTerminate: true,
		PruneBuilds: true, repoPass: true, folder: rp.folder, allOwners: true, liveNow: ad.liveIDs,
		repoKey: rp.key, scope: &repoScope{bench: []string{rp.folder}, locked: []string{rp.key}}}
	// The lock of the repository found at discovery, not of whatever the
	// folder resolves to now; every evaluation below checks that the folder
	// still resolves to it (Request.repoKey).
	unlock, err := d.Lock(ctx, rp.key)
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
	orderByRoots(p.Items, roots)
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
// listed as linked worktrees with their directory (never a prunable one)
// that no session works in by b's facts (read under this batch's lock).
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
// measured is not idle (left out). A prunable one is never a candidate
// (fix round 2, R2-1): git calls a worktree prunable whenever it cannot
// see its directory — gone, but also unreadable (EACCES) or on a volume
// not mounted — and `git worktree remove` would then detach it, staged
// work in its index included, with no one confirming; the owner's Clean Up
// shows it as a row. The measures run checkWorkers at a time; when ctx is
// done nothing is a candidate.
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

// orderByRoots puts the worktree items in the order of roots (the oldest
// activity first) within the places they hold, so the apply removes the
// oldest first whatever git's listing order; every other item stays where
// it is.
func orderByRoots(items []Item, roots []string) {
	rank := map[string]int{}
	for i, root := range roots {
		rank["worktree:"+root] = i
	}
	var at []int
	var trees []Item
	for i, it := range items {
		if _, ok := rank[it.Key]; ok && it.Kind == KindWorktree {
			at = append(at, i)
			trees = append(trees, it)
		}
	}
	slices.SortStableFunc(trees, func(x, y Item) int { return rank[x.Key] - rank[y.Key] })
	for j, i := range at {
		items[i] = trees[j]
	}
}

// passSelection are the keys a batch applies: the worktrees of the plan
// that may go, in the order of roots (the oldest activity first), at most
// limit of them, with the LaunchServices entries of the app bundles inside
// each (as a Clean Up row's) and its branch when that branch item may go
// too.
func passSelection(items []Item, roots []string, limit int) []string {
	byKey := map[string]Item{}
	branchKey := map[string]string{}
	bundles := map[string][]string{}
	for _, it := range items {
		byKey[it.Key] = it
		if it.Kind == KindBranch && it.Action == ActionRemove {
			branchKey[it.Name] = it.Key
		}
		if it.Kind == KindLsreg && it.Action == ActionRemove && it.Worktree != "" {
			bundles[it.Worktree] = append(bundles[it.Worktree], it.Key)
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
		only = append(only, bundles[root]...)
		limit--
		if k, ok := branchKey[it.Branch]; ok && it.Branch != "" {
			only = append(only, k)
		}
	}
	return only
}

// errLiveInIt: the live runs read right before a destructive step show a
// session holding the worktree — or one that may, by what is known of it.
var errLiveInIt = errors.New("a session the host lists live holds it now")

// errLiveUnreadable: the live runs, the sessions' activity or the ledger's
// owners — who works where — could not be read for a destructive step:
// the repository's pass stops (as an unreadable live set before a batch
// skips it).
var errLiveUnreadable = errors.New("who works in the worktrees could not be read")

// liveClear reads the session host's live runs once more, right before a
// removal or a build folder's move (the repository pass: Request.liveNow),
// with the ledger's owners and each live run's row by id. A live session
// holds root (errLiveInIt) when its working directory is inside, as stored
// or resolved (M1); when it recorded root in its ledger (the sweep's W2
// owners, R2-4); when its row is gone, or when it is an agent that has not
// said where it works, whatever its workbench (R2-5, R3-2); a plain shell,
// which never says, only when it was opened in root (R4-1). The tree then
// waits for the next pass. Any other error: what
// holds it cannot be told, the caller keeps the work. nil = none holds it;
// other requests: nil.
func (a *applier) liveClear(ctx context.Context, root string) error {
	if a.req.liveNow == nil {
		return nil
	}
	live, err := a.req.liveNow(ctx)
	if err != nil {
		return fmt.Errorf("%w: %w", errLiveUnreadable, err)
	}
	if len(live) == 0 {
		return nil
	}
	ledger, err := a.deps.DB.SessionWorktreeOwners(ctx)
	if err != nil {
		return fmt.Errorf("%w: the session worktree owners: %w", errLiveUnreadable, err)
	}
	var owners []int64
	for r, ids := range ledger {
		if r == root || resolvePath(r) == root {
			owners = append(owners, ids...)
		}
	}
	for _, id := range live {
		if slices.Contains(owners, id) {
			return fmt.Errorf("%w: session %d recorded it", errLiveInIt, id)
		}
		s, ok, err := a.deps.DB.SessionActivityOf(ctx, id)
		switch {
		case err != nil:
			return fmt.Errorf("%w: live session %d: %w", errLiveUnreadable, id, err)
		case !ok:
			return fmt.Errorf("%w: session %d has no row that says where it works", errLiveInIt, id)
		case s.AgentCwd == "" && s.Kind == "shell":
			// A plain shell never reports a cwd (only agent hooks write it):
			// it holds the tree it was opened in; one that cd'd into a tree
			// is a process there, which W5 sees in the final re-check (R4-1).
			if s.Folder != "" && (pathWithin(s.Folder, root) || pathWithin(resolvePath(s.Folder), root)) {
				return fmt.Errorf("%w: shell %d (%s) was opened in it", errLiveInIt, id, s.Title)
			}
		case s.AgentCwd == "":
			return fmt.Errorf("%w: session %d (%s) has not said where it works", errLiveInIt, id, s.Title)
		case s.AgentCwd != "" && (pathWithin(s.AgentCwd, root) || pathWithin(resolvePath(s.AgentCwd), root)):
			return fmt.Errorf("%w: session %d (%s) works in it", errLiveInIt, id, s.Title)
		}
	}
	return nil
}

// itemFailed: the item records a failure — an error, a build folder's, or
// a keep because a check could not be made or git refused.
func itemFailed(it Item) bool {
	return it.Error != "" || it.BuildError != "" ||
		it.Action == ActionKeep && (it.Reason == ReasonCheckFailed || it.Reason == ReasonGitRefused)
}

// markFailure notes it's first recorded failure, once: stopped is whether
// ctx — the pass's — was done at that moment (R4-3). Called right where
// failures are recorded, before any recovery runs.
func markFailure(ctx context.Context, it *Item) {
	if it.failSeen || !itemFailed(*it) {
		return
	}
	it.failSeen, it.stopped = true, ctx.Err() != nil
}

// noteFailures is markFailure for every item: the applier calls it right
// after each step that may record a failure, before any recovery.
func (a *applier) noteFailures(ctx context.Context) {
	for i := range a.items {
		markFailure(ctx, &a.items[i])
	}
}
