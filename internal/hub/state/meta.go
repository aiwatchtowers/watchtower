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
	// MetaTransport is the transport the hub runs on, "cloudkit" | "relay"
	// (adoption writes "cloudkit").
	MetaTransport = "transport"
	// MetaMailboxFullPhones is the device ids (a JSON list, nothing else)
	// whose relay mailbox refused the hub's write as over quota, until a
	// write to that phone's mailbox succeeds or the phone is unlinked.
	MetaMailboxFullPhones = "mailbox_full_phones"
	// MetaLapsePending is the relay lapses waiting for the switcher's Step,
	// "<device id>@<unix seconds>" comma-joined; only the switcher writes it.
	// A phone listed here offers no relay key (SetKXOffer).
	MetaLapsePending = "lapse_pending"
	// MetaReaderLostOwed is the devices, "<device id>@<link time, unix ns>"
	// comma-joined and sorted, whose ReaderLost cleared their relay keys and
	// did not finish (the lapsed mark, hub_on_relay); only the switcher writes
	// it, and its departure check finishes them, across a restart too. The
	// hub leaving the relay empties it, and a re-link drops that phone.
	MetaReaderLostOwed = "reader_lost_owed"
	// MetaServingNobodySince is when an answered relay account read first
	// showed no linked phone in a slot or no phone paying (unix seconds,
	// decimal); the runtime writes it at each answered read on the relay, a
	// rotation toward iCloud removes it, and the keyring's rotation check
	// reads it: while it is set no age rotation runs, and 14 days after it
	// the hub rotates once and clears every relay key (relay client Phase 5).
	MetaServingNobodySince = "relay_serving_nobody_since"
)

// Meta reads one hub_meta value; ok is false when the key is unset.
func (s *Store) Meta(key string) (string, bool, error) { return meta(s.db, key) }

// MetaTx is Meta inside the caller's transaction.
func MetaTx(tx *sql.Tx, key string) (string, bool, error) { return meta(tx, key) }

func meta(q querier, key string) (string, bool, error) {
	var v string
	err := q.QueryRow(`SELECT value FROM hub_meta WHERE key = ?`, key).Scan(&v)
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

// DeleteMetaTx removes one hub_meta value in the caller's transaction.
func DeleteMetaTx(tx *sql.Tx, key string) error {
	if _, err := tx.Exec(`DELETE FROM hub_meta WHERE key = ?`, key); err != nil {
		return fmt.Errorf("removing hub_meta %s: %w", key, err)
	}
	return nil
}
