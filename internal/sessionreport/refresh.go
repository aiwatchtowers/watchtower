package sessionreport

import (
	"context"
	"database/sql"
	"fmt"
	"maps"
	"slices"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/gitbin"
	"watchtower/internal/workbenchcheck"
)

// DefaultRefreshBudget bounds one Refresh: every git and gh call together.
const DefaultRefreshBudget = 10 * time.Second

// SummaryRefreshBudget bounds the git-only refresh of the merge verdicts
// that `session-report --summary` runs before its row lines (board #986).
const SummaryRefreshBudget = 3 * time.Second

// summaryWriteWait is how long one cache write of the --summary refresh
// waits for another process's write lock (cut to the budget left): the
// write is best effort — its verdict still reaches this run's rows — so it
// never holds the row lines up behind the daemon for the handle's 5 s.
const summaryWriteWait = 250 * time.Millisecond

// A cached ref is re-checked once it is older than freshFor, or older than
// settledFor when its pull request is merged or closed (rarely changes).
const (
	freshFor   = 60 * time.Second
	settledFor = 10 * time.Minute
)

// prFields is what `gh pr view` / `gh pr list` are asked for.
const prFields = "state,title,additions,deletions,mergedAt"

// run runs git and gh; a variable so a test can count the processes.
var run workbenchcheck.Runner = workbenchcheck.ExecRunner

// setWriteWait sets the handle's busy_timeout before a cache write; a
// variable so a test can see each write's wait without waiting it out.
var setWriteWait = (*db.DB).SetBusyTimeout

// RefreshOptions configures one Refresh.
type RefreshOptions struct {
	// Network allows reading pull requests through the gh CLI; without it
	// only the branches' git merge state is read.
	Network bool
	Budget  time.Duration    // 0 = DefaultRefreshBudget
	Now     func() time.Time // nil = time.Now
	// writeWait > 0 bounds each cache write's lock wait (the handle's
	// busy_timeout, set before each write and left at the last one's), cut
	// to the budget left (at least 1 ms).
	// RefreshedSummaries sets it, on the CLI's own handle.
	writeWait time.Duration
}

// RefreshResult is the outcome of one Refresh.
type RefreshResult struct {
	// Note says why PR state may be incomplete (gh missing, no network,
	// budget hit, a read that failed), or is empty.
	Note string
}

// prJSON is gh's pull request shape.
type prJSON struct {
	Number    int64  `json:"number"`
	State     string `json:"state"`
	Title     string `json:"title"`
	Additions int64  `json:"additions"`
	Deletions int64  `json:"deletions"`
	MergedAt  string `json:"mergedAt"`
}

// Refresh updates the PR cache of workbench workbenchID for refs ('pr:<n>',
// 'branch:<name>' or 'into:<base>:<branch>', a merge verdict that only ever
// runs git). Only refs whose cached row is stale are checked, within
// opts.Budget; a ref not checked keeps its cached row (none = unknown). It
// never fails: anything it could not check is named in the note. It writes
// the cache only — never the board, so PROJ-07's drift check stays the only
// place that flags merged_but_open.
func Refresh(ctx context.Context, d *db.DB, workbenchID int64, refs []string, opts RefreshOptions) RefreshResult {
	res, _, _ := refresh(ctx, d, workbenchID, refs, opts)
	return res
}

