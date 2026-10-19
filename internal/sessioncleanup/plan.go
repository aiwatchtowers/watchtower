package sessioncleanup

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"watchtower/internal/gitbin"
)

// sizeBudget bounds the size walk of one worktree (spec §8).
const sizeBudget = 20 * time.Second

// sizeWorkers is how many worktrees are measured at the same time: one walk
// at a time made a sweep over dozens of large worktrees take minutes.
const sizeWorkers = 4

// detailGone is the detail of a prunable worktree: its directory is gone,
// so removing it only drops git's metadata.
const detailGone = "directory is gone"

// Request is one evaluation: a session's cleanup, or the owner's sweep of
// a workbench.
type Request struct {
	WorkbenchID, SessionID int64
	Sweep                  bool
	// CallerSessionID is $WATCHTOWER_TERMINAL_SESSION_ID of the calling
	// agent; 0 = not an agent call.
	CallerSessionID int64
	// LiveSessions are the Desktop's live terminals.
	LiveSessions                        []int64
	DeclaredWorktrees, DeclaredBranches []string
	NoSize                              bool
	Now                                 time.Time
}

// builder carries one evaluation's facts.
type builder struct {
	deps       Deps
	req        Request
	now        time.Time
	self       int
	repo       *repoState
	session    SessionInfo // session mode
	seen       observed    // session mode
	folders    []string
	claudeHome []string // ~/.claude as given and symlink-resolved
	homeErr    error    // the home directory is unknown: every worktree is kept
	procs      []Proc
	activity   map[int64]SessionActivity
	live       map[int64]bool
	rootOwners map[string][]int64 // sweep
	// walked caches W9's walk per worktree root (nil = walk every time).
	// Apply shares one map between its evaluation and the early re-checks,
	// so a worktree is walked once there and once more right before
	// `git worktree remove`.
	walked map[string]string

	// After the worktree pass: where each branch is checked out, and the
	// subset of worktrees that stay.
	checkedOutIn      map[string]string
	checkedOutStaying map[string]string
}

// PlanResult evaluates the request and returns the plan as the command
// prints it: a plan-mode Result naming the workbench the session belongs
// to. It writes nothing: no ref, worktree, file, database row or signal
// (PROJ-18).
func PlanResult(ctx context.Context, d Deps, r Request) (Result, error) {
	b, err := newBuilder(ctx, d, r)
	if err != nil {
		return Result{}, err
	}
	p := b.evaluate(ctx)
	if p.Items == nil {
		p.Items = []Item{}
	}
	return Result{
		SessionID: r.SessionID, WorkbenchID: b.req.WorkbenchID, Mode: ModePlan, Sweep: r.Sweep,
		Plan: p, RemovedBytesKnown: true, Summary: Summarize(p.Items),
	}, nil
}

// evaluate lists and evaluates every candidate of the builder's facts.
func (b *builder) evaluate(ctx context.Context) Plan {
	items := b.worktreeItems(ctx)
	items = append(items, b.branchItems(ctx, items)...)
	items = append(items, b.extraItems(ctx, items)...)
	return Plan{Items: items, DefaultBranch: b.repo.defaultBranch}
}

func newBuilder(ctx context.Context, d Deps, r Request) (*builder, error) {
	if d.Git == nil || d.DB == nil || d.Procs == nil {
		return nil, errors.New("session cleanup: git, store and process scanner are required")
	}
	if !r.Sweep && r.SessionID == 0 {
		return nil, errors.New("session cleanup: a session or a sweep is required")
	}
	bin, ok := d.Git.GitBinary()
	if !ok {
		return nil, ErrNoGit
	}
	b := &builder{deps: d, req: r, now: r.Now, self: os.Getpid(), live: map[int64]bool{}}
	if b.now.IsZero() {
		b.now = clockNow(d)
	}
	for _, id := range r.LiveSessions {
		b.live[id] = true
	}
	if err := b.loadSession(ctx); err != nil {
		return nil, err
	}
	if err := b.loadRepo(ctx, gitCmd{run: d.Git, bin: bin}); err != nil {
		return nil, err
	}
	return b, b.loadFacts(ctx)
}

func clockNow(d Deps) time.Time {
	if d.Clock != nil {
		return d.Clock()
	}
	return time.Now()
}

// ErrWrongWorkbench is a session that does not belong to the requested
// workbench: nothing is planned or done.
var ErrWrongWorkbench = errors.New("wrong workbench")

