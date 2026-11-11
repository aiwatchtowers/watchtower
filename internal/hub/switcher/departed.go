package switcher

import (
	"context"
	"errors"
	"log"
	"maps"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"

	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
)

// A phone gone while the Mac stays (relay client Phase 5, "Losing and
// regaining reader status"). When a phone's subscription moves or its slot is
// removed, the relay sends this hub no control and G2 stays quiet while
// someone else pays, so nothing else would stop its relay keys. checkDeparted
// reads the account's slot list on G2's poll (and on a host with no CloudKit,
// where G2 returns early); who pays plays no part in it. A phone departs when
// it has ephemeral state here (an offer or relay-key rows), a non-empty
// answered list omits it on two reads at least NoPayerPoll apart, the linked
// phones are unchanged and none was just linked (G2's guards). ReaderLost then
// clears its keys and marks it lapsed; it never moves the Mac.
//
// The outcomes, on two answered reads:
//   - another linked phone, or a paying phone not linked here, in a slot: the
//     gone phone's keys go, the Mac stays;
//   - an empty list: nobody departs (an empty answer cannot be told from a
//     revoked account); the keys are held, with no rotation, until the 14-day
//     end (the keyring's) or the phone's return;
//   - nobody pays and every phone has a route: G2 moves the hub first in the
//     poll, and this check skips (the switch is pending);
//   - a failed read, or one not made afresh (ErrNotFresh): nothing moves or
//     clears and the count holds.
//
// The count is in memory, like G2's: a restart starts it again, which only
// delays.

// departures is checkDeparted's state (in memory only).
type departures struct {
	last time.Time // when the last read was tried (zero = none yet)
	fp   string    // the linked phones the misses were counted against
	// missed is, per phone (uppercase device id), when the first answered
	// read of the current run that omitted it was made.
	missed map[string]time.Time
	// owed is the phones a ReaderLost started for and did not finish (its
	// first clear committed, the lapsed mark or hub_on_relay did not), each
	// with the link time it was owed under: with no ephemeral state left, only
	// this set brings them back at the next poll. Kept in hub_meta
	// (MetaReaderLostOwed), so a restart finishes them too; reset never drops
	// it. The hub leaving the relay drops all of it (the rotation toward
	// iCloud has cleared every offer, and hub_on_relay means nothing there),
	// and a re-link drops that phone's entry (finishOwed).
	owed map[string]time.Time
}

// checkDeparted is one tick of the departure check (see above). It runs at
// most once per NoPayerPoll.
func (s *Switcher) checkDeparted(ctx context.Context) {
	if s.c.Slotted == nil || s.c.Relay == nil {
		return
	}
	now := s.now()
	s.dpMu.Lock()
	defer s.dpMu.Unlock()
	if !s.dp.last.IsZero() && now.Sub(s.dp.last) < NoPayerPoll {
		return
	}
	if s.activeKind() != transport.KindRelay {
		s.dropOwed()
		s.dp = departures{}
		return
	}
	if s.Pending() {
		s.dp = departures{owed: s.dp.owed}
		return
	}
	s.finishOwed()
	fp, quiet := s.linkedPhones()
	if fp == "" || !quiet {
		s.dp = departures{last: now, owed: s.dp.owed}
		return
	}
	pctx, cancel := context.WithTimeout(ctx, s.oldSide())
	slotted, err := s.c.Slotted(pctx)
	cancel()
	if errors.Is(err, ErrNotFresh) {
		return // no read happened: nothing counted, tried again at the next poll
	}
	s.dp.last = now
	if err != nil {
		return // unknown: nothing moves, nothing clears, the count holds
	}
	if s.leaving() {
		return // the hub left or is leaving the relay during the read: the next poll resets
	}
	if after, _ := s.linkedPhones(); after != fp || s.dp.fp != fp {
		s.dp = departures{last: now, fp: after, owed: s.dp.owed}
		if after != fp {
			return
		}
	}
	if len(slotted) == 0 {
		return // an empty list: held, the count holds (see above)
	}
	listed := map[string]bool{}
	for _, id := range slotted {
		listed[id] = true
	}
	devices, err := s.c.Store.Devices()
	if err != nil {
		return
	}
	if s.dp.missed == nil {
		s.dp.missed = map[string]time.Time{}
	}
	for _, d := range devices {
		id := canonical(d.ID)
		if _, owed := s.dp.owed[id]; owed {
			continue // finishOwed's
		}
		if d.RelayDeviceID == "" || listed[d.RelayDeviceID] {
			delete(s.dp.missed, id)
			continue
		}
		if has, err := s.c.Store.HasDeviceKX(d.ID); err != nil || !has {
			delete(s.dp.missed, id)
			continue
		}
		first, seen := s.dp.missed[id]
		if !seen {
			s.dp.missed[id] = now
			continue
		}
		if now.Sub(first) < NoPayerPoll {
			continue
		}
		delete(s.dp.missed, id)
		if s.leaving() {
			return // a Step's lapse moved the hub meanwhile: hub_on_relay must not go ahead of its switch
		}
		if err := s.ReaderLost(d.ID); err != nil {
			log.Printf("hub: a departed relay reader is finished at the next poll (%s)", errClass(err))
			s.setOwed(id, d.LinkedAt)
		}
	}
}

// leaving is true when the hub no longer runs on the relay or a switch is
// pending: a departure found then waits for the next poll, which resets.
func (s *Switcher) leaving() bool {
	return s.activeKind() != transport.KindRelay || s.Pending()
}

