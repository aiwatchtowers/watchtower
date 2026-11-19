package hub

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/alerts"
	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/secure"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/transport/relay"
	"watchtower/internal/hub/transport/relay/client"
	"watchtower/internal/hub/transport/relay/relayv1"
	"watchtower/internal/hub/wire"
	"watchtower/internal/logcanary"
)

// ---- the publisher and the pusher together (switch, burst) ----

// pushSource is an ask_alert slice the test fills.
type pushSource struct {
	mu    sync.Mutex
	items []hubslices.Item
}

func (*pushSource) Kind() hubslices.Kind { return hubslices.KindAskAlert }

func (s *pushSource) Items(context.Context) ([]hubslices.Item, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]hubslices.Item, len(s.items))
	for i, it := range s.items {
		it.Payload = bytes.Clone(it.Payload)
		out[i] = it
	}
	return out, nil
}

func (s *pushSource) set(t *testing.T, alerts ...secure.WorkAlertFields) {
	t.Helper()
	items := make([]hubslices.Item, 0, len(alerts))
	for _, a := range alerts {
		b, err := json.Marshal(a)
		if err != nil {
			t.Fatal(err)
		}
		items = append(items, hubslices.Item{ID: a.Key, Payload: b})
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.items = items
}

func workAlert(key string) secure.WorkAlertFields {
	return secure.WorkAlertFields{Event: "ask", Key: key, WorkbenchID: 1, WorkbenchName: "acme", Title: "t", Body: "b"}
}

// kindFlip is a memfake whose kind the test moves, as the switcher's Front
// reports the active transport.
type kindFlip struct {
	*memfake.Fake
	kind atomic.Value
}

func (f *kindFlip) Kind() transport.Kind { return f.kind.Load().(transport.Kind) }

// pushClock is a settable clock whose timers fire on advance; every timer
// is announced on waits.
type pushClock struct {
	mu     sync.Mutex
	now    time.Time
	timers []pushTimer
	waits  chan time.Duration
}

type pushTimer struct {
	at time.Time
	ch chan time.Time
}

func (c *pushClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *pushClock) Timer(d time.Duration) (<-chan time.Time, func()) {
	c.mu.Lock()
	ch := make(chan time.Time, 1)
	c.timers = append(c.timers, pushTimer{at: c.now.Add(d), ch: ch})
	c.mu.Unlock()
	c.waits <- d
	return ch, func() {}
}

func (c *pushClock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
	kept := c.timers[:0]
	for _, t := range c.timers {
		if !t.at.After(c.now) {
			t.ch <- c.now
			continue
		}
		kept = append(kept, t)
	}
	c.timers = kept
}

// scriptedAlerts answers each send_alert with the next of answers, then
// with err; with block set, it waits for the call's context instead.
type scriptedAlerts struct {
	block   bool
	answers []error // given first, in order
	err     error
	mu      sync.Mutex
	keys    []string
	calls   chan string
}

func (s *scriptedAlerts) SendAlert(ctx context.Context, _ string, p secure.Push) error {
	s.mu.Lock()
	s.keys = append(s.keys, p.Key())
	err := s.err
	if len(s.answers) > 0 {
		err, s.answers = s.answers[0], s.answers[1:]
	}
	s.mu.Unlock()
	s.calls <- p.Key()
	if s.block {
		<-ctx.Done()
		return fmt.Errorf("relay: send_alert: %w", relay.MapError(ctx.Err()))
	}
	return err
}

func (s *scriptedAlerts) sent() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.keys)
}

func rateLimited(after uint32) error {
	return fmt.Errorf("relay: send_alert: %w", relay.MapError(&client.Error{E: &relayv1.Error{
		Code: relayv1.ErrorCode_ERROR_CODE_RATE_LIMITED, Message: "rate limited", RetryAfterS: &after,
	}}))
}

// pushWorld is a publisher on a kind-moving memfake whose OnAlertSaved is a
// running pusher's Enqueue, with one linked phone.
type pushWorld struct {
	t      *testing.T
	st     *state.Store
	kr     *identity.Keyring
	fake   *memfake.Fake
	tr     *kindFlip
	clock  *pushClock
	send   *scriptedAlerts
	src    *pushSource
	push   *alerts.Pusher
	pub    *hubslices.Publisher
	device string
	logs   *logcanary.Sink
	saved  atomic.Int32 // OnAlertSaved calls
}

