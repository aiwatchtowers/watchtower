package db

import (
	"fmt"
	"strings"
)

// SearchOpts provides filtering options for full-text search.
type SearchOpts struct {
	ChannelIDs []string
	UserIDs    []string
	FromUnix   float64
	ToUnix     float64
	Limit      int
}

// SearchMessages performs a full-text search on messages using FTS5.
// The query string is passed to FTS5 MATCH. Results can be filtered by
// channel, user, and time range. Returns messages joined with the messages
// table for full data.
func (db *DB) SearchMessages(query string, opts SearchOpts) ([]Message, error) {
	if query == "" {
		return nil, nil
	}

	sqlQuery := `
		SELECT m.channel_id, m.ts, m.user_id, m.text, m.thread_ts, m.reply_count,
			m.is_edited, m.is_deleted, m.subtype, m.permalink, m.ts_unix, m.raw_json
		FROM messages_fts fts
		JOIN messages m ON m.channel_id = fts.channel_id AND m.ts = fts.ts`

	var conditions []string
	var args []any

	// Sanitize FTS5 query: strip operators and special characters
	sanitizedQuery := sanitizeFTS5Query(query)
	if sanitizedQuery == "" {
		return nil, nil
	}
	conditions = append(conditions, "messages_fts MATCH ?")
	args = append(args, sanitizedQuery)

	if len(opts.ChannelIDs) > 0 {
		placeholders := make([]string, len(opts.ChannelIDs))
		for i, id := range opts.ChannelIDs {
			placeholders[i] = "?"
			args = append(args, id)
		}
		conditions = append(conditions, "m.channel_id IN ("+strings.Join(placeholders, ",")+")")
	}

	if len(opts.UserIDs) > 0 {
		placeholders := make([]string, len(opts.UserIDs))
		for i, id := range opts.UserIDs {
			placeholders[i] = "?"
			args = append(args, id)
		}
		conditions = append(conditions, "m.user_id IN ("+strings.Join(placeholders, ",")+")")
	}

	if opts.FromUnix > 0 {
		conditions = append(conditions, "m.ts_unix >= ?")
		args = append(args, opts.FromUnix)
	}

	if opts.ToUnix > 0 {
		conditions = append(conditions, "m.ts_unix <= ?")
		args = append(args, opts.ToUnix)
	}

	sqlQuery += " WHERE " + strings.Join(conditions, " AND ")
	sqlQuery += " ORDER BY m.ts_unix DESC"

	limit := opts.Limit
	if limit <= 0 {
		limit = 50
	}
	sqlQuery += " LIMIT ?"
	args = append(args, limit)

	rows, err := db.Query(sqlQuery, args...)
	if err != nil {
		return nil, fmt.Errorf("searching messages: %w", err)
	}
	defer rows.Close()

	return scanMessages(rows)
}

// ListRecentMessages returns messages filtered by channel, user, and time
// range without a full-text query — the "everything from this person" lookup
// that SearchMessages (which requires a MATCH term) cannot serve. Results are
// newest-first and bounded by Limit. An unfiltered call (no channels, users, or
// time bound) returns nothing rather than the whole table, so callers must
// narrow with at least one filter.
func (db *DB) ListRecentMessages(opts SearchOpts) ([]Message, error) {
	var conditions []string
	var args []any

	if len(opts.ChannelIDs) > 0 {
		placeholders := make([]string, len(opts.ChannelIDs))
		for i, id := range opts.ChannelIDs {
			placeholders[i] = "?"
			args = append(args, id)
		}
		conditions = append(conditions, "channel_id IN ("+strings.Join(placeholders, ",")+")")
	}

	if len(opts.UserIDs) > 0 {
		placeholders := make([]string, len(opts.UserIDs))
		for i, id := range opts.UserIDs {
			placeholders[i] = "?"
			args = append(args, id)
		}
		conditions = append(conditions, "user_id IN ("+strings.Join(placeholders, ",")+")")
	}

	if opts.FromUnix > 0 {
		conditions = append(conditions, "ts_unix >= ?")
		args = append(args, opts.FromUnix)
	}

	if opts.ToUnix > 0 {
		conditions = append(conditions, "ts_unix <= ?")
		args = append(args, opts.ToUnix)
	}

	if len(conditions) == 0 {
		return nil, nil
	}

	sqlQuery := `SELECT ` + msgSelectCols + ` FROM messages WHERE is_deleted = 0 AND ` +
		strings.Join(conditions, " AND ") + ` ORDER BY ts_unix DESC LIMIT ?`

	limit := opts.Limit
	if limit <= 0 {
		limit = 50
	}
	args = append(args, limit)

	rows, err := db.Query(sqlQuery, args...)
	if err != nil {
		return nil, fmt.Errorf("listing recent messages: %w", err)
	}
	defer rows.Close()

	return scanMessages(rows)
}

