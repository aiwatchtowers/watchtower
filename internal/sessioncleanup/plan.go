package sessioncleanup

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"sync"
	"time"

	"watchtower/internal/gitbin"
	"watchtower/internal/sessionagent"
	"watchtower/internal/workbenchgit"
)

// sizeBudget bounds the size walk of one worktree (spec §8).
const sizeBudget = 20 * time.Second

// sizeWorkers is how many worktrees are measured at the same time: one walk
// at a time made a sweep over dozens of large worktrees take minutes.
const sizeWorkers = 4

// checkWorkers is how many worktrees are checked at the same time: each
// check runs `git status`, and one at a time a sweep over dozens of
// worktrees spent most of its time waiting for them.
const checkWorkers = 4

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
	// PruneBuilds lets an apply that names no item, of a session that
	// ended (finished or being deleted), outside a terminal session,
	// delete the build output of the worktrees it keeps for their work
	// (#2131, builds.go), and the repository pass's (repoPass). Ignored
	// anywhere else — the owner's sweep included.
	PruneBuilds bool
	// NoTerminate: the apply signals no process; a worktree with an orphan
	// in it is kept (process_running), as in a sweep. The daemon's
	// automatic apply sets it (#2131): no owner action asked for it.
	NoTerminate bool
	// RequireEnded: the apply acts only while the session's finish stands
	// and it is not being deleted — checked on the facts read under the
	// repository locks, and again before each removal and prune; a session
	// resumed since it was listed loses nothing. The automatic apply sets
	// it (#2131).
	RequireEnded bool
	// Quiet: the session never called finish_session but has been quiet
	// for 24 h (#2402), so it counts as ended for the build prune like a
	// finished one. Only the automatic pass sets it, for a quiet row
	// (with RequireEnded off: there is no finish to re-check); the CLI
	// never does.
	Quiet bool
	// QuietBefore: with Quiet, the session stands as ended only while
	// its newest activity (last_active_at, agent_state_at) is at or before
	// this, re-read under the repository lock and before each removal; a
	// session that reopened since it was listed loses nothing. A row that
	// got finished meanwhile still stands as ended.
	QuietBefore time.Time
	// BuildsChecked are worktree roots whose build folders an earlier
	// automatic apply, since the session's finish, already found nothing
	// left to delete in: the prune does not walk them again.
	BuildsChecked []string
	Now           time.Time
	// Observer hears the evaluation (and an apply) as it goes; nil = no
	// events. Apply's re-checks never report.
	Observer Observer
	// recheck marks an apply's re-check: it never reports, so it reads no
	// display facts (dates, merged).
	recheck bool
	// folder is the bench folder whose repository one part of a sweep
	// evaluates (sweepBuilders); "" = the workbench's home folder.
	folder string
	// keyFolder qualifies the part's branch keys (branchKey): a branch name
	// is unique only within its repository. "" = a session's plan or the
	// sweep of a one-folder bench, whose keys stay as they always were.
	keyFolder string
	// staleUnder are the part's other bench folders over the same
	// repository: their stale LaunchServices entries are listed too.
	staleUnder []string
	// scope is the folder set Apply read once and locked (repoScope); nil
	// = read here as before (a plan).
	scope *repoScope
	// repoPass marks the daemon's repository pass (#2402 §2, repopass.go):
	// a sweep whose apply may prune the build output of the worktrees it
	// keeps (pruneBuilds). The owner's sweep never sets it.
	repoPass bool
	// onlyRoots, in a sweep, limits the evaluation to these worktree roots
	// and their branches, with no stale LaunchServices entry: the
	// repository pass's batch. nil = every worktree.
	onlyRoots map[string]bool
	// allOwners: in a sweep, every session that recorded a worktree, of
	// any workbench — a folder that left its bench included — is its owner
	// (W2), read afresh by every evaluation and re-check: the repository
	// pass's owners (#2402).
	allOwners bool
	// liveNow, when set, re-reads the session host's live runs for every
	// re-check (applier.fresh): a session the host started since
	// LiveSessions was read counts. An error fails the re-check.
	liveNow func(ctx context.Context) ([]int64, error)
	// repoKey, when set, is the git common dir whose cleanup lock the
	// caller holds (the repository pass): an evaluation whose folder now
	// resolves to another repository fails (errRepositoryMoved).
	repoKey string
}

