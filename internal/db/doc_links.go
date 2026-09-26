package db

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// DocLink is one cross-source mention (doc_links, migration 00074): the
// document FromKind/FromRef (a knowledge-index ref) mentions ToRef — a Jira
// key ("jira_issue") or a Confluence page "<cloud_id>:<page_id>"
// ("confluence_page"). Written by internal/doclinks.
type DocLink struct{ FromKind, FromRef, ToKind, ToRef, DetectedAt string }

// docLinksToQuery seeks idx_doc_links_to; pinned by
// TestDocLinks_QueryPlansUseIndexes.
const docLinksToQuery = `SELECT from_kind, from_ref, to_kind, to_ref, detected_at FROM doc_links
	WHERE to_kind = ? AND to_ref = ? ORDER BY detected_at DESC, from_kind, from_ref LIMIT ?`

// docLinksFromQuery seeks the primary key's (from_kind, from_ref) prefix.
const docLinksFromQuery = `SELECT from_kind, from_ref, to_kind, to_ref, detected_at FROM doc_links
	WHERE from_kind = ? AND from_ref = ? ORDER BY to_kind, to_ref`

// DocLinksTo returns up to limit documents mentioning (toKind, toRef),
// newest detection first.
func (db *DB) DocLinksTo(toKind, toRef string, limit int) ([]DocLink, error) {
	return db.queryDocLinks(docLinksToQuery, toKind, toRef, limit)
}

// DocLinksFrom returns everything the document (fromKind, fromRef) mentions.
func (db *DB) DocLinksFrom(fromKind, fromRef string) ([]DocLink, error) {
	return db.queryDocLinks(docLinksFromQuery, fromKind, fromRef)
}

func (db *DB) queryDocLinks(query string, args ...any) ([]DocLink, error) {
	rows, err := db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("querying doc links: %w", err)
	}
	defer rows.Close()
	var out []DocLink
	for rows.Next() {
		var l DocLink
		if err := rows.Scan(&l.FromKind, &l.FromRef, &l.ToKind, &l.ToRef, &l.DetectedAt); err != nil {
			return nil, fmt.Errorf("scanning doc link: %w", err)
		}
		out = append(out, l)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("querying doc links: %w", err)
	}
	return out, nil
}

// ExtDocBrief is the stored summary of one ext_documents row: enough to name
// and excerpt it without the knowledge index.
type ExtDocBrief struct {
	Title, URL, Space string
	Text              string // section texts joined by newlines
}

// ExtDocumentBrief returns sourceID/extID's summary, nil when absent.
func (db *DB) ExtDocumentBrief(sourceID int64, extID string) (*ExtDocBrief, error) {
	var b ExtDocBrief
	var sectionsJSON string
	err := db.QueryRow(`SELECT d.title, d.url, s.container_key, d.sections_json
		FROM ext_documents d JOIN ext_sources s ON s.id = d.source_id
		WHERE d.source_id = ? AND d.ext_id = ?`, sourceID, extID).Scan(&b.Title, &b.URL, &b.Space, &sectionsJSON)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("loading ext document %d/%s: %w", sourceID, extID, err)
	}
	var sections []struct {
		Text string `json:"text"`
	}
	// extsync writes sections_json with json.Marshal; an unreadable value
	// (a hand-edited row) degrades to no text rather than failing the caller.
	_ = json.Unmarshal([]byte(sectionsJSON), &sections)
	texts := make([]string, 0, len(sections))
	for _, s := range sections {
		if s.Text != "" {
			texts = append(texts, s.Text)
		}
	}
	b.Text = strings.Join(texts, "\n")
	return &b, nil
}