// loadSession reads the session (session mode) and checks it belongs to
// the requested workbench — the one place the ids are checked.
func (b *builder) loadSession(ctx context.Context) error {
	if b.req.Sweep {
		if b.req.WorkbenchID == 0 {
			return errors.New("session cleanup: a sweep needs a workbench")
		}
		return nil
	}
	s, err := b.deps.DB.CleanupSession(ctx, b.req.SessionID)
	if err != nil {
		return err // names the session already
	}
	if b.req.WorkbenchID != 0 && s.WorkbenchID != b.req.WorkbenchID {
		return fmt.Errorf("%w: session %d belongs to workbench %d, not %d",
			ErrWrongWorkbench, s.ID, s.WorkbenchID, b.req.WorkbenchID)
	}
	b.session, b.req.WorkbenchID = s, s.WorkbenchID
	return nil
}

func (b *builder) loadRepo(ctx context.Context, g gitCmd) error {
	folder, err := b.deps.DB.WorkbenchFolder(ctx, b.req.WorkbenchID)
	if err != nil {
		return fmt.Errorf("reading workbench %d: %w", b.req.WorkbenchID, err)
	}
	folder = resolvePath(folder)
	if !gitbin.InsideRepository(folder) {
		return fmt.Errorf("the workbench folder %s is not in a git repository", folder)
	}
	b.repo, err = readRepo(ctx, g, folder)
	return err
}

// loadFacts reads everything the catches consult, once per evaluation.
func (b *builder) loadFacts(ctx context.Context) error {
	folders, err := b.deps.DB.WorkbenchFolders(ctx)
	if err != nil {
		return fmt.Errorf("reading workbench folders: %w", err)
	}
	for _, f := range folders {
		b.folders = append(b.folders, resolvePath(f))
	}
	b.loadClaudeHome()
	acts, err := b.deps.DB.AllSessionActivity(ctx)
	if err != nil {
		return fmt.Errorf("reading the terminal sessions: %w", err)
	}
	b.activity = map[int64]SessionActivity{}
	for _, a := range acts {
		if a.AgentCwd != "" {
			a.AgentCwd = resolvePath(a.AgentCwd)
		}
		b.activity[a.ID] = a
	}
	if b.procs, err = b.deps.Procs.Scan(ctx); err != nil {
		return fmt.Errorf("scanning processes: %w", err)
	}
	if b.req.Sweep {
		return b.loadOwners(ctx)
	}
	return b.loadObserved(ctx)
}

// loadClaudeHome locates ~/.claude; a failure is kept in homeErr, so every
// worktree is kept as check_failed rather than the plan failing.
func (b *builder) loadClaudeHome() {
	home := os.UserHomeDir
	if b.deps.Home != nil {
		home = b.deps.Home
	}
	dir, err := home()
	switch {
	case err != nil:
		b.homeErr = err
	case dir == "" || !filepath.IsAbs(dir):
		b.homeErr = fmt.Errorf("home directory %q is not an absolute path", dir)
	default:
		claude := filepath.Join(dir, ".claude")
		b.claudeHome = []string{claude, resolvePath(claude)}
	}
}

func (b *builder) loadOwners(ctx context.Context) error {
	owners, err := b.deps.DB.WorkbenchSessionWorktrees(ctx, b.req.WorkbenchID)
	if err != nil {
		return fmt.Errorf("reading workbench %d session worktrees: %w", b.req.WorkbenchID, err)
	}
	b.rootOwners = map[string][]int64{}
	for root, ids := range owners {
		key := resolvePath(root)
		b.rootOwners[key] = append(b.rootOwners[key], ids...)
	}
	return nil
}

func (b *builder) loadObserved(ctx context.Context) error {
	rows, err := b.deps.DB.SessionWorktrees(ctx, b.session.ID)
	if err != nil {
		return fmt.Errorf("reading session %d worktrees: %w", b.session.ID, err)
	}
	targets, err := b.deps.DB.SessionTargetBranches(ctx, b.session.ID)
	if err != nil {
		return fmt.Errorf("reading session %d target branches: %w", b.session.ID, err)
	}
	b.seen = observe(rows, targets, b.req.DeclaredWorktrees, b.req.DeclaredBranches)
	b.observePlacement()
	return nil
}

// observePlacement records a placed row's own worktree and branch, each
// only when born no later than the row (bornByRecord), as seen so they are
// listed, and as owned by record so W2 and B3 pass them. A non-absolute
// folder_path places nothing (it would resolve against our own cwd).
func (b *builder) observePlacement() {
	if b.session.PlacedCwd == "" || !filepath.IsAbs(b.session.PlacedCwd) {
		return
	}
	created := b.session.CreatedAt
	b.seen.placedCwd = resolvePath(b.session.PlacedCwd)
	for _, w := range b.repo.worktrees {
		if !b.seen.placedWorktree(w, b.repo.worktrees) {
			continue
		}
		if birth, known := b.worktreeBirth(w.Root); bornByRecord(birth, known, created) {
			b.seen.placedRoot, b.seen.roots[w.Root] = w.Root, true
		}
	}
	name := b.session.PlacedBranch
	if name == "" {
		return
	}
	if birth, known := b.repo.branchBirth(name); bornByRecord(birth, known, created) {
		b.seen.placedBranch, b.seen.branches[name] = name, true
	}
}

