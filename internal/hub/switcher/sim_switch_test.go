package switcher_test

import (
	"slices"
	"testing"
	"time"

	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/secure"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// The relay sim's switch scenarios (relay repo sim/README.md rules 8–13) on
// real envelopes, over the relay memfake and CloudKit in both fakes.

var dataZone = transport.DataZone(hubRelayID)

// marker reads the transport marker of store's data zone as ph (with the
// keys it holds), leaving the phone where it was.
func (w *world) marker(ph *hubtest.Phone, store hubtest.Records, mailbox string) (wire.Control, bool) {
	w.t.Helper()
	ph.Use(store, mailbox)
	c, ok, err := ph.ReadMarker(dataZone)
	if err != nil {
		w.t.Fatalf("reading the marker: %v", err)
	}
	return c, ok
}

// lastDataChange is the wire name of the newest change in store's data zone.
func (w *world) lastDataChange(store hubtest.Records) string {
	w.t.Helper()
	b, err := store.Changes(w.ctx, dataZone, 0)
	if err != nil {
		w.t.Fatal(err)
	}
	if len(b.Changed) == 0 {
		return ""
	}
	return b.Changed[len(b.Changed)-1].Name
}

func (w *world) publish() {
	w.t.Helper()
	w.advance(3 * time.Second) // past either transport's spacing
	if _, err := w.pub.Cycle(w.ctx, []hubslices.Kind{hubslices.KindDeviceGrant}); err != nil {
		w.t.Fatalf("publish: %v", err)
	}
}

// Contract point 6a, both directions: on every accepted switch the hub
// writes into the transport it leaves, sealed in the old epoch, the
// transport_switched for every phone and the marker in its data zone, and
// publishes nothing there afterwards; the new transport gets the full
// republish.
func TestSwitchNoticeWrittenIntoTheTransportBeingLeft(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, b := w.addPhone(true), w.addPhone(true)
		w.publish() // the keyboxes are on CloudKit
		e := w.epoch()

		// CloudKit → relay. b never follows (it only reads where it was).
		w.ask(a, wire.TransportRelay)
		w.settle(a, b)
		w.wantActive(transport.KindRelay)
		w.publish() // lands on the relay only
		for _, ph := range []*hubtest.Phone{a, b} {
			got := switched(ph)
			if len(got) != 1 || *got[0].Epoch != e+1 || *got[0].Target != wire.TransportRelay {
				t.Fatalf("CloudKit notices %+v", got)
			}
			if ep := switchedEpochs(ph); !slices.Equal(ep, []uint32{e}) {
				t.Fatalf("notice sealed in epoch %v, want the old %d", ep, e)
			}
		}
		// b holds only the old keys and still opens the CloudKit marker.
		if b.HoldsEpoch(e + 1) {
			t.Fatal("b got the new keys without following")
		}
		m, ok := w.marker(b, w.ckStore, transport.SharedMailboxZone(hubRelayID))
		if !ok || *m.Target != wire.TransportRelay || *m.Epoch != e+1 || m.Keybox != nil || m.DeviceID != nil {
			t.Fatalf("CloudKit marker %+v, %v", m, ok)
		}
		if last, name := w.lastDataChange(w.ckStore), markerName(t, w); last != name {
			t.Fatalf("CloudKit's data zone changed after the marker (last %q)", last)
		}
		// The relay got the full republish in the new epoch and its own
		// marker (contract point 4).
		w.onRelay(a)
		if _, _, err := a.ReadKeybox(dataZone); err != nil {
			t.Fatal(err)
		}
		if err := a.Follow(switched(a)[0]); err != nil {
			t.Fatal(err)
		}
		if m, ok, err := a.ReadMarker(dataZone); err != nil || !ok || *m.Epoch != e+1 {
			t.Fatalf("relay marker %+v %v %v", m, ok, err)
		}
		w.settle(a)

		// relay → CloudKit: the notice in every relay mailbox, the marker in
		// data/<hub>, both sealed in epoch e+1.
		w.advance(time.Minute)
		w.ask(a, wire.TransportCloudKit)
		w.onRelay(b) // b reads the relay mailbox it has there, keys of e only
		w.settle(a, b)
		w.wantActive(transport.KindCloudKit)
		w.publish()
		// Each phone's relay mailbox also held its copy of the first notice
		// (same id as the CloudKit one); the newest is the way back.
		for _, ph := range []*hubtest.Phone{a, b} {
			got, eps := switched(ph), switchedEpochs(ph)
			last := got[len(got)-1]
			if *last.Epoch != e+2 || *last.Target != wire.TransportCloudKit || eps[len(eps)-1] != e+1 {
				t.Fatalf("relay notices %+v (sealed in %v)", got, eps)
			}
			if len(got) != 3 || got[0].ID != got[1].ID {
				t.Fatalf("want the CloudKit and relay copies of the first notice, then the second: %+v", got)
			}
		}
		m, ok = w.marker(a, w.relay, "")
		if !ok || *m.Target != wire.TransportCloudKit || *m.Epoch != e+2 {
			t.Fatalf("relay marker %+v %v", m, ok)
		}
		if last := w.lastDataChange(w.relay); last != markerName(t, w) {
			t.Fatalf("the relay's data zone changed after the marker (last %q)", last)
		}
	})
}

