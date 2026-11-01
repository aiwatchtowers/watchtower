package cloudkit_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"

	"watchtower/internal/hub/actions"
	"watchtower/internal/hub/hubtest"
	"watchtower/internal/hub/secure"
	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/cloudkit"
	pb "watchtower/internal/hub/transport/cloudkit/bridgepb"
	"watchtower/internal/hub/wire"
	"watchtower/internal/logcanary"
)

// canaryEncodings is each marker as itself and as the protocol encodes bytes
// elsewhere (std and URL-safe base64, hex).
func canaryEncodings(markers []string) []string {
	out := append([]string(nil), markers...)
	for _, m := range markers {
		out = append(out, base64.StdEncoding.EncodeToString([]byte(m)),
			base64.RawURLEncoding.EncodeToString([]byte(m)), hex.EncodeToString([]byte(m)))
	}
	return out
}

// canary is the world of TestBridgeFramesCarryNoPlaintext: the rig, a linked
// phone, the markers and where each was sealed.
type canary struct {
	*rig
	phone    *hubtest.Phone
	epoch    uint32
	keys     wire.KeyboxKeys
	markers  []string
	sealedAt map[string]string // marker → the plain id of the data record it was sealed in
	saved    int               // hub records saved
	assets   []*secure.AssetDescriptor
	sealed   [][]byte // sealed asset bytes (a prefix of each)

	mGrant, mControl, cID string
}

