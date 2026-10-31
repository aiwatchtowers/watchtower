package actions

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"log"
	"slices"
	"strconv"
	"time"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// record is one action record as read: its wire name, sealed envelope and
// the precondition its echo overwrites it under (the version read; a held
// action applied later uses ExpectAbsent and replaces the hub's own held
// echo at that name, see writeQueued).
type record struct {
	name   string
	env    []byte
	expect state.Control
}

// actionName is an ordered action's plain record name, a-<device>-<seq>
// (RecordName(K_meta, relay, "a", "<device>-<seq>") on the wire).
func actionName(device secure.ID, seq uint64) string {
	return "a-" + device.String() + "-" + strconv.FormatUint(seq, 10)
}

// errRelinked ends the handling of a record read under a link that no
// longer stands: a re-link or unlink reset the phone's action order (and
// deleted its held actions and rollback marks), so nothing read under the old
// link may commit. The record is dropped; the new link's records are read
// fresh.
var errRelinked = errors.New("actions: the phone was re-linked or unlinked meanwhile")

// decide runs fn as a deciding transaction for b's phone: committed only
// while the link b was read under still stands (errRelinked otherwise).
func (p *Processor) decide(ctx context.Context, b mailbox, fn func(*sql.Tx) error) error {
	return p.cfg.Store.WithTx(ctx, func(tx *sql.Tx) error {
		nonce, ok, err := state.LinkNonceTx(tx, b.id.String())
		if err != nil {
			return err
		}
		if !ok || nonce != b.link {
			return errRelinked
		}
		return fn(tx)
	})
}

// mark writes the rollback mark of an opened record: called only inside the
// transaction that commits the first decision about it (a crash before
// that commit leaves the record new, so its redelivery is applied).
func mark(tx *sql.Tx, wireName string, o secure.Opened) error {
	return state.RecordSeen(tx, wireName, o.Sender.String(), o.Epoch, o.Seq)
}

// parseAction decodes an ordered action and binds it to its record: the
// sender is b's phone and the frame names a-<sender>-<action_seq>. ok is
// false for a record to drop unanswered (no decodable id to echo, or a
// payload without action_seq, which takes the legacy path of Task 10).
func parseAction(b mailbox, o secure.Opened) (a wire.ActionRequest, seq uint64, plain string, ok bool) {
	if err := json.Unmarshal(o.Frame.Payload, &a); err != nil {
		log.Printf("hub: undecodable action of device %s dropped", b.id)
		return a, 0, "", false
	}
	if a.ActionSeq == nil {
		return a, 0, "", false
	}
	seq = *a.ActionSeq
	plain = actionName(b.id, seq)
	if seq == 0 || o.Sender != b.id || o.Frame.ID != plain {
		log.Printf("hub: action of device %s names another record: dropped", b.id)
		return a, 0, "", false
	}
	return a, seq, plain, true
}

// action places one ordered action: a repeat is echoed again, one ahead of
// a gap is held, the next one is applied and then the held ones that follow.
func (p *Processor) action(ctx context.Context, b mailbox, r record, o secure.Opened, ps *pass) error {
	a, seq, plain, ok := parseAction(b, o)
	if !ok || a.Status != wire.StatusPending {
		return nil
	}
	dev, linked, err := p.cfg.Store.Device(b.id.String())
	if err != nil || !linked {
		return err
	}
	if dev.LinkNonce != b.link {
		return errRelinked
	}
	last := dev.LastAppliedActionSeq
	switch {
	case seq <= last:
		return p.repeat(ctx, b, r, o, a, plain, ps)
	case seq > last+1:
		return p.hold(ctx, b, r, o, a, seq, dev, plain, ps)
	}
	if err := p.apply(ctx, b, r, o, a, seq, plain, ps); err != nil {
		return err
	}
	return p.drainHeld(ctx, b, ps)
}