const pushZone = "data/hubpushtest"

func newPushWorld(t *testing.T, send *scriptedAlerts, extra ...hubslices.Source) *pushWorld {
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
	w := &pushWorld{t: t, st: st, send: send, src: &pushSource{}, logs: logcanary.Capture(t),
		clock: &pushClock{now: time.Unix(1_800_000_000, 0).UTC(), waits: make(chan time.Duration, 256)}}
	if w.kr, err = identity.NewKeyring(id, st, w.clock.Now); err != nil {
		t.Fatal(err)
	}
	w.fake = memfake.New(transport.KindRelay, w.clock.Now)
	w.tr = &kindFlip{Fake: w.fake}
	w.tr.kind.Store(transport.KindRelay)
	w.device = linkTestPhone(t, st, "relay-phone-a")
	sealer := secure.NewSealer(w.kr)
	w.push = alerts.New(alerts.Config{
		Store: st, Sealer: sealer, Send: send, Clock: w.clock.Now, Timer: w.clock.Timer,
		Targets: func(context.Context) ([]alerts.Target, error) {
			return []alerts.Target{{DeviceID: w.device, RelayID: "relay-phone-a"}}, nil
		},
	})
	if err := w.push.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(w.push.Stop)
	w.pub = hubslices.NewPublisher(hubslices.Config{
		Store: st, Transport: w.tr, Sealer: sealer, DataZone: pushZone, Sources: append([]hubslices.Source{w.src}, extra...),
		Clock: w.clock.Now, Away: alwaysAway{},
		OnAlertSaved: func(key string, f secure.WorkAlertFields, at time.Time) {
			w.saved.Add(1)
			w.push.Enqueue(key, f, at)
		},
	})
	return w
}

// linkTestPhone writes a linked phone with relayID into the sidecar.
func linkTestPhone(t *testing.T, st *state.Store, relayID string) string {
	t.Helper()
	_, sig, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	kx, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	devID := secure.DeviceID(sig.Public().(ed25519.PublicKey)).String()
	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0xa}, 16))
	if err := st.WithTx(context.Background(), func(tx *sql.Tx) error {
		return state.LinkDevice(tx, state.Device{
			ID: devID, Name: "iPhone", Scope: wire.ScopePrivate, LinkedAt: time.Now(),
			SigningKey: sig.Public().(ed25519.PublicKey), AgreementKey: kx.PublicKey().Bytes(), LinkNonce: nonce,
			RelayDeviceID: relayID,
		})
	}); err != nil {
		t.Fatal(err)
	}
	return devID
}

func (w *pushWorld) cycle(kinds ...hubslices.Kind) {
	w.t.Helper()
	if _, err := w.pub.Cycle(context.Background(), kinds); err != nil {
		w.t.Fatalf("Cycle: %v", err)
	}
}

func (w *pushWorld) nextCall() string { return <-w.send.calls }

func (w *pushWorld) nextWait() time.Duration { return <-w.clock.waits }

// settledLine is the pusher's log line for a settled push.
func (w *pushWorld) settledLine(key, outcome string) string {
	return "push of " + key + " to " + w.device + ": " + outcome
}

func (w *pushWorld) waitLog(line string) {
	w.t.Helper()
	eventually(w.t, line, func() bool { return strings.Contains(w.logs.String(), line) })
}

// signalled is which of keys have a signal record in the zone.
func (w *pushWorld) signalled(keys ...string) map[string]bool {
	w.t.Helper()
	sealer := secure.NewSealer(w.kr)
	live := map[string]bool{}
	var since uint64
	for {
		b, err := w.fake.Changes(context.Background(), pushZone, since)
		if err != nil {
			w.t.Fatal(err)
		}
		for _, c := range b.Changed {
			live[c.Name] = true
		}
		for _, n := range b.Deleted {
			delete(live, n)
		}
		since = b.NewSeq
		if !b.More {
			break
		}
	}
	out := map[string]bool{}
	for _, k := range keys {
		wn, err := sealer.WireName(secure.ZoneData, "ask_alert-"+k)
		if err != nil {
			w.t.Fatal(err)
		}
		out[k] = live[secure.SignalName(wn)]
	}
	return out
}

func (w *pushWorld) toCloudKit() {
	w.t.Helper()
	w.tr.kind.Store(transport.KindCloudKit)
	switchPushes(w.push, w.pub, transport.KindCloudKit)
}

