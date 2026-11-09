package hub

import (
	"context"
	"crypto/ecdh"
	"crypto/rand"
	"database/sql"
	"errors"
	"testing"
	"time"

	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/link"
	"watchtower/internal/hub/secure"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay/relayv1"
)

// Losing and regaining reader status through the runtime (relay client
// Phase 5, Task 13): the zone keybox of a phone whose lapse waits, a readers
// sync that adds a reader, and the idle hub that nothing moves.

// The F43 window: the relay's signal with a failed account read leaves the
// lapse waiting in lapse_pending; the phone's zone keybox has no keys from
// queueLapse on, and the grant is published soon.
func TestLapsedPhoneKeyboxHasNoKeysAndIsRepublished(t *testing.T) {
	g := startG2(t, false)
	dev := g.onlyPhone()
	g.giveRelayKeys(dev)
	if k := g.zoneKeys(dev); k == nil {
		t.Fatal("no keys in the zone before the lapse")
	}
	g.fake.SetAvailable(false) // the account read fails: the lapse waits
	if err := g.h.sw.OnControl(context.Background(), transport.Control{Kind: transport.EntitlementExpired, Detail: dev.RelayDeviceID}); err != nil {
		t.Fatal(err)
	}
	if !g.h.pub.DirtyForTest(hubslices.KindDeviceGrant) {
		t.Fatal("the lapse did not ask for the grant to be published")
	}
	if k := g.zoneKeys(dev); k != nil {
		t.Fatalf("keys in the zone while the lapse waits: %+v", k)
	}
	if err := g.h.sw.Step(context.Background()); err != nil {
		t.Fatal(err)
	}
	if pending, _ := g.h.st.LapsePending(dev.ID); !pending {
		t.Fatal("the lapse did not wait for the failed read")
	}
	if k := g.zoneKeys(dev); k != nil {
		t.Fatalf("keys in the zone after a failed read: %+v", k)
	}
	if has, _ := g.h.st.HasDeviceKX(dev.ID); has {
		t.Fatal("the phone's relay keys outlived the signal")
	}
}

// F45 and ask #1093: a Mac on the relay with an empty account list, a phone
// with no iCloud route and no signal stays, with no rotation, until the
// 14-day end (the keyring's, through housekeeping) clears the keys; it still
// stays on the relay after that.
func TestIdleHubWithNoSignalStaysAndEndsAt14Days(t *testing.T) {
	g := startG2(t, false)
	dev := g.onlyPhone()
	if err := g.h.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		_, err := tx.Exec(`UPDATE devices SET user_record_name = ''`) // no iCloud route
		return err
	}); err != nil {
		t.Fatal(err)
	}
	g.giveRelayKeys(dev)
	e, _ := g.h.kr.CurrentEpoch()
	g.fake.SetAccountState(&relayv1.AccountState{}) // empty: no slot, nobody pays
	for range 4 {
		g.poll()
	}
	if _, ok, _ := g.h.st.Meta(state.MetaServingNobodySince); !ok {
		t.Fatal("no answered read set relay_serving_nobody_since")
	}
	g.clock.Advance(14*24*time.Hour - time.Hour)
	g.h.housekeeping(context.Background())
	if now, _ := g.h.kr.CurrentEpoch(); now != e {
		t.Fatalf("epoch %d → %d before day 14", e, now)
	}
	if has, _ := g.h.st.HasDeviceKX(dev.ID); !has {
		t.Fatal("the keys went before day 14")
	}
	g.clock.Advance(2 * time.Hour)
	g.h.housekeeping(context.Background())
	if now, _ := g.h.kr.CurrentEpoch(); now != e+1 {
		t.Fatalf("epoch %d → %d at day 14, want one rotation", e, now)
	}
	if has, _ := g.h.st.HasDeviceKX(dev.ID); has {
		t.Fatal("the 14-day end left the phone's relay keys")
	}
	g.poll()
	if !g.h.sw.IsActive(transport.KindRelay) {
		t.Fatal("the idle hub moved with no signal")
	}
	if d, _, _ := g.h.st.Device(dev.ID); d.RelayLapsedAt != nil {
		t.Fatal("an empty list marked the phone lapsed")
	}
}

