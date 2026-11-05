package switcher

import (
	"context"
	"log"
	"sort"
	"strings"
	"time"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// NoPayerPoll is how often a hub on the relay asks whether anybody still pays
// for it, and the least time between the two reads that must both say nobody
// does (relay client launch condition G2).
const NoPayerPoll = 5 * time.Minute

// noPayer is the state of the check; in memory only, so a restart restarts
// the count (toward staying on the relay).
type noPayer struct {
	last  time.Time // when the last read was tried (zero = none yet)
	count int       // consecutive reads that answered "nobody pays"
	fp    string    // the linked phones when the first of them was read
}

func (n *noPayer) reset(now time.Time) { *n = noPayer{last: now} }

// fingerprint is the linked phones with their relay ids: a phone linking, or
// its relay id being learned, changes it.
func (s *Switcher) fingerprint() (string, bool) {
	devices, err := s.c.Store.Devices()
	if err != nil || len(devices) == 0 {
		return "", false
	}
	ids := make([]string, 0, len(devices))
	recent := false
	now := s.now()
	for _, d := range devices {
		ids = append(ids, canonical(d.ID)+"="+d.RelayDeviceID)
		if now.Sub(d.LinkedAt) < NoPayerPoll {
			recent = true
		}
	}
	sort.Strings(ids)
	return strings.Join(ids, ","), !recent
}

// checkNoPayer is G2: a desktop host on the relay whose account no longer
// lists any paying phone (a subscription move revokes the old account's
// slots with no control, and the old phone may be wiped) moves to CloudKit by
// itself, as on rule 16 with no other payer (by = entitlement_expired). It
// moves only on two reads that answered, at least NoPayerPoll apart, with the
// same linked phones, none linked within the interval; a read that failed or
// timed out, a paying phone, a pending switch or a phone linking resets the
// count and moves nothing. An answer with no phones at all cannot be told
// from a revoked account, so the two reads and the phone list are its guard.
func (s *Switcher) checkNoPayer(ctx context.Context) {
	if s.c.AnyPaying == nil || s.c.Relay == nil || s.c.CloudKit == nil {
		return
	}
	now := s.now()
	s.npMu.Lock()
	defer s.npMu.Unlock()
	if !s.np.last.IsZero() && now.Sub(s.np.last) < NoPayerPoll {
		return
	}
	if s.activeKind() != transport.KindRelay || s.Pending() {
		s.np.reset(time.Time{})
		return
	}
	fp, quiet := s.fingerprint()
	if fp == "" || !quiet {
		s.np.reset(now)
		return
	}
	pctx, cancel := context.WithTimeout(ctx, s.oldSide())
	pays, err := s.c.AnyPaying(pctx)
	cancel()
	if err != nil || pays {
		s.np.reset(now)
		return
	}
	if after, _ := s.fingerprint(); after != fp {
		s.np.reset(now)
		return
	}
	if s.np.count == 0 || s.np.fp != fp {
		s.np = noPayer{last: now, count: 1, fp: fp}
		return
	}
	s.mu.Lock()
	accepted, err := s.accept(wire.SwitchedByEntitlement, transport.KindCloudKit, now)
	s.mu.Unlock()
	s.np.reset(now)
	if err != nil {
		log.Printf("hub: no paying phone is left: %s", errClass(err))
		return
	}
	if accepted {
		log.Printf("hub: no phone pays for the relay any more: transport switch to cloudkit accepted")
		s.resetBackoff()
		s.Kick()
	}
}
