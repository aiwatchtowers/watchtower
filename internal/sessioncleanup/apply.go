package sessioncleanup

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"os"
	"slices"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/gitbin"
	"watchtower/internal/workbenchgit"
)

// Result modes.
const (
	ModePlan  = "plan"
	ModeApply = "apply"
)

// Reasons an apply adds to the plan's (spec §7).
const (
	// ReasonGitRefused: `git worktree remove` (no --force) refused; git's
	// message is in detail.
	ReasonGitRefused = "git_refused"
	// ReasonMoved: the branch tip is not the one the apply checked; the
	// compare-and-delete left it.
	ReasonMoved = "moved"
	// ReasonNotSelected: eligible, but the apply named other items.
	ReasonNotSelected = "not_selected"
	// ReasonNotInPlan: a named item the apply's own evaluation does not list.
	ReasonNotInPlan = "not_in_plan"
	// ReasonNotAttempted: an earlier failure stopped the apply first.
	ReasonNotAttempted = "not_attempted"
	// ReasonWorktreeKept: a process or LaunchServices item of a worktree
	// that was not removed.
	ReasonWorktreeKept = "worktree_kept"
	// ReasonBundleExists: a stale LaunchServices entry's bundle is back on
	// disk, so it is not stale any more.
	ReasonBundleExists = "bundle_exists"
	// ReasonBundleUnreadable: whether a stale entry's bundle is still on
	// disk cannot be told (Lstat failed); the entry stays.
	ReasonBundleUnreadable = "bundle_unreadable"
)

// Timeouts and waits of an apply (spec §4, §7).
const (
	worktreeRemoveTimeout = 120 * time.Second
	defaultOrphanGrace    = 5 * time.Second
	orphanPollStep        = 100 * time.Millisecond
	resultSaveTimeout     = 10 * time.Second
)

// ErrSweepNeedsItems is returned when a sweep names no items: a sweep
// applies only the items the owner named.
var ErrSweepNeedsItems = errors.New("session cleanup: a sweep applies only named items")

// ResultStore saves a session's cleanup result (db.DB.SaveCleanupResult).
type ResultStore interface {
	SaveCleanupResult(ctx context.Context, sessionID int64, resultJSON, at string) error
}

// Result is a plan or an apply as the command prints it (spec §4.1).
// ResultSaved/ResultError report the best-effort cleanup_result write.
type Result struct {
	SessionID   int64  `json:"session_id"`
	WorkbenchID int64  `json:"workbench_id"`
	Mode        string `json:"mode"`
	Sweep       bool   `json:"sweep"`
	Plan
	RemovedBytes int64 `json:"removed_bytes"`
	// RemovedBytesKnown is false when a removed worktree was not measured
	// (--no-size, or the walk ran over): RemovedBytes is then a lower bound.
	RemovedBytesKnown bool   `json:"removed_bytes_known"`
	Summary           string `json:"summary"`
	ResultSaved       bool   `json:"result_saved"`
	ResultError       string `json:"result_error"`
}

