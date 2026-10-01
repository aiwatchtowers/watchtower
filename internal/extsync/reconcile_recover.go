package extsync

import (
	"cmp"
	"context"
	"fmt"
	"slices"
	"strconv"
)

// recoverBatchSize is how many refs (or comment parents) one recovery
// chunk handles between budget checks (a variable so tests can shrink it).
var recoverBatchSize = 20

// recoverListed fetches what the reconcile listing holds but the store
// lacks or holds at another version, through the same paths as the delta
// streams, without touching their state. The streams only see an item
// again when it is modified, so without this an item that comes back
// unmodified — a view restriction lifted, a page restored from the trash
// or moved into the space — would stay out of search until someone edits
// it. In order: pages and blog posts (each with its comment set), then
// attachments (the pending-version gate applies, see
// staleAttachmentRefs), then the comment sets of stored parents whose
// listed comments are missing or at another version.
//
// Chunks of recoverBatchSize, the budget checked before each except the
// first, so every reconcile makes progress even when the enumeration alone
// spent the budget. done is false when the budget cut it (Incomplete is
// set).
func (e *Engine) recoverListed(ctx context.Context, p pass, l reconcileListing) (done bool, err error) {
	local, err := localDocVersions(ctx, e.db, p.src.ID)
	if err != nil {
		return false, err
	}
	r := recovery{p: p}
	pages := listedStale(l.pages, local, false)
	if !r.chunks(len(pages), func(start, end int) (int, error) {
		return end - start, e.applyPages(ctx, p, pages[start:end], noTx)
	}) {
		return false, r.err
	}
	attachments := listedStale(l.attachments, local, true)
	if !r.chunks(len(attachments), func(start, end int) (int, error) {
		return e.applyAttachments(ctx, p, attachments[start:end], func(Queryer, int) error { return nil })
	}) {
		return false, r.err
	}
	parents, err := listedCommentParents(ctx, e.db, p.src.ID, l.comments)
	if err != nil {
		return false, err
	}
	if !r.chunks(len(parents), func(start, end int) (int, error) {
		return end - start, e.applyCommentSets(ctx, p, parents[start:end], noTx)
	}) {
		return false, r.err
	}
	return true, nil
}

// noTx is an inTx hook that adds nothing to the transaction.
func noTx(Queryer) error { return nil }

// recovery runs recoverListed's chunks under one budget; ran records that
// a chunk ran, so only the very first one ignores the budget.
type recovery struct {
	p   pass
	ran bool
	err error
}

// chunks runs apply over [0, n) in chunks of recoverBatchSize; apply
// returns how many of its chunk it processed. It reports whether all n
// were processed; on false, r.err holds the error, or Incomplete is set.
func (r *recovery) chunks(n int, apply func(start, end int) (int, error)) bool {
	for start := 0; start < n; start += recoverBatchSize {
		if r.ran && r.p.budget != nil && r.p.budget.over() {
			r.p.st.Incomplete = true
			return false
		}
		r.ran = true
		end := min(start+recoverBatchSize, n)
		done, err := apply(start, end)
		if err != nil {
			r.err = err
			return false
		}
		if done < end-start {
			r.p.st.Incomplete = true
			return false
		}
	}
	return true
}

// listedStale returns the listed refs the store lacks or holds at another
// version, sorted by ext id. With pending, a listed version equal to the
// stored pending one is not stale either: its retries belong to
// revisitAttachments.
func listedStale(listed map[string]ItemRef, local map[string]attachmentVersion, pending bool) []ItemRef {
	var out []ItemRef
	for id, r := range listed {
		v, ok := local[id]
		if ok && (v.stored == r.Version || (pending && v.pending == r.Version)) {
			continue
		}
		out = append(out, r)
	}
	slices.SortFunc(out, func(a, b ItemRef) int { return cmp.Compare(a.ExtID, b.ExtID) })
	return out
}

// localDocVersions reads the stored and pending versions of every document
// of sourceID in one query (pending 0 = none). A listing can hold far more
// ids than one IN clause takes, so the diff is made in memory.
func localDocVersions(ctx context.Context, q Queryer, sourceID int64) (map[string]attachmentVersion, error) {
	rows, err := q.QueryContext(ctx, `SELECT ext_id, version, COALESCE(json_extract(meta_json, ?), '')
		FROM ext_documents WHERE source_id = ?`, "$."+pendingVersionKey, sourceID)
	if err != nil {
		return nil, fmt.Errorf("extsync: reading local document versions: %w", err)
	}
	defer rows.Close()
	out := map[string]attachmentVersion{}
	for rows.Next() {
		var id, pending string
		var v attachmentVersion
		if err := rows.Scan(&id, &v.stored, &pending); err != nil {
			return nil, fmt.Errorf("extsync: scanning local document version: %w", err)
		}
		v.pending, _ = strconv.Atoi(pending) // absent or malformed = no pending version
		out[id] = v
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("extsync: reading local document versions: %w", err)
	}
	return out, nil
}

// listedCommentParents returns, sorted, the stored pages and blog posts
// with a listed comment the store lacks or holds at another version. It
// reads the store after the page recovery, so a parent recovered with its
// comment set is not reloaded again.
func listedCommentParents(ctx context.Context, q Queryer, sourceID int64, listed map[string]ItemRef) ([]string, error) {
	stored, err := localComments(ctx, q, sourceID)
	if err != nil {
		return nil, err
	}
	versions := make(map[string]int, len(stored))
	for _, c := range stored {
		versions[c.id] = c.version
	}
	ids, err := localIDs(ctx, q, sourceID, []ItemKind{KindPage, KindBlogpost})
	if err != nil {
		return nil, err
	}
	parents := make(map[string]bool, len(ids))
	for _, id := range ids {
		parents[id] = false
	}
	for id, r := range listed {
		if v, ok := versions[id]; ok && v == r.Version {
			continue
		}
		if _, ok := parents[r.ParentID]; ok {
			parents[r.ParentID] = true
		}
	}
	var out []string
	for id, reload := range parents {
		if reload {
			out = append(out, id)
		}
	}
	slices.Sort(out)
	return out, nil
}
