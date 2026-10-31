package relay

import (
	"bytes"
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay/client"
	"watchtower/internal/hub/transport/relay/relayv1"
)

// testKeys is a throwaway KeySource: the relay never opens an envelope, so
// only the Sealer needs it.
type testKeys struct {
	sig        ed25519.PrivateKey
	kx         *ecdh.PrivateKey
	data, meta []byte
	seq        uint64
}

func newTestKeys(t *testing.T) *testKeys {
	t.Helper()
	_, sig, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	kx, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	k := &testKeys{sig: sig, kx: kx, data: make([]byte, 32), meta: make([]byte, 32)}
	_, _ = rand.Read(k.data)
	_, _ = rand.Read(k.meta)
	return k
}

func (k *testKeys) HubID() secure.ID                   { return secure.ID{0xa, 0xb} }
func (k *testKeys) CurrentEpoch() (uint32, error)      { return 1, nil }
func (k *testKeys) NextSeq() (uint64, error)           { k.seq++; return k.seq, nil }
func (k *testKeys) DataKey(uint32) ([]byte, error)     { return bytes.Clone(k.data), nil }
func (k *testKeys) AlertKey(uint32) ([]byte, error)    { return bytes.Clone(k.data), nil }
func (k *testKeys) MetaKey() ([]byte, error)           { return bytes.Clone(k.meta), nil }
func (k *testKeys) RelayDevices() ([]secure.ID, error) { return nil, nil }
func (k *testKeys) Signer() ed25519.PrivateKey         { return k.sig }
func (k *testKeys) Agreement() *ecdh.PrivateKey        { return k.kx }
func (k *testKeys) AcceptsRelayEpoch(uint32, secure.ID) (bool, error) {
	return false, nil
}
func (k *testKeys) RelayKey(secure.Direction, secure.ID, uint32) ([]byte, error) {
	return nil, errors.New("no relay keys")
}
func (k *testKeys) KeyboxRecipient(secure.ID) (*ecdh.PublicKey, error) {
	return nil, errors.New("no devices")
}

