package extsync

import (
	"cmp"
	"context"
	"fmt"
	"slices"
	"time"
)

// reconcileVerifyCap bounds how many absent children (attachments, or the
// parents whose comment sets are checked) one reconcile verifies one by
// one when a child listing looks degraded (a variable so tests can shrink
// it).
var reconcileVerifyCap = 50

// storedChild is one stored attachment or comment and its parent.
type storedChild struct{ id, parent string }

// keptChildren holds the absent children the reconcile must not delete,
// by ext id.
type keptChildren struct{ attachments, comments map[string]bool }

// guardChildren decides which stored attachments and comments absent from
// their listing the reconcile keeps. A provider may list children from an
// eventually-consistent search index (Confluence: CQL, addressed by space
// key) rather than from its database, so a lagging index or a stale
// container key can drop most of them from one listing while their pages
// stay listed. A child whose parent is not listed either is an orphan and
// always goes with its parent's deletion; for the rest, when the listing
// came back empty or lacks more than half of them, the absence is not
// trusted: up to reconcileVerifyCap of them are checked one by one (an
// attachment by Fetch, a comment by its parent's Comments), only those
// confirmed gone are deleted, and the rest — present, or not checked this
// time — are kept for a later reconcile. The verified sample rotates by
// day, so a large legitimate deletion still drains.
func (e *Engine) guardChildren(ctx context.Context, p pass, l reconcileListing) (keptChildren, error) {
	attachments, err := localAttachments(ctx, e.db, p.src.ID)
	if err != nil {
		return keptChildren{}, err
	}
	keepA, err := e.guardKind(ctx, p, KindAttachment, attachments, l.attachments, l.pages, func(c storedChild) (bool, error) {
		it, err := p.f.Fetch(ctx, p.c, ItemRef{Kind: KindAttachment, ExtID: c.id, ParentID: c.parent})
		if err != nil {
			return false, fmt.Errorf("extsync: verifying attachment %s: %w", c.id, err)
		}
		return it == nil, nil
	})
	if err != nil {
		return keptChildren{}, err
	}
	comments, err := localComments(ctx, e.db, p.src.ID)
	if err != nil {
		return keptChildren{}, err
	}
	stored := make([]storedChild, len(comments))
	for i, c := range comments {
		stored[i] = storedChild{id: c.id, parent: c.page}
	}
	keepC, err := e.guardComments(ctx, p, stored, l)
	if err != nil {
		return keptChildren{}, err
	}
	return keptChildren{attachments: keepA, comments: keepC}, nil
}

// guardComments is guardKind for comments, verified a parent at a time:
// one Comments call confirms or refutes every absent comment of a parent.
func (e *Engine) guardComments(ctx context.Context, p pass, stored []storedChild, l reconcileListing) (map[string]bool, error) {
	cands, suspect := absentChildren(stored, l.comments, l.pages)
	if !suspect {
		return nil, nil
	}
	byParent := map[string][]string{}
	for _, c := range cands {
		byParent[c.parent] = append(byParent[c.parent], c.id)
	}
	parents := make([]string, 0, len(byParent))
	for parent := range byParent {
		parents = append(parents, parent)
	}
	slices.Sort(parents)
	gone := map[string]bool{}
	for _, parent := range verifySample(parents, e.opts.Now()) {
		set, err := p.f.Comments(ctx, p.c, parent)
		if err != nil {
			return nil, fmt.Errorf("extsync: verifying the comments of %s: %w", parent, err)
		}
		present := map[string]bool{}
		for i := range set {
			present[set[i].Ref.ExtID] = true
		}
		for _, id := range byParent[parent] {
			if !present[id] {
				gone[id] = true
			}
		}
	}
	return e.keepUnconfirmed(p, KindComment, cands, len(stored), gone), nil
}

// guardKind returns the absent stored children of one kind to keep (nil =
// the listing is trusted), checking a sample of them with gone.
func (e *Engine) guardKind(ctx context.Context, p pass, kind ItemKind, stored []storedChild, listed, parents map[string]ItemRef,
	gone func(storedChild) (bool, error)) (map[string]bool, error) {
	cands, suspect := absentChildren(stored, listed, parents)
	if !suspect {
		return nil, nil
	}
	confirmed := map[string]bool{}
	for _, c := range verifySample(cands, e.opts.Now()) {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		ok, err := gone(c)
		if err != nil {
			return nil, err
		}
		if ok {
			confirmed[c.id] = true
		}
	}
	return e.keepUnconfirmed(p, kind, cands, len(stored), confirmed), nil
}