// Apply evaluates the request afresh and removes what is eligible now and,
// when only names item keys, only those; a sweep needs only. Every item is
// re-checked immediately before it is acted on, against fresh git, process
// and database facts; anything that changed or cannot be evaluated is
// kept. Order (spec §7): per worktree its orphans (session mode),
// `lsregister -u` of its bundles, then `git worktree remove` without
// --force; then each branch by compare-and-delete (`update-ref -d <ref>
// <checked sha>`). A failure that is not git's own refusal stops the apply:
// the rest is left untouched and reported not_attempted. In session mode
// the result is saved through Deps.Results (best effort). Under the
// repository locks, before anything is evaluated, every unlock an
// interrupted apply left is undone first (restoreScope). The error is
// non-nil only when nothing was removed — that relock aside. A sweep over several repositories
// applies them one after another (sweepBuilders); a failure that stops one
// leaves the later ones not_attempted.
func Apply(ctx context.Context, d Deps, r Request, only []string) (Result, error) {
	res := Result{SessionID: r.SessionID, WorkbenchID: r.WorkbenchID, Mode: ModeApply, Sweep: r.Sweep,
		Plan: Plan{Items: []Item{}, Notes: []string{}}}
	if r.Sweep && len(only) == 0 {
		return res, ErrSweepNeedsItems
	}
	if d.DB != nil && d.Git != nil && (r.Sweep && r.WorkbenchID != 0 || !r.Sweep && r.SessionID != 0) {
		sc, err := readScope(ctx, d, r)
		if err != nil {
			return res, fmt.Errorf("session cleanup: %w", err)
		}
		r.scope = sc
	}
	unlock, err := lockRepositories(ctx, d, r)
	if err != nil {
		return res, fmt.Errorf("session cleanup: %w", err)
	}
	defer unlock()
	// Undo an unlock an interrupted apply left (#2402 §3), under the
	// repository locks taken above, before any fact is loaded.
	restored := restoreScope(ctx, d, r)
	parts, err := evaluationBuilders(ctx, d, r)
	if err != nil {
		return res, err
	}
	parts[0].notes = append(parts[0].notes, restored...)
	if (r.RequireEnded || r.Quiet) && !r.Sweep && !parts[0].endStands() {
		return res, fmt.Errorf("session %d: %w", r.SessionID, ErrSessionNotEnded)
	}
	reportListing(parts)
	plans := make([]Plan, 0, len(parts))
	var a *applier
	var halt error
	for _, b := range parts {
		b.walked = map[string]string{}
		p := b.evaluate(ctx)
		a = newApplier(b, p, only)
		a.halt = halt
		a.run(ctx)
		if len(only) == 0 {
			a.pruneBuilds(ctx)
		}
		halt = a.halt
		p.Items = a.items
		plans = append(plans, p)
	}
	res.WorkbenchID, res.Plan = parts[0].req.WorkbenchID, mergePlans(plans)
	if len(parts) > 1 {
		res.Items = dropForeignNotInPlan(res.Items)
	}
	res.RemovedBytes, res.RemovedBytesKnown = removedBytes(res.Items)
	res.Summary = Summarize(res.Items)
	a.save(ctx, &res) // a session's apply has one part; a sweep saves nothing
	return res, nil
}

// repoScope is the folder set an apply reads once, before it locks
// anything (readScope): it locks the repositories of exactly these folders
// and evaluates exactly these, so a folder added to or moved in the bench
// meanwhile is never acted on unlocked. The re-checks reuse it.
type repoScope struct {
	// bench is a sweep's live bench folders as read.
	bench []string
	// sessionFolder is a session's own folder ("" = its workbench's home).
	sessionFolder string
	// home is the workbench's home folder, read when the folders above
	// leave the evaluation to it.
	home string
	// unlocked are the folders (resolved) whose repository lockKeys could
	// not tell, each with its note: never evaluated (sweepBuilders).
	unlocked map[string]string
	// locked are the canonical common dirs whose lock Apply took (Deps.Lock):
	// the only repositories an unlock marker is restored in (restoreScope).
	locked []string
}

// folders are the folders the scope evaluates.
func (s *repoScope) folders(sweep bool) []string {
	switch {
	case sweep && len(s.bench) > 0:
		return s.bench
	case !sweep && s.sessionFolder != "":
		return []string{s.sessionFolder}
	case s.home != "":
		return []string{s.home}
	}
	return nil
}

// readScope reads the request's folder set once: a sweep's live bench
// folders, a session's own folder, and the workbench's home when those
// leave the evaluation to it.
func readScope(ctx context.Context, d Deps, r Request) (*repoScope, error) {
	sc := &repoScope{}
	wb := r.WorkbenchID
	if r.Sweep {
		bench, err := d.DB.BenchFolders(ctx, r.WorkbenchID)
		if err != nil {
			return nil, fmt.Errorf("reading workbench %d folders: %w", r.WorkbenchID, err)
		}
		sc.bench = bench
	} else {
		s, err := d.DB.CleanupSession(ctx, r.SessionID)
		if err != nil {
			return nil, err //nolint:wrapcheck // names the session already
		}
		// The session must be the request's workbench's before anything
		// is done, the recovery of an interrupted unlock included (fix
		// round 2, R2-3); loadSession checks it again.
		if r.WorkbenchID != 0 && s.WorkbenchID != r.WorkbenchID {
			return nil, fmt.Errorf("%w: session %d belongs to workbench %d, not %d",
				ErrWrongWorkbench, s.ID, s.WorkbenchID, r.WorkbenchID)
		}
		sc.sessionFolder, wb = s.Folder, s.WorkbenchID
	}
	if len(sc.folders(r.Sweep)) == 0 && wb != 0 {
		home, err := d.DB.WorkbenchFolder(ctx, wb)
		if err != nil {
			return nil, fmt.Errorf("reading workbench %d: %w", wb, err)
		}
		sc.home = home
	}
	return sc, nil
}

