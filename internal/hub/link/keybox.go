package link

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"strings"
	"time"

	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
)

// Confirm is the owner's answer to the request device waits with, showing
// code (the four-digit code the owner compared). ok=false refuses it
// (not_confirmed; the link code stays open) whatever code it shows now.
// ok=true on a request whose code is no longer code (a newer or replayed
// hello replaced it) links nothing and keeps it waiting: ErrCodeChanged (the
// Swift confirmLink(deviceID:sas:)). Otherwise it re-checks the link code
// in the same transaction that links: still valid, the phone is linked with
// its keys and link nonce, the code is used, and every other waiting request
// is refused used_code (F17); expired or used meanwhile, the phone gets that
// refusal and no keys. ErrNoRequest when nothing waits (it was refused,
// unlinked or swept first).
func (c *Center) Confirm(device, code string, ok bool) error {
	c.mu.Lock()
	defer c.unlock()
	now := c.now()
	var (
		request pendingDevice
		reason  string
		others  []pendingDevice
		linked  bool
	)
	err := c.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		p, found, err := pendingTx(tx, device)
		if err != nil {
			return err
		}
		if !found {
			return ErrNoRequest
		}
		request = p
		if ok && p.sas != code {
			return ErrCodeChanged
		}
		if !ok {
			reason = wire.RefusedNotConfirmed
			return refusePending(tx, p, reason, now)
		}
		stored, kept, err := linkCodeTx(tx, p.linkNonce)
		if err != nil {
			return err
		}
		switch d, why := decide(stored, kept, p.deviceID, now); d {
		case decisionRefused:
			reason = why
			return refusePending(tx, p, reason, now)
		case decisionUsedByThisDevice:
			_, err := tx.Exec(`DELETE FROM pending_devices WHERE device_id = ? COLLATE NOCASE`, p.deviceID)
			return err
		case decisionValid:
		}
		if err := linkPending(tx, p, now); err != nil {
			return err
		}
		linked = true
		rest, err := pendingDevicesTx(tx)
		if err != nil {
			return err
		}
		for _, o := range rest {
			if err := refusePending(tx, o, wire.RefusedUsedCode, now); err != nil {
				return err
			}
		}
		others = rest
		return nil
	})
	if errors.Is(err, ErrNoRequest) {
		return err
	}
	if errors.Is(err, ErrCodeChanged) {
		log.Printf("hub link: link request of %s changed before Link: kept for a fresh decision", request.deviceID)
		return err
	}
	if err != nil {
		return fmt.Errorf("link: confirming a request: %w", err)
	}
	switch {
	case linked:
		log.Printf("hub link: linked phone %s, %d other requests refused", request.deviceID, len(others))
		c.emit(PairEvent{Kind: EventLinked, DeviceID: request.deviceID, Name: request.name})
		for _, o := range others {
			c.emit(PairEvent{Kind: EventRefused, DeviceID: o.deviceID, Name: o.name, Reason: wire.RefusedUsedCode})
		}
		c.changed()
	case reason != "":
		log.Printf("hub link: link request of %s refused (%s)", request.deviceID, reason)
		c.refusedEvent(request, reason)
	}
	return nil
}

// linkPending links p in tx (the Swift linkDevice + the key columns): the
// code is marked used by it, its row written with its keys and link nonce —
// a re-link keeps the owner's grants and decision time and restarts its
// action order — and its refusal, revoked row, rollback marks and held
// actions are forgotten (they belong to the old link nonce's relay keys).
func linkPending(tx *sql.Tx, p pendingDevice, now time.Time) error {
	id := strings.ToUpper(p.deviceID)
	d := state.Device{
		ID: id, Name: p.name, Scope: p.scope, LinkedAt: now, SigningKey: p.signingKey, AgreementKey: p.agreementKey,
		LinkNonce: p.linkNonce, TypingRequested: p.typingRequested, StartSessionsAllowed: p.startSessions,
		RelayDeviceID: p.relayDeviceID,
	}
	var decided sql.NullFloat64
	err := tx.QueryRow(`SELECT typing_allowed, permissions_allowed, permissions_requested, start_sessions_granted, decided_at
		FROM devices WHERE device_id = ? COLLATE NOCASE`, id).
		Scan(&d.TypingAllowed, &d.PermissionsAllowed, &d.PermissionsRequested, &d.StartSessionsGranted, &decided)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return err
	}
	if _, err := tx.Exec(`UPDATE link_codes SET used_by_device = ?, used_at = ? WHERE nonce = ?`, id, secs(now), p.linkNonce); err != nil {
		return err
	}
	if err := state.LinkDevice(tx, d); err != nil {
		return err
	}
	if decided.Valid {
		if _, err := tx.Exec(`UPDATE devices SET decided_at = ? WHERE device_id = ?`, decided.Float64, id); err != nil {
			return err
		}
	}
	for _, q := range []string{
		`DELETE FROM link_refusals WHERE device_id = ? COLLATE NOCASE`,
		`DELETE FROM revoked_devices WHERE device_id = ? COLLATE NOCASE`,
		`DELETE FROM relay_seen WHERE sender_id = ? COLLATE NOCASE`,
		`DELETE FROM held_actions WHERE device_id = ? COLLATE NOCASE`,
		`DELETE FROM pending_devices WHERE device_id = ? COLLATE NOCASE`,
	} {
		if _, err := tx.Exec(q, id); err != nil {
			return err
		}
	}
	return nil
}
