package secure

import (
	"bytes"
	"crypto/ecdh"
	"crypto/ed25519"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"testing"
)

// InMemoryKeySource is the fixed test KeySource over the Kit fixture keys:
// hub 00112233-…, epoch 1 current, relay keys derived from hub_kx/dev_kx and
// the fixture link nonce. Every key it hands out is a fresh copy, tracked so a
// test can check the caller zeroed it.
type InMemoryKeySource struct {
	k        keys
	hub      ID
	epoch    uint32
	accepted map[uint32]bool
	devices  []ID
	seq      uint64
	handed   [][]byte
	metaErr  error
}

func newKeySource(t *testing.T) *InMemoryKeySource {
	t.Helper()
	k := fixtureKeys(t)
	return &InMemoryKeySource{k: k, hub: fixtureHubID, epoch: 1, accepted: map[uint32]bool{1: true}, devices: []ID{k.deviceID}, seq: 6}
}

func (s *InMemoryKeySource) hand(b []byte) []byte {
	c := bytes.Clone(b)
	s.handed = append(s.handed, c)
	return c
}

func (s *InMemoryKeySource) HubID() ID                      { return s.hub }
func (s *InMemoryKeySource) CurrentEpoch() (uint32, error)  { return s.epoch, nil }
func (s *InMemoryKeySource) NextSeq() (uint64, error)       { s.seq++; return s.seq, nil }
func (s *InMemoryKeySource) DataKey(uint32) ([]byte, error) { return s.hand(dataKey), nil }
func (s *InMemoryKeySource) AlertKey(uint32) ([]byte, error) {
	return s.hand(alertKey), nil
}
func (s *InMemoryKeySource) MetaKey() ([]byte, error) {
	if s.metaErr != nil {
		return nil, s.metaErr
	}
	return s.hand(metaKey), nil
}
func (s *InMemoryKeySource) RelayKey(dir Direction, device ID, epoch uint32) ([]byte, error) {
	if !slices.Contains(s.devices, device) {
		return nil, fmt.Errorf("unknown device %s", device)
	}
	key, err := RelayKey(s.k.hubKX, s.k.devKX.PublicKey(), linkNonce, s.hub, device, epoch, dir)
	if err != nil {
		return nil, err
	}
	s.handed = append(s.handed, key)
	return key, nil
}
func (s *InMemoryKeySource) AcceptsRelayEpoch(epoch uint32, device ID) (bool, error) {
	return s.accepted[epoch] && slices.Contains(s.devices, device), nil
}
func (s *InMemoryKeySource) RelayDevices() ([]ID, error) { return slices.Clone(s.devices), nil }
func (s *InMemoryKeySource) Signer() ed25519.PrivateKey  { return s.k.hubSig }
func (s *InMemoryKeySource) Agreement() *ecdh.PrivateKey { return s.k.hubKX }
func (s *InMemoryKeySource) KeyboxRecipient(device ID) (*ecdh.PublicKey, error) {
	if device != s.k.deviceID {
		return nil, fmt.Errorf("unknown device %s", device)
	}
	return s.k.devKX.PublicKey(), nil
}

// memGuard is relay_seen in memory; records counts every Record call.
type memGuard struct {
	seen    map[string][2]uint64
	records int
}

func newGuard() *memGuard { return &memGuard{seen: map[string][2]uint64{}} }

func (g *memGuard) Check(wire string, sender ID, epoch uint32, seq uint64) (Verdict, error) {
	v, ok := g.seen[wire+"|"+sender.String()]
	if !ok {
		return Newer, nil
	}
	return CompareVersion(uint32(v[0]), v[1], epoch, seq), nil
}

func (g *memGuard) Record(wire string, sender ID, epoch uint32, seq uint64) error {
	g.records++
	g.seen[wire+"|"+sender.String()] = [2]uint64{uint64(epoch), seq}
	return nil
}

