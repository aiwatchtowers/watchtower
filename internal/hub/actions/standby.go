package actions

import (
	"context"
	"database/sql"
	"log"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// Standby (relay sim rule 12a): with a switcher the hub runs a processor per
// transport, and only the active transport's applies anything. The other one
// is polled for the phones' controls (sim rule 11): a transport_switch and an
// epoch_ack are read as on the active side, and so are CloudKit's device
// records (a phone may unlink while the hub runs on the relay). Every other
// phone record — an action, an upload, another control — is left to the
// phone, never applied, deleted or marked: a phone that has not followed the
// switch gets the switcher's answer (transport_switched again or
// hub_on_relay), once per record version, and its outbox resends the same
// bytes on the transport it follows to (sim rule 13), where the ledger
// applies each action once.

// maxStaleSeen caps the standby answer table; it is cleared when full.
const maxStaleSeen = 4096

// standby reports whether this processor's transport is not the hub's
// active one.
func (p *Processor) standby() bool {
	return p.cfg.Switch != nil && !p.cfg.Switch.IsActive(p.cfg.Transport.Kind())
}

// lapsed reports whether b's phone lapsed on this transport (sim rule 16,
// Switch.Lapsed): none of its actions or uploads is applied here.
func (p *Processor) lapsed(b mailbox) bool {
	return p.cfg.Switch != nil && p.cfg.Switch.Lapsed(p.cfg.Transport.Kind(), b.id.String())
}

// drainHeldActive drains b's held actions and retries its held uploads,
// on the active transport only and never for a lapsed phone: on standby
// nothing is applied.
func (p *Processor) drainHeldActive(ctx context.Context, b mailbox, ps *pass) error {
	if p.standby() || p.lapsed(b) {
		return nil
	}
	if err := p.drainHeld(ctx, b, ps); err != nil {
		return err
	}
	return p.retryUploads(ctx, b, ps)
}

// onStandby routes one opened phone record on standby: left is true when it
// was left to the phone (answered at most once per record version); false
// for the records read as on the active side.
func (p *Processor) onStandby(ctx context.Context, b mailbox, rec transport.Stored, o secure.Opened) (left bool) {
	switch o.Frame.Kind {
	case kindDevice:
		return false
	case kindControl:
		var c wire.Control
		if decodes(o.Frame.Payload, &c) && (c.Kind == wire.ControlSwitch || c.Kind == wire.ControlEpochAck) {
			return false
		}
	case kindAction, kindRecordingUpload:
	default:
		return true // an unknown kind has no work on either side
	}
	p.answerStale(ctx, b, rec)
	return true
}

// answerStale queues the switcher's answer to a record b's phone left on
// this standby transport, once per record version. An answer that cannot be
// made (the switcher, sealing or the queue failed) is logged and left for
// the record's next version: it never stalls the mailbox.
func (p *Processor) answerStale(ctx context.Context, b mailbox, rec transport.Stored) {
	key := b.zone + "\x00" + rec.Name
	if seq, ok := p.staleSeen[key]; ok && seq == rec.RecordSeq {
		return
	}
	c, epoch, ok, err := p.cfg.Switch.Stale(ctx, p.cfg.Transport.Kind(), b.id.String())
	if err != nil {
		log.Printf("hub: device %s wrote on the standby transport: no answer (%s)", b.id, errClass(err))
		return
	}
	if ok {
		sealer := p.cfg.Sealer
		if epoch != 0 {
			sealer = sealer.InEpoch(epoch)
		}
		q, err := p.sealControlIn(sealer, b, c)
		if err == nil {
			err = p.cfg.Store.WithTx(ctx, func(tx *sql.Tx) error { return state.Enqueue(tx, q.control(b.queue)) })
		}
		if err != nil {
			log.Printf("hub: device %s wrote on the standby transport: no answer (%s)", b.id, errClass(err))
			return
		}
		log.Printf("hub: device %s wrote on the standby %s transport: answered %s", b.id, p.cfg.Transport.Kind(), c.Kind)
	}
	if p.staleSeen == nil || len(p.staleSeen) >= maxStaleSeen {
		p.staleSeen = map[string]uint64{}
	}
	p.staleSeen[key] = rec.RecordSeq
}

// MailboxZones lists the phone mailbox zones on this processor's transport
// (the switcher rewinds them in its own transaction, state.SetZoneTokenTx).
func (p *Processor) MailboxZones() ([]string, error) {
	boxes, err := p.mailboxes()
	if err != nil {
		return nil, err
	}
	var out []string
	for _, g := range byZone(boxes) {
		out = append(out, g.zone)
	}
	return out, nil
}

// Rewind resets the stored change tokens of every phone mailbox on this
// processor's transport, so its next pass reads each mailbox from the start:
// the switcher calls it when the transport becomes active, so the records
// left there on standby are read now (repeats are answered from the ledger,
// never applied twice).
func (p *Processor) Rewind() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	boxes, err := p.mailboxes()
	if err != nil {
		return err
	}
	for _, g := range byZone(boxes) {
		if err := p.cfg.Store.SetZoneToken(g.zone, 0); err != nil {
			return err
		}
	}
	p.staleSeen = nil
	return nil
}
