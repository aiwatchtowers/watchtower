package extsync

import (
	"context"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/db"
)

// reconcileListing is what the daily reconcile enumerated: every visible
// ref of the source, by ext id. All(KindPage) lists pages and blog posts
// together, mirroring Changed.
type reconcileListing struct {
	pages, attachments, comments map[string]ItemRef
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
// permission model — except the children guardChildren keeps (a listing
// that looks degraded), and stamps last_reconcile_at in the same
// transaction. Every enumeration, comments included, completes before
// anything is deleted, so a failed listing deletes nothing. It then fetches
// what the listing holds but the store lacks (see recoverListed); a
// recovery the budget cuts keeps its listing in memory and resumes on the
// next cycles (resumeRecovery) without enumerating again.
func (e *Engine) reconcile(ctx context.Context, p pass) error {
	c, err := e.refreshContainer(ctx, p)
	if err != nil {
		return err
	}
	p.c = c
	l, err := enumerateReconcile(ctx, p)
	if err != nil {
		return err
	}
	kept, err := e.guardChildren(ctx, p, l)
	if err != nil {
		return err
	}
	deleted := 0
	err = e.withTx(ctx, func(q Queryer) error {
		n, err := e.reconcileDocs(ctx, q, p.src, l, kept.attachments)
		if err != nil {
			return err
		}
		deleted = n
		// After the documents: a deleted document's comments are gone
		// already, so only the surviving parents are stamped and relinked.
		if err := e.reconcileComments(ctx, q, p.src, l.comments, kept.comments); err != nil {
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
	return e.resumeRecovery(ctx, p, l)
}

// resumeRecovery runs recoverListed over l and keeps l for the next cycle
// while the budget cuts it. A restart drops a kept listing: the next daily
// reconcile lists everything again.
func (e *Engine) resumeRecovery(ctx context.Context, p pass, l reconcileListing) error {
	delete(e.pendingRecovery, p.src.ID)
	done, err := e.recoverListed(ctx, p, l)
	if err == nil && !done {
		e.pendingRecovery[p.src.ID] = l
	}
	return err
}

// enumerateReconcile drains every reconcile enumeration: pages and blog
// posts, attachments, then comments.
func enumerateReconcile(ctx context.Context, p pass) (reconcileListing, error) {
	pages, err := enumerateAll(ctx, p.f, p.c, KindPage)
	if err != nil {
		return reconcileListing{}, err
	}
	attachments, err := enumerateAll(ctx, p.f, p.c, KindAttachment)
	if err != nil {
		return reconcileListing{}, err
	}
	comments, err := enumerateAll(ctx, p.f, p.c, KindComment)
	if err != nil {
		return reconcileListing{}, err
	}
	return reconcileListing{pages: pages, attachments: attachments, comments: comments}, nil
}

// reconcileDocs deletes the documents absent from the listing, except the
// attachments in keepAttachments, and relinks them, returning how many
// were deleted.
func (e *Engine) reconcileDocs(ctx context.Context, q Queryer, src db.ExtSource, l reconcileListing, keepAttachments map[string]bool) (int, error) {
	deleted := 0
	for _, set := range []struct {
		local  []ItemKind
		remote map[string]ItemRef
		keep   map[string]bool
	}{{[]ItemKind{KindPage, KindBlogpost}, l.pages, nil}, {[]ItemKind{KindAttachment}, l.attachments, keepAttachments}} {
		gone, err := deleteAbsent(ctx, q, src.ID, set.local, set.remote, set.keep)
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

// reconcileComments deletes the stored comments absent from remote, except
// those in keep. A comment deletion does not bump its page's version, and
// the comments stream only lists what changed, so without this a deleted
// comment would stay searchable forever. Each parent that lost a comment is stamped
// children_changed_at (the KB re-renders it) and relinked.
func (e *Engine) reconcileComments(ctx context.Context, q Queryer, src db.ExtSource, remote map[string]ItemRef, keep map[string]bool) error {
	local, err := localComments(ctx, q, src.ID)
	if err != nil {
		return err
	}
	var parents []string
	seen := map[string]bool{}
	for _, c := range local {
		if _, ok := remote[c.id]; ok || keep[c.id] {
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

// storedComment is one ext_comments row's identity and version.
type storedComment struct {
	id, page string
	version  int
}

// localComments lists the stored comments of sourceID, ordered by id. The
// rows are closed before it returns (see localIDs).
func localComments(ctx context.Context, q Queryer, sourceID int64) ([]storedComment, error) {
	rows, err := q.QueryContext(ctx, `SELECT ext_id, page_ext_id, version FROM ext_comments
		WHERE source_id = ? ORDER BY ext_id`, sourceID)
	if err != nil {
		return nil, fmt.Errorf("extsync: listing local comments: %w", err)
	}
	defer rows.Close()
	var out []storedComment
	for rows.Next() {
		var c storedComment
		if err := rows.Scan(&c.id, &c.page, &c.version); err != nil {
			return nil, fmt.Errorf("extsync: scanning local comment: %w", err)
		}
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("extsync: listing local comments: %w", err)
	}
	return out, nil
}

// enumerateAll drains All(kind) into its refs by ext id.
func enumerateAll(ctx context.Context, f Fetcher, c Container, kind ItemKind) (map[string]ItemRef, error) {
	ids := map[string]ItemRef{}
	page := ""
	for {
		refs, next, err := f.All(ctx, c, kind, page)
		if err != nil {
			return nil, fmt.Errorf("extsync: enumerating %s: %w", kind, err)
		}
		for _, r := range refs {
			ids[r.ExtID] = r
		}
		if next == "" {
			return ids, nil
		}
		page = next
	}
}

// deleteAbsent deletes the local documents of kinds whose ext id is in
// neither remote nor keep, returning their ids.
func deleteAbsent(ctx context.Context, q Queryer, sourceID int64, kinds []ItemKind, remote map[string]ItemRef, keep map[string]bool) ([]string, error) {
	local, err := localIDs(ctx, q, sourceID, kinds)
	if err != nil {
		return nil, err
	}
	var gone []string
	for _, id := range local {
		if _, ok := remote[id]; ok || keep[id] {
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