// errRepositoryMoved: the evaluated folder resolves to another repository
// than the one whose lock is held.
var errRepositoryMoved = errors.New("the folder now belongs to another repository than the one locked")

// builder carries one evaluation's facts.
type builder struct {
	deps    Deps
	req     Request
	now     time.Time
	self    int
	repo    *repoState
	session SessionInfo // session mode
	seen    observed    // session mode
	// ledgerRoots are the roots the session's own cwd ledger recorded
	// (session mode): when its folder left the bench, only these can go.
	ledgerRoots map[string]bool
	folders     []string
	claudeHome  []string // ~/.claude as given and symlink-resolved
	homeErr     error    // the home directory is unknown: every worktree is kept
	procs       []Proc
	activity    map[int64]SessionActivity
	live        map[int64]bool
	rootOwners  map[string][]int64 // sweep
	// walked caches W9's walk per worktree root (nil = walk every time).
	// Apply shares one map between its evaluation and the early re-checks,
	// so a worktree is walked once there and once more right before
	// `git worktree remove`.
	walked map[string]string
	walkMu sync.Mutex // guards walked and judged: worktrees are checked concurrently
	// judged is, per root, the lock W3 let pass (merged and idle): the only
	// lock an apply may then unlock (unlock.go).
	judged map[string]lockSeen
	report *reporter
	// notes are the plan's notes (Plan.Notes), in session mode.
	notes []string
	// extras are each worktree to remove's orphans and bundles, found
	// right after its catches.
	extras map[string][]Item

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
	parts, err := evaluationBuilders(ctx, d, r)
	if err != nil {
		return Result{}, err
	}
	reportListing(parts)
	plans := make([]Plan, 0, len(parts))
	for _, b := range parts {
		plans = append(plans, b.evaluate(ctx))
	}
	p := mergePlans(plans)
	return Result{
		SessionID: r.SessionID, WorkbenchID: parts[0].req.WorkbenchID, Mode: ModePlan, Sweep: r.Sweep,
		Plan: p, RemovedBytesKnown: true, Summary: Summarize(p.Items),
	}, nil
}

