package state

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"strings"
)

// MetaRelaySlotLinks is the phones whose link was confirmed through a relay
// pairing slot with a proven relay id, and the requests waiting that came
// through one: JSON {"v": 2, "linked": {device id: devices.link_nonce of that
// link}, "pending": {device id: {"nonce": the request's code nonce,
// "proven": the hello proved its relay id}}}, ids uppercase. A CloudKit link
// whose owner could not be read carries no iCloud user, like a slot link
// (ICloudRoutes cannot tell them apart), so linked is the switcher's
// positive "linked over Relay" signal (relay-link check). No migration: a
// hub_meta row.
//
// Pending records the route (an entry: the request came through a slot) and
// the mark apart (#2387): a slot hello is marked (proven) only when its
// device data proves the relay id the hello names (link's slotRelayIDProof);
// link's savePending compares both with a re-sent hello (same device, code,
// keys and relay id): a different route or a gained or lost proof replaces
// the request, so a CloudKit hello after a slot one binds its iCloud user.
// Only a proven request is promoted to linked, so an
// unproven claim (an older phone's, or one naming no relay id) never moves
// the hub to Relay.
//
// The row carries its version (v, relaySlotLinksVersion). A v1 row, written
// without v by the builds between #2191 and #2387 ({"linked": {id: nonce},
// "pending": {id: nonce}}), keeps its pending entries as slot requests,
// unproven (their route still counts), and loses its linked marks, which
// were never proven (losing them only takes candidates away); the next
// write stores v2 and logs the drop once. A row of any other version reads
// as empty.
//
// Each entry names the link or request it was written for (the link nonce,
// the code nonce), and the readers compare it with the row they stand for:
// a re-link or a replaced request that a writer outside this file made
// without updating the row can never leave a stale mark that counts.
//
// Its writers are internal/hub/link only, each in the transaction of the
// change it records, all under the link center's lock: a hello's saved
// request (writes or clears its pending entry), the confirm (promotes a
// proven entry whose code nonce matches the linked request, or drops the
// phone from linked for any other link: a re-link over CloudKit or an
// unproven one), a refusal or expiry of a waiting request (its pending entry
// only: a linked phone's link stays), and an unlink (both). Every write also
// prunes entries whose devices or pending_devices row is gone or names
// another nonce. The switcher only reads it. A row that cannot be decoded
// reads as an error here (the switcher logs it and sees no candidate); a
// writer replaces it, as empty plus its own change.
const MetaRelaySlotLinks = "relay_slot_links"

// relaySlotLinksVersion is the row's version; any other reads as empty.
const relaySlotLinksVersion = 2

// ErrRelaySlotLinksUndecodable is the relay_slot_links row being there but
// not decodable (an error of its own, apart from a failed read).
var ErrRelaySlotLinksUndecodable = errors.New("state: relay_slot_links cannot be decoded")

// relaySlotLinks is the row's content.
type relaySlotLinks struct {
	V       int                    `json:"v"`
	Linked  map[string]string      `json:"linked,omitempty"`
	Pending map[string]slotRequest `json:"pending,omitempty"`
	// droppedV1 is how many linked marks a v1 row lost on read (not stored).
	droppedV1 int
}

// slotRequest is a waiting request that came through a pairing slot.
type slotRequest struct {
	Nonce  string `json:"nonce"`
	Proven bool   `json:"proven,omitempty"`
}

// slotID is the row's form of a device id; every reader and writer uses it.
func slotID(device string) string { return strings.ToUpper(device) }

func readRelaySlotLinks(q querier) (relaySlotLinks, error) {
	raw, ok, err := meta(q, MetaRelaySlotLinks)
	if err != nil || !ok || raw == "" {
		return relaySlotLinks{}, err
	}
	var version struct {
		V int `json:"v"`
	}
	if err := json.Unmarshal([]byte(raw), &version); err != nil {
		return relaySlotLinks{}, fmt.Errorf("%w: %w", ErrRelaySlotLinksUndecodable, err)
	}
	switch version.V {
	case relaySlotLinksVersion:
	case 0:
		return readRelaySlotLinksV1(raw)
	default:
		return relaySlotLinks{}, nil
	}
	var r relaySlotLinks
	if err := json.Unmarshal([]byte(raw), &r); err != nil {
		return relaySlotLinks{}, fmt.Errorf("%w: %w", ErrRelaySlotLinksUndecodable, err)
	}
	return r, nil
}

