package state

import (
	"database/sql"
	"errors"
	"fmt"
)

// ZoneToken is the transport's stored change token for zone (the hosted
// relay's since_seq); 0 when none is stored.
func (s *Store) ZoneToken(zone string) (uint64, error) {
	var v int64
	err := s.db.QueryRow(`SELECT since_seq FROM zone_tokens WHERE zone = ?`, zone).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("reading a zone token: %w", err)
	}
	return uint64(max(v, 0)), nil
}

// SetZoneToken stores zone's change token (0 after TOKEN_EXPIRED).
func (s *Store) SetZoneToken(zone string, since uint64) error {
	v, err := u64(since)
	if err != nil {
		return err
	}
	return s.write(func(tx *sql.Tx) error {
		if _, err := tx.Exec(`INSERT INTO zone_tokens (zone, since_seq) VALUES (?, ?)
			ON CONFLICT(zone) DO UPDATE SET since_seq = excluded.since_seq`, zone, v); err != nil {
			return fmt.Errorf("writing a zone token: %w", err)
		}
		return nil
	})
}