// repeat answers an action at or below the last applied seq with its stored
// final echo (applied when the ledger has none: skipped or pruned), never
// dispatching it again.
func (p *Processor) repeat(ctx context.Context, b mailbox, r record, o secure.Opened, a wire.ActionRequest, plain string, ps *pass) error {
	_, _, stored, err := p.cfg.Store.Phase(b.ledger(plain))
	if err != nil {
		return err
	}
	out, ok := decodeStored(stored)
	if !ok {
		out = Outcome{Status: wire.StatusApplied}
	}
	q, err := p.sealEcho(b, r.name, plain, a, out, r.expect)
	if err != nil {
		return err
	}
	if err := p.decide(ctx, b, func(tx *sql.Tx) error {
		if err := mark(tx, r.name, o); err != nil {
			return err
		}
		return state.Enqueue(tx, q.control(b.zone))
	}); err != nil {
		return err
	}
	ps.report.Repeats++
	ps.report.Echoed++
	return nil
}

// hold keeps an action that arrived ahead of a gap, echoes it held and asks
// for the gap once: resend_from(last+1) unless that gap was already asked.
func (p *Processor) hold(ctx context.Context, b mailbox, r record, o secure.Opened, a wire.ActionRequest, seq uint64, dev state.Device, plain string, ps *pass) error {
	echo, err := p.sealEcho(b, r.name, plain, a, Outcome{Status: wire.StatusHeld}, r.expect)
	if err != nil {
		return err
	}
	from := dev.LastAppliedActionSeq + 1
	var resend *queued
	if dev.ResendRequestedFrom != from {
		q, err := p.sealResendFrom(b, from)
		if err != nil {
			return err
		}
		resend = &q
	}
	device := b.id.String()
	if err := p.decide(ctx, b, func(tx *sql.Tx) error {
		if err := mark(tx, r.name, o); err != nil {
			return err
		}
		if err := state.Hold(tx, device, seq, r.name, r.env); err != nil {
			return err
		}
		if err := state.Enqueue(tx, echo.control(b.zone)); err != nil {
			return err
		}
		if resend == nil {
			return nil
		}
		if err := state.Enqueue(tx, resend.control(b.zone)); err != nil {
			return err
		}
		return state.SetResendRequested(tx, device, from)
	}); err != nil {
		return err
	}
	ps.budget--
	ps.report.Held++
	ps.report.Echoed++
	return nil
}

// apply decides and commits the outcome of the next action: a begun record
// (the hub stopped mid-apply) is outcome_unknown and never dispatched; the
// gates (device, hub, age, kind) answer without a handler; otherwise a
// non-idempotent kind is claimed begun first (with its received echo), the
// handler runs outside any transaction, and one transaction marks the
// record done, moves the phone's last applied seq, drops it from the held
// actions and queues the final echo.
func (p *Processor) apply(ctx context.Context, b mailbox, r record, o secure.Opened, a wire.ActionRequest, seq uint64, plain string, ps *pass) error {
	now := p.cfg.Clock()
	reg, registered := p.cfg.Dispatcher.lookup(a.Kind)
	phase, _, stored, err := p.cfg.Store.Phase(b.ledger(plain))
	if err != nil {
		return err
	}
	var out Outcome
	run := false
	switch phase {
	case state.PhaseBegun:
		out = failed(reasonOutcomeUnknown, restartedMessage)
	case state.PhaseDone: // done but the order did not move: settle it again
		var ok bool
		if out, ok = decodeStored(stored); !ok {
			out = Outcome{Status: wire.StatusApplied}
		}
	default:
		out, run = p.gate(b, a, reg, registered, now)
	}
	if run && reg.opts.NonIdempotent {
		claimed, err := p.claim(ctx, b, r, o, a, plain, reg.opts.ReceivedEcho, now, ps)
		if err != nil {
			return err
		}
		if !claimed {
			out, run = failed(reasonOutcomeUnknown, restartedMessage), false
		}
	}
	if run {
		out = normalize(reg.handler(ctx, Request{Device: b.id, RecordName: plain, Action: a, ReceivedAt: now}))
	}
	if _, err := out.result(); err != nil {
		log.Printf("hub: action %s answered a result that does not encode", plain)
		out = failed(reasonWriteFailed, "")
	}
	final, err := p.sealEcho(b, r.name, plain, a, out, r.expect)
	if err != nil {
		return err
	}
	stored, err = encodeStored(out)
	if err != nil {
		return err
	}
	device := b.id.String()
	if err := p.decide(ctx, b, func(tx *sql.Tx) error {
		if err := state.MarkDone(tx, b.ledger(plain), ledgerOutcome(out), stored, nil, p.cfg.Clock()); err != nil {
			return err
		}
		if err := state.SetLastApplied(tx, device, seq); err != nil {
			return err
		}
		if err := state.DropHeld(tx, device, seq); err != nil {
			return err
		}
		if err := mark(tx, r.name, o); err != nil { // the deciding commit for idempotent kinds
			return err
		}
		if err := state.Enqueue(tx, final.control(b.zone)); err != nil {
			return err
		}
		if p.fault != nil {
			return p.fault("done")
		}
		return nil
	}); err != nil {
		return err
	}
	ps.budget--
	ps.report.Applied++
	ps.report.Echoed++
	if registered && out.Status == wire.StatusApplied {
		ps.nudges = append(ps.nudges, reg.opts.Nudges...)
	}
	return nil
}

