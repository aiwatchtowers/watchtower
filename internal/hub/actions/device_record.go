package actions

import (
	"context"
	"database/sql"
	"errors"
	"log"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// The phone's device record (protocol §5.5, the Kit's RelayRecordKind.device):
// device-<DEVICE_ID> in its mailbox, rewritten by the phone whenever its name
// or one of its toggles changes, never deleted by the hub. The Swift hub's
// RelayProcessor hands it to MobileLinkCenter.handleDevice; here the link
// center (link.Center) applies it.

const (
	kindDevice   = "device"
	devicePrefix = "device-"
)

// Links is what a phone's device record drives in the link center
// (link.Center): an unlink, or the phone's rewrite of its name, toggles and
// requests.
type Links interface {
	Unlink(device string) error
	PhoneRewrite(device string, p wire.DevicePayload) error
}

// handleDeviceRecord applies a device record opened as b's phone's: it acts
// only for that phone — the payload's device_id and the record's name must
// both be the authenticated sender (a linked phone writing another's unlink
// or start-sessions choice is dropped) — and a payload carrying a link nonce
// asks for a link, which only a hello makes. unlinked: true unlinks the phone
// (Links.Unlink: its keys rotate out); any other rewrite is
// Links.PhoneRewrite, where a request is stored for the owner, never a grant.
// The record's rollback mark commits after it was applied, so a crash in
// between applies it again (the rewrite is idempotent) and an older copy is
// refused (ErrRolledBack in FromPhone). With no Links the record is left
// alone, as the Swift hub leaves it with no link center.
func (p *Processor) handleDeviceRecord(ctx context.Context, b mailbox, rec transport.Stored, o secure.Opened) error {
	if p.cfg.Links == nil {
		return nil
	}
	var d wire.DevicePayload
	if !decodes(o.Frame.Payload, &d) {
		log.Printf("hub: undecodable device record of device %s dropped", b.id)
		return nil
	}
	if !sameID(d.DeviceID, b.id) || o.Frame.ID != devicePrefix+b.id.String() {
		log.Printf("hub: a device record of device %s names another phone: sender_mismatch", b.id)
		return nil
	}
	if d.LinkNonce != nil && *d.LinkNonce != "" && (d.Unlinked == nil || !*d.Unlinked) {
		log.Printf("hub: device record of device %s carries a code: a link needs a hello, ignored", b.id)
		return p.markRead(ctx, b, rec, o)
	}
	device := b.id.String()
	if d.Unlinked != nil && *d.Unlinked {
		// The unlink removes the device's rollback marks with its row; there
		// is no link left to mark the record under.
		err := p.cfg.Links.Unlink(device)
		if errors.Is(err, state.ErrNoDevice) {
			return nil
		}
		if err != nil {
			return err
		}
		log.Printf("hub: phone %s unlinked itself", b.id)
		return nil
	}
	if err := p.cfg.Links.PhoneRewrite(device, d); err != nil {
		return err
	}
	err := p.decide(ctx, b, func(tx *sql.Tx) error { return mark(tx, b, rec.Name, o) })
	if errors.Is(err, errRelinked) {
		return nil // unlinked or linked again meanwhile: nothing to mark
	}
	return err
}
