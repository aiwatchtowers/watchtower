package watchman

import (
	"context"
	"errors"
	"fmt"
	"time"

	"watchtower/internal/db"
)

// statusSources are the sources a status lists, in learning order.
var statusSources = []string{SourceAsk, SourceReview, SourceSpec, SourcePermission, SourceJournal, "turn", "git"}

// BacktestInterrupted is the status a running backtest row is reported with
// when no process holds the lock: its run died; the next run closes the row.
const BacktestInterrupted = "interrupted"

// StatusReport is `watchman status --json` (keys pinned by
// TestWatchmanStatus_JSONKeysPinned and testdata/status.json, which the
// Desktop's test reads).
type StatusReport struct {
	OK          bool              `json:"ok"`
	Workbenches []WorkbenchStatus `json:"workbenches"`
}

// WorkbenchStatus is one workbench's Watchman state. A workbench Watchman is
// not on for has EnabledAt nil, Estimate set (nil when counting its commits
// timed out) and Learning nil; an enabled one the reverse.
type WorkbenchStatus struct {
	Workbench         int64                   `json:"workbench"`
	Name              string                  `json:"name"`
	EnabledAt         *string                 `json:"enabled_at"`
	AnalyticsOn       bool                    `json:"analytics_on"`
	Precedents        map[string]int          `json:"precedents"`
	Sources           map[string]SourceStatus `json:"sources"`
	SleepWindow       string                  `json:"sleep_window"` // "" when not learned or set
	SleepWindowPinned bool                    `json:"sleep_window_pinned"`
	Estimate          *EstimateStatus         `json:"estimate"`
	Learning          *LearningStatus         `json:"learning"`
	Backtest          *BacktestStatus         `json:"backtest"`
	LastDone          *BacktestStatus         `json:"last_done"`
	Running           bool                    `json:"running"`
}

// SourceStatus is one source's precedents written and whether its backfill
// is done. Done is the workbench's learned_through: the sources' cursors do
// not record a per-source end, so every source is done once all are.
type SourceStatus struct {
	Written int  `json:"written"`
	Done    bool `json:"done"`
}

// EstimateStatus is the counts-only learning estimate of a workbench
// Watchman is not on for.
type EstimateStatus struct {
	Decisions  int `json:"decisions"`
	NeedLabels int `json:"need_labels"`
	Tokens     int `json:"tokens"`
}

// LearningStatus is the learning progress: Written = precedents + the
// decisions that got no category, Estimated = the estimate taken at start,
// Done = every source finished its backfill, RelabelPending = the earlier
// precedents the relabel pass has not flagged yet (the backtest waits for 0).
type LearningStatus struct {
	Written        int  `json:"written"`
	Estimated      int  `json:"estimated"`
	Done           bool `json:"done"`
	RelabelPending int  `json:"relabel_pending"`
}

// BacktestStatus is one backtest run.
type BacktestStatus struct {
	ID         int64            `json:"id"`
	Status     string           `json:"status"` // running, done, failed, interrupted
	StartedAt  string           `json:"started_at"`
	FinishedAt *string          `json:"finished_at"`
	Error      string           `json:"error"`
	Verdict    string           `json:"verdict"` // "", go, stop
	CostUSD    float64          `json:"cost_usd"`
	Progress   string           `json:"progress"`
	Categories []CategoryResult `json:"categories"`
}

// CategoryResult is one category's backtest row: Total scored decisions
// graded same (Agree), Acceptable or Bad by the judge; Handed the hidden
// items the twin justly handed to the owner (at most 30; their questions are
// not scored).
type CategoryResult struct {
	Category    string  `json:"category"`
	Total       int     `json:"total"`
	Agree       int     `json:"agree"`
	Acceptable  int     `json:"acceptable"`
	Bad         int     `json:"bad"`
	WrongHigh   int     `json:"wrong_high"` // bad while the twin's confidence was high
	Status      string  `json:"status"`     // strong, weak, not_measured
	CostUSD     float64 `json:"cost_usd"`
	Baseline    float64 `json:"baseline"`     // share of the owner's most common choice among the hidden items
	RecBaseline float64 `json:"rec_baseline"` // share of the decisions where the owner picked the recommended option
	Handed      int     `json:"handed"`
}

// StatusOptions are what Status cannot read from the database: Running is
// whether the workspace's Watchman lock is held (Locked), Git sizes the
// estimate of a workbench Watchman is not on for (ExecGit when nil).
type StatusOptions struct {
	Running bool
	Git     GitRunner
}