// lockRepositories takes Deps.Lock for every repository of the request's
// scope (lockKeys), in sorted order, before anything is evaluated, so two
// applies over one repository — the Desktop's, the agent's, the daemon's
// automatic one, of one workbench or of two over the same repository —
// never act on the same facts at once. No Lock (tests, a caller that holds
// it already) locks nothing.
func lockRepositories(ctx context.Context, d Deps, r Request) (func(), error) {
	if d.Lock == nil {
		return func() {}, nil
	}
	var unlocks []func()
	unlockAll := func() {
		for i := len(unlocks) - 1; i >= 0; i-- {
			unlocks[i]()
		}
	}
	folders := r.scope.folders(r.Sweep)
	keys, unlocked := lockKeys(ctx, d, folders)
	// A folder whose repository could not be told is never evaluated: its
	// lock is not held. A sweep of several folders leaves it out with a
	// note; anywhere else the apply fails, nothing done.
	r.scope.unlocked = unlocked
	if len(unlocked) > 0 && (!r.Sweep || len(folders) <= 1) {
		folder := slices.Sorted(maps.Keys(unlocked))[0]
		if !gitbin.InsideRepository(folder) {
			// As the evaluation words it (loadRepo).
			return nil, fmt.Errorf("the workbench folder %s is not in a git repository", folder)
		}
		return nil, errors.New(unlocked[folder])
	}
	for _, k := range keys {
		unlock, err := d.Lock(ctx, k)
		if err != nil {
			unlockAll()
			return nil, fmt.Errorf("waiting for another cleanup of %s: %w", k, err)
		}
		unlocks = append(unlocks, unlock)
		r.scope.locked = append(r.scope.locked, k)
	}
	return unlockAll, nil
}

// lockKeys are the git common dirs (symlink-resolved, sorted, distinct) of
// folders. A folder that is missing, in no repository, or whose common dir
// git cannot tell gives no key and is returned in unlocked with its note
// (fail closed: lockRepositories keeps it out of the evaluation).
func lockKeys(ctx context.Context, d Deps, folders []string) (keys []string, unlocked map[string]string) {
	bin, ok := d.Git.GitBinary()
	if !ok {
		return nil, nil
	}
	g := gitCmd{run: d.Git, bin: bin}
	seen := map[string]bool{}
	unlocked = map[string]string{}
	for _, f := range folders {
		if f == "" {
			continue
		}
		folder := resolvePath(f)
		if note := unsweptNote(folder); note != "" {
			unlocked[folder] = note
			continue
		}
		out, err := g.output(ctx, folder, "rev-parse", "--git-common-dir")
		if err != nil {
			unlocked[folder] = fmt.Sprintf("%s: its repository could not be read (%v), not cleaned up", folder, err)
			continue
		}
		k := absFrom(folder, strings.TrimSpace(string(out)))
		if !seen[k] {
			seen[k] = true
			keys = append(keys, k)
		}
	}
	slices.Sort(keys)
	return keys, unlocked
}

// applier carries one apply: the evaluated items it updates in place and
// what it needs to re-check them.
type applier struct {
	deps   Deps
	req    Request // workbench resolved; sizes and display facts off for the re-checks
	git    gitCmd
	folder string
	items  []Item
	tips   map[string]string // branch -> the tip the apply's evaluation saw
	halt   error             // set by a failure that stops the apply
	self   int               // this process: never an orphan
	walked map[string]string // W9 walks of the evaluation, reused until the final re-check
	report *reporter         // the request's Observer; the re-checks' builders have none
	// evidence is the plan's observed.evidence: which worktrees showed a
	// branch was the session's (§2a, §2b, §2c).
	evidence map[string][]string
}

func newApplier(b *builder, p Plan, only []string) *applier {
	a := &applier{deps: b.deps, req: b.req, git: b.repo.git, folder: b.repo.folder, items: p.Items,
		tips: map[string]string{}, self: b.self, walked: b.walked, report: b.report, evidence: b.seen.evidence}
	a.req.NoSize, a.req.Observer, a.req.recheck = true, nil, true
	for _, br := range b.repo.branches {
		a.tips[br.Name] = br.Sha
	}
	a.selectItems(only)
	return a
}

