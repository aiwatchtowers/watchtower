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
type Engine struct {
	db       *db.DB
	fetchers map[int64]Fetcher // by jira_accounts.id
	opts     Options
}

// New returns an engine over d. Unset Options fields get their defaults.
func New(d *db.DB, opts Options) *Engine {
	if opts.Now == nil {
		opts.Now = time.Now
	}
	if opts.Logger == nil {
		opts.Logger = log.New(io.Discard, "", 0)
	}
	return &Engine{db: d, fetchers: map[int64]Fetcher{}, opts: opts}
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

// Run syncs every enabled source that has a fetcher, sharing one budget. A
// source's error does not stop its siblings; all errors are joined.
func (e *Engine) Run(ctx context.Context) (Stats, error) {
	var st Stats
	srcs, err := e.db.ListExtSources(providerConfluence)
	if err != nil {
		return st, fmt.Errorf("extsync: %w", err)
	}
	b := e.newBudget()
	var errs []error
	for _, src := range srcs {
		f := e.fetchers[src.JiraAccountID]
		if !src.Enabled || f == nil {
			continue
		}
		if b.over() {
			st.Incomplete = true
			break
		}
		s, err := e.runSource(ctx, src, f, b)
		st.add(s)
		if err != nil {
			if ctx.Err() != nil {
				return st, ctx.Err()
			}
			errs = append(errs, fmt.Errorf("source %d (%s): %w", src.ID, src.ContainerKey, err))
		}
	}
	return st, errors.Join(errs...)
}

// RunSource syncs one source with a fresh budget (the CLI `confluence sync`
// path).
func (e *Engine) RunSource(ctx context.Context, src db.ExtSource) (Stats, error) {
	f := e.fetchers[src.JiraAccountID]
	if f == nil {
		return Stats{}, fmt.Errorf("extsync: no fetcher for source %d", src.ID)
	}
	return e.runSource(ctx, src, f, e.newBudget())
}

// runSource runs src's streams in order, stopping when the budget runs out.
func (e *Engine) runSource(ctx context.Context, src db.ExtSource, f Fetcher, b *budget) (Stats, error) {
	var st Stats
	c := Container{Key: src.ContainerKey, Name: src.ContainerName, ExtID: src.ContainerExtID}
	for _, spec := range []streamSpec{pagesStream} {
		if err := e.runStream(ctx, pass{src: src, f: f, c: c, spec: spec, st: &st}, b); err != nil {
			return st, err
		}
		if st.Incomplete {
			break
		}
	}
	return st, nil
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
