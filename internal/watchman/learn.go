package watchman

import (
	"context"
	"errors"
	"fmt"
	"log"
	"slices"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/db"
	"watchtower/internal/logredact"
)

const (
	// defaultLearnBatch is how many precedents one Next call asks for.
	defaultLearnBatch = 50
	// turnsPerSession is the estimate's owner turns per agent session.
	turnsPerSession = 12
	// labelTokensPerItem is the estimate's tokens per labelled item.
	labelTokensPerItem = 350
)

// LearnOptions drives one learning pass over a workbench. Budget <= 0 means
// no time limit (the daemon's learner runs an unlearned workbench to the
// end); Now defaults to time.Now and BatchSize to defaultLearnBatch.
// Proceed, when set, is asked before each batch, as the budget is: false
// stops the pass Incomplete (the learner's background-AI consent, BGAI-01).
type LearnOptions struct {
	Budget    time.Duration
	Now       func() time.Time
	Sources   []Source
	Labeler   Labeler
	BatchSize int
	Proceed   func() bool
}

// stop reports whether the pass must end before its next batch: the budget
// is spent or Proceed says no.
func (o LearnOptions) stop(start time.Time) bool {
	return (o.Budget > 0 && o.Now().Sub(start) >= o.Budget) || (o.Proceed != nil && !o.Proceed())
}

// LearnStats is what one pass did. Unlabelled counts the decisions a source
// offered that got no valid category (not stored, their keys marked
// skipped); Skipped the rows the sources could not read (SkipCounter);
// Relabelled the earlier precedents the relabel pass flagged.
type LearnStats struct {
	Written    int
	BySource   map[string]int
	Incomplete bool
	Labelled   int
	Unlabelled int
	Skipped    int
	Relabelled int
	// RelabelFailed: the relabel pass stopped on an error (logged, not
	// returned; its rows stay pending). The daemon's learner then waits
	// for the next cycle instead of retrying on every wake.
	RelabelFailed bool
}

// flagNeed is which flags the labeller is asked for an item.
type flagNeed int

const (
	noFlags flagNeed = iota
	// parkedOnly: an ask is always a decision (spec §9.1); only parked is
	// read from the reply, decision is forced true.
	parkedOnly
	// bothFlags: a turn takes decision and parked from the reply.
	bothFlags
)

// labelFlags are the sources whose precedents the labeller flags (spec
// §9.1); permission rows are flagged by the hard-limit table, the other
// sources are always decisions and never flagged.
var labelFlags = map[string]flagNeed{SourceAsk: parkedOnly, "turn": bothFlags}

// relabelSources are the sources the relabel pass walks.
var relabelSources = []string{SourceAsk, "turn", SourcePermission}

// Learn walks each source from its stored cursor and stores what it offers:
// the precedents with no category, and every ask and turn (for its flags),
// go through the labeller first; each batch, its
// skipped keys, the unlabelled counter and the new cursor are written in one
// transaction, so an interrupted pass resumes without duplicates. It stops
// when the budget is spent (Incomplete); the budget is checked before each
// Next, so a pass can overrun it by one batch (its Next and label calls). A source that fails is reported and
// the others still run. When every source reports done (and none failed)
// the workbench is marked learned. Then, in what is left of the budget, the
// relabel pass flags earlier precedents; its error is logged (counts only)
// and never fails the pass or changes learned_through.
func Learn(ctx context.Context, d *db.DB, workbenchID int64, o LearnOptions) (LearnStats, error) {
	if o.Now == nil {
		o.Now = time.Now
	}
	if o.BatchSize <= 0 {
		o.BatchSize = defaultLearnBatch
	}
	st := LearnStats{BySource: map[string]int{}}
	start := o.Now()
	allDone := true
	var errs []error
	for _, src := range o.Sources {
		done, err := learnSource(ctx, d, workbenchID, src, o, start, &st)
		if cerr := ctx.Err(); cerr != nil {
			return st, cerr
		}
		if err != nil {
			errs = append(errs, err)
			allDone = false
			continue
		}
		if st.Incomplete {
			allDone = false
			break
		}
		allDone = allDone && done
	}
	if allDone && len(errs) == 0 {
		if err := d.MarkWatchmanLearned(workbenchID, start); err != nil {
			errs = append(errs, err)
		}
	}
	if !st.Incomplete {
		n, err := relabel(ctx, d, workbenchID, o, start)
		st.Relabelled = n
		if cerr := ctx.Err(); cerr != nil {
			return st, errors.Join(append(errs, cerr)...)
		}
		if err != nil {
			// Never fails the pass nor touches learned_through: the
			// backtest waits on the pending count alone; RelabelFailed
			// tells the caller. The error may quote a reply or a folder:
			// only its fingerprint (FILES-01).
			st.RelabelFailed = true
			left, _ := d.WatchmanFlagsPending(workbenchID) // best effort: the line is informational
			log.Printf("watchman learn: %v", logredact.Errorf("workbench %d: the relabel pass stopped after %d precedents, %d left for the next cycle: %s",
				workbenchID, n, left, logredact.Text(err.Error())))
		}
	}
	return st, errors.Join(errs...)
}