// claim commits plain as begun with the rollback mark (and the received
// echo, written at once so the phone sees it before the handler runs).
// claimed is false when the ledger already holds the record.
func (p *Processor) claim(ctx context.Context, b mailbox, r record, o secure.Opened, a wire.ActionRequest, plain string, received bool, now time.Time, ps *pass) (claimed bool, err error) {
	var recv *queued
	if received {
		q, err := p.sealEcho(b, r.name, plain, a, Outcome{Status: wire.StatusReceived}, r.expect)
		if err != nil {
			return false, err
		}
		recv = &q
	}
	err = p.decide(ctx, b, func(tx *sql.Tx) error {
		if err := state.Begin(tx, b.ledger(plain), now); err != nil {
			return err
		}
		if err := mark(tx, r.name, o); err != nil {
			return err
		}
		if recv == nil {
			return nil
		}
		return state.Enqueue(tx, recv.control(b.zone))
	})
	if errors.Is(err, state.ErrClaimed) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if recv != nil {
		ps.report.Echoed++
		if _, _, err := p.flushMailbox(ctx, b.zone); err != nil {
			return true, err
		}
	}
	return true, nil
}

// gate answers an action that must not reach its handler (Swift's
// processAction/applyAction order): a device_id other than the sender, another
// hub, past its window or dated ahead of the hub's clock, a refused or
// unregistered kind. run is true when the handler should run.
func (p *Processor) gate(b mailbox, a wire.ActionRequest, reg registration, registered bool, now time.Time) (out Outcome, run bool) {
	if a.DeviceID == nil || !sameID(*a.DeviceID, b.id) {
		return failed(reasonDeviceNotLinked, notLinkedMessage), false
	}
	if a.HubID != nil && !sameID(*a.HubID, p.cfg.Keys.HubID()) {
		return failed(reasonWrongHub, wrongHubMessage), false
	}
	maxAge := ActionMaxAge
	switch {
	case registered:
		maxAge = reg.opts.MaxAge
	case slices.Contains(sessionRequestKinds, a.Kind):
		maxAge = SessionRequestMaxAge
	}
	age := now.Sub(a.CreatedAt.Time)
	if age < -MaxClockSkew {
		return Outcome{Status: wire.StatusExpired, Reason: reasonExpired, Message: clockAheadMessage}, false
	}
	if age > maxAge {
		return Outcome{Status: wire.StatusExpired, Reason: reasonExpired}, false
	}
	if slices.Contains(RefusedKinds, a.Kind) || !registered {
		return failed(reasonUnsupported, ""), false
	}
	return Outcome{}, true
}

func sameID(s string, id secure.ID) bool {
	parsed, err := secure.ParseID(s)
	return err == nil && parsed == id
}

