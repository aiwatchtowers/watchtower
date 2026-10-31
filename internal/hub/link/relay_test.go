package link

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/wire"
)

// relayID is a phone's hosted-relay device id, as the relay derives it.
func relayID(t *testing.T) string {
	t.Helper()
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return identity.RelayDeviceID(pub)
}

func withRelayID(id string) func(*wire.DeviceHello) {
	return func(h *wire.DeviceHello) { h.RelayDeviceID = id }
}

// pairZoneRecords reads every live record of the slot's pair zone.
func pairZoneRecords(t *testing.T, f *memfake.Fake, slot string) []transport.Stored {
	t.Helper()
	var out []transport.Stored
	var since uint64
	for {
		b, err := f.Changes(context.Background(), transport.PairZone(slot), since)
		if err != nil {
			t.Fatal(err)
		}
		out = append(out, b.Changed...)
		since = b.NewSeq
		if !b.More {
			return out
		}
	}
}

// pairKeybox is p's keybox as the phone reads it from the pair zone.
func (r *rig) pairKeybox(f *memfake.Fake, slot string, p phone) (wire.Keybox, bool) {
	r.t.Helper()
	for _, s := range pairZoneRecords(r.t, f, slot) {
		if s.Name != "keybox-"+p.id.String() {
			continue
		}
		hub := r.kr.HubID()
		_, fr, err := secure.OpenHPKE(s.Envelope, secure.ClassKeybox, p.kx, secure.KeyboxInfo(hub, p.id),
			secure.Context{Zone: secure.ZoneData, WireName: s.Name}, r.kr.Signer().Public().(ed25519.PublicKey))
		if err != nil {
			r.t.Fatalf("the phone cannot open its pair-zone keybox: %v", err)
		}
		var kb wire.Keybox
		if err := json.Unmarshal(fr.Payload, &kb); err != nil {
			r.t.Fatal(err)
		}
		return kb, true
	}
	return wire.Keybox{}, false
}

// writeHello is the phone writing its hello into the pair zone.
func (r *rig) writeHello(f *memfake.Fake, slot string, p phone, nonce string, edit ...func(*wire.DeviceHello)) {
	r.t.Helper()
	if _, err := f.Write(transport.PairZone(slot), p.name(), r.hello(p, nonce, edit...), transport.Expect{}); err != nil {
		r.t.Fatal(err)
	}
}

// readers records every set the center hands to set_hub_readers.
type readers struct {
	mu   sync.Mutex
	sets [][]string
}

func (rd *readers) set(_ context.Context, ids []string) error {
	rd.mu.Lock()
	defer rd.mu.Unlock()
	rd.sets = append(rd.sets, slices.Clone(ids))
	return nil
}

func (rd *readers) last(t *testing.T) []string {
	t.Helper()
	rd.mu.Lock()
	defer rd.mu.Unlock()
	if len(rd.sets) == 0 {
		t.Fatal("set_hub_readers never called")
	}
	return rd.sets[len(rd.sets)-1]
}

