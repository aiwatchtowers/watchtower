package switcher

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"strings"
	"time"

	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// relayLink is the throttle of checkRelayLink; in memory only, so the first
// check after a start reads (a restart finishes a switch a crash cut short:
// a zero last is always NoPayerPoll ago). The RelayLinkSoon flag is
// Switcher.rlSoon.
type relayLink struct {
	last        time.Time // when the last read was tried (zero = none yet)
	retryAt     time.Time // a too_soon's end (zero = none)
	loggedClass string    // the last "switch waits" class logged
}

// RelayLinkSoon marks the next relay-link check due (it skips the
// NoPayerPoll throttle, never an anti-flap wait) and kicks Run. The runtime
// calls it on a confirm and when an account read newly lists a linked phone.
// Safe from any goroutine.
func (s *Switcher) RelayLinkSoon() {
	s.rlSoon.Store(true)
	s.Kick()
}

// relayLinkSince is the relay_link_since stamp for a start at now: the
// second before now's whole second. The link center writes linked_at
// truncated to the second and a candidate's linked_at must come strictly
// after the stamp, so a link confirmed in the same second as the start
// counts (its linked_at is now's whole second).
func relayLinkSince(now time.Time) time.Time {
	return now.Truncate(time.Second).Add(-time.Second)
}

// markRelayLinkSince writes hub_meta.relay_link_since (relayLinkSince) at
// the first start of a build that carries the relay-link check. Its writers
// are this (only when unset) and relayLinkCandidates (only ever back to
// relayLinkSince(now), when the stamp lies in the future). A failure never stops the hub: it is logged (class only)
// and leaves the key unset, which means no candidate, the check off until a
// later start writes it.
func (s *Switcher) markRelayLinkSince() {
	_, ok, err := s.c.Store.Meta(MetaRelayLinkSince)
	if err == nil && !ok {
		err = s.c.Store.SetMeta(MetaRelayLinkSince, stamp(relayLinkSince(s.now())))
	}
	if err != nil {
		log.Printf("hub: a phone linked over Relay: switch waits (store)")
	}
}

// relayLinkCandidates are the linked phones that may move a CloudKit hub to
// the relay, in devices order (linked_at, device_id): each was confirmed
// through a relay pairing slot (hub_meta relay_slot_links, written by the
// link center: an empty iCloud user alone cannot tell a slot link from a
// CloudKit link whose owner was unreadable) under the link nonce its row
// still carries (a re-link the record missed never counts), has a relay id
// and no iCloud route, and linked after both the last switch and
// relay_link_since, so a later decision wins and a link from before the
// update never counts. An
// unset relay_link_since means none; an unreadable or undecodable
// relay_slot_links is an error (logged as store, no candidate).
//
// A relay_link_since in the future (the Mac's clock ran ahead when it was
// written) is pulled back to relayLinkSince(now), never forward. Known limit: a phone linked
// before the update while the clock ran ahead may carry a linked_at later
// than a relay_link_since written after the clock was corrected, and counts.
func (s *Switcher) relayLinkCandidates(now time.Time) ([]state.Device, error) {
	raw, ok, err := s.c.Store.Meta(MetaRelayLinkSince)
	if err != nil || !ok {
		return nil, err
	}
	after, err := parseStamp(raw)
	if err != nil {
		return nil, fmt.Errorf("switcher: unreadable %s: %w", MetaRelayLinkSince, err)
	}
	if after.After(now) {
		after = relayLinkSince(now)
		if err := s.c.Store.SetMeta(MetaRelayLinkSince, stamp(after)); err != nil {
			return nil, err
		}
	}
	switchedAt, _, switched, err := s.SwitchedAt()
	if err != nil {
		return nil, err
	}
	if switched && switchedAt.After(after) {
		after = switchedAt
	}
	devices, err := s.c.Store.Devices()
	if err != nil {
		return nil, err
	}
	routes, err := s.c.Store.ICloudRoutes()
	if err != nil {
		return nil, err
	}
	slot, err := s.c.Store.RelaySlotLinked()
	if err != nil {
		return nil, err
	}
	var out []state.Device
	for _, d := range devices {
		if d.LinkNonce != "" && slot[strings.ToUpper(d.ID)] == d.LinkNonce && d.RelayDeviceID != "" && !routes[strings.ToLower(d.ID)] && d.LinkedAt.After(after) {
			out = append(out, d)
		}
	}
	return out, nil
}

// relayLinkDue is the throttle, under rlMu: due once retryAt has passed and
// either RelayLinkSoon asked, NoPayerPoll has passed since the last read, or
// a too_soon's wait ended since the last read.
func (s *Switcher) relayLinkDue(now time.Time) bool {
	rl := &s.rl
	if !rl.retryAt.IsZero() && now.Before(rl.retryAt) {
		return false
	}
	return s.rlSoon.Load() || now.Sub(rl.last) >= NoPayerPoll || rl.retryAt.After(rl.last)
}

// relayLinkWaits logs the class a check waits on, once per class change.
func (s *Switcher) relayLinkWaits(class string) {
	if s.rl.loggedClass == class {
		return
	}
	s.rl.loggedClass = class
	log.Printf("hub: a phone linked over Relay: switch waits (%s)", class)
}