// refresh is Refresh, also returning the cache as it stands afterwards (the
// rows read before, with every row it read; nil when the cache could not be
// read) and the stale refs it could not check (unchecked): a read that
// failed — a git call, an unresolvable base, gh — or one the budget left
// out. A folder outside a repository leaves none unchecked: git has nothing
// to say there, now or later.
func refresh(ctx context.Context, d *db.DB, workbenchID int64, refs []string,
	opts RefreshOptions) (res RefreshResult, cache map[string]db.PRState, unchecked map[string]bool) {
	if opts.Budget <= 0 {
		opts.Budget = DefaultRefreshBudget
	}
	if opts.Now == nil {
		opts.Now = time.Now
	}
	wb, err := d.GetWorkbench(workbenchID)
	if err != nil {
		return RefreshResult{Note: "PR states not refreshed: " + err.Error()}, nil, nil
	}
	cache, err = d.PRStates(workbenchID)
	if err != nil {
		return RefreshResult{Note: "PR states not refreshed: " + err.Error()}, nil, nil
	}
	start := opts.Now()
	var stale []string
	seen := map[string]bool{}
	for _, ref := range refs {
		if seen[ref] {
			continue
		}
		seen[ref] = true
		if row, ok := cache[ref]; !ok || isStale(row, start) {
			stale = append(stale, ref)
		}
	}
	if len(stale) == 0 {
		return RefreshResult{}, cache, nil
	}
	// Longest due first (never checked before all): a ref that keeps
	// reading no verdict is stamped too — a failed read due again at once
	// (dueAgain), so it is the most recently due and waits behind every
	// other ref instead of spending the budget ahead of them.
	slices.SortStableFunc(stale, func(a, b string) int { return dueSince(cache[a]).Compare(dueSince(cache[b])) })
	ctx, cancel := context.WithTimeout(ctx, opts.Budget)
	defer cancel()
	deadline := start.Add(opts.Budget)
	r := refresher{d: d, workbenchID: workbenchID, folder: wb.FolderPath, cache: cache, opts: opts, deadline: deadline,
		unchecked: map[string]bool{}}
	r.open(ctx, stale)
	for i, ref := range stale {
		// A ref whose read the budget cut short counts as not checked.
		if ctx.Err() != nil || opts.Now().After(deadline) || !r.check(ctx, ref) {
			r.note(fmt.Sprintf("the %s time budget ran out; %d ref(s) keep their cached state", opts.Budget, len(stale)-i))
			if r.inRepo {
				for _, left := range stale[i:] {
					r.unchecked[left] = true
				}
			}
			break
		}
	}
	r.noteGuards()
	r.noteSkipped()
	r.noteUnsaved()
	return RefreshResult{Note: strings.Join(r.notes, "; ")}, cache, r.unchecked
}

// isStale: the row is old enough to check again (or its time unreadable).
func isStale(row db.PRState, now time.Time) bool {
	at, err := time.Parse(time.RFC3339, row.CheckedAt)
	if err != nil {
		return true
	}
	return now.Sub(at) > staleAfter(row.State)
}

// dueSince is when row became due for a check: its check time plus its
// fresh window; the zero time for a row never checked or unreadable.
func dueSince(row db.PRState) time.Time {
	at, err := time.Parse(time.RFC3339, row.CheckedAt)
	if err != nil {
		return time.Time{}
	}
	return at.Add(staleAfter(row.State))
}

// staleAfter is how long a row in state stays fresh.
func staleAfter(state string) time.Duration {
	if state == "merged" || state == "closed" {
		return settledFor
	}
	return freshFor
}

// refresher holds what every ref's check shares.
type refresher struct {
	d           *db.DB
	workbenchID int64
	folder      string
	cache       map[string]db.PRState
	opts        RefreshOptions
	deadline    time.Time                             // the budget's end
	inRepo      bool                                  // the folder is inside a git repository
	repo        *workbenchcheck.Repository            // against the default branch; nil outside a repository or with into: refs only
	bases       map[string]*workbenchcheck.Repository // against each into: base, opened on first use
	gh          bool                                  // gh is installed, signed in and allowed
	notes       []string
	skipped     int             // refs whose state could not be read
	firstErr    string          // why the first of them could not
	unchecked   map[string]bool // stale refs this run could not check
	unsaved     int             // refs read, but their cache write failed
	firstUnsave string          // why the first of them failed
}

