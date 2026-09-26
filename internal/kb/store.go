package kb

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

// Queryer is the read/write surface shared by *db.DB and *sql.Tx.
type Queryer interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

const isoLayout = "2006-01-02T15:04:05Z"

// writeDoc writes one rendered document behind the content-hash gate.
// It normalizes d's Title/Meta/Sections text in place before hashing/storing
// it — callers should not reuse d's text fields afterward without expecting
// the normalized form. A document whose sections are all blank but whose
// title is not (a summary-only issue, a transcript with no text) is indexed
// as one section holding the title: only a nil Build means "gone". A
// document with neither is deleted.
func writeDoc(ctx context.Context, q Queryer, d *Doc) (bool, error) {
	d.Title, d.Meta = Normalize(d.Title), Normalize(d.Meta)
	for i := range d.Sections {
		d.Sections[i].Text = Normalize(d.Sections[i].Text)
	}
	chunks := BuildChunks(d.Sections)
	if len(chunks) == 0 {
		chunks = BuildChunks([]Section{{Text: d.Title}})
	}
	if len(chunks) == 0 {
		_, err := deleteDoc(ctx, q, d.ID)
		return false, err
	}
	hash := contentHash(d, chunks)
	var old string
	err := q.QueryRowContext(ctx, `SELECT content_hash FROM kb_documents WHERE id = ?`, d.ID).Scan(&old)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return false, fmt.Errorf("kb: reading hash of %s: %w", d.ID, err)
	}
	if old == hash {
		return false, nil
	}
	if _, err := deleteDoc(ctx, q, d.ID); err != nil {
		return false, err
	}
	docAnchor := d.Anchor
	if docAnchor == nil {
		docAnchor = map[string]string{}
	}
	anchor, err := json.Marshal(docAnchor)
	if err != nil {
		return false, err
	}
	docTime, docUnix := "", 0.0
	if !d.Time.IsZero() {
		docTime = d.Time.UTC().Format(isoLayout)
		docUnix = float64(d.Time.Unix())
	}
	if _, err := q.ExecContext(ctx, `INSERT INTO kb_documents
		(id, source, title, doc_time, doc_time_unix, link, anchor_json, meta, content_hash, chunk_count)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		d.ID, d.Source, d.Title, docTime, docUnix, d.Link, string(anchor), d.Meta, hash, len(chunks)); err != nil {
		return false, fmt.Errorf("kb: inserting %s: %w", d.ID, err)
	}
	for _, c := range chunks {
		if _, err := q.ExecContext(ctx, `INSERT INTO kb_chunks (doc_id, idx, title, body, meta, anchor)
			VALUES (?, ?, ?, ?, ?, ?)`, d.ID, c.Idx, d.Title, c.Body, d.Meta, c.Anchor); err != nil {
			return false, fmt.Errorf("kb: inserting chunk %d of %s: %w", c.Idx, d.ID, err)
		}
	}
	return true, nil
}

// deleteDoc removes a document and its chunks (chunks first: the FTS delete
// trigger fires per chunk row, no reliance on cascade).
func deleteDoc(ctx context.Context, q Queryer, id string) (bool, error) {
	if _, err := q.ExecContext(ctx, `DELETE FROM kb_chunks WHERE doc_id = ?`, id); err != nil {
		return false, fmt.Errorf("kb: deleting chunks of %s: %w", id, err)
	}
	res, err := q.ExecContext(ctx, `DELETE FROM kb_documents WHERE id = ?`, id)
	if err != nil {
		return false, fmt.Errorf("kb: deleting %s: %w", id, err)
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

func docIDs(ctx context.Context, q Queryer, source string) (map[string]bool, error) {
	ids, err := queryStrings(ctx, q, `SELECT id FROM kb_documents WHERE source = ?`, source)
	if err != nil {
		return nil, err
	}
	out := make(map[string]bool, len(ids))
	for _, id := range ids {
		out[id] = true
	}
	return out, nil
}

// docIDsWithPrefix lists indexed ids starting with prefix via a PK range scan
// ([prefix, upper bound)): SQLite's BINARY collation compares UTF-8 bytes,
// the same order Go's string comparison uses.
func docIDsWithPrefix(ctx context.Context, q Queryer, prefix string) ([]string, error) {
	if upper, ok := prefixUpperBound(prefix); ok {
		return queryStrings(ctx, q, `SELECT id FROM kb_documents WHERE id >= ? AND id < ? ORDER BY id`, prefix, upper)
	}
	return queryStrings(ctx, q, `SELECT id FROM kb_documents WHERE id >= ? ORDER BY id`, prefix)
}

// prefixUpperBound returns the smallest string greater than every string
// starting with prefix, byte-wise: the prefix with its last byte incremented,
// dropping trailing 0xFF bytes. Incrementing the last byte of a multibyte
// rune may produce invalid UTF-8; that is fine for a byte-wise bound. ok is
// false when no bound exists (empty or all-0xFF prefix).
func prefixUpperBound(prefix string) (string, bool) {
	b := []byte(prefix)
	for i := len(b) - 1; i >= 0; i-- {
		if b[i] < 0xFF {
			b[i]++
			return string(b[:i+1]), true
		}
	}
	return "", false
}

// queryStrings runs a one-column query and returns every row (rows closed
// before returning — the single-connection rule).
func queryStrings(ctx context.Context, q Queryer, query string, args ...any) ([]string, error) {
	rows, err := q.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

type sourceState struct {
	Cursor           string
	LastReconciledAt string
	UpdatedAt        string
}

func loadState(ctx context.Context, q Queryer, source string) (sourceState, error) {
	var st sourceState
	err := q.QueryRowContext(ctx, `SELECT cursor, last_reconciled_at, updated_at FROM kb_sources WHERE source = ?`, source).
		Scan(&st.Cursor, &st.LastReconciledAt, &st.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return sourceState{}, nil
	}
	return st, err
}

func saveCursor(ctx context.Context, q Queryer, source, cursor string, now time.Time) error {
	_, err := q.ExecContext(ctx, `INSERT INTO kb_sources (source, cursor, updated_at) VALUES (?, ?, ?)
		ON CONFLICT(source) DO UPDATE SET cursor = excluded.cursor, updated_at = excluded.updated_at`,
		source, cursor, now.UTC().Format(isoLayout))
	return err
}

func saveReconciled(ctx context.Context, q Queryer, source string, now time.Time) error {
	ts := now.UTC().Format(isoLayout)
	_, err := q.ExecContext(ctx, `INSERT INTO kb_sources (source, last_reconciled_at, updated_at) VALUES (?, ?, ?)
		ON CONFLICT(source) DO UPDATE SET last_reconciled_at = excluded.last_reconciled_at, updated_at = excluded.updated_at`,
		source, ts, ts)
	return err
}