func TestPairingOpenedAnswersKeyboxInPairZone(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()
	f := memfake.New(transport.KindRelay, r.clock)
	code := r.issue()
	p := newPhone(t)

	// PAIRING_OPENED can arrive before the phone wrote its hello: nothing to answer yet.
	if err := r.c.OnPairingOpened(ctx, f, "slot1"); err != nil {
		t.Fatal(err)
	}
	if n := len(pairZoneRecords(t, f, "slot1")); n != 0 {
		t.Fatalf("hub wrote %d records into an empty pair zone", n)
	}

	r.writeHello(f, "slot1", p, code.Nonce, withRelayID(relayID(t)))
	if err := r.c.OnPairingOpened(ctx, f, "slot1"); err != nil {
		t.Fatal(err)
	}
	kb, ok := r.pairKeybox(f, "slot1", p)
	if !ok {
		t.Fatal("no keybox in the pair zone")
	}
	if kb.Grant.AwaitingConfirmation == nil || !*kb.Grant.AwaitingConfirmation || kb.Grant.ConfirmNonce == nil ||
		kb.Grant.LinkCodeTag == nil || kb.Keys != nil {
		t.Fatalf("awaiting keybox: %+v", kb)
	}
	if kb.Grant.RelayDeviceID != testRelayID || !slices.Equal(kb.Grant.Transports, []string{wire.TransportRelay}) {
		t.Fatalf("grant relay identity: %+v", kb.Grant)
	}

	// The hub's own keybox write wakes the zone again: reading it answers
	// nothing new, so the hub never loops on its own writes.
	frames := len(f.Frames())
	for range 3 {
		if err := r.c.OnPairingOpened(ctx, f, "slot1"); err != nil {
			t.Fatal(err)
		}
	}
	if got := len(f.Frames()); got != frames {
		t.Fatalf("re-reading the pair zone wrote %d more records", got-frames)
	}

	// A hello that opens under no kept code gets no answer.
	stranger := newPhone(t)
	r.writeHello(f, "slot1", stranger, b64.EncodeToString(make([]byte, 32)))
	if err := r.c.OnPairingOpened(ctx, f, "slot1"); err != nil {
		t.Fatal(err)
	}
	if _, ok := r.pairKeybox(f, "slot1", stranger); ok {
		t.Fatal("a dropped hello was answered")
	}

	for _, bad := range []string{"", "a/b"} {
		if err := r.c.OnPairingOpened(ctx, f, bad); err == nil {
			t.Errorf("slot %q accepted", bad)
		}
	}
}

func TestPromotedPhoneBecomesReader(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()
	f := memfake.New(transport.KindRelay, r.clock)
	code := r.issue()
	p := newPhone(t)
	pid := relayID(t)
	r.writeHello(f, "slot1", p, code.Nonce, withRelayID(pid))
	if err := r.c.OnPairingOpened(ctx, f, "slot1"); err != nil {
		t.Fatal(err)
	}

	var rd readers
	if err := r.c.SyncReaders(ctx, rd.set); err != nil {
		t.Fatal(err)
	}
	if got := rd.last(t); len(got) != 0 {
		t.Fatalf("a phone waiting for the owner reads the data zone: %v", got)
	}

	// The relay id survives a restart: it is stored with the request.
	c2 := NewCenter(Config{Store: r.st, Keys: r.kr, Opener: secure.NewOpener(r.kr, r.kr),
		Host: HostInfo{RelayDeviceID: testRelayID, RelayAuthPub: testRelayPub}, Clock: r.clock})
	if err := c2.Confirm(p.id.String(), r.code(p), true); err != nil {
		t.Fatal(err)
	}
	if err := c2.SyncReaders(ctx, rd.set); err != nil {
		t.Fatal(err)
	}
	if got := rd.last(t); !slices.Equal(got, []string{pid}) {
		t.Fatalf("readers after the link: %v, want [%s]", got, pid)
	}
	d, ok, err := r.st.Device(p.id.String())
	if err != nil || !ok || d.RelayDeviceID != pid {
		t.Fatalf("device row: %+v %v %v", d, ok, err)
	}

	// The confirmed keybox reaches the phone in the pair zone, with the keys.
	if err := r.c.PublishPairKeyboxes(ctx, f); err != nil {
		t.Fatal(err)
	}
	kb, ok := r.pairKeybox(f, "slot1", p)
	if !ok || !kb.Grant.Linked || kb.Keys == nil {
		t.Fatalf("linked pair-zone keybox: %+v (found %v)", kb, ok)
	}

	// A phone linked without a relay id (the CloudKit route) is no reader.
	other := newPhone(t)
	r.handle(other, r.issue().Nonce)
	if err := r.c.Confirm(other.id.String(), r.code(other), true); err != nil {
		t.Fatal(err)
	}
	if err := r.c.SyncReaders(ctx, rd.set); err != nil {
		t.Fatal(err)
	}
	if got := rd.last(t); !slices.Equal(got, []string{pid}) {
		t.Fatalf("readers with a CloudKit phone: %v", got)
	}
}