// harness is one hub's transport over a fake relay.
type harness struct {
	relay    *fakeRelay
	store    *state.Store
	sealer   *secure.Sealer
	key      ed25519.PrivateKey
	assetDir string
	tr       *Transport
	data     string // the hub's data zone
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	st, err := state.Open(filepath.Join(t.TempDir(), "hub"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	h := &harness{relay: newFakeRelay(t), store: st, sealer: secure.NewSealer(newTestKeys(t)), key: key, assetDir: t.TempDir()}
	h.tr = h.newTransport(t)
	h.data = transport.DataZone(h.tr.c.DeviceID())
	return h
}

// newTransport builds another transport of the same hub (same key, store).
func (h *harness) newTransport(t *testing.T) *Transport {
	t.Helper()
	c := NewClient(h.relay.URL, h.key)
	tr := New(c, Options{
		Origin: h.relay.URL, HubRelayID: c.DeviceID(), Store: h.store, AssetDir: h.assetDir,
		Clock: func() time.Time { return time.UnixMilli(1_700_000_000_000) },
	})
	t.Cleanup(func() { _ = tr.Close() })
	return tr
}

func (h *harness) seal(t *testing.T, plain, payload string) secure.Record {
	t.Helper()
	r, err := h.sealer.Data(h.data, plain, "", []byte(payload), nil, "")
	if err != nil {
		t.Fatal(err)
	}
	return r
}

// sealAsset seals an asset file into dir and a record that carries it.
func (h *harness) sealAsset(t *testing.T, dir, zone string) (secure.Record, string) {
	t.Helper()
	src, sealedPath := filepath.Join(t.TempDir(), "plain"), filepath.Join(dir, "sealed-asset")
	if err := os.WriteFile(src, bytes.Repeat([]byte("ab"), 1000), 0o600); err != nil {
		t.Fatal(err)
	}
	d, err := secure.EncryptAssetFile(src, sealedPath, secure.ID{1})
	if err != nil {
		t.Fatal(err)
	}
	r, err := h.sealer.Data(zone, "session_report-1", "", []byte(`{}`), &d, sealedPath)
	if err != nil {
		t.Fatal(err)
	}
	return r, sealedPath
}

// nextEvent waits for the next transport event.
func nextEvent(t *testing.T, tr *Transport) transport.Event {
	t.Helper()
	select {
	case ev := <-tr.Events():
		return ev
	case <-time.After(5 * time.Second):
		t.Fatal("no event")
		return transport.Event{}
	}
}

// waitZoneEvent waits for a zone event of zone, skipping others.
func waitZoneEvent(t *testing.T, tr *Transport, zone string) {
	t.Helper()
	deadline := time.After(5 * time.Second)
	for {
		select {
		case ev := <-tr.Events():
			if ev.Zone == zone && ev.Err == nil {
				return
			}
		case <-deadline:
			t.Fatalf("no zone event for %s", zone)
		}
	}
}

func TestRelayTransport_RefusesUnsealedRecord(t *testing.T) {
	h := newHarness(t)
	before := h.relay.hits.Load()
	items := []transport.SaveItem{{Record: h.seal(t, "target-1", `{}`)}, {Record: secure.Record{}}}
	if _, err := h.tr.Save(t.Context(), items); !errors.Is(err, secure.ErrUnsealed) {
		t.Fatalf("save: %v, want ErrUnsealed", err)
	}
	if n := h.relay.hits.Load() - before; n != 0 {
		t.Fatalf("%d requests reached the relay", n)
	}
}

func TestRelayTransport_SaveConditionalOutcomes(t *testing.T) {
	h := newHarness(t)
	ctx := t.Context()
	a, b := h.seal(t, "target-1", `{"a":1}`), h.seal(t, "target-2", `{"b":1}`)
	out, err := h.tr.Save(ctx, []transport.SaveItem{{Record: a, Expect: transport.Expect{Mode: transport.ExpectAbsent}}, {Record: b}})
	if err != nil || len(out) != 2 || !out[0].Saved || !out[1].Saved || out[0].RecordSeq != 1 || out[1].RecordSeq != 2 {
		t.Fatalf("first save: %+v, %v", out, err)
	}
	saved := h.relay.requests("save")[0].GetSave().GetItems()
	if saved[0].GetMustNotExist() != true || saved[1].GetExpect() != nil || saved[0].GetRecord().GetClientModifiedAtMs() != 1_700_000_000_000 {
		t.Fatalf("wire items: %v", saved)
	}
	if !bytes.Equal(saved[0].GetRecord().GetEnvelope(), a.Envelope()) || saved[0].GetRecord().GetName() != a.WireName() {
		t.Fatal("the sealed envelope did not go out as is")
	}
	// Second round: item 0 conflicts (absent expected), item 1 is written at its seq.
	out, err = h.tr.Save(ctx, []transport.SaveItem{
		{Record: a, Expect: transport.Expect{Mode: transport.ExpectAbsent}},
		{Record: b, Expect: transport.Expect{Mode: transport.ExpectSeq, Seq: 2}},
	})
	if err != nil || len(out) != 2 {
		t.Fatalf("second save: %+v, %v", out, err)
	}
	if out[0].Saved || out[0].Refused != nil || out[0].Conflict == nil || out[0].Conflict.RecordSeq != 1 ||
		!bytes.Equal(out[0].Conflict.Envelope, a.Envelope()) {
		t.Fatalf("conflict outcome: %+v", out[0])
	}
	if !out[1].Saved || out[1].RecordSeq != 3 {
		t.Fatalf("conditional write: %+v", out[1])
	}
	dout, err := h.tr.Delete(ctx, h.data, []transport.DeleteItem{
		{Name: a.WireName(), Expect: transport.Expect{Mode: transport.ExpectSeq, Seq: 9}},
		{Name: b.WireName()},
	})
	if err != nil || len(dout) != 2 || dout[0].Saved || dout[0].Conflict == nil || !dout[1].Saved {
		t.Fatalf("delete: %+v, %v", dout, err)
	}
	if _, err := h.tr.Delete(ctx, h.data, []transport.DeleteItem{{Name: "x", Expect: transport.Expect{Mode: transport.ExpectAbsent}}}); err == nil {
		t.Fatal("a delete expecting absence was sent")
	}
}

func TestRelayTransport_ZoneTokensPersist(t *testing.T) {
	h := newHarness(t)
	ctx := t.Context()
	for i := range 3 {
		h.relay.put(h.data, fmt.Sprintf("n%d", i), []byte{byte(i)})
	}
	h.relay.pageLimit = 2
	var got []string
	apply := func(b transport.Batch) error {
		for _, s := range b.Changed {
			got = append(got, s.Name)
		}
		return nil
	}
	if err := h.tr.Pull(ctx, h.data, apply); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(got, []string{"n0", "n1", "n2"}) {
		t.Fatalf("pulled %v", got)
	}
	if tok, err := h.store.ZoneToken(h.data); err != nil || tok != 3 {
		t.Fatalf("stored token %d, %v", tok, err)
	}
	// A failed apply keeps the token where it was.
	h.relay.put(h.data, "n3", []byte{3})
	if err := h.tr.Pull(ctx, h.data, func(transport.Batch) error { return errors.New("boom") }); err == nil {
		t.Fatal("apply error swallowed")
	}
	if tok, _ := h.store.ZoneToken(h.data); tok != 3 {
		t.Fatalf("token moved past an unapplied page: %d", tok)
	}
	// A new transport over the same sidecar resumes from the stored token.
	got = nil
	if err := h.newTransport(t).Pull(ctx, h.data, apply); err != nil {
		t.Fatal(err)
	}
	reqs := h.relay.requests("changes")
	if last := reqs[len(reqs)-1].GetChanges(); last.GetSinceSeq() != 3 || !slices.Equal(got, []string{"n3"}) {
		t.Fatalf("resumed from %d, got %v", last.GetSinceSeq(), got)
	}
	if tok, _ := h.store.ZoneToken(h.data); tok != 4 {
		t.Fatalf("stored token %d", tok)
	}
}

func TestRelayTransport_TokenExpiredResetsZoneToZero(t *testing.T) {
	h := newHarness(t)
	ctx := t.Context()
	h.relay.put(h.data, "n0", []byte{0})
	if err := h.store.SetZoneToken(h.data, 7); err != nil {
		t.Fatal(err)
	}
	if _, err := h.tr.Changes(ctx, h.data, 7); !errors.Is(err, transport.ErrTokenExpired) {
		t.Fatalf("changes: %v", err)
	}
	if tok, err := h.store.ZoneToken(h.data); err != nil || tok != 0 {
		t.Fatalf("token after TOKEN_EXPIRED: %d, %v", tok, err)
	}
	// Pull: the stored token expires again, the zone is pulled from 0.
	if err := h.store.SetZoneToken(h.data, 7); err != nil {
		t.Fatal(err)
	}
	var got []string
	var resets []bool
	if err := h.tr.Pull(ctx, h.data, func(b transport.Batch) error {
		resets = append(resets, b.Reset)
		for _, s := range b.Changed {
			got = append(got, s.Name)
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	var sinces []uint64
	for _, r := range h.relay.requests("changes") {
		sinces = append(sinces, r.GetChanges().GetSinceSeq())
	}
	if !slices.Equal(resets, []bool{true}) {
		t.Fatalf("Reset flags %v, want the resync page marked", resets)
	}
	if !slices.Equal(sinces, []uint64{7, 7, 0}) || !slices.Equal(got, []string{"n0"}) {
		t.Fatalf("since sequence %v, got %v", sinces, got)
	}
	if tok, _ := h.store.ZoneToken(h.data); tok != 1 {
		t.Fatalf("token after resync: %d", tok)
	}
}

func TestRelayTransport_SaveErrorRereadsZone(t *testing.T) {
	h := newHarness(t)
	box := transport.MailboxZone(h.tr.c.DeviceID(), "phone1")
	h.relay.failNext("save", relayv1.ErrorCode_ERROR_CODE_HUB_QUOTA_EXCEEDED)
	r2, err := h.sealer.Data(box, "target-2", "", []byte(`{}`), nil, "")
	if err != nil {
		t.Fatal(err)
	}
	_, err = h.tr.Save(t.Context(), []transport.SaveItem{{Record: h.seal(t, "target-1", `{}`)}, {Record: r2}})
	if !errors.Is(err, transport.ErrHubQuota) {
		t.Fatalf("save: %v", err)
	}
	seen := map[string]bool{}
	for range 2 {
		ev := nextEvent(t, h.tr)
		seen[ev.Zone] = true
	}
	if !seen[h.data] || !seen[box] {
		t.Fatalf("re-read events: %v", seen)
	}
}

func TestRelayTransport_ErrorMapping(t *testing.T) {
	pe := func(c relayv1.ErrorCode) error { return &client.Error{E: &relayv1.Error{Code: c}} }
	cases := []struct {
		code relayv1.ErrorCode
		want error
	}{
		{relayv1.ErrorCode_ERROR_CODE_HUB_QUOTA_EXCEEDED, transport.ErrHubQuota},
		{relayv1.ErrorCode_ERROR_CODE_MAILBOX_QUOTA_EXCEEDED, transport.ErrMailboxQuota},
		{relayv1.ErrorCode_ERROR_CODE_ENTITLEMENT_INACTIVE, transport.ErrEntitlementInactive},
		{relayv1.ErrorCode_ERROR_CODE_FORBIDDEN, transport.ErrForbidden},
		{relayv1.ErrorCode_ERROR_CODE_UNAUTHENTICATED, transport.ErrForbidden},
		{relayv1.ErrorCode_ERROR_CODE_TOKEN_EXPIRED, transport.ErrTokenExpired},
		{relayv1.ErrorCode_ERROR_CODE_UNSUPPORTED_VERSION, transport.ErrUnsupportedVersion},
		{relayv1.ErrorCode_ERROR_CODE_RECORD_TOO_LARGE, transport.ErrRecordTooLarge},
		{relayv1.ErrorCode_ERROR_CODE_ATTACHMENT_TOO_LARGE, transport.ErrRecordTooLarge},
		{relayv1.ErrorCode_ERROR_CODE_RATE_LIMITED, transport.ErrRateLimited},
		{relayv1.ErrorCode_ERROR_CODE_TRAFFIC_LIMIT_EXCEEDED, transport.ErrRateLimited},
		{relayv1.ErrorCode_ERROR_CODE_UNAVAILABLE, transport.ErrUnavailable},
		{relayv1.ErrorCode_ERROR_CODE_ATTESTATION_REQUIRED, ErrAttestationRequired},
		{relayv1.ErrorCode_ERROR_CODE_ATTESTATION_FAILED, ErrAttestationFailed},
		{relayv1.ErrorCode_ERROR_CODE_SLOT_LIMIT, ErrSlotLimit},
		{relayv1.ErrorCode_ERROR_CODE_SLOT_REPLACEMENT_LIMIT, ErrSlotLimit},
	}
	for _, c := range cases {
		err := MapError(pe(c.code))
		if !errors.Is(err, c.want) || client.Code(err) != c.code {
			t.Errorf("%s: %v, want %v with the code kept", c.code, err, c.want)
		}
	}
	for _, code := range []relayv1.ErrorCode{relayv1.ErrorCode_ERROR_CODE_ATTESTATION_REQUIRED, relayv1.ErrorCode_ERROR_CODE_ATTESTATION_FAILED} {
		if !errors.Is(MapError(pe(code)), transport.ErrForbidden) {
			t.Errorf("%s does not read as forbidden", code)
		}
	}
	unmapped := MapError(pe(relayv1.ErrorCode_ERROR_CODE_PAIRING_EXPIRED))
	if client.Code(unmapped) != relayv1.ErrorCode_ERROR_CODE_PAIRING_EXPIRED || errors.Is(unmapped, transport.ErrUnavailable) {
		t.Errorf("unmapped code: %v", unmapped)
	}
	if err := MapError(client.ErrDisconnected); !errors.Is(err, transport.ErrUnavailable) {
		t.Errorf("disconnected: %v", err)
	}
	if err := MapError(errors.New("dial tcp: refused")); !errors.Is(err, transport.ErrUnavailable) {
		t.Errorf("network: %v", err)
	}
	if err := MapError(client.ErrUnsupportedVersion); !errors.Is(err, transport.ErrUnsupportedVersion) {
		t.Errorf("close 4000: %v", err)
	}
	if err := MapError(context.Canceled); !errors.Is(err, context.Canceled) || errors.Is(err, transport.ErrUnavailable) {
		t.Errorf("canceled: %v", err)
	}
	if MapError(nil) != nil {
		t.Error("nil mapped to an error")
	}
	// Through the transport: an op error comes back mapped.
	h := newHarness(t)
	h.relay.failNext("changes", relayv1.ErrorCode_ERROR_CODE_FORBIDDEN)
	if _, err := h.tr.Changes(t.Context(), h.data, 0); !errors.Is(err, transport.ErrForbidden) {
		t.Errorf("changes forbidden: %v", err)
	}
	h.relay.failNext("set_hub_readers", relayv1.ErrorCode_ERROR_CODE_ENTITLEMENT_INACTIVE)
	if err := h.tr.SetHubReaders(t.Context(), []string{"p"}); !errors.Is(err, transport.ErrEntitlementInactive) {
		t.Errorf("set_hub_readers: %v", err)
	}
}

func TestRelayTransport_ConnectRegistersSubscribesAndPulls(t *testing.T) {
	h := newHarness(t)
	h.relay.account = &relayv1.AccountState{Phones: []*relayv1.SlotHolder{{PhoneDeviceId: "phone1", Paying: true}}}
	box := transport.MailboxZone(h.tr.c.DeviceID(), "phone1")
	if h.tr.Admitted() {
		t.Fatal("admitted before any account state")
	}
	if err := h.tr.Connect(t.Context(), []string{h.data, box}); err != nil {
		t.Fatal(err)
	}
	reg := h.relay.requests("register")
	if len(reg) != 1 || reg[0].GetRegister().GetDeviceKind() != relayv1.DeviceKind_DEVICE_KIND_MAC || reg[0].GetRegister().GetAttestation() != nil {
		t.Fatalf("register: %v", reg)
	}
	seen := map[string]bool{}
	for range 2 {
		seen[nextEvent(t, h.tr).Zone] = true
	}
	if !seen[h.data] || !seen[box] {
		t.Fatalf("initial pulls: %v", seen)
	}
	if !h.tr.Admitted() || len(h.relay.requests("get_account_state")) != 1 {
		t.Fatal("account state not read at connect")
	}
	if !slices.Contains(h.relay.opsSeen(), "ws:subscribe") {
		t.Fatalf("no subscribe: %v", h.relay.opsSeen())
	}
	if err := h.tr.Connect(t.Context(), nil); err == nil {
		t.Fatal("a second Connect was accepted")
	}
}

func TestRelayTransport_ConnectRefusesOtherHubID(t *testing.T) {
	h := newHarness(t)
	tr := New(NewClient(h.relay.URL, h.key), Options{Origin: h.relay.URL, HubRelayID: "other", Store: h.store})
	t.Cleanup(func() { _ = tr.Close() })
	if err := tr.Connect(t.Context(), []string{h.data}); err == nil {
		t.Fatal("connect with a mismatched hub relay id")
	}
	if h.relay.hits.Load() != 0 {
		t.Fatal("requests sent")
	}
}

func TestRelayTransport_ZoneChangedWithoutRecordMeansPull(t *testing.T) {
	h := newHarness(t)
	if err := h.tr.Connect(t.Context(), []string{h.data}); err != nil {
		t.Fatal(err)
	}
	waitZoneEvent(t, h.tr, h.data) // the initial pull
	states := len(h.relay.requests("get_account_state"))
	// The client's reconnect marker: a record-less ZoneChanged with seq 0.
	h.relay.push(t, &relayv1.Event{Kind: &relayv1.Event_ZoneChanged{ZoneChanged: &relayv1.ZoneChanged{Zone: h.data}}})
	ev := nextEvent(t, h.tr)
	if ev.Zone != h.data || ev.Control != nil || ev.Err != nil || !ev.Resync {
		t.Fatalf("event: %+v", ev)
	}
	deadline := time.Now().Add(5 * time.Second)
	for len(h.relay.requests("get_account_state")) == states {
		if time.Now().After(deadline) {
			t.Fatal("account state not re-read after a record-less ZoneChanged")
		}
		time.Sleep(10 * time.Millisecond)
	}
	// A ZoneChanged with a record is a pull too (the record is not trusted as the state).
	h.relay.push(t, &relayv1.Event{Kind: &relayv1.Event_ZoneChanged{ZoneChanged: &relayv1.ZoneChanged{
		Zone: h.data, Seq: 4, Record: &relayv1.Record{Zone: h.data, Name: "n", RecordSeq: 4}}}})
	if ev := nextEvent(t, h.tr); ev.Zone != h.data || ev.Resync {
		t.Fatalf("event: %+v", ev)
	}
	// Controls come through, mapped.
	h.relay.push(t, &relayv1.Event{Kind: &relayv1.Event_Control{Control: &relayv1.Control{
		Kind: relayv1.ControlKind_CONTROL_KIND_PAIRING_OPENED, Detail: "slot1"}}})
	ev = nextEvent(t, h.tr)
	if ev.Control == nil || ev.Control.Kind != transport.PairingOpened || ev.Control.Detail != "slot1" {
		t.Fatalf("control: %+v", ev)
	}
	if got := h.tr.PairZoneFor("slot1"); got != "pair/slot1" {
		t.Fatalf("pair zone %q", got)
	}
}

func TestRelayTransport_UploadThenSaveWithAttachment(t *testing.T) {
	h := newHarness(t)
	ctx := t.Context()
	rec, sealedPath := h.sealAsset(t, h.assetDir, h.data)
	want, _ := os.ReadFile(sealedPath)
	out, err := h.tr.Save(ctx, []transport.SaveItem{{Record: rec}})
	if err != nil || len(out) != 1 || !out[0].Saved {
		t.Fatalf("save: %+v, %v", out, err)
	}
	ops := h.relay.opsSeen()
	if i, j := slices.Index(ops, "create_upload"), slices.Index(ops, "save"); i < 0 || j < i {
		t.Fatalf("op order %v", ops)
	}
	up := h.relay.uploads[0]
	if up.GetZone() != h.data || up.GetSize() != uint64(len(want)) {
		t.Fatalf("create_upload: %v", up)
	}
	if !bytes.Equal(h.relay.blobs["att-1"], want) || h.relay.blobHeaders[0].Get("X-Test-Upload") != "yes" {
		t.Fatal("the PUT did not carry the sealed file with the upload's headers")
	}
	saved := h.relay.requests("save")[0].GetSave().GetItems()[0].GetRecord()
	if saved.GetAttachmentId() != "att-1" || bytes.Contains(saved.GetEnvelope(), want[:64]) {
		t.Fatalf("save record: attachment %q", saved.GetAttachmentId())
	}
	b, err := h.tr.Changes(ctx, h.data, 0)
	if err != nil || len(b.Changed) != 1 || b.Changed[0].AttachmentID != "att-1" {
		t.Fatalf("changes: %+v, %v", b, err)
	}
	dst := filepath.Join(t.TempDir(), "out")
	if err := h.tr.Download(ctx, h.data, "att-1", dst); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(dst)
	if info, err := os.Stat(dst); !bytes.Equal(got, want) || err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("download: %d bytes, %v", len(got), err)
	}
	// After a restart (a new transport, nothing pulled) the caller's zone is enough.
	tr2 := h.newTransport(t)
	if err := tr2.Download(ctx, h.data, "att-1", dst); err != nil {
		t.Fatalf("download from a new transport: %v", err)
	}
	// The relay refuses an attachment named through another zone.
	other := transport.MailboxZone(h.tr.c.DeviceID(), "phone1")
	if err := tr2.Download(ctx, other, "att-1", dst); !errors.Is(err, transport.ErrForbidden) {
		t.Fatalf("other zone: %v", err)
	}
}

func TestRelayTransport_DownloadCappedAndRedirectsChecked(t *testing.T) {
	h := newHarness(t)
	ctx := t.Context()
	rec, sealedPath := h.sealAsset(t, h.assetDir, h.data)
	if _, err := h.tr.Save(ctx, []transport.SaveItem{{Record: rec}}); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(sealedPath)
	if err != nil {
		t.Fatal(err)
	}
	h.tr.o.MaxAttachmentBytes = info.Size() - 1
	for _, hide := range []bool{false, true} { // with and without Content-Length
		h.relay.mu.Lock()
		h.relay.hideLength = hide
		h.relay.mu.Unlock()
		dir := t.TempDir()
		dst := filepath.Join(dir, "out")
		if err := h.tr.Download(ctx, h.data, "att-1", dst); !errors.Is(err, transport.ErrRecordTooLarge) {
			t.Fatalf("hide length %v: %v, want ErrRecordTooLarge", hide, err)
		}
		if left, _ := os.ReadDir(dir); len(left) != 0 {
			t.Fatalf("hide length %v: files left: %v", hide, left)
		}
	}
	h.tr.o.MaxAttachmentBytes = info.Size()
	if err := h.tr.Download(ctx, h.data, "att-1", filepath.Join(t.TempDir(), "out")); err != nil {
		t.Fatalf("at the cap: %v", err)
	}

	// An HTTPS download URL that redirects to plain HTTP is refused.
	plain := h.relay.URL + "/blob/att-1"
	tlsSrv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, plain, http.StatusFound)
	}))
	t.Cleanup(tlsSrv.Close)
	h.relay.mu.Lock()
	h.relay.downloadBase = tlsSrv.URL
	h.relay.mu.Unlock()
	tr := New(NewClient(h.relay.URL, h.key), Options{Origin: h.relay.URL, Store: h.store, HTTP: tlsSrv.Client()})
	t.Cleanup(func() { _ = tr.Close() })
	dst := filepath.Join(t.TempDir(), "out")
	if err := tr.Download(ctx, h.data, "att-1", dst); err == nil || !strings.Contains(err.Error(), "leaves HTTPS") {
		t.Fatalf("https→http redirect: %v", err)
	}
	if _, err := os.Stat(dst); !os.IsNotExist(err) {
		t.Fatal("a file was written for a refused redirect")
	}
	if strings.Contains(fmt.Sprint(tr.Download(ctx, h.data, "att-1", dst)), "X-Sig") {
		t.Fatal("the signed URL reached the error")
	}
	// A redirect loop stops at the cap.
	var loop *httptest.Server
	loop = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, loop.URL+"/again", http.StatusFound)
	}))
	t.Cleanup(loop.Close)
	h.relay.mu.Lock()
	h.relay.downloadBase = loop.URL
	h.relay.mu.Unlock()
	if err := h.tr.Download(ctx, h.data, "att-1", dst); err == nil || !strings.Contains(err.Error(), "too many redirects") {
		t.Fatalf("redirect loop: %v", err)
	}
}

