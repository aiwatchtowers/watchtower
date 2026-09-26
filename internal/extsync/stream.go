package extsync

import (
	"context"
	"errors"
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

// batchApplier applies one listed batch of a stream and returns the new
// cursor; it commits the batch's rows and the stream state in one
// transaction.
type batchApplier func(e *Engine, ctx context.Context, p pass, bt batch) (string, error)

// streamSpec describes one delta stream: which state columns it owns, which
// kind it enumerates and how a batch is applied.
type streamSpec struct {
	name  streamName
	kind  ItemKind
	apply batchApplier
	// marksBackfill: completing a pass from an empty cursor sets
	// ext_sources.backfill_done.
	marksBackfill bool
}

// pagesStream enumerates pages and blog posts in one pass (the provider's
// Changed(KindPage) covers both), sharing page_cursor/page_token.
var pagesStream = streamSpec{name: streamPages, kind: KindPage, apply: (*Engine).processBatch, marksBackfill: true}

// streamState returns the stored (cursor, token) of stream on src.
func streamState(src db.ExtSource, stream streamName) (string, string) {
	switch stream {
	case streamPages:
		return src.PageCursor, src.PageToken
	case streamComments:
		return src.CommentCursor, src.CommentToken
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

// parseCursor parses a stored cursor; "" is the zero time (never synced).
func parseCursor(cursor string) (time.Time, error) {
	if cursor == "" {
		return time.Time{}, nil
	}
	t, err := time.Parse(isoLayout, cursor)
	if err != nil {
		return time.Time{}, fmt.Errorf("extsync: bad cursor %q: %w", cursor, err)
	}
	return t, nil
}

// sinceOf is the since of a fresh pass: cursor − overlap, zero for an empty
// cursor (a full backfill).
func sinceOf(cursor string) (time.Time, error) {
	t, err := parseCursor(cursor)
	if err != nil || t.IsZero() {
		return t, err
	}
	return t.Add(-cursorOverlap), nil
}

// advanceCursor returns max(cursor, max Modified of refs).
func advanceCursor(cursor string, refs []ItemRef) (string, error) {
	best, err := parseCursor(cursor)
	if err != nil {
		return "", err
	}
	for _, r := range refs {
		if r.Modified.After(best) {
			best = r.Modified
		}
	}
	return formatTime(best), nil
}

// pass is the per-source context of one stream run.
type pass struct {
	src   db.ExtSource
	f     Fetcher
	c     Container
	spec  streamSpec
	st    *Stats
	users userSet // authors and mentions written this run
}

// batch is one Changed page ready to be applied.
type batch struct {
	refs         []ItemRef
	cursor       string // cursor before this batch
	token        string // stored token to save with this batch
	backfillDone bool   // this batch completes a pass from an empty cursor
}

// runStream drains one stream for this cycle. Whether the stream entry
// resumes a stored token is decided once, up front: a fresh pass that
// completes ends the stream; a resumed pass that completes is followed by
// at most one fresh pass from the advanced cursor, which then ends it. A
// cycle therefore makes at most two passes, however many pages the overlap
// window holds. The budget is checked only between batches: a started
// batch always commits. A malformed cursor fails the stream before any
// network call.
func (e *Engine) runStream(ctx context.Context, p pass, b *budget) error {
	cursor, token := streamState(p.src, p.spec.name)
	if _, err := parseCursor(cursor); err != nil {
		return err
	}
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
	freshPassLeft := resumed
	for {
		next, err := e.streamBatch(ctx, p, &cursor, anchor, page)
		if err != nil {
			return err
		}
		page = next
		if next == "" {
			if !freshPassLeft {
				return nil
			}
			freshPassLeft = false
			if anchor, err = sinceOf(cursor); err != nil {
				return err
			}
		}
		if b.over() {
			p.st.Incomplete = true
			return nil
		}
	}
}

// streamBatch lists one page of the pass anchored at anchor and applies it,
// advancing *cursor. It returns the provider's next token ("" = the pass is
// complete).
func (e *Engine) streamBatch(ctx context.Context, p pass, cursor *string, anchor time.Time, page string) (string, error) {
	refs, next, err := p.f.Changed(ctx, p.c, p.spec.kind, anchor, page)
	if err != nil {
		err = fmt.Errorf("extsync: listing %s changes: %w", p.spec.kind, err)
		return "", e.dropTokenOnFailure(ctx, p, *cursor, page, err)
	}
	bt := batch{refs: refs, cursor: *cursor, backfillDone: p.spec.marksBackfill && next == "" && anchor.IsZero()}
	if next != "" {
		bt.token = encodeToken(anchor, next)
	}
	if *cursor, err = p.spec.apply(e, ctx, p, bt); err != nil {
		return "", err
	}
	return next, nil
}

// dropTokenOnFailure clears the stream's stored token after a Changed call
// that carried one failed: a provider may expire or reject a pagination
// token, and a kept token would wedge the stream on it forever. The next
// cycle starts a fresh pass from the cursor, which is lossless because
// every committed batch already advanced it. A cancelled ctx (shutdown)
// keeps the token. It returns err, joined with a failure to clear.
func (e *Engine) dropTokenOnFailure(ctx context.Context, p pass, cursor, page string, err error) error {
	if page == "" || ctx.Err() != nil {
		return err
	}
	if serr := saveStream(ctx, e.db, p.src.ID, p.spec.name, cursor, ""); serr != nil {
		return errors.Join(err, serr)
	}
	return err
}

// processBatch applies one batch: the version gate, the fetches (each
// re-fetched page with its full comment set), then one transaction writing
// the rows and the stream state. It returns the new cursor.
func (e *Engine) processBatch(ctx context.Context, p pass, bt batch) (string, error) {
	stale, err := staleRefs(ctx, e.db, p.src.ID, bt.refs)
	if err != nil {
		return "", err
	}
	items, err := fetchAll(ctx, p.f, p.c, stale)
	if err != nil {
		return "", err
	}
	parents := commentParents(items)
	sets, err := fetchCommentSets(ctx, p.f, p.c, parents)
	if err != nil {
		return "", err
	}
	cursor, err := advanceCursor(bt.cursor, bt.refs)
	if err != nil {
		return "", err
	}
	st := Stats{Unchanged: len(bt.refs) - len(stale)}
	err = e.withTx(ctx, func(q Queryer) error {
		if err := writeItems(ctx, q, p.src.ID, stale, items, e.opts.Now(), &st); err != nil {
			return err
		}
		for i, parent := range parents {
			if err := replaceComments(ctx, q, p.src.ID, parent, sets[i]); err != nil {
				return err
			}
			st.Comments += len(sets[i])
		}
		return saveBatchState(ctx, q, p, bt, cursor)
	})
	if err != nil {
		return "", err
	}
	p.st.add(st)
	collectUsers(p.users, items, sets)
	return cursor, nil
}

// staleRefs returns the refs whose version differs from the stored one (or
// that are not stored at all): the only ones worth fetching.
func staleRefs(ctx context.Context, q Queryer, sourceID int64, refs []ItemRef) ([]ItemRef, error) {
	ids := make([]string, len(refs))
	for i, r := range refs {
		ids[i] = r.ExtID
	}
	local, err := localVersions(ctx, q, sourceID, ids)
	if err != nil {
		return nil, err
	}
	var stale []ItemRef
	for _, r := range refs {
		if v, ok := local[r.ExtID]; !ok || v != r.Version {
			stale = append(stale, r)
		}
	}
	return stale, nil
}

// saveBatchState persists the stream state a committed batch reached.
func saveBatchState(ctx context.Context, q Queryer, p pass, bt batch, cursor string) error {
	if err := saveStream(ctx, q, p.src.ID, p.spec.name, cursor, bt.token); err != nil {
		return err
	}
	if bt.backfillDone {
		return markBackfillDone(ctx, q, p.src.ID)
	}
	return nil
}

// commentParents returns the ids of the fetched items that carry comments;
// a re-fetched page reloads its whole comment set in the same batch.
func commentParents(items []*Item) []string {
	var out []string
	for _, it := range items {
		if it != nil && isCommentParent(it.Ref.Kind) {
			out = append(out, it.Ref.ExtID)
		}
	}
	return out
}

// collectUsers records the authors and mentions of written items and
// comments.
func collectUsers(u userSet, items []*Item, sets [][]Item) {
	for _, it := range items {
		if it != nil {
			u.addItem(it)
		}
	}
	for _, set := range sets {
		for i := range set {
			u.addItem(&set[i])
		}
	}
}

// writeItems upserts fetched items and deletes the refs whose Fetch
// reported them gone.
func writeItems(ctx context.Context, q Queryer, sourceID int64, refs []ItemRef, items []*Item, now time.Time, st *Stats) error {
	for i, it := range items {
		if it != nil && it.Ref.ExtID != refs[i].ExtID {
			return fmt.Errorf("extsync: fetch of %s returned item %q", refs[i].ExtID, it.Ref.ExtID)
		}
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