// worktreeItems lists and evaluates the worktree candidates: in session
// mode the ones the session observed (the main worktree and workbench
// folders only when declared), in the sweep every linked worktree but
// those; plus a keep item per declared path that is no worktree.
func (b *builder) worktreeItems(ctx context.Context) []Item {
	items := []Item{}
	b.checkedOutIn, b.checkedOutStaying = map[string]string{}, map[string]string{}
	known := map[string]bool{}
	for _, w := range b.repo.worktrees {
		known[w.Root] = true
		listed := !w.Bare && b.listsWorktree(w)
		if w.Branch != "" {
			b.checkedOutIn[w.Branch] = w.Root
		}
		if !listed {
			b.markStaying(w)
			continue
		}
		it := b.evaluateWorktree(ctx, w)
		if it.Action == ActionKeep {
			b.markStaying(w)
		}
		items = append(items, it)
	}
	return append(items, b.undeclaredWorktrees(known)...)
}

func (b *builder) markStaying(w worktree) {
	if w.Branch != "" {
		b.checkedOutStaying[w.Branch] = w.Root
	}
}

func (b *builder) listsWorktree(w worktree) bool {
	structural, _, _ := catchFolders(context.Background(), b, w)
	if b.req.Sweep {
		return structural == ""
	}
	if structural != "" {
		return b.declaredRoot(w.Root)
	}
	return b.seen.sawWorktree(w)
}

func (b *builder) declaredRoot(root string) bool {
	for _, p := range b.req.DeclaredWorktrees {
		if resolvePath(p) == root {
			return true
		}
	}
	return false
}

func (b *builder) undeclaredWorktrees(known map[string]bool) []Item {
	var items []Item
	for _, p := range b.req.DeclaredWorktrees {
		root := resolvePath(p)
		if known[root] {
			continue
		}
		known[root] = true
		items = append(items, Item{Key: "worktree:" + root, Kind: KindWorktree, Name: filepath.Base(root),
			Action: ActionKeep, Reason: ReasonNotAWorktree})
	}
	return items
}

func (b *builder) evaluateWorktree(ctx context.Context, w worktree) Item {
	it := Item{Key: "worktree:" + w.Root, Kind: KindWorktree, Name: filepath.Base(w.Root), Branch: w.Branch,
		Action: ActionRemove}
	for _, c := range b.worktreeCatches(w) {
		reason, detail, err := c(ctx, b, w)
		if err != nil {
			reason, detail = ReasonCheckFailed, err.Error()
		}
		if reason != "" {
			it.Action, it.Reason, it.Detail = ActionKeep, reason, detail
			break
		}
	}
	if b.req.Sweep {
		it.Owner = b.ownerHint(w.Root)
	}
	if w.Prunable && it.Action == ActionRemove {
		it.Detail, it.BytesKnown = detailGone, true
	}
	return it
}

// ownerHint is the most recently active session that recorded root, or
// Unknown.
func (b *builder) ownerHint(root string) *OwnerHint {
	var best *SessionActivity
	for _, id := range b.rootOwners[root] {
		if a, ok := b.activity[id]; ok && (best == nil || a.LastActive.After(best.LastActive)) {
			best = &a
		}
	}
	if best == nil {
		return &OwnerHint{Unknown: true}
	}
	h := &OwnerHint{SessionID: best.ID, Title: best.Title}
	if !best.LastActive.IsZero() {
		h.LastActive = best.LastActive.UTC().Format(time.RFC3339)
	}
	return h
}

// branchItems lists and evaluates the branch candidates after the worktree
// pass (B2 needs to know which worktrees stay).
func (b *builder) branchItems(ctx context.Context, worktreeItems []Item) []Item {
	var items []Item
	for _, name := range b.branchCandidates(worktreeItems) {
		sha, ok := b.repo.branchTip(name)
		if !ok {
			items = append(items, Item{Key: "branch:" + name, Kind: KindBranch, Name: name, Branch: name,
				Action: ActionKeep, Reason: ReasonNotABranch})
			continue
		}
		items = append(items, b.evaluateBranch(ctx, branchRef{Name: name, Sha: sha}))
	}
	return items
}

