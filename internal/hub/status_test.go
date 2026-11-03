package hub

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/hub/alerts"
	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/transport/relay/relayv1"
	"watchtower/internal/logcanary"
	"watchtower/internal/policy/policytest"
)

// healthRig is a relayHealth over a fresh sidecar with a fake clock and two
// linked phones on the relay.
type healthRig struct {
	st     *state.Store
	dir    string
	mu     sync.Mutex
	now    time.Time
	r      *relayHealth
	hub    string
	phones []state.Device
}

func newHealthRig(t *testing.T) *healthRig {
	t.Helper()
	g := &healthRig{dir: t.TempDir(), now: time.Unix(1_800_000_000, 0).UTC(), hub: "hub-relay-id"}
	g.st = g.open(t)
	for range 2 {
		p, err := hubtest.New(hubtest.Config{})
		if err != nil {
			t.Fatal(err)
		}
		d := p.Device()
		if err := g.st.WithTx(context.Background(), func(tx *sql.Tx) error { return state.LinkDevice(tx, d) }); err != nil {
			t.Fatal(err)
		}
		g.phones = append(g.phones, d)
	}
	g.r = g.health()
	return g
}

func (g *healthRig) open(t *testing.T) *state.Store {
	t.Helper()
	st, err := state.Open(g.dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	return st
}

func (g *healthRig) clock() time.Time {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.now
}

func (g *healthRig) advance(d time.Duration) {
	g.mu.Lock()
	g.now = g.now.Add(d)
	g.mu.Unlock()
}

// health is a new relayHealth over the rig's sidecar (a hub start).
func (g *healthRig) health() *relayHealth {
	return newRelayHealth(g.st, g.clock, g.hub, memfake.New(transport.KindRelay, nil))
}

func (g *healthRig) mailbox(i int) string {
	return transport.MailboxZone(g.hub, g.phones[i].RelayDeviceID)
}

func (g *healthRig) data() string { return transport.DataZone(g.hub) }

func (g *healthRig) facts(connected bool) (RelayHealth, []string) {
	return g.r.facts(connected, g.phones, true)
}

// persisted is the hub_meta mailbox_full_phones list.
func (g *healthRig) persisted(t *testing.T) []string {
	t.Helper()
	raw, ok, err := g.st.Meta(state.MetaMailboxFullPhones)
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		return nil
	}
	var ids []string
	if err := json.Unmarshal([]byte(raw), &ids); err != nil {
		t.Fatalf("hub_meta %s = %q: %v", state.MetaMailboxFullPhones, raw, err)
	}
	return ids
}

func TestRelayUnavailableAfter60s(t *testing.T) {
	g := newHealthRig(t)
	t0 := g.clock()
	if h, _ := g.facts(false); h.State != RelayConnecting || h.Since != rfc3339(t0) {
		t.Fatalf("at start: %+v, want connecting since the start", h)
	}
	g.advance(59 * time.Second)
	if h, _ := g.facts(false); h.State != RelayConnecting {
		t.Fatalf("at 59 s: %+v, want connecting", h)
	}
	g.advance(time.Second)
	if h, _ := g.facts(false); h.State != RelayUnavailable || h.Since != rfc3339(t0.Add(60*time.Second)) {
		t.Fatalf("at 60 s: %+v, want unavailable since 60 s", h)
	}
	g.advance(5 * time.Second)
	connected, _ := g.facts(true)
	if connected.State != RelayConnected || connected.Since != rfc3339(g.clock()) {
		t.Fatalf("reconnected: %+v", connected)
	}
	g.advance(10 * time.Second)
	if h, _ := g.facts(false); h.State != RelayConnecting || h.Since != rfc3339(g.clock()) {
		t.Fatalf("dropped again: %+v, want connecting from now", h)
	}

	// The status that carries the reconnect is a status watch event.
	w := &pairListener{queue: make(chan ControlAnswer, 4)}
	s := &supervisor{o: Options{Dir: t.TempDir()}, pairs: map[*pairListener]bool{}, watches: map[*pairListener]bool{w: true}}
	down := RelayHealth{State: RelayUnavailable, Since: rfc3339(t0.Add(60 * time.Second))}
	s.setStatus(Status{State: StateRunning, Relay: &down})
	s.setStatus(Status{State: StateRunning, Relay: &RelayHealth{State: RelayUnavailable, Since: down.Since}}) // the same: no event
	s.setStatus(Status{State: StateRunning, Relay: &connected})
	for i := range 2 {
		select {
		case ev := <-w.queue:
			if ev.Event != EventStatus {
				t.Fatalf("event %d = %+v", i, ev)
			}
		case <-time.After(time.Second):
			t.Fatalf("status event %d missing", i)
		}
	}
	select {
	case ev := <-w.queue:
		t.Fatalf("an unchanged status was an event: %+v", ev)
	default:
	}
	f, err := readStatusFile(s.o.Dir)
	if err != nil || f.Relay == nil || f.Relay.State != RelayConnected {
		t.Fatalf("status file relay = %+v, %v", f.Relay, err)
	}
}

