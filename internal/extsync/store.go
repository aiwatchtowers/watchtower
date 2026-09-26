package extsync

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// Queryer is the read/write surface shared by *db.DB and *sql.Tx (the
// internal/kb precedent).
type Queryer interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

// isoLayout is the timestamp format of every ext_* time column.
const isoLayout = time.RFC3339

// streamName names one delta stream; each owns a cursor and token column
// pair on ext_sources.
type streamName string

const streamPages streamName = "page"

// streamColumns maps a stream to its (cursor, token) columns. Column names
// never come from input, only from this table.
var streamColumns = map[streamName][2]string{
	streamPages: {"page_cursor", "page_token"},
}

func formatTime(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(isoLayout)
}

// localVersions returns ext_id → version for the ids already stored under
// sourceID, in one query.
func localVersions(ctx context.Context, q Queryer, sourceID int64, ids []string) (map[string]int, error) {
	out := make(map[string]int, len(ids))
	if len(ids) == 0 {
		return out, nil
	}
	args := make([]any, 0, len(ids)+1)
	args = append(args, sourceID)
	for _, id := range ids {
		args = append(args, id)
	}
	placeholders := strings.TrimSuffix(strings.Repeat("?,", len(ids)), ",")
	rows, err := q.QueryContext(ctx, `SELECT ext_id, version FROM ext_documents
		WHERE source_id = ? AND ext_id IN (`+placeholders+`)`, args...)
	if err != nil {
		return nil, fmt.Errorf("extsync: reading local versions: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var id string
		var v int
		if err := rows.Scan(&id, &v); err != nil {
			return nil, fmt.Errorf("extsync: scanning local version: %w", err)
		}
		out[id] = v
	}
	return out, rows.Err()
}

// upsertDocument writes it into ext_documents. Extraction state
// (extract_status/attempts) and children_changed_at are left to their own
// writers.
func upsertDocument(ctx context.Context, q Queryer, sourceID int64, it *Item, now time.Time) error {
	sections := it.Sections
	if sections == nil {
		sections = []Section{}
	}
	sectionsJSON, err := json.Marshal(sections)
	if err != nil {
		return fmt.Errorf("extsync: encoding sections of %s: %w", it.Ref.ExtID, err)
	}
	meta := it.Meta
	if meta == nil {
		meta = map[string]string{}
	}
	metaJSON, err := json.Marshal(meta)
	if err != nil {
		return fmt.Errorf("extsync: encoding meta of %s: %w", it.Ref.ExtID, err)
	}
	status := it.Status
	if status == "" {
		status = "current"
	}
	_, err = q.ExecContext(ctx, `INSERT INTO ext_documents
		(source_id, ext_id, kind, parent_ext_id, title, url, version, status, author_id,
		 created_at, modified_at, sections_json, meta_json, media_type, size_bytes, synced_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(source_id, ext_id) DO UPDATE SET
		 kind = excluded.kind, parent_ext_id = excluded.parent_ext_id, title = excluded.title,
		 url = excluded.url, version = excluded.version, status = excluded.status,
		 author_id = excluded.author_id, created_at = excluded.created_at,
		 modified_at = excluded.modified_at, sections_json = excluded.sections_json,
		 meta_json = excluded.meta_json, media_type = excluded.media_type,
		 size_bytes = excluded.size_bytes, synced_at = excluded.synced_at`,
		sourceID, it.Ref.ExtID, string(it.Ref.Kind), it.Ref.ParentID, it.Title, it.URL, it.Ref.Version,
		status, it.AuthorID, formatTime(it.Created), formatTime(it.Ref.Modified),
		string(sectionsJSON), string(metaJSON), it.MediaType, it.Size, formatTime(now))
	if err != nil {
		return fmt.Errorf("extsync: upserting %s: %w", it.Ref.ExtID, err)
	}
	return nil
}

// deleteDocument removes one document (a no-op when absent).
func deleteDocument(ctx context.Context, q Queryer, sourceID int64, extID string) error {
	if _, err := q.ExecContext(ctx, `DELETE FROM ext_documents WHERE source_id = ? AND ext_id = ?`,
		sourceID, extID); err != nil {
		return fmt.Errorf("extsync: deleting %s: %w", extID, err)
	}
	return nil
}

// saveStream persists a stream's cursor and in-flight token.
func saveStream(ctx context.Context, q Queryer, sourceID int64, stream streamName, cursor, token string) error {
	cols, ok := streamColumns[stream]
	if !ok {
		return fmt.Errorf("extsync: unknown stream %q", stream)
	}
	if _, err := q.ExecContext(ctx, `UPDATE ext_sources SET `+cols[0]+` = ?, `+cols[1]+` = ? WHERE id = ?`,
		cursor, token, sourceID); err != nil {
		return fmt.Errorf("extsync: saving %s stream state: %w", stream, err)
	}
	return nil
}

// markBackfillDone records that a pass from an empty cursor completed.
func markBackfillDone(ctx context.Context, q Queryer, sourceID int64) error {
	if _, err := q.ExecContext(ctx, `UPDATE ext_sources SET backfill_done = 1 WHERE id = ? AND backfill_done = 0`,
		sourceID); err != nil {
		return fmt.Errorf("extsync: marking backfill done: %w", err)
	}
	return nil
}