// drainHeld applies the held actions that are next in line now, in order.
// A held action that no longer opens (its epoch's keys are gone, or a newer
// copy rolled it back) is dropped and its gap asked for again.
func (p *Processor) drainHeld(ctx context.Context, b mailbox, ps *pass) error {
	device := b.id.String()
	for {
		dev, linked, err := p.cfg.Store.Device(device)
		if err != nil || !linked {
			return err
		}
		if dev.LinkNonce != b.link {
			return errRelinked
		}
		last := dev.LastAppliedActionSeq
		held, err := p.cfg.Store.HeldActions(device)
		if err != nil {
			return err
		}
		var next *state.Held
		var stale []uint64
		for i := range held {
			switch h := held[i]; {
			case h.ActionSeq <= last:
				stale = append(stale, h.ActionSeq) // passed by a skip_to
			case h.ActionSeq == last+1:
				next = &held[i]
			}
		}
		if err := p.dropHeld(ctx, b, stale); err != nil {
			return err
		}
		if next == nil {
			return nil
		}
		o, err := p.cfg.Opener.FromPhone(b.zone, next.RecordName, next.Envelope)
		if err != nil {
			if !droppable(err) {
				return err
			}
			log.Printf("hub: held action %d of device %s no longer opens (%s): asking again", next.ActionSeq, b.id, errClass(err))
			return p.reaskHeld(ctx, b, next.ActionSeq, last+1)
		}
		a, seq, plain, ok := parseAction(b, o)
		if !ok || seq != next.ActionSeq {
			return p.reaskHeld(ctx, b, next.ActionSeq, last+1)
		}
		r := record{name: next.RecordName, env: next.Envelope, expect: expectAbsent}
		if err := p.apply(ctx, b, r, o, a, seq, plain, ps); err != nil {
			return err
		}
	}
}

func (p *Processor) dropHeld(ctx context.Context, b mailbox, seqs []uint64) error {
	device := b.id.String()
	if len(seqs) == 0 {
		return nil
	}
	return p.decide(ctx, b, func(tx *sql.Tx) error {
		for _, s := range seqs {
			if err := state.DropHeld(tx, device, s); err != nil {
				return err
			}
		}
		return nil
	})
}

// reaskHeld drops an unusable held action and writes resend_from(from) again.
func (p *Processor) reaskHeld(ctx context.Context, b mailbox, seq, from uint64) error {
	q, err := p.sealResendFrom(b, from)
	if err != nil {
		return err
	}
	device := b.id.String()
	return p.decide(ctx, b, func(tx *sql.Tx) error {
		if err := state.DropHeld(tx, device, seq); err != nil {
			return err
		}
		if err := state.Enqueue(tx, q.control(b.zone)); err != nil {
			return err
		}
		return state.SetResendRequested(tx, device, from)
	})
}

// phoneControl handles a phone's control record. skip_to(m) (sim rule 6):
// the phone no longer has the actions before m, so the order continues from
// m — last becomes m-1 when that moves it forward — and the held actions that
// are now next are applied. The control is deleted once handled (recipient
// delete); a re-read one is harmless. The other phone controls are Task 10's.
func (p *Processor) phoneControl(ctx context.Context, b mailbox, rec transport.Stored, o secure.Opened, ps *pass) error {
	var c wire.Control
	if err := json.Unmarshal(o.Frame.Payload, &c); err != nil || c.ID == "" || o.Frame.ID != "c-"+c.ID {
		log.Printf("hub: undecodable control of device %s dropped", b.id)
		return nil
	}
	if c.Kind != wire.ControlSkipTo {
		return nil
	}
	if c.Seq == nil || *c.Seq == 0 {
		log.Printf("hub: skip_to without a seq from device %s dropped", b.id)
		return nil
	}
	m := *c.Seq
	device := b.id.String()
	dev, linked, err := p.cfg.Store.Device(device)
	if err != nil || !linked {
		return err
	}
	if dev.LinkNonce != b.link {
		return errRelinked
	}
	if err := p.decide(ctx, b, func(tx *sql.Tx) error {
		if err := mark(tx, rec.Name, o); err != nil {
			return err
		}
		if m > dev.LastAppliedActionSeq+1 {
			return state.SetLastApplied(tx, device, m-1)
		}
		return nil
	}); err != nil {
		return err
	}
	if err := p.drainHeld(ctx, b, ps); err != nil {
		return err
	}
	out, err := p.cfg.Transport.Delete(ctx, b.zone, []transport.DeleteItem{{
		Name: rec.Name, Expect: transport.Expect{Mode: transport.ExpectSeq, Seq: rec.RecordSeq},
	}})
	if err != nil || len(out) != 1 || !out[0].Saved {
		log.Printf("hub: skip_to of device %s not deleted (%s)", b.id, deleteClass(err, out))
	}
	return nil
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
