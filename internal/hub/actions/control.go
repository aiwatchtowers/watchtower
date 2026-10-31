package actions

import (
	"context"
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"
	"log"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// The control queue and the phone's controls (Go hub spec §8 p. 3, relay sim
// rules 6, 7a and 15). The control kinds are wire.Control*; the hub writes
// resend_from and transport_switch_rejected in phase 1 (transport_switched
// and hub_on_relay come with the switch, phase 3) and reads skip_to,
// epoch_ack and transport_switch.

// switchNotSupported is transport_switch_rejected's reason while the hub
// cannot switch transports (phase 1): the phone stops waiting at once.
const switchNotSupported = "not supported yet"

// sealControl seals c as a hub control c-<uuid> for b's phone: a new id, and
// device_id and hub_id naming the phone and this hub. It is queued with
// ExpectAbsent (a new record).
func (p *Processor) sealControl(b mailbox, c wire.Control) (queued, error) {
	id, err := newUUID()
	if err != nil {
		return queued{}, err
	}
	device, hub := b.id.String(), p.cfg.Keys.HubID().String()
	c.ID, c.DeviceID, c.HubID = id, &device, &hub
	payload, err := wire.Marshal(c)
	if err != nil {
		return queued{}, err
	}
	plain := "c-" + id
	name, err := p.cfg.Sealer.WireName(secure.ZoneRelay, plain)
	if err != nil {
		return queued{}, err
	}
	rec, err := p.cfg.Sealer.ToPhone(b.zone, b.id, name, kindControl, plain, payload)
	if err != nil {
		return queued{}, fmt.Errorf("actions: sealing %s: %w", c.Kind, err)
	}
	return queued{rec: rec, kind: c.Kind, expect: expectAbsent}, nil
}

// sealResendFrom seals a resend_from(from) control for b.
func (p *Processor) sealResendFrom(b mailbox, from uint64) (queued, error) {
	return p.sealControl(b, wire.Control{Kind: wire.ControlResendFrom, Seq: &from})
}

// newUUID is a random v4 UUID in Swift's uuidString form.
func newUUID() (string, error) {
	var id secure.ID
	if _, err := rand.Read(id[:]); err != nil {
		return "", fmt.Errorf("actions: random: %w", err)
	}
	id[6] = id[6]&0x0f | 0x40
	id[8] = id[8]&0x3f | 0x80
	return id.String(), nil
}

// phoneControl handles a phone's control record once and deletes it
// (recipient delete, sim rule 15). A control id the hub already read — its
// rollback mark exists, so this is a second copy or a re-read after a resync
// — is deleted unread. A delete that fails leaves the record to the next
// re-read or the mailbox TTL; handling it again is then skipped by the mark.
func (p *Processor) phoneControl(ctx context.Context, b mailbox, rec transport.Stored, o secure.Opened, ps *pass) error {
	_, _, seen, err := p.cfg.Store.RelaySeen(rec.Name, b.id.String())
	if err != nil {
		return err
	}
	if !seen {
		if err := p.readControl(ctx, b, rec, o, ps); err != nil {
			return err
		}
	}
	p.deleteControl(ctx, b, rec)
	return nil
}

// readControl decides one phone control: its rollback mark commits with the
// decision, so the record counts as read from then on. A control that does
// not decode, names another device or hub, or has a kind the hub does not
// take from a phone is read with no effect.
func (p *Processor) readControl(ctx context.Context, b mailbox, rec transport.Stored, o secure.Opened, ps *pass) error {
	var c wire.Control
	if !decodes(o.Frame.Payload, &c) || c.ID == "" || o.Frame.ID != "c-"+c.ID ||
		c.DeviceID == nil || !sameID(*c.DeviceID, b.id) ||
		(c.HubID != nil && !sameID(*c.HubID, p.cfg.Keys.HubID())) {
		log.Printf("hub: a control of device %s is malformed or names another device or hub: dropped", b.id)
		return p.markRead(ctx, b, rec, o)
	}
	switch c.Kind {
	case wire.ControlSkipTo:
		return p.skipTo(ctx, b, rec, o, c, ps)
	case wire.ControlEpochAck:
		return p.epochAck(ctx, b, rec, o, c)
	case wire.ControlSwitch:
		return p.rejectSwitch(ctx, b, rec, o)
	}
	return p.markRead(ctx, b, rec, o)
}

// markRead commits only the rollback mark of a control read with no effect.
func (p *Processor) markRead(ctx context.Context, b mailbox, rec transport.Stored, o secure.Opened) error {
	return p.decide(ctx, b, func(tx *sql.Tx) error { return mark(tx, b, rec.Name, o) })
}

// skipTo is sim rule 6: the phone no longer has the actions before m, so the
// order continues from m — last becomes m-1 when that moves it forward — and
// the held actions that are now next are applied. m must lie within
// MaxSkipAhead of the next expected seq.
func (p *Processor) skipTo(ctx context.Context, b mailbox, rec transport.Stored, o secure.Opened, c wire.Control, ps *pass) error {
	device := b.id.String()
	dev, linked, err := p.cfg.Store.Device(device)
	if err != nil || !linked {
		return err
	}
	if dev.LinkNonce != b.link {
		return errRelinked
	}
	if c.Seq == nil || *c.Seq == 0 {
		log.Printf("hub: skip_to of device %s without a seq: dropped", b.id)
		return p.markRead(ctx, b, rec, o)
	}
	m := *c.Seq
	if m > dev.LastAppliedActionSeq+1+MaxSkipAhead {
		log.Printf("hub: skip_to of device %s jumps past the order window: dropped", b.id)
		return p.markRead(ctx, b, rec, o)
	}
	if err := p.decide(ctx, b, func(tx *sql.Tx) error {
		if err := mark(tx, b, rec.Name, o); err != nil {
			return err
		}
		if m > dev.LastAppliedActionSeq+1 {
			return state.SetLastApplied(tx, device, m-1)
		}
		return nil
	}); err != nil {
		return err
	}
	return p.drainHeld(ctx, b, ps)
}

// epochAck records the newest hub epoch the phone confirmed (never lowered;
// an epoch the hub has not reached is ignored). Phase 3's key retirement
// reads it (sim rule 14).
func (p *Processor) epochAck(ctx context.Context, b mailbox, rec transport.Stored, o secure.Opened, c wire.Control) error {
	current, err := p.cfg.Keys.CurrentEpoch()
	if err != nil {
		return err
	}
	if c.Epoch == nil || *c.Epoch > current {
		log.Printf("hub: epoch_ack of device %s without an epoch the hub has: dropped", b.id)
		return p.markRead(ctx, b, rec, o)
	}
	epoch, device := *c.Epoch, b.id.String()
	return p.decide(ctx, b, func(tx *sql.Tx) error {
		if err := mark(tx, b, rec.Name, o); err != nil {
			return err
		}
		return state.AckEpoch(tx, device, epoch)
	})
}

// rejectSwitch answers a phone's transport_switch with
// transport_switch_rejected("not supported yet"), queued in the transaction
// that reads the request (so it is retried until written); the hub's
// transport does not change. Phase 3 implements the switch (sim rules 8–16).
func (p *Processor) rejectSwitch(ctx context.Context, b mailbox, rec transport.Stored, o secure.Opened) error {
	reason := switchNotSupported
	q, err := p.sealControl(b, wire.Control{Kind: wire.ControlSwitchRejected, Reason: &reason})
	if err != nil {
		return err
	}
	if err := p.decide(ctx, b, func(tx *sql.Tx) error {
		if err := mark(tx, b, rec.Name, o); err != nil {
			return err
		}
		return state.Enqueue(tx, q.control(b.zone))
	}); err != nil {
		return err
	}
	log.Printf("hub: device %s asked for a transport switch: rejected, not supported yet", b.id)
	return nil
}

// deleteControl deletes a phone control the hub read, under the version read.
func (p *Processor) deleteControl(ctx context.Context, b mailbox, rec transport.Stored) {
	out, err := p.cfg.Transport.Delete(ctx, b.zone, []transport.DeleteItem{{
		Name: rec.Name, Expect: transport.Expect{Mode: transport.ExpectSeq, Seq: rec.RecordSeq},
	}})
	if err != nil || len(out) != 1 || !out[0].Saved {
		log.Printf("hub: a control of device %s was not deleted (%s)", b.id, deleteClass(err, out))
	}
}

func deleteClass(err error, out []transport.Outcome) string {
	switch {
	case err != nil:
		return errClass(err)
	case len(out) != 1:
		return "no_outcome"
	case out[0].Refused != nil:
		return errClass(out[0].Refused)
	default:
		return "changed"
	}
}

// FlushControls writes every linked phone's queued echoes and controls, in
// queue order per mailbox (sim rule 7a). A row that does not land stays
// queued, counts an attempt with its error class and stops its mailbox until
// the next pass (so order holds); a row refused for good (refusedForGood) is
// dropped with its class logged and the mailbox goes on. A row whose record
// changed meanwhile is dropped — the phone's newer copy comes through the
// feed and is answered then — except that an echo replaces the hub's own
// older record at its name.
func (p *Processor) FlushControls(ctx context.Context) (written, failed int, err error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.flushAll(ctx)
}

func (p *Processor) flushAll(ctx context.Context) (written, failed int, err error) {
	boxes, err := p.mailboxes()
	if err != nil {
		return 0, 0, err
	}
	var errs []error
	for _, b := range boxes {
		w, f, err := p.flushMailbox(ctx, b)
		written, failed = written+w, failed+f
		if err != nil {
			// One phone's failure never holds back the others' queues.
			log.Printf("hub: flushing device %s's mailbox: %s", b.id, errClass(err))
			errs = append(errs, err)
		}
	}
	return written, failed, errors.Join(errs...)
}

// flushMailbox writes b's queue in order; failed counts rows that did not
// land this time (the first one stops the mailbox).
func (p *Processor) flushMailbox(ctx context.Context, b mailbox) (written, failed int, err error) {
	zone := b.zone
	rows, err := p.cfg.Store.PendingControls(zone)
	if err != nil {
		return 0, 0, err
	}
	for _, c := range rows {
		rec, err := p.cfg.Opener.Requeue(zone, b.id, c.RecordName, c.Envelope)
		if err != nil {
			if !droppable(err) {
				return written, failed, err
			}
			// The phone could not open it either (its keys are gone): drop it.
			log.Printf("hub: dropping queued %s %d: %s", c.Kind, c.ID, errClass(err))
			if err := p.cfg.Store.ControlDone(c.ID); err != nil {
				return written, failed, err
			}
			continue
		}
		landed, err := p.writeQueued(ctx, b, c, rec)
		if err != nil {
			return written, failed, err
		}
		if !landed {
			return written, failed + 1, nil
		}
		written++
	}
	return written, failed, nil
}

// refusedForGood reports a write the transport will never take, whatever the
// retries: the record is too large, or this hub may not write that mailbox.
// Everything else waits in the queue: an outage or rate limit passes, a full
// mailbox empties as the phone deletes what it read, and a lapsed
// entitlement or an outdated protocol waits for the switch (phase 3) or an
// update rather than losing the write.
func refusedForGood(err error) bool {
	return errors.Is(err, transport.ErrRecordTooLarge) || errors.Is(err, transport.ErrForbidden)
}

// writeQueued saves one of b's queued rows; landed is false when it must
// wait for the next pass (the row is marked failed with its error class). A
// dropped row counts as landed: it is gone from the queue. A resend_from
// dropped for good also forgets that its gap was asked, so the gap is asked
// again rather than stalled.
func (p *Processor) writeQueued(ctx context.Context, b mailbox, c state.Control, rec secure.Record) (landed bool, err error) {
	expect := transport.Expect{Mode: transport.ExpectNone}
	switch c.Expect {
	case state.ExpectAbsent:
		expect.Mode = transport.ExpectAbsent
	case state.ExpectSeq:
		expect = transport.Expect{Mode: transport.ExpectSeq, Seq: c.ExpectSeq}
	}
	for attempt := 0; ; attempt++ {
		out, err := p.cfg.Transport.Save(ctx, []transport.SaveItem{{Record: rec, Expect: expect}})
		if err == nil && len(out) != 1 {
			err = errors.New("actions: save answered no outcome")
		}
		if err == nil && out[0].Refused != nil {
			err = out[0].Refused
		}
		if err != nil {
			if ctx.Err() != nil {
				return false, ctx.Err()
			}
			if refusedForGood(err) {
				log.Printf("hub: dropping queued %s %d, refused for good: %s", c.Kind, c.ID, errClass(err))
				if c.Kind == wire.ControlResendFrom {
					return true, p.cfg.Store.DropResendFrom(c.ID, b.id.String())
				}
				return true, p.cfg.Store.ControlDone(c.ID)
			}
			return false, p.cfg.Store.ControlFailed(c.ID, errClass(err))
		}
		o := out[0]
		if o.Saved {
			return true, p.cfg.Store.ControlDone(c.ID)
		}
		// A failed precondition: an echo replaces the hub's own older record
		// at its name (a held echo before the final one); anything else means
		// the phone changed the record, and its copy is answered when read.
		if c.Kind == queueEcho && attempt == 0 && o.Conflict != nil && p.ownRecord(o.Conflict) {
			expect = transport.Expect{Mode: transport.ExpectSeq, Seq: o.Conflict.RecordSeq}
			continue
		}
		return true, p.cfg.Store.ControlDone(c.ID)
	}
}

// ownRecord reports whether s is a record the hub wrote (one of its echoes).
func (p *Processor) ownRecord(s *transport.Stored) bool {
	_, err := p.cfg.Opener.OwnEcho(s.Zone, s.Name, s.Envelope)
	return err == nil
}