// markerName is the marker's wire name.
func markerName(t *testing.T, w *world) string {
	t.Helper()
	name, err := secure.NewSealer(w.keys).WireName(secure.ZoneData, wire.MarkerPlain)
	if err != nil {
		t.Fatal(err)
	}
	return name
}

// A phone that never sent action_seq (today's path) gets the control and
// the marker too.
func TestALegacyPathPhoneGetsTheNoticeToo(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, legacy := w.addPhone(true), w.addPhone(false)
		if _, err := legacy.SendLegacy(legacy.NewAction("test_noop")); err != nil {
			t.Fatal(err)
		}
		w.settle(legacy)
		if d, _, _ := w.st.Device(legacy.ID().String()); d.Ordered {
			t.Fatal("the legacy phone runs ordered")
		}
		w.ask(a, wire.TransportRelay)
		w.settle(a, legacy)
		if len(switched(legacy)) != 1 {
			t.Fatalf("the legacy phone read %+v", legacy.Controls)
		}
		if _, ok := w.marker(legacy, w.ckStore, transport.SharedMailboxZone(hubRelayID)); !ok {
			t.Fatal("no marker for the legacy phone")
		}
		// Not ordered: no hub_on_relay at the switch (rule 11.4 is for
		// ordered phones).
		if n := count(legacy, wire.ControlHubOnRelay); n != 0 {
			t.Fatalf("%d hub_on_relay", n)
		}
	})
}

// The marker left on CloudKit outlives the 7-day hygiene.
func TestTheOldTransportMarkerIsNeverSwept(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a := w.addPhone(true)
		w.ask(a, wire.TransportRelay)
		w.settle(a)
		w.wantActive(transport.KindRelay)
		w.advance(actions.ActionMaxAge + 48*time.Hour)
		rep, err := w.sw.Processor(transport.KindCloudKit).Hygiene(w.ctx)
		if err != nil || !rep.Ran {
			t.Fatalf("hygiene %+v %v", rep, err)
		}
		if _, ok := w.marker(a, w.ckStore, transport.SharedMailboxZone(hubRelayID)); !ok {
			t.Fatal("the CloudKit marker was swept")
		}
	})
}

