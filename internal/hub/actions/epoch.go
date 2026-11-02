package actions

import (
	"context"
	"database/sql"
	"log"
	"strconv"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
)

// Old-epoch actions (relay sim rule 14 with the 7-day cap of ask #843): the
// hub keeps a retired epoch's receiving keys at most identity.
// PreviousEpochGrace. An action a phone sealed in an epoch the hub no longer
// holds (a phone away longer than that, resending its outbox with the same
// bytes after a switch, rule 13) does not open; it is answered
// resend_from(last+1) once per record version, and the phone reseals every
// outbox action from that seq older than its current epoch with the same
// action_seq and overwrites the record. Nothing is applied, marked or
// deleted: the resealed copy is read as a new version and applied once by
// the order rule (4).

// maxOldEpochScan bounds how far past the phone's last applied action_seq a
// record's wire name is matched as one of its actions (a name the hub cannot
// open says nothing else about itself).
const maxOldEpochScan = 1024

// oldEpochAction answers rec, from b's mailbox, which did not open because
// its epoch is not accepted. Only an action of b's phone that is still to
// be applied, sealed in an epoch older than the current one, on the active
// transport and for a phone that has not lapsed, is answered; anything else
// is dropped with no answer, as before.
func (p *Processor) oldEpochAction(ctx context.Context, b mailbox, rec transport.Stored, ps *pass) error {
	if p.standby() || ps.resent[b.id] {
		return nil
	}
	key := b.zone + "\x00" + rec.Name
	if seq, ok := p.oldSeen[key]; ok && seq == rec.RecordSeq {
		return nil
	}
	epoch, ok := sealedBy(rec.Envelope, b.id)
	if !ok {
		return nil
	}
	current, err := p.cfg.Keys.CurrentEpoch()
	if err != nil {
		return err
	}
	if epoch >= current {
		return nil // not an old epoch: a future or unknown one is just dropped
	}
	device := b.id.String()
	dev, linked, err := p.cfg.Store.Device(device)
	if err != nil || !linked {
		return err
	}
	if dev.LinkNonce != b.link {
		return errRelinked
	}
	from := dev.LastAppliedActionSeq + 1
	seq, err := p.namesNextAction(b, rec.Name, from)
	if err != nil || seq == 0 {
		return err
	}
	if lapsed, err := p.lapsed(b, seq, rec.ServerAt); err != nil || lapsed {
		return err
	}
	q, err := p.sealResendFrom(b, from)
	if err != nil {
		return err
	}
	if err := p.decide(ctx, b, func(tx *sql.Tx) error {
		if err := state.Enqueue(tx, q.control(b.queue)); err != nil {
			return err
		}
		return state.SetResendRequested(tx, device, from)
	}); err != nil {
		return err
	}
	if ps.resent == nil {
		ps.resent = map[secure.ID]bool{}
	}
	ps.resent[b.id] = true
	if p.oldSeen == nil || len(p.oldSeen) >= maxStaleSeen {
		p.oldSeen = map[string]uint64{}
	}
	p.oldSeen[key] = rec.RecordSeq
	log.Printf("hub: an action of device %s is sealed in an epoch the hub no longer holds: resend_from asked", b.id)
	return nil
}

// sealedBy is the epoch env's header names when its sender is device; ok is
// false for an envelope that does not parse or names another sender.
func sealedBy(env []byte, device secure.ID) (uint32, bool) {
	h, err := secure.ParseHeader(env)
	if err != nil || h.Sender != device {
		return 0, false
	}
	return h.Epoch, true
}

// namesNextAction is the action_seq of the action of b whose wire name is
// name, looked for from action_seq from on (within maxOldEpochScan); 0 for none.
func (p *Processor) namesNextAction(b mailbox, name string, from uint64) (uint64, error) {
	meta, err := p.cfg.Keys.MetaKey()
	if err != nil {
		return 0, err
	}
	defer clear(meta)
	prefix := b.id.String() + "-"
	for s := from; s < from+maxOldEpochScan; s++ {
		if secure.RecordName(meta, secure.ZoneRelay, "a", prefix+strconv.FormatUint(s, 10)) == name {
			return s, nil
		}
	}
	return 0, nil
}

// HighestActionSeq is the highest action_seq among device's action records
// in its mailbox on this processor's transport, read from the start (no
// stored token moves): an action that opens gives its own seq, one that
// does not (an epoch the hub no longer holds) its name matched as one of the
// phone's next actions. 0 when there is none. The switcher calls it before
// a relay lapse ends (sim rule 16), outside any pass: everything the phone
// sent before then is skipped.
func (p *Processor) HighestActionSeq(ctx context.Context, device string) (uint64, error) {
	boxes, err := p.mailboxes()
	if err != nil {
		return 0, err
	}
	var b mailbox
	found := false
	for _, x := range boxes {
		if sameID(device, x.id) {
			b, found = x, true
		}
	}
	if !found {
		return 0, nil
	}
	dev, linked, err := p.cfg.Store.Device(device)
	if err != nil || !linked {
		return 0, err
	}
	var highest, since uint64
	for {
		batch, err := p.cfg.Transport.Changes(ctx, b.zone, since)
		if err != nil {
			return 0, err
		}
		for _, rec := range batch.Changed {
			if _, ok := sealedBy(rec.Envelope, b.id); !ok {
				continue
			}
			var seq uint64
			if o, err := p.cfg.Opener.FromPhone(b.zone, rec.Name, rec.Envelope); err == nil {
				seq = orderedSeq(b, o)
			} else if !droppable(err) {
				return 0, err
			} else if seq, err = p.namesNextAction(b, rec.Name, dev.LastAppliedActionSeq+1); err != nil {
				return 0, err
			}
			highest = max(highest, seq)
		}
		if !batch.More {
			return highest, nil
		}
		since = batch.NewSeq
	}
}
