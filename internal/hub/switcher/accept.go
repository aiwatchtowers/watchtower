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
// ID is the switch's own id (the marker carries it; each phone's
// transport_switched has its own control id). Epoch is the epoch it began,
// 0 until the rotation committed (with Epoch set the switch never rotates
// again). Done marks the notices queued and the transport moved (the
// markers owed are marker.go's). Waiting lists the phones whose request a
// later one replaced before the rotation: they are answered when it ends.
// Next is a request accepted after the rotation, run once this one is done.
type switchRecord struct {
	ID      string         `json:"id"`
	From    transport.Kind `json:"from"`
	Target  transport.Kind `json:"target"`
	By      string         `json:"by"`
	At      time.Time      `json:"at"`
	Epoch   uint32         `json:"epoch,omitempty"`
	Done    bool           `json:"done,omitempty"`
	Waiting []string       `json:"waiting,omitempty"`
	Next    *request       `json:"next,omitempty"`
}

// request is an accepted request waiting for the switch in flight.
type request struct {
	Target  transport.Kind `json:"target"`
	By      string         `json:"by"`
	At      time.Time      `json:"at"`
	Waiting []string       `json:"waiting,omitempty"`
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
// it is rejected (*actions.SwitchRejected) within AntiFlap of the last switch
// (too_soon with the wait), from a phone the relay account does not list as
// paying (not_paying; an account that cannot be read counts as paying, as in
// Stale), or on a hub with no relay side; toward CloudKit it is always
// accepted. An accepted request is recorded (the last one wins) and carried
// out by Step; a request for the transport the hub is on or moving to
// changes nothing and re-sends the asking phone where the hub runs. It never
// calls into a processor's pass.
func (s *Switcher) Request(ctx context.Context, from string, target transport.Kind, _ string) error {
	if s.transport(target) == nil {
		return &actions.SwitchRejected{Reason: actions.SwitchNotSupported}
	}
	person := from != wire.SwitchedByEntitlement
	if !person && target != transport.KindCloudKit {
		return &actions.SwitchRejected{Reason: actions.SwitchNotSupported}
	}
	if target == transport.KindRelay && person && !s.canFollowToRelay(ctx, from) {
		return &actions.SwitchRejected{Reason: wire.SwitchNotPaying}
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
	log.Printf("hub: transport switch to %s accepted", target)
	s.resetBackoff()
	s.Kick()
	return nil
}

// accept records an accepted request under s.mu; false when the hub is on
// (or already moving to) target. A rejection is an *actions.SwitchRejected.
func (s *Switcher) accept(from string, target transport.Kind, now time.Time) (bool, error) {
	ok := false
	err := s.c.Store.WithTx(context.Background(), func(tx *sql.Tx) error {
		r, has, err := recordTx(tx)
		if err != nil {
			return err
		}
		pending := has && !r.Done
		heading := s.active
		switch {
		case pending && r.Epoch != 0 && r.Next != nil:
			heading = r.Next.Target
		case pending:
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
		case pending && r.Epoch == 0:
			// Not rotated yet: the last request wins outright; the replaced
			// requester is answered when it ends.
			r.Waiting = appendWaiting(r.Waiting, r.By)
			r.Target, r.By, r.At = target, from, now
		case pending && r.Next != nil:
			r.Next = &request{Target: target, By: from, At: now, Waiting: appendWaiting(r.Next.Waiting, r.Next.By)}
		case pending:
			r.Next = &request{Target: target, By: from, At: now}
		default:
			id, err := newUUID()
			if err != nil {
				return err
			}
			r = switchRecord{ID: id, From: s.active, Target: target, By: from, At: now}
		}
		ok = true
		return saveRecordTx(tx, r)
	})
	return ok, err
}

func appendWaiting(w []string, by string) []string {
	if by == "" || by == wire.SwitchedByEntitlement {
		return w
	}
	for _, x := range w {
		if x == by {
			return w
		}
	}
	return append(w, by)
}

// antiFlapWait is what is left of AntiFlap since the last switch that
// rotated (switched_at).
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

// SwitchedAt is the last switch's time and who asked for it (hub_meta
// switched_at, switched_by, written by the rotation of a switch that moves
// the hub); ok is false before the first.
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
// nothing. The answer is sealed in an epoch the phone holds (sealEpochFor).
func (s *Switcher) Stale(ctx context.Context, k transport.Kind, device string) (wire.Control, uint32, bool, error) {
	dev, linked, err := s.c.Store.Device(device)
	if err != nil || !linked {
		return wire.Control{}, 0, false, err
	}
	current, err := s.c.Keys.CurrentEpoch()
	if err != nil {
		return wire.Control{}, 0, false, err
	}
	active := s.activeKind()
	if active == k {
		return wire.Control{}, 0, false, nil
	}
	epoch := s.sealEpochFor(dev, current, s.epochBeforeLastSwitch())
	if active == transport.KindRelay && !s.canFollowToRelay(ctx, dev.ID) {
		return wire.Control{Kind: wire.ControlHubOnRelay}, epoch, true, nil
	}
	if dev.AckedEpoch >= current {
		return wire.Control{}, 0, false, nil
	}
	c, ok, err := s.whereItRuns(dev.ID)
	return c, epoch, ok, err
}

// epochBeforeLastSwitch is the epoch the last switch left (every phone that
// did not follow holds it); 0 before any switch rotated.
func (s *Switcher) epochBeforeLastSwitch() uint32 {
	r, ok, err := s.record()
	if err != nil || !ok || r.Epoch <= 1 {
		return 0
	}
	return r.Epoch - 1
}

// sealEpochFor is the epoch to seal a control for dev in, never above
// ceiling: the epoch the phone acked, else each of fallbacks, the first one
// its relay keys are still accepted in; 0 (the current epoch) when none is.
// A failing keyring read also gives 0, so one phone never stops a switch.
func (s *Switcher) sealEpochFor(dev state.Device, ceiling uint32, fallbacks ...uint32) uint32 {
	current, err := s.c.Keys.CurrentEpoch()
	if err != nil {
		return 0
	}
	id, err := secure.ParseID(dev.ID)
	if err != nil {
		return 0
	}
	for _, e := range append([]uint32{dev.AckedEpoch}, fallbacks...) {
		if e == 0 || e > ceiling {
			continue
		}
		if e >= current {
			return 0
		}
		if ok, err := s.c.Keys.AcceptsRelayEpoch(e, id); err == nil && ok {
			return e
		}
	}
	return 0
}

// canFollowToRelay: a phone follows the hub onto the relay only if the
// relay account lists it as paying; unknown (no Paying, an unreadable or
// unanswered account read) counts as able, so no phone is refused or told
// it cannot follow by mistake, and no mailbox waits on the account.
func (s *Switcher) canFollowToRelay(ctx context.Context, device string) bool {
	if s.c.Paying == nil {
		return true
	}
	pctx, cancel := context.WithTimeout(ctx, s.oldSide())
	defer cancel()
	paying, err := s.c.Paying(pctx)
	if err != nil {
		log.Printf("hub: switch: the relay account is unreadable (%s): the phone counts as paying", errClass(err))
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
