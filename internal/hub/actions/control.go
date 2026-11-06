package actions

import (
	"bytes"
	"context"
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"time"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// The control queue and the phone's controls (Go hub spec §8 p. 3, relay sim
// rules 6, 7a and 15). The control kinds are wire.Control*; the hub writes
// resend_from and transport_switch_rejected, transport_switched and
// hub_on_relay (the switcher's, through SealControlFor and Stale), and reads
// skip_to, epoch_ack and transport_switch.

// SwitchNotSupported is transport_switch_rejected's reason on a hub that
// cannot switch transports (no Switch): the phone stops waiting at once.
const SwitchNotSupported = wire.SwitchNotSupported

// Switch is the hub's transport switcher as a processor sees it
// (internal/hub/switcher). A hub without one (headless, relay-only) answers
// every transport_switch "not supported yet". With one, the hub runs a
// processor per transport and each owns its own queue keys.
type Switch interface {
	// Active reports whether k is the transport the hub applies actions
	// from. On any other a processor applies nothing (sim rule 12a): it
	// answers a phone's action with Stale's control and leaves the record
	// to the phone, and reads only transport_switch, epoch_ack and the
	// phones' device records.
	IsActive(k transport.Kind) bool
	// Request is a phone's transport_switch toward target (from = its
	// device id): nil accepts it, *SwitchRejected rejects it, any other
	// error leaves it for the next pass. It must not call back into a
	// processor (it runs inside a pass).
	Request(ctx context.Context, from string, target transport.Kind, reason string) error
	// Stale is the answer to device's action read on the inactive
	// transport k: the control to queue there and the epoch to seal it in
	// (0 = the current one), or ok false for none. Called once per record
	// version; it must not call back into a processor.
	Stale(ctx context.Context, k transport.Kind, device string) (c wire.Control, epoch uint32, ok bool, err error)
	// Lapsed reports whether device's relay entitlement is lapsed on k now
	// while the hub stays on the relay for another paying phone (sim rule
	// 16): its actions and uploads are left to the phone, which was told
	// hub_on_relay over CloudKit; its controls are read as usual. seq is
	// the ordered action being read (0 = none), remembered as sent before
	// the lapse.
	Lapsed(k transport.Kind, device string, seq uint64) (bool, error)
	// Skipped reports whether a record of device on k was sent before its
	// last lapse ended (the phone was told it is not delivered): an ordered
	// action by its seq, a legacy action or an upload by writtenAt (the
	// transport's ServerAt). Such an action is answered expired, never
	// applied (the phone's retry is a new action, relay client spec §5 p.
	// 6, protocol §7 p. 7).
	Skipped(k transport.Kind, device string, seq uint64, writtenAt time.Time) (bool, error)
	// EntitlementInactive reports a hub write into device's mailbox on k
	// refused with transport.ErrEntitlementInactive (sim rule 16): the
	// switcher records it and decides it in its next Step, outside the pass:
	// it must neither read the relay nor call back into a processor.
	EntitlementInactive(k transport.Kind, device string)
}

// SwitchRejected is Switch.Request's refusal: the reason and the wait the
// phone gets in transport_switch_rejected (0 = no retry_after_s).
type SwitchRejected struct {
	Reason     string
	RetryAfter time.Duration
}

func (e *SwitchRejected) Error() string { return "transport switch rejected: " + e.Reason }

// SealControlFor seals c for device's mailbox on this processor's transport
// as a control_queue row, in epoch (0 = the current one), keeping c's id
// when it has one (one control id, a copy per transport). ok is false when
// the phone has no mailbox here (not linked, or no relay device id on the
// hosted relay). The caller enqueues the row (state.Enqueue).
func (p *Processor) SealControlFor(device string, c wire.Control, epoch uint32) (row state.Control, ok bool, err error) {
	boxes, err := p.mailboxes()
	if err != nil {
		return state.Control{}, false, err
	}
	for _, b := range boxes {
		if !sameID(device, b.id) {
			continue
		}
		sealer := p.cfg.Sealer
		if epoch != 0 {
			sealer = sealer.InEpoch(epoch)
		}
		q, err := p.sealControlIn(sealer, b, c)
		if err != nil {
			return state.Control{}, false, err
		}
		return q.control(b.queue), true, nil
	}
	return state.Control{}, false, nil
}

// QueueOf is device's control_queue key on this processor's transport; ok
// is false when the phone has no mailbox here.
func (p *Processor) QueueOf(device string) (queue string, ok bool, err error) {
	boxes, err := p.mailboxes()
	if err != nil {
		return "", false, err
	}
	for _, b := range boxes {
		if sameID(device, b.id) {
			return b.queue, true, nil
		}
	}
	return "", false, nil
}

// sealControl seals c as a hub control c-<uuid> for b's phone: a new id, and
// device_id and hub_id naming the phone and this hub. It is queued with
// ExpectAbsent (a new record).
func (p *Processor) sealControl(b mailbox, c wire.Control) (queued, error) {
	c.ID = ""
	return p.sealControlIn(p.cfg.Sealer, b, c)
}

// sealControlIn is sealControl with sealer (the Sealer, or one pinned to an
// older epoch) and c's own id when it has one: the switcher writes one
// control id as two copies, one per transport.
func (p *Processor) sealControlIn(sealer *secure.Sealer, b mailbox, c wire.Control) (queued, error) {
	if c.ID == "" {
		id, err := newUUID()
		if err != nil {
			return queued{}, err
		}
		c.ID = id
	}
	device, hub := b.id.String(), p.cfg.Keys.HubID().String()
	c.DeviceID, c.HubID = &device, &hub
	payload, err := wire.Marshal(c)
	if err != nil {
		return queued{}, err
	}
	plain := "c-" + c.ID
	name, err := sealer.WireName(secure.ZoneRelay, plain)
	if err != nil {
		return queued{}, err
	}
	rec, err := sealer.ToPhone(b.zone, b.id, name, kindControl, plain, payload)
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
		if p.cfg.Switch == nil {
			return p.rejectSwitch(ctx, b, rec, o)
		}
		return p.requestSwitch(ctx, b, rec, o, c)
	}
	return p.markRead(ctx, b, rec, o)
}