func TestRelayTransport_MalformedSaveAnswerIsAnError(t *testing.T) {
	cases := map[string]*relayv1.SaveResult{
		"out of range": {Conflicts: []*relayv1.SaveConflict{{Index: 5}}, Saved: []*relayv1.Record{{RecordSeq: 1}}},
		"repeated":     {Conflicts: []*relayv1.SaveConflict{{Index: 0}, {Index: 0}}},
		"short":        {Saved: []*relayv1.Record{{RecordSeq: 1}}},
		"long":         {Saved: []*relayv1.Record{{RecordSeq: 1}, {RecordSeq: 2}, {RecordSeq: 3}}},
	}
	for name, res := range cases {
		out := make([]transport.Outcome, 2)
		if err := saveOutcomes(res, []int{0, 1}, out); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	// Through the transport: the reviewer's answer (2 items, conflict index 5, 1 saved).
	h := newHarness(t)
	h.relay.saveOverride = &relayv1.SaveResult{Conflicts: []*relayv1.SaveConflict{{Index: 5}}, Saved: []*relayv1.Record{{RecordSeq: 1}}}
	items := []transport.SaveItem{{Record: h.seal(t, "target-1", `{}`)}, {Record: h.seal(t, "target-2", `{}`)}}
	if _, err := h.tr.Save(t.Context(), items); err == nil {
		t.Fatal("a malformed save answer was accepted")
	}
}

func TestRelayTransport_AssetOutsideSealerDirRefused(t *testing.T) {
	h := newHarness(t)
	outside, _ := h.sealAsset(t, t.TempDir(), h.data)
	// A symlink inside the asset dir that points at a sealed file outside it.
	src, target := filepath.Join(t.TempDir(), "plain"), filepath.Join(t.TempDir(), "real")
	if err := os.WriteFile(src, []byte("ab"), 0o600); err != nil {
		t.Fatal(err)
	}
	d, err := secure.EncryptAssetFile(src, target, secure.ID{2})
	if err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(h.assetDir, "link")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	linked, err := h.sealer.Data(h.data, "session_report-2", "", []byte(`{}`), &d, link)
	if err != nil {
		t.Fatal(err)
	}
	before := h.relay.hits.Load()
	for name, rec := range map[string]secure.Record{"outside": outside, "symlink": linked} {
		items := []transport.SaveItem{{Record: h.seal(t, "target-1", `{}`)}, {Record: rec}}
		if _, err := h.tr.Save(t.Context(), items); !errors.Is(err, secure.ErrUnsealed) {
			t.Errorf("%s: %v, want ErrUnsealed", name, err)
		}
	}
	if h.relay.hits.Load() != before {
		t.Fatal("requests sent for a refused asset")
	}
	// No asset dir configured: every asset is refused.
	h.tr.o.AssetDir = ""
	inside, _ := h.sealAsset(t, h.assetDir, h.data)
	if _, err := h.tr.Save(t.Context(), []transport.SaveItem{{Record: inside}}); !errors.Is(err, secure.ErrUnsealed) {
		t.Fatalf("no asset dir: %v", err)
	}
}

func TestRelayTransport_PairZoneAttachmentRefused(t *testing.T) {
	h := newHarness(t)
	pair := h.tr.PairZoneFor("slot1")
	rec, _ := h.sealAsset(t, h.assetDir, pair)
	out, err := h.tr.Save(t.Context(), []transport.SaveItem{{Record: rec}, {Record: h.seal(t, "target-1", `{}`)}})
	if err != nil || len(out) != 2 {
		t.Fatalf("save: %+v, %v", out, err)
	}
	if out[0].Saved || !errors.Is(out[0].Refused, transport.ErrForbidden) || !out[1].Saved || out[1].RecordSeq != 1 {
		t.Fatalf("outcomes: %+v", out)
	}
	if len(h.relay.uploads) != 0 || len(h.relay.requests("save")[0].GetSave().GetItems()) != 1 {
		t.Fatal("the pairing-zone asset went out")
	}
}

func TestRelayTransport_SetHubReadersAndAccountState(t *testing.T) {
	h := newHarness(t)
	if err := h.tr.SetHubReaders(t.Context(), []string{"p1", "p2"}); err != nil {
		t.Fatal(err)
	}
	if got := h.relay.readers; len(got) != 1 || !slices.Equal(got[0], []string{"p1", "p2"}) {
		t.Fatalf("readers: %v", got)
	}
	h.relay.account = &relayv1.AccountState{Phones: []*relayv1.SlotHolder{{PhoneDeviceId: "p1", Paying: false}}}
	st, err := h.tr.AccountState(t.Context())
	if err != nil || len(st.GetPhones()) != 1 {
		t.Fatalf("account state: %v, %v", st, err)
	}
	if h.tr.Admitted() {
		t.Fatal("admitted with no paying phone")
	}
}

// TestRelayTransport_DeviceIDMatchesIdentity: the hub's own derivation of its
// relay_device_id (put into device_grant and the QR) is the relay client's.
func TestRelayTransport_DeviceIDMatchesIdentity(t *testing.T) {
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if identity.RelayDeviceID(pub) != client.DeviceID(pub) {
		t.Fatal("identity.RelayDeviceID differs from the relay client's DeviceID")
	}
}