func TestRemovedPhoneLeavesReaders(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()
	f := memfake.New(transport.KindRelay, r.clock)
	a, b := newPhone(t), newPhone(t)
	aid, bid := relayID(t), relayID(t)
	for i, ph := range []struct {
		p  phone
		id string
	}{{a, aid}, {b, bid}} {
		slot := []string{"slot-a", "slot-b"}[i]
		r.writeHello(f, slot, ph.p, r.issue().Nonce, withRelayID(ph.id))
		if err := r.c.OnPairingOpened(ctx, f, slot); err != nil {
			t.Fatal(err)
		}
		if err := r.c.Confirm(ph.p.id.String(), r.code(ph.p), true); err != nil {
			t.Fatal(err)
		}
	}
	var rd readers
	if err := r.c.SyncReaders(ctx, rd.set); err != nil {
		t.Fatal(err)
	}
	want := []string{aid, bid}
	slices.Sort(want)
	if got := rd.last(t); !slices.Equal(got, want) {
		t.Fatalf("readers: %v, want %v", got, want)
	}
	if err := r.c.Unlink(a.id.String()); err != nil {
		t.Fatal(err)
	}
	if err := r.c.SyncReaders(ctx, rd.set); err != nil {
		t.Fatal(err)
	}
	if got := rd.last(t); !slices.Equal(got, []string{bid}) {
		t.Fatalf("readers after the unlink: %v, want [%s]", got, bid)
	}
	// A failing set is returned to the caller, who retries on its next pass.
	boom := errors.New("relay down")
	if err := r.c.SyncReaders(ctx, func(context.Context, []string) error { return boom }); !errors.Is(err, boom) {
		t.Fatalf("set failure: %v", err)
	}
}

func TestPairZoneCarriesNoAttachments(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()
	f := memfake.New(transport.KindRelay, r.clock)
	code := r.issue()
	p := newPhone(t)
	r.writeHello(f, "slot1", p, code.Nonce, withRelayID(relayID(t)))
	if err := r.c.OnPairingOpened(ctx, f, "slot1"); err != nil {
		t.Fatal(err)
	}
	if err := r.c.Confirm(p.id.String(), r.code(p), true); err != nil {
		t.Fatal(err)
	}
	if err := r.c.PublishPairKeyboxes(ctx, f); err != nil {
		t.Fatal(err)
	}
	recs := pairZoneRecords(t, f, "slot1")
	if len(recs) != 2 {
		t.Fatalf("pair zone records: %d, want the hello and the keybox", len(recs))
	}
	for _, s := range recs {
		if s.AttachmentID != "" {
			t.Fatalf("record %s carries an attachment", s.Name)
		}
		if !strings.HasPrefix(s.Name, "hello-") && !strings.HasPrefix(s.Name, "keybox-") {
			t.Fatalf("unexpected record %s in the pair zone", s.Name)
		}
	}
	if n := len(f.Attachments()); n != 0 {
		t.Fatalf("%d attachments uploaded during pairing", n)
	}
}

func TestHelloWithAMalformedRelayIDIsDropped(t *testing.T) {
	r := newRig(t)
	code := r.issue()
	p := newPhone(t)
	for _, bad := range []string{"NOT-A-RELAY-ID", strings.Repeat("a", 51), strings.Repeat("1", 52)} {
		_, err := r.c.HandleHello("relay", p.name(), r.hello(p, code.Nonce, withRelayID(bad)))
		if !errors.Is(err, ErrHelloDropped) {
			t.Errorf("relay id %q: %v", bad, err)
		}
	}
	if got := r.handle(p, code.Nonce, withRelayID(relayID(t))); got.Code == "" {
		t.Fatalf("a well-formed relay id: %+v", got)
	}
}

func TestHeadlessHostPinsRelayOnly(t *testing.T) {
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	h := HeadlessHost("acme-host", pub)
	if h.Name != "acme-host" || !slices.Equal(h.Transports, []string{wire.TransportRelay}) ||
		h.RelayDeviceID != identity.RelayDeviceID(pub) || h.RelayAuthPub != b64.EncodeToString(pub) {
		t.Fatalf("host: %+v", h)
	}
}

// watchingFake is the memfake with the hosted relay's pair-zone subscribe.
type watchingFake struct {
	*memfake.Fake
	mu      sync.Mutex
	fail    int
	watched []string
}

