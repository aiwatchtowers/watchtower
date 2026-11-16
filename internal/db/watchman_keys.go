package db

import (
	"fmt"
	"strings"
)

// WatchmanStoredKeys reports which of keys are already stored as precedents
// of source (keys are unique per source).
func (db *DB) WatchmanStoredKeys(source string, keys []string) (map[string]bool, error) {
	out := map[string]bool{}
	const chunk = 500
	for start := 0; start < len(keys); start += chunk {
		if err := db.watchmanStoredKeysChunk(source, keys[start:min(start+chunk, len(keys))], out); err != nil {
			return nil, fmt.Errorf("reading stored watchman %s keys: %w", source, err)
		}
	}
	return out, nil
}

func (db *DB) watchmanStoredKeysChunk(source string, keys []string, out map[string]bool) error {
	args := []any{source}
	for _, k := range keys {
		args = append(args, k)
	}
	rows, err := db.Query(`SELECT source_key FROM watchman_precedents WHERE source = ? AND source_key IN (`+
		strings.TrimSuffix(strings.Repeat("?,", len(keys)), ",")+`)`, args...)
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