// TestSwitchToCloudKitStopsQueuedPushes (Review Focus 5): a switch while
// pushes wait sends no send_alert after it; the one in progress settles
// expired in_flight, the queued ones expired switched, and an alert saved on
// CloudKit afterwards is never pushed.
func TestSwitchToCloudKitStopsQueuedPushes(t *testing.T) {
	bubble(t, func(t *testing.T) {
		w := newPushWorld(t, &scriptedAlerts{block: true, calls: make(chan string, 64)})
		w.src.set(t, workAlert("ask-1"), workAlert("ask-2"), workAlert("ask-3"))
		w.cycle(hubslices.KindAskAlert)
		first := w.nextCall()
		w.toCloudKit()
		w.waitLog(w.settledLine(first, "expired (in_flight)"))
		for _, k := range []string{"ask-1", "ask-2", "ask-3"} {
			if k != first {
				w.waitLog(w.settledLine(k, "expired (switched)"))
			}
		}
		w.clock.advance(hubslices.CloudKitSpacing)
		w.src.set(t, workAlert("ask-1"), workAlert("ask-2"), workAlert("ask-3"), workAlert("ask-4"))
		w.cycle(hubslices.KindAskAlert)
		time.Sleep(100 * time.Millisecond) // a sender that would still send has done so
		synctest.Wait()
		if got := w.send.sent(); len(got) != 1 {
			t.Fatalf("send_alert calls %v, want only the one before the switch", got)
		}
		if n, err := w.st.ExpirePendingAlertPushes(w.clock.Now()); err != nil || n != 0 {
			t.Fatalf("%d pushes left pending, %v", n, err)
		}
	})
}

// TestSwitchToCloudKitResignalsOpenQueuedAlerts (Review Focus 5): two
// alerts waiting (one in a retry wait, one queued), one resolved before the
// switch: both pushes expire switched, the open one gets one signal on
// CloudKit, the resolved one none.
func TestSwitchToCloudKitResignalsOpenQueuedAlerts(t *testing.T) {
	bubble(t, func(t *testing.T) {
		w := newPushWorld(t, &scriptedAlerts{err: rateLimited(30), calls: make(chan string, 64)})
		w.src.set(t, workAlert("ask-1"), workAlert("ask-2"))
		w.cycle(hubslices.KindAskAlert)
		w.nextCall()
		if d := w.nextWait(); d != 30*time.Second {
			t.Fatalf("retry wait %v, want the relay's 30 s", d)
		}
		w.src.set(t, workAlert("ask-1")) // ask-2 resolved
		w.toCloudKit()
		w.waitLog(w.settledLine("ask-1", "expired (switched)"))
		w.waitLog(w.settledLine("ask-2", "expired (switched)"))
		w.clock.advance(hubslices.CloudKitSpacing)
		w.cycle()
		if got := w.signalled("ask-1", "ask-2"); !got["ask-1"] || got["ask-2"] {
			t.Fatalf("signals on CloudKit %v, want ask-1 only", got)
		}
		if got := w.send.sent(); len(got) != 1 {
			t.Fatalf("send_alert calls %v after the switch", got)
		}
	})
}

// TestRateLimitedBurstNeverBlocksPublishing (Review Focus 4): ten alerts
// against a relay answering RATE_LIMITED 30 s. The cycle that enqueues them
// returns while the pushes wait, the next slice save follows within the
// relay's spacing, retries honour retry_after_s, and the pushes left expire
// once the five minutes are over.
func TestRateLimitedBurstNeverBlocksPublishing(t *testing.T) {
	bubble(t, func(t *testing.T) {
		var n atomic.Int64
		w := newPushWorld(t, &scriptedAlerts{err: rateLimited(30), calls: make(chan string, 256)}, bumpSource{&n})
		var burst []secure.WorkAlertFields
		for i := range 10 {
			burst = append(burst, workAlert(fmt.Sprintf("stop-%d-1000", i)))
		}
		w.src.set(t, burst...)
		w.cycle(hubslices.KindAskAlert)
		first := w.nextCall()

		n.Add(1)
		start := time.Now()
		rep, err := w.pub.Cycle(context.Background(), []hubslices.Kind{"target"})
		if err != nil || rep.Saved != 1 {
			t.Fatalf("the next save: %+v, %v", rep, err)
		}
		if took := time.Since(start); took > hubslices.RelaySpacing {
			t.Fatalf("the next save took %v with ten pushes waiting", took)
		}

		end := w.clock.Now().Add(alerts.Freshness)
		for w.clock.Now().Before(end) {
			if d := w.nextWait(); d != 30*time.Second {
				t.Fatalf("retry wait %v, want the relay's 30 s", d)
			}
			w.clock.advance(30 * time.Second)
			if w.clock.Now().Before(end) {
				w.nextCall()
			}
		}
		for _, a := range burst {
			w.waitLog(w.settledLine(a.Key, "expired (freshness)"))
		}
		for _, k := range w.send.sent() {
			if k != first {
				t.Fatalf("%s was sent while %s waited: one push at a time per phone", k, first)
			}
		}
	})
}

