package slices

import (
	"encoding/json"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
)

// flipTransport is the rig's fake whose kind a test moves (the switcher's
// Front reports the active transport's kind).
type flipTransport struct {
	*memfake.Fake
	kind atomic.Value // transport.Kind
}

func (f *flipTransport) Kind() transport.Kind { return f.kind.Load().(transport.Kind) }

func (r *rig) flip(k transport.Kind) *flipTransport {
	f := &flipTransport{Fake: r.tr}
	f.kind.Store(k)
	return f
}

// savedAlert is one OnAlertSaved call.
type savedAlert struct {
	key    string
	fields secure.WorkAlertFields
	at     time.Time
}

type alertLog struct {
	mu    sync.Mutex
	calls []savedAlert
}

func (l *alertLog) saved(key string, f secure.WorkAlertFields, at time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.calls = append(l.calls, savedAlert{key, f, at})
}

func (l *alertLog) keys() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	out := make([]string, len(l.calls))
	for i, c := range l.calls {
		out[i] = c.key
	}
	return out
}

// alertItem is an ask_alert item with a WorkAlertFields payload.
func alertItem(t *testing.T, key, title string) Item {
	t.Helper()
	b, err := json.Marshal(secure.WorkAlertFields{Event: "ask", Key: key, WorkbenchID: 3, WorkbenchName: "acme", Title: title, Body: "b"})
	if err != nil {
		t.Fatal(err)
	}
	return Item{ID: key, Payload: b}
}

type fixedAway struct{ away atomic.Bool }

func (a *fixedAway) Away() (bool, error) { return a.away.Load(), nil }

// TestFirstSaveOfAnAlertEnqueuesAPushOnRelay: an alert that first reaches
// the relay's zone is handed to OnAlertSaved once, with its fields and the
// save's time, after its state write.
func TestFirstSaveOfAnAlertEnqueuesAPushOnRelay(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	src := &fakeSource{kind: KindAskAlert}
	src.set(alertItem(t, "ask-7", "Deploy?"))
	var log alertLog
	p := r.publisherWith(Config{OnAlertSaved: log.saved}, src)
	r.cycle(p, KindAskAlert)
	if len(log.calls) != 1 {
		t.Fatalf("%d OnAlertSaved calls, want 1", len(log.calls))
	}
	c := log.calls[0]
	if c.key != "ask-7" || c.fields.Key != "ask-7" || c.fields.Title != "Deploy?" || c.fields.WorkbenchName != "acme" || !c.at.Equal(r.clock()) {
		t.Fatalf("call %+v", c)
	}
	if known, _ := r.st.SliceHashes(string(KindAskAlert)); known["ask_alert-ask-7"].Hash == "" {
		t.Fatal("OnAlertSaved before the alert's state write")
	}
}

// TestRepublishAndRotationNeverPushAgain: a changed payload, a rotation's
// reseal and a full diff resave the alert without a second OnAlertSaved; an
// alert whose first save was refused is pushed at its first successful save.
func TestRepublishAndRotationNeverPushAgain(t *testing.T) {
	r := newRig(t, transport.KindRelay)
	src := &fakeSource{kind: KindAskAlert}
	src.set(alertItem(t, "ask-7", "one"))
	var log alertLog
	p := r.publisherWith(Config{OnAlertSaved: log.saved}, src)
	r.cycle(p, KindAskAlert)

	r.advance(RelaySpacing)
	src.set(alertItem(t, "ask-7", "two"))
	if rep := r.cycle(p, KindAskAlert); rep.Saved != 1 {
		t.Fatalf("changed alert not resaved: %+v", rep)
	}
	if err := r.kr.Rotate(identity.ReasonManual); err != nil {
		t.Fatal(err)
	}
	r.advance(RelaySpacing)
	if rep := r.cycle(p); rep.Saved == 0 {
		t.Fatalf("the rotation resealed nothing: %+v", rep)
	}

	// A second alert refused on its first save, then saved.
	r.advance(RelaySpacing)
	src.set(alertItem(t, "ask-7", "two"), alertItem(t, "ask-8", "three"))
	r.tr.FailNext("save", transport.ErrUnavailable)
	if _, err := p.Cycle(t.Context(), []Kind{KindAskAlert}); err == nil {
		t.Fatal("the failed save did not fail the cycle")
	}
	r.advance(RelaySpacing)
	r.cycle(p, KindAskAlert)
	r.advance(RelaySpacing)
	r.cycle(p, KindAskAlert)
	if got := log.keys(); len(got) != 2 || got[0] != "ask-7" || got[1] != "ask-8" {
		t.Fatalf("OnAlertSaved keys %v, want [ask-7 ask-8]", got)
	}
}

// TestNoSendAlertOnCloudKit: an alert saved on CloudKit gets its signal and
// is never handed to the pusher.
func TestNoSendAlertOnCloudKit(t *testing.T) {
	r := newRig(t, transport.KindCloudKit)
	src := &fakeSource{kind: KindAskAlert}
	src.set(alertItem(t, "ask-7", "x"))
	var log alertLog
	r.cycle(r.publisherWith(Config{OnAlertSaved: log.saved}, src), KindAskAlert)
	if len(log.calls) != 0 {
		t.Fatalf("OnAlertSaved on CloudKit: %v", log.keys())
	}
	if n := r.signalCount(); n != 1 {
		t.Fatalf("%d signals on CloudKit, want 1", n)
	}
}