func TestQuotaClassSetAndClearedBySave(t *testing.T) {
	g := newHealthRig(t)
	g.r.saved(g.data(), fmt.Errorf("relay: save: %w", transport.ErrHubQuota))
	if h, _ := g.facts(true); !h.QuotaHub || h.LastSavedAt != "" {
		t.Fatalf("after a refused save: %+v", h)
	}
	g.r.saved(g.data(), transport.ErrUnavailable)
	g.r.saved(g.mailbox(0), nil)
	if h, _ := g.facts(true); !h.QuotaHub {
		t.Fatal("cleared by another error or a mailbox write")
	}
	g.advance(time.Second)
	g.r.saved(g.data(), nil)
	if h, _ := g.facts(true); h.QuotaHub || h.LastSavedAt != rfc3339(g.clock().Truncate(time.Minute)) {
		t.Fatalf("after a successful save: %+v", h)
	}
}

func TestMailboxFullIsPerPhoneAndClearedOnlyByThatPhonesWrite(t *testing.T) {
	g := newHealthRig(t)
	a, b := g.phones[0].ID, g.phones[1].ID
	g.r.saved(g.mailbox(0), fmt.Errorf("relay: save: %w", transport.ErrMailboxQuota))
	g.r.saved(g.mailbox(1), transport.ErrMailboxQuota)
	want := []string{a, b}
	slices.Sort(want)
	if _, full := g.facts(true); !slices.Equal(full, want) {
		t.Fatalf("full = %v, want %v", full, want)
	}
	g.r.saved(g.data(), nil)
	g.r.saved(g.mailbox(0), transport.ErrUnavailable)
	if _, full := g.facts(true); !slices.Equal(full, want) {
		t.Fatalf("a data-zone save or another error cleared a flag: %v", full)
	}
	g.r.saved(g.mailbox(0), nil)
	if _, full := g.facts(true); !slices.Equal(full, []string{b}) {
		t.Fatalf("after A's write: %v, want only B", full)
	}
	if got := g.persisted(t); !slices.Equal(got, []string{b}) {
		t.Fatalf("hub_meta = %v, want only B", got)
	}
}

func TestUnlinkRemovesThePhoneFromMailboxFull(t *testing.T) {
	g := newHealthRig(t)
	g.r.saved(g.mailbox(0), transport.ErrMailboxQuota)
	g.phones = g.phones[1:] // phone A unlinked
	if _, full := g.facts(true); len(full) != 0 {
		t.Fatalf("full = %v after the unlink", full)
	}
	if got := g.persisted(t); len(got) != 0 {
		t.Fatalf("hub_meta = %v after the unlink", got)
	}
}

// TestMailboxFullSurvivesAFailedDeviceRead: a failed read of the linked
// phones is not an unlink — the flags stay, in memory and in hub_meta, and
// the paying list stays unknown; the next good read drops an unlinked one.
func TestMailboxFullSurvivesAFailedDeviceRead(t *testing.T) {
	g := newHealthRig(t)
	a, b := g.phones[0].ID, g.phones[1].ID
	g.r.saved(g.mailbox(0), transport.ErrMailboxQuota)
	g.r.saved(g.mailbox(1), transport.ErrMailboxQuota)
	want := []string{a, b}
	slices.Sort(want)
	if _, full := g.r.facts(true, nil, false); !slices.Equal(full, want) {
		t.Fatalf("after a failed device read: %v, want %v", full, want)
	}
	if got := g.persisted(t); !slices.Equal(got, want) {
		t.Fatalf("hub_meta after a failed device read = %v, want %v", got, want)
	}
	if _, full := g.r.facts(true, g.phones[1:], true); !slices.Equal(full, []string{b}) {
		t.Fatalf("after a good read without A: %v, want only B", full)
	}
	if got := g.persisted(t); !slices.Equal(got, []string{b}) {
		t.Fatalf("hub_meta = %v, want only B", got)
	}
}

