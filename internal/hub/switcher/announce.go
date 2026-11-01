package switcher

import (
	"context"
	"database/sql"
	"encoding/base64"
	"errors"
	"fmt"
	"log"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// Step carries out the accepted switch, if any (rule 11; the package doc's
// steps 1–5), and then any request accepted meanwhile. It is safe to call
// again after a crash or an error at any point: a rotated switch never
// rotates again.
func (s *Switcher) Step(ctx context.Context) error {
	s.stepMu.Lock()
	defer s.stepMu.Unlock()
	if s.c.Publisher != nil {
		// Paused from the rotation until the new transport is active, so no
		// slice of the new epoch lands on the transport being left; a
		// Resume without a Pause does nothing.
		defer s.c.Publisher.Resume()
	}
	for {
		r, ok, err := s.record()
		if err != nil || !ok || r.Done {
			return err
		}
		if r.Epoch == 0 {
			if r.Target == r.From {
				// The last request undid the first before it ran.
				if err := s.settleNoSwitch(r); err != nil {
					return err
				}
				continue
			}
			s.drain(ctx, r.From) // step 1
			if s.c.Publisher != nil {
				s.c.Publisher.Pause()
			}
			if err := s.rotate(r); err != nil { // step 2
				return err
			}
			continue // re-read: the record now carries the epoch
		}
		if p := s.procs[r.Target]; p != nil {
			// Read from the start once active: what waited there on
			// standby is read then (repeats come from the ledger).
			if err := p.Rewind(); err != nil {
				return fmt.Errorf("switcher: rewinding the %s mailboxes: %w", r.Target, err)
			}
		}
		if err := s.announce(r); err != nil { // step 3
			return err
		}
		s.leave(ctx, r)  // step 4
		s.arrive(ctx, r) // step 5
	}
}

// drain finishes every phone's mailbox on the transport being left, in the
// old epoch, if it answers within OldSideTimeout.
func (s *Switcher) drain(ctx context.Context, from transport.Kind) {
	p := s.procs[from]
	if p == nil {
		return
	}
	dctx, cancel := context.WithTimeout(ctx, OldSideTimeout)
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

// rotate begins the switch's epoch once: the record gets the new epoch in
// the rotation's own transaction, and a record replaced meanwhile (a later
// request won) rotates nothing.
func (s *Switcher) rotate(r switchRecord) error {
	err := s.c.Keys.RotateWith(identity.ReasonTransportSwitch, func(tx *sql.Tx) error {
		cur, ok, err := recordTx(tx)
		if err != nil {
			return err
		}
		if !ok || cur.ID != r.ID || cur.Epoch != 0 || cur.Target != r.Target {
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
		return saveRecordTx(tx, cur)
	})
	if err != nil {
		return fmt.Errorf("switcher: rotating for the switch: %w", err)
	}
	return nil
}

// notice is r's transport_switched for one phone (keybox sealed now in the
// current epoch), or ok false for a phone without keys to carry.
func (s *Switcher) notice(r switchRecord, kb wire.Keybox) (wire.Control, bool, error) {
	if kb.Keys == nil {
		return wire.Control{}, false, nil
	}
	id, err := secure.ParseID(kb.Grant.DeviceID)
	if err != nil {
		return wire.Control{}, false, nil
	}
	payload, err := wire.Marshal(kb)
	if err != nil {
		return wire.Control{}, false, err
	}
	defer clear(payload)
	sealed, err := s.sealer.Keybox(s.data, id, payload)
	if err != nil {
		return wire.Control{}, false, fmt.Errorf("switcher: sealing a keybox: %w", err)
	}
	box := base64.RawURLEncoding.EncodeToString(sealed.Envelope())
	target, by, epoch := string(r.Target), r.By, r.Epoch
	return wire.Control{
		ID: r.ID, Kind: wire.ControlSwitched, Target: &target, Epoch: &epoch, By: &by,
		At: &wire.Time{Time: r.At}, Keybox: &box,
	}, true, nil
}

// keyboxFor is device's keybox payload, ok false when it has none.
func (s *Switcher) keyboxFor(device string) (wire.Keybox, bool, error) {
	if s.c.Keyboxes == nil {
		return wire.Keybox{}, false, errors.New("switcher: no keyboxes")
	}
	boxes, err := s.c.Keyboxes()
	if err != nil {
		return wire.Keybox{}, false, err
	}
	for _, kb := range boxes {
		if canonical(kb.Grant.DeviceID) == canonical(device) && kb.Keys != nil {
			return kb, true, nil
		}
	}
	return wire.Keybox{}, false, nil
}

// announce is step 3: in one transaction every phone's transport_switched
// on both transports (the old copy in the old epoch), hub_on_relay toward
// the relay for every ordered phone that does not pay, hub_meta.transport,
// and the record done with its markers owed (and the next request, if one
// waits, as the new record).
func (s *Switcher) announce(r switchRecord) error {
	old := r.Epoch - 1
	boxes, err := s.c.Keyboxes()
	if err != nil {
		return fmt.Errorf("switcher: reading the keyboxes: %w", err)
	}
	var rows []state.Control
	add := func(k transport.Kind, device string, c wire.Control, epoch uint32) error {
		p := s.procs[k]
		if p == nil {
			return nil
		}
		row, ok, err := p.SealControlFor(device, c, epoch)
		if err != nil {
			return fmt.Errorf("switcher: sealing a %s notice: %w", k, err)
		}
		if ok {
			rows = append(rows, row)
		}
		return nil
	}
	for _, kb := range boxes {
		c, ok, err := s.notice(r, kb)
		if err != nil {
			return err
		}
		if !ok {
			continue
		}
		// One control id per phone, the same on both transports: a shared
		// RelayZone holds every phone's copy, so ids never repeat across
		// phones (the marker carries the switch's own id).
		if c.ID, err = newUUID(); err != nil {
			return err
		}
		device := kb.Grant.DeviceID
		if err := add(r.From, device, c, old); err != nil {
			return err
		}
		if err := add(r.Target, device, c, 0); err != nil {
			return err
		}
	}
	if r.Target == transport.KindRelay {
		free, err := s.freeOrderedPhones()
		if err != nil {
			log.Printf("hub: switch: who pays is unknown (%s): hub_on_relay is left to the phones' next write", errClass(err))
		}
		for _, d := range free {
			if err := add(transport.KindCloudKit, d, wire.Control{Kind: wire.ControlHubOnRelay}, old); err != nil {
				return err
			}
		}
	}
	owed := map[transport.Kind]uint32{r.From: old}
	if r.Target == transport.KindRelay && s.c.Relay != nil {
		owed[transport.KindRelay] = r.Epoch
	}
	err = s.c.Store.WithTx(context.Background(), func(tx *sql.Tx) error {
		cur, ok, err := recordTx(tx)
		if err != nil {
			return err
		}
		if !ok || cur.ID != r.ID || cur.Done {
			return nil // finished by an earlier Step
		}
		for _, row := range rows {
			if err := state.Enqueue(tx, row); err != nil {
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
	if err != nil {
		return fmt.Errorf("switcher: queueing the switch notices: %w", err)
	}
	log.Printf("hub: transport switched from %s to %s (epoch %d, %d notices queued)", r.From, r.Target, r.Epoch, len(rows))
	return nil
}

// queueNextTx turns a request accepted during the switch into the next
// record.
func (s *Switcher) queueNextTx(tx *sql.Tx, done switchRecord) error {
	if done.Next == nil || done.Next.Target == done.Target {
		return nil
	}
	id, err := newUUID()
	if err != nil {
		return err
	}
	return saveRecordTx(tx, switchRecord{ID: id, From: done.Target, Target: done.Next.Target, By: done.Next.By, At: done.Next.At})
}

// freeOrderedPhones lists the ordered phones the relay account does not
// list as paying.
func (s *Switcher) freeOrderedPhones() ([]string, error) {
	if s.c.Paying == nil {
		return nil, nil
	}
	paying, err := s.c.Paying(context.Background())
	if err != nil {
		return nil, err
	}
	devices, err := s.c.Store.Devices()
	if err != nil {
		return nil, err
	}
	var out []string
	for _, d := range devices {
		if d.Ordered && !paying[canonical(d.ID)] {
			out = append(out, d.ID)
		}
	}
	return out, nil
}

// leave is step 4: the old transport's queue (the notices) and its marker,
// written before the hub stops publishing there, each within
// OldSideTimeout; what does not land stays owed.
func (s *Switcher) leave(ctx context.Context, r switchRecord) {
	p := s.procs[r.From]
	if p == nil {
		return
	}
	lctx, cancel := context.WithTimeout(ctx, OldSideTimeout)
	defer cancel()
	if _, failed, err := p.FlushControls(lctx); err != nil || failed > 0 {
		log.Printf("hub: switch: the notices on %s wait for it (%s)", r.From, errClass(err))
	}
	s.writeOwedMarkers(lctx)
}

// arrive is step 5: the new transport is active, its mailboxes are read from
// the start, its queue is written and the publisher resumes there with a
// full diff.
func (s *Switcher) arrive(ctx context.Context, r switchRecord) {
	s.mu.Lock()
	s.active = r.Target
	s.mu.Unlock()
	if p := s.procs[r.Target]; p != nil {
		if err := p.Rewind(); err != nil {
			log.Printf("hub: switch: the %s mailboxes were not rewound (%s)", r.Target, errClass(err))
		}
		if _, _, err := p.FlushControls(ctx); err != nil {
			log.Printf("hub: switch: the notices on %s wait (%s)", r.Target, errClass(err))
		}
	}
	s.writeOwedMarkers(ctx)
	if s.c.Publisher != nil {
		s.c.Publisher.Resume()
	}
}

// settleNoSwitch ends a record whose last request asks for the transport the
// hub is on: nothing rotates; every phone is told where the hub runs.
func (s *Switcher) settleNoSwitch(r switchRecord) error {
	err := s.c.Store.WithTx(context.Background(), func(tx *sql.Tx) error {
		cur, ok, err := recordTx(tx)
		if err != nil || !ok || cur.ID != r.ID || cur.Epoch != 0 {
			return err
		}
		cur.Done = true
		return saveRecordTx(tx, cur)
	})
	if err != nil {
		return err
	}
	s.answerWhereItRuns(r.By)
	return nil
}

// whereItRuns is a transport_switched telling device where the hub runs now
// (the last switch's by and at, the current epoch, its keybox sealed now)
// under id ("" = a new one); ok false for a phone with no keys.
func (s *Switcher) whereItRuns(device, id string) (wire.Control, bool, error) {
	kb, ok, err := s.keyboxFor(device)
	if err != nil || !ok {
		return wire.Control{}, false, err
	}
	current, err := s.c.Keys.CurrentEpoch()
	if err != nil {
		return wire.Control{}, false, err
	}
	r := switchRecord{ID: id, Target: s.activeKind(), Epoch: current, At: s.now()}
	if at, by, ok, err := s.SwitchedAt(); err == nil && ok {
		r.At, r.By = at, by
	}
	return s.notice(r, kb)
}

// answerWhereItRuns queues for device, on both transports, where the hub
// runs (a request for the transport it is on). Best effort: logged.
func (s *Switcher) answerWhereItRuns(device string) {
	if device == "" || device == wire.SwitchedByEntitlement {
		return
	}
	id, err := newUUID()
	if err != nil {
		return
	}
	c, ok, err := s.whereItRuns(device, id)
	if err != nil || !ok {
		return
	}
	// Sealed before the transaction: the sidecar has one connection.
	var rows []state.Control
	for _, p := range s.procs {
		row, ok, err := p.SealControlFor(device, c, 0)
		if err != nil {
			log.Printf("hub: switch: telling a phone where the hub runs: %s", errClass(err))
			return
		}
		if ok {
			rows = append(rows, row)
		}
	}
	err = s.c.Store.WithTx(context.Background(), func(tx *sql.Tx) error {
		for _, row := range rows {
			if err := state.Enqueue(tx, row); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		log.Printf("hub: switch: telling a phone where the hub runs: %s", errClass(err))
	}
}