// markRead commits only the rollback mark of a control read with no effect.
func (p *Processor) markRead(ctx context.Context, b mailbox, rec transport.Stored, o secure.Opened) error {
	return p.decide(ctx, b, func(tx *sql.Tx) error { return mark(tx, b, rec.Name, o) })
}

// skipTo is sim rule 6: the phone no longer has the actions before m, so the
// order continues from m — last becomes m-1 when that moves it forward — and
// the held actions that are now next are applied, unless the phone lapsed or
// the hub is on standby. m must lie within MaxSkipAhead of the next expected
// seq. Each seq passed is answered in the
// ledger: a late copy of one is told expired (as sim rule 16's are), never
// applied, and a repeat's stored answer goes back to the phone.
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
	skipped := Outcome{Status: wire.StatusExpired, Reason: reasonExpired}
	stored, err := encodeStored(skipped)
	if err != nil {
		return err
	}
	now := p.cfg.Clock()
	if err := p.decide(ctx, b, func(tx *sql.Tx) error {
		if err := mark(tx, b, rec.Name, o); err != nil {
			return err
		}
		if m <= dev.LastAppliedActionSeq+1 {
			return nil
		}
		for seq := dev.LastAppliedActionSeq + 1; seq < m; seq++ {
			key := b.ledger(actionName(b.id, seq))
			if err := state.MarkSkippedIfAbsent(tx, key, ledgerOutcome(skipped), stored, now); err != nil {
				return err
			}
		}
		return state.SetLastApplied(tx, device, m-1)
	}); err != nil {
		return err
	}
	return p.drainHeldActive(ctx, b, ps)
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

// requestSwitch hands a phone's transport_switch to the hub's switcher
// (sim rules 8–10). Accepted, the request is marked read and the switcher
// carries the switch out after the pass; rejected (*SwitchRejected), the
// phone gets transport_switch_rejected with the reason and retry_after_s,
// queued with the read mark; any other error (the switcher could not record
// it) is answered the same way with wire.SwitchUnavailable and
// SwitchRetryAfter, so the phone asks again and the mailbox never waits on
// it. A target that is no transport is read with no effect.
func (p *Processor) requestSwitch(ctx context.Context, b mailbox, rec transport.Stored, o secure.Opened, c wire.Control) error {
	if c.Target == nil || (*c.Target != wire.TransportRelay && *c.Target != wire.TransportCloudKit) {
		log.Printf("hub: a transport_switch of device %s names no transport: dropped", b.id)
		return p.markRead(ctx, b, rec, o)
	}
	reason := ""
	if c.Reason != nil {
		reason = *c.Reason
	}
	err := p.cfg.Switch.Request(ctx, b.id.String(), transport.Kind(*c.Target), reason)
	var rej *SwitchRejected
	if err != nil && !errors.As(err, &rej) {
		log.Printf("hub: device %s asked for a transport switch: not recorded (%s)", b.id, errClass(err))
		rej = &SwitchRejected{Reason: wire.SwitchUnavailable, RetryAfter: SwitchRetryAfter}
	}
	switch {
	case err == nil:
		return p.markRead(ctx, b, rec, o)
	default:
		why := rej.Reason
		ctl := wire.Control{Kind: wire.ControlSwitchRejected, Reason: &why}
		if rej.RetryAfter > 0 {
			secs := uint32((rej.RetryAfter + time.Second - 1) / time.Second)
			ctl.RetryAfterS = &secs
		}
		q, err := p.sealControl(b, ctl)
		if err != nil {
			return err
		}
		if err := p.decide(ctx, b, func(tx *sql.Tx) error {
			if err := mark(tx, b, rec.Name, o); err != nil {
				return err
			}
			return state.Enqueue(tx, q.control(b.queue))
		}); err != nil {
			return err
		}
		log.Printf("hub: device %s asked for a transport switch: rejected, %s", b.id, why)
		return nil
	}
}

