package extsync

import (
	"context"
	"fmt"
	"strings"
	"time"

	"golang.org/x/sync/errgroup"

	"watchtower/internal/db"
)

// cursorOverlap re-lists the minute before a stream's cursor on every pass:
// providers may compare modification times at minute precision (Confluence
// CQL), and the version gate makes the re-listed rows free.
const cursorOverlap = time.Minute

// fetchConcurrency bounds in-flight Fetch calls per batch.
const fetchConcurrency = 4

// tokenSep separates the pass anchor from the provider's pagination token in
// a stored token. An RFC3339 time never contains it.
const tokenSep = "|"

// streamSpec describes one delta stream: which state columns it owns and
// which kind it enumerates.
type streamSpec struct {
	name streamName
	kind ItemKind
}

// pagesStream enumerates pages and blog posts in one pass (the provider's
// Changed(KindPage) covers both), sharing page_cursor/page_token.
var pagesStream = streamSpec{name: streamPages, kind: KindPage}

// streamState returns the stored (cursor, token) of stream on src.
func streamState(src db.ExtSource, stream streamName) (string, string) {
	switch stream {
	case streamPages:
		return src.PageCursor, src.PageToken
	}
	return "", ""
}

// encodeToken stores a pagination token together with the since value of
// the pass it belongs to. A provider token is only valid for the query it
// was issued for, and the cursor advances with every batch, so a resumed
// pass must replay the pass's original since rather than recompute it from
// the cursor — otherwise items between the old and new since would be
// skipped.
func encodeToken(anchor time.Time, page string) string {
	return formatTime(anchor) + tokenSep + page
}

// decodeToken splits a stored token. ok is false for "" (no pass in
// flight) and for a malformed token, which is dropped.
func decodeToken(token string) (anchor time.Time, page string, ok bool) {
	head, page, found := strings.Cut(token, tokenSep)
	if !found || page == "" {
		return time.Time{}, "", false
	}
	if head == "" {
		return time.Time{}, page, true
	}
	anchor, err := time.Parse(isoLayout, head)
	if err != nil {
		return time.Time{}, "", false
	}
	return anchor, page, true
}

// sinceOf is the since of a fresh pass: cursor − overlap, zero for an empty
// cursor (a full backfill).
func sinceOf(cursor string) (time.Time, error) {
	if cursor == "" {
		return time.Time{}, nil
	}
	t, err := time.Parse(isoLayout, cursor)
	if err != nil {
		return time.Time{}, fmt.Errorf("extsync: bad cursor %q: %w", cursor, err)
	}
	return t.Add(-cursorOverlap), nil
}

// advanceCursor returns max(cursor, max Modified of refs).
func advanceCursor(cursor string, refs []ItemRef) string {
	best, _ := time.Parse(isoLayout, cursor) // "" → zero time
	for _, r := range refs {
		if r.Modified.After(best) {
			best = r.Modified
		}
	}
	return formatTime(best)
}

// pass is the per-source context of one stream run.
type pass struct {
	src  db.ExtSource
	f    Fetcher
	c    Container
	spec streamSpec
	st   *Stats
}

// batch is one Changed page ready to be applied.
type batch struct {
	refs         []ItemRef
	cursor       string // cursor before this batch
	token        string // stored token to save with this batch
	backfillDone bool   // this batch completes a pass from an empty cursor
}

// runStream drains one stream. A pass that resumes a saved token and then
// completes is followed by a fresh pass from the cursor; a fresh pass that
// completes ends the stream for this cycle. The budget is checked only
// between batches: a started batch always commits.
func (e *Engine) runStream(ctx context.Context, p pass, b *budget) error {
	cursor, token := streamState(p.src, p.spec.name)
	for {
		anchor, page, resumed := decodeToken(token)
		if !resumed {
			if token != "" {
				e.opts.Logger.Printf("source %d: dropping malformed %s token", p.src.ID, p.spec.name)
			}
			var err error
			if anchor, err = sinceOf(cursor); err != nil {
				return err
			}
		}
		refs, next, err := p.f.Changed(ctx, p.c, p.spec.kind, anchor, page)
		if err != nil {
			return fmt.Errorf("extsync: listing %s changes: %w", p.spec.kind, err)
		}
		bt := batch{refs: refs, cursor: cursor, backfillDone: next == "" && anchor.IsZero()}
		if next != "" {
			bt.token = encodeToken(anchor, next)
		}
		if cursor, err = e.processBatch(ctx, p, bt); err != nil {
			return err
		}
		token = bt.token
		if next == "" && !resumed {
			return nil
		}
		if b.over() {
			p.st.Incomplete = true
			return nil
		}
	}
}

// processBatch applies one batch: the version gate, the fetches, then one
// transaction writing the rows and the stream state. It returns the new
// cursor.
func (e *Engine) processBatch(ctx context.Context, p pass, bt batch) (string, error) {
	ids := make([]string, len(bt.refs))
	for i, r := range bt.refs {
		ids[i] = r.ExtID
	}
	local, err := localVersions(ctx, e.db, p.src.ID, ids)
	if err != nil {
		return "", err
	}
	var stale []ItemRef
	for _, r := range bt.refs {
		if v, ok := local[r.ExtID]; !ok || v != r.Version {
			stale = append(stale, r)
		}
	}
	items, err := fetchAll(ctx, p.f, p.c, stale)
	if err != nil {
		return "", err
	}
	cursor := advanceCursor(bt.cursor, bt.refs)
	var st Stats
	st.Unchanged = len(bt.refs) - len(stale)
	err = e.withTx(ctx, func(q Queryer) error {
		if err := writeItems(ctx, q, p.src.ID, stale, items, e.opts.Now(), &st); err != nil {
			return err
		}
		if err := saveStream(ctx, q, p.src.ID, p.spec.name, cursor, bt.token); err != nil {
			return err
		}
		if bt.backfillDone {
			return markBackfillDone(ctx, q, p.src.ID)
		}
		return nil
	})
	if err != nil {
		return "", err
	}
	p.st.add(st)
	return cursor, nil
}

// writeItems upserts fetched items and deletes the refs whose Fetch
// reported them gone.
func writeItems(ctx context.Context, q Queryer, sourceID int64, refs []ItemRef, items []*Item, now time.Time, st *Stats) error {
	for i, it := range items {
		if it == nil {
			if err := deleteDocument(ctx, q, sourceID, refs[i].ExtID); err != nil {
				return err
			}
			st.Deleted++
			continue
		}
		if err := upsertDocument(ctx, q, sourceID, it, now); err != nil {
			return err
		}
		st.Fetched++
	}
	return nil
}

// fetchAll fetches refs with up to fetchConcurrency in flight; results are
// in ref order, nil for a gone item.
func fetchAll(ctx context.Context, f Fetcher, c Container, refs []ItemRef) ([]*Item, error) {
	items := make([]*Item, len(refs))
	g, gctx := errgroup.WithContext(ctx)
	g.SetLimit(fetchConcurrency)
	for i, r := range refs {
		g.Go(func() error {
			it, err := f.Fetch(gctx, c, r)
			if err != nil {
				return fmt.Errorf("extsync: fetching %s %s: %w", r.Kind, r.ExtID, err)
			}
			items[i] = it
			return nil
		})
	}
	if err := g.Wait(); err != nil {
		return nil, err
	}
	return items, nil
}
