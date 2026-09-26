package extsync

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"time"

	"watchtower/internal/db"
)

// providerConfluence is the ext_sources.provider the engine syncs.
const providerConfluence = "confluence"

// Engine syncs every enabled external source through its account's Fetcher.
// The daemon keeps one Engine, so the rotation state lives in memory.
type Engine struct {
	db       *db.DB
	fetchers map[int64]Fetcher // by jira_accounts.id
	opts     Options
	// startAt is the source id the next Run begins with (the first source
	// with id >= startAt, wrapping), set when a Run is cut by the budget so
	// one source's long backfill cannot starve the sources listed after it.
	startAt int64
	// reconcileFailedAt holds, per source id, when its last reconcile
	// failed (see reconcileAllowed).
	reconcileFailedAt map[int64]time.Time
}

// New returns an engine over d. Unset Options fields get their defaults.
func New(d *db.DB, opts Options) *Engine {
	if opts.Now == nil {
		opts.Now = time.Now
	}
	if opts.Logger == nil {
		opts.Logger = log.New(io.Discard, "", 0)
	}
	return &Engine{db: d, fetchers: map[int64]Fetcher{}, opts: opts, reconcileFailedAt: map[int64]time.Time{}}
}

// SetFetcher wires the fetcher for every source owned by jiraAccountID.
func (e *Engine) SetFetcher(jiraAccountID int64, f Fetcher) {
	e.fetchers[jiraAccountID] = f
}

// budget is the cycle budget, read only through Options.Now.
type budget struct {
	start time.Time
	limit time.Duration
	now   func() time.Time
}

func (e *Engine) newBudget() *budget {
	return &budget{start: e.opts.Now(), limit: e.opts.Budget, now: e.opts.Now}
}

// over reports whether the budget is spent (never, when unbounded).
func (b *budget) over() bool {
	return b.limit > 0 && b.now().Sub(b.start) >= b.limit
}

// Run syncs every enabled source that has a fetcher, sharing one budget,
// starting where the last budget cut left off. A source's error does not
// stop its siblings; errors are joined, except the expected
// needs_consent/revoked states, which are only recorded on the source.
func (e *Engine) Run(ctx context.Context) (Stats, error) {
	e.sweepTemp()
	var st Stats
	srcs, err := e.db.ListExtSources(providerConfluence)
	if err != nil {
		return st, fmt.Errorf("extsync: %w", err)
	}
	srcs = e.rotate(e.runnable(srcs))
	b := e.newBudget()
	stopped := map[int64]outcome{}
	var errs []error
	for i, src := range srcs {
		if b.over() {
			st.Incomplete = true
			e.startAt = src.ID
			break
		}
		s, runErr, recErr := e.syncSource(ctx, src, b, stopped)
		st.add(s)
		if ctx.Err() != nil {
			return st, ctx.Err()
		}
		if runErr != nil && !isExpected(runErr) {
			errs = append(errs, fmt.Errorf("source %d (%s): %w", src.ID, src.ContainerKey, runErr))
		}
		if recErr != nil {
			errs = append(errs, fmt.Errorf("source %d (%s): %w", src.ID, src.ContainerKey, recErr))
		}
		if s.Incomplete {
			e.startAt = srcs[(i+1)%len(srcs)].ID
			break
		}
	}
	if !st.Incomplete {
		// With the budget left after the sources: the one-shot relink of
		// documents stored before links existed (a single read once done).
		if err := e.relinkBackfill(ctx, b); err != nil {
			if ctx.Err() != nil {
				return st, ctx.Err()
			}
			errs = append(errs, err)
		}
	}
	return st, errors.Join(errs...)
}

// RunSource syncs one source with a fresh budget (the CLI `confluence sync`
// path) and records its status like Run. Unlike Run it returns the
// needs_consent/revoked errors, so the caller can show the hint.
func (e *Engine) RunSource(ctx context.Context, src db.ExtSource) (Stats, error) {
	if e.fetchers[src.JiraAccountID] == nil {
		return Stats{}, fmt.Errorf("extsync: no fetcher for source %d", src.ID)
	}
	e.sweepTemp()
	st, runErr, recErr := e.syncSource(ctx, src, e.newBudget(), map[int64]outcome{})
	if ctx.Err() != nil {
		return st, ctx.Err()
	}
	return st, errors.Join(runErr, recErr)
}

// sweepTemp removes the extractor's crash leftovers before a run spools
// anything new. A failure is logged, never fatal: the leftovers only cost
// disk, and the next run tries again.
func (e *Engine) sweepTemp() {
	s, ok := e.opts.Extractor.(TempSweeper)
	if !ok {
		return
	}
	n, err := s.SweepStale(e.opts.Now())
	if n > 0 {
		e.opts.Logger.Printf("removed %d stale attachment temp file(s)", n)
	}
	if err != nil {
		e.opts.Logger.Printf("sweeping attachment temp files: %v", err)
	}
}

