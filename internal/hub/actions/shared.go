package actions

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"strconv"
	"strings"
	"time"

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
// then come back as repeats the ledger answers.
//
// Only a record whose own content fails (contentError: it cannot be decoded,
// sealed back or encoded) is struck — never one that met a busy store or a
// transport error, and never the records queued behind it, which are simply
// not attempted. A struck record is passed over (logged at error level) once
// it failed MaxRecordStrikes times over at least StrikeWindow of wall-clock
// time: passes run on every transport nudge, so a count alone would pass a
// record over within seconds. A passed-over record stays in the zone for the
// phone's next write or the next resync, as the daily hygiene leaves what
// nobody can use; the phone's records behind it then go on.

const (
	// MaxRecordStrikes is how many failed passes a record's content needs
	// before it is passed over.
	MaxRecordStrikes = 3
	// StrikeWindow is the least time between a record's first and last
	// strike before it is passed over.
	StrikeWindow = 10 * time.Minute
	// maxStrikeRecords caps the strike table; the oldest entry goes first.
	maxStrikeRecords = 256
)

// errHeldBack ends a shared page whose token must not move: a record of a
// failed phone was left for the next pass.
var errHeldBack = errors.New("actions: a record of the shared mailbox was left for the next pass")

// strikeEntry is one record version's failed passes since first.
type strikeEntry struct {
	n      int
	first  time.Time
	passed bool
}

// contentError reports whether err comes from the record's own content — it
// does not decode, or its answer does not seal or encode — rather than from
// the store, the transport or the keyring, which pass.
func contentError(err error) bool {
	var (
		syntax    *json.SyntaxError
		typ       *json.UnmarshalTypeError
		value     *json.UnsupportedValueError
		marshaler *json.MarshalerError
	)
	if errors.As(err, &syntax) || errors.As(err, &typ) || errors.As(err, &value) || errors.As(err, &marshaler) {
		return true
	}
	for _, e := range []error{
		secure.ErrOversized, secure.ErrFrameMalformed, secure.ErrNameMismatch,
		secure.ErrLengthMismatch, secure.ErrTooShort, secure.ErrBadMagic,
	} {
		if errors.Is(err, e) {
			return true
		}
	}
	return false
}

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
			if p.cfg.Hello != nil && isHello(rec) {
				if err := p.cfg.Hello(ctx, rec); err != nil {
					if ctx.Err() != nil {
						return ctx.Err()
					}
					heldBack = true // read again next pass
					errs = append(errs, fmt.Errorf("actions: a hello of the shared mailbox: %w", err))
				}
				continue
			}
			b, own, ok, err := p.owner(g, rec)
			if !ok {
				continue // nobody's here: dropped with no answer (D9)
			}
			if failed[b.id] {
				heldBack = true // behind its phone's failure: not attempted, no strike
				continue
			}
			if err == nil {
				if own != nil {
					err = p.ownReceived(ctx, b, rec, *own, ps)
				} else {
					err = p.handle(ctx, b, rec, ps)
				}
			}
			if err == nil {
				p.forget(g.zone, rec)
				continue
			}
			if errors.Is(err, errBudget) {
				return err
			}
			if ctx.Err() != nil {
				return ctx.Err()
			}
			if contentError(err) && p.strike(g.zone, rec, err) {
				continue // passed over: the phone's later records go on
			}
			failed[b.id] = true
			heldBack = true
			errs = passError(b, err, errs)
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

// isHello: rec is a phone's hello (its envelope's class), the link lane's.
func isHello(rec transport.Stored) bool {
	h, err := secure.ParseHeader(rec.Envelope)
	return err == nil && h.Class == secure.ClassHello
}

// withHelloZone adds CloudKit's shared RelayZone, with no phone in it, when
// no linked phone put it in groups and hellos are wanted: for a pass while
// the lane takes them (Config.Hello) and Config.HelloWanted says a code is
// open or a link urgent; for the hygiene (always), so stale hellos age out
// with no phone linked.
func (p *Processor) withHelloZone(groups []zoneGroup, hygiene bool) []zoneGroup {
	if p.cfg.Transport.Kind() != transport.KindCloudKit {
		return groups
	}
	if !hygiene && (p.cfg.Hello == nil || (p.cfg.HelloWanted != nil && !p.cfg.HelloWanted())) {
		return groups
	}
	sm, ok := p.cfg.Transport.(transport.SharedMailbox)
	if !ok {
		return groups
	}
	zone := sm.MailboxFor(p.cfg.HubRelayID, "")
	for _, g := range groups {
		if g.zone == zone {
			return groups
		}
	}
	return append(groups, zoneGroup{zone: zone, shared: true})
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

func strikeKey(zone string, rec transport.Stored) string {
	return zone + "|" + rec.Name + "|" + strconv.FormatUint(rec.RecordSeq, 10)
}

// strike counts one more failed pass of rec's content (err) and reports
// whether rec is now passed over: MaxRecordStrikes failures spread over at
// least StrikeWindow (the processor's clock). A passed-over record stays
// passed over while the page is read again.
func (p *Processor) strike(zone string, rec transport.Stored, err error) bool {
	now := p.cfg.Clock()
	if p.strikes == nil {
		p.strikes = map[string]*strikeEntry{}
	}
	key := strikeKey(zone, rec)
	e, ok := p.strikes[key]
	if !ok {
		if len(p.strikes) >= maxStrikeRecords {
			p.dropOldestStrike()
		}
		e = &strikeEntry{first: now}
		p.strikes[key] = e
	}
	if e.passed {
		return true
	}
	e.n++
	if e.n < MaxRecordStrikes || now.Sub(e.first) < StrikeWindow {
		return false
	}
	e.passed = true
	log.Printf("hub: error: record %s of the shared mailbox failed %d times over %s (%s): passed over",
		rec.Name, e.n, now.Sub(e.first).Round(time.Second), errClass(err))
	return true
}

// forget clears rec's strikes once it was handled.
func (p *Processor) forget(zone string, rec transport.Stored) {
	delete(p.strikes, strikeKey(zone, rec))
}

// dropOldestStrike makes room in the strike table.
func (p *Processor) dropOldestStrike() {
	oldest := ""
	var at time.Time
	for k, e := range p.strikes {
		if oldest == "" || e.first.Before(at) {
			oldest, at = k, e.first
		}
	}
	delete(p.strikes, oldest)
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
