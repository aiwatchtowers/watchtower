package extsync

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"

	"watchtower/internal/doclinks"
)

// docRef is the knowledge-index ref of a stored document
// ("<provider>:<source_id>:<ext_id>", internal/kb/source_ext.go). Confluence
// is the only provider (the ext_sources CHECK).
func docRef(sourceID int64, extID string) string {
	return "confluence:" + strconv.FormatInt(sourceID, 10) + ":" + extID
}

// relinkDocs recomputes the Jira-key doc_links of each document in ids from
// what is stored for it now — title, sections and, for a page, its comments
// (a comment belongs to its page's knowledge document) — so a page edit, a
// comment-only change and a degraded attachment all end with links that
// match the stored text. It runs inside the batch transaction that wrote
// the rows; a document no longer stored ends with no links.
func relinkDocs(ctx context.Context, q Queryer, sourceID int64, ids []string) error {
	for _, id := range ids {
		texts, err := storedTexts(ctx, q, sourceID, id)
		if err != nil {
			return err
		}
		if err := doclinks.LinkConfluenceDoc(ctx, q, docRef(sourceID, id), texts...); err != nil {
			return fmt.Errorf("extsync: %w", err)
		}
	}
	return nil
}

// unlinkDoc drops every Jira-key link of a deleted document.
func unlinkDoc(ctx context.Context, q Queryer, sourceID int64, extID string) error {
	if err := doclinks.LinkConfluenceDoc(ctx, q, docRef(sourceID, extID)); err != nil {
		return fmt.Errorf("extsync: %w", err)
	}
	return nil
}

// storedTexts returns the stored searchable text of one document: its
// title, section texts and comment bodies/anchors (nil when absent).
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

// writtenIDs returns the ids of the non-nil items.
func writtenIDs(items []*Item) []string {
	var out []string
	for _, it := range items {
		if it != nil {
			out = append(out, it.Ref.ExtID)
		}
	}
	return out
}
