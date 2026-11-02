package switcher

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"strconv"
	"time"

	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// switchRecord is the latest accepted switch (hub_meta transport_switch).
// ID is its transport_switched control id (one id for every copy). Epoch is
// the epoch it began, 0 until the rotation committed (with Epoch set the
// switch never rotates again). Done marks the notices queued and the
// transport moved (the markers owed are marker.go's). Next is a request
// accepted after the rotation, run once this one is done.
type switchRecord struct {
	ID     string         `json:"id"`
	From   transport.Kind `json:"from"`
	Target transport.Kind `json:"target"`
	By     string         `json:"by"`
	At     time.Time      `json:"at"`
	Epoch  uint32         `json:"epoch,omitempty"`
	Done   bool           `json:"done,omitempty"`
	Next   *request       `json:"next,omitempty"`
}

// request is an accepted request waiting for the switch in flight.
type request struct {
	Target transport.Kind `json:"target"`
	By     string         `json:"by"`
	At     time.Time      `json:"at"`
}

func loadRecord(q func(string) (string, bool, error)) (switchRecord, bool, error) {
	raw, ok, err := q(metaSwitch)
	if err != nil || !ok || raw == "" {
		return switchRecord{}, false, err
	}
	var r switchRecord
	if err := json.Unmarshal([]byte(raw), &r); err != nil {
		return switchRecord{}, false, fmt.Errorf("switcher: unreadable switch record: %w", err)
	}
	return r, true, nil
}

func (s *Switcher) record() (switchRecord, bool, error) { return loadRecord(s.c.Store.Meta) }

func recordTx(tx *sql.Tx) (switchRecord, bool, error) {
	return loadRecord(func(k string) (string, bool, error) { return state.MetaTx(tx, k) })
}

func saveRecordTx(tx *sql.Tx, r switchRecord) error {
	raw, err := json.Marshal(r)
	if err != nil {
		return err
	}
	return state.SetMetaTx(tx, metaSwitch, string(raw))
}

// Pending reports whether an accepted switch is not carried out yet.
func (s *Switcher) Pending() bool {
	r, ok, err := s.record()
	return err == nil && ok && !r.Done
}

// Request is a person's switch toward target (rules 8–10): from is the
// asking phone's device id or wire.SwitchedByEntitlement. Toward the relay
// it is rejected (*actions.SwitchRejected) within AntiFlap of the last
// accepted switch (too_soon with the wait), from a phone the relay account
// does not list as paying, or on a hub with no relay side; toward CloudKit
// it is always accepted. An accepted request is recorded (the last one
// wins) and carried out by Step; a request for the transport the hub is on
// or moving to changes nothing and re-sends the asking phone the notice of
// where the hub runs. A request toward CloudKit with reason
// entitlement_expired is the phone's lapse (sim rule 16, entitlement.go):
// the hub moves only when no other phone pays for the relay. It never calls
// into a processor's pass.
func (s *Switcher) Request(ctx context.Context, from string, target transport.Kind, reason string) error {
	if s.transport(target) == nil {
		return &actions.SwitchRejected{Reason: actions.SwitchNotSupported}
	}
	person := from != wire.SwitchedByEntitlement
	if person && target == transport.KindCloudKit && reason == wire.SwitchedByEntitlement {
		return s.lapse(ctx, from)
	}
	if !person && target != transport.KindCloudKit {
		return &actions.SwitchRejected{Reason: actions.SwitchNotSupported}
	}
	if target == transport.KindRelay && person && s.c.Paying != nil {
		paying, err := s.c.Paying(ctx)
		if err != nil {
			return fmt.Errorf("switcher: reading who pays: %w", err)
		}
		if !paying[canonical(from)] {
			return &actions.SwitchRejected{Reason: ReasonNotPaying}
		}
	}
	now := s.now()
	s.mu.Lock()
	accepted, err := s.accept(from, target, now)
	s.mu.Unlock()
	if err != nil {
		return err
	}
	if !accepted {
		if person {
			s.answerWhereItRuns(from)
		}
		return nil
	}
	if target == transport.KindRelay {
		s.mu.Lock()
		delete(s.lapsed, canonical(from)) // it pays again (checked above)
		s.mu.Unlock()
	}
	log.Printf("hub: transport switch to %s accepted", target)
	s.Kick()
	return nil
}

// ReasonNotPaying is transport_switch_rejected's reason for a switch toward
// the relay asked by a phone the relay account does not list as paying.
const ReasonNotPaying = "not_paying"

// accept records an accepted request under s.mu; false when the hub is on
// (or already moving to) target. A rejection is an *actions.SwitchRejected.
func (s *Switcher) accept(from string, target transport.Kind, now time.Time) (bool, error) {
	ok := false
	err := s.c.Store.WithTx(context.Background(), func(tx *sql.Tx) error {
		r, has, err := recordTx(tx)
		if err != nil {
			return err
		}
		heading := s.active
		switch {
		case has && !r.Done && r.Epoch == 0:
			heading = r.Target
		case has && !r.Done && r.Next != nil:
			heading = r.Next.Target
		case has && !r.Done:
			heading = r.Target
		}
		if target == heading {
			return nil
		}
		if target == transport.KindRelay {
			if wait, err := antiFlapWait(tx, now); err != nil {
				return err
			} else if wait > 0 {
				return &actions.SwitchRejected{Reason: wire.SwitchTooSoon, RetryAfter: wait}
			}
		}
		switch {
		case has && !r.Done && r.Epoch == 0:
			// Not rotated yet: the last request wins outright.
			r.Target, r.By, r.At = target, from, now
		case has && !r.Done:
			r.Next = &request{Target: target, By: from, At: now}
		default:
			id, err := newUUID()
			if err != nil {
				return err
			}
			r = switchRecord{ID: id, From: s.active, Target: target, By: from, At: now}
		}
		if err := saveRecordTx(tx, r); err != nil {
			return err
		}
		if err := state.SetMetaTx(tx, MetaSwitchedAt, stamp(now)); err != nil {
			return err
		}
		ok = true
		return state.SetMetaTx(tx, MetaSwitchedBy, from)
	})
	return ok, err
}

