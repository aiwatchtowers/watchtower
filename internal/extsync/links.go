package extsync

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// RelinkFunc records the cross-source links of one stored document from its
// text, replacing whatever it recorded for ref before; called with no texts
// it drops them (the document is gone). It runs inside the engine's batch
// transaction. cmd wires internal/doclinks.LinkConfluenceDoc; the engine
// itself stays free of any link or Atlassian-specific package.
type RelinkFunc func(ctx context.Context, q Queryer, ref string, texts ...string) error

// relinkBatchSize is how many stored documents one backfill transaction
// relinks between budget checks (a variable so tests can shrink it).
var relinkBatchSize = 200

// relinkStateKey names the ext_link_state row of the one-shot relink
// backfill: "" or absent = not started, "<source_id>|<ext_id>" = resumes
// after that document, relinkDone = finished.
const (
	relinkStateKey = "ext_relink"
	relinkDone     = "done"
)

// docRef is the knowledge-index ref of a stored document
// ("<provider>:<source_id>:<ext_id>", internal/kb/source_ext.go).
func docRef(provider string, sourceID int64, extID string) string {
	return provider + ":" + strconv.FormatInt(sourceID, 10) + ":" + extID
}

// relinkDocs re-records the links of each document in ids from what is
// stored for it now — title, sections and, for a page, its comments (a
// comment belongs to its page's knowledge document) — so a page edit, a
// comment-only change, a deletion and a degraded attachment all end with
// links that match the stored text. A no-op without Options.Relink.
func (e *Engine) relinkDocs(ctx context.Context, q Queryer, provider string, sourceID int64, ids []string) error {
	if e.opts.Relink == nil {
		return nil
	}
	for _, id := range ids {
		texts, err := storedTexts(ctx, q, sourceID, id)
		if err != nil {
			return err
		}
		if err := e.opts.Relink(ctx, q, docRef(provider, sourceID, id), texts...); err != nil {
			return fmt.Errorf("extsync: linking %s: %w", id, err)
		}
	}
	return nil
}

// storedTexts returns the stored searchable text of one document: its
// title, section headings and texts, and comment bodies/anchors (nil when
// the document is not stored).
func storedTexts(ctx context.Context, q Queryer, sourceID int64, extID string) ([]string, error) {
	var title, sectionsJSON string
	err := q.QueryRowContext(ctx, `SELECT title, sections_json FROM ext_documents WHERE source_id = ? AND ext_id = ?`,
		sourceID, extID).Scan(&title, &sectionsJSON)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("extsync: reading %s for links: %w", extID, err)
	}
	texts := []string{title}
	var sections []Section
	// upsertDocument writes sections_json with json.Marshal; an unreadable
	// value (only a hand-edited row) links as no sections rather than
	// failing — and so wedging — every batch that touches the document.
	_ = json.Unmarshal([]byte(sectionsJSON), &sections)
	for _, s := range sections {
		texts = append(texts, s.Heading, s.Text)
	}
	return appendCommentTexts(ctx, q, sourceID, extID, texts)
}

func appendCommentTexts(ctx context.Context, q Queryer, sourceID int64, pageID string, texts []string) ([]string, error) {
	rows, err := q.QueryContext(ctx, `SELECT body_text, anchor_text FROM ext_comments WHERE source_id = ? AND page_ext_id = ?`,
		sourceID, pageID)
	if err != nil {
		return nil, fmt.Errorf("extsync: reading comments of %s for links: %w", pageID, err)
	}
	defer rows.Close()
	for rows.Next() {
		var body, anchor string
		if err := rows.Scan(&body, &anchor); err != nil {
			return nil, fmt.Errorf("extsync: scanning comment of %s for links: %w", pageID, err)
		}
		texts = append(texts, body, anchor)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("extsync: reading comments of %s for links: %w", pageID, err)
	}
	return texts, nil
}

// refIDs returns the ext ids of refs.
func refIDs(refs []ItemRef) []string {
	out := make([]string, len(refs))
	for i, r := range refs {
		out[i] = r.ExtID
	}
	return out
}