// selectItems keeps every eligible item only does not name, and lists the
// named keys the evaluation does not have as kept not_in_plan.
func (a *applier) selectItems(only []string) {
	if len(only) == 0 {
		return
	}
	named := map[string]bool{}
	for _, k := range only {
		named[k] = true
	}
	for i := range a.items {
		it := &a.items[i]
		delete(named, it.Key)
		if it.Action == ActionRemove && !containsKey(only, it.Key) {
			keepItem(it, ReasonNotSelected, "")
		}
	}
	for _, k := range only {
		if named[k] {
			delete(named, k)
			a.items = append(a.items, Item{Key: k, Kind: kindOfKey(k), Name: k, Action: ActionKeep,
				Reason: ReasonNotInPlan})
		}
	}
}

func containsKey(keys []string, key string) bool {
	return slices.Contains(keys, key)
}

func kindOfKey(key string) Kind {
	prefix, _, _ := strings.Cut(key, ":")
	return Kind(prefix)
}

func keepItem(it *Item, reason, detail string) {
	it.Action, it.Reason, it.Detail, it.Done = ActionKeep, reason, detail, false
}

// run acts on the selected items: worktrees first, then branches (B2 sees
// the removed worktrees), then the sweep's stale LaunchServices entries.
func (a *applier) run(ctx context.Context) {
	for _, kind := range []Kind{KindWorktree, KindBranch} {
		for i := range a.items {
			if a.items[i].Kind == kind && a.items[i].Action == ActionRemove {
				a.actReported(ctx, i)
			}
		}
	}
	for i := range a.items {
		if a.items[i].Kind == KindLsreg && a.items[i].Action == ActionRemove && a.ownerRoot(a.items[i]) == "" {
			a.actReported(ctx, i)
		}
	}
	a.settleDependents()
}

// actReported is act between the Observer's Removing and Removed.
func (a *applier) actReported(ctx context.Context, i int) {
	a.report.removing(a.items[i].Key)
	a.act(ctx, i)
	a.report.removed(a.items[i])
}

// act re-checks and removes one item, unless the apply has stopped.
func (a *applier) act(ctx context.Context, i int) {
	it := &a.items[i]
	if a.halt == nil && ctx.Err() != nil {
		a.halt = ctx.Err()
	}
	if a.halt != nil {
		keepItem(it, ReasonNotAttempted, "stopped after an earlier failure: "+a.halt.Error())
		return
	}
	switch it.Kind {
	case KindWorktree:
		a.removeWorktree(ctx, it)
	case KindBranch:
		a.deleteBranch(ctx, it)
	case KindLsreg:
		a.unregisterStale(ctx, it)
	case KindProcess:
		// A process is stopped only by its worktree's removal
		// (clearOrphans); on its own it is never signalled.
		keepItem(it, ReasonNotAttempted, "a process is stopped only with its worktree")
	}
}

// fresh is a new evaluation of the request: the re-check's facts.
func (a *applier) fresh(ctx context.Context) (*builder, error) {
	if err := benchFolderGone(ctx, a.deps, a.req); err != nil {
		return nil, fmt.Errorf("re-checking: %w", err)
	}
	r := a.req
	if r.liveNow != nil {
		live, err := r.liveNow(ctx)
		if err != nil {
			return nil, fmt.Errorf("re-checking: %w: %w", errLiveUnreadable, err)
		}
		r.LiveSessions = live
	}
	b, err := newBuilder(ctx, a.deps, r)
	if err != nil {
		return nil, fmt.Errorf("re-checking: %w", err)
	}
	return b, nil
}

// ErrSessionNotEnded is returned when a RequireEnded apply finds the session's finish gone
// (resumed) or the session being deleted; nothing more is removed.
var ErrSessionNotEnded = errors.New("the session is no longer finished")

// stillEnded is RequireEnded's check on fresh facts b before a removal: a
// session no longer finished stops the apply (check_failed, the rest
// not_attempted).
func (a *applier) stillEnded(it *Item, b *builder) bool {
	if b.endStands() {
		return true
	}
	a.fail(it, ErrSessionNotEnded)
	return false
}

// fail keeps it as check_failed and stops the apply.
func (a *applier) fail(it *Item, err error) {
	keepItem(it, ReasonCheckFailed, err.Error())
	a.halt = err
}

