package kb

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
)

// batchSize is the number of documents written per transaction.
const batchSize = 200

// Options controls one indexing run.
type Options struct {
	Budget  time.Duration // zero = unlimited
	Sources []string      // nil = all, in allSources() order
	Now     time.Time     // zero = time.Now()
}

// Stats reports what one run changed. Incomplete means the budget ran out
// before every selected source caught up; the next run resumes from the
// stored cursors.
type Stats struct {
	Written, Deleted int
	Incomplete       bool
}

// runner carries the indexer's injectable seams: the source set and the
// budget clock. Production code uses defaultRunner; tests build their own
// instead of swapping package state (the package's tests may run in parallel).
type runner struct {
	sources func() []Source
	clock   func() time.Time
}

var defaultRunner = runner{sources: allSources, clock: time.Now}

// Run indexes every selected source incrementally. One source's error never
// stops the others; the returned error joins them all. An unknown name in
// opts.Sources is an error before anything runs.
func Run(ctx context.Context, d *db.DB, opts Options) (Stats, error) {
	return defaultRunner.run(ctx, d, opts)
}

func (r runner) run(ctx context.Context, d *db.DB, opts Options) (Stats, error) {
	sources, err := r.selectSources(opts.Sources)
	if err != nil {
		return Stats{}, err
	}
	now := opts.Now
	if now.IsZero() {
		now = time.Now()
	}
	start := r.clock()
	overBudget := func() bool { return opts.Budget > 0 && r.clock().Sub(start) > opts.Budget }
	var st Stats
	var errs []error
	for _, src := range sources {
		if cerr := ctx.Err(); cerr != nil {
			// A cancellation that already failed a source is reported once.
			if !errors.Is(errors.Join(errs...), cerr) {
				errs = append(errs, cerr)
			}
			break
		}
		if overBudget() {
			st.Incomplete = true
			break
		}
		caughtUp, err := runSource(ctx, d, src, now, overBudget, &st)
		if err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", src.Name(), err))
			continue
		}
		if !caughtUp {
			st.Incomplete = true
			break
		}
		if err := reconcileIfDue(ctx, d, src, now, &st); err != nil {
			errs = append(errs, fmt.Errorf("%s reconcile: %w", src.Name(), err))
		}
	}
	return st, errors.Join(errs...)
}

// Reindex drops the named sources' documents and cursors (all sources when
// names is nil) and rebuilds them without a budget. Every name is validated
// before anything is deleted.
func Reindex(ctx context.Context, d *db.DB, names []string, now time.Time) (Stats, error) {
	return defaultRunner.reindex(ctx, d, names, now)
}

func (r runner) reindex(ctx context.Context, d *db.DB, names []string, now time.Time) (Stats, error) {
	sources, err := r.selectSources(names)
	if err != nil {
		return Stats{}, err
	}
	err = withTx(ctx, d, func(tx *sql.Tx) error {
		for _, src := range sources {
			n := src.Name()
			if _, err := tx.ExecContext(ctx, `DELETE FROM kb_chunks WHERE doc_id IN (SELECT id FROM kb_documents WHERE source = ?)`, n); err != nil {
				return fmt.Errorf("kb: deleting %s chunks: %w", n, err)
			}
			if _, err := tx.ExecContext(ctx, `DELETE FROM kb_documents WHERE source = ?`, n); err != nil {
				return fmt.Errorf("kb: deleting %s documents: %w", n, err)
			}
			if _, err := tx.ExecContext(ctx, `DELETE FROM kb_sources WHERE source = ?`, n); err != nil {
				return fmt.Errorf("kb: deleting %s state: %w", n, err)
			}
		}
		return nil
	})
	if err != nil {
		return Stats{}, err
	}
	return r.run(ctx, d, Options{Sources: names, Now: now})
}

// selectSources builds fresh source instances (so per-run caches such as
// Slack's name cache never outlive a run), filtered to names in the
// factory's order. nil = all; an unknown name is an error.
func (r runner) selectSources(names []string) ([]Source, error) {
	all := r.sources()
	if names == nil {
		return all, nil
	}
	known := make(map[string]bool, len(all))
	var knownNames []string
	for _, s := range all {
		known[s.Name()] = true
		knownNames = append(knownNames, s.Name())
	}
	want := make(map[string]bool, len(names))
	for _, n := range names {
		if !known[n] {
			return nil, fmt.Errorf("kb: unknown source %q (known: %v)", n, knownNames)
		}
		want[n] = true
	}
	var out []Source
	for _, s := range all {
		if want[s.Name()] {
			out = append(out, s)
		}
	}
	return out, nil
}

func withTx(ctx context.Context, d *db.DB, fn func(tx *sql.Tx) error) error {
	tx, err := d.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("kb: begin: %w", err)
	}
	if err := fn(tx); err != nil {
		_ = tx.Rollback()
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("kb: commit: %w", err)
	}
	return nil
}

