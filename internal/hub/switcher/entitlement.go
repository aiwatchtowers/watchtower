package switcher

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"maps"
	"time"

	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// A phone's relay entitlement lapsed (relay sim rule 16, rulings R31–R32).
// The hub hears of it three ways: the relay's ENTITLEMENT_EXPIRED control
// naming the phone in its detail (OnControl), the phone's own
// transport_switch(cloudkit, reason = entitlement_expired) (Request), or a
// hub write into the phone's relay mailbox refused ENTITLEMENT_INACTIVE
// (EntitlementInactive, acted on at the next Step). Each runs lapse, which
// never waits on the relay: whether another phone pays is the last account
// read that answered, and unknown counts as nobody (toward CloudKit is
// always allowed):
//
//   - the echoes queued for the phone's relay mailbox are owed and moved to
//     its CloudKit mailbox, written there before anything queued after them
//     (an action the hub applied before it heard counts as delivered); the
//     other controls queued for the relay mailbox are dropped;
//   - with no other phone known to pay, the hub moves to CloudKit as on
//     rule 11, by = entitlement_expired (superseding a request toward the
//     relay); a phone that asked while the hub already runs or moves there
//     is told where it runs;
//   - with another paying phone and the hub on the relay, it stays: the
//     phone is marked lapsed in the sidecar (devices.relay_lapsed_at and
//     relay_skip_before, one compare-and-set, so hub_on_relay goes once),
//     its held actions are dropped, and hub_on_relay is queued over CloudKit
//     after the owed echoes. The phone lists its unechoed actions as not
//     delivered, so none of its relay actions written before the lapse is
//     ever applied (Lapsed, kept across restarts and switches).
//
// The lapse ends only when an account read that answered lists the phone
// as paying again (PollOther, or its own transport_switch toward the relay);
// relay_skip_before stays.

// OnControl handles a relay server control the switcher acts on: an
// ENTITLEMENT_EXPIRED whose detail names a linked phone (its relay device id
// or its device id, R31) is that phone's lapse, at once. Other controls and
// a detail that names no linked phone are ignored.
func (s *Switcher) OnControl(_ context.Context, c transport.Control) error {
	if c.Kind != transport.EntitlementExpired || c.Detail == "" {
		return nil
	}
	device, ok, err := s.deviceNamed(c.Detail)
	if err != nil || !ok {
		return err
	}
	return s.lapse(device, false)
}

// Lapsed implements actions.Switch over the sidecar: on the relay, a phone
// lapsed now, or a record written (writtenAt, the relay's ServerAt) before
// its last lapse.
func (s *Switcher) Lapsed(k transport.Kind, device string, writtenAt time.Time) (bool, error) {
	if k != transport.KindRelay {
		return false, nil
	}
	dev, linked, err := s.c.Store.Device(device)
	if err != nil || !linked {
		return false, err
	}
	if dev.RelayLapsedAt != nil {
		return true, nil
	}
	return !writtenAt.IsZero() && dev.RelaySkipBefore != nil && !writtenAt.After(*dev.RelaySkipBefore), nil
}

// EntitlementInactive implements actions.Switch: a write into device's relay
// mailbox was refused ENTITLEMENT_INACTIVE. The lapse runs at the next Step
// (this is called from inside a processor's flush).
func (s *Switcher) EntitlementInactive(k transport.Kind, device string) {
	if k != transport.KindRelay {
		return
	}
	s.mu.Lock()
	if s.pending == nil {
		s.pending = map[string]bool{}
	}
	s.pending[canonical(device)] = true
	s.mu.Unlock()
	s.Kick()
}

// takePending empties the lapses waiting for a Step.
func (s *Switcher) takePending() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]string, 0, len(s.pending))
	for d := range s.pending {
		out = append(out, d)
	}
	s.pending = nil
	return out
}

// lapses runs every lapse waiting for a Step; one that fails waits for the
// next Step.
func (s *Switcher) lapses() {
	for _, d := range s.takePending() {
		if err := s.lapse(d, false); err != nil {
			log.Printf("hub: a lapsed relay entitlement waits (%s)", errClass(err))
			s.EntitlementInactive(transport.KindRelay, d)
		}
	}
}

// lapse is rule 16 for device (see the package note above); asked is the
// phone's own request, answered with where the hub runs when nothing moves.
func (s *Switcher) lapse(device string, asked bool) error {
	dev, linked, err := s.c.Store.Device(device)
	if err != nil || !linked {
		return err
	}
	id := canonical(dev.ID)
	others, err := s.othersPay(id)
	if err != nil {
		return err
	}
	stay := others && s.activeKind() == transport.KindRelay && s.heading() == transport.KindRelay
	if err := s.owe(dev.ID, stay); err != nil {
		return err
	}
	if stay || s.c.CloudKit == nil {
		return nil
	}
	s.mu.Lock()
	accepted, err := s.accept(wire.SwitchedByEntitlement, transport.KindCloudKit, s.now())
	s.mu.Unlock()
	if err != nil {
		return err
	}
	if accepted {
		log.Printf("hub: the relay entitlement of device %s lapsed and no other phone is known to pay: transport switch to cloudkit accepted", id)
		s.resetBackoff()
		s.Kick()
	} else if asked {
		s.answerWhereItRuns(dev.ID)
	}
	return nil
}

