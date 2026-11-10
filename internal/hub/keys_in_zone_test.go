package hub

import (
	"context"
	"database/sql"
	"encoding/json"
	"strings"
	"sync"
	"testing"

	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/link"
	"watchtower/internal/hub/secure"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/wire"
)

// The runtime's KeysInZone (relay client Phase 5): on the relay, a phone's
// data-zone keybox carries the epoch keys only while it is not lapsed and
// reads the zone, or while the reader list is still unknown.

// zoneReadersRelay is the relay memfake with the reader list the relay last
// accepted (nil before one).
type zoneReadersRelay struct {
	*memfake.Fake
	mu      sync.Mutex
	readers []string
}

func (z *zoneReadersRelay) Readers() []string {
	z.mu.Lock()
	defer z.mu.Unlock()
	if z.readers == nil {
		return nil
	}
	return append([]string{}, z.readers...)
}

func (z *zoneReadersRelay) setReaders(ids ...string) {
	z.mu.Lock()
	defer z.mu.Unlock()
	z.readers = append([]string{}, ids...)
}

// zoneRig is relayKeysRig with a link center wired to the runtime's
// keysInZone over a relay that keeps a reader list.
type zoneRig struct {
	*relayKeysRig
	rel    *zoneReadersRelay
	center *link.Center
}

func newZoneRig(t *testing.T, kind string) *zoneRig {
	t.Helper()
	r := &zoneRig{relayKeysRig: newRelayKeysRig(t, kind)}
	r.rel = &zoneReadersRelay{Fake: r.tr}
	h := &hubRuntime{sup: &supervisor{o: Options{}}, st: r.st, kr: r.kr, tr: r.rel}
	r.center = link.NewCenter(link.Config{Store: r.st, Keys: r.kr, Opener: secure.NewOpener(r.kr, r.kr),
		Clock: r.clock, KeysInZone: h.keysInZone})
	return r
}

// zoneKeys is ph's keybox keys as the device_grant slice publishes them (one
// publisher cycle's read of the grant source).
func (r *zoneRig) zoneKeys(ph *hubtest.Phone) *wire.KeyboxKeys {
	r.t.Helper()
	items, err := hubslices.GrantSource(r.center).Items(context.Background())
	if err != nil {
		r.t.Fatal(err)
	}
	for _, it := range items {
		if !strings.EqualFold(it.ID, ph.ID().String()) {
			continue
		}
		var kb wire.Keybox
		if err := json.Unmarshal(it.Payload, &kb); err != nil {
			r.t.Fatal(err)
		}
		return kb.Keys
	}
	r.t.Fatalf("no keybox for %s", ph.ID())
	return nil
}

func (r *zoneRig) lapse(ph *hubtest.Phone) {
	r.t.Helper()
	if err := r.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		_, err := state.LapseRelay(tx, ph.ID().String(), r.clock())
		return err
	}); err != nil {
		r.t.Fatal(err)
	}
}

// A free phone on the relay: the reader list the relay accepted leaves it out,
// so its zone keybox has no keys; the paying reader's has them.
func TestFreePhoneOnRelayIsNoReaderSoNoKeysInZone(t *testing.T) {
	r := newZoneRig(t, "relay")
	paying, free := r.phone(), r.phone()
	r.rel.setReaders(paying.RelayDeviceID())
	if r.zoneKeys(paying) == nil {
		t.Fatal("the reader's keybox has no keys")
	}
	if k := r.zoneKeys(free); k != nil {
		t.Fatalf("the free phone's keybox has keys: %+v", k)
	}
}

// After a start the reader list is unknown until the first set_hub_readers
// the relay accepts: availability first, every linked phone keeps its keys.
// Once the list is known, a phone it leaves out has none.
func TestReaderListUnknownKeepsKeys(t *testing.T) {
	r := newZoneRig(t, "relay")
	ph := r.phone()
	if k := r.zoneKeys(ph); k == nil {
		t.Fatal("an unknown reader list took the keys away")
	}
	r.rel.setReaders()
	if k := r.zoneKeys(ph); k != nil {
		t.Fatalf("an empty known list kept the keys: %+v", k)
	}
}

// A phone that starts paying is added to the readers by the next readers
// sync; the next publisher cycle's keybox carries its keys.
func TestPayingPhoneBecomesReaderGetsKeysNextCycle(t *testing.T) {
	r := newZoneRig(t, "relay")
	a, b := r.phone(), r.phone()
	r.rel.setReaders(a.RelayDeviceID())
	if r.zoneKeys(b) != nil {
		t.Fatal("not a reader yet, but keys")
	}
	r.rel.setReaders(a.RelayDeviceID(), b.RelayDeviceID())
	got := r.zoneKeys(b)
	want, err := r.kr.KeyboxKeysFor(b.ID())
	if err != nil {
		t.Fatal(err)
	}
	if got == nil || got.Epoch != want.Epoch || got.DataKey != want.DataKey {
		t.Fatalf("a new reader's keybox %+v", got)
	}
}

// A lapsed phone is no reader, even while the relay's list still names it.
func TestLapsedPhoneOnRelayHasNoKeysInZone(t *testing.T) {
	r := newZoneRig(t, "relay")
	ph := r.phone()
	r.rel.setReaders(ph.RelayDeviceID())
	r.lapse(ph)
	if k := r.zoneKeys(ph); k != nil {
		t.Fatalf("a lapsed phone's keybox has keys: %+v", k)
	}
}

// A hub on iCloud keeps every keybox as before Phase 5: keys for every linked
// phone, lapsed, free or out of the reader list alike.
func TestCloudKitHubKeyboxesAreAsToday(t *testing.T) {
	r := newZoneRig(t, "cloudkit")
	free, lapsed := r.phone(), r.phone()
	r.rel.setReaders()
	r.lapse(lapsed)
	for _, ph := range []*hubtest.Phone{free, lapsed} {
		got := r.zoneKeys(ph)
		want, err := r.kr.KeyboxKeysFor(ph.ID())
		if err != nil {
			t.Fatal(err)
		}
		a, _ := json.Marshal(got)
		b, _ := json.Marshal(want)
		if got == nil || string(a) != string(b) {
			t.Fatalf("keybox %s, want %s", a, b)
		}
	}
}

// A headless hub decides by its own transport (the keyring's relay rule), not
// by a hub_meta.transport it never writes.
func TestHeadlessRelayHubDecidesByItsTransport(t *testing.T) {
	r := newZoneRig(t, "cloudkit")
	r.kr.SetRelayRule(func(*sql.Tx) (bool, error) { return true, nil })
	ph := r.phone()
	r.rel.setReaders()
	if k := r.zoneKeys(ph); k != nil {
		t.Fatalf("a headless relay hub put keys in the zone for a non-reader: %+v", k)
	}
}

// A sidecar that cannot be read keeps the keys in the zone (as before Phase
// 5), logged by class: a read failure never takes a reader's keys away.
func TestKeysInZoneUnreadableKeepsKeys(t *testing.T) {
	r := newZoneRig(t, "relay")
	ph := r.phone()
	r.rel.setReaders()
	h := &hubRuntime{sup: &supervisor{o: Options{}}, st: r.st, kr: r.kr, tr: r.rel}
	if h.keysInZone(ph.ID().String()) {
		t.Fatal("a non-reader kept its keys while the sidecar reads")
	}
	if err := r.st.Close(); err != nil {
		t.Fatal(err)
	}
	if !h.keysInZone(ph.ID().String()) {
		t.Fatal("an unreadable sidecar took the keys away")
	}
}
