package state

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// MetaRelaySlotLinks is the phones whose link was confirmed through a relay
// pairing slot, and the requests waiting that came through one: JSON
// {"linked": {device id: devices.link_nonce of that link}, "pending":
// {device id: the request's code nonce}}, ids uppercase. A CloudKit link
// whose owner could not be read carries no iCloud user, like a slot link
// (ICloudRoutes cannot tell them apart), so this is the switcher's positive
// "linked over Relay" signal (relay-link check). No migration: a hub_meta
// row.
//
// Each entry names the link or request it was written for (the link nonce,
// the code nonce), and the readers compare it with the row they stand for:
// a re-link or a replaced request that a writer outside this file made
// without updating the row can never leave a stale mark that counts.
//
// Its writers are internal/hub/link only, each in the transaction of the
// change it records, all under the link center's lock: a hello's saved
// request (marks or clears its pending entry), the confirm (promotes the
// entry whose code nonce matches the linked request, or drops the phone from
// linked for any other link: a re-link over CloudKit), a refusal or expiry of
// a waiting request (its pending entry only: a linked phone's link stays),
// and an unlink (both). Every write also prunes entries whose devices or
// pending_devices row is gone or names another nonce. The switcher only
// reads it. A row that cannot be decoded reads as an error here (the
// switcher logs it and sees no candidate); a writer replaces it, as empty
// plus its own change: losing entries only takes candidates away.
//
// A slot hello proves where it arrived, not who owns the relay id it names
// (the hello carries no relay_auth proof; the device record's later proof,
// VerifyRelayIDProof, is what moves an id between rows).
const MetaRelaySlotLinks = "relay_slot_links"

// ErrRelaySlotLinksUndecodable is the relay_slot_links row being there but
// not decodable (an error of its own, apart from a failed read).
var ErrRelaySlotLinksUndecodable = errors.New("state: relay_slot_links cannot be decoded")

// relaySlotLinks is the row's content.
type relaySlotLinks struct {
	Linked  map[string]string `json:"linked,omitempty"`
	Pending map[string]string `json:"pending,omitempty"`
}

// slotID is the row's form of a device id; every reader and writer uses it.
func slotID(device string) string { return strings.ToUpper(device) }

func readRelaySlotLinks(q querier) (relaySlotLinks, error) {
	raw, ok, err := meta(q, MetaRelaySlotLinks)
	if err != nil || !ok || raw == "" {
		return relaySlotLinks{}, err
	}
	var r relaySlotLinks
	if err := json.Unmarshal([]byte(raw), &r); err != nil {
		return relaySlotLinks{}, fmt.Errorf("%w: %w", ErrRelaySlotLinksUndecodable, err)
	}
	return r, nil
}

// RelaySlotLinked is the linked phones confirmed through a relay pairing
// slot, each with the link nonce of that link (uppercase ids). A caller
// counts a phone only while its devices row carries the same link nonce. An
// undecodable row is an error.
func (s *Store) RelaySlotLinked() (map[string]string, error) {
	r, err := readRelaySlotLinks(s.db)
	if err != nil {
		return nil, err
	}
	out := make(map[string]string, len(r.Linked))
	for id, nonce := range r.Linked {
		out[slotID(id)] = nonce
	}
	return out, nil
}

// RelaySlotLinkedTx is whether device's link under linkNonce was confirmed
// through a pairing slot, inside the caller's transaction.
func RelaySlotLinkedTx(tx *sql.Tx, device, linkNonce string) (bool, error) {
	r, err := readRelaySlotLinks(tx)
	if err != nil {
		return false, err
	}
	for id, nonce := range r.Linked {
		if slotID(id) == slotID(device) {
			return linkNonce != "" && nonce == linkNonce, nil
		}
	}
	return false, nil
}

