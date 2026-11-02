package switcher

import (
	"context"
	"database/sql"
	"encoding/base64"
	"fmt"
	"log"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// Step carries out the accepted switch, if any (the package doc's steps
// 1–5), and then any request accepted meanwhile. It is safe to call again
// after a crash or an error at any point: a rotated switch never rotates
// again. The old side costs it at most the old-side timeout (the drain);
// the old transport's notices and marker are PollOther's.
func (s *Switcher) Step(ctx context.Context) error {
	s.stepMu.Lock()
	defer s.stepMu.Unlock()
	s.lapses()
	for {
		r, ok, err := s.record()
		if err != nil || !ok || r.Done {
			return err
		}
		s.holdPublisher() // step 1 (idempotent; New holds it after a restart)
		if r.Epoch == 0 {
			if r.Target == r.From {
				// The last request undid the first before it ran.
				if err := s.settleNoSwitch(r); err != nil {
					return err
				}
				continue
			}
			s.drain(ctx, r.From) // step 2
			s.pauseOld(r)
			skipped, err := s.rotate(r) // step 3
			if err != nil || skipped {
				if p := s.procs[r.From]; p != nil {
					p.ResumeFor(pauseReason) // not rotated: the old side is still the hub's
				}
				if err != nil {
					return err
				}
			}
			continue // re-read: the record now carries the epoch
		}
		s.pauseOld(r)
		if err := s.announce(r); err != nil { // step 4
			return err
		}
		s.arrive(ctx, r) // step 5
	}
}

// drain finishes every phone's mailbox on the transport being left, in the
// old epoch, if it answers within the old-side timeout.
func (s *Switcher) drain(ctx context.Context, from transport.Kind) {
	p := s.procs[from]
	if p == nil {
		return
	}
	dctx, cancel := context.WithTimeout(ctx, s.oldSide())
	defer cancel()
	for range 10 {
		rep, err := p.Pass(dctx)
		if err != nil {
			log.Printf("hub: switch: the %s mailboxes were not finished (%s); switching anyway", from, errClass(err))
			return
		}
		if rep.Remaining == 0 {
			return
		}
	}
}

// rotate begins the switch's epoch once: the record gets the new epoch, and
// switched_at/switched_by the switch, in the rotation's own transaction; a
// record replaced meanwhile (a later request won) rotates nothing (skipped).
func (s *Switcher) rotate(r switchRecord) (skipped bool, err error) {
	skipped = true
	err = s.c.Keys.RotateWith(identity.ReasonTransportSwitch, func(tx *sql.Tx) error {
		cur, ok, err := recordTx(tx)
		if err != nil {
			return err
		}
		if !ok || cur.ID != r.ID || cur.Epoch != 0 || cur.Target != r.Target || cur.Target == cur.From {
			return identity.ErrSkipRotation
		}
		epochs, err := state.EpochsTx(tx)
		if err != nil {
			return err
		}
		if len(epochs) == 0 {
			return identity.ErrKeysUnavailable
		}
		cur.Epoch = epochs[len(epochs)-1].Epoch + 1
		if err := state.SetMetaTx(tx, MetaSwitchedAt, stamp(cur.At)); err != nil {
			return err
		}
		if err := state.SetMetaTx(tx, MetaSwitchedBy, cur.By); err != nil {
			return err
		}
		skipped = false
		return saveRecordTx(tx, cur)
	})
	if err != nil {
		return false, fmt.Errorf("switcher: rotating for the switch: %w", err)
	}
	return skipped, nil
}

// notice is a transport_switched for one phone (keybox sealed now in the
// current epoch) under a new control id, or ok false for a phone without
// keys to carry or whose keybox cannot be sealed (logged).
func (s *Switcher) notice(target transport.Kind, epoch uint32, by string, at wire.Time, kb wire.Keybox) (wire.Control, bool) {
	if kb.Keys == nil {
		return wire.Control{}, false
	}
	id, err := secure.ParseID(kb.Grant.DeviceID)
	if err != nil {
		return wire.Control{}, false
	}
	payload, err := wire.Marshal(kb)
	if err != nil {
		log.Printf("hub: switch: a keybox does not encode (%s): that phone gets no notice", errClass(err))
		return wire.Control{}, false
	}
	defer clear(payload)
	sealed, err := s.sealer.Keybox(s.data, id, payload)
	if err != nil {
		log.Printf("hub: switch: a keybox does not seal (%s): that phone gets no notice", errClass(err))
		return wire.Control{}, false
	}
	cid, err := newUUID()
	if err != nil {
		return wire.Control{}, false
	}
	box := base64.RawURLEncoding.EncodeToString(sealed.Envelope())
	t := string(target)
	return wire.Control{ID: cid, Kind: wire.ControlSwitched, Target: &t, Epoch: &epoch, By: &by, At: &at, Keybox: &box}, true
}

// queuedRow is one sealed control row and the phone it is for.
type queuedRow struct {
	device string
	row    state.Control
}

// sealFor seals c for device on k's transport in epoch; a phone it cannot be
// sealed for is logged and skipped.
func (s *Switcher) sealFor(k transport.Kind, device string, c wire.Control, epoch uint32) (queuedRow, bool) {
	p := s.procs[k]
	if p == nil {
		return queuedRow{}, false
	}
	row, ok, err := p.SealControlFor(device, c, epoch)
	if err != nil {
		log.Printf("hub: switch: a %s %s does not seal (%s): skipped for that phone", k, c.Kind, errClass(err))
		return queuedRow{}, false
	}
	return queuedRow{device: device, row: row}, ok
}

// announce is step 4. Everything is sealed first (the sidecar has one
// connection), then one transaction re-checks each phone is still linked and
// queues its rows, sets hub_meta.transport, rewinds the new transport's
// mailboxes, owes the markers and ends the record (the next request, if one
// waits, becomes the new record); the in-memory transport moves with the
// commit and the old processor resumes, now on standby.
func (s *Switcher) announce(r switchRecord) error {
	old := r.Epoch - 1
	boxes, err := s.c.Keyboxes()
	if err != nil {
		return fmt.Errorf("switcher: reading the keyboxes: %w", err)
	}
	devices, err := s.c.Store.Devices()
	if err != nil {
		return err
	}
	byID := map[string]state.Device{}
	for _, d := range devices {
		byID[canonical(d.ID)] = d
	}
	var rows []queuedRow
	add := func(q queuedRow, ok bool) {
		if ok {
			rows = append(rows, q)
		}
	}
	at := wire.Time{Time: r.At}
	for _, kb := range boxes {
		dev, linked := byID[canonical(kb.Grant.DeviceID)]
		if !linked {
			continue
		}
		c, ok := s.notice(r.Target, r.Epoch, r.By, at, kb)
		if !ok {
			continue
		}
		add(s.sealFor(r.From, dev.ID, c, s.sealEpochFor(dev, old, old)))
		add(s.sealFor(r.Target, dev.ID, c, 0))
	}
	if r.Target == transport.KindRelay {
		free, err := s.freeOrderedPhones()
		if err != nil {
			log.Printf("hub: switch: who pays is unknown (%s): hub_on_relay is left to the phones' next write", errClass(err))
		}
		for _, d := range free {
			add(s.sealFor(transport.KindCloudKit, d.ID, wire.Control{Kind: wire.ControlHubOnRelay}, s.sealEpochFor(d, old, old)))
		}
	}
	var rewind []string
	if p := s.procs[r.Target]; p != nil {
		if rewind, err = p.MailboxZones(); err != nil {
			return err
		}
	}
	owed := map[transport.Kind]uint32{r.From: old}
	if r.Target == transport.KindRelay && s.c.Relay != nil {
		owed[transport.KindRelay] = r.Epoch
	}
	queued := 0
	s.mu.Lock()
	err = s.c.Store.WithTx(context.Background(), func(tx *sql.Tx) error {
		queued = 0
		cur, ok, err := recordTx(tx)
		if err != nil {
			return err
		}
		if !ok || cur.ID != r.ID || cur.Done {
			return nil // finished by an earlier Step
		}
		for _, q := range rows {
			if _, linked, err := state.LinkNonceTx(tx, q.device); err != nil {
				return err
			} else if !linked {
				continue // unlinked meanwhile
			}
			if err := state.Enqueue(tx, q.row); err != nil {
				return err
			}
			queued++
		}
		for _, z := range rewind {
			if err := state.SetZoneTokenTx(tx, z, 0); err != nil {
				return err
			}
		}
		if err := state.SetMetaTx(tx, MetaTransport, string(r.Target)); err != nil {
			return err
		}
		if err := s.oweMarkersTx(tx, r, owed); err != nil {
			return err
		}
		cur.Done = true
		if err := saveRecordTx(tx, cur); err != nil {
			return err
		}
		return s.queueNextTx(tx, cur)
	})
	if err == nil {
		s.active = r.Target
	}
	s.mu.Unlock()
	if err != nil {
		return fmt.Errorf("switcher: queueing the switch notices: %w", err)
	}
	if p := s.procs[r.From]; p != nil {
		p.ResumeFor(pauseReason) // on standby now: it seals nothing in the new epoch
	}
	log.Printf("hub: transport switched from %s to %s (epoch %d, %d notices queued)", r.From, r.Target, r.Epoch, queued)
	return nil
}

// queueNextTx turns a request accepted during the switch into the next
// record.
func (s *Switcher) queueNextTx(tx *sql.Tx, done switchRecord) error {
	if done.Next == nil {
		return nil
	}
	id, err := newUUID()
	if err != nil {
		return err
	}
	n := done.Next
	return saveRecordTx(tx, switchRecord{ID: id, From: done.Target, Target: n.Target, By: n.By, At: n.At, Waiting: n.Waiting})
}

// freeOrderedPhones lists the ordered phones the relay account does not
// list as paying.
func (s *Switcher) freeOrderedPhones() ([]state.Device, error) {
	if s.c.Paying == nil {
		return nil, nil
	}
	pctx, cancel := context.WithTimeout(context.Background(), s.oldSide())
	defer cancel()
	paying, err := s.readPaying(pctx)
	if err != nil {
		return nil, err
	}
	devices, err := s.c.Store.Devices()
	if err != nil {
		return nil, err
	}
	var out []state.Device
	for _, d := range devices {
		if d.Ordered && !paying[canonical(d.ID)] {
			out = append(out, d)
		}
	}
	return out, nil
}

// arrive is step 5: the new transport's queue is written (bounded) with its
// marker, and the publisher resumes there with a full diff.
func (s *Switcher) arrive(ctx context.Context, r switchRecord) {
	if p := s.procs[r.Target]; p != nil {
		actx, cancel := context.WithTimeout(ctx, s.oldSide())
		if _, _, err := p.FlushControls(actx); err != nil {
			log.Printf("hub: switch: the notices on %s wait (%s)", r.Target, errClass(err))
		}
		cancel()
	}
	s.writeOwedMarkers(ctx, r.Target)
	s.releasePublisher()
}

// settleNoSwitch ends a record whose last request asks for the transport the
// hub is on: nothing rotates; the asking phone and those it replaced are
// told where the hub runs.
func (s *Switcher) settleNoSwitch(r switchRecord) error {
	s.mu.Lock()
	err := s.c.Store.WithTx(context.Background(), func(tx *sql.Tx) error {
		cur, ok, err := recordTx(tx)
		if err != nil || !ok || cur.ID != r.ID || cur.Epoch != 0 {
			return err
		}
		cur.Done = true
		return saveRecordTx(tx, cur)
	})
	s.mu.Unlock()
	if err != nil {
		return err
	}
	for _, d := range appendWaiting(r.Waiting, r.By) {
		s.answerWhereItRuns(d)
	}
	s.releasePublisher()
	return nil
}

// whereItRuns is a transport_switched telling device where the hub runs:
// the committed transport, the last switch's by and at, the current epoch,
// its keybox sealed now; ok false for a phone with no keys.
func (s *Switcher) whereItRuns(device string) (wire.Control, bool, error) {
	boxes, err := s.c.Keyboxes()
	if err != nil {
		return wire.Control{}, false, err
	}
	current, err := s.c.Keys.CurrentEpoch()
	if err != nil {
		return wire.Control{}, false, err
	}
	target := s.activeKind()
	at, by := wire.Time{Time: s.now()}, ""
	if t, b, ok, err := s.SwitchedAt(); err == nil && ok {
		at, by = wire.Time{Time: t}, b
	}
	for _, kb := range boxes {
		if canonical(kb.Grant.DeviceID) == canonical(device) {
			c, ok := s.notice(target, current, by, at, kb)
			return c, ok, nil
		}
	}
	return wire.Control{}, false, nil
}

// answerWhereItRuns queues for device, on both transports, where the hub
// runs (a request for the transport it is on, or one a later request
// replaced), each copy sealed in an epoch the phone holds. Best effort:
// logged.
func (s *Switcher) answerWhereItRuns(device string) {
	if device == "" || device == wire.SwitchedByEntitlement {
		return
	}
	dev, linked, err := s.c.Store.Device(device)
	if err != nil || !linked {
		return
	}
	c, ok, err := s.whereItRuns(device)
	if err != nil || !ok {
		return
	}
	current, err := s.c.Keys.CurrentEpoch()
	if err != nil {
		return
	}
	epoch := s.sealEpochFor(dev, current, s.epochBeforeLastSwitch())
	// Sealed before the transaction: the sidecar has one connection.
	var rows []queuedRow
	for k := range s.procs {
		if q, ok := s.sealFor(k, dev.ID, c, epoch); ok {
			rows = append(rows, q)
		}
	}
	err = s.c.Store.WithTx(context.Background(), func(tx *sql.Tx) error {
		for _, q := range rows {
			if err := state.Enqueue(tx, q.row); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		log.Printf("hub: switch: telling a phone where the hub runs: %s", errClass(err))
	}
}