// heading is the transport the hub runs on, or moves to with a switch not
// carried out yet.
func (s *Switcher) heading() transport.Kind {
	s.mu.Lock()
	defer s.mu.Unlock()
	r, ok, err := s.record()
	switch {
	case err != nil || !ok || r.Done:
		return s.active
	case r.Epoch != 0 && r.Next != nil:
		return r.Next.Target
	}
	return r.Target
}

// readPaying reads who pays for the relay (bounded by the old-side timeout)
// and keeps the answer for othersPay.
func (s *Switcher) readPaying(ctx context.Context) (map[string]bool, error) {
	pctx, cancel := context.WithTimeout(ctx, s.oldSide())
	defer cancel()
	paying, err := s.c.Paying(pctx)
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	s.paying = maps.Clone(paying)
	s.mu.Unlock()
	return paying, nil
}

// othersPay reports whether a linked phone other than device paid for the
// relay at the last account read that answered; no such read is nobody.
func (s *Switcher) othersPay(device string) (bool, error) {
	s.mu.Lock()
	paying := s.paying
	s.mu.Unlock()
	if len(paying) == 0 {
		return false, nil
	}
	devices, err := s.c.Store.Devices()
	if err != nil {
		return false, err
	}
	for _, d := range devices {
		if id := canonical(d.ID); id != device && paying[id] {
			return true, nil
		}
	}
	return false, nil
}

// recheckLapsed ends the lapse of every lapsed phone that a fresh account
// read lists as paying (an unreadable account ends nothing).
func (s *Switcher) recheckLapsed(ctx context.Context) {
	if s.c.Paying == nil {
		return
	}
	devices, err := s.c.Store.Devices()
	if err != nil {
		return
	}
	var lapsed []string
	for _, d := range devices {
		if d.RelayLapsedAt != nil {
			lapsed = append(lapsed, d.ID)
		}
	}
	if len(lapsed) == 0 {
		return
	}
	paying, err := s.readPaying(ctx)
	if err != nil {
		return
	}
	for _, d := range lapsed {
		if paying[canonical(d)] {
			s.endLapse(d)
		}
	}
}

// endLapseIfPaying ends device's lapse when a fresh account read lists it
// as paying.
func (s *Switcher) endLapseIfPaying(ctx context.Context, device string) {
	dev, linked, err := s.c.Store.Device(device)
	if err != nil || !linked || dev.RelayLapsedAt == nil || s.c.Paying == nil {
		return
	}
	if paying, err := s.readPaying(ctx); err == nil && paying[canonical(dev.ID)] {
		s.endLapse(dev.ID)
	}
}

func (s *Switcher) endLapse(device string) {
	ended, err := s.c.Store.EndRelayLapse(device)
	if err != nil {
		log.Printf("hub: ending a relay lapse: %s", errClass(err))
		return
	}
	if ended {
		log.Printf("hub: device %s pays for the relay again", canonical(device))
	}
}

// owe moves device's queued relay echoes to its CloudKit mailbox (the rest
// of its relay queue is dropped) and, with stay, marks it lapsed — a
// compare-and-set — and on the first mark queues hub_on_relay there after
// them, in one transaction.
func (s *Switcher) owe(device string, stay bool) error {
	rp, cp := s.procs[transport.KindRelay], s.procs[transport.KindCloudKit]
	if rp == nil || cp == nil {
		return nil
	}
	from, okFrom, err := rp.QueueOf(device)
	if err != nil {
		return err
	}
	to, okTo, err := cp.QueueOf(device)
	if err != nil || !okTo {
		return err
	}
	var notice *state.Control
	if stay {
		row, ok, err := cp.SealControlFor(device, wire.Control{Kind: wire.ControlHubOnRelay}, 0)
		if err != nil {
			return fmt.Errorf("switcher: sealing hub_on_relay: %w", err)
		}
		if ok {
			notice = &row
		}
	}
	var moved int64
	told := false
	err = s.c.Store.WithTx(context.Background(), func(tx *sql.Tx) error {
		moved, told = 0, false
		if okFrom {
			n, err := state.OweOver(tx, device, from, to, actions.QueueEcho, wire.ControlResendFrom)
			if err != nil {
				return err
			}
			moved = n
		}
		if !stay {
			return nil
		}
		first, err := state.LapseRelay(tx, device, s.now())
		if err != nil || !first {
			return err
		}
		told = true
		if notice != nil {
			return state.Enqueue(tx, *notice)
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("switcher: moving what a lapsed phone is owed: %w", err)
	}
	if moved > 0 {
		log.Printf("hub: %d echoes owed to device %s move to its CloudKit mailbox", moved, canonical(device))
	}
	if told {
		log.Printf("hub: the relay entitlement of device %s lapsed; another phone pays, the hub stays on the relay", canonical(device))
	}
	return nil
}

// deviceNamed is the linked phone whose relay device id or device id is
// name.
func (s *Switcher) deviceNamed(name string) (string, bool, error) {
	devices, err := s.c.Store.Devices()
	if err != nil {
		return "", false, err
	}
	for _, d := range devices {
		if (d.RelayDeviceID != "" && d.RelayDeviceID == name) || canonical(d.ID) == canonical(name) {
			return d.ID, true, nil
		}
	}
	return "", false, nil
}
