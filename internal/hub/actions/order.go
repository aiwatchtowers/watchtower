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

// mark writes the rollback mark of a record b's phone sent: called only
// inside the transaction that commits the first decision about it (a crash
// before that commit leaves the record new, so its redelivery is applied).
// The hub's own echo read back (ownReceived) has no phone mark to write.
func mark(tx *sql.Tx, b mailbox, wireName string, o secure.Opened) error {
	if o.Sender != b.id {
		return nil
	}
	return state.RecordSeen(tx, wireName, o.Sender.String(), o.Epoch, o.Seq)
}

// decodes reports whether payload decodes into v; a record that does not is
// dropped unanswered (it carries no id to echo).
func decodes(payload []byte, v any) bool { return json.Unmarshal(payload, v) == nil }

// parseAction decodes an ordered action and binds it to its record (see
// bindAction). ok is false for a record to drop unanswered (no decodable id
// to echo, or a payload without action_seq: a held action always has one).
func parseAction(b mailbox, o secure.Opened) (a wire.ActionRequest, seq uint64, plain string, ok bool) {
	if err := json.Unmarshal(o.Frame.Payload, &a); err != nil {
		log.Printf("hub: undecodable action of device %s dropped", b.id)
		return a, 0, "", false
	}
	seq, plain, ok = bindAction(b, o, a)
	return a, seq, plain, ok
}

// bindAction binds an ordered action to its record: the sender is b's phone
// and the frame names a-<sender>-<action_seq>.
func bindAction(b mailbox, o secure.Opened, a wire.ActionRequest) (seq uint64, plain string, ok bool) {
	if a.ActionSeq == nil {
		return 0, "", false
	}
	seq = *a.ActionSeq
	plain = actionName(b.id, seq)
	if seq == 0 || o.Sender != b.id || o.Frame.ID != plain {
		log.Printf("hub: action of device %s names another record: dropped", b.id)
		return 0, "", false
	}
	return seq, plain, true
}

// action places one action. A payload without action_seq takes today's
// unordered path (legacy.go). An ordered one: a repeat is echoed again, one
// ahead of a gap is held, the next one is applied and then the held ones that
// follow. The first ordered action a phone sends marks it ordered.
func (p *Processor) action(ctx context.Context, b mailbox, r record, o secure.Opened, ps *pass) error {
	var a wire.ActionRequest
	if !decodes(o.Frame.Payload, &a) {
		log.Printf("hub: undecodable action of device %s dropped", b.id)
		return nil
	}
	if a.ActionSeq == nil {
		return p.legacyAction(ctx, b, r, o, a, ps)
	}
	seq, plain, ok := bindAction(b, o, a)
	if !ok || a.Status != wire.StatusPending {
		return nil
	}
	device := b.id.String()
	dev, linked, err := p.cfg.Store.Device(device)
	if err != nil || !linked {
		return err
	}
	if dev.LinkNonce != b.link {
		return errRelinked
	}
	if !dev.Ordered {
		if err := p.decide(ctx, b, func(tx *sql.Tx) error { return state.SetOrdered(tx, device) }); err != nil {
			return err
		}
	}
	last := dev.LastAppliedActionSeq
	switch {
	case seq <= last:
		return p.repeat(ctx, b, r, o, a, b.ledger(plain), plain, ps)
	case seq > last+1:
		return p.hold(ctx, b, r, o, a, seq, dev, plain, ps)
	}
	if err := p.apply(ctx, b, r, o, a, seq, plain, ps); err != nil {
		return err
	}
	return p.drainHeld(ctx, b, ps)
}

// ownReceived settles an action whose claim outlived its pass. A
// received-echo kind is claimed begun and its record overwritten with the
// hub's received echo before the handler runs; if the hub then stops (or the
// done transaction fails), the phone's record holds only that echo, which
// FromPhone refuses as the hub's own. Read back here, an own received echo of
// the next action whose ledger row is still begun is answered
// outcome_unknown — never re-run — so the order moves on (the Swift hub's
// begun → outcome_unknown, RelayProcessor processAction). Any other own
// record is no work. o is rec opened under b's key (OwnEchoFor).
func (p *Processor) ownReceived(ctx context.Context, b mailbox, rec transport.Stored, o secure.Opened, ps *pass) error {
	if o.Frame.Kind != kindAction {
		return nil
	}
	var a wire.ActionRequest
	if !decodes(o.Frame.Payload, &a) || a.Status != wire.StatusReceived {
		return nil
	}
	if a.ActionSeq == nil {
		return p.legacyOwnReceived(ctx, b, rec, o, a, ps)
	}
	seq := *a.ActionSeq
	plain := actionName(b.id, seq)
	if o.Frame.ID != plain { // the echo of another phone's action
		return nil
	}
	dev, linked, err := p.cfg.Store.Device(b.id.String())
	if err != nil || !linked {
		return err
	}
	if dev.LinkNonce != b.link {
		return errRelinked
	}
	if seq != dev.LastAppliedActionSeq+1 {
		return nil
	}
	phase, _, _, err := p.cfg.Store.Phase(b.ledger(plain))
	if err != nil || phase != state.PhaseBegun {
		return err
	}
	ps.report.Read++
	if err := p.apply(ctx, b, record{name: rec.Name, env: rec.Envelope, expect: expectSeq(rec.RecordSeq)}, o, a, seq, plain, ps); err != nil {
		return err
	}
	return p.drainHeld(ctx, b, ps)
}