// keepUnconfirmed returns the candidates not confirmed gone, and logs the
// guard's decision.
func (e *Engine) keepUnconfirmed(p pass, kind ItemKind, cands []storedChild, stored int, gone map[string]bool) map[string]bool {
	keep := map[string]bool{}
	for _, c := range cands {
		if !gone[c.id] {
			keep[c.id] = true
		}
	}
	e.opts.Logger.Printf("source %d: the %s listing lacks %d of %d stored under listed parents; not trusted — deleting the %d confirmed gone, keeping %d",
		p.src.ID, kind, len(cands), stored, len(gone), len(keep))
	return keep
}

// absentChildren returns, sorted by id, the stored children absent from
// listed whose parent is listed (orphans are not candidates: they go with
// their parent), and whether the listing is suspect: it came back empty, or
// it lacks more than half of the stored children under listed parents.
func absentChildren(stored []storedChild, listed, parents map[string]ItemRef) ([]storedChild, bool) {
	var cands []storedChild
	underListed := 0
	for _, c := range stored {
		if _, ok := parents[c.parent]; !ok {
			continue
		}
		underListed++
		if _, ok := listed[c.id]; !ok {
			cands = append(cands, c)
		}
	}
	if len(cands) == 0 {
		return nil, false
	}
	slices.SortFunc(cands, func(a, b storedChild) int { return cmp.Compare(a.id, b.id) })
	return cands, len(listed) == 0 || 2*len(cands) > underListed
}

// verifySample returns up to reconcileVerifyCap of sorted, starting at an
// offset that moves by the cap every UTC day and wrapping, so successive
// reconciles check different ones.
func verifySample[T any](sorted []T, now time.Time) []T {
	n := len(sorted)
	if n <= reconcileVerifyCap {
		return sorted
	}
	day := int(now.UTC().Unix() / 86400)
	start := (day % n) * reconcileVerifyCap % n
	out := make([]T, 0, reconcileVerifyCap)
	for i := range reconcileVerifyCap {
		out = append(out, sorted[(start+i)%n])
	}
	return out
}

// localAttachments lists the stored attachments of sourceID with their
// parents. The rows are closed before it returns (see localIDs).
func localAttachments(ctx context.Context, q Queryer, sourceID int64) ([]storedChild, error) {
	rows, err := q.QueryContext(ctx, `SELECT ext_id, parent_ext_id FROM ext_documents
		WHERE source_id = ? AND kind = ?`, sourceID, string(KindAttachment))
	if err != nil {
		return nil, fmt.Errorf("extsync: listing local attachments: %w", err)
	}
	defer rows.Close()
	var out []storedChild
	for rows.Next() {
		var c storedChild
		if err := rows.Scan(&c.id, &c.parent); err != nil {
			return nil, fmt.Errorf("extsync: scanning local attachment: %w", err)
		}
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("extsync: listing local attachments: %w", err)
	}
	return out, nil
}

// refreshContainer re-reads the source's container from the provider by
// its stable ext id and stores a changed key or name before the reconcile
// enumerates: a provider may let a container's key change (Confluence
// space keys can be renamed) while its listings are addressed by key. A
// container the account no longer sees keeps its stored identity — the
// page listing then decides what goes.
func (e *Engine) refreshContainer(ctx context.Context, p pass) (Container, error) {
	if p.c.ExtID == "" {
		return p.c, nil
	}
	cs, err := p.f.Containers(ctx)
	if err != nil {
		return p.c, fmt.Errorf("extsync: listing containers: %w", err)
	}
	for _, c := range cs {
		if c.ExtID != p.c.ExtID || (c.Key == p.c.Key && c.Name == p.c.Name) {
			continue
		}
		if c.Key == "" {
			return p.c, nil
		}
		if _, err := e.db.ExecContext(ctx, `UPDATE ext_sources SET container_key = ?, container_name = ? WHERE id = ?`,
			c.Key, c.Name, p.src.ID); err != nil {
			return p.c, fmt.Errorf("extsync: storing the renamed container %s: %w", c.ExtID, err)
		}
		e.opts.Logger.Printf("source %d: container %s is now %q (%s), was %q", p.src.ID, c.ExtID, c.Key, c.Name, p.c.Key)
		return c, nil
	}
	return p.c, nil
}
