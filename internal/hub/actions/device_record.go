package actions

import (
	"context"
	"database/sql"
	"errors"
	"log"
	"strings"

	"watchtower/internal/hub/link"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// The phone's device record (protocol §5.5, the Kit's RelayRecordKind.device):
// device-<DEVICE_ID> in its mailbox, rewritten by the phone whenever its name
// or one of its toggles changes, never deleted by the hub. The Swift hub's
// RelayProcessor hands it to MobileLinkCenter.handleDevice; here the link
// center applies it (link.Center.ApplyDeviceRecord). Read in CloudKit's
// shared RelayZone only: the relay path is unchanged.

const (
	kindDevice   = "device"
	devicePrefix = "device-"
)

// Links is what a phone's device record drives in the link center
// (link.Center).
type Links interface {
	ApplyDeviceRecord(ctx context.Context, device string, r link.DeviceRecord) error
}

// handleDeviceRecord applies a device record opened as b's phone's (handle
// has checked that its name, device-<id>, is the sender). It acts only for
// that phone — the payload's device_id must be the authenticated sender too
// (a linked phone writing another's unlink or start-sessions choice is
// dropped) — and a payload carrying a link nonce asks for a link, which only
// a hello makes. The link center checks the record against the link (scope)
// and applies an unlink or a rewrite. The record's rollback mark commits
// after it was applied, so a crash in between applies it again (the rewrite
// is idempotent) and an older copy is refused (ErrRolledBack in FromPhone).
// With no Links the record is left alone, as the Swift hub leaves it with no
// link center.
func (p *Processor) handleDeviceRecord(ctx context.Context, b mailbox, rec transport.Stored, o secure.Opened) error {
	if p.cfg.Links == nil {
		return nil
	}
	var d wire.DevicePayload
	if !decodes(o.Frame.Payload, &d) {
		log.Printf("hub: undecodable device record of device %s dropped", b.id)
		return nil
	}
	if !strings.HasPrefix(o.Frame.ID, devicePrefix) || !sameID(d.DeviceID, b.id) {
		log.Printf("hub: a device record of device %s names another phone: sender_mismatch", b.id)
		return nil
	}
	if d.LinkNonce != nil && *d.LinkNonce != "" && (d.Unlinked == nil || !*d.Unlinked) {
		log.Printf("hub: device record of device %s carries a code: a link needs a hello, ignored", b.id)
		return p.markRead(ctx, b, rec, o)
	}
	if err := p.cfg.Links.ApplyDeviceRecord(ctx, b.id.String(), link.DeviceRecord{Payload: d}); err != nil {
		return err
	}
	err := p.decide(ctx, b, func(tx *sql.Tx) error { return mark(tx, b, rec.Name, o) })
	if errors.Is(err, errRelinked) {
		return nil // unlinked (by this record, or meanwhile): nothing to mark
	}
	return err
}