// removeWorktree clears the worktree's orphans, unregisters its bundles,
// re-checks it once more and only then runs `git worktree remove`, a locked
// one unlocked right before it (removeWorktreeNow). When it stays, the
// bundles unregistered for it are registered again.
func (a *applier) removeWorktree(ctx context.Context, it *Item) {
	root := strings.TrimPrefix(it.Key, "worktree:")
	if !a.clearOrphans(ctx, it, root) {
		return
	}
	a.unregisterBundles(ctx, root)
	// The final re-check runs under the worktree lock, right before the
	// removal: a wait for the lock never stands between them.
	lctx, cancelLock := context.WithTimeout(ctx, worktreeRemoveTimeout)
	unlock, err := a.lockWorktrees(lctx)
	cancelLock()
	if err != nil {
		a.fail(it, err)
	} else {
		if b, ok := a.recheckClear(ctx, it, root, "process in use: ", true); ok {
			a.removeWorktreeNow(ctx, it, root, b)
		}
		unlock()
	}
	if !it.Done {
		a.reregisterBundles(ctx, root)
	}
}

// lockWorktrees takes the repository's worktree lock (workbenchgit.LockWorktrees),
// so the removal never races a session start's or a coach publish's
// `worktree add` (#2394). A common dir git cannot tell is a failure: the
// worktree stays.
func (a *applier) lockWorktrees(ctx context.Context) (func(), error) {
	out, err := a.git.output(ctx, a.folder, "rev-parse", "--git-common-dir")
	if err != nil {
		return nil, fmt.Errorf("locating the repository for the worktree lock: %w", err)
	}
	return workbenchgit.LockWorktrees(ctx, absFrom(a.folder, strings.TrimSpace(string(out))))
}

// settleGit records a git removal: done, refused (kept with git's words,
// the apply goes on) or a failure that stops the apply.
func (a *applier) settleGit(it *Item, code int, err error) {
	var gitErr *GitError
	switch {
	case err == nil:
		it.Done = true
	case code > 0 && errors.As(err, &gitErr):
		keepItem(it, ReasonGitRefused, strings.TrimSpace(gitErr.Stderr))
	default:
		a.fail(it, err)
	}
}

// recheckWorktree re-evaluates root with fresh facts; false keeps it. W9's
// walk is the evaluation's unless walk asks for a new one (the final
// re-check); `git worktree list` is always read afresh.
func (a *applier) recheckWorktree(ctx context.Context, it *Item, root string, walk bool) (*builder, bool) {
	b, err := a.fresh(ctx)
	if err != nil {
		a.fail(it, err)
		return nil, false
	}
	if !a.stillEnded(it, b) {
		return nil, false
	}
	if !walk {
		b.walked = a.walked
	}
	for _, w := range b.repo.worktrees {
		if w.Root != root || w.Bare {
			continue
		}
		ev := b.evaluateWorktree(ctx, w)
		if ev.Action != ActionRemove {
			keepItem(it, ev.Reason, ev.Detail)
			return nil, false
		}
		// The repository pass took the worktree for being idle: right
		// before the removal it still must be (#2402 §2).
		if admin := b.repo.adminDirs[root]; walk && a.req.repoPass && (admin == "" || !isIdle(ctx, a.deps, root, admin)) {
			keepItem(it, reasonNotIdle, "active again since the pass chose it")
			return nil, false
		}
		// The walks above can take long; a quiet session may have reopened
		// meanwhile: read its activity once more, right before the removal.
		switch ok, err := a.quietStillStands(ctx); {
		case err != nil:
			a.fail(it, err)
			return nil, false
		case !ok:
			a.fail(it, ErrSessionNotEnded)
			return nil, false
		}
		return b, true
	}
	keepItem(it, ReasonNotAWorktree, "git no longer lists it")
	return nil, false
}

// clearOrphans re-checks the worktree and, in session mode, stops its
// orphans: only when the plan named every one of them, SIGTERM to each,
// then process scans alone until none is left or the grace runs out, then
// one full re-check. True when the worktree may be removed now.
func (a *applier) clearOrphans(ctx context.Context, it *Item, root string) bool {
	b, ok := a.recheckWorktree(ctx, it, root, false)
	if !ok {
		return false
	}
	orphans, _ := OrphansIn(b.procs, []string{root}, a.self)
	if len(orphans) == 0 {
		a.markGone(root, b.procs)
		return true
	}
	if a.req.Sweep || a.req.NoTerminate {
		// The sweep never signals (its catch keeps such a worktree), nor
		// does an automatic apply.
		keepItem(it, ReasonProcessRunning, "process in use: "+procText(orphans[0]))
		return false
	}
	if !a.terminate(it, orphans) || !a.awaitExit(ctx, it, root) {
		return false
	}
	_, ok = a.recheckClear(ctx, it, root, "survived SIGTERM: ", false)
	return ok
}