// learnSource drains one source until it is done, the budget ends or it
// makes no progress.
func learnSource(ctx context.Context, d *db.DB, workbenchID int64, src Source, o LearnOptions, start time.Time, st *LearnStats) (bool, error) {
	name := src.Name()
	cur, err := d.WatchmanCursor(workbenchID, name)
	if err != nil {
		return false, err
	}
	sc, counts := src.(SkipCounter)
	for {
		if err := ctx.Err(); err != nil {
			return false, err
		}
		if o.stop(start) {
			st.Incomplete = true
			return false, nil
		}
		before := 0
		if counts {
			before = sc.Skipped()
		}
		ps, next, done, err := src.Next(ctx, d, workbenchID, cur, o.BatchSize)
		if err != nil {
			if ctx.Err() != nil {
				return false, ctx.Err()
			}
			// A source error may name a transcript or a folder (FILES-01):
			// only its fingerprint travels.
			return false, logredact.Errorf("watchman learn: workbench %d, source %s: %s", workbenchID, name, logredact.Text(err.Error()))
		}
		skipped := 0
		if counts {
			skipped = sc.Skipped() - before
		}
		keep, drop, unflagged, labelled, err := labelPrecedents(ctx, o.Labeler, ps)
		if err != nil {
			return false, fmt.Errorf("watchman learn: workbench %d, source %s: %w", workbenchID, name, err)
		}
		if err := saveBatch(d, workbenchID, name, batch{keep: keep, drop: drop, unflagged: unflagged, skipped: skipped}, next, start); err != nil {
			return false, err
		}
		st.Written += len(keep)
		st.BySource[name] += len(keep)
		st.Labelled += labelled
		st.Unlabelled += len(drop)
		st.Skipped += skipped
		if done {
			return true, nil
		}
		if next == cur && len(ps) == 0 {
			return false, nil // no progress: the next pass tries again
		}
		cur = next
	}
}

// labelPrecedents sends the labeller the precedents with no category and
// every ask and turn (for their flags; a category Go set is kept). keep
// holds the ones to store, drop the keys that got no valid category,
// unflagged the stored keys whose flags are still missing after the retry
// (they stay candidates and are not relabelled). Without a labeller the
// categorised ones are stored unflagged and the relabel pass flags them later.
func labelPrecedents(ctx context.Context, l Labeler, ps []db.WatchmanPrecedent) (keep []db.WatchmanPrecedent, drop, unflagged []string, labelled int, err error) {
	ps = slices.Clone(ps) // the source's slice is not ours to change
	var need []int
	var items []LabelItem
	var wantFlags []flagNeed
	for i, p := range ps {
		flags := noFlags
		if p.IsDecision == nil && p.Parked == nil {
			flags = labelFlags[p.Source]
		}
		if p.Category == "" || flags != noFlags {
			need = append(need, i)
			items = append(items, LabelItem{Situation: p.Situation, Choice: joinNonEmpty("\n", p.Choice, p.OwnerWords), NeedCategory: p.Category == ""})
			wantFlags = append(wantFlags, flags)
		}
	}
	labels := map[int]Label{}
	if len(items) > 0 && l != nil {
		got, err := labelWithRetry(ctx, l, items, wantFlags)
		if err != nil {
			return nil, nil, nil, 0, err
		}
		for k, i := range need {
			labels[i] = got[k]
		}
	}
	dropped := map[int]bool{}
	for k, i := range need {
		p := &ps[i]
		lb, asked := labels[i]
		if p.Category == "" {
			if !asked {
				return nil, nil, nil, 0, errors.New("no labeller for unlabelled decisions")
			}
			if !decideCategories[lb.Category] {
				dropped[i] = true
				drop = append(drop, p.SourceKey)
				continue
			}
			p.Category = lb.Category
			labelled++
		}
		if asked && wantFlags[k] != noFlags {
			p.IsDecision, p.Parked = lb.Decision, lb.Parked
			if p.IsDecision == nil {
				unflagged = append(unflagged, p.SourceKey)
			}
		}
	}
	for i, p := range ps {
		if !dropped[i] {
			keep = append(keep, p)
		}
	}
	return keep, drop, unflagged, labelled, nil
}

