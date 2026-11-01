package link

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"strings"

	"watchtower/internal/hub/wire"
)

// PhoneRewrite applies a linked phone's own rewrite of its device record
// (protocol §5.5; the Swift MobileLinkCenter.handleLinkedRewrite) other than
// an unlink, which is Unlink: its name replaces the stored one, its
// start_sessions toggle becomes start_sessions_allowed (its opt-out, never
// the owner's grant), its typing and permission requests are stored for the
// owner to decide — a request is never a grant — and a request going from on
// to off revokes that grant (the phone's own revoke, spec §10). A rewrite for
// another toggle keeps a grant. user_record_name is kept for the participant
// sweep. The caller has bound p to device (the record's authenticated
// sender). A device that is not linked, or a payload whose scope is not the
// link's, changes nothing.
func (c *Center) PhoneRewrite(device string, p wire.DevicePayload) error {
	c.mu.Lock()
	defer c.unlock()
	var asked, typingRevoked, permsRevoked, changed bool
	err := c.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		var (
			name, scope, userRecord                 string
			typingAllowed, typingReq                bool
			permsAllowed, permsReq, startAllowedNow bool
		)
		err := tx.QueryRow(`SELECT name, scope, user_record_name, typing_allowed, typing_requested,
			permissions_allowed, permissions_requested, start_sessions_allowed
			FROM devices WHERE device_id = ? COLLATE NOCASE`, device).Scan(
			&name, &scope, &userRecord, &typingAllowed, &typingReq, &permsAllowed, &permsReq, &startAllowedNow)
		if errors.Is(err, sql.ErrNoRows) {
			return nil
		}
		if err != nil {
			return err
		}
		if p.Scope != scope {
			log.Printf("hub link: device record of phone %s not written in its link's scope: ignored", strings.ToUpper(device))
			return nil
		}
		permsWanted := p.PermissionsRequested != nil && *p.PermissionsRequested
		newName := displayName(p.Name)
		if p.UserRecordName != "" {
			userRecord = p.UserRecordName
		}
		revokeTyping := !p.TypingRequested && typingReq && typingAllowed
		revokePerms := !permsWanted && permsReq && permsAllowed
		asked = p.TypingRequested && !typingAllowed && !typingReq
		changed = newName != name || p.StartSessions != startAllowedNow || revokeTyping || revokePerms ||
			p.TypingRequested != typingReq || permsWanted != permsReq
		typingRevoked, permsRevoked = revokeTyping, revokePerms
		// A grant column the phone changed stamps decided_at, as the Swift
		// setGrant does; a request alone decides nothing.
		decided := revokeTyping || revokePerms || p.StartSessions != startAllowedNow
		_, err = tx.Exec(`UPDATE devices SET name = ?, user_record_name = ?, start_sessions_allowed = ?,
			typing_requested = ?, permissions_requested = ?,
			typing_allowed = typing_allowed AND NOT ?, permissions_allowed = permissions_allowed AND NOT ?,
			decided_at = CASE WHEN ? THEN ? ELSE decided_at END
			WHERE device_id = ? COLLATE NOCASE`,
			newName, userRecord, p.StartSessions, p.TypingRequested, permsWanted, revokeTyping, revokePerms,
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