// antiFlapWait is what is left of AntiFlap since the last accepted switch.
func antiFlapWait(tx *sql.Tx, now time.Time) (time.Duration, error) {
	raw, ok, err := state.MetaTx(tx, MetaSwitchedAt)
	if err != nil || !ok {
		return 0, err
	}
	last, err := parseStamp(raw)
	if err != nil {
		return 0, fmt.Errorf("switcher: unreadable %s: %w", MetaSwitchedAt, err)
	}
	if wait := AntiFlap - now.Sub(last); wait > 0 {
		return wait, nil
	}
	return 0, nil
}

// SwitchedAt is the last accepted switch's time and who asked for it
// (hub_meta switched_at, switched_by); ok is false before the first.
func (s *Switcher) SwitchedAt() (at time.Time, by string, ok bool, err error) {
	raw, ok, err := s.c.Store.Meta(MetaSwitchedAt)
	if err != nil || !ok {
		return time.Time{}, "", false, err
	}
	at, err = parseStamp(raw)
	if err != nil {
		return time.Time{}, "", false, err
	}
	by, _, err = s.c.Store.Meta(MetaSwitchedBy)
	return at, by, err == nil, err
}

// Stale implements actions.Switch (rule 12a): a phone wrote on the inactive
// transport k. A phone that cannot follow the hub to the relay (it does not
// pay) gets hub_on_relay; one that has not acked the current epoch gets
// transport_switched again (a new id, its keybox sealed now); anyone else
// nothing. The answer is sealed in an epoch the phone holds: the one before
// the last switch while it has not acked the current one and that epoch is
// still accepted, else the current one.
func (s *Switcher) Stale(ctx context.Context, k transport.Kind, device string) (wire.Control, uint32, bool, error) {
	dev, linked, err := s.c.Store.Device(device)
	if err != nil || !linked {
		return wire.Control{}, 0, false, err
	}
	current, err := s.c.Keys.CurrentEpoch()
	if err != nil {
		return wire.Control{}, 0, false, err
	}
	epoch, err := s.sealEpoch(dev, current)
	if err != nil {
		return wire.Control{}, 0, false, err
	}
	active := s.activeKind()
	if active == k {
		return wire.Control{}, 0, false, nil
	}
	if active == transport.KindRelay && !s.canFollowToRelay(ctx, dev.ID) {
		return wire.Control{Kind: wire.ControlHubOnRelay}, epoch, true, nil
	}
	if dev.AckedEpoch >= current {
		return wire.Control{}, 0, false, nil
	}
	c, ok, err := s.whereItRuns(dev.ID, "")
	return c, epoch, ok, err
}

// sealEpoch is the epoch an answer to dev is sealed in (0 = the current).
func (s *Switcher) sealEpoch(dev state.Device, current uint32) (uint32, error) {
	if dev.AckedEpoch >= current || current <= 1 {
		return 0, nil
	}
	id, err := secure.ParseID(dev.ID)
	if err != nil {
		return 0, fmt.Errorf("switcher: a linked device id is not a UUID: %w", err)
	}
	ok, err := s.c.Keys.AcceptsRelayEpoch(current-1, id)
	if err != nil || !ok {
		return 0, err
	}
	return current - 1, nil
}

// canFollowToRelay: a phone follows the hub onto the relay only if the
// relay account lists it as paying; unknown (no Paying, an unreadable
// account) counts as able, so no phone is told it cannot follow by mistake.
func (s *Switcher) canFollowToRelay(ctx context.Context, device string) bool {
	if s.c.Paying == nil {
		return true
	}
	paying, err := s.c.Paying(ctx)
	if err != nil {
		return true
	}
	return paying[canonical(device)]
}

// stamp writes t as hub_meta's seconds since 1970 (decimal).
func stamp(t time.Time) string {
	return strconv.FormatFloat(float64(t.UnixNano())/1e9, 'f', -1, 64)
}

func parseStamp(raw string) (time.Time, error) {
	f, err := strconv.ParseFloat(raw, 64)
	if err != nil {
		return time.Time{}, err
	}
	return time.Unix(0, int64(f*1e9)), nil
}

// canonical is a device id in its uuidString form (ids compare case-
// insensitively).
func canonical(id string) string {
	if p, err := secure.ParseID(id); err == nil {
		return p.String()
	}
	return id
}

// newUUID is a random v4 UUID in Swift's uuidString form.
func newUUID() (string, error) {
	var id secure.ID
	if _, err := rand.Read(id[:]); err != nil {
		return "", fmt.Errorf("switcher: random: %w", err)
	}
	id[6] = id[6]&0x0f | 0x40
	id[8] = id[8]&0x3f | 0x80
	return id.String(), nil
}
