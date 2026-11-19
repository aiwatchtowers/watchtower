package db

import (
	"database/sql"
	"fmt"
	"strings"
	"time"
)

// WatchmanKnownKeys reports which of keys a source already handed over in
// the workbench: stored as precedents of source, or marked skipped (offered,
// not stored). Keys are unique per workbench and source only (a git commit
// hash or PR number repeats across repositories).
func (db *DB) WatchmanKnownKeys(workbenchID int64, source string, keys []string) (map[string]bool, error) {
	out := map[string]bool{}
	const chunk = 500
	for start := 0; start < len(keys); start += chunk {
		if err := db.watchmanKnownKeysChunk(workbenchID, source, keys[start:min(start+chunk, len(keys))], out); err != nil {
			return nil, fmt.Errorf("reading known watchman %s keys: %w", source, err)
		}
	}
	return out, nil
}

func (db *DB) watchmanKnownKeysChunk(workbenchID int64, source string, keys []string, out map[string]bool) error {
	in := strings.TrimSuffix(strings.Repeat("?,", len(keys)), ",")
	args := make([]any, 0, 2*len(keys)+4)
	for range 2 {
		args = append(args, workbenchID, source)
		for _, k := range keys {
			args = append(args, k)
		}
	}
	rows, err := db.Query(`SELECT source_key FROM watchman_precedents WHERE workbench_id = ? AND source = ? AND source_key IN (`+in+`)
		UNION SELECT source_key FROM watchman_skipped_keys WHERE workbench_id = ? AND source = ? AND source_key IN (`+in+`)`, args...)
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

// MarkWatchmanSkippedKeys records inside tx that source offered keys in the
// workbench and the learner did not store them (no category), so they are not offered
// again. A key marked twice keeps its first time.
func (db *DB) MarkWatchmanSkippedKeys(tx *sql.Tx, workbenchID int64, source string, keys []string, at time.Time) error {
	for _, k := range keys {
		if _, err := tx.Exec(`INSERT INTO watchman_skipped_keys (workbench_id, source, source_key, skipped_at) VALUES (?, ?, ?, ?)
			ON CONFLICT(workbench_id, source, source_key) DO NOTHING`, workbenchID, source, k, wmTime(at)); err != nil {
			return fmt.Errorf("marking watchman %s key %s skipped: %w", source, k, err)
		}
	}
	return nil
}
