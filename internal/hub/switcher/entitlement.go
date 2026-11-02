package switcher

import (
	"context"
	"database/sql"
	"fmt"
	"log"

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
// (EntitlementInactive, acted on at the next Step). Each runs lapse:
//
//   - the echoes queued for the phone's relay mailbox are owed and moved to
//     its CloudKit mailbox, written there before anything queued after them
//     (an action the hub applied before it heard counts as delivered); the
//     other controls queued for the relay mailbox are dropped;
//   - with no other linked phone paying for the relay and the hub on it,
//     the hub moves to CloudKit as on rule 11, by = entitlement_expired;
//   - with another paying phone, the hub stays on the relay, applies none of
//     the phone's actions there from now on (Lapsed) and tells it
//     hub_on_relay over CloudKit; the phone lists its unechoed actions as
//     not delivered.
//
// Lapsed is kept in memory: after a restart the next hub write refused for
// that phone raises it again, and an action applied meanwhile is echoed over
// CloudKit all the same.

// OnControl handles a relay server control the switcher acts on: an
// ENTITLEMENT_EXPIRED whose detail names a linked phone (its relay device id
// or its device id, R31) is that phone's lapse, at once. Other controls and
// a detail that names no linked phone are ignored.
func (s *Switcher) OnControl(ctx context.Context, c transport.Control) error {
	if c.Kind != transport.EntitlementExpired || c.Detail == "" {
		return nil
	}
	device, ok, err := s.deviceNamed(c.Detail)
	if err != nil || !ok {
		return err
	}
	return s.lapse(ctx, device)
}

// Lapsed implements actions.Switch: device's entitlement lapsed while the
// hub stays on the relay.
func (s *Switcher) Lapsed(k transport.Kind, device string) bool {
	if k != transport.KindRelay {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.lapsed[canonical(device)]
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
func (s *Switcher) lapses(ctx context.Context) {
	for _, d := range s.takePending() {
		if err := s.lapse(ctx, d); err != nil {
			log.Printf("hub: a lapsed relay entitlement waits (%s)", errClass(err))
			s.EntitlementInactive(transport.KindRelay, d)
		}
	}
}

// lapse is rule 16 for device (see the package note above).
func (s *Switcher) lapse(ctx context.Context, device string) error {
	dev, linked, err := s.c.Store.Device(device)
	if err != nil || !linked {
		return err
	}
	id := canonical(dev.ID)
	others, err := s.otherPaying(ctx, id)
	if err != nil {
		return err
	}
	stay := s.activeKind() == transport.KindRelay && others
	// hub_on_relay once per lapse: a second report (the phone's request
	// after the relay's control, a refused write) only moves what is owed.
	tell := stay && !s.Lapsed(transport.KindRelay, id)
	if err := s.owe(dev.ID, tell); err != nil {
		return err
	}
	if stay {
		s.mu.Lock()
		if s.lapsed == nil {
			s.lapsed = map[string]bool{}
		}
		s.lapsed[id] = true
		s.mu.Unlock()
		if tell {
			log.Printf("hub: the relay entitlement of device %s lapsed; another phone pays, the hub stays on the relay", id)
		}
		return nil
	}
	if s.activeKind() != transport.KindRelay || s.c.CloudKit == nil {
		return nil
	}
	s.mu.Lock()
	accepted, err := s.accept(wire.SwitchedByEntitlement, transport.KindCloudKit, s.now())
	s.mu.Unlock()
	if err != nil {
		return err
	}
	if accepted {
		log.Printf("hub: the relay entitlement of device %s lapsed and no phone pays: transport switch to cloudkit accepted", id)
		s.Kick()
	}
	return nil
}

// otherPaying reports whether a linked phone other than device pays for the
// relay. Without Paying nobody is known to pay.
func (s *Switcher) otherPaying(ctx context.Context, device string) (bool, error) {
	if s.c.Paying == nil {
		return false, nil
	}
	paying, err := s.c.Paying(ctx)
	if err != nil {
		return false, fmt.Errorf("switcher: reading who pays: %w", err)
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

// owe moves device's queued relay echoes to its CloudKit mailbox (the rest
// of its relay queue is dropped) and, with tell, queues hub_on_relay there
// after them, in one transaction.
func (s *Switcher) owe(device string, tell bool) error {
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
	if tell {
		row, ok, err := cp.SealControlFor(device, wire.Control{Kind: wire.ControlHubOnRelay}, 0)
		if err != nil {
			return fmt.Errorf("switcher: sealing hub_on_relay: %w", err)
		}
		if ok {
			notice = &row
		}
	}
	var moved int64
	err = s.c.Store.WithTx(context.Background(), func(tx *sql.Tx) error {
		if okFrom {
			n, err := state.OweOver(tx, device, from, to, actions.QueueEcho, wire.ControlResendFrom)
			if err != nil {
				return err
			}
			moved = n
		}
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