// A lapsed phone that renews: its zone keybox has keys again (static, sealed
// to dev_kx, as the hub holds no offer), and its next offer is stored and
// answered at the next rotation.
func TestRenewedPhoneGetsKeysInZoneThenOffersAgain(t *testing.T) {
	r := newZoneRig(t, "relay")
	ph := r.phone()
	r.offer(ph)
	if err := r.kr.Rotate(identity.ReasonManual); err != nil {
		t.Fatal(err)
	}
	r.lapse(ph)
	if _, err := r.st.ClearDeviceKX(ph.ID().String()); err != nil {
		t.Fatal(err)
	}
	if k := r.zoneKeys(ph); k != nil {
		t.Fatal("a lapsed phone has keys in the zone")
	}
	if _, err := r.st.EndRelayLapse(ph.ID().String()); err != nil {
		t.Fatal(err)
	}
	k := r.zoneKeys(ph)
	if k == nil || k.RelayKX != nil {
		t.Fatalf("the renewed phone's zone keys %+v, want static keys", k)
	}
	if pub, _ := r.kr.KeyboxRecipient(ph.ID()); string(pub.Bytes()) != string(ph.Device().AgreementKey) {
		t.Fatal("the renewed phone's keybox is not sealed to dev_kx")
	}
	r.keybox(ph)
	r.offer(ph)
	if err := r.kr.Rotate(identity.ReasonManual); err != nil {
		t.Fatal(err)
	}
	if k := r.zoneKeys(ph); k == nil || k.RelayKX == nil {
		t.Fatalf("the epoch after the new offer is not ephemeral: %+v", k)
	}
}

// readersRelay is zoneReadersRelay with set_hub_readers: the linked phones the
// account state holds in a slot become the reader list.
type readersRelay struct{ *zoneReadersRelay }

func (r readersRelay) SetReadersFrom(_ context.Context, st *relayv1.AccountState, linked []string) error {
	slotted := map[string]bool{}
	for _, p := range st.GetPhones() {
		slotted[p.GetPhoneDeviceId()] = true
	}
	var out []string
	for _, id := range linked {
		if slotted[id] {
			out = append(out, id)
		}
	}
	r.setReaders(out...)
	return nil
}

// A readers sync that adds a phone publishes the grant soon, so its keys
// reach the zone at once, not at the next full diff.
func TestAReadersSyncThatAddsAPhonePublishesTheGrant(t *testing.T) {
	r := newZoneRig(t, "relay")
	ph := r.phone()
	rel := readersRelay{r.rel}
	rel.setReaders() // known and empty: the phone is no reader yet
	account := &relayv1.AccountState{}
	h := &hubRuntime{sup: &supervisor{o: Options{Clock: r.clock}}, st: r.st, kr: r.kr, tr: rel}
	h.acct = &accountReader{read: func(context.Context) (*relayv1.AccountState, error) { return account, nil },
		vouched: func() bool { return true }, clock: r.clock}
	h.center = link.NewCenter(link.Config{Store: r.st, Keys: r.kr, Opener: secure.NewOpener(r.kr, r.kr), Clock: r.clock, KeysInZone: h.keysInZone})
	h.pub = hubslices.NewPublisher(hubslices.Config{Store: r.st, Transport: rel, Sealer: secure.NewSealer(r.kr),
		DataZone: transport.DataZone("hubrelay"), Sources: []hubslices.Source{hubslices.GrantSource(h.center)}, Clock: r.clock})
	if k := r.zoneKeysOf(h.center, ph); k != nil {
		t.Fatal("a phone that is no reader has keys in the zone")
	}
	h.syncReaders(context.Background(), rel, true) // unchanged: nothing to publish
	if h.pub.DirtyForTest(hubslices.KindDeviceGrant) {
		t.Fatal("an unchanged reader list asked for a publish")
	}
	account = &relayv1.AccountState{Phones: []*relayv1.SlotHolder{holder(ph, true)}}
	h.syncReaders(context.Background(), rel, true)
	if !h.pub.DirtyForTest(hubslices.KindDeviceGrant) {
		t.Fatal("the new reader's grant was not published soon")
	}
	if k := r.zoneKeysOf(h.center, ph); k == nil {
		t.Fatal("the new reader has no keys in the zone")
	}
}