// open probes the repository and gh once. A plain folder runs no git — and
// no gh, which would run git from PATH and cannot name a PR without a
// repository anyway. With only into: refs stale neither the default branch
// nor gh is read: a merge verdict runs git against its own base.
func (r *refresher) open(ctx context.Context, stale []string) {
	if !gitbin.InsideRepository(r.folder) {
		r.note("the folder is not a git work tree; branch and pull request states not checked")
		return
	}
	r.inRepo = true
	if !slices.ContainsFunc(stale, func(ref string) bool { return !strings.HasPrefix(ref, intoPrefix) }) {
		return
	}
	r.repo = workbenchcheck.OpenRepository(ctx, r.folder, run)
	r.notes = append(r.notes, r.repo.Notes()...)
	switch {
	case !r.opts.Network:
		r.note("network off; pull request states not checked")
	case r.repo.GitMissing():
		r.note("git is not available; pull request states not checked")
	case ctx.Err() == nil:
		ok, note := workbenchcheck.GHStatus(ctx, r.folder, run)
		r.gh = ok
		if !ok {
			r.note(note)
		}
	}
}

func (r *refresher) note(s string) { r.notes = append(r.notes, s) }

// skip counts a ref whose state could not be read.
func (r *refresher) skip(ref, why string) {
	r.unchecked[ref] = true
	if r.skipped == 0 {
		r.firstErr = workbenchcheck.ClipNote(ref + ": " + why)
	}
	r.skipped++
}

// noteGuards names a squash read the filter guard refused, once per
// distinct note: it is set during the merge checks, so read after them.
func (r *refresher) noteGuards() {
	repos := []*workbenchcheck.Repository{r.repo}
	for _, base := range slices.Sorted(maps.Keys(r.bases)) {
		repos = append(repos, r.bases[base])
	}
	for _, repo := range repos {
		if repo == nil {
			continue
		}
		if n := repo.GuardNote(); n != "" && !slices.Contains(r.notes, n) {
			r.note(n)
		}
	}
}

func (r *refresher) noteSkipped() {
	if r.skipped > 0 {
		r.note(fmt.Sprintf("the state of %d ref(s) could not be read (%s)", r.skipped, r.firstErr))
	}
}

func (r *refresher) noteUnsaved() {
	if r.unsaved > 0 {
		r.note(fmt.Sprintf("the state of %d ref(s) was read but could not be saved (%s)", r.unsaved, r.firstUnsave))
	}
}

// save stores row in the cache table, its lock wait bounded by
// opts.writeWait when set: cut to the budget left, but never under 1 ms — a
// write with no other writer about needs no wait, and a verdict read at the
// budget's end is still worth keeping.
func (r *refresher) save(row db.PRState) error {
	if r.opts.writeWait > 0 {
		wait := max(min(r.opts.writeWait, r.deadline.Sub(r.opts.Now())), time.Millisecond)
		if err := setWriteWait(r.d, wait); err != nil {
			return err
		}
	}
	return r.d.UpsertPRState(row)
}

// check reads one ref and stores it; false when the budget cut the read
// short. Such a read is neither stored (it would read as "not found") nor
// counted as a failure. A read whose write fails still serves this run's
// rows (r.cache) and is counted apart: it was read, not saved.
func (r *refresher) check(ctx context.Context, ref string) bool {
	if !r.inRepo {
		return true
	}
	skipped, firstErr := r.skipped, r.firstErr
	row, ok := r.read(ctx, ref)
	if ctx.Err() != nil {
		r.skipped, r.firstErr = skipped, firstErr // the caller counts it unchecked
		return false
	}
	if !ok {
		return true
	}
	row.WorkbenchID, row.Ref = r.workbenchID, ref
	row.CheckedAt = r.opts.Now().UTC().Format(time.RFC3339)
	if r.unchecked[ref] {
		// A failed read that keeps its row (readInto): stamped, but due again.
		row.CheckedAt = dueAgain(row.State, r.opts.Now())
	}
	if err := r.save(row); err != nil {
		if r.unsaved == 0 {
			r.firstUnsave = workbenchcheck.ClipNote(ref + ": " + err.Error())
		}
		r.unsaved++
	}
	r.cache[ref] = row
	return true
}