// readRelaySlotLinksV1 reads a v1 row: its pending entries as unproven slot
// requests, its linked marks (never proven) dropped and counted for the
// writer's one log line.
func readRelaySlotLinksV1(raw string) (relaySlotLinks, error) {
	var v1 struct {
		Linked  map[string]string `json:"linked"`
		Pending map[string]string `json:"pending"`
	}
	if err := json.Unmarshal([]byte(raw), &v1); err != nil {
		return relaySlotLinks{}, fmt.Errorf("%w: %w", ErrRelaySlotLinksUndecodable, err)
	}
	r := relaySlotLinks{V: relaySlotLinksVersion, droppedV1: len(v1.Linked)}
	for id, nonce := range v1.Pending {
		if r.Pending == nil {
			r.Pending = map[string]slotRequest{}
		}
		r.Pending[id] = slotRequest{Nonce: nonce}
	}
	return r, nil
}

// RelaySlotLinked is the linked phones confirmed through a relay pairing
// slot with a proven relay id, each with the link nonce of that link
// (uppercase ids). A caller counts a phone only while its devices row
// carries the same link nonce. An undecodable row is an error.
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
// through a pairing slot with a proven relay id, inside the caller's
// transaction.
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

// RelaySlotPendingTx is how device's waiting request under the code nonce
// came in: through a pairing slot (slot) and, if so, with its relay id
// proven (proven). The nonce is compared, not just the device: a request
// that a writer which does not know the row replaced under another code
// never inherits the entry. An undecodable row is
// ErrRelaySlotLinksUndecodable (the route is unknown), a failed read its own
// error.
func RelaySlotPendingTx(tx *sql.Tx, device, nonce string) (slot, proven bool, err error) {
	r, err := readRelaySlotLinks(tx)
	if err != nil {
		return false, false, err
	}
	e, ok := r.Pending[slotID(device)]
	if nonce == "" || !ok || e.Nonce != nonce {
		return false, false, nil
	}
	return true, e.Proven, nil
}

// MarkRelaySlotRequestTx records how device's request, just saved under the
// code nonce, came in: through a pairing slot (slot), with its relay id
// proven or not, or not through one (its entry goes; proven is then
// ignored).
func MarkRelaySlotRequestTx(tx *sql.Tx, device, nonce string, slot, proven bool) error {
	return updateRelaySlotLinks(tx, func(r *relaySlotLinks) {
		id := slotID(device)
		if !slot {
			delete(r.Pending, id)
			return
		}
		if r.Pending == nil {
			r.Pending = map[string]slotRequest{}
		}
		r.Pending[id] = slotRequest{Nonce: nonce, Proven: proven}
	})
}

// ConfirmRelaySlotLinkTx is the confirm that linked device under the code
// nonce (which is also the link's devices.link_nonce): linked through a slot
// when its waiting request came through one under that nonce with its relay
// id proven, otherwise (a CloudKit link or re-link, an unproven slot link)
// not. The pending entry goes either way.
func ConfirmRelaySlotLinkTx(tx *sql.Tx, device, nonce string) error {
	return updateRelaySlotLinks(tx, func(r *relaySlotLinks) {
		id := slotID(device)
		e, ok := r.Pending[id]
		marked := ok && nonce != "" && e.Nonce == nonce && e.Proven
		delete(r.Pending, id)
		delete(r.Linked, id)
		if marked {
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
	if r.droppedV1 > 0 {
		log.Printf("hub state: %s: %d unproven Relay link marks of an older build dropped", MetaRelaySlotLinks, r.droppedV1)
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
	for id, e := range r.Pending {
		if n, ok := waiting[slotID(id)]; !ok || n != e.Nonce {
			delete(r.Pending, id)
		}
	}
	if len(r.Linked) == 0 && len(r.Pending) == 0 {
		return DeleteMetaTx(tx, MetaRelaySlotLinks)
	}
	r.V = relaySlotLinksVersion
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
