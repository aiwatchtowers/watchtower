package state

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
)

// MetaRelaySlotLinks is the phones whose link was confirmed through a relay
// pairing slot, and the requests waiting that came through one: JSON
// {"linked": [device ids], "pending": {device id: the request's code nonce}},
// ids uppercase. A slot hello proves its relay id through the slot, a
// CloudKit hello does not, and an empty iCloud user (ICloudRoutes) cannot
// tell the two apart, so this is the switcher's positive "linked over Relay"
// signal (relay-link check). No migration: a hub_meta row.
//
// Its writers are internal/hub/link only, each in the transaction of the
// change it records, all under the link center's lock: a hello's saved
// request (marks or clears its pending entry), the confirm (promotes the
// entry whose code nonce matches the linked request, or drops the phone from
// linked for any other link: a re-link over CloudKit), a refusal or expiry of
// a waiting request, and an unlink (drop the phone). Every write also prunes
// entries whose devices or pending_devices row is gone. The switcher only
// reads it. A row that cannot be decoded reads as an error here (the
// switcher logs it and sees no candidate); a writer replaces it, as empty
// plus its own change: losing entries only takes candidates away.
const MetaRelaySlotLinks = "relay_slot_links"

// relaySlotLinks is the row's content.
type relaySlotLinks struct {
	Linked  []string          `json:"linked,omitempty"`
	Pending map[string]string `json:"pending,omitempty"`
}

func readRelaySlotLinks(q querier) (relaySlotLinks, error) {
	raw, ok, err := meta(q, MetaRelaySlotLinks)
	if err != nil || !ok || raw == "" {
		return relaySlotLinks{}, err
	}
	var r relaySlotLinks
	if err := json.Unmarshal([]byte(raw), &r); err != nil {
		return relaySlotLinks{}, fmt.Errorf("reading hub_meta %s: %w", MetaRelaySlotLinks, err)
	}
	return r, nil
}

// RelaySlotLinked is the linked phones confirmed through a relay pairing
// slot (uppercase ids). An undecodable row is an error.
func (s *Store) RelaySlotLinked() (map[string]bool, error) {
	r, err := readRelaySlotLinks(s.db)
	if err != nil {
		return nil, err
	}
	out := make(map[string]bool, len(r.Linked))
	for _, id := range r.Linked {
		out[strings.ToUpper(id)] = true
	}
	return out, nil
}

// RelaySlotLinkedTx is whether device is among RelaySlotLinked, inside the
// caller's transaction.
func RelaySlotLinkedTx(tx *sql.Tx, device string) (bool, error) {
	r, err := readRelaySlotLinks(tx)
	if err != nil {
		return false, err
	}
	return slices.Contains(r.Linked, strings.ToUpper(device)), nil
}

// MarkRelaySlotRequestTx records how device's request, just saved under the
// code nonce, came in: through a pairing slot (slot) or not (its entry goes).
func MarkRelaySlotRequestTx(tx *sql.Tx, device, nonce string, slot bool) error {
	return updateRelaySlotLinks(tx, func(r *relaySlotLinks) {
		id := strings.ToUpper(device)
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
// nonce: linked through a slot when its waiting request was marked under that
// nonce, otherwise (a CloudKit link or re-link) not. The entry goes either way.
func ConfirmRelaySlotLinkTx(tx *sql.Tx, device, nonce string) error {
	return updateRelaySlotLinks(tx, func(r *relaySlotLinks) {
		id := strings.ToUpper(device)
		slot := nonce != "" && r.Pending[id] == nonce
		delete(r.Pending, id)
		r.Linked = slices.DeleteFunc(r.Linked, func(x string) bool { return x == id })
		if slot {
			r.Linked = append(r.Linked, id)
		}
	})
}

// ForgetRelaySlotTx drops device's waiting entry and its link (a refusal, an
// expiry, an unlink).
func ForgetRelaySlotTx(tx *sql.Tx, device string) error {
	return updateRelaySlotLinks(tx, func(r *relaySlotLinks) {
		id := strings.ToUpper(device)
		delete(r.Pending, id)
		r.Linked = slices.DeleteFunc(r.Linked, func(x string) bool { return x == id })
	})
}

// updateRelaySlotLinks applies change to the row (an undecodable one counts
// as empty), prunes entries whose phone is no longer linked or waiting, and
// writes it back (removed when empty).
func updateRelaySlotLinks(tx *sql.Tx, change func(*relaySlotLinks)) error {
	r, err := readRelaySlotLinks(tx)
	if err != nil {
		if _, _, merr := meta(tx, MetaRelaySlotLinks); merr != nil {
			return err // unreadable, not undecodable
		}
		r = relaySlotLinks{}
	}
	change(&r)
	linked, err := idSet(tx, `SELECT device_id FROM devices`)
	if err != nil {
		return err
	}
	waiting, err := idSet(tx, `SELECT device_id FROM pending_devices`)
	if err != nil {
		return err
	}
	r.Linked = slices.DeleteFunc(r.Linked, func(id string) bool { return !linked[id] })
	for id := range r.Pending {
		if !waiting[id] {
			delete(r.Pending, id)
		}
	}
	if len(r.Linked) == 0 && len(r.Pending) == 0 {
		return DeleteMetaTx(tx, MetaRelaySlotLinks)
	}
	slices.Sort(r.Linked)
	b, err := json.Marshal(r)
	if err != nil {
		return err
	}
	return SetMetaTx(tx, MetaRelaySlotLinks, string(b))
}

func idSet(tx *sql.Tx, query string) (map[string]bool, error) {
	rows, err := tx.Query(query)
	if err != nil {
		return nil, fmt.Errorf("reading %s: %w", MetaRelaySlotLinks, err)
	}
	defer func() { _ = rows.Close() }()
	out := map[string]bool{}
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out[strings.ToUpper(id)] = true
	}
	return out, rows.Err()
}
