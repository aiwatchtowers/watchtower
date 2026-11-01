package link

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"strings"

	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// DeviceRecord is a linked phone's own device record (protocol §5.5) as the
// processor read it: the payload, already bound to the record's
// authenticated sender, the record's CloudKit creator (Stored.Creator, ""
// when the transport gives none) and the transport it came from, whose
// CloudUser names the Mac's iCloud user (nil: unknown).
type DeviceRecord struct {
	Payload wire.DevicePayload
	Creator string
	Shares  transport.Shares
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
	var storedUser string
	if err := c.st.ReadTx(ctx, func(tx *sql.Tx) error {
		return tx.QueryRow(`SELECT user_record_name FROM devices WHERE device_id = ? COLLATE NOCASE`, device).Scan(&storedUser)
	}); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil
		}
		return fmt.Errorf("reading a phone's link: %w", err)
	}
	if !accepts(row, r) || !acceptsCreator(row.Scope, storedUser, r.Creator) ||
		!c.deviceCreatorMatches(ctx, r) {
		log.Printf("hub link: device record of phone %s not written by its linked phone: ignored", strings.ToUpper(device))
		return nil
	}
	if r.Payload.Unlinked != nil && *r.Payload.Unlinked {
		log.Printf("hub link: phone %s unlinked itself", strings.ToUpper(device))
		return c.unlinkItself(ctx, r.Shares, device)
	}
	return c.rewrite(ctx, device, r.Payload)
}

// unlinkItself is a phone's own unlink: on CloudKit (shares set) through
// RemoveCloudKit, so its iCloud user leaves the shares at once, elsewhere
// Unlink. A participant removal that failed once the phone was unlinked is
// no error here: RemoveCloudKit logged it and the sweep removes it later.
func (c *Center) unlinkItself(ctx context.Context, shares transport.Shares, device string) error {
	var err error
	if shares != nil {
		err = c.RemoveCloudKit(ctx, shares, device)
	} else {
		err = c.Unlink(device)
	}
	if err == nil || errors.Is(err, state.ErrNoDevice) {
		return nil
	}
	if _, linked, rerr := c.st.Device(device); rerr == nil && !linked {
		return nil
	}
	return err
}

// accepts is the Swift hub's check that a device record comes from the
// phone's link: written in the link's scope.
func accepts(row state.Device, r DeviceRecord) bool {
	return r.Payload.Scope == row.Scope
}

// acceptsCreator is the Swift LinkedDevice.accepts(creator:) (the device
// gate's creator check, spec §5.2 rule 4): in shared scope the record's
// creator is the phone's user record name stored at the link; in private
// scope no creator (a transport that names none), the current-user name or
// the stored name.
func acceptsCreator(scope, storedUser, creator string) bool {
	if scope == wire.ScopeShared {
		return creator != "" && creator == storedUser
	}
	if creator == "" {
		return true
	}
	return creator == transport.CurrentUserCreator || (storedUser != "" && creator == storedUser)
}

// deviceCreatorMatches is the Swift creatorMatches for a device record: a
// shared phone's record was created by the user it names, a private phone's
// by the Mac's user (creatorMatches, the owner read through r.Shares).
func (c *Center) deviceCreatorMatches(ctx context.Context, r DeviceRecord) bool {
	owner := ""
	if r.Payload.Scope == wire.ScopePrivate && r.Creator != "" && r.Creator != transport.CurrentUserCreator && r.Shares != nil {
		owner = c.owner(ctx, r.Shares)
	}
	return creatorMatches(r.Payload, r.Creator, owner)
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
