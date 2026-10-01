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
// lacks, or holds at an older version, through the same paths as the
// delta streams, without touching their state. The streams only see an
// item again when it is modified, so without this an item that comes back
// unmodified — a view restriction lifted, a page restored from the trash
// or moved into the space — would stay out of search until someone edits
// it. In order: pages and blog posts (each with its comment set), then
// attachments, then the comment sets of stored parents whose listed
// comments are missing or newer.
//
// Only a newer listed version counts: a listing may come from a lagging
// search index, and an older listed version would otherwise be re-fetched
// (an attachment re-downloaded and re-extracted) on every reconcile.
//
// Chunks of recoverBatchSize, the budget checked before each except the
// very first, so a reconcile whose enumeration spent the budget still
// progresses. A chunk that fails is retried ref by ref, and a ref that
// still fails for itself (anything but auth/consent or a cancelled ctx) is
// logged and left to the next reconcile, so one unfetchable item cannot
// hold back the rest. done is false when the budget cut it (Incomplete is
// set).
func (e *Engine) recoverListed(ctx context.Context, p pass, l reconcileListing) (done bool, err error) {
	local, err := localDocVersions(ctx, e.db, p.src.ID)
	if err != nil {
		return false, err
	}
	ran := false
	refID := func(r ItemRef) string { return r.ExtID }
	pages := listedNewer(l.pages, local)
	done, err = recoverEach(ctx, e, p, &ran, pages, refID, func(refs []ItemRef) (int, error) {
		return len(refs), e.applyPages(ctx, p, refs, func(Queryer) error { return nil })
	})
	if err != nil || !done {
		return false, err
	}
	attachments := listedNewer(l.attachments, local)
	done, err = recoverEach(ctx, e, p, &ran, attachments, refID, func(refs []ItemRef) (int, error) {
		return e.applyAttachments(ctx, p, refs, func(Queryer, int) error { return nil })
	})
	if err != nil || !done {
		return false, err
	}
	parents, err := listedCommentParents(ctx, e.db, p.src.ID, l.comments)
	if err != nil {
		return false, err
	}
	return recoverEach(ctx, e, p, &ran, parents, func(id string) string { return id }, func(ids []string) (int, error) {
		return len(ids), e.applyCommentSets(ctx, p, ids, func(Queryer) error { return nil })
	})
}

// recoverEach runs apply over items in chunks of recoverBatchSize (see
// recoverListed); apply returns how many of its chunk it processed. *ran
// records that a chunk ran, so only the very first one of a reconcile
// ignores the budget.
func recoverEach[T any](ctx context.Context, e *Engine, p pass, ran *bool, items []T, id func(T) string,
	apply func([]T) (int, error)) (bool, error) {
	for start := 0; start < len(items); start += recoverBatchSize {
		if *ran && p.budget != nil && p.budget.over() {
			p.st.Incomplete = true
			return false, nil
		}
		*ran = true
		chunk := items[start:min(start+recoverBatchSize, len(items))]
		done, err := apply(chunk)
		if err != nil {
			if ctx.Err() != nil || isExpected(err) {
				return false, err
			}
			done, err = recoverOneByOne(ctx, e, p, chunk, id, apply)
			if err != nil {
				return false, err
			}
		}
		if done < len(chunk) {
			p.st.Incomplete = true
			return false, nil
		}
	}
	return true, nil
}

// recoverOneByOne retries a failed chunk an item at a time, logging and
// skipping the items that fail for themselves. The budget is checked
// before each item but the first, like recoverEach's chunks; it returns
// how many items it got through.
func recoverOneByOne[T any](ctx context.Context, e *Engine, p pass, chunk []T, id func(T) string,
	apply func([]T) (int, error)) (int, error) {
	for i, it := range chunk {
		if i > 0 && p.budget != nil && p.budget.over() {
			return i, nil
		}
		if _, err := apply(chunk[i : i+1]); err != nil {
			if ctx.Err() != nil || isExpected(err) {
				return 0, err
			}
			e.opts.Logger.Printf("source %d: reconcile could not recover %s (left to the next reconcile): %v", p.src.ID, id(it), err)
		}
	}
	return len(chunk), nil
}

// docVersion is a stored document's version and the version its pending
// retry tried (pending 0 = none, see pendingVersionKey).
type docVersion struct{ stored, pending int }

// listedNewer returns, sorted by ext id, the listed refs the store lacks or
// holds at an older version than listed — older than both the stored and
// the pending version, whose retries belong to revisitAttachments.
func listedNewer(listed map[string]ItemRef, local map[string]docVersion) []ItemRef {
	var out []ItemRef
	for id, r := range listed {
		if v, ok := local[id]; ok && r.Version <= max(v.stored, v.pending) {
			continue
		}
		out = append(out, r)
	}
	slices.SortFunc(out, func(a, b ItemRef) int { return cmp.Compare(a.ExtID, b.ExtID) })
	return out
}

// localDocVersions reads the stored and pending versions of every document
// of sourceID in one query. A listing can hold far more ids than one IN
// clause takes, so the diff is made in memory.
func localDocVersions(ctx context.Context, q Queryer, sourceID int64) (map[string]docVersion, error) {
	rows, err := q.QueryContext(ctx, `SELECT ext_id, version, COALESCE(json_extract(meta_json, ?), '')
		FROM ext_documents WHERE source_id = ?`, "$."+pendingVersionKey, sourceID)
	if err != nil {
		return nil, fmt.Errorf("extsync: reading local document versions: %w", err)
	}
	defer rows.Close()
	out := map[string]docVersion{}
	for rows.Next() {
		var id, pending string
		var v docVersion
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
// with a listed comment the store lacks or holds at an older version. It
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
		if v, ok := versions[id]; ok && r.Version <= v {
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