// ---- the running hub on the fake relay ----

// pushRig is a running hub on relaytest with an ask_alert source the test
// fills, its alerts nudged by a phone action, and one linked, admitted,
// paying phone that registered a push token.
type pushRig struct {
	*vouchRig
	src    *pushSource
	l      linkedPhone
	phone  string // the phone's relay device id
	marked atomic.Pointer[[]secure.WorkAlertFields]
}

func startPushRig(t *testing.T) *pushRig {
	t.Helper()
	pr := &pushRig{src: &pushSource{}}
	pr.vouchRig = startOnRelay(t, false, func(o *Options) {
		o.away = alwaysAway{}
		o.Sources = func(*state.Store) []hubslices.Source { return []hubslices.Source{pr.src} }
		o.Register = func(d *actions.Dispatcher) {
			d.Register("alert_test", func(context.Context, actions.Request) actions.Outcome {
				if next := pr.marked.Load(); next != nil {
					pr.src.set(t, *next...)
				}
				return actions.Outcome{Status: wire.StatusApplied}
			}, actions.KindOptions{Nudges: []string{string(hubslices.KindAskAlert)}})
		}
	})
	pr.l = pr.link()
	pr.admit(pr.l)
	pr.phone = pr.device(t).RelayDeviceID
	if _, err := pr.l.store.C.Do(t.Context(), &relayv1.Request{Op: &relayv1.Request_RegisterPush{RegisterPush: &relayv1.RegisterPushToken{
		Token: "a1b2c3", Env: relayv1.PushEnv_PUSH_ENV_SANDBOX,
	}}}); err != nil {
		t.Fatal(err)
	}
	eventually(t, "the phone a hub reader", func() bool {
		rs := pr.srv.Readers()
		return len(rs) > 0 && slices.Contains(rs[len(rs)-1], pr.phone)
	})
	return pr
}

// raise makes alerts the slice (from the next nudge on) and nudges it with
// a phone action.
func (pr *pushRig) raise(alerts ...secure.WorkAlertFields) {
	pr.t.Helper()
	// The rig's clock is frozen: one step past the relay spacing, so the
	// nudged cycle writes the kind again.
	pr.clock.Advance(time.Second)
	pr.marked.Store(&alerts)
	if _, err := pr.l.phone.Act("alert_test"); err != nil {
		pr.t.Fatal(err)
	}
}

func (pr *pushRig) sendAlerts() []*relayv1.SendAlert {
	var out []*relayv1.SendAlert
	for _, r := range pr.srv.Requests("send_alert") {
		out = append(out, r.GetSendAlert())
	}
	return out
}

// TestE2ECanary_AlertPushCarriesNoPlaintext: canaries in the workbench name,
// title and body of an alert never appear in the send_alert the relay got
// (in any encoding), which goes to the phone's relay id, and its envelope
// opens with the phone's K_alert under alert-push to the alert, canaries
// and key intact.
func TestE2ECanary_AlertPushCarriesNoPlaintext(t *testing.T) {
	bubble(t, func(t *testing.T) {
		pr := startPushRig(t)
		a := secure.WorkAlertFields{
			Event: "ask", Key: "ask-41", WorkbenchID: 7, WorkbenchName: logcanary.Text("alert.workbench"),
			Title: logcanary.Text("alert.title"), Body: logcanary.Text("alert.body"),
		}
		pr.raise(a)
		eventually(t, "the relay accepted the push", func() bool { return len(pr.srv.Alerts()) == 1 })
		sent := pr.sendAlerts()
		if len(sent) != 1 || sent[0].GetPhoneDeviceId() != pr.phone {
			t.Fatalf("send_alert requests %v, want one to %s", sent, pr.phone)
		}
		canaries := []string{a.WorkbenchName, a.Title, a.Body, logcanary.Marker}
		for _, c := range slices.Clone(canaries) {
			canaries = append(canaries, base64.StdEncoding.EncodeToString([]byte(c)), base64.RawURLEncoding.EncodeToString([]byte(c)))
		}
		for _, f := range pr.srv.Frames() {
			for _, c := range canaries {
				if bytes.Contains(f, []byte(c)) {
					t.Fatalf("a frame the relay got carries %q in the clear", c)
				}
			}
		}
		f, err := pr.l.phone.OpenAlertPush(transport.DataZone(pr.l.lp.RelayDeviceID), sent[0].GetEnvelope())
		if err != nil {
			t.Fatalf("the push does not open as the NSE opens it: %v", err)
		}
		var got secure.WorkAlertFields
		if err := json.Unmarshal(f.Payload, &got); err != nil {
			t.Fatal(err)
		}
		if f.Kind != "ask_alert" || f.ID != "ask_alert-ask-41" || got != a {
			t.Fatalf("opened %s %s %+v, want the alert", f.Kind, f.ID, got)
		}
	})
}

