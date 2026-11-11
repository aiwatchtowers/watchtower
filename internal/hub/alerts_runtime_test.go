package hub

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"sync"
	"testing"
	"testing/synctest"
	"time"

	"google.golang.org/protobuf/proto"

	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/secure"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/transport/relay"
	"watchtower/internal/hub/transport/relay/client"
	"watchtower/internal/hub/transport/relay/relayv1"
	"watchtower/internal/logcanary"
)

// ---- the runtime's own wiring of the pusher (newPusher, withAlerts,
// switcherConfig, pushTargets) over a relay-shaped fake ----

// pushRelay is a memfake with the relay transport's alert side: send_alert,
// the account state, the accepted reader list and the connect hook.
type pushRelay struct {
	*memfake.Fake
	send *scriptedAlerts

	mu        sync.Mutex
	acct      *relayv1.AccountState
	readers   []string
	onConnect func()
}

func (r *pushRelay) SendAlert(ctx context.Context, phone string, p secure.Push) error {
	return r.send.SendAlert(ctx, phone, p)
}
func (r *pushRelay) Vouched() bool  { return true }
func (r *pushRelay) Admitted() bool { return true }
func (r *pushRelay) LastAccountState() *relayv1.AccountState {
	r.mu.Lock()
	defer r.mu.Unlock()
	return proto.Clone(r.acct).(*relayv1.AccountState)
}
func (r *pushRelay) Readers() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return slices.Clone(r.readers)
}
func (r *pushRelay) OnConnected(fn func()) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.onConnect = fn
}
func (r *pushRelay) setReaders(ids ...string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.readers = ids
}
func (r *pushRelay) connected() {
	r.mu.Lock()
	fn := r.onConnect
	r.mu.Unlock()
	if fn != nil {
		fn()
	}
}

// runtimePush is a hubRuntime holding only what the alert wiring uses: the
// pusher newPusher builds, a publisher configured by withAlerts, both on
// pushRelay, one linked paying phone.
type runtimePush struct {
	t      *testing.T
	h      *hubRuntime
	rel    *pushRelay
	src    *pushSource
	logs   *logcanary.Sink
	device string
	away   *fixedAwayInput
}

// fixedAwayInput is a platform.Away the test moves.
type fixedAwayInput struct {
	mu   sync.Mutex
	away bool
}

func (a *fixedAwayInput) Away() (bool, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.away, nil
}

const runtimePhone = "relay-phone-a"

