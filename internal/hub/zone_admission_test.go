package hub

import (
	"context"
	"database/sql"
	"sync"
	"testing"
	"time"

	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/transport/relay/relayv1"
)

// #1761: a phone that names its relay id has its mailbox refused
// (FORBIDDEN) until the relay puts the hub in its slot, often the same
// second. The admission makes the refused zone due at once; the relay's
// refusals while it has not admitted the hub keep their backoff.

// slotRelay is a relay memfake whose WatchZone refuses every zone until
// the hub is admitted, with the account state that admission lists. The
// hub is vouched throughout (another phone's slot), as on a Mac whose
// phone switched from CloudKit.
type slotRelay struct {
	*memfake.Fake
	mu       sync.Mutex
	admitted bool
	acct     *relayv1.AccountState
	tries    map[string]int
}

func (s *slotRelay) WatchZone(_ context.Context, zone string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.tries[zone]++
	if !s.admitted {
		return transport.ErrForbidden
	}
	return nil
}

func (s *slotRelay) Vouched() bool  { return true }
func (s *slotRelay) Admitted() bool { return true }
func (s *slotRelay) LastAccountState() *relayv1.AccountState {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.acct
}

func (s *slotRelay) admit(phoneRelayID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.admitted = true
	s.acct = &relayv1.AccountState{Phones: []*relayv1.SlotHolder{{PhoneDeviceId: phoneRelayID}}}
}

func (s *slotRelay) refuseAgain() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.admitted = false
}

func (s *slotRelay) triesOf(zone string) int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.tries[zone]
}

type zoneAdmissionRig struct {
	t       *testing.T
	h       *hubRuntime
	rel     *slotRelay
	phone   *hubtest.Phone
	mailbox string
	mu      sync.Mutex
	now     time.Time
}

func newZoneAdmissionRig(t *testing.T) *zoneAdmissionRig {
	t.Helper()
	st, err := state.Open(t.TempDir() + "/hub")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	phone, err := hubtest.New(hubtest.Config{})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WithTx(context.Background(), func(tx *sql.Tx) error { return state.LinkDevice(tx, phone.Device()) }); err != nil {
		t.Fatal(err)
	}
	r := &zoneAdmissionRig{t: t, phone: phone, now: time.Unix(1_800_000_000, 0)}
	r.rel = &slotRelay{Fake: memfake.New(transport.KindRelay, r.clock), acct: &relayv1.AccountState{}, tries: map[string]int{}}
	const relayID = "HUBRELAYID"
	r.h = &hubRuntime{
		sup: &supervisor{o: Options{Clock: r.clock, linkEvery: time.Minute}},
		st:  st, tr: r.rel, relayID: relayID, data: transport.DataZone(relayID),
		watched: map[string]bool{}, subRetry: map[string]*subRetry{}, wasVouched: true,
		linkKick: make(chan struct{}, 1),
	}
	r.mailbox = transport.MailboxZone(relayID, phone.RelayDeviceID())
	return r
}

func (r *zoneAdmissionRig) clock() time.Time {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.now
}

func (r *zoneAdmissionRig) advance(d time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.now = r.now.Add(d)
}

// upkeep is the zone half of one link upkeep.
func (r *zoneAdmissionRig) upkeep() { r.h.watchZones(context.Background(), r.rel) }

// kicked drains a pending link-upkeep kick.
func (r *zoneAdmissionRig) kicked() bool {
	select {
	case <-r.h.linkKick:
		return true
	default:
		return false
	}
}

// SLOT_ADDED after a refusal: a link upkeep is kicked and subscribes the
// mailbox with the clock where it was, not linkEvery later.
func TestRefusedMailboxSubscribedAtOnceOnSlotAdded(t *testing.T) {
	r := newZoneAdmissionRig(t)
	r.upkeep()
	if r.rel.triesOf(r.mailbox) != 1 || r.h.watched[r.mailbox] {
		t.Fatalf("mailbox tried %d times before admission", r.rel.triesOf(r.mailbox))
	}
	r.rel.admit(r.phone.RelayDeviceID())
	r.h.onControl(context.Background(), transport.Control{Kind: transport.SlotAdded})
	if !r.kicked() {
		t.Fatal("SLOT_ADDED kicked no link upkeep")
	}
	r.upkeep()
	if !r.h.watched[r.mailbox] || !r.h.watched[r.h.data] {
		t.Fatalf("zones not subscribed at once after SLOT_ADDED: tried %d", r.rel.triesOf(r.mailbox))
	}
}

// The relay admitting the hub for a phone (a new admission stamp read off
// the account state, no SLOT_ADDED) does the same.
func TestRefusedMailboxSubscribedAtOnceOnAdmissionStamp(t *testing.T) {
	r := newZoneAdmissionRig(t)
	r.upkeep()
	r.rel.admit(r.phone.RelayDeviceID())
	r.h.followAccount(r.rel.LastAccountState())
	if !r.kicked() {
		t.Fatal("a new admission kicked no link upkeep")
	}
	r.upkeep()
	if !r.h.watched[r.mailbox] {
		t.Fatal("mailbox not subscribed at once after the admission")
	}
	// The stamp is once per phone: the same account state again kicks nothing.
	r.h.followAccount(r.rel.LastAccountState())
	if r.kicked() {
		t.Fatal("an already-stamped phone kicked the link upkeep again")
	}
}

// While the relay has not admitted the hub its refusals keep the backoff:
// no try before linkEvery, one at it, then a doubled wait.
func TestRefusedZoneKeepsBackoffWhileNotAdmitted(t *testing.T) {
	r := newZoneAdmissionRig(t)
	r.upkeep()
	r.upkeep()
	r.advance(time.Minute - time.Second)
	r.upkeep()
	if n := r.rel.triesOf(r.mailbox); n != 1 {
		t.Fatalf("refused mailbox tried %d times inside linkEvery", n)
	}
	r.advance(time.Second)
	r.upkeep()
	if n := r.rel.triesOf(r.mailbox); n != 2 {
		t.Fatalf("refused mailbox tried %d times at linkEvery, want 2", n)
	}
	r.advance(time.Minute)
	r.upkeep()
	if n := r.rel.triesOf(r.mailbox); n != 2 {
		t.Fatalf("second refusal did not double the wait: %d tries", n)
	}
}

// A refusal right after an admission (the relay not caught up, or a restart
// between the stamp and the subscribe) still backs off: the admission makes
// the zone due once, and the next try waits the doubled wait — never a spin.
func TestRefusalAfterAdmissionStillBacksOff(t *testing.T) {
	r := newZoneAdmissionRig(t)
	r.upkeep() // refused: next at +1 min
	r.rel.admit(r.phone.RelayDeviceID())
	r.h.onControl(context.Background(), transport.Control{Kind: transport.SlotAdded})
	r.rel.refuseAgain()
	r.upkeep() // due at once, refused again: next at +2 min
	if n := r.rel.triesOf(r.mailbox); n != 2 {
		t.Fatalf("admission made the mailbox tried %d times, want 2", n)
	}
	for range 5 {
		r.upkeep()
	}
	r.advance(time.Minute)
	r.upkeep()
	if n := r.rel.triesOf(r.mailbox); n != 2 {
		t.Fatalf("refused mailbox tried %d times after an admission, want the doubled wait", n)
	}
	r.advance(time.Minute)
	r.upkeep()
	if n := r.rel.triesOf(r.mailbox); n != 3 {
		t.Fatalf("refused mailbox tried %d times at the doubled wait, want 3", n)
	}
}