// repeat answers an action already decided (ordered: at or below the last
// applied seq; legacy: done in the ledger under key) with its stored final
// echo (applied when the ledger has none: skipped or pruned), never
// dispatching it again.
func (p *Processor) repeat(ctx context.Context, b mailbox, r record, o secure.Opened, a wire.ActionRequest, key, plain string, ps *pass) error {
	_, _, stored, err := p.cfg.Store.Phase(key)
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
		if err := mark(tx, b, r.name, o); err != nil {
			return err
		}
		return state.Enqueue(tx, q.control(b.queue))
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
		if err := mark(tx, b, r.name, o); err != nil {
			return err
		}
		if err := state.Hold(tx, device, seq, r.name, r.env); err != nil {
			return err
		}
		if err := state.Enqueue(tx, echo.control(b.queue)); err != nil {
			return err
		}
		if resend == nil {
			return nil
		}
		if err := state.Enqueue(tx, resend.control(b.queue)); err != nil {
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
// actions and queues the final echo. seq 0 is a legacy action (legacy.go):
// keyed by its plain name, with no order to move.
func (p *Processor) apply(ctx context.Context, b mailbox, r record, o secure.Opened, a wire.ActionRequest, seq uint64, plain string, ps *pass) error {
	now := p.cfg.Clock()
	reg, registered := p.cfg.Dispatcher.lookup(a.Kind)
	key := b.ledgerKey(plain, seq)
	phase, _, stored, err := p.cfg.Store.Phase(key)
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
		claimed, err := p.claim(ctx, b, r, o, a, key, plain, reg.opts.ReceivedEcho, now, ps)
		if err != nil {
			return err
		}
		if !claimed {
			out, run = failed(reasonOutcomeUnknown, restartedMessage), false
		}
	}
	if run {
		out = normalize(reg.handler(ctx, Request{Device: b.id, Hub: p.cfg.Keys.HubID(), RecordName: plain, Action: a, ReceivedAt: now}))
	}
	if _, err := out.result(); err != nil {
		out = unencodable(b.id)
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
		if err := state.MarkDone(tx, key, ledgerOutcome(out), stored, nil, p.cfg.Clock()); err != nil {
			return err
		}
		if seq > 0 {
			if err := state.SetLastApplied(tx, device, seq); err != nil {
				return err
			}
			if err := state.DropHeld(tx, device, seq); err != nil {
				return err
			}
		}
		if err := mark(tx, b, r.name, o); err != nil { // the deciding commit for idempotent kinds
			return err
		}
		if err := state.Enqueue(tx, final.control(b.queue)); err != nil {
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

// unencodable is the outcome of a handler answer whose result does not
// encode: failed/write_failed rather than a record that wedges the order. It
// logs the device only (an action seq flowing here hangs gosec's G706 taint
// analysis, see reaskHeld).
func unencodable(device secure.ID) Outcome {
	log.Printf("hub: an action of device %s answered a result that does not encode", device)
	return failed(reasonWriteFailed, "")
}

// claim commits the ledger key as begun with the rollback mark (and the
// received echo, written at once so the phone sees it before the handler
// runs). claimed is false when the ledger already holds the record.
func (p *Processor) claim(ctx context.Context, b mailbox, r record, o secure.Opened, a wire.ActionRequest, key, plain string, received bool, now time.Time, ps *pass) (claimed bool, err error) {
	var recv *queued
	if received {
		q, err := p.sealEcho(b, r.name, plain, a, Outcome{Status: wire.StatusReceived}, r.expect)
		if err != nil {
			return false, err
		}
		recv = &q
	}
	err = p.decide(ctx, b, func(tx *sql.Tx) error {
		if err := state.Begin(tx, key, now); err != nil {
			return err
		}
		if err := mark(tx, b, r.name, o); err != nil {
			return err
		}
		if recv == nil {
			return nil
		}
		return state.Enqueue(tx, recv.control(b.queue))
	})
	if errors.Is(err, state.ErrClaimed) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if recv != nil {
		ps.report.Echoed++
		if _, _, err := p.flushMailbox(ctx, b); err != nil {
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
	if p.fault != nil {
		if err := p.fault("drain " + device); err != nil {
			return err
		}
	}
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
			return p.reaskHeld(ctx, b, next.ActionSeq, last+1)
		}
		a, seq, plain, ok := parseAction(b, o)
		if !ok || seq != next.ActionSeq {
			return p.reaskHeld(ctx, b, next.ActionSeq, last+1)
		}
		if ps.budget <= 0 {
			ps.report.Remaining++ // resumed at the start of the next pass
			return nil
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
	// The class stays out of this line: logging a value that flows from the held
	// row through FromPhone sends gosec's G706 taint analysis into a loop it
	// never leaves (it hung golangci-lint); the device id is enough here.
	log.Printf("hub: a held action of device %s no longer opens: asking again", b.id)
	q, err := p.sealResendFrom(b, from)
	if err != nil {
		return err
	}
	device := b.id.String()
	return p.decide(ctx, b, func(tx *sql.Tx) error {
		if err := state.DropHeld(tx, device, seq); err != nil {
			return err
		}
		if err := state.Enqueue(tx, q.control(b.queue)); err != nil {
			return err
		}
		return state.SetResendRequested(tx, device, from)
	})
}