// relinkBackfill relinks, once, every document stored before the engine
// was given a Relink (rows synced by an earlier version never went through
// relinkDocs). It walks ext_documents in primary-key order in
// relinkBatchSize transactions, each saving its resume point, until done —
// then relinkDone is stored and every later Run skips it with one read.
// The budget is checked before every batch; a started batch commits.
func (e *Engine) relinkBackfill(ctx context.Context, b *budget) error {
	if e.opts.Relink == nil {
		return nil
	}
	for {
		if b.over() {
			return nil
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		done, err := e.relinkBatch(ctx)
		if err != nil || done {
			return err
		}
	}
}

// storedDoc is one ext_documents row of the backfill walk.
type storedDoc struct {
	provider string
	sourceID int64
	extID    string
}

// relinkBatch relinks the next relinkBatchSize stored documents and saves
// the resume point in the same transaction; done reports the walk is over.
func (e *Engine) relinkBatch(ctx context.Context) (bool, error) {
	done := false
	err := e.withTx(ctx, func(q Queryer) error {
		state, err := loadRelinkState(ctx, q)
		if err != nil || state == relinkDone {
			done = true
			return err
		}
		docs, err := nextStoredDocs(ctx, q, state)
		if err != nil {
			return err
		}
		next := relinkDone
		if len(docs) == relinkBatchSize {
			last := docs[len(docs)-1]
			next = strconv.FormatInt(last.sourceID, 10) + "|" + last.extID
		}
		for _, d := range docs {
			if err := e.relinkDocs(ctx, q, d.provider, d.sourceID, []string{d.extID}); err != nil {
				return err
			}
		}
		done = next == relinkDone
		return saveRelinkState(ctx, q, next)
	})
	return done, err
}

func loadRelinkState(ctx context.Context, q Queryer) (string, error) {
	var s string
	err := q.QueryRowContext(ctx, `SELECT cursor FROM ext_link_state WHERE from_kind = ?`, relinkStateKey).Scan(&s)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("extsync: reading relink state: %w", err)
	}
	return s, nil
}

func saveRelinkState(ctx context.Context, q Queryer, s string) error {
	if _, err := q.ExecContext(ctx, `INSERT INTO ext_link_state (from_kind, cursor) VALUES (?, ?)
		ON CONFLICT(from_kind) DO UPDATE SET cursor = excluded.cursor`, relinkStateKey, s); err != nil {
		return fmt.Errorf("extsync: saving relink state: %w", err)
	}
	return nil
}

// relinkWalkQuery pages ext_documents by its primary key
// (TestLinks_BackfillQueryPlan).
const relinkWalkQuery = `SELECT s.provider, d.source_id, d.ext_id
	FROM ext_documents d JOIN ext_sources s ON s.id = d.source_id
	WHERE (d.source_id, d.ext_id) > (?, ?)
	ORDER BY d.source_id, d.ext_id LIMIT ?`

// nextStoredDocs lists the documents after the resume point state
// ("<source_id>|<ext_id>", "" = from the start) in primary-key order. The
// rows are closed before the caller writes (single connection).
func nextStoredDocs(ctx context.Context, q Queryer, state string) ([]storedDoc, error) {
	sourceStr, afterID, _ := strings.Cut(state, "|")
	afterSource, _ := strconv.ParseInt(sourceStr, 10, 64) // "" = 0, the start
	rows, err := q.QueryContext(ctx, relinkWalkQuery, afterSource, afterID, relinkBatchSize)
	if err != nil {
		return nil, fmt.Errorf("extsync: listing documents to relink: %w", err)
	}
	defer rows.Close()
	var out []storedDoc
	for rows.Next() {
		var d storedDoc
		if err := rows.Scan(&d.provider, &d.sourceID, &d.extID); err != nil {
			return nil, fmt.Errorf("extsync: scanning document to relink: %w", err)
		}
		out = append(out, d)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("extsync: listing documents to relink: %w", err)
	}
	return out, nil
}
