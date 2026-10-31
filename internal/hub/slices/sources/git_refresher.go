package sources

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"os"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/gitbin"
	"watchtower/internal/workbenchgit"
)

// GitTiming is the git refresher's cadence (WorkbenchGitRefresher.Timing).
type GitTiming struct {
	// Every is the regular refresh of one workbench.
	Every time.Duration
	// MinSpacing is the least time between two runs for one workbench, for
	// a session-change request.
	MinSpacing time.Duration
	// Timeout bounds one status read.
	Timeout time.Duration
	// Idle is the longest wait between two passes with no session change.
	Idle time.Duration
}

// StandardGitTiming is WorkbenchGitRefresher.Timing.standard.
var StandardGitTiming = GitTiming{Every: 120 * time.Second, MinSpacing: 30 * time.Second, Timeout: 20 * time.Second, Idle: 15 * time.Second}

// GitFetch reads one workbench's git status.
type GitFetch func(ctx context.Context, workbenchID int64) (workbenchgit.Status, error)

// GitRefresherOptions wires the git refresher. Timing zero is
// StandardGitTiming; Fetch nil reads the workbench folder's status
// in-process (workbenchgit.ReadStatus, what `workbench git status --json`
// prints — PROJ-10's git, its processes in their own group, killed whole at
// the timeout and waited for); Active nil is always (the hub's linked-phone
// gate: with no phone no status is read); Now nil is time.Now.
type GitRefresherOptions struct {
	Timing GitTiming
	Fetch  GitFetch
	Active func() bool
	Now    func() time.Time
	// OnChange (nil = none) is called when a workbench's stored status
	// changed: the hub publishes the workbench slice then.
	OnChange func()
	// MinimumGap (0 = the standard 5 s) is a test seam: the least time
	// between two passes a signal starts.
	MinimumGap time.Duration
}

// GitRefresher keeps each published workbench's git status for the
// workbench slice (mobile POC spec §4.2, the Swift WorkbenchGitRefresher):
// every 120 s per workbench and on a state change of one of its sessions, at
// most once per 30 s per workbench. A failed, refused or hung read keeps the
// last value. Run sleeps until a session change wakes it or a deferred
// request is due, at most Idle (board #842). Status is its last good value,
// the workbench source's GitStatus.
type GitRefresher struct {
	d    *db.DB
	o    GitRefresherOptions
	c    *cadence[GitSnapshot]
	wake *runnerWake
}

// NewGitRefresher builds the git refresher over the published workbenches
// of d.
func NewGitRefresher(d *db.DB, o GitRefresherOptions) *GitRefresher {
	if o.Timing == (GitTiming{}) {
		o.Timing = StandardGitTiming
	}
	if o.Active == nil {
		o.Active = func() bool { return true }
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	g := &GitRefresher{d: d, o: o, c: newCadence[GitSnapshot](o.Timing.Every, o.Timing.MinSpacing), wake: newRunnerWake(o.MinimumGap)}
	if g.o.Fetch == nil {
		g.o.Fetch = g.readStatus
	}
	return g
}

// Status is workbenchID's last good git status; false before the first.
func (g *GitRefresher) Status(workbenchID int64) (GitSnapshot, bool) { return g.c.value(workbenchID) }

// SessionStateChanged wakes the loop, which refreshes workbenchID no sooner
// than MinSpacing after its last run (a workbench not listed yet runs as new
// on that pass).
func (g *GitRefresher) SessionStateChanged(workbenchID int64) {
	g.c.request(workbenchID, true)
	g.wake.signal()
}

// Run is the refresher's loop until ctx ends.
func (g *GitRefresher) Run(ctx context.Context) error {
	for ctx.Err() == nil {
		wait := g.o.Timing.Idle
		if g.o.Active() {
			g.RefreshDue(ctx)
			wait = g.c.nextWait(g.o.Now(), g.o.Timing.Idle)
		}
		g.wake.wait(ctx, wait)
	}
	return ctx.Err()
}

// RefreshDue is one pass: every due workbench, one after the other. A ctx
// that ends during the pass stops it before its next read; the read in
// flight stores nothing and every workbench the pass did not finish stays
// due. It returns the workbenches whose read was started.
func (g *GitRefresher) RefreshDue(ctx context.Context) []int64 {
	ids, err := g.publishedIDs(ctx)
	if err != nil {
		log.Printf("hub slices: git status: listing workbenches failed (%s)", errClass(err))
		return nil
	}
	keep := make(map[int64]bool, len(ids))
	for _, id := range ids {
		keep[id] = true
	}
	always := func(int64) bool { return true }
	due := g.c.takeDue(ids, keep, g.o.Now(), func(int64, bool) bool { return true }, always)
	var attempted []int64
	for len(due) > 0 && ctx.Err() == nil {
		attempted = append(attempted, due[0].id)
		if !g.refresh(ctx, due[0].id) {
			break
		}
		due = due[1:]
	}
	g.c.restore(due)
	return attempted
}

// refresh reads one workbench; false when ctx ended during the read
// (nothing stored). A failure counts as finished: it keeps the last value.
func (g *GitRefresher) refresh(ctx context.Context, id int64) bool {
	st, err := bounded(ctx, g.o.Timing.Timeout, func(ctx context.Context) (workbenchgit.Status, error) {
		return g.o.Fetch(ctx, id)
	})
	if ctx.Err() != nil {
		return false
	}
	switch {
	case errors.Is(err, errRunTimedOut):
		log.Printf("hub slices: git status for workbench %d timed out; keeping the last value", id)
	case err != nil:
		log.Printf("hub slices: git status for workbench %d failed (%s); keeping the last value", id, errClass(err))
	case !st.StatusOK:
		log.Printf("hub slices: git status for workbench %d could not be read; keeping the last value", id)
	default:
		snap := gitSnapshot(st)
		old, had := g.c.value(id)
		g.c.store(id, snap)
		if (!had || old != snap) && g.o.OnChange != nil {
			g.o.OnChange()
		}
	}
	return true
}

// gitSnapshot is WorkbenchGitRefresher.snapshot: no branch while detached.
func gitSnapshot(st workbenchgit.Status) GitSnapshot {
	branch := st.Branch
	if st.Detached {
		branch = ""
	}
	return GitSnapshot{Branch: branch, Detached: st.Detached, Changes: st.Changes}
}

// publishedIDs is WorkbenchSlice.publishedWorkbenchRefs' ids.
func (g *GitRefresher) publishedIDs(ctx context.Context) ([]int64, error) {
	var ids []int64
	err := readTx(ctx, g.d, func(tx *sql.Tx) error {
		refs, err := publishedRefs(ctx, tx)
		for _, r := range refs {
			ids = append(ids, r.id)
		}
		return err
	})
	return ids, err
}

// readStatus is `workbench git status --workbench N --json` in-process: the
// workbench folder's status, every git process in its own group.
func (g *GitRefresher) readStatus(ctx context.Context, id int64) (workbenchgit.Status, error) {
	w, err := g.d.GetWorkbench(id)
	if err != nil {
		return workbenchgit.Status{}, fmt.Errorf("workbench %d: %w", id, err)
	}
	if _, err := os.Stat(w.FolderPath); err != nil {
		return workbenchgit.Status{}, fmt.Errorf("workbench %d: the folder is missing", id)
	}
	st := workbenchgit.ReadStatus(gitbin.WithProcessGroup(ctx), workbenchgit.Options{Folder: w.FolderPath})
	st.WorkbenchID = id
	return st, nil
}
