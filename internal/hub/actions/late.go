package actions

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
)

// ErrNotDecided refuses a late echo of an action the ledger does not hold as
// done under the phone's current link: a removed or re-linked phone (whose
// new action order may reuse the record name) is never echoed (D9).
var ErrNotDecided = errors.New("actions: no decided action of a linked phone at that record")

// LateEcho rewrites an action already echoed and decided with a later
// outcome (a held phone line that went, failed, expired or was cancelled:
// Swift RelayProcessor.lateEcho, mobile POC spec §6.6): the phone's record
// gets the new echo and the ledger's stored echo is replaced in the same
// transaction, so a lost ack re-echoes the final outcome. It runs under the
// pass lock, so it lands after the pass that echoed held for the same
// record; a handler must never call it from inside its own dispatch (the
// lock is not re-entrant) — the handlers queue it on a goroutine of their
// own. E2E: sealed relayToPhone to r.Device like every echo, never written
// in the clear. The queued write is flushed at once (best effort: a failed
// write stays queued for the next pass).
func (p *Processor) LateEcho(ctx context.Context, r Request, o Outcome) error {
	o = normalize(o)
	if _, err := o.result(); err != nil {
		return err
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	boxes, err := p.mailboxes()
	if err != nil {
		return err
	}
	var b mailbox
	found := false
	for _, box := range boxes {
		if box.id == r.Device {
			b, found = box, true
			break
		}
	}
	if !found {
		return ErrNotDecided
	}
	var seq uint64
	if r.Action.ActionSeq != nil {
		seq = *r.Action.ActionSeq
	}
	key := b.ledgerKey(r.RecordName, seq)
	phase, _, _, err := p.cfg.Store.Phase(key)
	if err != nil {
		return err
	}
	if phase != state.PhaseDone {
		return ErrNotDecided
	}
	wireName, err := p.cfg.Sealer.WireName(secure.ZoneRelay, r.RecordName)
	if err != nil {
		return fmt.Errorf("actions: a late echo's wire name: %w", err)
	}
	q, err := p.sealEcho(b, wireName, r.RecordName, r.Action, o, state.Control{Expect: state.ExpectNone})
	if err != nil {
		return err
	}
	stored, err := encodeStored(o)
	if err != nil {
		return err
	}
	if err := p.decide(ctx, b, func(tx *sql.Tx) error {
		if err := state.MarkDone(tx, key, ledgerOutcome(o), stored, nil, p.cfg.Clock()); err != nil {
			return err
		}
		return state.Enqueue(tx, q.control(b.zone))
	}); err != nil {
		if errors.Is(err, errRelinked) {
			return ErrNotDecided
		}
		return err
	}
	if _, _, err := p.flushMailbox(ctx, b); err != nil {
		log.Printf("hub: flushing device %s's mailbox after a late echo: %s", b.id, errClass(err))
	}
	return nil
}