// SwitchRetryAfter is the wait a phone gets with wire.SwitchUnavailable.
const SwitchRetryAfter = time.Minute

// rejectSwitch answers a phone's transport_switch with
// transport_switch_rejected("not supported yet"), queued in the transaction
// that reads the request (so it is retried until written); the hub's
// transport does not change. A hub without a switcher (a headless,
// relay-only hub) keeps this answer.
func (p *Processor) rejectSwitch(ctx context.Context, b mailbox, rec transport.Stored, o secure.Opened) error {
	reason := SwitchNotSupported
	q, err := p.sealControl(b, wire.Control{Kind: wire.ControlSwitchRejected, Reason: &reason})
	if err != nil {
		return err
	}
	if err := p.decide(ctx, b, func(tx *sql.Tx) error {
		if err := mark(tx, b, rec.Name, o); err != nil {
			return err
		}
		return state.Enqueue(tx, q.control(b.queue))
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
	if p.paused.Load() {
		return 0, 0, nil
	}
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
	// Rows queued while the phone's mailbox had the other shape (its own
	// zone ↔ the shared one) join its queue, in their order: their envelopes
	// are bound to the relay zone, not to a transport's zone name.
	if n, err := p.cfg.Store.RekeyControls(b.oldQueues, b.queue); err != nil {
		return 0, 0, err
	} else if n > 0 {
		log.Printf("hub: %d queued records of device %s moved to its current mailbox", n, b.id)
	}
	rows, err := p.cfg.Store.PendingControls(b.queue)
	if err != nil {
		return 0, 0, err
	}
	batch := make([]queuedRow, 0, len(rows))
	for _, c := range rows {
		rec, err := p.cfg.Opener.Requeue(zone, b.id, c.RecordName, c.Envelope)
		if err != nil {
			if !droppable(err) {
				return 0, 0, err
			}
			// The phone could not open it either (its keys are gone): drop it.
			log.Printf("hub: dropping queued %s %d: %s", c.Kind, c.ID, errClass(err))
			if err := p.cfg.Store.ControlDone(c.ID); err != nil {
				return 0, 0, err
			}
			continue
		}
		batch = append(batch, queuedRow{c: c, rec: rec, expect: expectOf(c)})
	}
	batch = collapseEchoes(batch)
	for len(batch) > 0 {
		n := min(len(batch), saveBatch)
		w, f, err := p.writeQueued(ctx, b, batch[:n], true)
		written, failed = written+w, failed+f
		if err != nil || f > 0 {
			return written, failed, err
		}
		batch = batch[n:]
	}
	return written, failed, nil
}

// saveBatch is the most queued rows one Save carries (a long outage's queue
// goes out in several, in order).
const saveBatch = 50

// queuedRow is one queued row to save: its control row, the record resealed
// for the mailbox and the precondition it is written under. superseded is
// the ids of the earlier echoes of the same record it stands for
// (collapseEchoes), settled with it. landed marks a row already written, saved
// again after a row re-saved ahead of it (writeQueued's tail): it stays
// queued until that save lands, so a failed tail never leaves it ahead.
type queuedRow struct {
	c          state.Control
	rec        secure.Record
	expect     transport.Expect
	superseded []int64
	landed     bool
}

// expectOf is the transport precondition of queued row c.
func expectOf(c state.Control) transport.Expect {
	switch c.Expect {
	case state.ExpectAbsent:
		return transport.Expect{Mode: transport.ExpectAbsent}
	case state.ExpectSeq:
		return transport.Expect{Mode: transport.ExpectSeq, Seq: c.ExpectSeq}
	}
	return transport.Expect{Mode: transport.ExpectNone}
}

// collapseEchoes folds the queued echoes of one record (a held echo and the
// final one, a received echo and the final one) into one row: the last
// echo's content, at the last one's place in the queue, under the last one's
// precondition when it names a record version (a repeat of a phone's newer
// copy), else under the latest version an earlier one names (the final echo
// of a held action, queued "replace the hub's own held echo", takes the
// version the held echo was written over). So a phone's newer copy still
// wins, and an earlier echo that already landed is the hub's own record,
// written over (writeQueued). The
// earlier rows leave the queue when that row is settled; until then they
// stay, so a row that waits is folded the same way next time. A phone never
// needs an intermediate echo once a later one is owed: one batch never
// carries two writes of one record, so a partly written batch cannot leave an
// older echo over a newer one.
func collapseEchoes(rows []queuedRow) []queuedRow {
	first := map[string]int{} // record name → index of its first echo
	last := map[string]int{}
	for i, r := range rows {
		if r.c.Kind != queueEcho {
			continue
		}
		if _, ok := first[r.c.RecordName]; !ok {
			first[r.c.RecordName] = i
		}
		last[r.c.RecordName] = i
	}
	out := make([]queuedRow, 0, len(rows))
	for i, r := range rows {
		if r.c.Kind != queueEcho || first[r.c.RecordName] == last[r.c.RecordName] {
			out = append(out, r)
			continue
		}
		if i != last[r.c.RecordName] {
			continue
		}
		var read *transport.Expect // the latest record version an earlier echo was written over
		for j := first[r.c.RecordName]; j < i; j++ {
			if e := rows[j]; e.c.Kind == queueEcho && e.c.RecordName == r.c.RecordName {
				r.superseded = append(r.superseded, e.c.ID)
				if e.expect.Mode == transport.ExpectSeq {
					read = &e.expect
				}
			}
		}
		if r.expect.Mode != transport.ExpectSeq && read != nil {
			r.expect = *read
		}
		out = append(out, r)
	}
	return out
}

// refusedForGood reports a write the transport will never take, whatever the
// retries: the record is too large, or this hub may not write that mailbox.
// Everything else waits in the queue: an outage or rate limit passes, a full
// mailbox empties as the phone deletes what it read, and an outdated
// protocol waits for an update rather than losing the write. A lapsed
// entitlement waits too: with a switcher it is reported
// (Switch.EntitlementInactive) and the switcher moves the phone's owed
// echoes over CloudKit (sim rule 16); without one (a headless hub) the row
// waits for the phone to pay again.
func refusedForGood(err error) bool {
	return errors.Is(err, transport.ErrRecordTooLarge) || errors.Is(err, transport.ErrForbidden)
}

// writeQueued saves b's queued rows, in queue order, in one Save (the relay
// writes a batch's items in request order, each on its own), and settles each
// row by its outcome:
//   - written: done;
//   - a failed precondition over the hub's own identical record: it landed in
//     an earlier, partly written batch — done;
//   - a failed precondition over the hub's own older record at its name (an
//     echo after the hub's held or received echo): written again over it,
//     when retry is set; so the phone's feed keeps the queue order, every row
//     after it that landed is written again too, after it (the tail Save), and
//     leaves the queue only with that save;
//   - any other failed precondition: the phone changed the record, and its
//     copy is answered when read — done;
//   - refused: notLanded.
//
// written counts the rows that left the queue, failed the rows that wait for
// the next pass.
//
// A Save that fails as a whole may have written part of the batch (relay
// proto, Save): nothing is settled, the first row is marked failed and the
// mailbox waits for the next pass, which reads the mailbox before it writes
// again; a row that did land then meets its own record (above). A
// whole-batch refusal for good (a record too large, a forbidden mailbox)
// names no row: the rows are then saved one at a time, so only the refused
// one is dropped.
func (p *Processor) writeQueued(ctx context.Context, b mailbox, rows []queuedRow, retry bool) (written, failed int, err error) {
	if len(rows) == 0 {
		return 0, 0, nil
	}
	items := make([]transport.SaveItem, len(rows))
	for i, r := range rows {
		items[i] = transport.SaveItem{Record: r.rec, Expect: r.expect}
	}
	out, err := p.cfg.Transport.Save(ctx, items)
	if err == nil && len(out) != len(rows) {
		err = fmt.Errorf("actions: save answered %d outcomes for %d rows", len(out), len(rows))
	}
	if err != nil {
		return p.batchFailed(ctx, b, rows, retry, err)
	}
	var tail []queuedRow
	for i, o := range out {
		r := rows[i]
		if r.landed {
			// Written before, saved again after a row re-saved ahead of it:
			// it leaves the queue now, with the row it follows.
			if err := p.settle(r); err != nil {
				return written, failed, err
			}
			written++
			continue
		}
		switch {
		case o.Refused != nil:
			landed, err := p.notLanded(b, r, o.Refused)
			if err != nil {
				return written, failed, err
			}
			if !landed {
				failed++
				continue
			}
		case o.Saved || (o.Conflict != nil && bytes.Equal(o.Conflict.Envelope, r.rec.Envelope())):
			// Written now, or in an earlier, partly written batch.
			if len(tail) > 0 {
				seq := o.RecordSeq
				if !o.Saved {
					seq = o.Conflict.RecordSeq
				}
				r.expect, r.landed = transport.Expect{Mode: transport.ExpectSeq, Seq: seq}, true
				tail = append(tail, r)
				continue
			}
			if err := p.settle(r); err != nil {
				return written, failed, err
			}
		case retry && r.c.Kind == queueEcho && o.Conflict != nil && p.ownRecord(b, o.Conflict):
			r.expect = transport.Expect{Mode: transport.ExpectSeq, Seq: o.Conflict.RecordSeq}
			tail = append(tail, r)
			continue
		default:
			if err := p.settle(r); err != nil {
				return written, failed, err
			}
		}
		written++
	}
	w, f, err := p.writeQueued(ctx, b, tail, false)
	return written + w, failed + f, err
}

// batchFailed handles a Save of rows that failed as a whole (see
// writeQueued). A landed row of a tail stays queued as it is: the next pass
// meets it as its own identical record, behind the row re-saved ahead of it.
func (p *Processor) batchFailed(ctx context.Context, b mailbox, rows []queuedRow, retry bool, err error) (written, failed int, _ error) {
	if ctx.Err() != nil {
		return 0, 0, ctx.Err()
	}
	if len(rows) > 1 && refusedForGood(err) {
		for i := range rows {
			w, f, err := p.writeQueued(ctx, b, rows[i:i+1], retry)
			written, failed = written+w, failed+f
			if err != nil || f > 0 {
				return written, failed, err
			}
		}
		return written, failed, nil
	}
	for _, r := range rows {
		if r.landed {
			continue
		}
		landed, err := p.notLanded(b, r, err)
		if landed {
			return 1, 0, err
		}
		return 0, 1, err
	}
	return 0, 0, nil
}

// settle removes r's row and the echoes it superseded from the queue.
func (p *Processor) settle(r queuedRow) error {
	for _, id := range append([]int64{r.c.ID}, r.superseded...) {
		if err := p.cfg.Store.ControlDone(id); err != nil {
			return err
		}
	}
	return nil
}

// notLanded settles a row the transport did not write: landed is false when
// it must wait for the next pass (the row is marked failed with its error
// class; the echoes it superseded stay with it). A row refused for good is
// dropped and counts as landed: it is gone from the queue. A resend_from
// dropped for good also forgets that its gap was asked, so the gap is asked
// again rather than stalled.
func (p *Processor) notLanded(b mailbox, r queuedRow, err error) (landed bool, serr error) {
	c := r.c
	if refusedForGood(err) {
		log.Printf("hub: dropping queued %s %d, refused for good: %s", c.Kind, c.ID, errClass(err))
		if c.Kind == wire.ControlResendFrom {
			return true, p.cfg.Store.DropResendFrom(c.ID, b.id.String())
		}
		return true, p.settle(r)
	}
	if p.cfg.Switch != nil && errors.Is(err, transport.ErrEntitlementInactive) {
		// Sim rule 16: the phone's relay entitlement lapsed. The switcher
		// moves what is owed to it over CloudKit.
		p.cfg.Switch.EntitlementInactive(p.cfg.Transport.Kind(), b.id.String())
	}
	return false, p.cfg.Store.ControlFailed(c.ID, errClass(err))
}

// ownRecord reports whether s is a record the hub wrote for b (one of its echoes).
func (p *Processor) ownRecord(b mailbox, s *transport.Stored) bool {
	_, err := p.ownEcho(b, s.Name, s.Envelope)
	return err == nil
}