// read returns ref's new row, or false when there is nothing to store (no
// way to read it now, or a read that failed: the cached row stays).
func (r *refresher) read(ctx context.Context, ref string) (db.PRState, bool) {
	switch kind, name, _ := strings.Cut(ref, ":"); {
	case kind == "pr" && validArg(strings.TrimPrefix(name, "#")):
		return r.readPR(ctx, ref, strings.TrimPrefix(name, "#"))
	case kind == "branch" && name != "":
		return r.readBranch(ctx, ref, name)
	case kind+":" == intoPrefix:
		base, branch, _ := strings.Cut(name, ":")
		if base == "" || branch == "" {
			r.skip(ref, "not an into:<base>:<branch> reference")
			return db.PRState{}, false
		}
		return r.readInto(ctx, ref, base, branch)
	default:
		r.skip(ref, "not a pr:, branch: or into: reference")
		return db.PRState{}, false
	}
}

// validArg: a gh argument that cannot read as a flag.
func validArg(s string) bool { return s != "" && !strings.HasPrefix(s, "-") }

// readPR asks gh for a pull request; without gh it is left as cached.
func (r *refresher) readPR(ctx context.Context, ref, number string) (db.PRState, bool) {
	if !r.gh {
		return db.PRState{}, false
	}
	var v prJSON
	if err := workbenchcheck.GHJSON(ctx, r.folder, run, &v, "pr", "view", number, "--json", prFields); err != nil {
		r.skip(ref, err.Error())
		return db.PRState{}, false
	}
	row, ok := prRow(v)
	if !ok {
		r.skip(ref, "unreadable gh output")
		return db.PRState{}, false
	}
	if n, err := strconv.ParseInt(number, 10, 64); err == nil {
		row.PRNumber = sql.NullInt64{Int64: n, Valid: true}
	}
	return row, true
}

// readBranch takes the branch's pull request from gh when there is one —
// the cached PR number, else `gh pr list --head` — and otherwise its git
// merge state: merged, or "none" (no PR yet) when gh found none. Without gh
// git can only upgrade a cached row to merged (keeping the PR fields gh gave
// earlier): any other cached state — a PR gh saw closed, "none" — stays as
// it is, never turned into "open". A branch with no row yet reads merged or
// open.
func (r *refresher) readBranch(ctx context.Context, ref, branch string) (db.PRState, bool) {
	cached := r.cache[ref]
	if r.gh {
		switch v, found, err := r.branchPR(ctx, cached, branch); {
		case err != nil:
			r.skip(ref, err.Error())
			return db.PRState{}, false
		case found:
			row, ok := prRow(v)
			if !ok {
				r.skip(ref, "unreadable gh output")
			}
			if v.Number > 0 {
				row.PRNumber = sql.NullInt64{Int64: v.Number, Valid: true}
			} else {
				row.PRNumber = cached.PRNumber
			}
			return row, ok
		}
		if r.repo.BranchMerge(ctx, branch) == workbenchcheck.BranchMerged {
			return db.PRState{State: "merged"}, true
		}
		return db.PRState{State: "none"}, true
	}
	_, hasRow := r.cache[ref]
	switch r.repo.BranchMerge(ctx, branch) {
	case workbenchcheck.BranchMerged:
		cached.State = "merged"
	case workbenchcheck.BranchNotMerged:
		if hasRow {
			return db.PRState{}, false
		}
		cached.State = "open"
	default: // missing or unknown: no conclusion without gh
		return db.PRState{}, false
	}
	return cached, true
}

