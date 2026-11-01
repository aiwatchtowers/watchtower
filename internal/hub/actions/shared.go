package actions

import (
	"context"
	"errors"
	"fmt"
	"log"
	"strconv"
	"strings"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/transport"
)

// The shared mailbox (Go hub phase 3, spec §12a, protocol §7.5 points 1–2):
// on CloudKit every phone of the hub writes into the one RelayZone, read
// once per pass with one change token. Each record goes to the phone its
// envelope's sender names, and FromPhone authenticates it under that phone's
// key alone, so a record is never attributed to another phone than the one
// that sealed it; the hub's own record read back (an echo, a c-* control) goes
// to the one phone whose key opens it (OwnEchoFor).
//
// One phone's failure never holds back the others. A phone whose drain or
// upload retry failed, that was re-linked meanwhile, or whose record failed
// with an error, is "failed" for the rest of the pass: its records are left
// unhandled while every other phone's are handled. The zone has one token
// (CloudKit's is opaque, per page), so a page with a record left unhandled
// stores no token and is read again next pass — the other phones' records
// then come back as repeats the ledger answers. A record left unhandled
// MaxRecordStrikes passes in a row no longer holds the page: it is passed
// over (logged), as the daily hygiene passes over what nobody can use, and
// stays in the zone for the phone's next write or the next resync.

// MaxRecordStrikes is how many passes in a row one record version may hold
// back the shared mailbox's token.
const MaxRecordStrikes = 3

// errHeldBack ends a shared page whose token must not move: a record of a
// failed phone was left for the next pass.
var errHeldBack = errors.New("actions: a record of the shared mailbox was left for the next pass")

// passShared is one pass over the shared mailbox g: every phone's held
// actions and uploads, then the zone once.
func (p *Processor) passShared(ctx context.Context, g zoneGroup, ps *pass) []error {
	var errs []error
	failed := map[secure.ID]bool{}
	for _, b := range g.boxes {
		err := p.drainHeld(ctx, b, ps)
		if err == nil {
			err = p.retryUploads(ctx, b, ps)
		}
		if err != nil && !errors.Is(err, errBudget) {
			failed[b.id] = true
		}
		errs = passError(b, err, errs)
	}
	err := p.pull(ctx, g.zone, func(batch transport.Batch) error {
		heldBack := false
		for i, rec := range batch.Changed {
			if ps.budget <= 0 {
				ps.report.Remaining += len(batch.Changed) - i
				return errBudget
			}
			b, own, ok, err := p.owner(g, rec)
			if !ok {
				continue // nobody's here: dropped with no answer (D9)
			}
			if err == nil && !failed[b.id] {
				if own != nil {
					err = p.ownReceived(ctx, b, rec, *own, ps)
				} else {
					err = p.handle(ctx, b, rec, ps)
				}
			}
			if errors.Is(err, errBudget) {
				return err
			}
			if err != nil {
				if ctx.Err() != nil {
					return ctx.Err()
				}
				failed[b.id] = true
				errs = passError(b, err, errs)
			}
			if failed[b.id] && p.strike(g.zone, rec) {
				heldBack = true
			}
		}
		if heldBack {
			return errHeldBack
		}
		p.clearStrikes(g.zone)
		return nil
	})
	if err != nil && !errors.Is(err, errBudget) && !errors.Is(err, errHeldBack) {
		// The zone itself (the transport, the token store): no phone's fault.
		log.Printf("hub: reading the shared mailbox: %s", errClass(err))
		errs = append(errs, fmt.Errorf("actions: reading the shared mailbox: %w", err))
	}
	return errs
}

// owner finds the phone of g a record belongs to: a phone's record
// (relayToHub) by its envelope's sender, the hub's own (relayToPhone) by the
// phone whose key opens it, with own the opened record. ok is false for a
// record that belongs to nobody here (a sender with no mailbox, another
// hub's, a hello, bytes that are no envelope); err is b's failure opening
// it (a key it cannot read now).
func (p *Processor) owner(g zoneGroup, rec transport.Stored) (b mailbox, own *secure.Opened, ok bool, err error) {
	h, err := secure.ParseHeader(rec.Envelope)
	if err != nil {
		log.Printf("hub: dropped a record of the shared mailbox: %s", errClass(err))
		return mailbox{}, nil, false, nil
	}
	switch h.Class {
	case secure.ClassRelayToHub:
		b, ok := g.box(h.Sender)
		if !ok {
			log.Printf("hub: dropped a record of device %s, which has no mailbox here", h.Sender)
		}
		return b, nil, ok, nil
	case secure.ClassRelayToPhone:
		for _, b := range g.boxes {
			o, err := p.cfg.Opener.OwnEchoFor(b.id, rec.Name, rec.Envelope)
			switch {
			case errors.Is(err, secure.ErrNoRelayKey):
				continue // another phone's record
			case err == nil:
				return b, &o, true, nil
			case droppable(err):
				return mailbox{}, nil, false, nil
			}
			return b, nil, true, err
		}
	case secure.ClassHello, secure.ClassData, secure.ClassAlert, secure.ClassKeybox:
		// A hello is the link lane's; the rest never belongs in a mailbox.
	}
	return mailbox{}, nil, false, nil
}

// strike counts one more pass that left rec unhandled and reports whether it
// still holds the page back (under MaxRecordStrikes passes).
func (p *Processor) strike(zone string, rec transport.Stored) bool {
	if p.strikes == nil {
		p.strikes = map[string]int{}
	}
	key := zone + "|" + rec.Name + "|" + strconv.FormatUint(rec.RecordSeq, 10)
	p.strikes[key]++
	if p.strikes[key] < MaxRecordStrikes {
		return true
	}
	if p.strikes[key] == MaxRecordStrikes {
		log.Printf("hub: a record of the shared mailbox was left unhandled %d passes: passed over", MaxRecordStrikes)
	}
	return false
}

// clearStrikes forgets zone's strikes once a page of it was handled whole
// (its token moved past every struck record).
func (p *Processor) clearStrikes(zone string) {
	for k := range p.strikes {
		if strings.HasPrefix(k, zone+"|") {
			delete(p.strikes, k)
		}
	}
}

// phoneSender is the sender of a phone's record (a relayToHub envelope) as
// its header names it, unauthenticated until FromPhone opens it; ok is false
// for any other class and for bytes that are no envelope.
func phoneSender(env []byte) (secure.ID, bool) {
	h, err := secure.ParseHeader(env)
	if err != nil || h.Class != secure.ClassRelayToHub {
		return secure.ID{}, false
	}
	return h.Sender, true
}

// namesItsSender reports whether an opened phone record's plain name names
// its sender, where the name names a device at all: a-<device>-<seq> and
// device-<device> must (one parse, case-insensitive); action-<uuid>,
// c-<uuid> and recupload-<id> name none.
func namesItsSender(o secure.Opened) bool {
	plain := o.Frame.ID
	var dev string
	switch {
	case strings.HasPrefix(plain, "a-"):
		rest := plain[len("a-"):]
		if len(rest) < 38 || rest[36] != '-' {
			return false
		}
		dev = rest[:36]
	case strings.HasPrefix(plain, devicePrefix):
		dev = plain[len(devicePrefix):]
	default:
		return true
	}
	id, err := secure.ParseID(dev)
	return err == nil && id == o.Sender
}