// finishOwed retries every ReaderLost that failed after its first clear
// (dpMu held), before the poll's account read: the mark, hub_on_relay and
// the last clear, whatever the list says now. A phone marked lapsed
// meanwhile has only the clear left; one no longer linked, or linked again
// since (another link time), is done.
func (s *Switcher) finishOwed() {
	for id, linkedAt := range s.dp.owed {
		d, linked, err := s.c.Store.Device(id)
		if err != nil {
			continue
		}
		if linked && !linkedAt.IsZero() && !d.LinkedAt.Equal(linkedAt) {
			s.setOwed(id, time.Time{}) // a re-link: the new link starts with no relay keys and owes nothing
			continue
		}
		if linked && d.RelayLapsedAt == nil {
			if err := s.owe(d.ID, true); err != nil {
				log.Printf("hub: a departed relay reader is finished at the next poll (%s)", errClass(err))
				continue
			}
		}
		if err := s.clearKeys(id); err != nil {
			log.Printf("hub: a departed relay reader is finished at the next poll (%s)", errClass(err))
			continue
		}
		s.setOwed(id, time.Time{})
	}
}

// setOwed adds id, owed under the link of linkedAt, to the owed set, or
// removes it when linkedAt is zero, and writes the set to hub_meta (dpMu
// held). A failed write keeps memory as it is: the poll runs again.
func (s *Switcher) setOwed(id string, linkedAt time.Time) {
	if s.dp.owed == nil {
		s.dp.owed = map[string]time.Time{}
	}
	if !linkedAt.IsZero() {
		s.dp.owed[id] = linkedAt
	} else {
		delete(s.dp.owed, id)
	}
	s.saveOwed()
}

// dropOwed forgets every unfinished departure (dpMu held): the hub left the
// relay.
func (s *Switcher) dropOwed() {
	if len(s.dp.owed) == 0 {
		return
	}
	s.dp.owed = nil
	s.saveOwed()
}

// saveOwed writes the owed set to hub_meta as "ID@<link time, unix ns>",
// comma-joined and sorted.
func (s *Switcher) saveOwed() {
	entries := make([]string, 0, len(s.dp.owed))
	for _, id := range slices.Sorted(maps.Keys(s.dp.owed)) {
		entries = append(entries, id+"@"+strconv.FormatInt(s.dp.owed[id].UnixNano(), 10))
	}
	if err := s.c.Store.SetMeta(state.MetaReaderLostOwed, strings.Join(entries, ",")); err != nil {
		log.Printf("hub: the unfinished departures are not saved (%s)", errClass(err))
	}
}

// loadOwed restores the unfinished departures at a restart.
func (s *Switcher) loadOwed() {
	v, ok, err := s.c.Store.Meta(state.MetaReaderLostOwed)
	if err != nil || !ok || v == "" {
		return
	}
	s.dpMu.Lock()
	defer s.dpMu.Unlock()
	s.dp.owed = map[string]time.Time{}
	for _, entry := range strings.Split(v, ",") {
		id, at, _ := strings.Cut(entry, "@")
		ns, err := strconv.ParseInt(at, 10, 64)
		if id == "" || err != nil {
			continue
		}
		s.dp.owed[id] = time.Unix(0, ns)
	}
}

// linkedPhones is G2's guard without its route rule: the linked phones with
// their relay ids ("" when none is linked or they cannot be read), and false
// while one was linked within NoPayerPoll.
func (s *Switcher) linkedPhones() (string, bool) {
	devices, err := s.c.Store.Devices()
	if err != nil || len(devices) == 0 {
		return "", false
	}
	ids := make([]string, 0, len(devices))
	quiet := true
	now := s.now()
	for _, d := range devices {
		ids = append(ids, canonical(d.ID)+"="+d.RelayDeviceID)
		if now.Sub(d.LinkedAt) < NoPayerPoll {
			quiet = false
		}
	}
	sort.Strings(ids)
	return strings.Join(ids, ","), quiet
}

// ReaderLost is a phone that is no longer a reader of this hub on the relay
// while the hub stays (checkDeparted): its relay offer and relay-key rows go
// (every key for it is static from then on, and its data-zone keybox loses
// its keys), and it is marked lapsed as rule 16 marks a phone when another
// pays (owe with stay): hub_on_relay is queued to its CloudKit mailbox when it
// has one, sealed static, and a phone with no iCloud route is marked all the
// same, so none of its relay actions written before is applied. A phone with
// no ephemeral state here is left alone. It never moves the Mac. Its return
// (the account lists it paying again) ends the lapse through recheckLapsed,
// and its next epoch_ack offers again.
func (s *Switcher) ReaderLost(device string) error {
	dev, linked, err := s.c.Store.Device(device)
	if err != nil || !linked {
		return err
	}
	has, err := s.c.Store.HasDeviceKX(dev.ID)
	if err != nil || !has {
		return err
	}
	if err := s.clearKeys(canonical(dev.ID)); err != nil {
		return err
	}
	if err := s.owe(dev.ID, true); err != nil {
		return err
	}
	// Once more after the lapsed mark: an epoch_ack read between the first clear and the mark (no lapse_pending
	// names this phone) may have stored an offer, which a rotation would derive from. From the mark on SetKXOffer
	// refuses, so this clear is the last.
	return s.clearKeys(canonical(dev.ID))
}