// Status reports workbenchID, or every workbench when it is 0 (those
// Watchman is not on for too, with their estimate).
func Status(ctx context.Context, d *db.DB, workbenchID int64, o StatusOptions) (StatusReport, error) {
	if o.Git == nil {
		o.Git = ExecGit
	}
	var wbs []db.Workbench
	if workbenchID != 0 {
		wb, err := d.GetWorkbench(workbenchID)
		if err != nil {
			return StatusReport{}, fmt.Errorf("watchman status: %w", err)
		}
		wbs = []db.Workbench{*wb}
	} else {
		var err error
		if wbs, err = d.ListWorkbenches(); err != nil {
			return StatusReport{}, fmt.Errorf("watchman status: %w", err)
		}
	}
	rep := StatusReport{OK: true, Workbenches: []WorkbenchStatus{}}
	for _, wb := range wbs {
		s, err := workbenchStatus(ctx, d, wb, o)
		if err != nil {
			return StatusReport{}, err
		}
		rep.Workbenches = append(rep.Workbenches, s)
	}
	return rep, nil
}

func workbenchStatus(ctx context.Context, d *db.DB, wb db.Workbench, o StatusOptions) (WorkbenchStatus, error) {
	s := WorkbenchStatus{Workbench: wb.ID, Name: wb.Name, Running: o.Running,
		Precedents: map[string]int{}, Sources: map[string]SourceStatus{}}
	state, err := d.WatchmanWorkbench(wb.ID)
	if err != nil {
		return s, err
	}
	if s.AnalyticsOn, err = d.WorkbenchAgentAnalytics(wb.ID); err != nil {
		return s, err
	}
	byCat, bySrc, err := d.WatchmanPrecedentCounts(wb.ID)
	if err != nil {
		return s, err
	}
	written := 0
	for _, c := range Categories {
		s.Precedents[c] = byCat[c]
	}
	for _, n := range byCat {
		written += n
	}
	done := state != nil && state.LearnedThrough != nil
	for _, src := range statusSources {
		s.Sources[src] = SourceStatus{Written: bySrc[src], Done: done}
	}
	profiles, err := d.WatchmanProfiles(wb.ID)
	if err != nil {
		return s, err
	}
	for _, p := range profiles {
		if p.Key == SleepWindowKey {
			s.SleepWindow, s.SleepWindowPinned = p.Text, p.Pinned
		}
	}
	if state == nil {
		est, err := statusEstimate(ctx, d, o.Git, wb.ID)
		if err != nil {
			return s, err
		}
		s.Estimate = est
	} else {
		at := state.EnabledAt.UTC().Format(time.RFC3339)
		s.EnabledAt = &at
		pending, err := d.WatchmanFlagsPending(wb.ID)
		if err != nil {
			return s, err
		}
		s.Learning = &LearningStatus{Written: written + state.Unlabelled, Estimated: state.EstimatedDecisions, Done: done, RelabelPending: pending}
	}
	latest, rows, err := d.LatestWatchmanBacktest(wb.ID)
	if err != nil {
		return s, err
	}
	s.Backtest = backtestStatus(latest, rows, o.Running)
	lastDone, rows, err := d.LatestDoneWatchmanBacktest(wb.ID)
	if err != nil {
		return s, err
	}
	s.LastDone = backtestStatus(lastDone, rows, o.Running)
	return s, nil
}

// statusGitTimeout bounds the `git rev-list` of one workbench's estimate: a
// huge or stuck repository does not hold the whole status up. Tests replace it.
var statusGitTimeout = 3 * time.Second

// statusEstimate is a not-enabled workbench's estimate, nil when counting
// its commits ran past statusGitTimeout.
func statusEstimate(ctx context.Context, d *db.DB, git GitRunner, workbenchID int64) (*EstimateStatus, error) {
	gctx, cancel := context.WithTimeout(ctx, statusGitTimeout)
	defer cancel()
	est, err := Estimate(gctx, d, git, workbenchID)
	if errors.Is(err, context.DeadlineExceeded) && ctx.Err() == nil {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &EstimateStatus{Decisions: est.Decisions, NeedLabels: est.NeedLabels, Tokens: est.Tokens}, nil
}

// backtestStatus converts a backtest row; a running row while the lock is
// free is reported interrupted.
func backtestStatus(b *db.WatchmanBacktest, rows []db.WatchmanBacktestRow, running bool) *BacktestStatus {
	if b == nil {
		return nil
	}
	out := &BacktestStatus{ID: b.ID, Status: b.Status, StartedAt: b.StartedAt.UTC().Format(time.RFC3339), Error: b.Error,
		Verdict: b.Verdict, CostUSD: b.CostUSD, Progress: b.Progress, Categories: []CategoryResult{}}
	if b.Status == "running" && !running {
		out.Status = BacktestInterrupted
	}
	if b.FinishedAt != nil {
		f := b.FinishedAt.UTC().Format(time.RFC3339)
		out.FinishedAt = &f
	}
	for _, r := range rows {
		out.Categories = append(out.Categories, CategoryResult{Category: r.Category, Total: r.Total, Agree: r.Agree,
			Acceptable: r.Acceptable, Bad: r.Bad, WrongHigh: r.WrongHigh, Status: r.Status, CostUSD: r.CostUSD,
			Baseline: r.Baseline, RecBaseline: r.RecBaseline, Handed: r.Handed})
	}
	return out
}