// labelWithRetry labels items and sends the ones whose wanted flags are
// missing once more (spec §9.1 Failures); the retry fills only what the
// first reply lacked. An ask's decision is forced true, never read from the
// reply. A flag pair still incomplete after the retry comes back as both nil
// (the item stays a candidate). A reply shorter than the items leaves the
// rest empty.
func labelWithRetry(ctx context.Context, l Labeler, items []LabelItem, wantFlags []flagNeed) ([]Label, error) {
	got, err := l.Label(ctx, items)
	if err != nil {
		return nil, err
	}
	out := make([]Label, len(items))
	copy(out, got)
	yes := true
	var again []int
	for k := range out {
		if wantFlags[k] == parkedOnly {
			out[k].Decision = &yes
		}
		if wantFlags[k] != noFlags && (out[k].Decision == nil || out[k].Parked == nil) {
			again = append(again, k)
		}
	}
	if len(again) == 0 {
		return out, nil
	}
	retry := make([]LabelItem, len(again))
	for j, k := range again {
		retry[j] = items[k]
	}
	got, err = l.Label(ctx, retry)
	if err != nil {
		return nil, err
	}
	for j, k := range again {
		if j < len(got) {
			if !decideCategories[out[k].Category] {
				out[k].Category = got[j].Category
			}
			if out[k].Decision == nil {
				out[k].Decision = got[j].Decision
			}
			if out[k].Parked == nil {
				out[k].Parked = got[j].Parked
			}
		}
		if out[k].Decision == nil || out[k].Parked == nil {
			out[k].Decision, out[k].Parked = nil, nil
		}
	}
	return out, nil
}

// batch is what one source batch stores: the precedents, the keys that got
// no category, the stored keys whose flags stayed missing, and the rows the
// source could not read.
type batch struct {
	keep      []db.WatchmanPrecedent
	drop      []string
	unflagged []string
	skipped   int
}

// saveBatch writes a batch, its unstored keys, the unlabelled count and the
// source's new cursor in one transaction.
func saveBatch(d *db.DB, workbenchID int64, source string, b batch, cursor string, at time.Time) error {
	tx, err := d.Begin()
	if err != nil {
		return fmt.Errorf("watchman learn: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	if err := d.UpsertWatchmanPrecedents(tx, b.keep); err != nil {
		return err
	}
	if err := d.MarkWatchmanFlagsTried(tx, workbenchID, source, b.unflagged, at); err != nil {
		return err
	}
	if err := d.MarkWatchmanSkippedKeys(tx, workbenchID, source, b.drop, at); err != nil {
		return err
	}
	if err := d.AddWatchmanUnlabelled(tx, workbenchID, len(b.drop)+b.skipped); err != nil {
		return err
	}
	if err := d.SetWatchmanCursor(tx, workbenchID, source, cursor); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("watchman learn: saving a %s batch: %w", source, err)
	}
	return nil
}

// relabel is the one-time pass over the precedents stored before the flags
// existed (spec §9.1, D39): labelBatch rows at a time, newest first, asks and
// turns through the labeller (never their category), permission rows through
// the hard-limit table. Each batch's flags are written in one short
// transaction after its labeller calls; a row whose flags stay missing after
// the retry is written unset (a candidate) and not tried again. It stops at
// the budget or on the first error; the rows left stay pending and the next
// cycle resumes with them. Returns how many rows it flagged.
func relabel(ctx context.Context, d *db.DB, workbenchID int64, o LearnOptions, start time.Time) (int, error) {
	sources := relabelSources
	if o.Labeler == nil {
		sources = []string{SourcePermission}
	}
	done := 0
	for {
		if err := ctx.Err(); err != nil {
			return done, err
		}
		if o.stop(start) {
			return done, nil
		}
		rows, err := d.WatchmanUnflagged(workbenchID, sources, labelBatch)
		if err != nil || len(rows) == 0 {
			return done, err
		}
		flags, err := relabelFlags(ctx, d, workbenchID, o.Labeler, rows)
		if err != nil {
			return done, err
		}
		tx, err := d.Begin()
		if err != nil {
			return done, fmt.Errorf("watchman relabel: %w", err)
		}
		if err := d.SetWatchmanPrecedentFlags(tx, flags, o.Now()); err != nil {
			_ = tx.Rollback()
			return done, err
		}
		if err := tx.Commit(); err != nil {
			return done, fmt.Errorf("watchman relabel: %w", err)
		}
		done += len(flags)
	}
}