// recheckClear is a full re-check of root that also wants no orphan left
// (prefix words the keep detail of one that is); the process items of
// root that are gone are marked done; walk as in recheckWorktree. The
// fresh facts come back with true.
func (a *applier) recheckClear(ctx context.Context, it *Item, root, prefix string, walk bool) (*builder, bool) {
	b, ok := a.recheckWorktree(ctx, it, root, walk)
	if !ok {
		return nil, false
	}
	if orphans, _ := OrphansIn(b.procs, []string{root}, a.self); len(orphans) > 0 {
		keepItem(it, ReasonProcessRunning, prefix+procText(orphans[0]))
		return nil, false
	}
	a.markGone(root, b.procs)
	return b, true
}

// awaitExit re-runs the process scan alone each poll step until no orphan
// of root is left (true) or the grace runs out (kept, false).
func (a *applier) awaitExit(ctx context.Context, it *Item, root string) bool {
	deadline := time.Now().Add(a.grace())
	for {
		if !a.pause(ctx, it) {
			return false
		}
		procs, err := a.deps.Procs.Scan(ctx)
		if err != nil {
			a.fail(it, fmt.Errorf("re-scanning processes: %w", err))
			return false
		}
		orphans, _ := OrphansIn(procs, []string{root}, a.self)
		if len(orphans) == 0 {
			return true
		}
		if time.Now().After(deadline) {
			keepItem(it, ReasonProcessRunning, "survived SIGTERM: "+procText(orphans[0]))
			return false
		}
	}
}

func (a *applier) grace() time.Duration {
	if a.deps.OrphanGrace > 0 {
		return a.deps.OrphanGrace
	}
	return defaultOrphanGrace
}

func (a *applier) pause(ctx context.Context, it *Item) bool {
	select {
	case <-ctx.Done():
		a.fail(it, ctx.Err())
		return false
	case <-time.After(orphanPollStep):
		return true
	}
}

func procKey(p Proc) string { return fmt.Sprintf("process:%d:%s", p.PID, p.Start) }

func procText(p Proc) string { return fmt.Sprintf("%s pid %d", procLabel(p), p.PID) }

// terminate signals the orphans only when the apply's evaluation listed
// every one of them, as the same process (the key carries the start time),
// and it is selected; otherwise none is signalled and the worktree stays.
func (a *applier) terminate(it *Item, orphans []Proc) bool {
	for _, p := range orphans {
		if pi := a.find(procKey(p)); pi == nil || pi.Action != ActionRemove {
			keepItem(it, ReasonProcessRunning, "orphan not named by the plan: "+procText(p))
			return false
		}
	}
	for _, p := range orphans {
		if err := a.deps.Procs.Terminate(p); err != nil && !errors.Is(err, errPidReused) {
			a.find(procKey(p)).Error = err.Error()
			keepItem(it, ReasonProcessRunning, "stopping "+procText(p)+": "+err.Error())
			return false
		}
	}
	return true
}

// markGone marks done the selected process items of root that the scan
// no longer lists: stopped by the apply or exited on their own.
func (a *applier) markGone(root string, procs []Proc) {
	alive := map[string]bool{}
	for _, p := range procs {
		alive[procKey(p)] = true
	}
	for i := range a.items {
		it := &a.items[i]
		if it.Kind == KindProcess && it.Action == ActionRemove && !alive[it.Key] && a.ownerRoot(*it) == root {
			it.Done = true
		}
	}
}

func (a *applier) find(key string) *Item {
	for i := range a.items {
		if a.items[i].Key == key {
			return &a.items[i]
		}
	}
	return nil
}

// ownerRoot is the root of the worktree item a process or LaunchServices
// item lies in ("" for none: a stale LaunchServices entry).
func (a *applier) ownerRoot(it Item) string {
	for _, w := range a.items {
		root := strings.TrimPrefix(w.Key, "worktree:")
		if w.Kind == KindWorktree && pathWithin(it.Detail, root) {
			return root
		}
	}
	return ""
}