func TestMailboxFullSurvivesARestart(t *testing.T) {
	g := newHealthRig(t)
	g.r.saved(g.mailbox(1), transport.ErrMailboxQuota)
	g.r = g.health() // the hub starts again
	if _, full := g.facts(true); !slices.Equal(full, []string{g.phones[1].ID}) {
		t.Fatalf("full after a restart = %v", full)
	}
	g.r.saved(g.mailbox(1), nil)
	if _, full := g.facts(true); len(full) != 0 {
		t.Fatalf("restored flag not cleared by the phone's write: %v", full)
	}
}

// pushLedger writes settled alert pushes in order, one second apart; an
// empty outcome leaves the row pending.
func pushLedger(t *testing.T, st *state.Store, at time.Time, rows ...[2]string) {
	t.Helper()
	for i, r := range rows {
		key, when := fmt.Sprintf("ask-%d", i), at.Add(time.Duration(i)*time.Second)
		if _, err := st.BeginAlertPush(key, "phone-a", when); err != nil {
			t.Fatal(err)
		}
		if r[0] == "" {
			continue
		}
		if _, err := st.SettleAlertPush(key, "phone-a", r[0], r[1], 1, when); err != nil {
			t.Fatal(err)
		}
	}
}

// pushOffAfter is the push-off line after a push_off answer and then rows.
func pushOffAfter(t *testing.T, rows ...[2]string) bool {
	t.Helper()
	g := newHealthRig(t)
	pushLedger(t, g.st, g.clock(), append([][2]string{{state.AlertPushOff, ""}}, rows...)...)
	off, err := g.st.PushOff(g.clock().Add(-AlertOutcomeWindow))
	if err != nil {
		t.Fatal(err)
	}
	return off
}

func TestPushOffSetByPushOff(t *testing.T) {
	if !pushOffAfter(t) {
		t.Fatal("a push_off answer did not set the line")
	}
	g := newHealthRig(t)
	if off, err := g.st.PushOff(g.clock().Add(-AlertOutcomeWindow)); err != nil || off {
		t.Fatalf("no answer yet: %v, %v", off, err)
	}
}

func TestPushOffClearedByAccepted(t *testing.T) {
	if pushOffAfter(t, [2]string{state.AlertAccepted, ""}) {
		t.Fatal("accepted did not clear the line")
	}
}

func TestPushOffClearedByNotPaying(t *testing.T) {
	if pushOffAfter(t, [2]string{state.AlertNotPaying, ""}) {
		t.Fatal("not_paying did not clear the line")
	}
}

func TestPushOffClearedByTooLarge(t *testing.T) {
	if pushOffAfter(t, [2]string{state.AlertTooLarge, ""}) {
		t.Fatal("too_large did not clear the line")
	}
}

func TestPushOffClearedByNoToken(t *testing.T) {
	if pushOffAfter(t, [2]string{state.AlertNoToken, ""}) {
		t.Fatal("no_token did not clear the line")
	}
}

func TestPushOffKeptAfterForbidden(t *testing.T) {
	// FORBIDDEN and HUB_NOT_VOUCHED both settle forbidden.
	if !pushOffAfter(t, [2]string{state.AlertForbidden, ""}) {
		t.Fatal("forbidden cleared the line")
	}
}

func TestPushOffKeptAfterFailed(t *testing.T) {
	if !pushOffAfter(t, [2]string{state.AlertFailed, ""}) {
		t.Fatal("failed cleared the line")
	}
}

