package extsync

import (
	"context"
	"fmt"
	"strings"
	"time"

	"golang.org/x/sync/errgroup"
)

// commentsStream enumerates changed comments (comment_cursor/comment_token).
// A comment does not bump its page's version, so the stream reloads the
// parent's whole comment set and stamps children_changed_at for the KB to
// re-render the page — the page itself is never re-fetched here.
var commentsStream = streamSpec{name: streamComments, kind: KindComment, apply: (*Engine).processCommentBatch}

// processCommentBatch applies one comments batch: comments whose version
// differs from ext_comments mark their parent for a reload; parents not
// stored locally are skipped (the pages stream brings them, with their
// comments). It returns the new cursor.
func (e *Engine) processCommentBatch(ctx context.Context, p pass, bt batch) (string, error) {
	parents, err := changedParents(ctx, e.db, p.src.ID, bt.refs)
	if err != nil {
		return "", err
	}
	sets, err := fetchCommentSets(ctx, p.f, p.c, parents)
	if err != nil {
		return "", err
	}
	cursor, err := advanceCursor(bt.cursor, bt.refs)
	if err != nil {
		return "", err
	}
	now := e.opts.Now()
	written := 0
	err = e.withTx(ctx, func(q Queryer) error {
		for i, parent := range parents {
			if err := replaceComments(ctx, q, p.src.ID, parent, sets[i]); err != nil {
				return err
			}
			if err := stampChildrenChanged(ctx, q, p.src.ID, parent, now); err != nil {
				return err
			}
			written += len(sets[i])
		}
		return saveStream(ctx, q, p.src.ID, p.spec.name, cursor, bt.token)
	})
	if err != nil {
		return "", err
	}
	collectUsers(p.users, nil, sets)
	p.st.Comments += written
	return cursor, nil
}

// changedParents returns, in first-seen order, the distinct parents of the
// refs whose comment is new or has a new version, restricted to parents
// stored under sourceID.
func changedParents(ctx context.Context, q Queryer, sourceID int64, refs []ItemRef) ([]string, error) {
	ids := make([]string, len(refs))
	for i, r := range refs {
		ids[i] = r.ExtID
	}
	local, err := localCommentVersions(ctx, q, sourceID, ids)
	if err != nil {
		return nil, err
	}
	var candidates []string
	seen := map[string]bool{}
	for _, r := range refs {
		if v, ok := local[r.ExtID]; (ok && v == r.Version) || r.ParentID == "" || seen[r.ParentID] {
			continue
		}
		seen[r.ParentID] = true
		candidates = append(candidates, r.ParentID)
	}
	present, err := localVersions(ctx, q, sourceID, candidates)
	if err != nil {
		return nil, err
	}
	var out []string
	for _, id := range candidates {
		if _, ok := present[id]; ok {
			out = append(out, id)
		}
	}
	return out, nil
}

// fetchCommentSets loads each page's full comment set with up to
// fetchConcurrency in flight; results are in pageIDs order.
func fetchCommentSets(ctx context.Context, f Fetcher, c Container, pageIDs []string) ([][]Item, error) {
	sets := make([][]Item, len(pageIDs))
	g, gctx := errgroup.WithContext(ctx)
	g.SetLimit(fetchConcurrency)
	for i, id := range pageIDs {
		g.Go(func() error {
			set, err := f.Comments(gctx, c, id)
			if err != nil {
				return fmt.Errorf("extsync: listing comments of %s: %w", id, err)
			}
			sets[i] = set
			return nil
		})
	}
	if err := g.Wait(); err != nil {
		return nil, err
	}
	return sets, nil
}

// isCommentParent reports whether kind carries comments reloaded on every
// re-fetch.
func isCommentParent(kind ItemKind) bool {
	return kind == KindPage || kind == KindBlogpost
}

// replaceComments makes set the whole stored comment set of pageID.
func replaceComments(ctx context.Context, q Queryer, sourceID int64, pageID string, set []Item) error {
	if err := deleteComments(ctx, q, sourceID, pageID); err != nil {
		return err
	}
	for i := range set {
		if err := insertComment(ctx, q, sourceID, pageID, &set[i]); err != nil {
			return err
		}
	}
	return nil
}

// deleteComments removes every stored comment of pageID.
func deleteComments(ctx context.Context, q Queryer, sourceID int64, pageID string) error {
	if _, err := q.ExecContext(ctx, `DELETE FROM ext_comments WHERE source_id = ? AND page_ext_id = ?`,
		sourceID, pageID); err != nil {
		return fmt.Errorf("extsync: deleting comments of %s: %w", pageID, err)
	}
	return nil
}

func insertComment(ctx context.Context, q Queryer, sourceID int64, pageID string, it *Item) error {
	kind := it.CommentKind
	if kind == "" {
		kind = "footer"
	}
	texts := make([]string, 0, len(it.Sections))
	for _, s := range it.Sections {
		texts = append(texts, s.Text)
	}
	resolved := 0
	if it.Resolved {
		resolved = 1
	}
	// OR REPLACE: a comment id is unique per source; should a provider list
	// it under two pages, the later set wins rather than failing the batch.
	if _, err := q.ExecContext(ctx, `INSERT OR REPLACE INTO ext_comments
		(source_id, ext_id, page_ext_id, kind, author_id, created_at, version, body_text, anchor_text, resolved)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		sourceID, it.Ref.ExtID, pageID, kind, it.AuthorID, formatTime(it.Created), it.Ref.Version,
		strings.Join(texts, "\n\n"), it.AnchorText, resolved); err != nil {
		return fmt.Errorf("extsync: writing comment %s: %w", it.Ref.ExtID, err)
	}
	return nil
}

// stampChildrenChanged marks pageID for a KB re-render.
func stampChildrenChanged(ctx context.Context, q Queryer, sourceID int64, pageID string, now time.Time) error {
	if _, err := q.ExecContext(ctx, `UPDATE ext_documents SET children_changed_at = ? WHERE source_id = ? AND ext_id = ?`,
		formatTime(now), sourceID, pageID); err != nil {
		return fmt.Errorf("extsync: stamping %s: %w", pageID, err)
	}
	return nil
}