// HasRunnable reports whether Run would sync any of srcs: an enabled source
// whose account has a fetcher. The daemon skips the phase (no pipeline_runs
// row, no link scan) when none is — e.g. every selected space belongs to a
// removed or disabled Jira account.
func (e *Engine) HasRunnable(srcs []db.ExtSource) bool {
	return len(e.runnable(srcs)) > 0
}

// runnable keeps the enabled sources whose account has a fetcher.
func (e *Engine) runnable(srcs []db.ExtSource) []db.ExtSource {
	var out []db.ExtSource
	for _, src := range srcs {
		if src.Enabled && e.fetchers[src.JiraAccountID] != nil {
			out = append(out, src)
		}
	}
	return out
}

// rotate starts srcs (ordered by id) at the first source with id >=
// e.startAt, wrapping the ones before it to the end.
func (e *Engine) rotate(srcs []db.ExtSource) []db.ExtSource {
	for i, src := range srcs {
		if src.ID >= e.startAt {
			out := append([]db.ExtSource(nil), srcs[i:]...)
			return append(out, srcs[:i]...)
		}
	}
	return srcs
}

// isExpected reports an expected re-consent state rather than a failure.
func isExpected(err error) bool {
	return errors.Is(err, ErrAuthRevoked) || errors.Is(err, ErrNeedsConsent)
}

// syncSource runs one source and records its outcome. An account already
// stopped this run (revoked, or missing consent), or whose scopes check
// fails, is recorded without any network call. runErr is the source's own
// error (the hint wrapping its sentinel for the expected states); recErr is
// a failure to record. A cancelled ctx records nothing.
func (e *Engine) syncSource(ctx context.Context, src db.ExtSource, b *budget, stopped map[int64]outcome) (st Stats, runErr, recErr error) {
	acct := src.JiraAccountID
	o, isStopped := stopped[acct]
	if !isStopped && e.opts.ScopesOK != nil && !e.opts.ScopesOK(acct) {
		o, isStopped = needsConsentOutcome(acct), true
		stopped[acct] = o
	}
	if isStopped {
		return st, o.err(), e.record(src, o)
	}
	st, runErr = e.runSource(ctx, src, e.fetchers[acct], b)
	if ctx.Err() != nil {
		return st, runErr, nil
	}
	o = classify(runErr, acct)
	if o.accountWide {
		stopped[acct] = o
	}
	if o.expected() {
		runErr = o.err()
	}
	return st, runErr, e.record(src, o)
}

// record writes a source's outcome. A clean run stamps last_synced_at and
// writes ok back only when the stored status is not already ok.
func (e *Engine) record(src db.ExtSource, o outcome) error {
	if o.status != statusOK {
		return e.db.SetExtSourceStatus(src.ID, o.status, o.text)
	}
	if _, err := e.db.Exec(`UPDATE ext_sources SET last_synced_at = ? WHERE id = ?`,
		formatTime(e.opts.Now()), src.ID); err != nil {
		return fmt.Errorf("extsync: stamping last sync of source %d: %w", src.ID, err)
	}
	if src.Status == statusOK && src.Error == "" {
		return nil
	}
	return e.db.SetExtSourceStatus(src.ID, statusOK, "")
}

// runSource runs src's streams in order (see runStreams), then the
// daily reconcile when due and budget remains, then resolves the users
// written this run.
func (e *Engine) runSource(ctx context.Context, src db.ExtSource, f Fetcher, b *budget) (Stats, error) {
	var st Stats
	p := pass{
		src: src, f: f, st: &st, users: userSet{}, budget: b, retried: map[string]bool{},
		c: Container{Key: src.ContainerKey, Name: src.ContainerName, ExtID: src.ContainerExtID},
	}
	err := e.runStreams(ctx, p, b)
	if err == nil && !st.Incomplete && !b.over() && e.reconcileAllowed(src, e.opts.Now()) {
		err = e.runReconcile(ctx, p)
	}
	// Users written by committed batches are resolved even after a later
	// failure, unless the account itself is failing or we are shutting down.
	if ctx.Err() == nil && !isExpected(err) {
		err = errors.Join(err, e.resolveUsers(ctx, src.Provider, f, p.users))
	}
	return st, err
}

// runStreams runs each stream in order (pages, comments, attachments),
// then the attachment revisit (skipped rows an extractor now handles,
// transient failures to retry), stopping when the budget runs out.
func (e *Engine) runStreams(ctx context.Context, p pass, b *budget) error {
	for _, spec := range []streamSpec{pagesStream, commentsStream, attachmentsStream} {
		p.spec = spec
		if err := e.runStream(ctx, p, b); err != nil {
			return err
		}
		if p.st.Incomplete {
			return nil
		}
	}
	return e.revisitAttachments(ctx, p, b)
}

// withTx runs fn in one transaction.
func (e *Engine) withTx(ctx context.Context, fn func(q Queryer) error) error {
	tx, err := e.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("extsync: begin: %w", err)
	}
	if err := fn(tx); err != nil {
		_ = tx.Rollback()
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("extsync: commit: %w", err)
	}
	return nil
}
