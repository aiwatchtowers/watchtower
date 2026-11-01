package actions

import (
	"context"
	"errors"
	"log"
	"strconv"
	"time"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// Relay hygiene (Go hub spec §8 p. 6, relay sim rule 15). Recipients delete
// what they read: the phone its echoes and the hub's controls, the hub the
// phone's controls (phoneControl). What is left behind ages out: on the
// hosted relay through its 14-day server TTL, so the hub scans nothing
// there; on CloudKit, which has no TTL, through the Swift hub's daily 7-day
// fallback sweep. Either way the ledger keeps done rows one day past the
// longest action window.

const (
	// hygieneStampKey is the hub_meta key of the last hygiene run (the Swift
	// hub's key; seconds since 1970 as a decimal string).
	hygieneStampKey = "hygiene_last_run"
	// HygieneInterval is how often Hygiene does any work.
	HygieneInterval = 24 * time.Hour
	// retentionMargin keeps ledger rows a day past ActionMaxAge, so a record
	// the sweep has not removed yet still meets its ledger row.
	retentionMargin = 24 * time.Hour
)

// HygieneReport counts one hygiene run: mailbox records deleted and ledger
// rows pruned. Ran is false when the last run was under HygieneInterval ago.
type HygieneReport struct {
	Ran     bool
	Deleted int
	Pruned  int64
}

// Hygiene runs the daily retention pass: on a CloudKit transport it deletes
// every mailbox record older than ActionMaxAge (server time) that no longer
// has work — a phone action already decided, a control, the hub's own
// records, anything nobody here can open — and then prunes the ledger. The
// stamp is written only after a run without errors, so a failed one is
// retried at the next call.
func (p *Processor) Hygiene(ctx context.Context) (HygieneReport, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.paused.Load() {
		return HygieneReport{}, nil
	}
	now := p.cfg.Clock()
	raw, ok, err := p.cfg.Store.Meta(hygieneStampKey)
	if err != nil {
		return HygieneReport{}, err
	}
	if last, perr := strconv.ParseFloat(raw, 64); ok && perr == nil &&
		now.Sub(time.Unix(0, int64(last*1e9))) < HygieneInterval {
		return HygieneReport{}, nil
	}
	rep := HygieneReport{Ran: true}
	var errs []error
	if p.cfg.Transport.Kind() == transport.KindCloudKit {
		boxes, err := p.mailboxes()
		if err != nil {
			return rep, err
		}
		for _, g := range byZone(boxes) { // the shared RelayZone once
			n, err := p.sweepZone(ctx, g, now)
			rep.Deleted += n
			if err != nil {
				log.Printf("hub: hygiene of device %s's mailbox: %s", g.boxes[0].id, errClass(err))
				errs = append(errs, err)
			}
		}
	}
	if rep.Pruned, err = p.cfg.Store.PruneLedger(now.Add(-(ActionMaxAge + retentionMargin))); err != nil {
		errs = append(errs, err)
	}
	if err := errors.Join(errs...); err != nil {
		return rep, err
	}
	if rep.Deleted > 0 || rep.Pruned > 0 {
		log.Printf("hub: hygiene deleted %d mailbox records and pruned %d ledger rows", rep.Deleted, rep.Pruned)
	}
	return rep, p.cfg.Store.SetMeta(hygieneStampKey, strconv.FormatFloat(float64(now.UnixNano())/1e9, 'f', -1, 64))
}

// sweepZone scans g's whole zone (from 0, apart from the pass's cursor) and
// deletes its stale records, each under the version scanned.
func (p *Processor) sweepZone(ctx context.Context, g zoneGroup, now time.Time) (int, error) {
	var stale []transport.DeleteItem
	var since uint64
	for {
		batch, err := p.cfg.Transport.Changes(ctx, g.zone, since)
		if err != nil {
			return 0, err
		}
		for _, rec := range batch.Changed {
			ok, err := p.isStale(g, rec, now)
			if err != nil {
				return 0, err
			}
			if ok {
				stale = append(stale, transport.DeleteItem{Name: rec.Name, Expect: transport.Expect{Mode: transport.ExpectSeq, Seq: rec.RecordSeq}})
			}
		}
		if !batch.More {
			break
		}
		since = batch.NewSeq
	}
	if len(stale) == 0 {
		return 0, nil
	}
	out, err := p.cfg.Transport.Delete(ctx, g.zone, stale)
	if err != nil {
		return 0, err
	}
	n := 0
	for _, o := range out {
		if o.Saved {
			n++
		}
	}
	return n, nil
}

// isStale reports whether rec is older than ActionMaxAge and has no work
// left: a phone action already decided, any phone control (it is deleted once
// read), a record of a phone with no mailbox in the zone, the hub's own
// records, or bytes nobody here can open. A phone's record is judged as its
// sender's (in the shared RelayZone, never as another phone's). A pending
// action still undecided waits for its expired echo, and the records of
// other lanes (device, recording_upload, future kinds) are kept, as the
// Swift hub keeps them.
func (p *Processor) isStale(g zoneGroup, rec transport.Stored, now time.Time) (bool, error) {
	if now.Sub(rec.ServerAt) <= ActionMaxAge {
		return false, nil
	}
	sender, ok := phoneSender(rec.Envelope)
	if !ok {
		return true, nil // the hub's own records, hellos and bytes that are no envelope
	}
	b, ok := g.box(sender)
	if !ok {
		return true, nil
	}
	o, err := p.cfg.Opener.FromPhone(b.zone, rec.Name, rec.Envelope)
	if err != nil {
		if !droppable(err) {
			return false, err
		}
		return true, nil // the hub's own records (wrong class) and anything that does not open
	}
	if o.Sender != b.id {
		return true, nil
	}
	switch o.Frame.Kind {
	case kindControl:
		return true, nil
	case kindAction:
		return p.decided(b, o)
	}
	return false, nil
}

// decided reports whether a phone's action record has nothing left to do:
// not pending (or received), or already decided — a legacy action done in
// the ledger, an ordered one at or below the phone's last applied seq.
func (p *Processor) decided(b mailbox, o secure.Opened) (bool, error) {
	var a wire.ActionRequest
	if !decodes(o.Frame.Payload, &a) || (a.Status != wire.StatusPending && a.Status != wire.StatusReceived) {
		return true, nil
	}
	if a.ActionSeq == nil {
		phase, _, _, err := p.cfg.Store.Phase(legacyName(a))
		return phase == state.PhaseDone, err
	}
	dev, linked, err := p.cfg.Store.Device(b.id.String())
	if err != nil || !linked {
		return false, err
	}
	return *a.ActionSeq <= dev.LastAppliedActionSeq, nil
}
