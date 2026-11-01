package link

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"strings"

	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
)

// DeviceRecord is a linked phone's own device record (protocol §5.5) as the
// processor read it: the payload, already bound to the record's
// authenticated sender. What the transport tells about who wrote the record
// joins it here, for the checks the Swift hub makes on it.
type DeviceRecord struct {
	Payload wire.DevicePayload
}

// ApplyDeviceRecord applies a linked phone's own rewrite of its device
// record (the Swift MobileLinkCenter.handleLinkedRewrite). It acts only when
// device is linked and the record passes accepts (the link's scope); then
// unlinked: true is the phone's own unlink (Unlink: its keys rotate out),
// and any other rewrite replaces its name, mirrors its start_sessions toggle
// into start_sessions_allowed (its opt-out, never the owner's grant), stores
// its typing and permission requests for the owner — a request is never a
// grant — and revokes a grant whose request goes from on to off (the phone's
// own revoke, spec §10). A rewrite for another toggle keeps a grant.
func (c *Center) ApplyDeviceRecord(ctx context.Context, device string, r DeviceRecord) error {
	row, linked, err := c.st.Device(device)
	if err != nil {
		return fmt.Errorf("reading a phone's link: %w", err)
	}
	if !linked {
		return nil
	}
	if !accepts(row, r) {
		log.Printf("hub link: device record of phone %s not written by its linked phone: ignored", strings.ToUpper(device))
		return nil
	}
	if r.Payload.Unlinked != nil && *r.Payload.Unlinked {
		log.Printf("hub link: phone %s unlinked itself", strings.ToUpper(device))
		if err := c.Unlink(device); err != nil && !errors.Is(err, state.ErrNoDevice) {
			return err
		}
		return nil
	}
	return c.rewrite(ctx, device, r.Payload)
}

// accepts is the Swift hub's check that a device record comes from the
// phone's link: written in the link's scope.
func accepts(row state.Device, r DeviceRecord) bool {
	return r.Payload.Scope == row.Scope
}

// rewrite is ApplyDeviceRecord's rewrite of a linked phone.
func (c *Center) rewrite(ctx context.Context, device string, p wire.DevicePayload) error {
	c.mu.Lock()
	defer c.unlock()
	var asked, typingRevoked, permsRevoked, changed bool
	err := c.st.WithTx(ctx, func(tx *sql.Tx) error {
		var (
			name                                    string
			typingAllowed, typingReq                bool
			permsAllowed, permsReq, startAllowedNow bool
		)
		err := tx.QueryRow(`SELECT name, typing_allowed, typing_requested,
			permissions_allowed, permissions_requested, start_sessions_allowed
			FROM devices WHERE device_id = ? COLLATE NOCASE`, device).Scan(
			&name, &typingAllowed, &typingReq, &permsAllowed, &permsReq, &startAllowedNow)
		if errors.Is(err, sql.ErrNoRows) {
			return nil // unlinked meanwhile
		}
		if err != nil {
			return err
		}
		permsWanted := p.PermissionsRequested != nil && *p.PermissionsRequested
		newName := displayName(p.Name)
		revokeTyping := !p.TypingRequested && typingReq && typingAllowed
		revokePerms := !permsWanted && permsReq && permsAllowed
		asked = p.TypingRequested && !typingAllowed && !typingReq
		changed = newName != name || p.StartSessions != startAllowedNow || revokeTyping || revokePerms ||
			p.TypingRequested != typingReq || permsWanted != permsReq
		typingRevoked, permsRevoked = revokeTyping, revokePerms
		// A grant column the phone changed stamps decided_at, as the Swift
		// setGrant does; a request alone decides nothing.
		decided := revokeTyping || revokePerms || p.StartSessions != startAllowedNow
		_, err = tx.Exec(`UPDATE devices SET name = ?, start_sessions_allowed = ?,
			typing_requested = ?, permissions_requested = ?,
			typing_allowed = typing_allowed AND NOT ?, permissions_allowed = permissions_allowed AND NOT ?,
			decided_at = CASE WHEN ? THEN ? ELSE decided_at END
			WHERE device_id = ? COLLATE NOCASE`,
			newName, p.StartSessions, p.TypingRequested, permsWanted, revokeTyping, revokePerms,
			decided, secs(c.now()), device)
		return err
	})
	if err != nil {
		return fmt.Errorf("applying a phone's device record: %w", err)
	}
	if asked {
		log.Printf("hub link: phone %s asks to type into sessions", strings.ToUpper(device))
	}
	if typingRevoked {
		log.Printf("hub link: phone %s turned typing off: grant revoked", strings.ToUpper(device))
		c.revoked = append(c.revoked, device)
	}
	if permsRevoked {
		log.Printf("hub link: phone %s turned permission answers off: grant revoked", strings.ToUpper(device))
	}
	if changed {
		c.changed()
	}
	return nil
}
