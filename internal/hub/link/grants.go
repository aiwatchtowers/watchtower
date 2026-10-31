package link

import (
	"context"
	"database/sql"
	"encoding/base64"
	"fmt"
	"strings"
	"time"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/wire"
)

// Grants is the device_grant slice's rows: Keyboxes without the keys.
func (c *Center) Grants() ([]wire.DeviceGrant, error) {
	boxes, err := c.Keyboxes()
	if err != nil {
		return nil, err
	}
	out := make([]wire.DeviceGrant, 0, len(boxes))
	for _, kb := range boxes {
		out = append(out, kb.Grant)
	}
	return out, nil
}

// Keyboxes is the device_grant slice (the Swift DeviceGrantSlice), one keybox
// per phone the hub answers, sealed later to that phone's key under
// keybox-<id>: every linked phone (never capped, newest link first; only a
// phone linked through a confirmed hello carries the epoch keys), then the
// waiting requests (awaiting_confirmation, confirm_nonce, link_code_tag),
// the refusals younger than RefusalLifetime and the revoked phones younger
// than RevokedLifetime, each newest first, filling what is left of
// MaxGrantRecords. A phone appears once: linked, waiting, refused, revoked.
// Every grant announces ordered_actions 1, the hub's transports and its relay
// identity. It holds the center's lock across the device read and the key
// read, so an Unlink (which rotates) never lands between them: a phone read
// as linked gets the keys of the epoch it was linked under, never the one
// that removes it.
func (c *Center) Keyboxes() ([]wire.Keybox, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.now()
	var linked, rest []wire.Keybox
	keyed := false
	err := c.st.ReadTx(context.Background(), func(tx *sql.Tx) error {
		var err error
		if linked, keyed, err = c.linkedRows(tx); err != nil {
			return err
		}
		answered := map[string]bool{}
		for _, r := range linked {
			answered[r.Grant.DeviceID] = true
		}
		pending, err := pendingDevicesTx(tx)
		if err != nil {
			return err
		}
		for i := len(pending) - 1; i >= 0; i-- {
			p := pending[i]
			if g, ok := c.newGrant(p.deviceID, answered); ok {
				g.Name, g.Scope = p.name, p.scope
				nonce := base64.RawURLEncoding.EncodeToString(p.confirmNonce)
				g.AwaitingConfirmation, g.ConfirmNonce = ptr(true), &nonce
				if raw, err := base64.RawURLEncoding.DecodeString(p.linkNonce); err == nil {
					g.LinkCodeTag = ptr(secure.LinkCodeTag(raw))
				}
				rest = append(rest, wire.Keybox{Grant: g})
			}
		}
		refused, err := c.refusedRows(tx, now, answered)
		if err != nil {
			return err
		}
		rest = append(rest, refused...)
		revoked, err := c.revokedRows(tx, now, answered)
		if err != nil {
			return err
		}
		rest = append(rest, revoked...)
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("link: reading the grants: %w", err)
	}
	if c.beforeKeys != nil {
		c.beforeKeys()
	}
	if keyed {
		keys, err := c.keys.KeyboxKeys()
		if err != nil {
			return nil, fmt.Errorf("link: keybox keys: %w", err)
		}
		for i := range linked {
			if linked[i].Keys != nil {
				k := keys
				linked[i].Keys = &k
			}
		}
	}
	room := max(0, MaxGrantRecords-len(linked))
	return append(linked, rest[:min(room, len(rest))]...), nil
}

// newGrant is the grant every row starts from; ok is false for a phone
// already answered by an earlier kind (the device id is recorded uppercase).
func (c *Center) newGrant(device string, answered map[string]bool) (wire.DeviceGrant, bool) {
	id := strings.ToUpper(device)
	if answered[id] {
		return wire.DeviceGrant{}, false
	}
	answered[id] = true
	return wire.DeviceGrant{
		DeviceID: id, HubID: c.keys.HubID().String(), StartSessionsAllowed: true, StartSessionsGranted: ptr(false),
		OrderedActions: ptr(1), Transports: append([]string(nil), c.host.Transports...),
		RelayDeviceID: c.host.RelayDeviceID, RelayAuthPub: c.host.RelayAuthPub,
	}, true
}

// linkedRows are the linked phones, newest link first. A keyed phone's row
// carries a placeholder Keys the caller fills; keyed is true when any does.
func (c *Center) linkedRows(tx *sql.Tx) ([]wire.Keybox, bool, error) {
	rows, err := tx.Query(`SELECT device_id, name, scope, linked_at, decided_at, typing_allowed, start_sessions_allowed,
		start_sessions_granted, permissions_allowed, agreement_key IS NOT NULL AND link_nonce IS NOT NULL
		FROM devices ORDER BY linked_at DESC, device_id DESC`)
	if err != nil {
		return nil, false, err
	}
	defer rows.Close()
	var (
		out      []wire.Keybox
		anyKeyed bool
		answered = map[string]bool{}
	)
	for rows.Next() {
		var (
			id, name, scope                    string
			linkedAt                           float64
			decided                            sql.NullFloat64
			typing, startAllowed, startGranted bool
			permissions, keyed                 bool
		)
		if err := rows.Scan(&id, &name, &scope, &linkedAt, &decided, &typing, &startAllowed, &startGranted,
			&permissions, &keyed); err != nil {
			return nil, false, err
		}
		g, ok := c.newGrant(id, answered)
		if !ok {
			continue
		}
		at := fromReal(linkedAt)
		g.Name, g.Scope, g.Linked, g.LinkedAt = name, scope, true, &wire.Time{Time: at}
		g.TypingAllowed, g.StartSessionsAllowed = typing, startAllowed
		g.StartSessionsGranted = ptr(startGranted && typing && startAllowed)
		if permissions {
			g.PermissionsAllowed = ptr(true)
		}
		if decided.Valid {
			g.DecidedAt = &wire.Time{Time: fromReal(decided.Float64)}
		}
		row := wire.Keybox{Grant: g}
		if keyed {
			row.Keys, anyKeyed = &wire.KeyboxKeys{}, true
		}
		out = append(out, row)
	}
	return out, anyKeyed, rows.Err()
}

// refusedRows are the refusals younger than RefusalLifetime, newest first;
// decided_at is the refusal's time, so a second identical refusal still
// reads as a new answer.
func (c *Center) refusedRows(tx *sql.Tx, now time.Time, answered map[string]bool) ([]wire.Keybox, error) {
	rows, err := tx.Query(`SELECT device_id, name, scope, reason, at FROM link_refusals WHERE at >= ?
		ORDER BY at DESC, device_id`, secs(now.Add(-RefusalLifetime)))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []wire.Keybox
	for rows.Next() {
		var (
			id, name, scope, reason string
			at                      float64
		)
		if err := rows.Scan(&id, &name, &scope, &reason, &at); err != nil {
			return nil, err
		}
		g, ok := c.newGrant(id, answered)
		if !ok {
			continue
		}
		t := fromReal(at)
		g.Name, g.Scope, g.LinkRefused, g.DecidedAt = name, scope, &reason, &wire.Time{Time: t}
		out = append(out, wire.Keybox{Grant: g})
	}
	return out, rows.Err()
}

// revokedRows are the unlinked phones younger than RevokedLifetime, newest
// first: linked false, revoked true, never keys.
func (c *Center) revokedRows(tx *sql.Tx, now time.Time, answered map[string]bool) ([]wire.Keybox, error) {
	rows, err := tx.Query(`SELECT device_id, COALESCE(name, ''), COALESCE(scope, ?), removed_at FROM revoked_devices
		WHERE removed_at > ? ORDER BY removed_at DESC, device_id`, wire.ScopePrivate, secs(now.Add(-RevokedLifetime)))
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []wire.Keybox
	for rows.Next() {
		var (
			id, name, scope string
			removed         float64
		)
		if err := rows.Scan(&id, &name, &scope, &removed); err != nil {
			return nil, err
		}
		g, ok := c.newGrant(id, answered)
		if !ok {
			continue
		}
		t := fromReal(removed)
		g.Name, g.Scope, g.Revoked, g.DecidedAt = name, scope, ptr(true), &wire.Time{Time: t}
		out = append(out, wire.Keybox{Grant: g})
	}
	return out, rows.Err()
}

func ptr[T any](v T) *T { return &v }
