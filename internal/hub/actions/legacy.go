package actions

import (
	"context"
	"log"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// Mixed versions (Go hub spec §8 p. 5, relay client spec §5 p. 10): a phone
// that predates ordered actions sends no action_seq. Its action takes today's
// path, the Swift RelayProcessor's: record action-<uuid>, applied in the order
// read with no hold, no resend_from and no order to move, exactly once through
// the ledger keyed by that plain name, echoed with today's statuses (received,
// then a final one). The phone stays unordered until it sends an action_seq.

// legacyName is a legacy action's plain record name.
func legacyName(a wire.ActionRequest) string { return "action-" + a.ID }

// legacyAction handles one action without action_seq. A pending (or
// received) action is applied; one the ledger already holds as done is
// echoed again with its stored outcome, never dispatched again.
func (p *Processor) legacyAction(ctx context.Context, b mailbox, r record, o secure.Opened, a wire.ActionRequest, ps *pass) error {
	plain := legacyName(a)
	if a.ID == "" || o.Sender != b.id || o.Frame.ID != plain {
		log.Printf("hub: legacy action of device %s names another record: dropped", b.id)
		return nil
	}
	if a.Status != wire.StatusPending && a.Status != wire.StatusReceived {
		return nil
	}
	phase, _, _, err := p.cfg.Store.Phase(plain)
	if err != nil {
		return err
	}
	if phase == state.PhaseDone {
		return p.repeat(ctx, b, r, o, a, plain, plain, ps)
	}
	return p.apply(ctx, b, r, o, a, 0, plain, ps)
}

// legacyOwnReceived is ownReceived for a legacy action: the hub's own
// received echo read back while the ledger still holds the action as begun
// (the hub stopped mid-apply) is answered outcome_unknown, never re-run.
func (p *Processor) legacyOwnReceived(ctx context.Context, b mailbox, rec transport.Stored, o secure.Opened, a wire.ActionRequest, ps *pass) error {
	plain := legacyName(a)
	if a.ID == "" || o.Frame.ID != plain || a.DeviceID == nil || !sameID(*a.DeviceID, b.id) {
		return nil
	}
	phase, _, _, err := p.cfg.Store.Phase(plain)
	if err != nil || phase != state.PhaseBegun {
		return err
	}
	ps.report.Read++
	return p.apply(ctx, b, record{name: rec.Name, env: rec.Envelope, expect: expectSeq(rec.RecordSeq)}, o, a, 0, plain, ps)
}