// Review Focus 4: the relay is down; a phone asks on CloudKit to switch
// back. The switch is accepted at once without waiting on the relay, the
// phone's unechoed actions resend on CloudKit and apply once, and when the
// relay comes back what was stuck there applies nothing twice.
func TestSwitchToCloudKitDuringRelayOutage(t *testing.T) {
	eachFlavourTimed(t, func(t *testing.T, w *world) {
		a := w.addPhone(true)
		w.moveTo(a, wire.TransportRelay)
		one := w.act(a)
		w.settle(a)
		w.wantCalls(call(a, one))

		w.relay.SetAvailable(false)
		stuck, err := a.Queue(a.NewAction("test_noop")) // never reaches the relay
		if err != nil {
			t.Fatal(err)
		}
		if err := a.Send(stuck); err == nil {
			t.Fatal("the relay took a write while down")
		}
		w.onCloudKit(a) // the phone polls its CloudKit mailbox (> 60 s outage)
		w.ask(a, wire.TransportCloudKit)
		start := time.Now()
		w.settle(a)
		// The bubble's clock: no wait at all. The bridgefake flavour runs on
		// the real clock, where an elapsed bound would only measure the
		// machine's load; the memfake flavour holds the exact zero.
		if d := time.Since(start); w.virtual && d != 0 {
			t.Fatalf("the switch waited on the unreachable relay (%s)", d)
		}
		w.wantActive(transport.KindCloudKit)
		c, ok := a.LastSwitch()
		if !ok || *c.Target != wire.TransportCloudKit {
			t.Fatalf("CloudKit notice %+v", a.Controls)
		}
		w.follow(a)
		w.settle(a)
		w.wantCalls(call(a, one), call(a, stuck))

		// The relay comes back: its owed notice and marker land; the stale
		// copies there are left and never applied again.
		w.relay.SetAvailable(true)
		w.onRelay(a)
		for _, s := range []uint64{one, stuck} { // late copies reach the relay
			if err := a.WriteCopy(s); err != nil {
				t.Fatal(err)
			}
		}
		w.onCloudKit(a)
		w.settle(a)
		w.wantCalls(call(a, one), call(a, stuck))
		m, ok := w.marker(a, w.relay, "")
		if !ok || *m.Target != wire.TransportCloudKit {
			t.Fatalf("the relay marker %+v %v", m, ok)
		}
		// The owed relay notice landed too, sealed in the epoch left.
		w.onRelay(a)
		if _, err := a.Sync(); err != nil {
			t.Fatal(err)
		}
		if c, _ := a.LastSwitch(); *c.Target != wire.TransportCloudKit {
			t.Fatalf("relay notice %+v", c)
		}
	})
}

// Rules 11–12: phone b did not ask; it reads the notice and follows; both
// phones' actions apply on the new transport, none twice.
func TestSecondPhoneFollowsSwitch(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, b := w.addPhone(true), w.addPhone(true)
		pre := w.act(b)
		w.settle(a, b)
		w.ask(a, wire.TransportRelay)
		w.settle(a, b)
		w.wantActive(transport.KindRelay)
		// b's next action was sealed before it read the notice and sits on
		// CloudKit: left there, then resent with the same bytes on the relay.
		late, err := b.Queue(b.NewAction("test_noop"))
		if err != nil {
			t.Fatal(err)
		}
		if err := b.Send(late); err != nil {
			t.Fatal(err)
		}
		w.settle(a, b)
		w.wantCalls(call(b, pre))
		w.follow(a)
		w.follow(b)
		w.settle(a, b)
		x, y := w.act(a), w.act(b)
		w.settle(a, b)
		// Order holds per phone; the two phones' mailboxes are read in turn.
		got := w.callLog()
		want := []string{call(b, pre), call(b, late), call(a, x), call(b, y)}
		if !slices.Equal(slices.Sorted(slices.Values(got)), slices.Sorted(slices.Values(want))) ||
			slices.Index(got, call(b, late)) > slices.Index(got, call(b, y)) {
			t.Fatalf("handler calls %v, want each of %v once, in order per phone", got, want)
		}
		for _, ph := range []*hubtest.Phone{a, b} {
			if len(ph.Outbox()) != 0 {
				t.Fatalf("outbox %v", ph.Outbox())
			}
			if d, _, _ := w.st.Device(ph.ID().String()); d.AckedEpoch != w.epoch() {
				t.Fatalf("acked %d, want %d", d.AckedEpoch, w.epoch())
			}
		}
	})
}