// TestAccountRefreshUpdatesTargets: a phone that stopped paying
// (ENTITLEMENT_EXPIRED, which makes the transport read the account) gets no
// push; once the account state is read again with it paying (a SLOT_ADDED
// control here; the readers sync reads it too), the next alert reaches it.
func TestAccountRefreshUpdatesTargets(t *testing.T) {
	bubble(t, func(t *testing.T) {
		pr := startPushRig(t)
		reads := pr.accountReads()
		pr.srv.SetPaying(pr.phone, false) // ENTITLEMENT_EXPIRED to the hub: it reads the account
		eventually(t, "the account read after the control", func() bool { return pr.accountReads() > reads })
		pr.raise(workAlert("ask-1"))
		time.Sleep(time.Second) // the nudged cycle and its enqueue
		synctest.Wait()
		if n := len(pr.sendAlerts()); n != 0 {
			t.Fatalf("%d send_alert to a phone that does not pay", n)
		}
		pr.srv.SetPaying(pr.phone, true)
		pr.srv.Push(t, &relayv1.Event{Kind: &relayv1.Event_Control{Control: &relayv1.Control{
			Kind: relayv1.ControlKind_CONTROL_KIND_SLOT_ADDED, Detail: pr.phone,
		}}})
		reads = pr.accountReads()
		eventually(t, "the account read after SLOT_ADDED", func() bool { return pr.accountReads() > reads })
		pr.raise(workAlert("ask-1"), workAlert("ask-2"))
		eventually(t, "the push of the next alert", func() bool { return len(pr.srv.Alerts()) == 1 })
		if sent := pr.sendAlerts(); len(sent) != 1 || sent[0].GetPhoneDeviceId() != pr.phone {
			t.Fatalf("send_alert requests %v", sent)
		}
	})
}

// TestWorkAlertsOffOnTheRelayStopsSendAlert (Open decision 1, option A): the
// phone's device record over the relay turns its alerts off and on again. While
// off an alert is not pushed; the next one after it is, once.
func TestWorkAlertsOffOnTheRelayStopsSendAlert(t *testing.T) {
	bubble(t, func(t *testing.T) {
		pr := startPushRig(t)
		record := func(off *bool, name string) {
			t.Helper()
			pr.clock.Advance(time.Second)
			if _, err := pr.l.phone.WriteDeviceRecord(wire.DevicePayload{DeviceID: pr.l.phone.ID().String(), Name: name,
				Scope: wire.ScopePrivate, StartSessions: true, WorkAlertsOff: off,
				UpdatedAt: wire.Time{Time: pr.clock.Now()}}, ""); err != nil {
				t.Fatal(err)
			}
			eventually(t, "the device record applied", func() bool { return pr.device(t).Name == name })
		}
		off := true
		record(&off, "Switch off")
		if !pr.device(t).WorkAlertsOff {
			t.Fatal("the switch was not stored")
		}
		pr.raise(workAlert("ask-off"))
		eventually(t, "the phone's action reached the source", func() bool {
			items, err := pr.src.Items(t.Context())
			return err == nil && len(items) == 1
		})
		time.Sleep(time.Second) // a push would have gone by now
		synctest.Wait()
		if sent := pr.srv.Alerts(); len(sent) != 0 {
			t.Fatalf("pushed while off: %v", sent)
		}
		record(nil, "Switch on")
		pr.raise(workAlert("ask-on"))
		eventually(t, "the push after the switch came on", func() bool { return len(pr.srv.Alerts()) == 1 })
		if sent := pr.sendAlerts(); len(sent) != 1 {
			t.Fatalf("send_alert %v, want one", sent)
		}
	})
}