func newRuntimePush(t *testing.T, send *scriptedAlerts) *runtimePush {
	t.Helper()
	st, err := state.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	id, err := identity.New()
	if err != nil {
		t.Fatal(err)
	}
	kr, err := identity.NewKeyring(id, st, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	rp := &runtimePush{t: t, src: &pushSource{}, logs: logcanary.Capture(t), away: &fixedAwayInput{away: true}}
	rp.rel = &pushRelay{Fake: memfake.New(transport.KindRelay, time.Now), send: send,
		acct: &relayv1.AccountState{Phones: []*relayv1.SlotHolder{{PhoneDeviceId: runtimePhone, Paying: true}}}}
	rp.rel.setReaders(runtimePhone)
	rp.device = linkTestPhone(t, st, runtimePhone)
	rp.h = &hubRuntime{sup: &supervisor{o: Options{Clock: time.Now, away: rp.away}}, st: st, tr: rp.rel, kr: kr}
	sealer := secure.NewSealer(kr)
	rp.h.newPusher(sealer)
	if rp.h.push == nil {
		t.Fatal("newPusher built no pusher over a relay that sends alerts")
	}
	rp.h.startPusher(context.Background())
	t.Cleanup(rp.h.stopPusher)
	c := hubslices.Config{Store: st, Transport: rp.rel, Sealer: sealer, DataZone: pushZone, Sources: []hubslices.Source{rp.src}}
	rp.h.withAlerts(&c)
	rp.h.pub = hubslices.NewPublisher(c)
	return rp
}

func (rp *runtimePush) raise(keys ...string) {
	rp.t.Helper()
	var as []secure.WorkAlertFields
	for _, k := range keys {
		as = append(as, workAlert(k))
	}
	rp.src.set(rp.t, as...)
	if _, err := rp.h.pub.Cycle(context.Background(), []hubslices.Kind{hubslices.KindAskAlert}); err != nil {
		rp.t.Fatal(err)
	}
}

// call is the next send_alert.
func (rp *runtimePush) call() string { return <-rp.rel.send.calls }

// noCall settles the bubble (every goroutine waits) and reports a
// send_alert made by then, if any.
func (rp *runtimePush) noCall() (string, bool) {
	synctest.Wait()
	select {
	case k := <-rp.rel.send.calls:
		return k, true
	default:
		return "", false
	}
}

func (rp *runtimePush) waitLog(line string) {
	rp.t.Helper()
	eventually(rp.t, line, func() bool { return strings.Contains(rp.logs.String(), line) })
}

// TestReconnectWakesUnavailableRetries: the relay answered UNAVAILABLE (its
// own code, after the client's retries) and the push waits its 30 s. A zone
// marker (an overflow's, or one per zone after a reconnect) does not wake
// it; the relay's WebSocket connect, through the hook newPusher set, does:
// the push is sent again at once.
func TestReconnectWakesUnavailableRetries(t *testing.T) {
	bubble(t, func(t *testing.T) {
		unavailable := fmt.Errorf("relay: send_alert: %w", relay.MapError(&client.Error{E: &relayv1.Error{
			Code: relayv1.ErrorCode_ERROR_CODE_UNAVAILABLE, Message: "unavailable",
		}}))
		rp := newRuntimePush(t, &scriptedAlerts{answers: []error{unavailable}, calls: make(chan string, 64)})
		rp.raise("ask-1")
		rp.call()
		// The settle also lets the sender reach its wait before the connect.
		rp.h.onEvent(context.Background(), transport.Event{Zone: pushZone, Resync: true})
		if k, ok := rp.noCall(); ok {
			t.Fatalf("a zone marker woke the push of %s", k)
		}
		rp.rel.connected()
		if k := rp.call(); k != "ask-1" {
			t.Fatalf("the connect woke the push of %q", k)
		}
		rp.waitLog("push of ask-1 to " + rp.device + ": accepted after 2 attempts")
	})
}

// TestPushTargetsFollowTheReadersSet: a paying phone the hub has not yet
// named in an accepted set_hub_readers (slotted after the last readers sync)
// gets no push, and no ledger row, so the alert is not settled forbidden;
// once the readers include it, the next alert reaches it.
func TestPushTargetsFollowTheReadersSet(t *testing.T) {
	bubble(t, func(t *testing.T) {
		rp := newRuntimePush(t, &scriptedAlerts{calls: make(chan string, 64)})
		rp.rel.setReaders()
		rp.raise("ask-1")
		if k, ok := rp.noCall(); ok {
			t.Fatalf("pushed %s to a phone not among the readers", k)
		}
		if began, err := rp.h.st.BeginAlertPush("ask-1", rp.device, time.Now()); err != nil || !began {
			t.Fatalf("a ledger row exists for the phone that was no target: %v, %v", began, err)
		}
		rp.rel.setReaders(runtimePhone)
		time.Sleep(hubslices.RelaySpacing) // the kind's next save is due
		rp.raise("ask-1", "ask-2")
		if k := rp.call(); k != "ask-2" {
			t.Fatalf("the next alert pushed was %q, want ask-2", k)
		}
	})
}

// TestRuntimeAlertConfigCarriesTheHooks: the publisher config the runtime
// builds hands first saves to the pusher and re-checks the runtime's own
// owner-away input; the switcher config's OnSwitched drops the queued pushes
// on a switch to CloudKit.
func TestRuntimeAlertConfigCarriesTheHooks(t *testing.T) {
	bubble(t, func(t *testing.T) {
		rp := newRuntimePush(t, &scriptedAlerts{err: rateLimited(30), calls: make(chan string, 64)})
		var c hubslices.Config
		rp.h.withAlerts(&c)
		if c.OnAlertSaved == nil || c.Away == nil {
			t.Fatal("the publisher config misses OnAlertSaved or Away")
		}
		rp.away.mu.Lock()
		rp.away.away = false
		rp.away.mu.Unlock()
		if away, err := c.Away.Away(); err != nil || away {
			t.Fatalf("the publisher's Away is not the runtime's input: %v, %v", away, err)
		}
		rp.away.mu.Lock()
		rp.away.away = true
		rp.away.mu.Unlock()

		rp.raise("ask-1", "ask-2")
		rp.call()
		sc := rp.h.switcherConfig(actions.Config{})
		if sc.OnSwitched == nil {
			t.Fatal("the switcher config has no OnSwitched")
		}
		sc.OnSwitched(transport.KindCloudKit)
		rp.waitLog("push of ask-1 to " + rp.device + ": expired (switched)")
		rp.waitLog("push of ask-2 to " + rp.device + ": expired (switched)")
	})
}

// TestRestartPushesAnAlertSavedAtOnce: after a restart the relay transport
// knows no readers until a set_hub_readers; the runtime syncs them before
// its first publish, so an alert that cycle saves at once reaches the phone
// that is a reader, exactly once.
func TestRestartPushesAnAlertSavedAtOnce(t *testing.T) {
	bubble(t, func(t *testing.T) {
		pr := startPushRig(t)
		if err := pr.stop(); err != nil {
			t.Fatal(err)
		}
		pr.src.set(t, workAlert("ask-9")) // new to the zone: the first cycle saves it
		r2 := &vouchRig{rig: newRelayRig(t, pr.dir, pr.srv), srv: pr.srv, clock: pr.clock}
		o := r2.options()
		o.newTransport, o.RelayOrigin, o.Clock, o.linkEvery = nil, pr.srv.URL, pr.clock.Now, time.Hour
		o.away = alwaysAway{}
		o.Sources = func(*state.Store) []hubslices.Source { return []hubslices.Source{pr.src} }
		r2.start(o)
		eventually(t, "the push after the restart", func() bool { return len(pr.srv.Alerts()) == 1 })
		time.Sleep(200 * time.Millisecond) // a second push would have gone by now
		synctest.Wait()
		if sent := pr.sendAlerts(); len(sent) != 1 || sent[0].GetPhoneDeviceId() != pr.phone {
			t.Fatalf("send_alert requests %v, want one to the reader", sent)
		}
	})
}
