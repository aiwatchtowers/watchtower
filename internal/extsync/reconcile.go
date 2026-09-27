package extsync

import (
	"context"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
)

// reconcileSet is one enumeration the daily reconcile compares against: the
// kind passed to All and the local kinds it covers. All(KindPage) lists
// pages and blog posts together, mirroring Changed.
type reconcileSet struct {
	kind  ItemKind
	local []ItemKind
}

var reconcileSets = []reconcileSet{
	{kind: KindPage, local: []ItemKind{KindPage, KindBlogpost}},
	{kind: KindAttachment, local: []ItemKind{KindAttachment}},
}

// reconcileDue reports whether src has not been reconciled on now's UTC
// date. An empty or unparseable stamp is due.
func reconcileDue(lastReconcileAt string, now time.Time) bool {
	last, err := time.Parse(isoLayout, lastReconcileAt)
	if err != nil {
		return true
	}
	ly, lm, ld := last.UTC().Date()
	ny, nm, nd := now.UTC().Date()
	return ly != ny || lm != nm || ld != nd
}

// reconcileRetryAfter is how long a source whose reconcile failed waits
// before the next try. The full enumeration is the most expensive thing a
// source does; without it a persistently failing reconcile (last_reconcile_at
// stays unstamped, so it stays due) would re-enumerate every cycle.
const reconcileRetryAfter = 4 * time.Hour

// reconcileAllowed reports whether src's reconcile should run now: due on
// now's UTC date, and not failed within reconcileRetryAfter. The failure
// backoff is kept in memory, not in last_reconcile_at: stamping that would
// make a failed attempt look like a successful reconcile (and push the
// retry to the next UTC day), and a daemon restart or a manual
// `confluence sync` retrying at once is the wanted behavior.
func (e *Engine) reconcileAllowed(src db.ExtSource, now time.Time) bool {
	if !reconcileDue(src.LastReconcileAt, now) {
		return false
	}
	failed, ok := e.reconcileFailedAt[src.ID]
	return !ok || now.Sub(failed) >= reconcileRetryAfter
}

// runReconcile runs reconcile and records its outcome for the backoff. A
// shutdown-cancelled attempt is not a failure.
func (e *Engine) runReconcile(ctx context.Context, p pass) error {
	err := e.reconcile(ctx, p)
	switch {
	case err == nil:
		delete(e.reconcileFailedAt, p.src.ID)
	case ctx.Err() == nil:
		e.reconcileFailedAt[p.src.ID] = e.opts.Now()
	}
	return err
}

// reconcile deletes the local documents (and their comments) and the
// comments the provider no longer enumerates — trashed, moved to another
// container, or no longer visible to the account, which is the whole
// permission model — and stamps last_reconcile_at. Every enumeration,
// comments included, completes before anything is deleted, so a failed
// listing deletes nothing.
func (e *Engine) reconcile(ctx context.Context, p pass) error {
	remote, remoteComments, err := enumerateReconcile(ctx, p)
	if err != nil {
		return err
	}
	deleted := 0
	err = e.withTx(ctx, func(q Queryer) error {
		n, err := e.reconcileDocs(ctx, q, p.src, remote)
		if err != nil {
			return err
		}
		deleted = n
		// After the documents: a deleted document's comments are gone
		// already, so only the surviving parents are stamped and relinked.
		if err := e.reconcileComments(ctx, q, p.src, remoteComments); err != nil {
			return err
		}
		if _, err := q.ExecContext(ctx, `UPDATE ext_sources SET last_reconcile_at = ? WHERE id = ?`,
			formatTime(e.opts.Now()), p.src.ID); err != nil {
			return fmt.Errorf("extsync: stamping reconcile: %w", err)
		}
		return nil
	})
	if err != nil {
		return err
	}
	p.st.Deleted += deleted
	return nil
}

// enumerateReconcile drains every reconcile enumeration: one id set per
// reconcileSets entry, then the comments.
func enumerateReconcile(ctx context.Context, p pass) ([]map[string]bool, map[string]bool, error) {
	remote := make([]map[string]bool, len(reconcileSets))
	for i, rs := range reconcileSets {
		ids, err := enumerateAll(ctx, p.f, p.c, rs.kind)
		if err != nil {
			return nil, nil, err
		}
		remote[i] = ids
	}
	comments, err := enumerateAll(ctx, p.f, p.c, KindComment)
	if err != nil {
		return nil, nil, err
	}
	return remote, comments, nil
}

