package hub

import (
	"context"
	"database/sql"
	"errors"
	"testing"
	"time"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/switcher"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay/relayv1"
	"watchtower/internal/policy/policytest"
)

// G2 through the real account reader and the desktop runtime's wiring
// (Config.AnyPaying), not a stub under them.

// An answer not read now is never a second "nobody pays": inside the
// unvouched window the reader hands the last read's error, or ErrNotFresh,
// and never the cached state.
func TestAccountReaderFreshNeverAnswersFromTheCache(t *testing.T) {
	clock := &setClock{now: time.Unix(1_800_000_000, 0)}
	reads, fail := 0, error(nil)
	r := &accountReader{
		read: func(context.Context) (*relayv1.AccountState, error) {
			reads++
			if fail != nil {
				return nil, fail
			}
			return &relayv1.AccountState{}, nil
		},
		vouched: func() bool { return false },
		clock:   clock.Now,
	}
	if _, err := r.Fresh(t.Context()); err != nil {
		t.Fatal(err)
	}
	// Two G2 reads cannot collapse into one answer.
	if _, err := r.Fresh(t.Context()); !errors.Is(err, switcher.ErrNotFresh) || reads != 1 {
		t.Fatalf("a second read inside the window: %v after %d reads", err, reads)
	}
	// A failed attempt (the upkeep's) is the error, not the old answer.
	clock.Advance(unvouchedPoll)
	fail = errors.New("relay down")
	if _, err := r.State(t.Context()); err == nil {
		t.Fatal("the read should fail")
	}
	clock.Advance(10 * time.Second)
	if _, err := r.Fresh(t.Context()); !errors.Is(err, fail) {
		t.Fatalf("inside the window of a failed read: %v", err)
	}
	// Past the window it reads for real.
	fail = nil
	clock.Advance(unvouchedPoll)
	if _, err := r.Fresh(t.Context()); err != nil || reads != 3 {
		t.Fatalf("past the window: %v after %d reads", err, reads)
	}
}

// unvouchedFake is the relay fake as the production transport shows a hub
// the relay does not know: not vouched, so the reader's window holds.
type unvouchedFake struct{ *watchFake }

func (unvouchedFake) Vouched() bool                           { return false }
func (unvouchedFake) Admitted() bool                          { return false }
func (unvouchedFake) LastAccountState() *relayv1.AccountState { return nil }

// g2Rig is a desktop host on the relay (one phone linked, no CloudKit link)
// with a clock the test sets and the upkeep out of the way. The switcher's
// loop is the test's: the host runs no Run of its own (switcherRun), so every
// PollOther and Step lands at an instant the test chose — a G2 read of the
// host's own at the frozen start instant could otherwise land after the test
// set its scenario and count before the test does.
type g2Rig struct {
	*deskRig
	h     *hubRuntime
	clock *setClock
	fake  *watchFake
}