// relabelFlags flags one batch of earlier precedents. A permission row whose
// request is gone (or whose key is not an id) is parked: a row the table
// cannot place is never measured (spec §9.1).
func relabelFlags(ctx context.Context, d *db.DB, workbenchID int64, l Labeler, rows []db.WatchmanPrecedent) ([]db.WatchmanPrecedentFlags, error) {
	var ids []int64
	var asked []int
	var items []LabelItem
	var want []flagNeed
	for i, p := range rows {
		if p.Source == SourcePermission {
			if id, err := strconv.ParseInt(p.SourceKey, 10, 64); err == nil {
				ids = append(ids, id)
			}
			continue
		}
		asked = append(asked, i)
		items = append(items, LabelItem{Situation: p.Situation, Choice: joinNonEmpty("\n", p.Choice, p.OwnerWords)})
		want = append(want, labelFlags[p.Source])
	}
	reqs, err := d.WatchmanPermissionRequests(workbenchID, ids)
	if err != nil {
		return nil, err
	}
	out := make([]db.WatchmanPrecedentFlags, len(rows))
	if len(items) > 0 {
		got, err := labelWithRetry(ctx, l, items, want)
		if err != nil {
			return nil, err
		}
		for k, i := range asked {
			out[i] = db.WatchmanPrecedentFlags{IsDecision: got[k].Decision, Parked: got[k].Parked}
		}
	}
	yes := true
	for i, p := range rows {
		if p.Source == SourcePermission {
			out[i] = db.WatchmanPrecedentFlags{IsDecision: &yes, Parked: &yes}
			if id, err := strconv.ParseInt(p.SourceKey, 10, 64); err == nil {
				if r, ok := reqs[id]; ok {
					out[i] = permissionFlags(permissionAskOf(r))
				}
			}
		}
		out[i].ID = p.ID
	}
	return out, nil
}

// LearnEstimate is the size and cost of a first learning pass, before it
// runs: an estimate ("~"), not a count of what will be stored.
type LearnEstimate struct {
	Decisions  int
	NeedLabels int
	Tokens     int
}

// Estimate sizes a workbench's learning without walking a source: the
// database sources' row counts, the workbench's agent sessions ×
// turnsPerSession owner turns, and its folder's non-merge commits.
// NeedLabels = asks (review asks too: their parked flag) + turns + commits
// + the precedents the relabel
// pass has not flagged yet; Tokens = NeedLabels ×
// labelTokensPerItem.
func Estimate(ctx context.Context, d *db.DB, git GitRunner, workbenchID int64) (LearnEstimate, error) {
	c, err := d.WatchmanCounts(workbenchID)
	if err != nil {
		return LearnEstimate{}, err
	}
	wb, err := d.GetWorkbench(workbenchID)
	if err != nil {
		return LearnEstimate{}, fmt.Errorf("watchman estimate: %w", err)
	}
	commits := 0
	if wb.FolderPath != "" {
		out, err := git(ctx, wb.FolderPath, "rev-list", "--count", "--no-merges", "HEAD")
		if cerr := ctx.Err(); cerr != nil {
			return LearnEstimate{}, cerr
		}
		// A folder that is not a repository, has no commit yet or prints an
		// unreadable count adds no commits: this is an estimate.
		if err == nil {
			commits, _ = strconv.Atoi(strings.TrimSpace(string(out)))
		}
	}
	// The relabel pass's rows count too: they are labelled once more.
	pending, err := d.WatchmanFlagsPending(workbenchID)
	if err != nil {
		return LearnEstimate{}, fmt.Errorf("watchman estimate: %w", err)
	}
	turns := c.Sessions * turnsPerSession
	need := c.Asks + turns + commits + pending
	return LearnEstimate{Decisions: c.Decided + turns + commits, NeedLabels: need, Tokens: need * labelTokensPerItem}, nil
}
