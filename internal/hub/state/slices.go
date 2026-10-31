package state

import (
	"database/sql"
	"fmt"
	"strings"
	"time"
)

// SliceRecord is what was last pushed for one DataZone record: its payload
// hash and opaque wire name.
type SliceRecord struct {
	Hash     string
	WireName string
}

// SliceHashes maps record name → last pushed state for every record of kind
// (record names "<kind>-…", as the Swift hub's hashes(forKind:), plus the
// bare name "<kind>": the heartbeat's record is "heartbeat"; no other kind
// writes a bare name).
func (s *Store) SliceHashes(kind string) (map[string]SliceRecord, error) {
	esc := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`).Replace(kind)
	rows, err := s.db.Query(`SELECT record_name, payload_hash, wire_name FROM slice_state
		WHERE record_name LIKE ? ESCAPE '\' OR record_name = ?`, esc+"-%", kind)
	if err != nil {
		return nil, fmt.Errorf("reading slice state: %w", err)
	}
	defer rows.Close()
	out := map[string]SliceRecord{}
	for rows.Next() {
		var (
			name string
			r    SliceRecord
			wire sql.NullString
		)
		if err := rows.Scan(&name, &r.Hash, &wire); err != nil {
			return nil, fmt.Errorf("reading slice state: %w", err)
		}
		r.WireName = wire.String
		out[name] = r
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading slice state: %w", err)
	}
	return out, nil
}

// SetSliceState records a pushed record.
func SetSliceState(tx *sql.Tx, record, wire, hash string, at time.Time) error {
	if _, err := tx.Exec(`INSERT INTO slice_state (record_name, payload_hash, pushed_at, wire_name) VALUES (?, ?, ?, ?)
		ON CONFLICT(record_name) DO UPDATE SET payload_hash = excluded.payload_hash,
			pushed_at = excluded.pushed_at, wire_name = excluded.wire_name`,
		record, hash, toReal(at), nullString(wire)); err != nil {
		return fmt.Errorf("writing slice state: %w", err)
	}
	return nil
}

// DeleteSliceState forgets a record removed from the zone.
func DeleteSliceState(tx *sql.Tx, record string) error {
	if _, err := tx.Exec(`DELETE FROM slice_state WHERE record_name = ?`, record); err != nil {
		return fmt.Errorf("deleting slice state: %w", err)
	}
	return nil
}
