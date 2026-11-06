package switcher

import (
	"context"
	"database/sql"
	"fmt"
	"log"
	"maps"
	"sort"
	"strconv"
	"strings"
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
// (EntitlementInactive). Each only records the lapse and kicks (queueLapse:
// the lapse path reads nothing in a processor's pass or flush), and the Step
// runs lapse, which decides over a fresh account read (ask #1075): another
// phone pays when any phone of the relay account other than the lapsed one
// does, linked to this Mac or not (a phone listed paying past LapseFresh, or
// on its own request, renewed: the lapse ends and the hub stays, the asking
// phone told where it runs). A read that failed or was not made afresh
// decides nothing, and the lapse waits (kept in hub_meta across a restart) and
// is retried at each Step, every OtherPoll at the latest, without limit. The
// exception is the phone's own request (ask #1079, the relay's rule 10): on
// an unreadable account it moves the hub at once, so a relay outage can move
// the Mac with no signal from the relay (moveOnUnreadable):
//
//   - the echoes queued for the phone's relay mailbox are owed and moved to
//     its CloudKit mailbox, written there before anything queued after them
//     (an action the hub applied before it heard counts as delivered); the
//     other controls queued for the relay mailbox are dropped;
//   - with no other phone paying, the hub moves to CloudKit as on
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
// or its device id, R31) is that phone's lapse, recorded at once and decided
// by the Step it kicks. Other controls and
// a detail that names no linked phone are ignored.
func (s *Switcher) OnControl(_ context.Context, c transport.Control) error {
	if c.Kind != transport.EntitlementExpired || c.Detail == "" {
		return nil
	}
	device, ok, err := s.deviceNamed(c.Detail)
	if err != nil || !ok {
		return err
	}
	return s.queueLapse(device, false)
}

// LegacySkipMargin widens the time cut for a lapsed phone's legacy relay
// actions (no action_seq): one the relay stamped up to this long after the
// lapse, by the Mac's clock, is still taken as sent before it, so a clock
// skew between the Mac and the relay errs toward skipping (the phone was
// told such an action is not delivered and may retry it).
const LegacySkipMargin = 2 * time.Minute

// Lapsed implements actions.Switch over the sidecar: on the relay, the
// phone is lapsed now; an ordered action read meanwhile raises
// relay_skip_seq.
func (s *Switcher) Lapsed(k transport.Kind, device string, seq uint64) (bool, error) {
	if k != transport.KindRelay {
		return false, nil
	}
	dev, linked, err := s.c.Store.Device(device)
	if err != nil || !linked || dev.RelayLapsedAt == nil {
		return false, err
	}
	if seq > dev.RelaySkipSeq {
		if err := s.c.Store.RaiseRelaySkipSeq(dev.ID, seq); err != nil {
			return true, err
		}
	}
	return true, nil
}

// Skipped implements actions.Switch over the sidecar, on the relay: the
// record was sent before the phone's last lapse ended — an ordered action
// with seq ≤ relay_skip_seq (no clock involved), a legacy action or an
// upload stamped (writtenAt, the relay's ServerAt) before the lapse's time
// plus LegacySkipMargin.
func (s *Switcher) Skipped(k transport.Kind, device string, seq uint64, writtenAt time.Time) (bool, error) {
	if k != transport.KindRelay {
		return false, nil
	}
	dev, linked, err := s.c.Store.Device(device)
	switch {
	case err != nil || !linked:
		return false, err
	case seq > 0:
		return seq <= dev.RelaySkipSeq, nil
	case writtenAt.IsZero() || dev.RelaySkipBefore == nil:
		return false, nil
	}
	return writtenAt.Before(dev.RelaySkipBefore.Add(LegacySkipMargin)), nil
}

// EntitlementInactive implements actions.Switch: a write into device's relay
// mailbox was refused ENTITLEMENT_INACTIVE. The lapse runs at the next Step
// (this is called from inside a processor's flush).
func (s *Switcher) EntitlementInactive(k transport.Kind, device string) {
	if k != transport.KindRelay {
		return
	}
	if err := s.queueLapse(device, false); err != nil {
		log.Printf("hub: a lapsed relay entitlement could not be queued (%s)", errClass(err))
	}
}

// LapseFresh is how long a relay-signalled lapse is taken as certain: inside
// it the account may still list the lapsed phone as paying on a stale
// snapshot, so its own entry is ignored; past it (a lapse that waited, across
// outages or a restart) a fresh read listing the phone as paying means it
// renewed, and the lapse ends.
const LapseFresh = 2 * time.Minute

// lapseRequest is a lapse waiting for a Step: asked is the phone's own
// transport_switch(cloudkit, entitlement_expired), also sent by the follower's
// automatic request (a restart forgets it: the phone repeats its request);
// at is when the lapse was first recorded (kept across a restart).
type lapseRequest struct {
	asked bool
	at    time.Time
}

const metaLapsePending = "lapse_pending"

// queueLapse records that device's relay entitlement lapsed and wakes the
// Step that decides it. The lapse path reads nothing here and never blocks on
// the relay: it runs inside a processor's pass (OnControl, Request) or flush
// (EntitlementInactive, with the processor's lock held), so a slow account
// read there would burn the pass and starve every phone behind it (a request
// toward the relay and a stale write's answer wait for the Step the same way,
// asks.go). The ids and times are kept in hub_meta, so a restart does not lose a lapse that was waiting.
func (s *Switcher) queueLapse(device string, asked bool) error {
	id := canonical(device)
	s.mu.Lock()
	if s.pending == nil {
		s.pending = map[string]*lapseRequest{}
	}
	req := s.pending[id]
	if req == nil {
		req = &lapseRequest{at: s.now().Round(0)} // wall clock: the age counts sleep
		s.pending[id] = req
	}
	req.asked = req.asked || asked
	err := s.savePendingLocked()
	s.mu.Unlock()
	s.Kick()
	return err
}

// savePendingLocked writes the waiting lapses' device ids and times (s.mu
// held), "<id>@<unix seconds>".
func (s *Switcher) savePendingLocked() error {
	ids := make([]string, 0, len(s.pending))
	for d, req := range s.pending {
		ids = append(ids, fmt.Sprintf("%s@%d", d, req.at.Unix()))
	}
	sort.Strings(ids)
	return s.c.Store.SetMeta(metaLapsePending, strings.Join(ids, ","))
}

// loadPending restores the lapses that were waiting at a restart (they have
// not been asked by a phone any more: a phone that asked retries).
func (s *Switcher) loadPending() {
	v, ok, err := s.c.Store.Meta(metaLapsePending)
	if err != nil || !ok || v == "" {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.pending == nil {
		s.pending = map[string]*lapseRequest{}
	}
	for _, e := range strings.Split(v, ",") {
		id, at, _ := strings.Cut(e, "@")
		when := s.now()
		if n, err := strconv.ParseInt(at, 10, 64); err == nil {
			when = time.Unix(n, 0)
		}
		s.pending[id] = &lapseRequest{at: when}
	}
}

// lapses retries every lapse still waiting, at a Step. One that cannot be
// decided (no fresh account read) stays and is tried again at the next Step
// (the run loop's tick, every OtherPoll, 30 s, and any kick); there is no
// limit on the tries, each bounded by the old-side timeout. It ends when the
// read answers, the phone is unlinked or the hub is no longer on the relay.
func (s *Switcher) lapses(ctx context.Context) { s.decideLapses(ctx) }

// decideLapses decides the waiting lapses, one at a time (lapseMu); the switcher's lock is never held over the read.
func (s *Switcher) decideLapses(ctx context.Context) {
	s.lapseMu.Lock()
	defer s.lapseMu.Unlock()
	s.mu.Lock()
	ids := make([]string, 0, len(s.pending))
	for d := range s.pending {
		ids = append(ids, d)
	}
	s.mu.Unlock()
	for _, d := range ids {
		s.mu.Lock()
		req := s.pending[d]
		s.mu.Unlock()
		if req == nil {
			continue
		}
		if err := s.lapse(ctx, d, req); err != nil {
			log.Printf("hub: a lapsed relay entitlement waits (%s)", errClass(err))
			continue
		}
		s.mu.Lock()
		delete(s.pending, d)
		if err := s.savePendingLocked(); err != nil {
			log.Printf("hub: clearing a decided lapse: %s", errClass(err))
		}
		s.mu.Unlock()
	}
}

// lapse is rule 16 for device (see the package note above): the hub stays on
// the relay while any phone other than the lapsed one pays (a fresh account
// read, linked to this Mac or not, no route check: ask #1075), and moves to
// CloudKit when nobody does. An error means undecided (see undecided). It
// runs in a Step, never in a processor's pass.
func (s *Switcher) lapse(ctx context.Context, device string, req *lapseRequest) error {
	dev, linked, err := s.c.Store.Device(device)
	if err != nil || !linked {
		return err
	}
	id := canonical(dev.ID)
	onRelay := s.activeKind() == transport.KindRelay && s.heading() == transport.KindRelay
	others, unreadable := false, false
	if onRelay {
		var renewed bool
		if others, renewed, err = s.othersPay(ctx, dev, req); err != nil {
			if !s.moveOnUnreadable(req) {
				return err // undecided: the lapse waits for the next Step
			}
			unreadable = true
		} else if renewed {
			log.Printf("hub: the relay entitlement of device %s is paying again: the lapse ends", id)
			s.mu.Lock()
			asked := req.asked
			s.mu.Unlock()
			if asked {
				s.answerWhereItRuns(dev.ID) // its Switch to iCloud does not wait for an answer that never comes
			}
			return nil
		}
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
	asked := req.asked
	s.mu.Unlock()
	if err != nil {
		return err
	}
	if accepted {
		if unreadable {
			log.Printf("hub: the relay entitlement of device %s lapsed and the account could not be read: transport switch to cloudkit accepted at the phone's own request", id)
		} else {
			log.Printf("hub: the relay entitlement of device %s lapsed and no other phone pays: transport switch to cloudkit accepted", id)
		}
		s.resetBackoff()
		s.Kick()
	} else if asked {
		s.answerWhereItRuns(dev.ID)
	}
	return nil
}

// moveOnUnreadable is the one place for a lapse whose fresh account read
// failed, timed out or was not made afresh (ask #1079). A lapse the phone
// asked for (its transport_switch(cloudkit, entitlement_expired), sent on its
// press or by the follower's automatic request, so possibly with no press)
// moves the Mac at once, as the relay's rule 10 says a free phone's request
// always works: the cost is that during a relay outage such a request can
// move the Mac off a paying phone, which returns it with the Relay row. The
// relay's own signal (the control, a refused write) stays undecided and is
// retried at the next Step: a failed read is never "nobody pays" there.
func (s *Switcher) moveOnUnreadable(req *lapseRequest) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return req.asked
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

// othersPay is the account side of rule 16, from a fresh read
// (Config.AccountPhones: the phones holding this Mac in a slot, linked here or
// not; a read that failed or was not made afresh is an error, undecided,
// never "nobody pays"). Whether another phone pays, and whether the lapsed
// phone itself is paying again (renewed), are decided only here:
//
//   - the lapsed phone's own entry is ignored while the lapse is fresh and
//     came from the relay (LapseFresh: a stale snapshot may still list it);
//   - listed paying past that, or on a phone's own request (nothing dates it:
//     it may be a copy read after a renewal), it means the phone renewed:
//     renewed is true and the lapse ends, the hub staying;
//   - a phone with no relay id cannot be found in the list: nothing is
//     excluded, any paying phone counts as another and the hub stays (the safe
//     side: a false stay costs a free phone a wait, a false move cuts a paying
//     owner off).
//
// Without AccountPhones (a host with no account read) the last Paying read of
// the linked phones decides, as before.
func (s *Switcher) othersPay(ctx context.Context, dev state.Device, req *lapseRequest) (others, renewed bool, err error) {
	if s.c.AccountPhones != nil {
		pctx, cancel := context.WithTimeout(ctx, s.oldSide())
		defer cancel()
		phones, err := s.c.AccountPhones(pctx)
		if err != nil {
			return false, false, err
		}
		s.mu.Lock()
		asked, age := req.asked, s.now().Sub(req.at)
		s.mu.Unlock()
		for _, p := range phones {
			if !p.Paying {
				continue
			}
			if dev.RelayDeviceID != "" && p.RelayDeviceID == dev.RelayDeviceID {
				if asked || age >= LapseFresh || age < 0 { // a clock set back errs to staying
					return false, true, nil
				}
				continue
			}
			others = true
		}
		return others, false, nil
	}
	s.mu.Lock()
	paying := s.paying
	s.mu.Unlock()
	if len(paying) == 0 {
		return false, false, nil
	}
	devices, err := s.c.Store.Devices()
	if err != nil {
		return false, false, err
	}
	id := canonical(dev.ID)
	for _, d := range devices {
		if other := canonical(d.ID); other != id && paying[other] {
			return true, false, nil
		}
	}
	return false, false, nil
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
			s.endLapse(ctx, d)
		}
	}
}

// endLapse ends device's lapse, never blind: the phone's relay mailbox is
// read first and relay_skip_seq raised to the highest action_seq there, so
// nothing it sent before the lapse ends — read by the hub or not, listed
// by the phone as not delivered — is ever applied; what it writes later has
// a higher seq. A mailbox that cannot be read keeps the phone lapsed until
// the next poll.
func (s *Switcher) endLapse(ctx context.Context, device string) {
	if rp := s.procs[transport.KindRelay]; rp != nil {
		rctx, cancel := context.WithTimeout(ctx, s.oldSide())
		seq, err := rp.HighestActionSeq(rctx, device)
		cancel()
		if err != nil {
			log.Printf("hub: a relay lapse stays until its mailbox is read (%s)", errClass(err))
			return
		}
		if err := s.c.Store.RaiseRelaySkipSeq(device, seq); err != nil {
			log.Printf("hub: ending a relay lapse: %s", errClass(err))
			return
		}
	}
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
// them, in one transaction. A phone with no CloudKit mailbox, or a host with
// no CloudKit, has nothing to move and no one to tell, but is still marked
// lapsed on stay: its relay actions must not apply either.
func (s *Switcher) owe(device string, stay bool) error {
	rp, cp := s.procs[transport.KindRelay], s.procs[transport.KindCloudKit]
	var from, to string
	var okFrom, okTo bool
	var err error
	if rp != nil && cp != nil {
		if from, okFrom, err = rp.QueueOf(device); err != nil {
			return err
		}
		if to, okTo, err = cp.QueueOf(device); err != nil {
			return err
		}
	}
	if !stay && !(okFrom && okTo) {
		return nil
	}
	var notice *state.Control
	if stay && okTo {
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
		if okFrom && okTo {
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