// unregisterBundles runs `lsregister -u` for each selected bundle under
// root before the worktree goes (spec §7 step 3); a failure is the item's
// error and never blocks the removal.
func (a *applier) unregisterBundles(ctx context.Context, root string) {
	for i := range a.items {
		it := &a.items[i]
		if it.Kind != KindLsreg || it.Action != ActionRemove || !pathWithin(it.Detail, root) {
			continue
		}
		if a.deps.LS == nil {
			it.Error = "LaunchServices is not available"
			continue
		}
		if err := a.deps.LS.Unregister(ctx, it.Detail); err != nil {
			it.Error = err.Error()
			continue
		}
		it.Done = true
	}
}

// bundleRegisterTimeout bounds registering a stayed worktree's bundles
// again, on a ctx of its own (reregisterBundles).
const bundleRegisterTimeout = 30 * time.Second

// reregisterBundles registers again the bundles unregistered for root
// when root stays: they are reported kept, not removed. It runs on a ctx
// that ignores the apply's cancellation, bounded by bundleRegisterTimeout
// (as relock does): an apply stopped after the unregister still leaves
// the worktree's entries as they were (#2402 fix round 2, R2-6).
func (a *applier) reregisterBundles(ctx context.Context, root string) {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), bundleRegisterTimeout)
	defer cancel()
	for i := range a.items {
		it := &a.items[i]
		if it.Kind != KindLsreg || !it.Done || !pathWithin(it.Detail, root) {
			continue
		}
		keepItem(it, ReasonWorktreeKept, it.Detail)
		if err := a.deps.LS.Register(ctx, it.Detail); err != nil {
			it.Error = "unregistered; registering it again failed: " + err.Error()
		}
	}
}

// unregisterStale drops a sweep's stale LaunchServices entry when its
// bundle is still gone.
func (a *applier) unregisterStale(ctx context.Context, it *Item) {
	if a.deps.LS == nil {
		it.Error = "LaunchServices is not available"
		return
	}
	switch _, err := os.Lstat(it.Detail); {
	case err == nil:
		keepItem(it, ReasonBundleExists, it.Detail)
		return
	case !errors.Is(err, os.ErrNotExist):
		keepItem(it, ReasonBundleUnreadable, it.Detail+": "+err.Error())
		return
	}
	if err := a.deps.LS.Unregister(ctx, it.Detail); err != nil {
		it.Error = err.Error()
		return
	}
	it.Done = true
}

// deleteBranch re-checks the branch against fresh facts and the tip the
// apply's evaluation saw, then deletes exactly that tip.
func (a *applier) deleteBranch(ctx context.Context, it *Item) {
	tip, ok := a.recheckBranch(ctx, it)
	if !ok || !a.notCheckedOutNow(ctx, it) {
		return
	}
	// The last thing before the ref delete: a quiet session's activity read
	// afresh (the evaluation above and the re-listing can take long).
	switch ok, err := a.quietStillStands(ctx); {
	case err != nil:
		a.fail(it, err)
		return
	case !ok:
		a.fail(it, ErrSessionNotEnded)
		return
	}
	gctx, cancel := context.WithTimeout(ctx, gitTimeout)
	defer cancel()
	_, code, err := a.git.run.RunGit(gctx, a.folder, a.git.bin, "update-ref", "-d", "refs/heads/"+it.Name, tip)
	a.settleGit(it, code, err)
	if it.Reason == ReasonGitRefused && strings.Contains(it.Detail, "but expected") {
		it.Reason = ReasonMoved // the compare-and-delete saw another tip
	}
	if it.Done {
		a.dropBranchConfig(ctx, it)
	}
}

