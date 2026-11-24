package switcher

import (
	"context"
	"errors"
	"log"
	"strings"
	"time"

	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// MetaRelayLinkSince is when the first build carrying the relay-link check
// started the hub (stamp format, written once by New, never rewritten): a
// phone linked over a pairing slot before it never moves the Mac by itself
// (spec Q5).
const MetaRelayLinkSince = "relay_link_since"

// relayLink is the throttle of checkRelayLink; in memory only, so the first
// check after a start reads (a restart finishes a switch a crash cut short).
// The RelayLinkSoon flag is Switcher.rlSoon.
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

// relayLinkCandidates are the linked phones that may move a CloudKit hub to
// the relay, in devices order (linked_at, device_id): each has a relay id, no
// iCloud route (it linked through a pairing slot) and linked after both the
// last switch and relay_link_since, so a later decision wins and a link from
// before the update never counts. Anything unreadable means none.
func (s *Switcher) relayLinkCandidates() []state.Device {
	raw, ok, err := s.c.Store.Meta(MetaRelayLinkSince)
	if err != nil || !ok {
		return nil
	}
	after, err := parseStamp(raw)
	if err != nil {
		return nil
	}
	switchedAt, _, switched, err := s.SwitchedAt()
	if err != nil {
		return nil
	}
	if switched && switchedAt.After(after) {
		after = switchedAt
	}
	devices, err := s.c.Store.Devices()
	if err != nil {
		return nil
	}
	routes, err := s.c.Store.ICloudRoutes()
	if err != nil {
		return nil
	}
	var out []state.Device
	for _, d := range devices {
		if d.RelayDeviceID != "" && !routes[strings.ToLower(d.ID)] && d.LinkedAt.After(after) {
			out = append(out, d)
		}
	}
	return out
}

// relayLinkDue applies the throttle under rlMu: due once retryAt has passed
// and either RelayLinkSoon asked, no read was tried since the start,
// NoPayerPoll has passed since the last, or a too_soon's wait ended since
// the last read. A due check clears the flag and the wait and dates the read.
func (s *Switcher) relayLinkDue(now time.Time) bool {
	rl := &s.rl
	if !rl.retryAt.IsZero() && now.Before(rl.retryAt) {
		return false
	}
	if !s.rlSoon.Load() && !rl.last.IsZero() && now.Sub(rl.last) < NoPayerPoll && !rl.retryAt.After(rl.last) {
		return false
	}
	s.rlSoon.Store(false)
	rl.retryAt, rl.last = time.Time{}, now
	return true
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
// waiting (the Step decides those first). An unknown answer (an error,
// ErrNotFresh, a timeout, a list without the phone) never counts as paying
// and moves nothing; too_soon sends nothing and retries once the wait ends.
func (s *Switcher) checkRelayLink(ctx context.Context) {
	if s.c.AccountPhones == nil || s.c.Relay == nil || s.c.CloudKit == nil {
		return
	}
	if s.activeKind() != transport.KindCloudKit || s.Pending() || s.asksWaiting() {
		return
	}
	s.rlMu.Lock()
	defer s.rlMu.Unlock()
	candidates := s.relayLinkCandidates()
	if len(candidates) == 0 {
		return
	}
	now := s.now()
	if !s.relayLinkDue(now) {
		return
	}
	pctx, cancel := context.WithTimeout(ctx, s.oldSide())
	phones, err := s.c.AccountPhones(pctx)
	cancel()
	if err != nil {
		class := errClass(err)
		if errors.Is(err, ErrNotFresh) {
			class = "not_fresh"
		}
		s.relayLinkWaits(class)
		return
	}
	paying := map[string]bool{}
	for _, p := range phones {
		if p.Paying {
			paying[p.RelayDeviceID] = true
		}
	}
	by := ""
	for _, d := range candidates {
		if paying[d.RelayDeviceID] {
			by = canonical(d.ID)
			break
		}
	}
	if by == "" {
		s.rl.loggedClass = ""
		return
	}
	s.mu.Lock()
	accepted, err := s.accept(by, transport.KindRelay, now)
	s.mu.Unlock()
	var rej *actions.SwitchRejected
	switch {
	case errors.As(err, &rej) && rej.Reason == wire.SwitchTooSoon:
		s.rl.retryAt = now.Add(rej.RetryAfter)
		s.relayLinkWaits(wire.SwitchTooSoon)
	case err != nil:
		s.relayLinkWaits(errClass(err))
	case accepted:
		s.rl.loggedClass = ""
		log.Printf("hub: a phone linked over Relay pays: transport switch to relay accepted")
		s.resetBackoff()
		s.Kick()
	}
}
