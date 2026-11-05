package actions

import (
	"context"
	"database/sql"
	"errors"
	"log"
	"strings"
	"time"

	"watchtower/internal/hub/link"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// The phone's device record (protocol §5.5, the Kit's RelayRecordKind.device):
// device-<DEVICE_ID> in its mailbox, rewritten by the phone whenever its name
// or one of its toggles changes, never deleted by the hub. The Swift hub's
// RelayProcessor hands it to MobileLinkCenter.handleDevice; here the link
// center applies it (link.Center.ApplyDeviceRecord). Read in CloudKit's shared
// RelayZone and in a phone's own mailbox on the hosted relay.

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
// a hello makes. The link center checks the record against the link (scope and CloudKit creator)
// and applies an unlink or a rewrite. The record's rollback mark commits
// after it was applied, so a crash in between applies it again (the rewrite
// is idempotent) and an older copy is refused (ErrRolledBack in FromPhone).
// With no Links the record is left alone, as the Swift hub leaves it with no
// link center. A record that is no unlink is a phone contact (Config.Contact).
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
	if d.Unlinked == nil || !*d.Unlinked {
		// The phone says when it was last in touch; an unlink is no
		// contact, and a replayed old record is no contact now.
		at := d.UpdatedAt.Time
		if d.SeenAt != nil {
			at = d.SeenAt.Time
		}
		p.contact(minTime(at, p.cfg.Clock()))
	}
	if d.LinkNonce != nil && *d.LinkNonce != "" && (d.Unlinked == nil || !*d.Unlinked) {
		log.Printf("hub: device record of device %s carries a code: a link needs a hello, ignored", b.id)
		return p.markRead(ctx, b, rec, o)
	}
	if o.Verdict == secure.Same {
		// This version was already decided and marked, whether it applied or
		// was ignored (ApplyDeviceRecord returns nil for both). A re-delivery
		// (a re-read zone) must not replay an old proof, which would take a
		// relay id back from the phone it moved to. The proof carries no time;
		// the mark is what dates it. A creator check that could not read the
		// owner is an error, not a decision: no mark is written, the verdict
		// stays newer and the next pass applies the record in full.
		d.RelayDeviceID, d.RelayAuthPub, d.RelayIDSig = "", "", ""
	}
	shares, _ := p.cfg.Transport.(transport.Shares)
	r := link.DeviceRecord{Payload: d, Creator: rec.Creator, Shares: shares, Hosted: !b.shared,
		Superseded: func(tx *sql.Tx) (bool, error) { return supersededTx(tx, rec.Name, o) }}
	if err := p.cfg.Links.ApplyDeviceRecord(ctx, b.id.String(), r); err != nil {
		if o.Verdict == secure.Same && errors.Is(err, link.ErrOwnerUnreadable) {
			return nil // decided and marked already: nothing to do, nothing to hold
		}
		return err
	}
	err := p.decide(ctx, b, func(tx *sql.Tx) error { return mark(tx, b, rec.Name, o) })
	if errors.Is(err, errRelinked) {
		return nil // unlinked (by this record, or meanwhile): nothing to mark
	}
	return err
}

// supersededTx reports whether a newer version of the record than o is marked
// by now: the other transport's processor applied one after o was opened.
func supersededTx(tx *sql.Tx, wireName string, o secure.Opened) (bool, error) {
	epoch, seq, ok, err := state.RelaySeenTx(tx, wireName, o.Sender.String())
	if err != nil || !ok {
		return false, err
	}
	return secure.CompareVersion(epoch, seq, o.Epoch, o.Seq) == secure.Older, nil
}

// minTime is the earlier of a and b.
func minTime(a, b time.Time) time.Time {
	if a.Before(b) {
		return a
	}
	return b
}
