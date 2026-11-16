package watchman

import (
	"context"
	"errors"
	"fmt"
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
// no time limit; Now defaults to time.Now and BatchSize to defaultLearnBatch.
type LearnOptions struct {
	Budget    time.Duration
	Now       func() time.Time
	Sources   []Source
	Labeler   Labeler
	BatchSize int
}

// LearnStats is what one pass did. Unlabelled counts the decisions a source
// offered that got no valid category (not stored, their keys marked
// skipped); Skipped the rows the sources could not read (SkipCounter).
type LearnStats struct {
	Written    int
	BySource   map[string]int
	Incomplete bool
	Labelled   int
	Unlabelled int
	Skipped    int
}

// Learn walks each source from its stored cursor and stores what it offers:
// the precedents with no category are labelled first; each batch, its
// skipped keys, the unlabelled counter and the new cursor are written in one
// transaction, so an interrupted pass resumes without duplicates. It stops
// when the budget is spent (Incomplete); the budget is checked before each
// Next, so a pass can overrun it by one batch (its Next and label calls). A source that fails is reported and
// the others still run. When every source reports done (and none failed)
// the workbench is marked learned.
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
		if o.Budget > 0 && o.Now().Sub(start) >= o.Budget {
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
		keep, drop, labelled, err := labelPrecedents(ctx, o.Labeler, ps)
		if err != nil {
			return false, fmt.Errorf("watchman learn: workbench %d, source %s: %w", workbenchID, name, err)
		}
		if err := saveBatch(d, workbenchID, name, keep, drop, skipped, next, start); err != nil {
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

// labelPrecedents labels the precedents with no category. keep holds the
// ones to store, drop the keys that got no valid category.
func labelPrecedents(ctx context.Context, l Labeler, ps []db.WatchmanPrecedent) (keep []db.WatchmanPrecedent, drop []string, labelled int, err error) {
	var need []int
	var items []LabelItem
	for i, p := range ps {
		if p.Category == "" {
			need = append(need, i)
			items = append(items, LabelItem{Situation: p.Situation, Choice: joinNonEmpty("\n", p.Choice, p.OwnerWords)})
		}
	}
	labels := map[int]string{}
	if len(items) > 0 {
		if l == nil {
			return nil, nil, 0, errors.New("no labeller for unlabelled decisions")
		}
		got, err := l.Label(ctx, items)
		if err != nil {
			return nil, nil, 0, err
		}
		for k, i := range need {
			if k < len(got) {
				labels[i] = strings.TrimSpace(got[k])
			}
		}
	}
	for i, p := range ps {
		if p.Category == "" {
			c := labels[i]
			if !decideCategories[c] {
				drop = append(drop, p.SourceKey)
				continue
			}
			p.Category = c
			labelled++
		}
		keep = append(keep, p)
	}
	return keep, drop, labelled, nil
}

// saveBatch writes a batch, its unstored keys, the unlabelled count and the
// source's new cursor in one transaction.
func saveBatch(d *db.DB, workbenchID int64, source string, keep []db.WatchmanPrecedent, drop []string, skipped int, cursor string, at time.Time) error {
	tx, err := d.Begin()
	if err != nil {
		return fmt.Errorf("watchman learn: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	if err := d.UpsertWatchmanPrecedents(tx, keep); err != nil {
		return err
	}
	if err := d.MarkWatchmanSkippedKeys(tx, source, drop, at); err != nil {
		return err
	}
	if err := d.AddWatchmanUnlabelled(tx, workbenchID, len(drop)+skipped); err != nil {
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
// NeedLabels = questions + turns + commits; Tokens = NeedLabels ×
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
	turns := c.Sessions * turnsPerSession
	need := c.Questions + turns + commits
	return LearnEstimate{Decisions: c.Decided + turns + commits, NeedLabels: need, Tokens: need * labelTokensPerItem}, nil
}