// evaluate evaluates every candidate of the builder's facts; the listing
// was reported before (reportListing).
func (b *builder) evaluate(ctx context.Context) Plan {
	items := b.worktreeItems(ctx)
	items = append(items, b.branchItems(ctx, items)...)
	items = append(items, b.extraItems(ctx, items)...)
	return Plan{Items: items, DefaultBranch: b.repo.defaultBranch, Notes: append([]string{}, b.notes...)}
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
	b := &builder{deps: d, req: r, now: r.Now, self: os.Getpid(), live: map[int64]bool{},
		report: &reporter{obs: r.Observer}}
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
	if r.repoKey != "" && b.repo.commonDir != r.repoKey {
		return nil, fmt.Errorf("%w: %s, not %s", errRepositoryMoved, b.repo.commonDir, r.repoKey)
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

// loadRepo reads the repository of the folder the evaluation is for: the
// session's own folder (a session started for one of the bench's folders,
// #2003), a sweep part's folder, else the workbench's home folder.
func (b *builder) loadRepo(ctx context.Context, g gitCmd) error {
	folder := b.session.Folder
	if b.req.scope != nil && !b.req.Sweep {
		folder = b.req.scope.sessionFolder // the folder Apply locked
	}
	if folder == "" {
		folder = b.req.folder
	}
	if folder == "" && b.req.scope != nil {
		folder = b.req.scope.home
	}
	if folder == "" {
		home, err := b.deps.DB.WorkbenchFolder(ctx, b.req.WorkbenchID)
		if err != nil {
			return fmt.Errorf("reading workbench %d: %w", b.req.WorkbenchID, err)
		}
		folder = home
	}
	folder = resolvePath(folder)
	if !gitbin.InsideRepository(folder) {
		return fmt.Errorf("the workbench folder %s is not in a git repository", folder)
	}
	var err error
	b.repo, err = readRepo(ctx, g, folder, !b.req.recheck)
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
		// Tagged: a prune's re-check that cannot read who works where
		// stops the repository pass (R3-4).
		return fmt.Errorf("reading the terminal sessions: %w: %w", errLiveUnreadable, err)
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
	var owners map[string][]int64
	var err error
	if b.req.allOwners {
		if owners, err = b.deps.DB.SessionWorktreeOwners(ctx); err != nil {
			return fmt.Errorf("reading the session worktree owners: %w: %w", errLiveUnreadable, err)
		}
	} else if owners, err = b.deps.DB.WorkbenchSessionWorktrees(ctx, b.req.WorkbenchID); err != nil {
		return fmt.Errorf("reading workbench %d session worktrees: %w", b.req.WorkbenchID, err)
	}
	b.rootOwners = map[string][]int64{}
	for root, ids := range owners {
		// Two spellings of one root resolve to one key: each id once.
		key := resolvePath(root)
		for _, id := range ids {
			if !slices.Contains(b.rootOwners[key], id) {
				b.rootOwners[key] = append(b.rootOwners[key], id)
			}
		}
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
	b.ledgerRoots = map[string]bool{}
	for _, r := range rows {
		b.ledgerRoots[resolvePath(r.Root)] = true
	}
	b.observePlacement()
	if err := b.loadAgentFiles(ctx); err != nil {
		return err
	}
	return b.loadHeadLogs(ctx)
}

// loadAgentFiles adopts what the session's Claude Code sessions made, from
// the files Claude Code writes itself (auto cleanup spec 2026-11-10 §2a,
// §2b), only for a kind whose caps have ClaudeSessionFiles (an unknown kind
// adopts nothing): the worktrees its subagents were started in, with their
// branches (subagentWorktrees), and its scratchpad lanes
// (adoptScratchLanes). A failed read fails the plan.
func (b *builder) loadAgentFiles(ctx context.Context) error {
	if !sessionagent.CapsOf(b.session.Kind).ClaudeSessionFiles {
		return nil
	}
	acquired, err := b.countedAgentSessions(ctx)
	if err != nil || len(acquired) == 0 {
		return err
	}
	b.adoptScratchLanes(acquired)
	ended := b.session.Ended
	if b.live[b.session.ID] || b.req.CallerSessionID == b.session.ID {
		ended = time.Time{}
	}
	projects := defaultClaudeProjectsDir
	if b.deps.ClaudeProjects != nil {
		projects = b.deps.ClaudeProjects
	}
	roots, branches, note, err := subagentWorktrees(projects(), acquired, ended, b.repo.worktrees,
		bornAt{worktree: b.worktreeBirth, branch: b.repo.branchBirth})
	if err != nil {
		return fmt.Errorf("reading the subagent records of session %d: %w", b.session.ID, err)
	}
	for r := range roots {
		b.seen.roots[r], b.seen.ownRoots[r] = true, true
	}
	for br, root := range branches {
		b.seen.own(br, root)
	}
	if note {
		b.notes = append(b.notes, NoteSubagentRecordsUnreadable)
	}
	return nil
}

// countedAgentSessions is every agent session id of this row that counts
// (spec §2) with the moment the row acquired it: this row is its only
// owner (history or current id of any terminal session, and no deleted
// row's tombstone). A uuid shared by two rows, or with an unreadable
// acquisition time, counts for neither (fail closed).
func (b *builder) countedAgentSessions(ctx context.Context) (map[string]time.Time, error) {
	ids, err := b.deps.DB.AgentSessionIDs(ctx, b.session.ID)
	if err != nil {
		return nil, err
	}
	uuids := make([]string, 0, len(ids))
	for _, a := range ids {
		if a.ID != "" {
			uuids = append(uuids, a.ID)
		}
	}
	owners, err := b.deps.DB.AgentSessionIDOwners(ctx, uuids)
	if err != nil {
		return nil, err
	}
	acquired := map[string]time.Time{}
	for _, a := range ids {
		o := owners[a.ID]
		since, perr := time.Parse(time.RFC3339, a.Since)
		if a.ID != "" && perr == nil && len(o) == 1 && o[0] == b.session.ID {
			acquired[a.ID] = since
		}
	}
	return acquired, nil
}

// adoptScratchLanes adopts the session's Claude scratchpad lanes (spec
// §2b): a linked worktree strictly inside `<base>/claude-<uid>/<slug>/<uuid>/`
// for a counted uuid, born at or after the moment this row acquired the uuid
// (second precision, so +1 s, as bornReason): the order rows were deleted
// in, or a history gap, can leave this row the only owner of a uuid another
// row used first. The lane's checked-out branch is named only when born
// after that moment too. An unknown birth adopts nothing.
func (b *builder) adoptScratchLanes(acquired map[string]time.Time) {
	dirs := scratchDirs()
	for _, w := range b.repo.worktrees {
		if w.Main || w.Bare {
			continue
		}
		since, ok := scratchLane(dirs, acquired, w.Root)
		if !ok {
			continue
		}
		after := since.Add(time.Second)
		if birth, known := b.worktreeBirth(w.Root); !known || birth.Before(after) {
			continue
		}
		b.seen.roots[w.Root], b.seen.ownRoots[w.Root] = true, true
		if w.Branch == "" {
			continue
		}
		if birth, known := b.repo.branchBirth(w.Branch); known && !birth.Before(after) {
			b.seen.own(w.Branch, w.Root)
			b.seen.named[w.Branch] = true
		}
	}
}

// loadHeadLogs adds the branches created in the session's own linked
// worktrees (spec §2c, headLogBranches) for every agent kind, and decides
// the cwd ledger's branches. The worktrees read are the ones the session
// owns by the cwd ledger, by placement or by §2a/§2b (ownsWorktree); a
// prunable one's log is read from its admin dir. A ledger branch never
// bypasses §2c for such a worktree, nor for a ledger root no longer listed
// (removed, its HEAD log gone with it): it counts only when §2c names it,
// so a branch only checked out there — or in a worktree without a HEAD log
// — is not_this_session (left for the Clean Up screen). Any other ledger
// branch (the main folder, a worktree older than the session) counts as
// before. A branch another source holds (a target, the agent's
// declaration, placement by record, a subagent record or a scratchpad lane)
// keeps that source's standing. When an exclusion could not be checked
// (unknown), the named branches are kept as created_unknown. A worktree's
// own unreadable log fails the plan. Each branch §2c names records the
// worktrees that named it (observed.evidence).
func (b *builder) loadHeadLogs(ctx context.Context) error {
	unknown := false
	named, gated, listed := map[string][]string{}, map[string]bool{}, map[string]bool{}
	for _, w := range b.repo.worktrees {
		listed[w.Root] = true
		if w.Main || w.Bare || !b.ownsWorktree(w) {
			continue
		}
		gated[w.Root] = true
		n, switched, _, unk, err := headLogBranches(ctx, b.repo, w)
		if err != nil {
			return fmt.Errorf("reading the branches of %s: %w", w.Root, err)
		}
		unknown = unknown || unk
		for c := range n {
			named[c] = append(named[c], w.Root)
		}
		for c := range switched {
			b.seen.switchedTo[c], b.seen.checkedOutOnly[c] = true, true
		}
	}
	for c, roots := range b.seen.ledgerBranches {
		if b.seen.branches[c] {
			continue
		}
		if !slices.ContainsFunc(roots, func(r string) bool { return gated[r] || !listed[r] }) {
			b.seen.branches[c] = true
		} else if named[c] == nil {
			b.seen.switchedTo[c] = true
		}
	}
	for c, roots := range named {
		switch {
		case b.seen.branches[c]:
		case unknown:
			b.seen.unknown[c] = true
		default:
			for _, r := range roots {
				b.seen.own(c, r)
			}
		}
	}
	return nil
}

// ownsWorktree: w is the row's placed worktree, or one the cwd ledger,
// a subagent record or the scratchpad gave the session (never a target's
// or a declared name) and born after the session started.
func (b *builder) ownsWorktree(w worktree) bool {
	if b.seen.placedRoot != "" && w.Root == b.seen.placedRoot {
		return true
	}
	if !b.seen.ownRoots[w.Root] {
		return false
	}
	birth, known := b.worktreeBirth(w.Root)
	return bornReason(birth, known, b.session.CreatedAt) == ""
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
	b.extras = map[string][]Item{}
	known := map[string]bool{}
	var toCheck []worktree
	for _, w := range b.repo.worktrees {
		known[w.Root] = true
		if w.Branch != "" {
			b.checkedOutIn[w.Branch] = w.Root
		}
		if !w.Bare && b.listsWorktree(w) {
			toCheck = append(toCheck, w)
		} else {
			b.markStaying(w)
		}
	}
	// The catches of different worktrees are independent reads: run them
	// checkWorkers at a time, then take the results in listing order on this
	// goroutine, so the maps, the events and the items keep today's order.
	results := b.evaluateWorktrees(ctx, toCheck)
	for i, w := range toCheck {
		it := <-results[i]
		if it.Action == ActionKeep {
			b.markStaying(w)
		}
		b.report.checked(it)
		if it.Action == ActionRemove && it.Detail != detailGone {
			b.extras[w.Root] = b.worktreeExtras(w.Root)
			b.report.checked(b.extras[w.Root]...)
		}
		items = append(items, it)
	}
	undeclared := b.undeclaredWorktrees(known)
	b.report.checked(undeclared...)
	return append(items, undeclared...)
}

// evaluateWorktrees evaluates the worktrees checkWorkers at a time, in
// listing order; result i arrives on results[i].
func (b *builder) evaluateWorktrees(ctx context.Context, list []worktree) []chan Item {
	results := make([]chan Item, len(list))
	for i := range results {
		results[i] = make(chan Item, 1)
	}
	next := make(chan int)
	var wg sync.WaitGroup
	for range min(checkWorkers, len(list)) {
		wg.Go(func() {
			for i := range next {
				results[i] <- b.evaluateWorktree(ctx, list[i])
			}
		})
	}
	go func() {
		for i := range list {
			next <- i
		}
		close(next)
		wg.Wait()
	}()
	return results
}

// worktreeExtras are root's orphans (session mode only — the sweep never
// signals) and its .app bundles.
func (b *builder) worktreeExtras(root string) []Item {
	var extra []Item
	if !b.req.Sweep {
		extra = append(extra, b.orphanItems(root)...)
	}
	return append(extra, b.bundleItems(root)...)
}

// listing is the Observer's Listed: the listed worktrees, then the branch
// candidates not checked out in one of them (sweep: in any worktree), with
// no action yet. It runs no catch but the structural one.
func (b *builder) listing() []Item {
	items := []Item{}
	known, ofListed, ofAny := map[string]bool{}, map[string]bool{}, map[string]bool{}
	var listedTrees []Item
	for _, w := range b.repo.worktrees {
		known[w.Root] = true
		if w.Branch != "" {
			ofAny[w.Branch] = true
		}
		if w.Bare || !b.listsWorktree(w) {
			continue
		}
		if w.Branch != "" {
			ofListed[w.Branch] = true
		}
		listedTrees = append(listedTrees, Item{Key: "worktree:" + w.Root, Kind: KindWorktree,
			Name: filepath.Base(w.Root), Branch: w.Branch, BranchKey: b.worktreeBranchKey(w)})
	}
	items = append(items, listedTrees...)
	for _, it := range b.undeclaredWorktrees(known) {
		it.Action, it.Reason = "", ""
		items = append(items, it)
	}
	var names []string
	if b.req.Sweep {
		set := map[string]bool{}
		for _, br := range b.repo.branches {
			if br.Name != b.repo.defaultBranch && !ofAny[br.Name] {
				set[br.Name] = true
			}
		}
		names = sortedKeys(set)
	} else {
		names = b.branchCandidates(listedTrees)
	}
	for _, name := range names {
		if !ofListed[name] {
			items = append(items, Item{Key: b.branchKey(name), Kind: KindBranch, Name: name, Branch: name})
		}
	}
	return items
}

func (b *builder) markStaying(w worktree) {
	if w.Branch != "" {
		b.checkedOutStaying[w.Branch] = w.Root
	}
}

func (b *builder) listsWorktree(w worktree) bool {
	structural, _, _ := catchFolders(context.Background(), b, w)
	if b.req.Sweep {
		return structural == "" && (b.req.onlyRoots == nil || b.req.onlyRoots[w.Root])
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
		BranchKey: b.worktreeBranchKey(w), Action: ActionRemove}
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
	it.Origin = string(workbenchgit.WorktreeOrigin(b.repo.mainRoot(), w.Root, w.Branch))
	if it.Owner != nil && !it.Owner.Unknown {
		it.Origin = string(workbenchgit.OriginSession)
	}
	if b.req.recheck {
		return it
	}
	if head, err := b.repo.recordedHead(w); err == nil {
		it.LastCommitAt = b.repo.commitDate(ctx, head)
		it.Merged = b.repo.isMerged(ctx, head)
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
			items = append(items, Item{Key: b.branchKey(name), Kind: KindBranch, Name: name, Branch: name,
				Action: ActionKeep, Reason: ReasonNotABranch})
		} else {
			items = append(items, b.evaluateBranch(ctx, branchRef{Name: name, Sha: sha}))
		}
		b.report.checked(items[len(items)-1])
	}
	return items
}

// branchCandidates: in session mode the observed branches that exist
// (the §2c candidates only switched to or undecided included), the
// branches of listed worktrees and every declared one (the default branch
// only when declared); in the sweep every local branch but the default and
// the ones checked out in a worktree that stays.
func (b *builder) branchCandidates(worktreeItems []Item) []string {
	set := map[string]bool{}
	if b.req.Sweep && b.req.onlyRoots != nil {
		// The batch's branches only: those of its worktrees that may go.
		for _, it := range worktreeItems {
			if it.Kind == KindWorktree && it.Action == ActionRemove && it.Branch != "" &&
				it.Branch != b.repo.defaultBranch {
				set[it.Branch] = true
			}
		}
		return sortedKeys(set)
	}
	if b.req.Sweep {
		for _, br := range b.repo.branches {
			_, staying := b.checkedOutStaying[br.Name]
			if br.Name != b.repo.defaultBranch && !staying {
				set[br.Name] = true
			}
		}
		return sortedKeys(set)
	}
	for _, seen := range []map[string]bool{b.seen.branches, b.seen.switchedTo, b.seen.unknown} {
		for name := range seen {
			if _, ok := b.repo.branchTip(name); ok && name != b.repo.defaultBranch {
				set[name] = true
			}
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
	it := Item{Key: b.branchKey(br.Name), Kind: KindBranch, Name: br.Name, Branch: br.Name, Action: ActionRemove,
		BytesKnown: true}
	if !b.req.recheck {
		it.LastCommitAt, it.Merged = b.repo.commitDate(ctx, br.Sha), b.repo.isMerged(ctx, br.Sha)
	}
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

// extraItems are, per worktree to remove, its size and its extras (found
// with its catches); and in the sweep the stale LaunchServices entries
// under the workbench folder.
func (b *builder) extraItems(ctx context.Context, items []Item) []Item {
	var removed []int
	for i, it := range items {
		if it.Kind == KindWorktree && it.Action == ActionRemove && it.Detail != detailGone {
			removed = append(removed, i)
		}
	}
	// Bundles and orphans were found before the slow size walks, so a
	// listing can show them while the sizes are still coming in.
	var extra []Item
	for _, i := range removed {
		extra = append(extra, b.extras[items[i].Key[len("worktree:"):]]...)
	}
	b.measureAll(ctx, items, removed)
	stale := b.staleItems(ctx)
	b.report.checked(stale...)
	return append(extra, stale...)
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
			b.report.sized(it.Key, it.Bytes, it.BytesKnown)
		})
	}
	wg.Wait()
}

func (b *builder) orphanItems(root string) []Item {
	orphans, _ := OrphansIn(b.procs, []string{root}, b.self)
	items := make([]Item, 0, len(orphans))
	for _, p := range orphans {
		items = append(items, Item{Key: procKey(p), Kind: KindProcess,
			Name: filepath.Base(p.Exe), Detail: p.Exe, Action: ActionRemove, BytesKnown: true, Worktree: root})
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
			Detail: bundle, Action: ActionRemove, BytesKnown: true, Worktree: root})
	}
	return items
}

func (b *builder) staleItems(ctx context.Context) []Item {
	if !b.req.Sweep || b.req.onlyRoots != nil || b.deps.LS == nil {
		return nil
	}
	var items []Item
	for _, folder := range append([]string{b.repo.folder}, b.req.staleUnder...) {
		stale, err := b.deps.LS.Stale(ctx, folder)
		if err != nil {
			items = append(items, Item{Key: "lsreg:" + folder, Kind: KindLsreg, Name: "LaunchServices",
				Action: ActionKeep, Reason: ReasonCheckFailed, Detail: err.Error()})
			continue
		}
		for _, bundle := range stale {
			items = append(items, Item{Key: "lsreg:" + bundle, Kind: KindLsreg, Name: filepath.Base(bundle),
				Detail: bundle, Action: ActionRemove, BytesKnown: true})
		}
	}
	return items
}
