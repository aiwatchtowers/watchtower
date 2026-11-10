package switcher_test

import (
	"strings"
	"testing"

	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/wire"
)

// keepOut makes the runtime's KeysInZone say no for ph: its data-zone keybox
// carries no keys (a free phone on the relay).
func (w *world) keepOut(ph *hubtest.Phone) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.zoneOut == nil {
		w.zoneOut = map[string]bool{}
	}
	w.zoneOut[strings.ToUpper(ph.ID().String())] = true
}

// zoneKeys is ph's keybox in the data zone (the device_grant slice).
func (w *world) zoneKeys(ph *hubtest.Phone) *wire.KeyboxKeys {
	w.t.Helper()
	boxes, err := w.center.Keyboxes()
	if err != nil {
		w.t.Fatal(err)
	}
	for _, kb := range boxes {
		if strings.EqualFold(kb.Grant.DeviceID, ph.ID().String()) {
			return kb.Keys
		}
	}
	w.t.Fatalf("no keybox for %s", ph.ID())
	return nil
}

// Mixed fleets: the hub on the relay with a paying and a free phone; the free
// phone's data-zone keybox has no keys. The switch to iCloud reads
// KeyboxesAll, so its transport_switched hands the free phone the new epoch's
// keys.
func TestSwitchToCloudKitGivesAFreePhoneItsKeys(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, free := w.addPhone(true), w.addPhone(false)
		w.moveTo(a, wire.TransportRelay)
		w.keepOut(free)
		if k := w.zoneKeys(free); k != nil {
			t.Fatalf("the free phone's zone keybox on the relay has keys: %+v", k)
		}
		if k := w.zoneKeys(a); k == nil {
			t.Fatal("the paying phone's zone keybox has no keys")
		}
		if _, err := free.Sync(); err != nil { // the relay's notice (a v1 limit, ask #1077)
			t.Fatal(err)
		}
		before := len(switched(free))
		w.ask(a, wire.TransportCloudKit)
		w.settle(a, free)
		w.wantActive(transport.KindCloudKit)
		got := switched(free)
		if len(got) != before+1 {
			t.Fatalf("the free phone read %d notices, want %d", len(got), before+1)
		}
		c := got[len(got)-1]
		if *c.Target != wire.TransportCloudKit || *c.Epoch != w.epoch() {
			t.Fatalf("notice %+v", c)
		}
		kb, err := free.OpenSwitchKeybox(c)
		if err != nil {
			t.Fatal(err)
		}
		if kb.Keys == nil || kb.Keys.Epoch != w.epoch() || kb.Keys.RelayKX != nil {
			t.Fatalf("the free phone's switch keybox %+v", kb.Keys)
		}
	})
}

// Rule 12a's answer to a stale action is a transport_switched too: with the
// hub on the relay, a lagging phone whose data-zone keybox has no keys still
// gets its keys in the notice (KeyboxesAll).
func TestStaleActionNoticeUsesKeyboxesAll(t *testing.T) {
	eachFlavour(t, func(t *testing.T, w *world) {
		a, lagging := w.addPhone(true), w.addPhone(true)
		w.moveTo(a, wire.TransportRelay)
		if _, err := lagging.Sync(); err != nil { // reads the notice, does not follow
			t.Fatal(err)
		}
		w.keepOut(lagging)
		before := len(switched(lagging))
		w.act(lagging) // still on CloudKit
		w.settle(a, lagging)
		got := switched(lagging)
		if len(got) != before+1 {
			t.Fatalf("notices %d, want %d", len(got), before+1)
		}
		kb, err := lagging.OpenSwitchKeybox(got[len(got)-1])
		if err != nil {
			t.Fatal(err)
		}
		if kb.Keys == nil || kb.Keys.Epoch != w.epoch() {
			t.Fatalf("the stale answer's keybox %+v", kb.Keys)
		}
		if k := w.zoneKeys(lagging); k != nil {
			t.Fatalf("the zone keybox has keys: %+v", k)
		}
	})
}