func newCanary(t *testing.T) *canary {
	t.Helper()
	r := newRig(t)
	meta, err := r.kr.MetaKey()
	if err != nil {
		t.Fatal(err)
	}
	epoch, err := r.kr.CurrentEpoch()
	if err != nil {
		t.Fatal(err)
	}
	keys, err := r.kr.KeyboxKeys()
	if err != nil {
		t.Fatal(err)
	}
	phone, err := hubtest.New(hubtest.Config{
		Hub: r.kr.HubID(), HubKX: r.ident.Agreement.PublicKey(), HubSig: r.ident.Signing.Public().(ed25519.PublicKey),
		MetaKey: meta, Epoch: epoch, HubRelayID: relayID, Transport: r.fake.PhoneRecords(r.hub),
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := r.st.WithTx(r.ctx, func(tx *sql.Tx) error { return state.LinkDevice(tx, phone.Device()) }); err != nil {
		t.Fatal(err)
	}
	return &canary{rig: r, phone: phone, epoch: epoch, keys: keys, sealedAt: map[string]string{}}
}

func (c *canary) mark(field string) string {
	m := logcanary.Text(field)
	c.markers = append(c.markers, m)
	return m
}

func canaryText(m string) []byte { b, _ := json.Marshal(map[string]string{"text": m}); return b }

// sealData seals a data record whose payload carries a marker.
func (c *canary) sealData(plain, field string, asset *secure.AssetDescriptor, assetPath string) transport.SaveItem {
	c.t.Helper()
	m := c.mark(field)
	rec, err := c.sealer.Data(dataZone, plain, "", canaryText(m), asset, assetPath)
	if err != nil {
		c.t.Fatalf("%s: %v", plain, err)
	}
	c.sealedAt[m] = plain
	return transport.SaveItem{Record: rec}
}

// saveHubRecords saves a record of every slice kind, an alert and its
// signal, the phone's keybox, a transcript with its sealed asset, and a hub
// control (transport_switched with a keybox inside) to the phone.
func (c *canary) saveHubRecords() {
	t := c.t
	var items []transport.SaveItem
	// Every slice kind the publisher has: the keybox and the alert below,
	// the heartbeat under its plain name, every other kind as <kind>-1.
	for _, k := range hubslices.AllKinds {
		switch k {
		case hubslices.KindDeviceGrant, hubslices.KindAskAlert:
		case hubslices.KindHeartbeat:
			items = append(items, c.sealData(string(k), "slice."+string(k), nil, ""))
		default:
			items = append(items, c.sealData(string(k)+"-1", "slice."+string(k), nil, ""))
		}
	}
	mAlert := c.mark("ask_alert")
	alert, err := c.sealer.Alert(dataZone, "ask_alert-1", canaryText(mAlert))
	if err != nil {
		t.Fatal(err)
	}
	c.sealedAt[mAlert] = "ask_alert-1"
	sig, err := c.sealer.Signal(alert)
	if err != nil {
		t.Fatal(err)
	}
	c.mGrant = c.mark("grant.name")
	kbPayload, err := wire.Marshal(wire.Keybox{Grant: wire.DeviceGrant{DeviceID: c.phone.ID().String(), HubID: c.hub, Name: c.mGrant, Linked: true}, Keys: &c.keys})
	if err != nil {
		t.Fatal(err)
	}
	kb, err := c.sealer.Keybox(dataZone, c.phone.ID(), kbPayload)
	if err != nil {
		t.Fatal(err)
	}
	assetPath := filepath.Join(c.dir, cloudkit.AssetsDirName, "transcripts", "t1.asset")
	d := sealedAsset(t, bytes.Repeat([]byte(c.mark("transcript.text")+" "), 4000), assetPath)
	c.assets, c.sealed = append(c.assets, d), append(c.sealed, mustRead(t, assetPath)[:512])
	transcript := c.sealData("meeting_transcript-2", "transcript.title", d, assetPath)
	transcript.Expect = transport.Expect{Mode: transport.ExpectAbsent}
	items = append(items, transport.SaveItem{Record: alert}, transport.SaveItem{Record: sig}, transport.SaveItem{Record: kb}, transcript)

	c.mControl, c.cID = c.mark("control.reason"), "0F0E0D0C-0000-4000-8000-000000000001"
	cPayload, err := wire.Marshal(wire.Control{ID: c.cID, Kind: wire.ControlSwitched, Reason: &c.mControl,
		Keybox: &wire.Keybox{Grant: wire.DeviceGrant{DeviceID: c.phone.ID().String(), Name: c.mControl}, Keys: &c.keys}})
	if err != nil {
		t.Fatal(err)
	}
	cName, err := c.sealer.WireName(secure.ZoneRelay, "c-"+c.cID)
	if err != nil {
		t.Fatal(err)
	}
	ctl, err := c.sealer.ToPhone("relay/"+relayID+"/"+c.phone.RelayDeviceID(), c.phone.ID(), cName, "control", "c-"+c.cID, cPayload)
	if err != nil {
		t.Fatal(err)
	}
	items = append(items, transport.SaveItem{Record: ctl, Expect: transport.Expect{Mode: transport.ExpectAbsent}})
	for i, o := range c.save(items...) {
		if !o.Saved {
			t.Fatalf("item %d: %+v", i, o)
		}
	}
	c.saved = len(items)
}

// phoneTraffic has the phone send an ordered action and a recording, both
// carrying markers, and runs the real processor over the client until the
// phone holds both echoes: its mailbox read, the echoes written, the upload
// downloaded through <hub dir>/downloads and opened by the intake.
func (c *canary) phoneTraffic() {
	t := c.t
	mAction, mRecording, mUpload := c.mark("action.text"), c.mark("recording.audio"), c.mark("upload.title")
	audio := bytes.Repeat([]byte(mRecording+" "), 3000)
	var mu sync.Mutex
	var applied []string
	var heard []byte
	disp := actions.NewDispatcher()
	disp.Register("test_note", func(_ context.Context, q actions.Request) actions.Outcome {
		var s string
		_ = json.Unmarshal(q.Action.Params["text"], &s)
		mu.Lock()
		applied = append(applied, s)
		mu.Unlock()
		return actions.Outcome{Status: wire.StatusApplied}
	}, actions.KindOptions{})
	disp.SetRecordings(func(ctx context.Context, in actions.RecordingIntake) actions.RecordingOutcome {
		dst := filepath.Join(t.TempDir(), "u1.sealed")
		if err := in.Download(ctx, dst); err != nil {
			t.Errorf("download: %v", err)
			return actions.RecordingOutcome{Status: wire.StatusFailed}
		}
		plain, err := secure.DecryptAsset(mustRead(t, dst), *in.Descriptor)
		if err != nil {
			t.Errorf("decrypt: %v", err)
		}
		mu.Lock()
		heard = plain
		mu.Unlock()
		return actions.RecordingOutcome{Status: wire.StatusReceived}
	}, nil)
	proc := actions.NewProcessor(actions.Config{
		Store: c.st, Transport: c.c, Sealer: c.sealer, Opener: secure.NewOpener(c.kr, c.kr), Keys: c.kr,
		Dispatcher: disp, HubRelayID: relayID,
	})
	a := c.phone.NewAction("test_note")
	a.Params["text"], _ = json.Marshal(mAction)
	seq, err := c.phone.Queue(a)
	if err != nil {
		t.Fatal(err)
	}
	if err := c.phone.Send(seq); err != nil {
		t.Fatal(err)
	}
	sealedAudio, aDesc, err := secure.EncryptAsset(audio, secure.ID{7}, bytes.Repeat([]byte{9}, 32), 1024)
	if err != nil {
		t.Fatal(err)
	}
	c.assets, c.sealed = append(c.assets, &aDesc), append(c.sealed, sealedAudio[:512])
	upload, _ := json.Marshal(map[string]any{"id": "u1", "status": "pending", "device_id": c.phone.ID().String(), "title": mUpload})
	if _, err := c.phone.WriteUpload("u1", upload, &aDesc, sealedAudio); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(15 * time.Second)
	for c.phone.Echoes[seq].Status != wire.StatusApplied || c.phone.UploadEchoes["u1"]["status"] != wire.StatusReceived {
		if time.Now().After(deadline) {
			t.Fatalf("echo %q, upload %v", c.phone.Echoes[seq].Status, c.phone.UploadEchoes["u1"])
		}
		if _, err := proc.Pass(c.ctx); err != nil {
			t.Fatalf("pass: %v", err)
		}
		if _, err := c.phone.Sync(); err != nil {
			t.Fatal(err)
		}
	}
	mu.Lock()
	defer mu.Unlock()
	if len(applied) != 1 || applied[0] != mAction {
		t.Errorf("the action was applied as %q", applied)
	}
	if !bytes.Equal(heard, audio) {
		t.Error("the recording did not open for the intake")
	}
}

// assertPhoneOpensEverything: the positive controls — each data marker
// opens from its record, the keybox and the control open on the phone.
func (c *canary) assertPhoneOpensEverything() {
	t := c.t
	opened, err := c.phone.OpenData(dataZone)
	if err != nil {
		t.Fatal(err)
	}
	found := map[string]bool{}
	for _, d := range opened {
		for m, plain := range c.sealedAt {
			found[m] = found[m] || d.Frame.ID == plain && bytes.Contains(d.Frame.Payload, []byte(m))
		}
	}
	for m := range c.sealedAt {
		if !found[m] {
			t.Errorf("marker %s did not open from the data zone", m)
		}
	}
	if kb, ok, err := c.phone.ReadKeybox(dataZone); err != nil || !ok || kb.Grant.Name != c.mGrant {
		t.Errorf("keybox: %v %v", ok, err)
	}
	saw := false
	for _, ctl := range c.phone.Controls {
		saw = saw || ctl.ID == c.cID && ctl.Reason != nil && *ctl.Reason == c.mControl
	}
	if !saw {
		t.Error("the phone did not open the hub's control")
	}
}

// assertSocketClean: no frame, either way, carries a marker in any encoding,
// a key the hub holds or asset bytes; every envelope is padded and sealed.
func (c *canary) assertSocketClean() {
	t := c.t
	secrets := hubSecrets(t, c.rig, c.phone.ID(), c.epoch, c.assets...)
	enc := canaryEncodings(c.markers)
	frames, answers := c.fake.Frames(), c.fake.Answers()
	if len(frames) < 5 || len(answers) < 5 {
		t.Fatalf("%d frames, %d answers", len(frames), len(answers))
	}
	for dir, list := range map[string][][]byte{"to the bridge": frames, "from the bridge": answers} {
		for i, f := range list {
			for _, m := range enc {
				if bytes.Contains(f, []byte(m)) {
					t.Errorf("frame %d %s carries %q", i, dir, m)
				}
			}
			for name, k := range secrets {
				if bytes.Contains(f, k) {
					t.Errorf("frame %d %s carries the %s", i, dir, name)
				}
			}
			for _, b := range c.sealed {
				if bytes.Contains(f, b) {
					t.Errorf("frame %d %s carries asset bytes", i, dir)
				}
			}
		}
	}
	envelopes := 0
	for i, f := range frames {
		var q pb.Request
		if err := proto.Unmarshal(f, &q); err != nil {
			t.Fatalf("frame %d: %v", i, err)
		}
		envelopes += checkEnvelopes(t, "request", i, q.ProtoReflect())
	}
	for i, f := range answers {
		var a pb.Response
		if err := proto.Unmarshal(f, &a); err != nil {
			t.Fatalf("answer %d: %v", i, err)
		}
		envelopes += checkEnvelopes(t, "answer", i, a.ProtoReflect())
	}
	if envelopes < c.saved {
		t.Fatalf("only %d envelopes checked", envelopes)
	}
}

// TestBridgeFramesCarryNoPlaintext (Review Focus 5): every slice kind, an
// alert and its signal, a keybox, a hub asset, a hub control, a phone's
// ordered action and its echo and a phone's recording cross the socket, each
// carrying a canary marker. The phone opens every one — proof the marker
// reached the sealer and crossed — yet no frame in either direction carries
// a marker (in any encoding), a key the hub holds or asset bytes; every
// envelope on the socket is a padded sealed envelope, every other field
// protocol metadata; the log stays clean.
func TestBridgeFramesCarryNoPlaintext(t *testing.T) {
	sink := logcanary.Capture(t)
	c := newCanary(t)
	c.saveHubRecords()
	c.phoneTraffic()
	c.assertPhoneOpensEverything()
	c.assertSocketClean()
	sink.AssertClean(t)
}

// checkEnvelopes walks every field of m: each envelope is a padded sealed
// envelope (a sig- record's is empty), each string a protocol value that
// carries no canary, and no unknown field slipped in. It returns the
// envelopes it checked.
func checkEnvelopes(t *testing.T, side string, i int, m protoreflect.Message) int {
	t.Helper()
	if len(m.GetUnknown()) != 0 {
		t.Errorf("%s %d carries unknown fields", side, i)
	}
	n := 0
	var name string
	if f := m.Descriptor().Fields().ByName("name"); f != nil && f.Kind() == protoreflect.StringKind {
		name = m.Get(f).String()
	}
	m.Range(func(fd protoreflect.FieldDescriptor, v protoreflect.Value) bool {
		switch {
		case fd.IsList() && fd.Kind() == protoreflect.MessageKind:
			l := v.List()
			for j := range l.Len() {
				n += checkEnvelopes(t, side, i, l.Get(j).Message())
			}
		case fd.Kind() == protoreflect.MessageKind:
			n += checkEnvelopes(t, side, i, v.Message())
		case fd.Kind() == protoreflect.BytesKind:
			if fd.Name() != "envelope" {
				t.Errorf("%s %d: bytes field %s", side, i, fd.Name())
				break
			}
			env := v.Bytes()
			if strings.HasPrefix(name, secure.SignalPrefix) && len(env) == 0 {
				break
			}
			h, err := secure.ParseHeader(env)
			if err != nil {
				t.Errorf("%s %d: %s is not an envelope", side, i, name)
				break
			}
			if h.Flags&secure.FlagPadded == 0 {
				t.Errorf("%s %d: %s (class %d) is not padded", side, i, name, h.Class)
			}
			n++
		case fd.Kind() == protoreflect.StringKind:
			if strings.Contains(v.String(), logcanary.Marker) {
				t.Errorf("%s %d: %s carries a canary", side, i, fd.Name())
			}
		}
		return true
	})
	return n
}

// hubSecrets is every key the hub holds for this test's records.
func hubSecrets(t *testing.T, r *rig, phone secure.ID, epoch uint32, assets ...*secure.AssetDescriptor) map[string][]byte {
	t.Helper()
	out := map[string][]byte{}
	add := func(name string, b []byte, err error) {
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		out[name] = b
	}
	k, err := r.kr.DataKey(epoch)
	add("data key", k, err)
	k, err = r.kr.AlertKey(epoch)
	add("alert key", k, err)
	k, err = r.kr.MetaKey()
	add("meta key", k, err)
	k, err = r.kr.RelayKey(secure.HubToPhone, phone, epoch)
	add("hub-to-phone key", k, err)
	k, err = r.kr.RelayKey(secure.PhoneToHub, phone, epoch)
	add("phone-to-hub key", k, err)
	out["signing seed"] = r.ident.Signing.Seed()
	out["agreement key"] = r.ident.Agreement.Bytes()
	for i, d := range assets {
		out["asset key "+string(rune('0'+i))] = bytes.Clone(d.Key[:])
	}
	return out
}

func mustRead(t *testing.T, p string) []byte {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return b
}