// RelaySlotPendingTx is whether device's waiting request under the code
// nonce came through a pairing slot. The nonce is compared, not just the
// device: a request that a writer which does not know the row replaced
// under another code never inherits the mark. An undecodable row is
// ErrRelaySlotLinksUndecodable (the route is unknown), a failed read its own
// error.
func RelaySlotPendingTx(tx *sql.Tx, device, nonce string) (bool, error) {
	r, err := readRelaySlotLinks(tx)
	if err != nil {
		return false, err
	}
	return nonce != "" && r.Pending[slotID(device)] == nonce, nil
}

// MarkRelaySlotRequestTx records how device's request, just saved under the
// code nonce, came in: through a pairing slot (slot) or not (its entry goes).
func MarkRelaySlotRequestTx(tx *sql.Tx, device, nonce string, slot bool) error {
	return updateRelaySlotLinks(tx, func(r *relaySlotLinks) {
		id := slotID(device)
		if !slot {
			delete(r.Pending, id)
			return
		}
		if r.Pending == nil {
			r.Pending = map[string]string{}
		}
		r.Pending[id] = nonce
	})
}

// ConfirmRelaySlotLinkTx is the confirm that linked device under the code
// nonce (which is also the link's devices.link_nonce): linked through a slot
// when its waiting request was marked under that nonce, otherwise (a
// CloudKit link or re-link) not. The pending entry goes either way.
func ConfirmRelaySlotLinkTx(tx *sql.Tx, device, nonce string) error {
	return updateRelaySlotLinks(tx, func(r *relaySlotLinks) {
		id := slotID(device)
		slot := nonce != "" && r.Pending[id] == nonce
		delete(r.Pending, id)
		delete(r.Linked, id)
		if slot {
			if r.Linked == nil {
				r.Linked = map[string]string{}
			}
			r.Linked[id] = nonce
		}
	})
}

// ForgetRelaySlotTx drops device's waiting entry and its link (an unlink).
func ForgetRelaySlotTx(tx *sql.Tx, device string) error {
	return updateRelaySlotLinks(tx, func(r *relaySlotLinks) {
		id := slotID(device)
		delete(r.Pending, id)
		delete(r.Linked, id)
	})
}

// updateRelaySlotLinks applies change to the row (an undecodable one counts
// as empty), prunes entries whose phone is no longer linked or waiting under
// the nonce they name, and writes it back (removed when empty).
func updateRelaySlotLinks(tx *sql.Tx, change func(*relaySlotLinks)) error {
	r, err := readRelaySlotLinks(tx)
	if errors.Is(err, ErrRelaySlotLinksUndecodable) {
		r = relaySlotLinks{}
	} else if err != nil {
		return err
	}
	change(&r)
	linked, err := nonces(tx, `SELECT device_id, link_nonce FROM devices`)
	if err != nil {
		return err
	}
	waiting, err := nonces(tx, `SELECT device_id, link_nonce FROM pending_devices`)
	if err != nil {
		return err
	}
	for id, nonce := range r.Linked {
		if n, ok := linked[slotID(id)]; !ok || n != nonce {
			delete(r.Linked, id)
		}
	}
	for id, nonce := range r.Pending {
		if n, ok := waiting[slotID(id)]; !ok || n != nonce {
			delete(r.Pending, id)
		}
	}
	if len(r.Linked) == 0 && len(r.Pending) == 0 {
		return DeleteMetaTx(tx, MetaRelaySlotLinks)
	}
	b, err := json.Marshal(r) // map keys sorted: the row is stable
	if err != nil {
		return err
	}
	return SetMetaTx(tx, MetaRelaySlotLinks, string(b))
}

// nonces is device id → link nonce for query's rows (two text columns).
func nonces(tx *sql.Tx, query string) (map[string]string, error) {
	rows, err := tx.Query(query)
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", MetaRelaySlotLinks, err)
	}
	defer func() { _ = rows.Close() }()
	out := map[string]string{}
	for rows.Next() {
		var id string
		var nonce sql.NullString
		if err := rows.Scan(&id, &nonce); err != nil {
			return nil, err
		}
		out[slotID(id)] = nonce.String
	}
	return out, rows.Err()
}
