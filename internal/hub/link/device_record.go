package link

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"strings"

	"watchtower/internal/hub/secure"
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
// own revoke, spec §10). A rewrite for another toggle keeps a grant. A
// record naming the phone's relay identity with its proof
// (VerifyRelayIDProof) gives the phone that relay id, taking it off any other
// linked phone (takeRelayID); an unproven id is logged by class and ignored,
// and the rest of the rewrite applies.
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
	if !accepts(row, r) || !acceptsCreator(row.Scope, storedUser, r.Creator) {
		log.Printf("hub link: device record of phone %s not written by its linked phone: ignored", strings.ToUpper(device))
		return nil
	}
	matches, err := c.deviceCreatorMatches(ctx, r)
	if err != nil {
		return err // no decision: the record is read again next pass
	}
	if !matches {
		log.Printf("hub link: device record of phone %s not written by its linked phone: ignored", strings.ToUpper(device))
		return nil
	}
	if r.Payload.Unlinked != nil && *r.Payload.Unlinked {
		log.Printf("hub link: phone %s unlinked itself", strings.ToUpper(device))
		return c.unlinkItself(ctx, r.Shares, device)
	}
	return c.rewrite(ctx, device, r.Payload)
}

// unlinkItself is a phone's own unlink through BeginRemove: on CloudKit
// (shares set) its iCloud user leaves the shares at once (the processor's
// pass already runs off any owner request, so it waits for the share
// calls here), elsewhere it is Unlink. A participant removal that failed is
// left to the sweep.
func (c *Center) unlinkItself(ctx context.Context, shares transport.Shares, device string) error {
	finish, err := c.BeginRemove(ctx, device)
	if errors.Is(err, state.ErrNoDevice) {
		return nil
	}
	if err != nil {
		return err
	}
	finish(ctx, shares)
	return nil
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
// by the Mac's user (creatorMatches, the owner read through r.Shares). An
// owner read that fails on a transport that can name the owner is no answer:
// ErrOwnerUnreadable, so the caller leaves the record undecided. A transport
// that cannot name it (no CloudUser) is a refusal, as before.
func (c *Center) deviceCreatorMatches(ctx context.Context, r DeviceRecord) (bool, error) {
	owner := ""
	if r.Payload.Scope == wire.ScopePrivate && r.Creator != "" && r.Creator != transport.CurrentUserCreator && r.Shares != nil {
		owner = c.owner(ctx, r.Shares)
		if _, canName := r.Shares.(transport.CloudUser); canName && owner == "" {
			return false, ErrOwnerUnreadable
		}
	}
	return creatorMatches(r.Payload, r.Creator, owner), nil
}

// ErrOwnerUnreadable says the Mac's iCloud user could not be read just now, so a
// device record's creator could not be checked. The record is not decided;
// the processor leaves it unmarked and reads it again next pass.
var ErrOwnerUnreadable = errors.New("link: the Mac's iCloud user is unreadable")

// rewrite is ApplyDeviceRecord's rewrite of a linked phone.
func (c *Center) rewrite(ctx context.Context, device string, p wire.DevicePayload) error {
	c.mu.Lock()
	defer c.unlock()
	var asked, typingRevoked, permsRevoked, changed, relayNamed, relayMoved bool
	var askedName, relayRefused string
	err := c.st.WithTx(ctx, func(tx *sql.Tx) error {
		var (
			name, storedRelay                       string
			typingAllowed, typingReq                bool
			permsAllowed, permsReq, startAllowedNow bool
		)
		err := tx.QueryRow(`SELECT name, typing_allowed, typing_requested,
			permissions_allowed, permissions_requested, start_sessions_allowed, ifnull(relay_device_id, '')
			FROM devices WHERE device_id = ? COLLATE NOCASE`, device).Scan(
			&name, &typingAllowed, &typingReq, &permsAllowed, &permsReq, &startAllowedNow, &storedRelay)
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
		askedName = newName
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
		if err != nil {
			return err
		}
		relayNamed, relayMoved, relayRefused, err = c.takeRelayID(tx, device, storedRelay, p)
		return err
	})
	if err != nil {
		return fmt.Errorf("applying a phone's device record: %w", err)
	}
	if asked {
		log.Printf("hub link: phone %s asks to type into sessions", strings.ToUpper(device))
		c.typingAsks = append(c.typingAsks, TypingAsk{DeviceID: strings.ToUpper(device), Name: askedName})
	}
	if typingRevoked {
		log.Printf("hub link: phone %s turned typing off: grant revoked", strings.ToUpper(device))
		c.revoked = append(c.revoked, device)
	}
	if permsRevoked {
		log.Printf("hub link: phone %s turned permission answers off: grant revoked", strings.ToUpper(device))
	}
	if relayRefused != "" {
		log.Printf("hub link: phone %s relay id ignored: %s", strings.ToUpper(device), relayRefused)
	}
	if relayMoved {
		log.Printf("hub link: phone %s relay id: %s", strings.ToUpper(device), relayIDMoved)
	}
	if relayNamed {
		log.Printf("hub link: phone %s named its relay id", strings.ToUpper(device))
		c.relayNamed = append(c.relayNamed, strings.ToUpper(device))
	}
	if changed {
		c.changed()
	}
	return nil
}

// The classes of a relay id that went elsewhere: relayIDTaken, a hello named
// an id another row holds (linkPending) and links without it; relayIDMoved, a
// proven record took its id off another row.
const (
	relayIDTaken = "held_by_another"
	relayIDMoved = "moved_from_another"
)

// takeRelayID stores the relay id p names for device, in the rewrite's
// transaction, when its proof holds. Only the holder of the relay_auth key can
// sign the proof, so the id is device's: any other row holding it (a stale
// link of the same phone, an unproven hello) loses it, and one relay id names
// one phone again. A store clears the relay admission stamp; moved says a row
// lost the id. A record naming no relay identity changes nothing and logs
// nothing; refused is the class of a bad proof, and named says the readers
// and the account state are due again.
func (c *Center) takeRelayID(tx *sql.Tx, device, stored string, p wire.DevicePayload) (named, moved bool, refused string, err error) {
	if p.RelayDeviceID == "" && p.RelayAuthPub == "" && p.RelayIDSig == "" {
		return false, false, "", nil
	}
	devID, perr := secure.ParseID(device)
	if perr != nil { // the processor names linked phones by their parsed id: never here
		return false, false, relayIDInvalid, nil //nolint:nilerr // a refusal class, not a failure
	}
	id, class := checkRelayIDProof(c.keys.HubID(), devID, p)
	if class != "" {
		return false, false, class, nil
	}
	n, err := state.ClearRelayDeviceIDTx(tx, id, device)
	if err != nil {
		return false, false, "", err
	}
	if id == stored {
		return n > 0, n > 0, "", nil
	}
	return true, n > 0, "", state.SetRelayDeviceIDTx(tx, device, id)
}