// branchCandidates: in session mode the observed branches that exist, the
// branches of listed worktrees and every declared one (the default branch
// only when declared); in the sweep every local branch but the default and
// the ones checked out in a worktree that stays.
func (b *builder) branchCandidates(worktreeItems []Item) []string {
	set := map[string]bool{}
	if b.req.Sweep {
		for _, br := range b.repo.branches {
			_, staying := b.checkedOutStaying[br.Name]
			if br.Name != b.repo.defaultBranch && !staying {
				set[br.Name] = true
			}
		}
		return sortedKeys(set)
	}
	for name := range b.seen.branches {
		if _, ok := b.repo.branchTip(name); ok && name != b.repo.defaultBranch {
			set[name] = true
		}
	}
	for _, it := range worktreeItems {
		if it.Branch != "" && it.Branch != b.repo.defaultBranch {
			set[it.Branch] = true
		}
	}
	for _, name := range b.req.DeclaredBranches {
		set[name] = true
	}
	return sortedKeys(set)
}

func sortedKeys(set map[string]bool) []string {
	out := make([]string, 0, len(set))
	for k := range set {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func (b *builder) evaluateBranch(ctx context.Context, br branchRef) Item {
	it := Item{Key: "branch:" + br.Name, Kind: KindBranch, Name: br.Name, Branch: br.Name, Action: ActionRemove,
		BytesKnown: true}
	for _, c := range b.branchCatches() {
		reason, detail, err := c(ctx, b, br)
		if err != nil {
			reason, detail = ReasonCheckFailed, err.Error()
		}
		if reason != "" {
			it.Action, it.Reason, it.Detail = ActionKeep, reason, detail
			break
		}
	}
	if b.req.Sweep {
		it.Owner = &OwnerHint{Unknown: true}
		if root, ok := b.checkedOutIn[br.Name]; ok {
			it.Owner = b.ownerHint(root)
		}
	}
	return it
}

// extraItems are, per worktree to remove, its size, its orphans (session
// mode only — the sweep never signals) and its .app bundles; and in the
// sweep the stale LaunchServices entries under the workbench folder.
func (b *builder) extraItems(ctx context.Context, items []Item) []Item {
	var removed []int
	for i, it := range items {
		if it.Kind == KindWorktree && it.Action == ActionRemove && it.Detail != detailGone {
			removed = append(removed, i)
		}
	}
	b.measureAll(ctx, items, removed)
	var extra []Item
	for _, i := range removed {
		root := items[i].Key[len("worktree:"):]
		if !b.req.Sweep {
			extra = append(extra, b.orphanItems(root)...)
		}
		extra = append(extra, b.bundleItems(root)...)
	}
	return append(extra, b.staleItems(ctx)...)
}

// measureAll sizes items[i] for each i in idx, up to sizeWorkers walks at
// a time; each walk keeps its own budget.
func (b *builder) measureAll(ctx context.Context, items []Item, idx []int) {
	if b.deps.Sizer == nil || b.req.NoSize {
		return
	}
	var wg sync.WaitGroup
	slots := make(chan struct{}, sizeWorkers)
	for _, i := range idx {
		slots <- struct{}{}
		wg.Go(func() {
			defer func() { <-slots }()
			it := &items[i]
			it.Bytes, it.BytesKnown = b.deps.Sizer.Size(ctx, it.Key[len("worktree:"):], sizeBudget)
		})
	}
	wg.Wait()
}

func (b *builder) orphanItems(root string) []Item {
	orphans, _ := OrphansIn(b.procs, []string{root}, b.self)
	items := make([]Item, 0, len(orphans))
	for _, p := range orphans {
		items = append(items, Item{Key: procKey(p), Kind: KindProcess,
			Name: filepath.Base(p.Exe), Detail: p.Exe, Action: ActionRemove, BytesKnown: true})
	}
	return items
}

func (b *builder) bundleItems(root string) []Item {
	if b.deps.LS == nil {
		return nil
	}
	var items []Item
	for _, bundle := range b.deps.LS.Bundles(root) {
		items = append(items, Item{Key: "lsreg:" + bundle, Kind: KindLsreg, Name: filepath.Base(bundle),
			Detail: bundle, Action: ActionRemove, BytesKnown: true})
	}
	return items
}

func (b *builder) staleItems(ctx context.Context) []Item {
	if !b.req.Sweep || b.deps.LS == nil {
		return nil
	}
	stale, err := b.deps.LS.Stale(ctx, b.repo.folder)
	if err != nil {
		return []Item{{Key: "lsreg:" + b.repo.folder, Kind: KindLsreg, Name: "LaunchServices",
			Action: ActionKeep, Reason: ReasonCheckFailed, Detail: err.Error()}}
	}
	var items []Item
	for _, bundle := range stale {
		items = append(items, Item{Key: "lsreg:" + bundle, Kind: KindLsreg, Name: filepath.Base(bundle),
			Detail: bundle, Action: ActionRemove, BytesKnown: true})
	}
	return items
}