func (w *watchingFake) WatchPairZone(_ context.Context, slot string) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.fail > 0 {
		w.fail--
		return transport.ErrUnavailable
	}
	w.watched = append(w.watched, slot)
	return nil
}

func TestPairZoneSubscribedUntilItTakes(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()
	w := &watchingFake{Fake: memfake.New(transport.KindRelay, r.clock), fail: 1}
	for range 3 {
		if err := r.c.OnPairingOpened(ctx, w, "slot1"); err != nil {
			t.Fatal(err)
		}
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if !slices.Equal(w.watched, []string{"slot1"}) {
		t.Fatalf("subscriptions: %v, want one after the failed one", w.watched)
	}
}

// rebuiltZone is a memfake whose pair zone was rebuilt on the relay: the
// first read after cursor 10 is TOKEN_EXPIRED and the zone's counter starts
// low again. It records every cursor the hub reads from.
type rebuiltZone struct {
	*memfake.Fake
	mu      sync.Mutex
	sinces  []uint64
	expired bool
}

func (z *rebuiltZone) Changes(ctx context.Context, zone string, since uint64) (transport.Batch, error) {
	z.mu.Lock()
	z.sinces = append(z.sinces, since)
	first := !z.expired
	z.mu.Unlock()
	switch {
	case since == 0 && first:
		// Before the rebuild the zone stood at 10.
		b, err := z.Fake.Changes(ctx, zone, 0)
		b.NewSeq = 10
		return b, err
	case since == 10:
		z.mu.Lock()
		z.expired = true
		z.mu.Unlock()
		return transport.Batch{}, transport.ErrTokenExpired
	}
	return z.Fake.Changes(ctx, zone, since)
}

func TestPairZoneCursorAfterResyncReplacesTheOldOne(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()
	z := &rebuiltZone{Fake: memfake.New(transport.KindRelay, r.clock)}
	p := newPhone(t)
	r.writeHello(z.Fake, "slot1", p, r.issue().Nonce, withRelayID(relayID(t)))
	for range 3 {
		if err := r.c.OnPairingOpened(ctx, z, "slot1"); err != nil {
			t.Fatal(err)
		}
	}
	z.mu.Lock()
	defer z.mu.Unlock()
	// Read 1 from 0 (cursor 10); read 2 from 10 → expired → from 0 (the
	// rebuilt zone: hello + keybox, seq 2); read 3 from 2, not from 10 or 0.
	want := []uint64{0, 10, 0, 2}
	if !slices.Equal(z.sinces, want) {
		t.Fatalf("cursors read: %v, want %v", z.sinces, want)
	}
}

func TestAFailedHelloStillAnswersTheOnesDecidedBeforeIt(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()
	f := memfake.New(transport.KindRelay, r.clock)
	code := r.issue()
	a, b := newPhone(t), newPhone(t)
	r.writeHello(f, "slot1", a, code.Nonce, withRelayID(relayID(t)))
	r.writeHello(f, "slot1", b, code.Nonce, withRelayID(relayID(t)))
	trigger := func(q string) {
		t.Helper()
		if err := r.st.WithTx(ctx, func(tx *sql.Tx) error { _, err := tx.Exec(q); return err }); err != nil {
			t.Fatal(err)
		}
	}
	trigger(`CREATE TRIGGER fail_b BEFORE INSERT ON pending_devices WHEN NEW.device_id = '` + b.id.String() +
		`' BEGIN SELECT RAISE(ABORT, 'injected'); END`)
	if err := r.c.OnPairingOpened(ctx, f, "slot1"); err == nil {
		t.Fatal("the failing hello's error was not reported")
	}
	if _, ok := r.pairKeybox(f, "slot1", a); !ok {
		t.Fatal("the hello decided before the failure got no keybox")
	}
	if _, ok := r.pairKeybox(f, "slot1", b); ok {
		t.Fatal("the failed hello got a keybox")
	}
	trigger(`DROP TRIGGER fail_b`)
	if err := r.c.OnPairingOpened(ctx, f, "slot1"); err != nil {
		t.Fatal(err)
	}
	if kb, ok := r.pairKeybox(f, "slot1", b); !ok || kb.Grant.AwaitingConfirmation == nil {
		t.Fatalf("the failed hello was not read again: %+v %v", kb, ok)
	}
	if r.code(a) == "" {
		t.Fatal("phone a's request was lost")
	}
}

func TestRefusalKeyboxReachesThePairZone(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()
	f := memfake.New(transport.KindRelay, r.clock)
	p := newPhone(t)
	r.writeHello(f, "slot1", p, r.issue().Nonce, withRelayID(relayID(t)))
	if err := r.c.OnPairingOpened(ctx, f, "slot1"); err != nil {
		t.Fatal(err)
	}
	if err := r.c.Confirm(p.id.String(), r.code(p), false); err != nil {
		t.Fatal(err)
	}
	if err := r.c.PublishPairKeyboxes(ctx, f); err != nil {
		t.Fatal(err)
	}
	kb, ok := r.pairKeybox(f, "slot1", p)
	if !ok || kb.Grant.LinkRefused == nil || *kb.Grant.LinkRefused != wire.RefusedNotConfirmed || kb.Keys != nil {
		t.Fatalf("refusal keybox: %+v (found %v)", kb, ok)
	}
}

func TestExpiryKeyboxReachesThePairZone(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()
	f := memfake.New(transport.KindRelay, r.clock)
	p := newPhone(t)
	code := r.issue()
	r.advance(60 * time.Second) // the phone scans and opens its slot a minute later
	r.writeHello(f, "slot1", p, code.Nonce, withRelayID(relayID(t)))
	if err := r.c.OnPairingOpened(ctx, f, "slot1"); err != nil {
		t.Fatal(err)
	}
	r.advance(wire.LinkLifetime - 59*time.Second) // past the code, inside the slot
	if err := r.c.Sweep(); err != nil {
		t.Fatal(err)
	}
	if err := r.c.PublishPairKeyboxes(ctx, f); err != nil {
		t.Fatal(err)
	}
	kb, ok := r.pairKeybox(f, "slot1", p)
	if !ok || kb.Grant.LinkRefused == nil || *kb.Grant.LinkRefused != wire.RefusedExpiredCode || kb.Keys != nil {
		t.Fatalf("expiry keybox: %+v (found %v)", kb, ok)
	}
}

// TestPairZoneKeyboxOpensInTheKitsDataContext pins the context the phone
// opens a keybox with: the Kit's ReplicaOpener.openKeybox uses
// EnvelopeContext(zone: .data, wireName: "keybox-<UUID>") whatever transport
// zone the record came from, so a pair-zone keybox is sealed with the data
// zone byte and that wire name, and does not open under the relay zone byte.
func TestPairZoneKeyboxOpensInTheKitsDataContext(t *testing.T) {
	r := newRig(t)
	ctx := context.Background()
	f := memfake.New(transport.KindRelay, r.clock)
	p := newPhone(t)
	r.writeHello(f, "slot1", p, r.issue().Nonce, withRelayID(relayID(t)))
	if err := r.c.OnPairingOpened(ctx, f, "slot1"); err != nil {
		t.Fatal(err)
	}
	var box *transport.Stored
	for _, s := range pairZoneRecords(t, f, "slot1") {
		if strings.HasPrefix(s.Name, "keybox-") {
			box = &s
		}
	}
	if box == nil || box.Name != "keybox-"+strings.ToUpper(p.id.String()) {
		t.Fatalf("keybox record: %+v", box)
	}
	hub := r.kr.HubID()
	sig := r.kr.Signer().Public().(ed25519.PublicKey)
	open := func(z secure.Zone) error {
		_, _, err := secure.OpenHPKE(box.Envelope, secure.ClassKeybox, p.kx, secure.KeyboxInfo(hub, p.id),
			secure.Context{Zone: z, WireName: box.Name}, sig)
		return err
	}
	if err := open(secure.ZoneData); err != nil {
		t.Fatalf("does not open in the data context: %v", err)
	}
	if err := open(secure.ZoneRelay); err == nil {
		t.Fatal("opens in the relay context too: the zone byte is not bound")
	}
}