// Rules 11.4 and 12a: toward the relay a free (not paying) ordered phone
// gets hub_on_relay on CloudKit, and again for each new version of an
// action it writes there; the action is left and never applied.
func TestHubOnRelayTellsFreePhone(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, free := w.addPhone(true), w.addPhone(false)
		w.act(free)
		w.settle(a, free) // free is ordered now
		w.ask(a, wire.TransportRelay)
		w.settle(a, free)
		w.wantActive(transport.KindRelay)
		if n := count(free, wire.ControlHubOnRelay); n != 1 {
			t.Fatalf("%d hub_on_relay at the switch", n)
		}
		seq := w.act(free)
		w.settle(a, free)
		if n := count(free, wire.ControlHubOnRelay); n != 2 {
			t.Fatalf("%d hub_on_relay after an action on CloudKit", n)
		}
		w.settle(a, free) // the same record version: no new answer
		if n := count(free, wire.ControlHubOnRelay); n != 2 {
			t.Fatalf("%d hub_on_relay for one record version", n)
		}
		if slices.Contains(w.callLog(), call(free, seq)) {
			t.Fatal("an action on the standby transport was applied")
		}
		if name, _ := free.Sealed(seq); !slices.Contains(records(t, free), name) {
			t.Fatal("the action was not left to the phone")
		}
	})
}

func records(t *testing.T, ph *hubtest.Phone) []string {
	t.Helper()
	names, err := ph.Records()
	if err != nil {
		t.Fatal(err)
	}
	return names
}

// Rule 12a: a phone that was away comes back to the old transport, reads
// the marker with the keys it holds, follows it and finds its keybox in the
// new transport's mailbox.
func TestMarkerLeadsReturningPhone(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, away := w.addPhone(true), w.addPhone(true)
		e := w.epoch()
		w.moveTo(a, wire.TransportRelay) // away never syncs meanwhile
		m, ok := w.marker(away, w.ckStore, transport.SharedMailboxZone(hubRelayID))
		if !ok || *m.Target != wire.TransportRelay || *m.Epoch != e+1 {
			t.Fatalf("marker %+v %v", m, ok)
		}
		w.onRelay(away)
		if _, err := away.Sync(); err != nil {
			t.Fatal(err)
		}
		w.follow(away)
		seq := w.act(away)
		w.settle(a, away)
		if !slices.Contains(w.callLog(), call(away, seq)) {
			t.Fatalf("the returning phone's action was not applied: %v", w.callLog())
		}
	})
}

// Rule 12a: after a switch, a phone that has not acked the new epoch and
// writes on the old transport gets transport_switched again (once per
// record version); the record is left to it.
func TestStaleActionGetsSwitchAgain(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, lagging := w.addPhone(true), w.addPhone(true)
		w.moveTo(a, wire.TransportRelay)
		if _, err := lagging.Sync(); err != nil { // reads the notice, does not follow
			t.Fatal(err)
		}
		before := len(switched(lagging))
		seq := w.act(lagging) // still on CloudKit
		w.settle(a, lagging)
		got := switched(lagging)
		if len(got) != before+1 {
			t.Fatalf("notices %d, want %d", len(got), before+1)
		}
		again := got[len(got)-1]
		if *again.Target != wire.TransportRelay || *again.Epoch != w.epoch() {
			t.Fatalf("notice %+v", again)
		}
		if _, err := lagging.OpenSwitchKeybox(again); err != nil {
			t.Fatal(err)
		}
		w.settle(a, lagging)
		if len(switched(lagging)) != before+1 {
			t.Fatal("answered twice for one record version")
		}
		if name, _ := lagging.Sealed(seq); !slices.Contains(records(t, lagging), name) {
			t.Fatal("the action was not left to the phone")
		}
		w.follow(lagging)
		w.settle(a, lagging)
		if !slices.Contains(w.callLog(), call(lagging, seq)) {
			t.Fatal("the resent action was not applied on the relay")
		}
	})
}