// reconcileDocs deletes the documents absent from remote (one set per
// reconcileSets entry) and relinks them, returning how many were deleted.
func (e *Engine) reconcileDocs(ctx context.Context, q Queryer, src db.ExtSource, remote []map[string]bool) (int, error) {
	deleted := 0
	for i, rs := range reconcileSets {
		gone, err := deleteAbsent(ctx, q, src.ID, rs.local, remote[i])
		if err != nil {
			return 0, err
		}
		if err := e.relinkDocs(ctx, q, src.Provider, src.ID, gone); err != nil {
			return 0, err
		}
		deleted += len(gone)
	}
	return deleted, nil
}

// reconcileComments deletes the stored comments absent from remote. A
// comment deletion does not bump its page's version, and the comments
// stream only lists what changed, so without this a deleted comment would
// stay searchable forever. Each parent that lost a comment is stamped
// children_changed_at (the KB re-renders it) and relinked.
func (e *Engine) reconcileComments(ctx context.Context, q Queryer, src db.ExtSource, remote map[string]bool) error {
	local, err := localComments(ctx, q, src.ID)
	if err != nil {
		return err
	}
	var parents []string
	seen := map[string]bool{}
	for _, c := range local {
		if remote[c.id] {
			continue
		}
		if _, err := q.ExecContext(ctx, `DELETE FROM ext_comments WHERE source_id = ? AND ext_id = ?`,
			src.ID, c.id); err != nil {
			return fmt.Errorf("extsync: deleting comment %s: %w", c.id, err)
		}
		if !seen[c.page] {
			seen[c.page] = true
			parents = append(parents, c.page)
		}
	}
	now := e.opts.Now()
	for _, page := range parents {
		if err := stampChildrenChanged(ctx, q, src.ID, page, now); err != nil {
			return err
		}
	}
	return e.relinkDocs(ctx, q, src.Provider, src.ID, parents)
}

// storedComment is one ext_comments row's identity.
type storedComment struct{ id, page string }

// localComments lists the stored comments of sourceID, ordered by id. The
// rows are closed before it returns (see localIDs).
func localComments(ctx context.Context, q Queryer, sourceID int64) ([]storedComment, error) {
	rows, err := q.QueryContext(ctx, `SELECT ext_id, page_ext_id FROM ext_comments
		WHERE source_id = ? ORDER BY ext_id`, sourceID)
	if err != nil {
		return nil, fmt.Errorf("extsync: listing local comments: %w", err)
	}
	defer rows.Close()
	var out []storedComment
	for rows.Next() {
		var c storedComment
		if err := rows.Scan(&c.id, &c.page); err != nil {
			return nil, fmt.Errorf("extsync: scanning local comment: %w", err)
		}
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("extsync: listing local comments: %w", err)
	}
	return out, nil
}

// enumerateAll drains All(kind) into a set of ext ids.
func enumerateAll(ctx context.Context, f Fetcher, c Container, kind ItemKind) (map[string]bool, error) {
	ids := map[string]bool{}
	page := ""
	for {
		refs, next, err := f.All(ctx, c, kind, page)
		if err != nil {
			return nil, fmt.Errorf("extsync: enumerating %s: %w", kind, err)
		}
		for _, r := range refs {
			ids[r.ExtID] = true
		}
		if next == "" {
			return ids, nil
		}
		page = next
	}
}

// deleteAbsent deletes the local documents of kinds whose ext id is not in
// remote, returning their ids.
func deleteAbsent(ctx context.Context, q Queryer, sourceID int64, kinds []ItemKind, remote map[string]bool) ([]string, error) {
	local, err := localIDs(ctx, q, sourceID, kinds)
	if err != nil {
		return nil, err
	}
	var gone []string
	for _, id := range local {
		if remote[id] {
			continue
		}
		if err := deleteDocument(ctx, q, sourceID, id); err != nil {
			return nil, err
		}
		gone = append(gone, id)
	}
	return gone, nil
}

// localIDs lists the stored document ids of kinds. The rows are closed
// before it returns: a transaction runs on one connection, so the caller's
// deletes must not overlap an open result set.
func localIDs(ctx context.Context, q Queryer, sourceID int64, kinds []ItemKind) ([]string, error) {
	args := make([]any, 0, len(kinds)+1)
	args = append(args, sourceID)
	for _, k := range kinds {
		args = append(args, string(k))
	}
	placeholders := strings.TrimSuffix(strings.Repeat("?,", len(kinds)), ",")
	rows, err := q.QueryContext(ctx, `SELECT ext_id FROM ext_documents
		WHERE source_id = ? AND kind IN (`+placeholders+`)`, args...)
	if err != nil {
		return nil, fmt.Errorf("extsync: listing local documents: %w", err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("extsync: scanning local document: %w", err)
		}
		out = append(out, id)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("extsync: listing local documents: %w", err)
	}
	return out, nil
}