// TestAnAlertOpenWhenTheSwitchComesBackOnIsNotPushed: Enqueue fires on an
// alert's first save only, so an alert raised while off stays unpushed through
// the next cycles after the switch came back on.
func TestAnAlertOpenWhenTheSwitchComesBackOnIsNotPushed(t *testing.T) {
	bubble(t, func(t *testing.T) {
		pr := startPushRig(t)
		record := func(off *bool, name string) {
			t.Helper()
			pr.clock.Advance(time.Second)
			if _, err := pr.l.phone.WriteDeviceRecord(wire.DevicePayload{DeviceID: pr.l.phone.ID().String(), Name: name,
				Scope: wire.ScopePrivate, StartSessions: true, WorkAlertsOff: off,
				UpdatedAt: wire.Time{Time: pr.clock.Now()}}, ""); err != nil {
				t.Fatal(err)
			}
			eventually(t, "the device record applied", func() bool { return pr.device(t).Name == name })
		}
		off := true
		record(&off, "Switch off")
		open := workAlert("ask-open")
		pr.raise(open)
		eventually(t, "the phone's action reached the source", func() bool {
			items, err := pr.src.Items(t.Context())
			return err == nil && len(items) == 1
		})
		time.Sleep(time.Second)
		synctest.Wait()
		record(nil, "Switch on")
		pr.raise(open) // the next cycle, the alert still open
		time.Sleep(time.Second)
		synctest.Wait()
		if sent := pr.srv.Alerts(); len(sent) != 0 {
			t.Fatalf("pushed after the switch came on: %v", sent)
		}
	})
}

// TestFarewellOverTheRelay: the farewell a phone flushes while it still holds
// the slot unlinks; one the hub reaches only after the slot went cannot be read
// (the Worker's rule, EnforceMailboxRead), and the row stays for the owner.
func TestFarewellOverTheRelay(t *testing.T) {
	farewell := func(t *testing.T, pr *pushRig) {
		t.Helper()
		unlinked := true
		if _, err := pr.l.phone.WriteDeviceRecord(wire.DevicePayload{DeviceID: pr.l.phone.ID().String(), Name: "Test Phone",
			Scope: wire.ScopePrivate, Unlinked: &unlinked, UpdatedAt: wire.Time{Time: pr.clock.Now()}}, ""); err != nil {
			t.Fatal(err)
		}
	}
	devices := func(t *testing.T, pr *pushRig) int {
		t.Helper()
		st, err := state.OpenReadOnly(pr.dir)
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = st.Close() }()
		ds, err := st.Devices()
		if err != nil {
			t.Fatal(err)
		}
		return len(ds)
	}
	t.Run("the slot still held", func(t *testing.T) {
		bubble(t, func(t *testing.T) {
			pr := startPushRig(t)
			pr.srv.EnforceMailboxRead()
			farewell(t, pr)
			eventually(t, "the row gone", func() bool { return devices(t, pr) == 0 })
		})
	})
	t.Run("the slot gone first", func(t *testing.T) {
		bubble(t, func(t *testing.T) {
			pr := startPushRig(t)
			pr.srv.EnforceMailboxRead()
			if err := pr.stop(); err != nil {
				t.Fatal(err)
			}
			farewell(t, pr)
			pr.srv.RemoveSlot(pr.phone, pr.l.lp.RelayDeviceID)
			r2 := &vouchRig{rig: newRelayRig(t, pr.dir, pr.srv), srv: pr.srv, clock: pr.clock}
			o := r2.options()
			o.newTransport, o.RelayOrigin, o.Clock, o.linkEvery = nil, pr.srv.URL, pr.clock.Now, time.Hour
			r2.start(o)
			time.Sleep(time.Second) // the hub is up and has tried its mailbox
			synctest.Wait()
			if got := devices(t, pr); got != 1 {
				t.Fatalf("devices %d: the row stays for the owner", got)
			}
		})
	})
}

// ---- sealed in an epoch the phone holds (relay client Phase 5, Task 5) ----

