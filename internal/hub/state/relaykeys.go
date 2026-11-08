package state

import (
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

// Relay key offers and per-epoch relay keys (relay client Phase 5).
//
// Writers: the processor (SetKXOffer, from a phone's epoch_ack), the switcher
// (ClearKXOffers on leaving the relay, ClearDeviceKX on a lapse or a lost
// reader), the link center (LinkDevice on a re-link, an unlink) and the
// rotation (InsertEpochRelayKeys, EraseEpoch), each in its own BEGIN IMMEDIATE
// transaction. A clear beats any offer read after it: the ack's transaction
// reads hub_meta.transport (the processor), relay_lapsed_at and lapse_pending
// (SetKXOffer) before it writes.

// EpochRelayKeys is one phone's relay keys of one epoch: SealedKeys is the two
// derived keys (p2h, h2p) sealed under the wrap key; HubPub and DevicePub are
// the ephemeral publics that built them, which the keybox names.
type EpochRelayKeys struct {
	Epoch      uint32
	DeviceID   string
	HubPub     []byte
	DevicePub  []byte
	SealedKeys []byte
}

// SetKXOffer stores pub as device's relay key offer from an ack of epoch, in
// the caller's transaction. It writes only when epoch is at least the stored
// offer's (an older ack never replaces a newer offer; the same epoch offered
// again does), the phone is not lapsed (relay_lapsed_at) and no lapse of it
// waits for the switcher (MetaLapsePending); false, and nothing written,
// otherwise or when device is not linked. The caller checks that the hub is on
// the relay and that pub is a usable X25519 key.
func SetKXOffer(tx *sql.Tx, device string, pub []byte, epoch uint32) (bool, error) {
	pending, err := lapsePending(tx, device)
	if err != nil || pending {
		return false, err
	}
	res, err := tx.Exec(`UPDATE devices SET kx_offer = ?, kx_offer_epoch = ?
		WHERE device_id = ? COLLATE NOCASE AND relay_lapsed_at IS NULL AND kx_offer_epoch <= ?`,
		pub, int64(epoch), device, int64(epoch))
	if err != nil {
		return false, fmt.Errorf("storing a relay key offer: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, fmt.Errorf("storing a relay key offer: %w", err)
	}
	return n > 0, nil
}

// lapsePending reports whether device is listed in MetaLapsePending.
func lapsePending(tx *sql.Tx, device string) (bool, error) {
	v, ok, err := MetaTx(tx, MetaLapsePending)
	if err != nil || !ok {
		return false, err
	}
	for e := range strings.SplitSeq(v, ",") {
		id, _, _ := strings.Cut(e, "@")
		if id != "" && strings.EqualFold(id, device) {
			return true, nil
		}
	}
	return false, nil
}

// ClearKXOffers drops every phone's offer (the hub left the relay), in the
// caller's transaction. Stored relay keys stay until their epoch is erased.
func ClearKXOffers(tx *sql.Tx) error {
	if _, err := tx.Exec(`UPDATE devices SET kx_offer = NULL, kx_offer_epoch = 0 WHERE kx_offer IS NOT NULL OR kx_offer_epoch != 0`); err != nil {
		return fmt.Errorf("clearing relay key offers: %w", err)
	}
	return nil
}

// ClearAllRelayKeys drops every phone's offer and every relay-key row, in the
// caller's transaction (the rotation that ends the 14-day hold of a hub
// serving nobody).
func ClearAllRelayKeys(tx *sql.Tx) error {
	if err := ClearKXOffers(tx); err != nil {
		return err
	}
	if _, err := tx.Exec(`DELETE FROM epoch_relay_keys`); err != nil {
		return fmt.Errorf("clearing relay keys: %w", err)
	}
	return nil
}

// ClearDeviceKX drops device's offer and every relay-key row of it, in the
// caller's transaction (a lapse, a lost reader, an unlink). A phone not linked
// loses its rows all the same.
func ClearDeviceKX(tx *sql.Tx, device string) error {
	if _, err := tx.Exec(`UPDATE devices SET kx_offer = NULL, kx_offer_epoch = 0 WHERE device_id = ? COLLATE NOCASE`, device); err != nil {
		return fmt.Errorf("clearing a phone's relay keys: %w", err)
	}
	return deleteRelayKeys(tx, device)
}

func deleteRelayKeys(tx *sql.Tx, device string) error {
	if _, err := tx.Exec(`DELETE FROM epoch_relay_keys WHERE device_id = ? COLLATE NOCASE`, device); err != nil {
		return fmt.Errorf("clearing a phone's relay keys: %w", err)
	}
	return nil
}

// InsertEpochRelayKeys writes one phone's relay keys of one epoch, in the
// caller's transaction (the rotation that begins the epoch); the device id is
// stored uppercase.
func InsertEpochRelayKeys(tx *sql.Tx, k EpochRelayKeys) error {
	if _, err := tx.Exec(`INSERT INTO epoch_relay_keys (epoch, device_id, hub_pub, device_pub, sealed_keys) VALUES (?, ?, ?, ?, ?)`,
		int64(k.Epoch), deviceKey(k.DeviceID), k.HubPub, k.DevicePub, k.SealedKeys); err != nil {
		return fmt.Errorf("writing relay keys: %w", err)
	}
	return nil
}

// EpochRelayKeys reads device's relay keys of epoch; ok is false when there
// are none.
func (s *Store) EpochRelayKeys(epoch uint32, device string) (EpochRelayKeys, bool, error) {
	k := EpochRelayKeys{Epoch: epoch}
	err := s.db.QueryRow(`SELECT device_id, hub_pub, device_pub, sealed_keys FROM epoch_relay_keys
		WHERE epoch = ? AND device_id = ? COLLATE NOCASE`, int64(epoch), device).
		Scan(&k.DeviceID, &k.HubPub, &k.DevicePub, &k.SealedKeys)
	if errors.Is(err, sql.ErrNoRows) {
		return EpochRelayKeys{}, false, nil
	}
	if err != nil {
		return EpochRelayKeys{}, false, fmt.Errorf("reading relay keys: %w", err)
	}
	return k, true, nil
}

// EraseEpoch erases a relay epoch's keys, in the caller's transaction: its
// relay-key rows go and its hub_epochs row stays with an empty sealed_keys. Only
// an epoch that began on the relay (on_relay = 1) loses its sealed_keys; an
// iCloud epoch and a row from before sidecar migration 00016 (on_relay NULL)
// keep theirs (ask #1066).
func EraseEpoch(tx *sql.Tx, epoch uint32) error {
	if _, err := tx.Exec(`DELETE FROM epoch_relay_keys WHERE epoch = ?`, int64(epoch)); err != nil {
		return fmt.Errorf("erasing an epoch: %w", err)
	}
	if _, err := tx.Exec(`UPDATE hub_epochs SET sealed_keys = x'' WHERE epoch = ? AND on_relay = 1`, int64(epoch)); err != nil {
		return fmt.Errorf("erasing an epoch: %w", err)
	}
	return nil
}

// EpochRelayKeyDevices is the devices (ids as stored) that hold a relay-key
// row in epoch. Read-only; no key material is read.
func (s *Store) EpochRelayKeyDevices(epoch uint32) ([]string, error) {
	rows, err := s.db.Query(`SELECT device_id FROM epoch_relay_keys WHERE epoch = ?`, int64(epoch))
	if err != nil {
		return nil, fmt.Errorf("listing relay-key devices: %w", err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scanning relay-key device: %w", err)
		}
		out = append(out, id)
	}
	return out, rows.Err()
}