func startG2(t *testing.T, unvouched bool) *g2Rig {
	t.Helper()
	policytest.Set(t, nil)
	r := newDeskRig(t, shortDir(t))
	setMeta(t, r.dir, state.MetaEnabled, "1")
	linkPhoneDirectly(t, r.dir)
	st, err := state.Open(r.dir)
	if err != nil {
		t.Fatal(err)
	}
	// An iCloud route for the phone (CloudKitLinks): G2 moves a hub nobody
	// can follow to iCloud for no one.
	err = st.WithTx(context.Background(), func(tx *sql.Tx) error {
		_, err := tx.Exec(`UPDATE devices SET user_record_name = '_user'`)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	_ = st.Close()
	setMeta(t, r.dir, switcher.MetaTransport, "relay") // a phone with an iCloud route, the host on the relay
	g := &g2Rig{deskRig: r, clock: &setClock{now: time.Unix(1_800_000_000, 0)}, fake: &watchFake{Fake: r.fake}}
	// Somebody pays at first, so the first poll (at the frozen clock) resets
	// the check instead of counting.
	g.fake.SetAccountState(&relayv1.AccountState{Phones: []*relayv1.SlotHolder{{PhoneDeviceId: "unlinked-phone", Paying: true}}})
	o := r.options()
	o.Clock = g.clock.Now
	o.linkEvery = time.Hour
	o.newTransport = func(context.Context, identity.Identity, *state.Store, []string) (transport.Transport, error) {
		if unvouched {
			return unvouchedFake{g.fake}, nil
		}
		return g.fake, nil
	}
	o.started = func(rt *hubRuntime) { g.h = rt }
	o.switcherRun = func(ctx context.Context, _ *switcher.Switcher) error {
		<-ctx.Done()
		return ctx.Err()
	}
	r.start(o)
	r.waitState(StateRunning, "")
	if !g.h.sw.IsActive(transport.KindRelay) || g.h.sw.Pending() {
		t.Fatal("the host does not start on the relay")
	}
	g.h.sw.PollOther(context.Background())
	return g
}

// poll is one PollOther an interval after the last.
func (g *g2Rig) poll() {
	g.clock.Advance(switcher.NoPayerPoll + time.Second)
	g.h.sw.PollOther(context.Background())
	// A read the host made at the same frozen instant (its link upkeep's)
	// leaves this one in the reader's window, not fresh and not counted: one more
	// poll once the window has passed counts it (a counted one throttles it).
	g.clock.Advance(unvouchedPoll + time.Second)
	g.h.sw.PollOther(context.Background())
}

// onCloudKit carries out the accepted switch (the Steps the host's own Run
// would make, a failed one tried again) until the host runs on CloudKit.
func (g *g2Rig) onCloudKit(t *testing.T) {
	t.Helper()
	eventually(t, "the host on CloudKit", func() bool {
		_ = g.h.sw.Step(context.Background())
		return g.h.sw.IsActive(transport.KindCloudKit)
	})
}

func TestG2TheDesktopWiringMovesOffARelayNobodyPays(t *testing.T) {
	for _, unvouched := range []bool{false, true} {
		name := "vouched"
		if unvouched {
			name = "HUB_NOT_VOUCHED"
		}
		t.Run(name, func(t *testing.T) {
			bubble(t, func(t *testing.T) {
				g := startG2(t, unvouched)
				g.fake.SetAccountState(&relayv1.AccountState{})
				g.poll()
				if !g.h.sw.IsActive(transport.KindRelay) || g.h.sw.Pending() {
					t.Fatal("moved on one read")
				}
				g.poll()
				g.onCloudKit(t)
			})
		})
	}
}

// The scenario of the review: a read that fails between the two G2 reads is
// not forgotten when the second one lands in the unvouched window.
func TestG2AFailedReadBetweenTheTwoDoesNotLetTheCacheAnswer(t *testing.T) {
	bubble(t, func(t *testing.T) {
		g := startG2(t, true)
		g.fake.SetAccountState(&relayv1.AccountState{})
		g.poll() // count 1
		g.fake.SetAvailable(false)
		g.clock.Advance(switcher.NoPayerPoll - 10*time.Second)
		if _, err := g.h.readAccount(context.Background()); err == nil { // the link upkeep's read
			t.Fatal("the read should fail")
		}
		g.clock.Advance(11 * time.Second)
		g.h.sw.PollOther(context.Background()) // inside the failed read's window
		g.fake.SetAvailable(true)
		g.clock.Advance(unvouchedPoll)
		g.h.sw.PollOther(context.Background()) // a real read now: count 1, not 2 (a move would be accepted in it)
		if !g.h.sw.IsActive(transport.KindRelay) || g.h.sw.Pending() {
			t.Fatal("moved on a cached answer after a failed read")
		}
	})
}

// A lapsed phone's row makes every poll's lapse recheck read the account.
// G2 reads first on its tick, so its read is the real one and the recheck
// takes the cached answer (the unvouched window): G2 is not starved by it.
func TestG2IsNotStarvedByTheLapseRecheck(t *testing.T) {
	bubble(t, func(t *testing.T) {
		g := startG2(t, true)
		st, err := state.Open(g.dir)
		if err != nil {
			t.Fatal(err)
		}
		err = st.WithTx(context.Background(), func(tx *sql.Tx) error {
			_, err := tx.Exec(`UPDATE devices SET relay_lapsed_at = 1`)
			return err
		})
		_ = st.Close()
		if err != nil {
			t.Fatal(err)
		}
		g.fake.SetAccountState(&relayv1.AccountState{})
		g.poll() // count 1
		g.poll()
		g.onCloudKit(t)
	})
}

// Rule 16 through the real reader and the desktop wiring (Config.AccountPhones):
// a phone of the account that is not linked here and pays keeps the Mac on
// the relay; with nobody paying the lapse moves it.
func TestALapseReadsTheAccountThroughTheDesktopWiring(t *testing.T) {
	for _, unlinkedPays := range []bool{true, false} {
		name := "nobody pays"
		if unlinkedPays {
			name = "an unlinked phone pays"
		}
		t.Run(name, func(t *testing.T) {
			bubble(t, func(t *testing.T) {
				g := startG2(t, true)
				devices, err := g.h.st.Devices()
				if err != nil || len(devices) != 1 {
					t.Fatalf("devices %v %v", devices, err)
				}
				lapsed := devices[0]
				// The relay may still list the lapsed phone as paying on a stale snapshot:
				// it is never "another" payer.
				phones := []*relayv1.SlotHolder{{PhoneDeviceId: lapsed.RelayDeviceID, Paying: true}}
				if unlinkedPays {
					phones = append(phones, &relayv1.SlotHolder{PhoneDeviceId: "unlinked-phone", Paying: true})
				}
				g.fake.SetAccountState(&relayv1.AccountState{Phones: phones})
				g.clock.Advance(time.Minute) // past the reader's window
				if err := g.h.sw.OnControl(context.Background(), transport.Control{Kind: transport.EntitlementExpired, Detail: lapsed.RelayDeviceID}); err != nil {
					t.Fatal(err)
				}
				g.decideLapse(t)
				if unlinkedPays {
					if !g.h.sw.IsActive(transport.KindRelay) || g.h.sw.Pending() {
						t.Fatal("moved with a paying phone in the account")
					}
					return
				}
				g.onCloudKit(t)
			})
		})
	}
}

// decideLapse runs the Step until the waiting lapse is decided (hub_meta
// lapse_pending empty). The lapse's account read must be fresh, and the clock
// is frozen: a read made at this instant (the link upkeep's) leaves it in the
// reader's unvouched window (ErrNotFresh), and the lapse waits for the next
// Step, which on a real clock comes past the window (OtherPoll). Here a Step
// that left the lapse waiting moves the clock past the window for the next
// one, a few times at most, so the lapse is still inside LapseFresh.
func (g *g2Rig) decideLapse(t *testing.T) {
	t.Helper()
	const maxMoves = 3
	if maxMoves*unvouchedPoll >= switcher.LapseFresh {
		t.Fatal("the moves would age the lapse past LapseFresh")
	}
	for moves := 0; ; moves++ {
		_ = g.h.sw.Step(context.Background()) // the lapse is tried in it (an error is the carry-out's: onCloudKit retries it)
		v, _, err := g.h.st.Meta(state.MetaLapsePending)
		if err != nil {
			t.Fatal(err)
		}
		if v == "" {
			return
		}
		if moves == maxMoves {
			t.Fatalf("the lapse is still waiting after %d Steps: %q", moves+1, v)
		}
		g.clock.Advance(unvouchedPoll)
	}
}
