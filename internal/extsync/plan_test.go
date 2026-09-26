package extsync

import (
	"context"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// explainPlanDetail runs EXPLAIN QUERY PLAN over query and returns every
// plan row's detail text joined, so a caller can assert on the index used
// (the internal/kb precedent, `explainPlanDetail` in source_mail_test.go).
func explainPlanDetail(ctx context.Context, t *testing.T, q Queryer, query string, args ...any) string {
	t.Helper()
	rows, err := q.QueryContext(ctx, "EXPLAIN QUERY PLAN "+query, args...)
	require.NoError(t, err)
	defer rows.Close()
	var lines []string
	for rows.Next() {
		var id, parent, notused int
		var detail string
		require.NoError(t, rows.Scan(&id, &parent, &notused, &detail))
		lines = append(lines, detail)
	}
	require.NoError(t, rows.Err())
	return strings.Join(lines, "\n")
}

// seedPlanFixture writes one page, one comment on it and one attachment
// under src, enough to exercise every query this file guards.
func seedPlanFixture(t *testing.T, d *db.DB, sourceID int64) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO ext_documents (source_id, ext_id, kind, title, sections_json) VALUES (?, 'p1', 'page', 'P1', '[]')`, sourceID)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO ext_comments (source_id, ext_id, page_ext_id, kind, body_text) VALUES (?, 'c1', 'p1', 'footer', 'x')`, sourceID)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO ext_documents (source_id, ext_id, kind, parent_ext_id, media_type, title, extract_status, extract_attempts)
		VALUES (?, 'a1', 'attachment', 'p1', 'image/png', 'x.png', 'ocr_pending', 1)`, sourceID)
	require.NoError(t, err)
}

// TestPlan01_LocalVersionsUsesPrimaryKey guards the version-gate lookup
// (localVersions/localCommentVersions, store.go's readVersions): a
// `source_id = ? AND ext_id IN (...)` lookup must resolve through the
// table's own (source_id, ext_id) primary key, never a scan of the whole
// table (a stream's batch can be a small fraction of a large space).
func TestPlan01_LocalVersionsUsesPrimaryKey(t *testing.T) {
	ctx := context.Background()
	d, src := newSourceDB(t)
	seedPlanFixture(t, d, src.ID)

	plan := explainPlanDetail(ctx, t, d, `SELECT ext_id, version FROM ext_documents WHERE source_id = ? AND ext_id IN (?,?)`,
		src.ID, "p1", "p2")
	assert.Contains(t, plan, "USING INDEX sqlite_autoindex_ext_documents_1 (source_id=? AND ext_id=?)",
		"localVersions must use the ext_documents primary key")
	assert.NotContains(t, plan, "SCAN ext_documents")

	planC := explainPlanDetail(ctx, t, d, `SELECT ext_id, version FROM ext_comments WHERE source_id = ? AND ext_id IN (?,?)`,
		src.ID, "c1", "c2")
	assert.Contains(t, planC, "USING INDEX sqlite_autoindex_ext_comments_1 (source_id=? AND ext_id=?)",
		"localCommentVersions must use the ext_comments primary key")
	assert.NotContains(t, planC, "SCAN ext_comments")
}

// TestPlan02_CommentsByPageUsesIndex guards every `... WHERE source_id = ?
// AND page_ext_id = ?` query (deleteComments, replaceComments' delete half,
// and links.go's evidence-text read): they must use idx_ext_comments_page,
// not a scan of every comment ever synced for the source.
func TestPlan02_CommentsByPageUsesIndex(t *testing.T) {
	ctx := context.Background()
	d, src := newSourceDB(t)
	seedPlanFixture(t, d, src.ID)

	plan := explainPlanDetail(ctx, t, d, `SELECT body_text, anchor_text FROM ext_comments WHERE source_id = ? AND page_ext_id = ?`,
		src.ID, "p1")
	assert.Contains(t, plan, "INDEX idx_ext_comments_page (source_id=? AND page_ext_id=?)")
	assert.NotContains(t, plan, "SCAN ext_comments")

	planDel := explainPlanDetail(ctx, t, d, `DELETE FROM ext_comments WHERE source_id = ? AND page_ext_id = ?`,
		src.ID, "p1")
	assert.Contains(t, planDel, "INDEX idx_ext_comments_page (source_id=? AND page_ext_id=?)")
	assert.NotContains(t, planDel, "SCAN ext_comments")
}

// TestPlan03_RevisitAttachmentsUsesPrimaryKey guards revisitRefs' listing of
// degraded attachment rows: the `source_id = ? AND kind = 'attachment' AND
// (...)` predicate must resolve source_id through the (source_id, ext_id)
// primary key (there is no dedicated index on kind/extract_status; the
// per-source PK range is the intended plan), and its ORDER BY ext_id must
// ride that same index's column order rather than a temp sort — the whole
// point of scoping every OCR-retry pass to one source.
func TestPlan03_RevisitAttachmentsUsesPrimaryKey(t *testing.T) {
	ctx := context.Background()
	d, src := newSourceDB(t)
	seedPlanFixture(t, d, src.ID)

	plan := explainPlanDetail(ctx, t, d, `SELECT ext_id, version, modified_at, parent_ext_id, media_type, title, extract_status
			FROM ext_documents WHERE source_id = ? AND kind = 'attachment'
			  AND (extract_status = ?
			    OR (extract_status IN (?, ?) AND extract_attempts > 0 AND extract_attempts < ?)
			    OR (extract_status = ? AND ? AND extract_attempts < ?))
			ORDER BY ext_id`,
		src.ID, extractSkippedType, extractFailed, extractOCRPending, maxExtractAttempts,
		extractOCRMissing, true, maxExtractAttempts)
	assert.Contains(t, plan, "USING INDEX sqlite_autoindex_ext_documents_1 (source_id=?)")
	assert.NotContains(t, plan, "SCAN ext_documents")
	assert.NotContains(t, plan, "TEMP B-TREE", "ext_id order should ride the primary key, not a separate sort")
}
