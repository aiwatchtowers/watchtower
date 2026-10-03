package sessionreport

import (
	"context"
	"database/sql"
	"fmt"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/gitbin"
	"watchtower/internal/workbenchcheck"
)

// DefaultRefreshBudget bounds one Refresh: every git and gh call together.
const DefaultRefreshBudget = 10 * time.Second

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

// RefreshOptions configures one Refresh.
type RefreshOptions struct {
	// Network allows reading pull requests through the gh CLI; without it
	// only the branches' git merge state is read.
	Network bool
	Budget  time.Duration    // 0 = DefaultRefreshBudget
	Now     func() time.Time // nil = time.Now
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

// Refresh updates workbench projectID's PR cache for refs ('pr:<n>' or
// 'branch:<name>'). Only refs whose cached row is stale are checked, within
// opts.Budget; a ref not checked keeps its cached row (none = unknown). It
// never fails: anything it could not check is named in the note. It writes
// the cache only — never the board, so PROJ-07's drift check stays the only
// place that flags merged_but_open.
func Refresh(ctx context.Context, d *db.DB, projectID int64, refs []string, opts RefreshOptions) RefreshResult {
	if opts.Budget <= 0 {
		opts.Budget = DefaultRefreshBudget
	}
	if opts.Now == nil {
		opts.Now = time.Now
	}
	wb, err := d.GetWorkbench(projectID)
	if err != nil {
		return RefreshResult{Note: "PR states not refreshed: " + err.Error()}
	}
	cache, err := d.PRStates(projectID)
	if err != nil {
		return RefreshResult{Note: "PR states not refreshed: " + err.Error()}
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
		return RefreshResult{}
	}
	ctx, cancel := context.WithTimeout(ctx, opts.Budget)
	defer cancel()
	r := refresher{d: d, projectID: projectID, folder: wb.FolderPath, cache: cache, opts: opts}
	r.open(ctx)
	deadline := start.Add(opts.Budget)
	for i, ref := range stale {
		// A ref whose read the budget cut short counts as not checked.
		if ctx.Err() != nil || opts.Now().After(deadline) || !r.check(ctx, ref) {
			r.note(fmt.Sprintf("the %s time budget ran out; %d ref(s) keep their cached state", opts.Budget, len(stale)-i))
			break
		}
	}
	r.noteSkipped()
	return RefreshResult{Note: strings.Join(r.notes, "; ")}
}

// isStale: the row is old enough to check again (or its time unreadable).
func isStale(row db.PRState, now time.Time) bool {
	at, err := time.Parse(time.RFC3339, row.CheckedAt)
	if err != nil {
		return true
	}
	limit := freshFor
	if row.State == "merged" || row.State == "closed" {
		limit = settledFor
	}
	return now.Sub(at) > limit
}

// refresher holds what every ref's check shares.
type refresher struct {
	d         *db.DB
	projectID int64
	folder    string
	cache     map[string]db.PRState
	opts      RefreshOptions
	repo      *workbenchcheck.Repository // nil outside a repository
	gh        bool                       // gh is installed, signed in and allowed
	notes     []string
	skipped   int    // refs whose state could not be read
	firstErr  string // why the first of them could not
}

// open probes the repository and gh once. A plain folder runs no git — and
// no gh, which would run git from PATH and cannot name a PR without a
// repository anyway.
func (r *refresher) open(ctx context.Context) {
	if !gitbin.InsideRepository(r.folder) {
		r.note("the folder is not a git work tree; branch and pull request states not checked")
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
	if r.skipped == 0 {
		r.firstErr = workbenchcheck.ClipNote(ref + ": " + why)
	}
	r.skipped++
}

func (r *refresher) noteSkipped() {
	if r.skipped > 0 {
		r.note(fmt.Sprintf("the state of %d ref(s) could not be read (%s)", r.skipped, r.firstErr))
	}
}

// check reads one ref and stores it; false when the budget cut the read
// short. Such a read is neither stored (it would read as "not found") nor
// counted as a failure.
func (r *refresher) check(ctx context.Context, ref string) bool {
	if r.repo == nil {
		return true
	}
	skipped, firstErr := r.skipped, r.firstErr
	row, ok := r.read(ctx, ref)
	if ctx.Err() != nil {
		r.skipped, r.firstErr = skipped, firstErr
		return false
	}
	if !ok {
		return true
	}
	row.WorkbenchID, row.Ref = r.projectID, ref
	row.CheckedAt = r.opts.Now().UTC().Format(time.RFC3339)
	if err := r.d.UpsertPRState(row); err != nil {
		r.skip(ref, err.Error())
	}
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
	default:
		r.skip(ref, "not a pr: or branch: reference")
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