// sanitizeFTS5Query sanitizes user input for safe use in FTS5 MATCH queries.
// Each term is individually double-quoted (allowlist approach) to prevent any
// FTS5 operator injection. Quotes within terms are stripped so they can't
// break out of the quoting.
func sanitizeFTS5Query(query string) string {
	words := strings.Fields(query)
	if len(words) == 0 {
		return ""
	}
	// FTS5 reserved operators (case-insensitive) — skip entirely
	operators := map[string]bool{
		"AND": true, "OR": true, "NOT": true, "NEAR": true,
	}
	var safe []string
	for _, w := range words {
		if operators[strings.ToUpper(w)] {
			continue
		}
		// Strip all quotes to prevent breaking out of the double-quoting
		w = strings.Map(func(r rune) rune {
			if r == '"' {
				return -1
			}
			return r
		}, w)
		w = strings.TrimSpace(w)
		if w != "" {
			safe = append(safe, `"`+w+`"`)
		}
	}
	if len(safe) == 0 {
		return ""
	}
	return strings.Join(safe, " ")
}

// TranscriptHit is one full-text match in a meeting transcript: enough to
// decide whether to fetch the whole thing, never the whole thing itself.
type TranscriptHit struct {
	ID        int64  `json:"id"`
	Title     string `json:"title"`
	EventID   string `json:"event_id,omitempty"`
	CreatedAt string `json:"created_at"`
	Snippet   string `json:"snippet"`
}

// SearchTranscripts runs a full-text search over meeting transcripts via
// transcripts_fts, newest first. The query is sanitized the same way
// SearchMessages sanitizes its input, so caller text can never inject FTS5
// operators. An empty query returns no rows and no error.
func (db *DB) SearchTranscripts(query string, limit int) ([]TranscriptHit, error) {
	sanitized := sanitizeFTS5Query(query)
	if sanitized == "" {
		return nil, nil
	}
	if limit <= 0 {
		limit = 20
	}

	rows, err := db.Query(`
		SELECT mt.id, mt.title, COALESCE(mt.event_id, ''), mt.created_at,
		       snippet(transcripts_fts, 0, '', '', '…', 40)
		FROM transcripts_fts
		JOIN meeting_transcripts mt ON mt.id = transcripts_fts.transcript_id
		WHERE transcripts_fts MATCH ?
		ORDER BY mt.created_at DESC
		LIMIT ?`, sanitized, limit)
	if err != nil {
		return nil, fmt.Errorf("searching transcripts: %w", err)
	}
	defer rows.Close()

	var out []TranscriptHit
	for rows.Next() {
		var h TranscriptHit
		if err := rows.Scan(&h.ID, &h.Title, &h.EventID, &h.CreatedAt, &h.Snippet); err != nil {
			return nil, fmt.Errorf("scanning transcript hit: %w", err)
		}
		out = append(out, h)
	}
	return out, rows.Err()
}
