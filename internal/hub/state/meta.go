package state

import (
	"database/sql"
	"errors"
	"fmt"
)

// hub_meta keys.
const (
	MetaHubID       = "hub_id"
	MetaEnabledAt   = "enabled_at"
	MetaKMetaSealed = "k_meta_sealed"
	MetaSeqCeiling  = "envelope_seq_ceiling"
	MetaHubImpl     = "hub_impl"
	MetaEnabled     = "enabled"
	MetaDisplayName = "display_name"
)

// Meta reads one hub_meta value; ok is false when the key is unset.
func (s *Store) Meta(key string) (string, bool, error) {
	var v string
	err := s.db.QueryRow(`SELECT value FROM hub_meta WHERE key = ?`, key).Scan(&v)
	if errors.Is(err, sql.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, fmt.Errorf("reading hub_meta %s: %w", key, err)
	}
	return v, true, nil
}

// SetMeta writes one hub_meta value.
func (s *Store) SetMeta(key, value string) error {
	return s.write(func(tx *sql.Tx) error { return SetMetaTx(tx, key, value) })
}

// SetMetaTx is SetMeta inside the caller's transaction (a key rotation
// writes the sealed K_meta and the epoch together).
func SetMetaTx(tx *sql.Tx, key, value string) error {
	if _, err := tx.Exec(`INSERT INTO hub_meta (key, value) VALUES (?, ?)
		ON CONFLICT(key) DO UPDATE SET value = excluded.value`, key, value); err != nil {
		return fmt.Errorf("writing hub_meta %s: %w", key, err)
	}
	return nil
}