// phoneAction seals what the phone writes into its mailbox: a relayToHub
// record of kind action under the p2h key.
func phoneAction(t *testing.T, ks *InMemoryKeySource, plain string, epoch uint32, seq uint64, hub, sender ID) (string, []byte) {
	t.Helper()
	wire, err := NewSealer(ks).WireName(ZoneRelay, plain)
	if err != nil {
		t.Fatal(err)
	}
	key, err := RelayKey(ks.k.hubKX, ks.k.devKX.PublicKey(), linkNonce, ks.hub, ks.k.deviceID, epoch, PhoneToHub)
	if err != nil {
		t.Fatal(err)
	}
	f := InnerFrame{Kind: "action", ID: plain, Payload: []byte(`{"op":"probe"}`)}
	env, err := SealSymmetric(f, ClassRelayToHub, key, hub, sender, epoch, seq, Context{Zone: ZoneRelay, WireName: wire}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	return wire, env
}

func TestRecord_ZeroValueIsNotSealed(t *testing.T) {
	var r Record
	if r.Sealed() || (Record{}).Sealed() {
		t.Fatal("a zero Record reports sealed")
	}
	if r.Envelope() != nil || r.WireName() != "" || r.Zone() != "" || r.AssetPath() != "" {
		t.Error("a zero Record carries data")
	}
	ks := newKeySource(t)
	sealed, err := NewSealer(ks).Data("data", "target-7", "", []byte(`{}`), nil, "")
	if err != nil || !sealed.Sealed() {
		t.Fatalf("sealer record: %v", err)
	}
	env := sealed.Envelope()
	env[0] = 'X'
	if sealed.Envelope()[0] != 'W' {
		t.Error("Envelope() exposes the record's own bytes")
	}
}

func TestSealer_WireNames(t *testing.T) {
	ks := newKeySource(t)
	s := NewSealer(ks)
	dev := ks.k.deviceID.String()
	lowerDev := "880b6d06-8852-6316-76c4-9a1a29e1eb29"
	cases := []struct {
		zone        Zone
		plain, want string
	}{
		{ZoneData, "heartbeat", "heartbeat"},
		{ZoneData, "device_grant-" + dev, "keybox-" + dev},
		{ZoneData, "device_grant-" + lowerDev, "keybox-" + dev},
		{ZoneData, "device_grant-not-a-uuid", "keybox-not-a-uuid"},
		{ZoneRelay, "hello-" + dev, "hello-" + dev},
		{ZoneData, "target-7", RecordName(metaKey, ZoneData, "target", "7")},
		{ZoneData, "session_chat-12-agent-3", RecordName(metaKey, ZoneData, "session_chat", "12-agent-3")},
		{ZoneData, "nodash", RecordName(metaKey, ZoneData, "nodash", "")},
		{ZoneRelay, "a-" + dev + "-4", RecordName(metaKey, ZoneRelay, "a", dev+"-4")},
		// The key-free rules are per zone.
		{ZoneRelay, "heartbeat", RecordName(metaKey, ZoneRelay, "heartbeat", "")},
		{ZoneData, "hello-" + dev, RecordName(metaKey, ZoneData, "hello", dev)},
	}
	for _, c := range cases {
		got, err := s.WireName(c.zone, c.plain)
		if err != nil || got != c.want {
			t.Errorf("WireName(%d, %q) = %q, %v; want %q", c.zone, c.plain, got, err, c.want)
		}
	}
	// A delete by plain name maps to the wire name of the record it sealed.
	r, err := s.Data("data", "target-7", "", []byte(`{}`), nil, "")
	if err != nil {
		t.Fatal(err)
	}
	if w, _ := s.WireName(ZoneData, "target-7"); w != r.WireName() {
		t.Errorf("delete name %q, sealed %q", w, r.WireName())
	}
	if _, err := s.WireName(ZoneData, ""); err == nil {
		t.Error("an empty name was mapped")
	}
	if _, err := s.WireName(Zone(9), "target-7"); err == nil {
		t.Error("an unknown zone was mapped")
	}
}

func TestSealer_EveryClassOpens(t *testing.T) {
	ks := newKeySource(t)
	s := NewSealer(ks)
	hubSigPub := ks.k.hubSig.Public().(ed25519.PublicKey)
	dev := ks.k.deviceID

	data, err := s.Data("dz", "meeting_transcript-9", "urgent", []byte(`{"title":"Acme sync"}`), nil, "")
	if err != nil {
		t.Fatal(err)
	}
	h, f, err := OpenSymmetric(data.Envelope(), []EnvelopeClass{ClassData}, Context{Zone: ZoneData, WireName: data.WireName()}, hubSigPub,
		func(Header) ([]byte, error) { return dataKey, nil })
	if err != nil {
		t.Fatal(err)
	}
	if f.Kind != "meeting_transcript" || f.ID != "meeting_transcript-9" || f.NotifyLevel != "urgent" || h.Sender != fixtureHubID || h.Hub != fixtureHubID ||
		h.Flags&FlagSigned == 0 || data.Zone() != "dz" || !data.Sealed() {
		t.Errorf("data: %+v %+v", h, f)
	}

	alert, err := s.Alert("dz", "ask_alert-42", []byte(`{"ask_id":42}`))
	if err != nil {
		t.Fatal(err)
	}
	if _, f, err := OpenSymmetric(alert.Envelope(), []EnvelopeClass{ClassAlert}, Context{Zone: ZoneData, WireName: alert.WireName()}, hubSigPub,
		func(Header) ([]byte, error) { return alertKey, nil }); err != nil || f.Kind != "ask_alert" || f.ID != "ask_alert-42" {
		t.Errorf("alert: %+v, %v", f, err)
	}

	box, err := s.Keybox("dz", dev, []byte(`{"grant":{}}`))
	if err != nil {
		t.Fatal(err)
	}
	if box.WireName() != "keybox-"+dev.String() {
		t.Errorf("keybox wire %q", box.WireName())
	}
	if _, f, err := OpenHPKE(box.Envelope(), ClassKeybox, ks.k.devKX, KeyboxInfo(fixtureHubID, dev), Context{Zone: ZoneData, WireName: box.WireName()},
		hubSigPub); err != nil || f.Kind != "device_grant" || f.ID != "device_grant-"+dev.String() {
		t.Errorf("keybox: %+v, %v", f, err)
	}

	plain := "a-" + dev.String() + "-1"
	wire, _ := s.WireName(ZoneRelay, plain)
	echo, err := s.ToPhone("mailbox", dev, wire, "action", plain, []byte(`{"status":"applied"}`))
	if err != nil {
		t.Fatal(err)
	}
	h2p, _ := RelayKey(ks.k.hubKX, ks.k.devKX.PublicKey(), linkNonce, fixtureHubID, dev, 1, HubToPhone)
	if h, f, err := OpenSymmetric(echo.Envelope(), []EnvelopeClass{ClassRelayToPhone}, Context{Zone: ZoneRelay, WireName: wire}, nil,
		func(Header) ([]byte, error) { return h2p, nil }); err != nil || f.ID != plain || h.Flags&FlagSigned != 0 {
		t.Errorf("to phone: %+v, %v", f, err)
	}
	opened, err := NewOpener(ks, newGuard()).OwnEcho("mailbox", wire, echo.Envelope())
	if err != nil || opened.Frame.ID != plain || opened.Sender != fixtureHubID || opened.Verdict != Newer {
		t.Errorf("own echo: %+v, %v", opened, err)
	}
}

func TestSealer_ZeroesEveryKeyItWasHanded(t *testing.T) {
	ks := newKeySource(t)
	s := NewSealer(ks)
	if _, err := s.Data("dz", "target-7", "", []byte(`{}`), nil, ""); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Alert("dz", "ask_alert-1", []byte(`{}`)); err != nil {
		t.Fatal(err)
	}
	plain := "a-" + ks.k.deviceID.String() + "-1"
	wire, _ := s.WireName(ZoneRelay, plain)
	rec, err := s.ToPhone("mb", ks.k.deviceID, wire, "action", plain, []byte(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := NewOpener(ks, newGuard()).OwnEcho("mb", wire, rec.Envelope()); err != nil {
		t.Fatal(err)
	}
	if len(ks.handed) < 6 {
		t.Fatalf("only %d keys handed out", len(ks.handed))
	}
	for i, k := range ks.handed {
		if !bytes.Equal(k, make([]byte, len(k))) {
			t.Errorf("key %d left unzeroed", i)
		}
	}
}

func TestSealer_RefusesMisuse(t *testing.T) {
	ks := newKeySource(t)
	s := NewSealer(ks)
	dev := ks.k.deviceID
	if _, err := s.Data("dz", "device_grant-"+dev.String(), "", nil, nil, ""); !errors.Is(err, ErrWrongClass) {
		t.Errorf("device_grant as data: %v", err)
	}
	if _, err := s.Data("dz", "ask_alert-1", "", nil, nil, ""); !errors.Is(err, ErrWrongClass) {
		t.Errorf("ask_alert as data: %v", err)
	}
	if _, err := s.Alert("dz", "target-1", nil); !errors.Is(err, ErrWrongClass) {
		t.Errorf("target as alert: %v", err)
	}
	if _, err := s.Data("", "target-1", "", nil, nil, ""); err == nil {
		t.Error("no zone accepted")
	}
	plain := "a-" + dev.String() + "-1"
	other, _ := s.WireName(ZoneRelay, "a-"+dev.String()+"-2")
	if _, err := s.ToPhone("mb", dev, other, "action", plain, nil); !errors.Is(err, ErrNameMismatch) {
		t.Errorf("mismatched wire name: %v", err)
	}
	if _, err := s.Keybox("dz", mustID("00000000-0000-0000-0000-000000000001"), nil); err == nil {
		t.Error("keybox to an unknown device sealed")
	}
	unsigned := newKeySource(t)
	unsigned.k.hubSig = nil
	if _, err := NewSealer(unsigned).Data("dz", "target-1", "", nil, nil, ""); !errors.Is(err, ErrSignatureRequired) {
		t.Errorf("no signer: %v", err)
	}
}

func TestSealer_AssetMustBeTheSealedFile(t *testing.T) {
	ks := newKeySource(t)
	s := NewSealer(ks)
	dir := t.TempDir()
	plainFile := filepath.Join(dir, "plain.bin")
	sealedFile := filepath.Join(dir, "asset.wta")
	if err := os.WriteFile(plainFile, bytes.Repeat([]byte("acme "), 1000), 0o600); err != nil {
		t.Fatal(err)
	}
	d, err := EncryptAssetFile(plainFile, sealedFile, fixtureHubID)
	if err != nil {
		t.Fatal(err)
	}
	r, err := s.Data("dz", "meeting_transcript-9", "", []byte(`{}`), &d, sealedFile)
	if err != nil {
		t.Fatalf("sealed asset refused: %v", err)
	}
	if r.AssetPath() != sealedFile {
		t.Errorf("asset path %q", r.AssetPath())
	}
	// A plaintext file of exactly the sealed length does not open.
	sealedBytes, _ := os.ReadFile(sealedFile)
	fake := filepath.Join(dir, "fake.wta")
	if err := os.WriteFile(fake, make([]byte, len(sealedBytes)), 0o600); err != nil {
		t.Fatal(err)
	}
	for name, try := range map[string]func() error{
		"plaintext":     func() error { _, err := s.Data("dz", "target-1", "", nil, &d, plainFile); return err },
		"same length":   func() error { _, err := s.Data("dz", "target-1", "", nil, &d, fake); return err },
		"no descriptor": func() error { _, err := s.Data("dz", "target-1", "", nil, nil, sealedFile); return err },
		"no file":       func() error { _, err := s.Data("dz", "target-1", "", nil, &d, ""); return err },
	} {
		if err := try(); !errors.Is(err, ErrUnsealed) {
			t.Errorf("%s: %v, want ErrUnsealed", name, err)
		}
	}
}

func TestOpener_FromPhoneNeverRecords(t *testing.T) {
	ks := newKeySource(t)
	g := newGuard()
	o := NewOpener(ks, g)
	wire, env := phoneAction(t, ks, "a-"+ks.k.deviceID.String()+"-1", 1, 5, fixtureHubID, ks.k.deviceID)
	for i := range 2 {
		opened, err := o.FromPhone("mb", wire, env)
		if err != nil {
			t.Fatalf("call %d: %v", i, err)
		}
		if opened.Verdict != Newer || opened.Sender != ks.k.deviceID || opened.Seq != 5 || opened.Epoch != 1 || opened.Frame.Kind != "action" {
			t.Errorf("call %d: %+v", i, opened)
		}
	}
	if g.records != 0 || len(g.seen) != 0 {
		t.Errorf("the opener wrote the guard: %d records", g.records)
	}
}

func TestOpener_RollbackRefusesOlderAndSame(t *testing.T) {
	ks := newKeySource(t)
	g := newGuard()
	o := NewOpener(ks, g)
	plain := "a-" + ks.k.deviceID.String() + "-1"
	wire, env := phoneAction(t, ks, plain, 1, 5, fixtureHubID, ks.k.deviceID)
	if err := g.Record(wire, ks.k.deviceID, 1, 5); err != nil {
		t.Fatal(err)
	}
	opened, err := o.FromPhone("mb", wire, env)
	if err != nil || opened.Verdict != Same {
		t.Errorf("same: %+v, %v", opened, err)
	}
	_, older := phoneAction(t, ks, plain, 1, 4, fixtureHubID, ks.k.deviceID)
	if _, err := o.FromPhone("mb", wire, older); !errors.Is(err, ErrRolledBack) {
		t.Errorf("older: %v", err)
	}
	_, newer := phoneAction(t, ks, plain, 1, 6, fixtureHubID, ks.k.deviceID)
	if opened, err := o.FromPhone("mb", wire, newer); err != nil || opened.Verdict != Newer {
		t.Errorf("newer: %+v, %v", opened, err)
	}
	// The guard is keyed by (wire, sender): the hub's echo at the same name is its own space.
	if err := g.Record(wire, fixtureHubID, 1, 99); err != nil {
		t.Fatal(err)
	}
	if opened, err := o.FromPhone("mb", wire, newer); err != nil || opened.Verdict != Newer {
		t.Errorf("after an echo mark: %+v, %v", opened, err)
	}
}

func TestOpener_UnacceptedEpochRefused(t *testing.T) {
	ks := newKeySource(t)
	o := NewOpener(ks, newGuard())
	wire, env := phoneAction(t, ks, "a-"+ks.k.deviceID.String()+"-1", 2, 5, fixtureHubID, ks.k.deviceID)
	if _, err := o.FromPhone("mb", wire, env); !errors.Is(err, ErrEpochNotAccepted) {
		t.Errorf("epoch 2: %v", err)
	}
	ks.accepted[2] = true
	if _, err := o.FromPhone("mb", wire, env); err != nil {
		t.Errorf("accepted epoch 2: %v", err)
	}
}

func TestOpener_RefusesAnotherHubOrSender(t *testing.T) {
	ks := newKeySource(t)
	o := NewOpener(ks, newGuard())
	s := NewSealer(ks)
	dev := ks.k.deviceID
	otherHub := mustID("FFEEDDCC-BBAA-9988-7766-554433221100")
	stranger := mustID("00000000-0000-0000-0000-0000000000AA")
	plain := "a-" + dev.String() + "-1"

	wire, env := phoneAction(t, ks, plain, 1, 5, otherHub, dev)
	if _, err := o.FromPhone("mb", wire, env); !errors.Is(err, ErrWrongHub) {
		t.Errorf("from phone, another hub: %v", err)
	}
	wire, env = phoneAction(t, ks, plain, 1, 5, fixtureHubID, stranger)
	if _, err := o.FromPhone("mb", wire, env); !errors.Is(err, ErrWrongSender) {
		t.Errorf("from phone, unlinked sender: %v", err)
	}
	// A phone writing a relayToPhone record that claims to be an echo.
	h2p, _ := RelayKey(ks.k.hubKX, ks.k.devKX.PublicKey(), linkNonce, fixtureHubID, dev, 1, HubToPhone)
	f := InnerFrame{Kind: "action", ID: plain, Payload: []byte(`{}`)}
	forged, err := SealSymmetric(f, ClassRelayToPhone, h2p, fixtureHubID, dev, 1, 5, Context{Zone: ZoneRelay, WireName: wire}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := o.OwnEcho("mb", wire, forged); !errors.Is(err, ErrWrongSender) {
		t.Errorf("own echo, sender not the hub: %v", err)
	}
	foreign, err := SealSymmetric(f, ClassRelayToPhone, h2p, otherHub, otherHub, 1, 5, Context{Zone: ZoneRelay, WireName: wire}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := o.OwnEcho("mb", wire, foreign); !errors.Is(err, ErrWrongHub) {
		t.Errorf("own echo, another hub: %v", err)
	}
	// Classes cross-checked.
	echo, err := s.ToPhone("mb", dev, wire, "action", plain, []byte(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := o.FromPhone("mb", wire, echo.Envelope()); !errors.Is(err, ErrWrongClass) {
		t.Errorf("echo through FromPhone: %v", err)
	}
	_, action := phoneAction(t, ks, plain, 1, 5, fixtureHubID, dev)
	if _, err := o.OwnEcho("mb", wire, action); !errors.Is(err, ErrWrongClass) {
		t.Errorf("action through OwnEcho: %v", err)
	}
	// An echo no linked device's key opens.
	ks.devices = nil
	if _, err := o.OwnEcho("mb", wire, echo.Envelope()); !errors.Is(err, ErrNoRelayKey) {
		t.Errorf("no linked device: %v", err)
	}
}

func TestOpener_FrameMustNameItsWireRecord(t *testing.T) {
	ks := newKeySource(t)
	o := NewOpener(ks, newGuard())
	dev := ks.k.deviceID
	// Sealed honestly under wire name A, with a frame naming record B.
	wireA, _ := NewSealer(ks).WireName(ZoneRelay, "a-"+dev.String()+"-1")
	key, _ := RelayKey(ks.k.hubKX, ks.k.devKX.PublicKey(), linkNonce, fixtureHubID, dev, 1, PhoneToHub)
	f := InnerFrame{Kind: "action", ID: "a-" + dev.String() + "-2", Payload: []byte(`{}`)}
	env, err := SealSymmetric(f, ClassRelayToHub, key, fixtureHubID, dev, 1, 5, Context{Zone: ZoneRelay, WireName: wireA}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := o.FromPhone("mb", wireA, env); !errors.Is(err, ErrNameMismatch) {
		t.Errorf("frame naming another record: %v", err)
	}
	// The same envelope read under another wire name does not open at all.
	wireB, _ := NewSealer(ks).WireName(ZoneRelay, f.ID)
	if _, err := o.FromPhone("mb", wireB, env); !errors.Is(err, ErrAuthenticationFailed) {
		t.Errorf("moved record: %v", err)
	}
}

func TestOpener_Hello(t *testing.T) {
	var fx struct {
		Hello hpkeCase `json:"hello"`
	}
	loadFixture(t, "hpke-envelope.json", &fx)
	ks := newKeySource(t)
	o := NewOpener(ks, newGuard())
	raw := mustHex(t, fx.Hello.Envelope)
	h, f, err := o.Hello("relay", fx.Hello.WireName, raw, linkNonce)
	if err != nil {
		t.Fatalf("kit hello: %v", err)
	}
	if h.Sender != ks.k.deviceID || f.Kind != "hello" || f.ID != fx.Hello.WireName {
		t.Errorf("hello %+v %+v", h, f)
	}
	if _, _, err := o.Hello("relay", fx.Hello.WireName, raw, metaKey); !errors.Is(err, ErrAuthenticationFailed) {
		t.Errorf("another code's nonce: %v", err)
	}
	if _, _, err := o.Hello("relay", "x"+fx.Hello.WireName, raw, linkNonce); !errors.Is(err, ErrNameMismatch) {
		t.Errorf("not a hello name: %v", err)
	}
	if _, _, err := o.Hello("relay", "hello-00000000-0000-0000-0000-000000000001", raw, linkNonce); !errors.Is(err, ErrWrongSender) {
		t.Errorf("name of another device: %v", err)
	}
	ks.hub = mustID("FFEEDDCC-BBAA-9988-7766-554433221100")
	if _, _, err := o.Hello("relay", fx.Hello.WireName, raw, linkNonce); !errors.Is(err, ErrWrongHub) {
		t.Errorf("another hub: %v", err)
	}
}

var updateGoSealed = flag.Bool("update", false, "rewrite testdata/go-sealed.json")

// goSealedCase is one Go-sealed record the Kit opens
// (GoSealedEnvelopeTests); hex fields, "" asset when the frame has none.
type goSealedCase struct {
	Class       int    `json:"class"`
	Zone        string `json:"zone"`
	WireName    string `json:"wireName"`
	Sender      string `json:"sender"`
	Kind        string `json:"kind"`
	ID          string `json:"id"`
	NotifyLevel string `json:"notifyLevel"`
	Asset       string `json:"asset"`
	Payload     string `json:"payload"`
	Envelope    string `json:"envelope"`
}

type goSealedFile struct {
	Source string                  `json:"source"`
	Epoch  uint32                  `json:"epoch"`
	Cases  map[string]goSealedCase `json:"cases"`
}

const goSealedPath = "testdata/go-sealed.json"

// sealGoVectors seals the four hub classes with the Kit fixture keys through
// the Sealer.
func sealGoVectors(t *testing.T) goSealedFile {
	t.Helper()
	ks := newKeySource(t)
	s := NewSealer(ks)
	dev := ks.k.deviceID
	asset := fixtureAsset(t)
	sealedAsset, _, err := EncryptAsset([]byte("[]"), fixtureHubID, run(0x90, 0xAF), 16)
	if err != nil {
		t.Fatal(err)
	}
	assetPath := filepath.Join(t.TempDir(), "asset.wta")
	if err := os.WriteFile(assetPath, sealedAsset, 0o600); err != nil {
		t.Fatal(err)
	}
	out := goSealedFile{Source: "sealed by internal/hub/secure (go test -run TestWriteGoSealed -update) with the Kit's E2EFixtureKeys", Epoch: 1,
		Cases: map[string]goSealedCase{}}
	add := func(name string, c EnvelopeClass, r Record, err error, f InnerFrame, zone string, sender ID) {
		t.Helper()
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		gc := goSealedCase{Class: int(c), Zone: zone, WireName: r.WireName(), Sender: sender.String(), Kind: f.Kind, ID: f.ID,
			NotifyLevel: f.NotifyLevel, Payload: hex.EncodeToString(f.Payload), Envelope: hex.EncodeToString(r.Envelope())}
		if f.Asset != nil {
			gc.Asset = hex.EncodeToString(f.Asset.Encode())
		}
		out.Cases[name] = gc
	}
	dataFrame := InnerFrame{Kind: "meeting_transcript", ID: "meeting_transcript-9", NotifyLevel: "urgent", Asset: asset, Payload: []byte(`{"title":"Acme sync"}`)}
	r, err := s.Data("DataZone", dataFrame.ID, dataFrame.NotifyLevel, dataFrame.Payload, asset, assetPath)
	add("data", ClassData, r, err, dataFrame, "DataZone", fixtureHubID)

	alertFrame := InnerFrame{Kind: "ask_alert", ID: "ask_alert-42", Payload: []byte(`{"ask_id":42,"title":"Acme"}`)}
	r, err = s.Alert("DataZone", alertFrame.ID, alertFrame.Payload)
	add("alert", ClassAlert, r, err, alertFrame, "DataZone", fixtureHubID)

	echoFrame := InnerFrame{Kind: "action", ID: "a-" + dev.String() + "-1", Payload: []byte(`{"status":"applied"}`)}
	wire, err := s.WireName(ZoneRelay, echoFrame.ID)
	if err != nil {
		t.Fatal(err)
	}
	r, err = s.ToPhone("RelayZone", dev, wire, echoFrame.Kind, echoFrame.ID, echoFrame.Payload)
	add("relayToPhone", ClassRelayToPhone, r, err, echoFrame, "RelayZone", fixtureHubID)

	boxFrame := InnerFrame{Kind: "device_grant", ID: "device_grant-" + dev.String(), Payload: []byte(`{"grant":{"device_id":"` + dev.String() + `"}}`)}
	r, err = s.Keybox("DataZone", dev, boxFrame.Payload)
	add("keybox", ClassKeybox, r, err, boxFrame, "DataZone", fixtureHubID)
	return out
}

// TestWriteGoSealed writes the Go→Kit vectors with -update; without it, the
// stored envelopes must still open in Go and carry what the sealer would
// write now (envelopes are randomized, so they are opened, never compared).
func TestWriteGoSealed(t *testing.T) {
	want := sealGoVectors(t)
	if *updateGoSealed {
		raw, err := json.MarshalIndent(want, "", "  ")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(goSealedPath, append(raw, '\n'), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	raw, err := os.ReadFile(goSealedPath)
	if err != nil {
		t.Fatalf("%v (run with -update)", err)
	}
	var got goSealedFile
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Cases) != len(want.Cases) || got.Epoch != want.Epoch {
		t.Fatalf("stored %d cases, want %d", len(got.Cases), len(want.Cases))
	}
	k := fixtureKeys(t)
	hubSigPub := k.hubSig.Public().(ed25519.PublicKey)
	h2p := relayKey(t, k, HubToPhone, 1)
	zones := map[string]Zone{"DataZone": ZoneData, "RelayZone": ZoneRelay}
	for name, w := range want.Cases {
		c, ok := got.Cases[name]
		if !ok {
			t.Fatalf("case %s missing", name)
		}
		stale := c
		stale.Envelope = w.Envelope
		if stale != w {
			t.Errorf("%s: stored metadata %+v, sealer writes %+v (run with -update)", name, c, w)
			continue
		}
		ctx := Context{Zone: zones[c.Zone], WireName: c.WireName}
		env := mustHex(t, c.Envelope)
		var (
			h   Header
			f   InnerFrame
			err error
		)
		switch EnvelopeClass(c.Class) {
		case ClassData:
			h, f, err = OpenSymmetric(env, []EnvelopeClass{ClassData}, ctx, hubSigPub, func(Header) ([]byte, error) { return dataKey, nil })
		case ClassAlert:
			h, f, err = OpenSymmetric(env, []EnvelopeClass{ClassAlert}, ctx, hubSigPub, func(Header) ([]byte, error) { return alertKey, nil })
		case ClassRelayToPhone:
			h, f, err = OpenSymmetric(env, []EnvelopeClass{ClassRelayToPhone}, ctx, nil, func(Header) ([]byte, error) { return h2p, nil })
		case ClassKeybox:
			h, f, err = OpenHPKE(env, ClassKeybox, k.devKX, KeyboxInfo(fixtureHubID, k.deviceID), ctx, hubSigPub)
		default:
			t.Fatalf("%s: class %d", name, c.Class)
		}
		if err != nil {
			t.Errorf("%s: open: %v", name, err)
			continue
		}
		assetHex := ""
		if f.Asset != nil {
			assetHex = hex.EncodeToString(f.Asset.Encode())
		}
		if f.Kind != c.Kind || f.ID != c.ID || f.NotifyLevel != c.NotifyLevel || hex.EncodeToString(f.Payload) != c.Payload || assetHex != c.Asset ||
			h.Hub != fixtureHubID || h.Sender.String() != c.Sender || h.Epoch != 1 {
			t.Errorf("%s: opened %+v %+v", name, h, f)
		}
	}
}

func TestSealer_RefusesUnknownKinds(t *testing.T) {
	ks := newKeySource(t)
	s := NewSealer(ks)
	if _, err := s.Data("dz", "targte-7", "", []byte(`{}`), nil, ""); !errors.Is(err, ErrUnknownKind) {
		t.Errorf("typo data kind: %v", err)
	}
	plain := "a-" + ks.k.deviceID.String() + "-1"
	wire, _ := s.WireName(ZoneRelay, plain)
	if _, err := s.ToPhone("mb", ks.k.deviceID, wire, "acton", plain, []byte(`{}`)); !errors.Is(err, ErrUnknownKind) {
		t.Errorf("typo relay kind: %v", err)
	}
	for _, kind := range []string{"heartbeat", "owner_ask", "session_chat", "meeting_transcript"} {
		if _, err := s.Data("dz", kind+"-1", "", []byte(`{}`), nil, ""); err != nil {
			t.Errorf("%s refused: %v", kind, err)
		}
	}
}

func TestOpener_MetaKeyFailureSurfaces(t *testing.T) {
	ks := newKeySource(t)
	o := NewOpener(ks, newGuard())
	wire, env := phoneAction(t, ks, "a-"+ks.k.deviceID.String()+"-1", 1, 5, fixtureHubID, ks.k.deviceID)
	locked := errors.New("keyring locked")
	ks.metaErr = locked
	_, err := o.FromPhone("mb", wire, env)
	if !errors.Is(err, locked) || errors.Is(err, ErrNameMismatch) {
		t.Errorf("locked keyring: %v, want the keyring's error", err)
	}
}