// onlyPhone is the rig's one linked phone.
func (g *g2Rig) onlyPhone() state.Device {
	g.t.Helper()
	devices, err := g.h.st.Devices()
	if err != nil || len(devices) != 1 {
		g.t.Fatalf("devices %v %v", devices, err)
	}
	return devices[0]
}

// giveRelayKeys stores an offer for dev and rotates once, so the hub holds an
// offer and a relay-key row for it.
func (g *g2Rig) giveRelayKeys(dev state.Device) {
	g.t.Helper()
	g.offer(dev)
	if err := g.h.kr.Rotate(identity.ReasonManual); err != nil {
		g.t.Fatal(err)
	}
	g.offer(dev)
	if has, err := g.h.st.HasDeviceKX(dev.ID); err != nil || !has {
		g.t.Fatalf("no relay keys for the phone (%v)", err)
	}
}

// offer stores a fresh offer for dev at the current epoch, as its ack would.
func (g *g2Rig) offer(dev state.Device) {
	g.t.Helper()
	k, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		g.t.Fatal(err)
	}
	e, err := g.h.kr.CurrentEpoch()
	if err != nil {
		g.t.Fatal(err)
	}
	if err := g.h.st.WithTx(context.Background(), func(tx *sql.Tx) error {
		ok, err := state.SetKXOffer(tx, dev.ID, k.PublicKey().Bytes(), e)
		if err == nil && !ok {
			err = errors.New("offer refused")
		}
		return err
	}); err != nil {
		g.t.Fatal(err)
	}
}

// zoneKeys is dev's data-zone keybox keys.
func (g *g2Rig) zoneKeys(dev state.Device) any {
	g.t.Helper()
	boxes, err := g.h.center.Keyboxes()
	if err != nil {
		g.t.Fatal(err)
	}
	for _, kb := range boxes {
		if kb.Grant.DeviceID == dev.ID || equalFoldID(kb.Grant.DeviceID, dev.ID) {
			if kb.Keys == nil {
				return nil
			}
			return kb.Keys
		}
	}
	g.t.Fatalf("no keybox for %s", dev.ID)
	return nil
}

func (r *zoneRig) zoneKeysOf(c *link.Center, ph *hubtest.Phone) any {
	r.t.Helper()
	boxes, err := c.Keyboxes()
	if err != nil {
		r.t.Fatal(err)
	}
	for _, kb := range boxes {
		if equalFoldID(kb.Grant.DeviceID, ph.ID().String()) {
			if kb.Keys == nil {
				return nil
			}
			return kb.Keys
		}
	}
	r.t.Fatalf("no keybox for %s", ph.ID())
	return nil
}

func equalFoldID(a, b string) bool {
	x, errA := secure.ParseID(a)
	y, errB := secure.ParseID(b)
	return errA == nil && errB == nil && x == y
}

// Review M3: the first readers sync after a restart turns an unknown list
// (keys kept for everyone) into an empty one: the grant is published soon.
func TestAReadersSyncFromUnknownToEmptyPublishesTheGrant(t *testing.T) {
	r := newZoneRig(t, "relay")
	r.phone()
	rel := readersRelay{r.rel} // Readers() nil: unknown
	h := &hubRuntime{sup: &supervisor{o: Options{Clock: r.clock}}, st: r.st, kr: r.kr, tr: rel}
	h.acct = &accountReader{read: func(context.Context) (*relayv1.AccountState, error) { return &relayv1.AccountState{}, nil },
		vouched: func() bool { return true }, clock: r.clock}
	h.center = link.NewCenter(link.Config{Store: r.st, Keys: r.kr, Opener: secure.NewOpener(r.kr, r.kr), Clock: r.clock, KeysInZone: h.keysInZone})
	h.pub = hubslices.NewPublisher(hubslices.Config{Store: r.st, Transport: rel, Sealer: secure.NewSealer(r.kr),
		DataZone: transport.DataZone("hubrelay"), Sources: []hubslices.Source{hubslices.GrantSource(h.center)}, Clock: r.clock})
	h.syncReaders(context.Background(), rel, true)
	if rel.Readers() == nil {
		t.Fatal("the sync set no list")
	}
	if !h.pub.DirtyForTest(hubslices.KindDeviceGrant) {
		t.Fatal("unknown to empty published nothing")
	}
}
