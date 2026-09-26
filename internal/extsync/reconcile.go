package extsync

import (
	"context"
	"fmt"
	"strings"
	"time"
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

// reconcile deletes the local documents (and their comments) the provider
// no longer enumerates — trashed, moved to another container, or no longer
// visible to the account, which is the whole permission model — and stamps
// last_reconcile_at. Every enumeration completes before anything is
// deleted, so a failed listing deletes nothing.
func (e *Engine) reconcile(ctx context.Context, p pass) error {
	remote := make([]map[string]bool, len(reconcileSets))
	for i, rs := range reconcileSets {
		ids, err := enumerateAll(ctx, p.f, p.c, rs.kind)
		if err != nil {
			return err
		}
		remote[i] = ids
	}
	deleted := 0
	err := e.withTx(ctx, func(q Queryer) error {
		for i, rs := range reconcileSets {
			n, err := deleteAbsent(ctx, q, p.src.ID, rs.local, remote[i])
			if err != nil {
				return err
			}
			deleted += n
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
// remote, returning how many went.
func deleteAbsent(ctx context.Context, q Queryer, sourceID int64, kinds []ItemKind, remote map[string]bool) (int, error) {
	local, err := localIDs(ctx, q, sourceID, kinds)
	if err != nil {
		return 0, err
	}
	n := 0
	for _, id := range local {
		if remote[id] {
			continue
		}
		if err := deleteDocument(ctx, q, sourceID, id); err != nil {
			return 0, err
		}
		n++
	}
	return n, nil
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