// retriedPushKeepsTheLine is a retried answer (RATE_LIMITED,
// TRAFFIC_LIMIT_EXCEEDED, a relay-coded UNAVAILABLE) as the pusher leaves it
// in the ledger: the pusher settles nothing for a retry, so the row stays
// pending through every wait, and the window's end settles it
// expired/freshness. The line stands at each step.
func retriedPushKeepsTheLine(t *testing.T) {
	t.Helper()
	g := newHealthRig(t)
	pushLedger(t, g.st, g.clock(), [2]string{state.AlertPushOff, ""})
	at := g.clock().Add(time.Second)
	if _, err := g.st.BeginAlertPush("ask-retried", "phone-b", at); err != nil {
		t.Fatal(err)
	}
	since := g.clock().Add(-AlertOutcomeWindow)
	if off, err := g.st.PushOff(since); err != nil || !off {
		t.Fatalf("while the retry waits: %v, %v", off, err)
	}
	if _, err := g.st.SettleAlertPush("ask-retried", "phone-b", state.AlertExpired, state.ReasonFreshness, 3, at.Add(alerts.Freshness)); err != nil {
		t.Fatal(err)
	}
	if off, err := g.st.PushOff(since); err != nil || !off {
		t.Fatalf("after the retries expired: %v, %v", off, err)
	}
}

func TestPushOffKeptAfterRateLimited(t *testing.T) { retriedPushKeepsTheLine(t) }

func TestPushOffKeptAfterUnavailable(t *testing.T) { retriedPushKeepsTheLine(t) }

// TestPushOffClearedAcrossPhones: the line is the relay's, not a phone's —
// push_off on phone A is cleared by accepted on phone B.
func TestPushOffClearedAcrossPhones(t *testing.T) {
	g := newHealthRig(t)
	t0 := g.clock()
	for i, row := range []struct{ device, outcome string }{{"phone-a", state.AlertPushOff}, {"phone-b", state.AlertAccepted}} {
		at := t0.Add(time.Duration(i) * time.Second)
		if _, err := g.st.BeginAlertPush("ask-1", row.device, at); err != nil {
			t.Fatal(err)
		}
		if _, err := g.st.SettleAlertPush("ask-1", row.device, row.outcome, "", 1, at); err != nil {
			t.Fatal(err)
		}
	}
	if off, err := g.st.PushOff(t0.Add(-AlertOutcomeWindow)); err != nil || off {
		t.Fatalf("after accepted on another phone: %v, %v", off, err)
	}
}

func TestPushOffKeptAfterExpiredOrPending(t *testing.T) {
	for _, reason := range []string{state.ReasonFreshness, state.ReasonOwnerBack, state.ReasonRestart, state.ReasonSwitched,
		state.ReasonOverflow, state.ReasonStopped} {
		if !pushOffAfter(t, [2]string{state.AlertExpired, reason}) {
			t.Fatalf("expired/%s cleared the line", reason)
		}
	}
	if !pushOffAfter(t, [2]string{"", ""}) {
		t.Fatal("a pending push cleared the line")
	}
}

func TestPushOffKeptAfterInFlight(t *testing.T) {
	if !pushOffAfter(t, [2]string{state.AlertExpired, state.ReasonInFlight}) {
		t.Fatal("expired/in_flight cleared the line")
	}
}

func TestPushOffSurvivesARestart(t *testing.T) {
	g := newHealthRig(t)
	pushLedger(t, g.st, g.clock(), [2]string{state.AlertPushOff, ""}, [2]string{state.AlertForbidden, ""})
	if err := g.st.Close(); err != nil {
		t.Fatal(err)
	}
	st := g.open(t)
	if off, err := st.PushOff(g.clock().Add(-AlertOutcomeWindow)); err != nil || !off {
		t.Fatalf("after a restart: %v, %v", off, err)
	}
	// It goes with the 7-day window.
	if off, err := st.PushOff(g.clock().Add(time.Minute)); err != nil || off {
		t.Fatalf("past the window: %v, %v", off, err)
	}
}

func TestPayingPhonesOnlyOnRelay(t *testing.T) {
	g := newHealthRig(t)
	acct := &relayv1.AccountState{Phones: []*relayv1.SlotHolder{
		{PhoneDeviceId: g.phones[0].RelayDeviceID, Paying: true},
		{PhoneDeviceId: g.phones[1].RelayDeviceID, Paying: false},
		{PhoneDeviceId: "not-linked", Paying: true},
	}}
	// Known: the paying phone is listed (true), the other not (false).
	if got := payingPhones(transport.KindRelay, acct, true, g.phones); !slices.Equal(got, []string{g.phones[0].ID}) {
		t.Fatalf("on the relay: %v", got)
	}
	if got := payingPhones(transport.KindCloudKit, acct, true, g.phones); got == nil || len(got) != 0 {
		t.Fatalf("on CloudKit: %#v, want an empty list", got)
	}
	// Unknown (no read yet, or forgotten after HUB_NOT_VOUCHED): nil, never
	// "nobody pays".
	if got := payingPhones(transport.KindRelay, &relayv1.AccountState{}, false, g.phones); got != nil {
		t.Fatalf("unknown account state: %#v, want nil", got)
	}
	b, err := json.Marshal(Status{}.withLists())
	if err != nil || !strings.Contains(string(b), `"paying_phones":null`) {
		t.Fatalf("an unknown paying list = %s, %v; want null", b, err)
	}
}

