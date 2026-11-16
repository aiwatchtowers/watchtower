package db

import (
	"database/sql"
	"fmt"
	"strings"
	"time"
)

// WatchmanKnownKeys reports which of keys a source already handed over:
// stored as precedents of source, or marked skipped (offered, not stored).
// Keys are unique per source.
func (db *DB) WatchmanKnownKeys(source string, keys []string) (map[string]bool, error) {
	out := map[string]bool{}
	const chunk = 500
	for start := 0; start < len(keys); start += chunk {
		if err := db.watchmanKnownKeysChunk(source, keys[start:min(start+chunk, len(keys))], out); err != nil {
			return nil, fmt.Errorf("reading known watchman %s keys: %w", source, err)
		}
	}
	return out, nil
}

func (db *DB) watchmanKnownKeysChunk(source string, keys []string, out map[string]bool) error {
	in := strings.TrimSuffix(strings.Repeat("?,", len(keys)), ",")
	args := make([]any, 0, 2*len(keys)+2)
	for range 2 {
		args = append(args, source)
		for _, k := range keys {
			args = append(args, k)
		}
	}
	rows, err := db.Query(`SELECT source_key FROM watchman_precedents WHERE source = ? AND source_key IN (`+in+`)
		UNION SELECT source_key FROM watchman_skipped_keys WHERE source = ? AND source_key IN (`+in+`)`, args...)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var k string
		if err := rows.Scan(&k); err != nil {
			return err
		}
		out[k] = true
	}
	return rows.Err()
}

// MarkWatchmanSkippedKeys records inside tx that source offered keys and
// the learner did not store them (no category), so they are not offered
// again. A key marked twice keeps its first time.
func (db *DB) MarkWatchmanSkippedKeys(tx *sql.Tx, source string, keys []string, at time.Time) error {
	for _, k := range keys {
		if _, err := tx.Exec(`INSERT INTO watchman_skipped_keys (source, source_key, skipped_at) VALUES (?, ?, ?)
			ON CONFLICT(source, source_key) DO NOTHING`, source, k, wmTime(at)); err != nil {
			return fmt.Errorf("marking watchman %s key %s skipped: %w", source, k, err)
		}
	}
	return nil
}
