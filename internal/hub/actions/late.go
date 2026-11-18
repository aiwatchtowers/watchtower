package actions

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
)

// ErrNotDecided refuses a late echo of an action the ledger does not hold as
// done with a held echo under the phone's current link: a removed or
// re-linked phone (whose new action order may reuse the record name) is never
// echoed (D9), and a final echo is never replaced.
var ErrNotDecided = errors.New("actions: no decided action of a linked phone at that record")

// LateEcho rewrites an action already echoed and decided with a later
// outcome (a held phone line that went, failed, expired or was cancelled:
// Swift RelayProcessor.lateEcho, mobile POC spec §6.6): the phone's record
// gets the new echo and the ledger's stored echo is replaced in the same
// transaction, so a lost ack re-echoes the final outcome. Its decision runs
// under p.mu, which the apply that echoed held holds until that echo is
// queued, so the late echo is queued after it and the queue's flush lock
// writes them in that order; a handler must never call it from inside its
// own dispatch (p.mu is not re-entrant) — the handlers queue it on a
// goroutine of their own. E2E: sealed relayToPhone to r.Device like every
// echo, never written in the clear. The queued write is flushed at once,
// with p.mu released and p.run held shared, as a pass's (best effort: a
// failed write stays queued for the next pass), except while paused
// (SetPaused).
func (p *Processor) LateEcho(ctx context.Context, r Request, o Outcome) error {
	if p.cfg.Sealer == nil {
		return errors.New("actions: no sealer for a late echo")
	}
	o = normalize(o)
	if _, err := o.result(); err != nil {
		return err
	}
	b, err := p.decideLate(ctx, r, o)
	if err != nil {
		return err
	}
	// The write is a pass's as PauseFor sees it: a pause returns only after
	// a write already past this check, and none starts after it.
	p.run.RLock()
	defer p.run.RUnlock()
	if p.paused.Load() {
		// Queued: the first pass after the pause writes it.
		return nil
	}
	if err := p.flushBox(ctx, b); err != nil {
		log.Printf("hub: flushing device %s's mailbox after a late echo: %s", b.id, errClass(err))
	}
	return nil
}

// decideLate commits LateEcho's outcome and queues its echo, under p.mu,
// and returns the phone's mailbox.
func (p *Processor) decideLate(ctx context.Context, r Request, o Outcome) (mailbox, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	boxes, err := p.mailboxes()
	if err != nil {
		return mailbox{}, err
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
		return mailbox{}, ErrNotDecided
	}
	var seq uint64
	if r.Action.ActionSeq != nil {
		seq = *r.Action.ActionSeq
	}
	key := b.ledgerKey(r.RecordName, seq)
	phase, _, before, err := p.cfg.Store.Phase(key)
	if err != nil {
		return mailbox{}, err
	}
	// Only a held echo is replaced: a final one (applied, failed, expired,
	// cancelled, outcome_unknown after a timeout) is never rewritten.
	if prev, ok := decodeStored(before); phase != state.PhaseDone || !ok || prev.Status != wire.StatusHeld {
		return mailbox{}, ErrNotDecided
	}
	wireName, err := p.cfg.Sealer.WireName(secure.ZoneRelay, r.RecordName)
	if err != nil {
		return mailbox{}, fmt.Errorf("actions: a late echo's wire name: %w", err)
	}
	q, err := p.sealEcho(b, wireName, r.RecordName, r.Action, o, state.Control{Expect: state.ExpectNone})
	if err != nil {
		return mailbox{}, err
	}
	stored, err := encodeStored(o)
	if err != nil {
		return mailbox{}, err
	}
	if err := p.decide(ctx, b, func(tx *sql.Tx) error {
		if err := state.MarkDone(tx, key, ledgerOutcome(o), stored, nil, p.cfg.Clock()); err != nil {
			return err
		}
		return state.Enqueue(tx, q.control(b.queue))
	}); err != nil {
		if errors.Is(err, errRelinked) {
			return mailbox{}, ErrNotDecided
		}
		return mailbox{}, err
	}
	return b, nil
}