// resignalRig publishes ask-1 and ask-2 on the relay with two linked
// phones, then moves the transport to CloudKit.
func resignalRig(t *testing.T, away bool) (*rig, *Publisher, *fakeSource, []phone) {
	t.Helper()
	r := newRig(t, transport.KindRelay)
	phones := []phone{r.linkPhone(), r.linkPhone()}
	src := &fakeSource{kind: KindAskAlert}
	src.set(alertItem(t, "ask-1", "a"), alertItem(t, "ask-2", "b"))
	ft := r.flip(transport.KindRelay)
	a := &fixedAway{}
	a.away.Store(away)
	var log alertLog
	p := r.publisherWith(Config{Transport: ft, OnAlertSaved: log.saved, Away: a}, src)
	r.cycle(p, KindAskAlert)
	if r.signalCount() != 0 || len(log.calls) != 2 {
		t.Fatalf("on the relay: %d signals, %d pushes", r.signalCount(), len(log.calls))
	}
	ft.kind.Store(transport.KindCloudKit)
	r.advance(CloudKitSpacing)
	return r, p, src, phones
}

func settle(t *testing.T, st *state.Store, key, device, outcome, reason string) {
	t.Helper()
	if _, err := st.BeginAlertPush(key, device, time.Now()); err != nil {
		t.Fatal(err)
	}
	if ok, err := st.SettleAlertPush(key, device, outcome, reason, 1, time.Now()); err != nil || !ok {
		t.Fatalf("settle %s/%s: %v, %v", key, device, ok, err)
	}
}

// signalled is which of the keys have a signal in the zone.
func (r *rig) signalled(keys ...string) map[string]bool {
	live := r.live()
	out := map[string]bool{}
	for _, k := range keys {
		_, out[k] = live[secure.SignalName(r.wireName("ask_alert-"+k))]
	}
	return out
}

// TestResignalSignalsOpenAlertsOnCloudKit: after a switch, an open alert
// asked for is resaved with its signal once; one resolved meanwhile writes
// nothing.
func TestResignalSignalsOpenAlertsOnCloudKit(t *testing.T) {
	r, p, src, _ := resignalRig(t, true)
	src.set(alertItem(t, "ask-1", "a")) // ask-2 resolved before the switch's cycle
	p.Resignal([]string{"ask-1", "ask-2"})
	r.cycle(p, KindAskAlert)
	if got := r.signalled("ask-1", "ask-2"); !got["ask-1"] || got["ask-2"] {
		t.Fatalf("signals %v, want ask-1 only", got)
	}
	r.advance(CloudKitSpacing)
	before := r.signalCount()
	r.cycle(p, KindAskAlert)
	if r.signalCount() != before {
		t.Fatal("the resignal was written twice")
	}
	p.mu.Lock()
	left := len(p.resignal)
	p.mu.Unlock()
	if left != 0 {
		t.Fatalf("%d resignal keys left after the cycle", left)
	}
}

// TestResignalWritesNothingWhenOwnerIsBack: the owner back at the Mac at the
// switch: no record, no signal.
func TestResignalWritesNothingWhenOwnerIsBack(t *testing.T) {
	r, p, _, _ := resignalRig(t, false)
	p.Resignal([]string{"ask-1", "ask-2"})
	if rep := r.cycle(p, KindAskAlert); rep.Saved != 0 {
		t.Fatalf("saved %d records with the owner back", rep.Saved)
	}
	if n := r.signalCount(); n != 0 {
		t.Fatalf("%d signals with the owner back", n)
	}
}

// TestResignalSkipsAlertsEveryPhoneAlreadyHad: ask-1 received by both phones
// (one accepted, one expired in_flight) gets no signal; ask-2 accepted by one
// of the two gets one, and its accepted row stays.
func TestResignalSkipsAlertsEveryPhoneAlreadyHad(t *testing.T) {
	r, p, _, phones := resignalRig(t, true)
	a, b := phones[0].id.String(), phones[1].id.String()
	settle(t, r.st, "ask-1", a, state.AlertAccepted, "")
	settle(t, r.st, "ask-1", b, state.AlertExpired, state.ReasonInFlight)
	settle(t, r.st, "ask-2", a, state.AlertAccepted, "")
	p.Resignal([]string{"ask-1", "ask-2"})
	r.cycle(p, KindAskAlert)
	if got := r.signalled("ask-1", "ask-2"); got["ask-1"] || !got["ask-2"] {
		t.Fatalf("signals %v, want ask-2 only", got)
	}
	recv, err := r.st.ReceivedAlertPushes([]string{"ask-2"})
	if err != nil || !recv["ask-2"][a] {
		t.Fatalf("the accepted row of ask-2 is gone: %v, %v", recv, err)
	}
	if began, err := r.st.BeginAlertPush("ask-2", a, time.Now()); err != nil || began {
		t.Fatalf("ask-2 could be pushed to the phone that had it again: %v, %v", began, err)
	}
}