// envelopeAlerts accepts every send_alert and hands its envelope out per
// relay device id.
type envelopeAlerts struct{ calls chan [2]string }

func (e *envelopeAlerts) SendAlert(_ context.Context, relayID string, p secure.Push) error {
	e.calls <- [2]string{relayID, string(p.Envelope())}
	return nil
}

// pushEnvelopes enqueues key's push to phones over r's keyring through the
// runtime's EpochFor (alertEpochFor) and returns each phone's envelope.
func (r *relayKeysRig) pushEnvelopes(key string, phones ...*hubtest.Phone) map[string][]byte {
	r.t.Helper()
	send := &envelopeAlerts{calls: make(chan [2]string, len(phones))}
	targets := make([]alerts.Target, 0, len(phones))
	for _, ph := range phones {
		targets = append(targets, alerts.Target{DeviceID: ph.ID().String(), RelayID: ph.RelayDeviceID()})
	}
	p := alerts.New(alerts.Config{
		Store: r.st, Sealer: secure.NewSealer(r.kr), Send: send, Clock: r.clock,
		Targets:  func(context.Context) ([]alerts.Target, error) { return targets, nil },
		EpochFor: alertEpochFor(r.st, r.kr),
	})
	if err := p.Start(context.Background()); err != nil {
		r.t.Fatal(err)
	}
	defer p.Stop()
	p.Enqueue(key, workAlert(key), r.clock())
	out := map[string][]byte{}
	for range phones {
		c := <-send.calls
		out[c[0]] = []byte(c[1])
	}
	return out
}

// ack is the phone's epoch_ack of epoch as the hub stored it.
func (r *relayKeysRig) ack(ph *hubtest.Phone, epoch uint32) {
	r.t.Helper()
	if err := r.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		return state.AckEpoch(tx, ph.ID().String(), epoch)
	}); err != nil {
		r.t.Fatal(err)
	}
}

// opensHeld opens env as ph's notification extension does, with the alert
// keys it held at its last unlock, and returns the epoch it was sealed in.
func opensHeld(t *testing.T, ph *hubtest.Phone, key string, env []byte) uint32 {
	t.Helper()
	h, f, err := ph.OpenHeldAlertPush(env)
	if err != nil {
		t.Fatalf("a locked phone does not open the push: %v", err)
	}
	if f.ID != "ask_alert-"+key {
		t.Fatalf("opened %s, want the alert %s", f.ID, key)
	}
	return h.Epoch
}

// TestAlertPushSealedInAnEpochThePhoneHolds (F11): a phone that acked epoch
// e and stayed locked across the rotation to e+1 opens the push with its
// K_alert[e], whether it offered a relay key or not.
func TestAlertPushSealedInAnEpochThePhoneHolds(t *testing.T) {
	for _, offering := range []bool{false, true} {
		t.Run(fmt.Sprintf("offering=%v", offering), func(t *testing.T) {
			r := newRelayKeysRig(t, "relay")
			ph := r.phone()
			if offering {
				r.offer(ph)
			}
			r.keybox(ph) // its last unlock
			r.ack(ph, 1)
			r.advance(week)
			r.rotateIfDue(true)
			if r.epoch() != 2 {
				t.Fatalf("epoch %d after the rotation, want 2", r.epoch())
			}
			env := r.pushEnvelopes("ask-1", ph)[ph.RelayDeviceID()]
			if e := opensHeld(t, ph, "ask-1", env); e != 1 {
				t.Fatalf("sealed in epoch %d, want the acked 1", e)
			}
		})
	}
}

// TestAlertPushFallsBackToCurrentAfterRetention: once the acked epoch left
// retention the push is sealed in the current epoch (the phone, unlocked
// since, holds it; one locked that long gets the content-free notice).
func TestAlertPushFallsBackToCurrentAfterRetention(t *testing.T) {
	r := newRelayKeysRig(t, "relay")
	ph := r.phone()
	r.keybox(ph)
	r.ack(ph, 1)
	r.advance(week)
	r.rotateIfDue(true)
	r.advance(week + time.Hour)
	r.rotateIfDue(true)
	if r.epoch() != 3 {
		t.Fatalf("epoch %d, want 3", r.epoch())
	}
	r.keybox(ph) // unlocked at last; its ack has not reached the hub
	env := r.pushEnvelopes("ask-1", ph)[ph.RelayDeviceID()]
	if e := opensHeld(t, ph, "ask-1", env); e != 3 {
		t.Fatalf("sealed in epoch %d, want the current 3", e)
	}
}