// readInto is git's verdict on branch's work being in base: merged, or open
// when every base ref says it is not. Anything else keeps the cached verdict
// (none yet = unknown) and only stamps its check time, so it backs off like
// any checked ref: a branch git cannot find (session cleanup deletes a merged
// worktree branch — expected, so quiet) and a cached merged branch left only
// on origin with a tip the base contains — there git cannot tell a
// fast-forward merge from a branch with no work of its own; so does a
// branch git cannot tell about (a base too far ahead for the squash check,
// for one), quietly. A read that failed (Repository.MergeFailed: a git
// call, an unresolvable base, a refused squash read) is counted in the note
// and stamped due again (check, dueAgain): every run tries it, last in line
// (refresh's order), so a row's merged_stale holds while the failure lasts
// instead of blinking off for the fresh window.
func (r *refresher) readInto(ctx context.Context, ref, base, branch string) (db.PRState, bool) {
	repo, ok := r.bases[base]
	if !ok {
		repo = workbenchcheck.OpenRepositoryAgainst(ctx, r.folder, base, run)
		if ctx.Err() != nil {
			return db.PRState{}, false // cut short: not kept, opened again next time
		}
		if r.bases == nil {
			r.bases = map[string]*workbenchcheck.Repository{}
		}
		r.bases[base] = repo
		for _, n := range repo.Notes() {
			if !slices.Contains(r.notes, n) {
				r.note(n)
			}
		}
	}
	cached, hasRow := r.cache[ref]
	switch repo.BranchMerge(ctx, branch) {
	case workbenchcheck.BranchMerged:
		return db.PRState{State: "merged"}, true
	case workbenchcheck.BranchNotMerged:
		if cached.State != "merged" || !repo.OriginOnlyContained(ctx, branch) {
			return db.PRState{State: "open"}, true
		}
	case workbenchcheck.BranchUnknown:
		if repo.MergeFailed(ctx, branch) {
			r.skip(ref, "git could not read its merge state")
		}
	case workbenchcheck.BranchMissing:
	}
	if !hasRow {
		return db.PRState{State: "unknown"}, true
	}
	return cached, true
}

// dueAgain is a check time that is already stale for a row in state (its
// fresh window and a second ago): the row is checked again on the next run,
// and dueSince puts it behind every ref that became due before now.
func dueAgain(state string, now time.Time) string {
	return now.Add(-staleAfter(state) - time.Second).UTC().Format(time.RFC3339)
}

// branchPR finds the branch's pull request through gh: the cached number,
// else the newest PR with the branch as its head.
func (r *refresher) branchPR(ctx context.Context, cached db.PRState, branch string) (prJSON, bool, error) {
	if cached.PRNumber.Valid {
		var v prJSON
		err := workbenchcheck.GHJSON(ctx, r.folder, run, &v, "pr", "view", strconv.FormatInt(cached.PRNumber.Int64, 10), "--json", prFields)
		return v, err == nil, err
	}
	if !validArg(branch) {
		return prJSON{}, false, fmt.Errorf("invalid branch name %q", branch)
	}
	var list []prJSON
	if err := workbenchcheck.GHJSON(ctx, r.folder, run, &list, "pr", "list", "--head", branch, "--state", "all",
		"--limit", "1", "--json", "number,"+prFields); err != nil {
		return prJSON{}, false, err
	}
	if len(list) == 0 {
		return prJSON{}, false, nil
	}
	return list[0], true, nil
}

// prRow maps gh's pull request to a cache row; false for a state gh should
// not answer.
func prRow(v prJSON) (db.PRState, bool) {
	state := strings.ToLower(v.State)
	if state != "merged" && state != "open" && state != "closed" {
		return db.PRState{}, false
	}
	return db.PRState{
		State:     state,
		Title:     v.Title,
		Additions: sql.NullInt64{Int64: v.Additions, Valid: true},
		Deletions: sql.NullInt64{Int64: v.Deletions, Valid: true},
		MergedAt:  v.MergedAt,
	}, true
}