func (a *applier) recheckBranch(ctx context.Context, it *Item) (string, bool) {
	b, err := a.fresh(ctx)
	if err != nil {
		a.fail(it, err)
		return "", false
	}
	if !a.stillEnded(it, b) {
		return "", false
	}
	tip, ok := b.repo.branchTip(it.Name)
	switch {
	case !ok:
		keepItem(it, ReasonNotABranch, "gone since the check")
		return "", false
	case tip != a.tips[it.Name]:
		keepItem(it, ReasonMoved, fmt.Sprintf("was %s, now %s", short(a.tips[it.Name]), short(tip)))
		return "", false
	}
	// The worktree that showed the branch was the session's may be one this
	// apply just removed, its HEAD log or record match gone with it. The
	// plan's evidence stands in for that worktree only: a fresh
	// not_this_session or created_unknown wins, and the rest of §2c — the
	// ref log, every other worktree's HEAD log — is read again now.
	// A ledger branch whose worktree this apply removed reads as unproven
	// now; that is the removal, not news, so only a HEAD log's own verdict
	// (checkedOutOnly) counts here.
	if a.ownedByRemoved(it.Name) && !b.seen.branches[it.Name] && !b.seen.checkedOutOnly[it.Name] &&
		!b.seen.unknown[it.Name] {
		switch owned, unknown := b.repo.recheckCreated(it.Name); {
		case owned:
			b.seen.branches[it.Name] = true
		case unknown:
			b.seen.unknown[it.Name] = true
		}
	}
	// Every worktree left now stays: B2 keeps a branch checked out in any.
	b.checkedOutIn, b.checkedOutStaying = map[string]string{}, map[string]string{}
	for _, w := range b.repo.worktrees {
		if w.Branch != "" {
			b.checkedOutIn[w.Branch], b.checkedOutStaying[w.Branch] = w.Root, w.Root
		}
	}
	ev := b.evaluateBranch(ctx, branchRef{Name: it.Name, Sha: tip})
	if ev.Action != ActionRemove {
		keepItem(it, ev.Reason, ev.Detail)
		return "", false
	}
	return tip, true
}

// ownedByRemoved: the plan owned branch name on the evidence of a worktree
// this apply removed.
func (a *applier) ownedByRemoved(name string) bool {
	for _, root := range a.evidence[name] {
		if it := a.find("worktree:" + root); it != nil && it.Done {
			return true
		}
	}
	return false
}

// notCheckedOutNow reads `git worktree list` once more right before the
// delete and keeps the branch when a worktree has it checked out now.
func (a *applier) notCheckedOutNow(ctx context.Context, it *Item) bool {
	out, err := a.git.output(ctx, a.folder, "worktree", "list", "--porcelain")
	if err != nil {
		a.fail(it, fmt.Errorf("re-listing worktrees: %w", err))
		return false
	}
	for _, w := range parseWorktrees(out) {
		if w.Branch == it.Name {
			keepItem(it, ReasonCheckedOut, resolvePath(w.Root))
			return false
		}
	}
	return true
}

// dropBranchConfig removes the deleted branch's config section; an absent
// section is fine, any other failure is the item's error.
func (a *applier) dropBranchConfig(ctx context.Context, it *Item) {
	gctx, cancel := context.WithTimeout(ctx, gitTimeout)
	defer cancel()
	_, _, err := a.git.run.RunGit(gctx, a.folder, a.git.bin, "config", "--remove-section", "branch."+it.Name)
	var gitErr *GitError
	if err != nil && !(errors.As(err, &gitErr) && strings.Contains(gitErr.Stderr, "no such section")) {
		it.Error = "branch deleted; its config section stays: " + err.Error()
	}
}

// settleDependents keeps the process and LaunchServices items that were
// not acted on: their worktree stayed, or the apply stopped first.
func (a *applier) settleDependents() {
	for i := range a.items {
		it := &a.items[i]
		if it.Action != ActionRemove || it.Done || it.Error != "" {
			continue
		}
		switch {
		case a.halt != nil:
			keepItem(it, ReasonNotAttempted, "stopped after an earlier failure: "+a.halt.Error())
		case it.Kind == KindProcess || it.Kind == KindLsreg:
			keepItem(it, ReasonWorktreeKept, it.Detail)
		}
	}
}

// removedBytes sums the measured removed worktrees; known is false when
// one of them was not measured.
func removedBytes(items []Item) (n int64, known bool) {
	known = true
	for _, it := range items {
		if it.Kind != KindWorktree || !it.Done {
			continue
		}
		if !it.BytesKnown {
			known = false
			continue
		}
		n += it.Bytes
	}
	return n, known
}

// save stores a session-mode result as cleanup_result. The stored copy
// says result_saved: it exists only when the write succeeded.
func (a *applier) save(ctx context.Context, res *Result) {
	if a.req.Sweep {
		return
	}
	if a.deps.Results == nil {
		res.ResultError = "the result was not saved: no result store"
		return
	}
	res.ResultSaved = true
	body, err := json.Marshal(res)
	if err == nil {
		sctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), resultSaveTimeout)
		defer cancel()
		err = a.deps.Results.SaveCleanupResult(sctx, res.SessionID, string(body), db.AgentStateStamp(clockNow(a.deps)))
	}
	if err != nil {
		res.ResultSaved, res.ResultError = false, err.Error()
	}
}