// TestTwoPhonesOnDifferentEpochsGetTheirOwnSeal: two locked phones that
// acked different retained epochs each get the push in their own epoch, and
// neither seal opens with the other phone's held keys alone.
func TestTwoPhonesOnDifferentEpochsGetTheirOwnSeal(t *testing.T) {
	r := newRelayKeysRig(t, "relay")
	a, b := r.phone(), r.phone()
	r.keybox(a)
	r.ack(a, 1) // a stays locked from here on
	if err := r.kr.Rotate(identity.ReasonManual); err != nil {
		t.Fatal(err)
	}
	r.keybox(b)
	r.ack(b, 2)
	r.advance(time.Hour)
	if err := r.kr.Rotate(identity.ReasonManual); err != nil {
		t.Fatal(err)
	}
	if r.epoch() != 3 {
		t.Fatalf("epoch %d, want 3", r.epoch())
	}
	envs := r.pushEnvelopes("ask-1", a, b)
	if e := opensHeld(t, a, "ask-1", envs[a.RelayDeviceID()]); e != 1 {
		t.Fatalf("a's push sealed in epoch %d, want 1", e)
	}
	if e := opensHeld(t, b, "ask-1", envs[b.RelayDeviceID()]); e != 2 {
		t.Fatalf("b's push sealed in epoch %d, want 2", e)
	}
	if _, _, err := a.OpenHeldAlertPush(envs[b.RelayDeviceID()]); err == nil {
		t.Fatal("a opens b's push, sealed in an epoch a never held")
	}
}

// TestRotationAt7DaysSendsNoSecondAlert: an open ask through three weekly
// rotations on the relay is handed to the pusher once (one OnAlertSaved, the
// alert's signal on the relay) and gets exactly one send_alert; each
// rotation reseals it.
func TestRotationAt7DaysSendsNoSecondAlert(t *testing.T) {
	bubble(t, func(t *testing.T) {
		send := &scriptedAlerts{calls: make(chan string, 16)}
		w := newPushWorld(t, send)
		if err := w.st.SetMeta(state.MetaTransport, "relay"); err != nil {
			t.Fatal(err)
		}
		w.src.set(t, workAlert("ask-1"))
		w.cycle(hubslices.KindAskAlert)
		w.nextCall()
		w.waitLog(w.settledLine("ask-1", "accepted"))
		for i := range 3 {
			w.clock.advance(week)
			if due, err := w.kr.RotateIfDue(rotationAlso); err != nil || !due {
				t.Fatalf("rotation %d: RotateIfDue = %v, %v", i+1, due, err)
			}
			if rep, err := w.pub.Cycle(context.Background(), nil); err != nil || rep.Saved == 0 {
				t.Fatalf("rotation %d: the cycle resealed nothing: %+v, %v", i+1, rep, err)
			}
		}
		if e, _ := w.kr.CurrentEpoch(); e != 4 {
			t.Fatalf("epoch %d, want 4", e)
		}
		time.Sleep(200 * time.Millisecond) // a second push would have gone by now
		synctest.Wait()
		if got := send.sent(); len(got) != 1 {
			t.Fatalf("send_alert %v, want exactly one", got)
		}
		if n := w.saved.Load(); n != 1 {
			t.Fatalf("OnAlertSaved %d times, want 1", n)
		}
	})
}

// TestAlertEpochForUnreadableReadsAsCurrent: an unknown device or an
// unreadable sidecar seals in the current epoch (0), today's sealing.
func TestAlertEpochForUnreadableReadsAsCurrent(t *testing.T) {
	r := newRelayKeysRig(t, "relay")
	ph := r.phone()
	r.ack(ph, 1)
	if err := r.kr.Rotate(identity.ReasonManual); err != nil {
		t.Fatal(err)
	}
	epochFor := alertEpochFor(r.st, r.kr)
	if e := epochFor(ph.ID().String()); e != 1 {
		t.Fatalf("EpochFor = %d, want the acked 1", e)
	}
	if e := epochFor("unknown-device"); e != 0 {
		t.Fatalf("EpochFor of an unknown device = %d, want 0", e)
	}
	if err := r.st.Close(); err != nil {
		t.Fatal(err)
	}
	if e := epochFor(ph.ID().String()); e != 0 {
		t.Fatalf("EpochFor over a closed sidecar = %d, want 0", e)
	}
}