// checkRelayLink moves a desktop host on CloudKit to the relay once a phone
// that linked over a pairing slot (a relay-linked candidate) is listed as
// paying by a fresh account read (spec §2): accepted like a person's request,
// by that phone. It runs only on CloudKit with no switch pending and no ask
// waiting (the Step decides those first), and checks all of it again with
// the phone's row in the accept's transaction, so an unlink, a re-link, a
// switch or an ask that came in during the read wins. An unknown answer (an
// error, a timeout, a list without the phone) never counts as paying and
// moves nothing; ErrNotFresh is no read and is tried again at the next poll;
// too_soon sends nothing and retries once the wait ends.
func (s *Switcher) checkRelayLink(ctx context.Context) {
	if s.c.AccountPhones == nil || s.c.Relay == nil || s.c.CloudKit == nil {
		return
	}
	now := s.now()
	s.rlMu.Lock()
	defer s.rlMu.Unlock()
	if !s.relayLinkDue(now) {
		return
	}
	if s.activeKind() != transport.KindCloudKit || s.Pending() || s.asksWaiting() {
		return
	}
	candidates, err := s.relayLinkCandidates(now)
	if err != nil {
		s.relayLinkWaits("store")
		return
	}
	if len(candidates) == 0 {
		return
	}
	s.rlSoon.Store(false)
	s.rl.retryAt, s.rl.last = time.Time{}, now
	pctx, cancel := context.WithTimeout(ctx, s.oldSide())
	phones, err := s.c.AccountPhones(pctx)
	cancel()
	if errors.Is(err, ErrNotFresh) {
		s.rlSoon.Store(true) // no read happened: the next poll tries again
		s.relayLinkWaits("not_fresh")
		return
	}
	if err != nil {
		s.relayLinkWaits(errClass(err))
		return
	}
	paying := map[string]bool{}
	for _, p := range phones {
		if p.Paying {
			paying[p.RelayDeviceID] = true
		}
	}
	var chosen *state.Device
	for i := range candidates {
		if paying[candidates[i].RelayDeviceID] {
			chosen = &candidates[i]
			break
		}
	}
	if chosen == nil {
		s.rl.loggedClass = ""
		return
	}
	s.mu.Lock()
	accepted, deferred, err := s.acceptRelayLink(*chosen, now)
	s.mu.Unlock()
	var rej *actions.SwitchRejected
	switch {
	case errors.As(err, &rej) && rej.Reason == wire.SwitchTooSoon:
		s.rl.retryAt = now.Add(rej.RetryAfter)
		s.relayLinkWaits(wire.SwitchTooSoon)
	case err != nil:
		s.relayLinkWaits(errClass(err))
	case deferred:
		s.rlSoon.Store(true) // what came in during the read goes first; then again
	case accepted:
		s.rl.loggedClass = ""
		log.Printf("hub: a phone linked over Relay pays: transport switch to relay accepted")
		s.resetBackoff()
		s.Kick()
	}
}

// acceptRelayLink accepts the switch by d under s.mu, in one transaction
// that first checks again what the read may have overtaken: the hub still
// on CloudKit, no switch pending, no ask waiting, and d still linked by the
// same link (link nonce, linked_at, relay id) after the last switch.
// deferred is true when any of it changed.
func (s *Switcher) acceptRelayLink(d state.Device, now time.Time) (accepted, deferred bool, err error) {
	err = s.c.Store.WithTx(context.Background(), func(tx *sql.Tx) error {
		if s.active != transport.KindCloudKit {
			deferred = true
			return nil
		}
		r, has, err := recordTx(tx)
		if err != nil {
			return err
		}
		asks, err := asksTx(tx)
		if err != nil {
			return err
		}
		if (has && !r.Done) || len(asks) > 0 {
			deferred = true
			return nil
		}
		still, err := stillRelayLinkTx(tx, d)
		if err != nil || !still {
			deferred = err == nil
			return err
		}
		accepted, err = s.acceptTx(tx, canonical(d.ID), transport.KindRelay, now)
		return err
	})
	return accepted, deferred, err
}

// stillRelayLinkTx reports whether d's row is the link the candidate was
// read from, still marked as linked through a pairing slot, and it came after
// the last switch.
func stillRelayLinkTx(tx *sql.Tx, d state.Device) (bool, error) {
	if slot, err := state.RelaySlotLinkedTx(tx, d.ID, d.LinkNonce); err != nil || !slot {
		return false, err
	}
	devices, err := state.DevicesTx(tx)
	if err != nil {
		return false, err
	}
	found := false
	for _, x := range devices {
		if strings.EqualFold(x.ID, d.ID) {
			found = x.LinkNonce == d.LinkNonce && x.RelayDeviceID == d.RelayDeviceID && x.LinkedAt.Equal(d.LinkedAt)
			break
		}
	}
	if !found {
		return false, nil
	}
	raw, ok, err := state.MetaTx(tx, MetaSwitchedAt)
	if err != nil || !ok {
		return err == nil, err
	}
	at, err := parseStamp(raw)
	if err != nil {
		return false, fmt.Errorf("switcher: unreadable %s: %w", MetaSwitchedAt, err)
	}
	return d.LinkedAt.After(at), nil
}