// TestLastSavedAtChangesTheStatusOncePerMinute: two saves within one minute
// show the same last_saved_at, so the status (and the watch) does not
// change between them; a save in the next minute does.
func TestLastSavedAtChangesTheStatusOncePerMinute(t *testing.T) {
	g := newHealthRig(t)
	g.mu.Lock()
	g.now = g.now.Truncate(time.Minute).Add(5 * time.Second)
	g.mu.Unlock()
	w := &pairListener{queue: make(chan ControlAnswer, 4)}
	s := &supervisor{o: Options{Dir: t.TempDir()}, pairs: map[*pairListener]bool{}, watches: map[*pairListener]bool{w: true}}
	status := func() {
		h, full := g.facts(true)
		s.setStatus(Status{State: StateRunning, Relay: &h, MailboxFullPhones: full})
	}
	g.r.saved(g.data(), nil)
	status()
	g.advance(40 * time.Second)
	g.r.saved(g.data(), nil)
	status()
	g.advance(30 * time.Second) // the next minute
	g.r.saved(g.data(), nil)
	status()
	events := 0
	for {
		select {
		case <-w.queue:
			events++
			continue
		default:
		}
		break
	}
	if events != 2 {
		t.Fatalf("%d status events for saves at 0:05, 0:45 and 1:15, want 2", events)
	}
}

// TestStatusFileHasNoContent is the status file's canary: a running hub's
// status carries ids, classes and times, never a phone's or the hub's name.
func TestStatusFileHasNoContent(t *testing.T) {
	policytest.Set(t, nil)
	dir := shortDir(t)
	marker := logcanary.Text("phone.name")
	setMeta(t, dir, state.MetaEnabled, "1", state.MetaDisplayName, logcanary.Text("hub.name"))
	p, err := hubtest.New(hubtest.Config{})
	if err != nil {
		t.Fatal(err)
	}
	d := p.Device()
	d.Name = marker
	st, err := state.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := st.WithTx(context.Background(), func(tx *sql.Tx) error { return state.LinkDevice(tx, d) }); err != nil {
		t.Fatal(err)
	}
	_ = st.Close()
	r := newRig(t, dir)
	r.start(r.options())
	r.waitState(StateRunning, "")
	eventually(t, 10*time.Second, "the relay indicators", func() bool { return r.rec.last().Relay != nil })
	raw, err := os.ReadFile(filepath.Join(dir, statusFileName))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), logcanary.Marker) {
		t.Fatalf("the status file carries content: %s", raw)
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	for _, k := range []string{"relay", "paying_phones", "mailbox_full_phones"} {
		if _, ok := m[k]; !ok {
			t.Errorf("status file has no %q: %s", k, raw)
		}
	}
}

// TestDeadRunStatusDropsItsRuntimeFacts: a status left by a hub that died
// reads off with no relay, an unknown paying list and no mailbox flags,
// however the hub stopped.
func TestDeadRunStatusDropsItsRuntimeFacts(t *testing.T) {
	dir := t.TempDir()
	b, err := json.Marshal(statusFile{Status: Status{
		State: StateRunning, Relay: &RelayHealth{State: RelayConnected},
		PayingPhones: []string{"A"}, MailboxFullPhones: []string{"A"},
	}, PID: 0, Run: "gone"})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, statusFileName), b, 0o600); err != nil {
		t.Fatal(err)
	}
	s, err := ReadStatus(dir)
	if err != nil {
		t.Fatal(err)
	}
	if s.State != StateOff || s.Relay != nil || s.PayingPhones != nil || s.MailboxFullPhones == nil || len(s.MailboxFullPhones) != 0 {
		t.Fatalf("dead run's status = %+v", s)
	}
}
