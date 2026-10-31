package state

import (
	"database/sql"
	"errors"
	"fmt"
	"math"
	"time"
)

// Epoch is one hub_epochs row: SealedKeys is ChaChaPoly(wrap, K_data ‖
// K_alert) in CryptoKit's combined layout; no key is stored in the clear.
type Epoch struct {
	Epoch      uint32
	SealedKeys []byte
	CreatedAt  time.Time
	FirstSeq   uint64
	RetiredAt  *time.Time
}

// querier is what a read needs: the database or a transaction.
type querier interface {
	Query(query string, args ...any) (*sql.Rows, error)
	QueryRow(query string, args ...any) *sql.Row
}

// Epochs lists every epoch, oldest first.
func (s *Store) Epochs() ([]Epoch, error) { return epochs(s.db) }

// EpochsTx is Epochs inside the caller's transaction (a rotation reads the
// current epoch under the write lock it then writes under).
func EpochsTx(tx *sql.Tx) ([]Epoch, error) { return epochs(tx) }

func epochs(q querier) ([]Epoch, error) {
	rows, err := q.Query(`SELECT epoch, sealed_keys, created_at, first_seq, retired_at FROM hub_epochs ORDER BY epoch`)
	if err != nil {
		return nil, fmt.Errorf("listing epochs: %w", err)
	}
	defer rows.Close()
	var out []Epoch
	for rows.Next() {
		var (
			e        Epoch
			epoch    int64
			created  float64
			first    int64
			retiredF sql.NullFloat64
		)
		if err := rows.Scan(&epoch, &e.SealedKeys, &created, &first, &retiredF); err != nil {
			return nil, fmt.Errorf("reading an epoch: %w", err)
		}
		if epoch < 0 || epoch > math.MaxUint32 {
			return nil, fmt.Errorf("epoch %d out of range", epoch)
		}
		e.Epoch = uint32(epoch)
		e.CreatedAt = fromReal(created)
		e.FirstSeq = uint64(max(first, 0))
		if retiredF.Valid {
			t := fromReal(retiredF.Float64)
			e.RetiredAt = &t
		}
		out = append(out, e)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing epochs: %w", err)
	}
	return out, nil
}

// InsertEpoch writes a new epoch in the caller's transaction (a rotation
// writes it with the retirement of the previous one).
func InsertEpoch(tx *sql.Tx, e Epoch) error {
	first, err := u64(e.FirstSeq)
	if err != nil {
		return err
	}
	var retired any
	if e.RetiredAt != nil {
		retired = toReal(*e.RetiredAt)
	}
	if _, err := tx.Exec(`INSERT INTO hub_epochs (epoch, sealed_keys, created_at, first_seq, retired_at) VALUES (?, ?, ?, ?, ?)`,
		int64(e.Epoch), e.SealedKeys, toReal(e.CreatedAt), first, retired); err != nil {
		return fmt.Errorf("writing an epoch: %w", err)
	}
	return nil
}

// RetireEpoch stamps epoch as retired at at.
func RetireEpoch(tx *sql.Tx, epoch uint32, at time.Time) error {
	if _, err := tx.Exec(`UPDATE hub_epochs SET retired_at = ? WHERE epoch = ?`, toReal(at), int64(epoch)); err != nil {
		return fmt.Errorf("retiring an epoch: %w", err)
	}
	return nil
}

// WipeSliceHashes forgets every pushed record's payload hash in the caller's
// transaction (a rotation: the next publish cycle republishes the window
// under the new epoch). Wire names and the relay tokens stay.
func WipeSliceHashes(tx *sql.Tx) error {
	if _, err := tx.Exec(`UPDATE slice_state SET payload_hash = ''`); err != nil {
		return fmt.Errorf("wiping slice hashes: %w", err)
	}
	return nil
}

// KeyboxRecipientKey is the agreement key a keybox for device is sealed to:
// a linked phone's, else a pending, a revoked or a refused one's (the Swift
// hub's order). nil when none of them holds a key for it.
func (s *Store) KeyboxRecipientKey(device string) ([]byte, error) {
	for _, q := range []string{
		`SELECT agreement_key FROM devices WHERE device_id = ? COLLATE NOCASE AND agreement_key IS NOT NULL`,
		`SELECT agreement_key FROM pending_devices WHERE device_id = ? COLLATE NOCASE AND agreement_key IS NOT NULL`,
		`SELECT agreement_key FROM revoked_devices WHERE device_id = ? COLLATE NOCASE AND agreement_key IS NOT NULL`,
		`SELECT agreement_key FROM link_refusals WHERE device_id = ? COLLATE NOCASE AND agreement_key IS NOT NULL`,
	} {
		var key []byte
		err := s.db.QueryRow(q, device).Scan(&key)
		if errors.Is(err, sql.ErrNoRows) {
			continue
		}
		if err != nil {
			return nil, fmt.Errorf("reading a keybox recipient: %w", err)
		}
		return key, nil
	}
	return nil, nil
}