// runSource drains src's change feed from its stored cursor, one range per
// Changed call. A range's cursor is saved only in the transaction of its last
// batch, so a failure mid-range leaves the old cursor and the range is redone
// next time (idempotent through the content-hash gate). The budget is checked
// only between ranges, never between batches of one range: a range whose
// render time exceeds the budget must still complete, or it would be redone
// from scratch every cycle (livelock). Overshoot is bounded by one range.
// It returns false (no error) when the budget ran out before the source
// caught up.
func runSource(ctx context.Context, d *db.DB, src Source, now time.Time, overBudget func() bool, st *Stats) (bool, error) {
	name := src.Name()
	for {
		state, err := loadState(ctx, d, name)
		if err != nil {
			return false, fmt.Errorf("loading state: %w", err)
		}
		keys, next, done, err := src.Changed(ctx, d, state.Cursor, now)
		if err != nil {
			return false, fmt.Errorf("listing changes: %w", err)
		}
		if len(keys) == 0 {
			if !done && next == state.Cursor {
				return false, fmt.Errorf("no progress: cursor %q did not advance", next)
			}
			if next != state.Cursor {
				if err := withTx(ctx, d, func(tx *sql.Tx) error { return saveCursor(ctx, tx, name, next, now) }); err != nil {
					return false, err
				}
			}
		}
		for i := 0; i < len(keys); i += batchSize {
			end := min(i+batchSize, len(keys))
			last := end == len(keys)
			var written, deleted int
			err := withTx(ctx, d, func(tx *sql.Tx) error {
				var err error
				if written, deleted, err = indexBatch(ctx, tx, src, keys[i:end]); err != nil {
					return err
				}
				if last {
					return saveCursor(ctx, tx, name, next, now)
				}
				return nil
			})
			if err != nil {
				return false, err
			}
			// Counted only once the batch committed: a rolled-back batch reports nothing.
			st.Written += written
			st.Deleted += deleted
		}
		if done {
			return true, nil
		}
		if overBudget() {
			return false, nil
		}
	}
}

// indexBatch builds and stores each key inside tx, returning how many
// documents it wrote and deleted.
func indexBatch(ctx context.Context, tx *sql.Tx, src Source, keys []string) (written, deleted int, err error) {
	for _, key := range keys {
		doc, err := src.Build(ctx, tx, key)
		if err != nil {
			return 0, 0, fmt.Errorf("building %s: %w", key, err)
		}
		if doc == nil || isBlank(doc) {
			removed, err := deleteDoc(ctx, tx, key)
			if err != nil {
				return 0, 0, err
			}
			if removed {
				deleted++
			}
			continue
		}
		wrote, err := writeDoc(ctx, tx, doc)
		if err != nil {
			return 0, 0, err
		}
		if wrote {
			written++
		}
	}
	return written, deleted, nil
}

// isBlank reports whether a document has neither a non-blank title nor any
// non-blank section text: nothing to index, so it is treated as gone (and
// counted as a deletion when indexed). A title-only document is indexed
// (writeDoc makes the title its one section).
func isBlank(doc *Doc) bool {
	if strings.TrimSpace(doc.Title) != "" {
		return false
	}
	for _, s := range doc.Sections {
		if strings.TrimSpace(s.Text) != "" {
			return false
		}
	}
	return true
}

// dailyReconciler marks a source whose Keys() is too costly to list every
// cycle (Slack: a DISTINCT over every message); it reconciles once per UTC day.
type dailyReconciler interface{ reconcilesDaily() }

// reconcileIfDue deletes every indexed document of src whose key no longer
// exists (hard deletes move no change marker). It runs on every run for the
// small sources, so a deletion leaves search within one cycle, and once per
// UTC day for a dailyReconciler.
func reconcileIfDue(ctx context.Context, d *db.DB, src Source, now time.Time, st *Stats) error {
	name := src.Name()
	state, err := loadState(ctx, d, name)
	if err != nil {
		return err
	}
	today := now.UTC().Format("2006-01-02")
	reconciledToday := len(state.LastReconciledAt) >= 10 && state.LastReconciledAt[:10] == today
	if _, daily := src.(dailyReconciler); daily && reconciledToday {
		return nil
	}
	keys, err := src.Keys(ctx, d)
	if err != nil {
		return fmt.Errorf("listing keys: %w", err)
	}
	live := make(map[string]bool, len(keys))
	for _, k := range keys {
		live[k] = true
	}
	ids, err := docIDs(ctx, d, name)
	if err != nil {
		return fmt.Errorf("listing indexed ids: %w", err)
	}
	var stale []string
	for id := range ids {
		if !live[id] {
			stale = append(stale, id)
		}
	}
	if len(stale) == 0 && reconciledToday {
		return nil // nothing to delete, today's stamp already written: no write
	}
	var deleted int
	err = withTx(ctx, d, func(tx *sql.Tx) error {
		for _, id := range stale {
			removed, err := deleteDoc(ctx, tx, id)
			if err != nil {
				return err
			}
			if removed {
				deleted++
			}
		}
		return saveReconciled(ctx, tx, name, now)
	})
	if err != nil {
		return err
	}
	st.Deleted += deleted
	return nil
}
