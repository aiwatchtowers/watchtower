package link

import (
	"context"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/wire"
	"watchtower/internal/logcanary"
)

// rig is one hub: a sidecar, a keyring, a link center on a settable clock.
type rig struct {
	t         *testing.T
	st        *state.Store
	kr        *identity.Keyring
	c         *Center
	mu        sync.Mutex
	now       time.Time
	published []string
}

const (
	testRelayID  = "relaydeviceidacme"
	testRelayPub = "cmVsYXktYXV0aC1wdWItYWNtZQ"
)

func newRig(t *testing.T) *rig {
	t.Helper()
	st, err := state.Open(filepath.Join(t.TempDir(), "hub"))
	if err != nil {
		t.Fatalf("state.Open: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	id, err := identity.New()
	if err != nil {
		t.Fatal(err)
	}
	r := &rig{t: t, st: st, now: time.Unix(1_800_000_000, 0).UTC()}
	kr, err := identity.NewKeyring(id, st, r.clock)
	if err != nil {
		t.Fatalf("NewKeyring: %v", err)
	}
	r.kr = kr
	r.c = NewCenter(Config{
		Store: st, Keys: kr, Opener: secure.NewOpener(kr, kr),
		Host:  HostInfo{Name: "acme-host", RelayDeviceID: testRelayID, RelayAuthPub: testRelayPub},
		Clock: r.clock,
		Publish: func(kinds ...string) {
			r.mu.Lock()
			defer r.mu.Unlock()
			r.published = append(r.published, kinds...)
		},
	})
	return r
}

func (r *rig) clock() time.Time {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.now
}

func (r *rig) advance(d time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.now = r.now.Add(d)
}

// phone is a phone's key pair and the device id its signing key hashes to.
type phone struct {
	sig ed25519.PrivateKey
	kx  *ecdh.PrivateKey
	id  secure.ID
}

func newPhone(t *testing.T) phone {
	t.Helper()
	_, sig, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return phoneWith(t, sig)
}

func phoneWith(t *testing.T, sig ed25519.PrivateKey) phone {
	t.Helper()
	kx, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return phone{sig: sig, kx: kx, id: secure.DeviceID(sig.Public().(ed25519.PublicKey))}
}

func (p phone) name() string { return "hello-" + p.id.String() }

var b64 = base64.RawURLEncoding

// hello is p's hello under the code nonce, sealed to the hub as the phone
// does (the Kit's TestHello.record).
func (r *rig) hello(p phone, nonce string, edit ...func(*wire.DeviceHello)) []byte {
	r.t.Helper()
	h := wire.DeviceHello{
		Device: wire.DevicePayload{
			DeviceID: p.id.String(), Name: "iPhone", Model: "iPhone18,1", AppVersion: "0.0.0-test",
			Scope: wire.ScopePrivate, StartSessions: true, UpdatedAt: wire.Time{Time: r.clock()},
		},
		SigningKey:   b64.EncodeToString(p.sig.Public().(ed25519.PublicKey)),
		AgreementKey: b64.EncodeToString(p.kx.PublicKey().Bytes()),
	}
	for _, e := range edit {
		e(&h)
	}
	payload, err := wire.Marshal(h)
	if err != nil {
		r.t.Fatal(err)
	}
	linkNonce, err := b64.DecodeString(nonce)
	if err != nil {
		r.t.Fatal(err)
	}
	hub := r.kr.HubID()
	f := secure.InnerFrame{Kind: "hello", ID: p.name(), Payload: payload}
	env, err := secure.SealHPKE(f, secure.ClassHello, r.kr.Agreement().PublicKey(), secure.HelloInfo(hub, linkNonce),
		hub, p.id, 1, 1, secure.Context{Zone: secure.ZoneRelay, WireName: p.name()}, p.sig)
	if err != nil {
		r.t.Fatal(err)
	}
	return env
}

func (r *rig) handle(p phone, nonce string, edit ...func(*wire.DeviceHello)) Pending {
	r.t.Helper()
	got, err := r.c.HandleHello("relay", p.name(), r.hello(p, nonce, edit...))
	if err != nil {
		r.t.Fatalf("HandleHello: %v", err)
	}
	return got
}

func (r *rig) issue() wire.LinkPayload {
	r.t.Helper()
	p, _, err := r.c.Issue()
	if err != nil {
		r.t.Fatalf("Issue: %v", err)
	}
	return p
}

// keybox is p's keybox as the phone reads it: the device_grant row sealed by
// the hub's Sealer, opened with p's key, the hub's signature checked. ok is
// false when the hub publishes none for p.
func (r *rig) keybox(p phone) (wire.Keybox, bool) {
	r.t.Helper()
	boxes, err := r.c.Keyboxes()
	if err != nil {
		r.t.Fatalf("Keyboxes: %v", err)
	}
	for _, kb := range boxes {
		if !strings.EqualFold(kb.Grant.DeviceID, p.id.String()) {
			continue
		}
		payload, err := wire.Marshal(kb)
		if err != nil {
			r.t.Fatal(err)
		}
		rec, err := secure.NewSealer(r.kr).Keybox("data", p.id, payload)
		if err != nil {
			r.t.Fatalf("seal keybox: %v", err)
		}
		hub := r.kr.HubID()
		_, f, err := secure.OpenHPKE(rec.Envelope(), secure.ClassKeybox, p.kx, secure.KeyboxInfo(hub, p.id),
			secure.Context{Zone: secure.ZoneData, WireName: rec.WireName()}, r.kr.Signer().Public().(ed25519.PublicKey))
		if err != nil {
			r.t.Fatalf("the phone cannot open its keybox: %v", err)
		}
		var out wire.Keybox
		if err := json.Unmarshal(f.Payload, &out); err != nil {
			r.t.Fatal(err)
		}
		return out, true
	}
	return wire.Keybox{}, false
}

func (r *rig) mustKeybox(p phone) wire.Keybox {
	r.t.Helper()
	kb, ok := r.keybox(p)
	if !ok {
		r.t.Fatalf("no keybox for %s", p.id)
	}
	return kb
}

func (r *rig) linked(p phone) bool {
	r.t.Helper()
	_, ok, err := r.st.Device(p.id.String())
	if err != nil {
		r.t.Fatal(err)
	}
	return ok
}

// refusalRows counts the stored refusals (the slice publishes at most
// MaxGrantRecords of them).
func (r *rig) refusalRows() int {
	r.t.Helper()
	n := 0
	err := r.st.ReadTx(context.Background(), func(tx *sql.Tx) error {
		return tx.QueryRow(`SELECT COUNT(*) FROM link_refusals`).Scan(&n)
	})
	if err != nil {
		r.t.Fatal(err)
	}
	return n
}

// code is the code p's waiting request shows now, "" when none waits.
func (r *rig) code(p phone) string {
	r.t.Helper()
	list, err := r.c.PendingLinks()
	if err != nil {
		r.t.Fatal(err)
	}
	for _, w := range list {
		if w.DeviceID == p.id.String() {
			return w.Code
		}
	}
	return ""
}

func pendingIDs(t *testing.T, c *Center) []string {
	t.Helper()
	list, err := c.PendingLinks()
	if err != nil {
		t.Fatal(err)
	}
	var ids []string
	for _, p := range list {
		ids = append(ids, p.DeviceID)
	}
	slices.Sort(ids)
	return ids
}

func sortedIDs(ps ...phone) []string {
	var ids []string
	for _, p := range ps {
		ids = append(ids, p.id.String())
	}
	slices.Sort(ids)
	return ids
}

func (r *rig) confirmLinked(p phone) {
	r.t.Helper()
	code := r.issue()
	if got := r.handle(p, code.Nonce); got.Code == "" {
		r.t.Fatalf("hello not waiting: %+v", got)
	}
	if err := r.c.Confirm(p.id.String(), r.code(p), true); err != nil {
		r.t.Fatalf("Confirm: %v", err)
	}
	if !r.linked(p) {
		r.t.Fatal("not linked after Confirm")
	}
}

func TestIssueCarriesV4RelayFields(t *testing.T) {
	r := newRig(t)
	p, url, err := r.c.Issue()
	if err != nil {
		t.Fatal(err)
	}
	if p.V != wire.LinkPayloadVersion || p.Transport != wire.TransportRelay || p.RelayDeviceID != testRelayID ||
		p.RelayAuthPub != testRelayPub || !slices.Equal(p.Transports, []string{wire.TransportRelay}) {
		t.Errorf("payload %+v", p)
	}
	if p.DataShare != nil || p.RelayShare != nil || p.Container != "" || p.OwnerUser != "" {
		t.Errorf("a headless code carries no CloudKit fields: %+v", p)
	}
	if p.Exp-p.Iat != 600 || p.HubID != r.kr.HubID().String() {
		t.Errorf("iat %d exp %d hub %s", p.Iat, p.Exp, p.HubID)
	}
	if n, err := b64.DecodeString(p.Nonce); err != nil || len(n) != 32 {
		t.Errorf("nonce %q", p.Nonce)
	}
	parsed, err := wire.ParseLinkURL(url)
	if err != nil || parsed.Nonce != p.Nonce || parsed.HubKX != b64.EncodeToString(r.kr.Agreement().PublicKey().Bytes()) {
		t.Errorf("url does not parse back: %v %+v", err, parsed)
	}
	ev := <-r.c.Events()
	if ev.Kind != EventQR || ev.URL != url || !ev.ExpiresAt.Equal(time.Unix(p.Exp, 0)) {
		t.Errorf("qr event %+v", ev)
	}
	if ev := <-r.c.Events(); ev.Kind != EventWaiting {
		t.Errorf("then waiting, got %+v", ev)
	}
}

func TestIssueKeepsAtMost50Codes(t *testing.T) {
	r := newRig(t)
	if KeptCodes != 50 {
		t.Fatalf("KeptCodes %d", KeptCodes)
	}
	var codes []wire.LinkPayload
	for range 60 {
		codes = append(codes, r.issue())
		r.advance(time.Second)
	}
	kept, err := r.c.keptCodes()
	if err != nil {
		t.Fatal(err)
	}
	if len(kept) != 50 || kept[0].nonce != codes[59].Nonce || kept[49].nonce != codes[10].Nonce {
		t.Fatalf("kept %d codes", len(kept))
	}
	// A hello under a pruned code opens under no kept code: unanswered.
	p := newPhone(t)
	if _, err := r.c.HandleHello("relay", p.name(), r.hello(p, codes[0].Nonce)); !errors.Is(err, ErrHelloDropped) {
		t.Errorf("pruned code: %v", err)
	}
	if _, ok := r.keybox(p); ok {
		t.Error("a hello under no kept code gets no keybox")
	}
}

func TestANewCodeRetiresThePreviousUnusedCode(t *testing.T) {
	r := newRig(t)
	first := r.issue()
	r.advance(10 * time.Second)
	r.issue()
	p := newPhone(t)
	if got := r.handle(p, first.Nonce); got.Refused != wire.RefusedExpiredCode {
		t.Errorf("hello under the retired code: %+v", got)
	}
}

func TestAUsedCodeIsRefused(t *testing.T) {
	r := newRig(t)
	code := r.issue()
	a, b := newPhone(t), newPhone(t)
	r.handle(a, code.Nonce)
	if err := r.c.Confirm(a.id.String(), r.code(a), true); err != nil {
		t.Fatal(err)
	}
	if got := r.handle(b, code.Nonce); got.Refused != wire.RefusedUsedCode {
		t.Fatalf("second phone: %+v", got)
	}
	kb := r.mustKeybox(b)
	if kb.Grant.LinkRefused == nil || *kb.Grant.LinkRefused != wire.RefusedUsedCode || kb.Keys != nil || kb.Grant.Linked {
		t.Errorf("refusal keybox %+v", kb)
	}
	// The same QR scanned again by the linked phone stays one link.
	if got := r.handle(a, code.Nonce); got.Refused != "" || got.Code != "" {
		t.Errorf("re-scan by the linked phone: %+v", got)
	}
	if !r.linked(a) || r.mustKeybox(a).Keys == nil {
		t.Error("the linked phone keeps its link")
	}
}

func TestAnExpiredCodeIsRefused(t *testing.T) {
	r := newRig(t)
	code := r.issue()
	a, b := newPhone(t), newPhone(t)
	r.advance(600 * time.Second)
	if got := r.handle(a, code.Nonce); got.Code == "" {
		t.Fatalf("still valid at exactly 600 s: %+v", got)
	}
	r.advance(time.Second)
	if got := r.handle(b, code.Nonce); got.Refused != wire.RefusedExpiredCode {
		t.Fatalf("after 600 s: %+v", got)
	}
	if kb := r.mustKeybox(b); kb.Grant.LinkRefused == nil || *kb.Grant.LinkRefused != wire.RefusedExpiredCode {
		t.Errorf("keybox %+v", kb)
	}
	// The sweep refuses the request still waiting under the expired code.
	if err := r.c.Sweep(); err != nil {
		t.Fatal(err)
	}
	if ids := pendingIDs(t, r.c); len(ids) != 0 {
		t.Errorf("still waiting: %v", ids)
	}
	if kb := r.mustKeybox(a); kb.Grant.LinkRefused == nil || *kb.Grant.LinkRefused != wire.RefusedExpiredCode || kb.Keys != nil {
		t.Errorf("swept request keybox %+v", kb)
	}
}

func TestFourthNonceOnACodeIsTooManyRequests(t *testing.T) {
	r := newRig(t)
	if MaxNoncesPerCode != 3 {
		t.Fatalf("MaxNoncesPerCode %d", MaxNoncesPerCode)
	}
	code := r.issue()
	a, b, c, d := newPhone(t), newPhone(t), newPhone(t), newPhone(t)
	for _, p := range []phone{a, b, c} {
		r.handle(p, code.Nonce)
	}
	if got := r.handle(d, code.Nonce); got.Refused != wire.RefusedTooManyRequests {
		t.Fatalf("fourth: %+v", got)
	}
	if ids := pendingIDs(t, r.c); !slices.Equal(ids, sortedIDs(a, b, c)) {
		t.Errorf("the fourth is not shown: %v", ids)
	}
	kb := r.mustKeybox(d)
	if kb.Grant.LinkRefused == nil || *kb.Grant.LinkRefused != wire.RefusedTooManyRequests || kb.Grant.ConfirmNonce != nil || kb.Keys != nil {
		t.Errorf("fourth keybox %+v", kb)
	}
	// A re-sent hello is no new attempt and keeps its nonce.
	first := r.mustKeybox(a).Grant.ConfirmNonce
	r.handle(a, code.Nonce)
	if again := r.mustKeybox(a); again.Grant.AwaitingConfirmation == nil || !*again.Grant.AwaitingConfirmation ||
		*again.Grant.ConfirmNonce != *first {
		t.Errorf("re-sent hello %+v", again)
	}
	// The owner's Refuse gives no try back; a new code does.
	if err := r.c.Confirm(b.id.String(), "", false); err != nil {
		t.Fatal(err)
	}
	e := newPhone(t)
	if got := r.handle(e, code.Nonce); got.Refused != wire.RefusedTooManyRequests {
		t.Errorf("after Refuse: %+v", got)
	}
	next := r.issue()
	if got := r.handle(d, next.Nonce); got.Code == "" {
		t.Errorf("a new code, new tries: %+v", got)
	}
}

func TestReRollingTheAgreementKeySpendsTheCodesNonces(t *testing.T) {
	r := newRig(t)
	code := r.issue()
	_, sig, _ := ed25519.GenerateKey(rand.Reader)
	var rolls []phone
	for range 4 {
		rolls = append(rolls, phoneWith(t, sig))
	}
	var third Pending
	for _, p := range rolls[:3] {
		third = r.handle(p, code.Nonce)
	}
	if got := r.handle(rolls[3], code.Nonce); got.Refused != wire.RefusedTooManyRequests {
		t.Fatalf("fourth roll: %+v", got)
	}
	list, err := r.c.PendingLinks()
	if err != nil || len(list) != 1 || list[0].Code != third.Code {
		t.Fatalf("still the third request: %+v %v", list, err)
	}
}

func TestRefusalsCappedPerCodeAndOverall(t *testing.T) {
	if MaxRefusalsPerCode != 10 || MaxLinkRefusals != 50 {
		t.Fatalf("caps %d / %d", MaxRefusalsPerCode, MaxLinkRefusals)
	}
	t.Run("per code", func(t *testing.T) {
		r := newRig(t)
		code := r.issue()
		for range 3 {
			r.handle(newPhone(t), code.Nonce)
		}
		var flood []phone
		for range MaxRefusalsPerCode + 2 {
			p := newPhone(t)
			flood = append(flood, p)
			r.handle(p, code.Nonce)
		}
		if n := r.refusalRows(); n != MaxRefusalsPerCode {
			t.Fatalf("refusals %d", n)
		}
		if _, ok := r.keybox(flood[len(flood)-1]); ok {
			t.Error("past the cap a hello gets no keybox")
		}
		if got := r.handle(flood[len(flood)-1], code.Nonce); !got.Unanswered {
			t.Errorf("past the cap: %+v", got)
		}
		// An already refused phone is answered again in place.
		if got := r.handle(flood[0], code.Nonce); got.Unanswered {
			t.Errorf("known phone: %+v", got)
		}
		if n := r.refusalRows(); n != MaxRefusalsPerCode {
			t.Errorf("refusals after a re-sent hello %d", n)
		}
	})
	t.Run("overall", func(t *testing.T) {
		r := newRig(t)
		var codes []wire.LinkPayload
		for range 6 {
			codes = append(codes, r.issue())
			r.advance(time.Second)
		}
		// Every code but the last is retired: each hello reads expired_code.
		n := 0
		for _, code := range codes[:5] {
			for range MaxNoncesPerCode + MaxRefusalsPerCode {
				got := r.handle(newPhone(t), code.Nonce)
				if got.Refused != wire.RefusedExpiredCode {
					t.Fatalf("hello %d: %+v", n, got)
				}
				n++
			}
		}
		if rows := r.refusalRows(); rows != MaxLinkRefusals {
			t.Fatalf("refusals %d, want %d", rows, MaxLinkRefusals)
		}
		if got := r.handle(newPhone(t), codes[4].Nonce); !got.Unanswered {
			t.Fatalf("past the total cap: %+v", got)
		}
		// An expired refusal frees its place.
		r.advance(RefusalLifetime + time.Second)
		if got := r.handle(newPhone(t), codes[4].Nonce); got.Unanswered {
			t.Errorf("after the lifetime a refusal is answered again: %+v", got)
		}
	})
}

func TestSASMatchesKit(t *testing.T) {
	r := newRig(t)
	code := r.issue()
	a := newPhone(t)
	got := r.handle(a, code.Nonce, func(h *wire.DeviceHello) { h.Device.Name = "Owner\u202es\niPhone\u200b\u0007" })
	if got.Name != "Owners iPhone" {
		t.Errorf("display name %q", got.Name)
	}
	kb := r.mustKeybox(a)
	g := kb.Grant
	if g.AwaitingConfirmation == nil || !*g.AwaitingConfirmation || g.ConfirmNonce == nil || g.LinkCodeTag == nil || kb.Keys != nil || g.Linked {
		t.Fatalf("waiting keybox %+v", kb)
	}
	linkNonce, _ := b64.DecodeString(code.Nonce)
	if *g.LinkCodeTag != secure.LinkCodeTag(linkNonce) {
		t.Errorf("link code tag %s", *g.LinkCodeTag)
	}
	confirm, err := b64.DecodeString(*g.ConfirmNonce)
	if err != nil || len(confirm) != secure.ConfirmNonceLength {
		t.Fatalf("confirm nonce %q", *g.ConfirmNonce)
	}
	// The phone's computation from the scanned QR and its keybox.
	hubSig, _ := b64.DecodeString(code.HubSig)
	hubKXRaw, _ := b64.DecodeString(code.HubKX)
	hubKX, err := ecdh.X25519().NewPublicKey(hubKXRaw)
	if err != nil {
		t.Fatal(err)
	}
	want := secure.SAS(r.kr.HubID(), linkNonce, hubSig, hubKX, a.sig.Public().(ed25519.PublicKey), a.kx.PublicKey(), confirm)
	if got.Code != want {
		t.Errorf("hub code %s, phone code %s", got.Code, want)
	}
	var sas PairEvent
	for ev := range drain(r.c) {
		if ev.Kind == EventSAS {
			sas = ev
		}
	}
	if sas.Code != want || sas.DeviceID != a.id.String() || sas.Name != "Owners iPhone" {
		t.Errorf("sas event %+v", sas)
	}
}

// drain returns the events queued so far.
func drain(c *Center) chan PairEvent {
	out := make(chan PairEvent, eventBuffer)
	for {
		select {
		case ev := <-c.Events():
			out <- ev
		default:
			close(out)
			return out
		}
	}
}

func TestAHelloFailingItsChecksIsDropped(t *testing.T) {
	r := newRig(t)
	code := r.issue()
	a, other := newPhone(t), newPhone(t)
	cases := map[string]func(*wire.DeviceHello){
		"device id not its key hash": func(h *wire.DeviceHello) { h.Device.DeviceID = other.id.String() },
		"unknown scope":              func(h *wire.DeviceHello) { h.Device.Scope = "galaxy" },
		"short agreement key":        func(h *wire.DeviceHello) { h.AgreementKey = b64.EncodeToString(make([]byte, 16)) },
		"low-order agreement key":    func(h *wire.DeviceHello) { h.AgreementKey = b64.EncodeToString(make([]byte, 32)) },
	}
	for name, edit := range cases {
		if _, err := r.c.HandleHello("relay", a.name(), r.hello(a, code.Nonce, edit)); !errors.Is(err, ErrHelloDropped) {
			t.Errorf("%s: %v", name, err)
		}
	}
	// Signed by another key than the one it carries.
	env := r.hello(a, code.Nonce, func(h *wire.DeviceHello) {
		h.SigningKey = b64.EncodeToString(other.sig.Public().(ed25519.PublicKey))
	})
	if _, err := r.c.HandleHello("relay", a.name(), env); !errors.Is(err, ErrHelloDropped) {
		t.Errorf("foreign signature: %v", err)
	}
	if ids := pendingIDs(t, r.c); len(ids) != 0 {
		t.Errorf("nothing waits: %v", ids)
	}
}

func TestConfirmSealsKeyboxWithGrantAndKeys(t *testing.T) {
	r := newRig(t)
	code := r.issue()
	a, b := newPhone(t), newPhone(t)
	r.handle(a, code.Nonce)
	r.handle(b, code.Nonce)
	drain(r.c)
	if err := r.c.Confirm(a.id.String(), r.code(a), true); err != nil {
		t.Fatal(err)
	}
	kb := r.mustKeybox(a)
	want, err := r.kr.KeyboxKeys()
	if err != nil {
		t.Fatal(err)
	}
	if !kb.Grant.Linked || kb.Grant.LinkedAt == nil || kb.Keys == nil || *kb.Keys != want {
		t.Fatalf("linked keybox %+v", kb)
	}
	if kb.Grant.AwaitingConfirmation != nil || kb.Grant.ConfirmNonce != nil || kb.Grant.TypingAllowed {
		t.Errorf("grant %+v", kb.Grant)
	}
	d, ok, err := r.st.Device(a.id.String())
	if err != nil || !ok || d.LinkNonce != code.Nonce || len(d.AgreementKey) != 32 || d.ID != a.id.String() {
		t.Errorf("device row %+v %v", d, err)
	}
	// The other request is refused used_code (F17), without keys.
	kbB := r.mustKeybox(b)
	if kbB.Grant.LinkRefused == nil || *kbB.Grant.LinkRefused != wire.RefusedUsedCode || kbB.Keys != nil {
		t.Errorf("other request %+v", kbB)
	}
	var kinds []string
	for ev := range drain(r.c) {
		kinds = append(kinds, ev.Kind)
	}
	if !slices.Contains(kinds, EventLinked) {
		t.Errorf("events %v", kinds)
	}
	if !slices.Contains(r.published, KindDeviceGrant) {
		t.Errorf("published %v", r.published)
	}
}

func TestConfirmAfterExpiryOrUnlinkSealsNoKeys(t *testing.T) {
	noKeys := func(t *testing.T, r *rig, p phone) {
		t.Helper()
		if r.linked(p) {
			t.Error("a devices row")
		}
		if kb, ok := r.keybox(p); ok && kb.Keys != nil {
			t.Errorf("keys sealed: %+v", kb.Grant)
		}
	}
	t.Run("expired code", func(t *testing.T) {
		r := newRig(t)
		code := r.issue()
		a := newPhone(t)
		r.handle(a, code.Nonce)
		r.advance(601 * time.Second)
		if err := r.c.Confirm(a.id.String(), r.code(a), true); err != nil {
			t.Fatal(err)
		}
		noKeys(t, r, a)
		if kb := r.mustKeybox(a); kb.Grant.LinkRefused == nil || *kb.Grant.LinkRefused != wire.RefusedExpiredCode {
			t.Errorf("keybox %+v", kb.Grant)
		}
	})
	t.Run("unlink first", func(t *testing.T) {
		r := newRig(t)
		code := r.issue()
		a := newPhone(t)
		r.handle(a, code.Nonce)
		if err := r.c.Unlink(a.id.String()); err != nil {
			t.Fatal(err)
		}
		if err := r.c.Confirm(a.id.String(), r.code(a), true); !errors.Is(err, ErrNoRequest) {
			t.Errorf("confirm after unlink: %v", err)
		}
		noKeys(t, r, a)
	})
	t.Run("refuse first", func(t *testing.T) {
		r := newRig(t)
		code := r.issue()
		a := newPhone(t)
		r.handle(a, code.Nonce)
		if err := r.c.Confirm(a.id.String(), "", false); err != nil {
			t.Fatal(err)
		}
		if err := r.c.Confirm(a.id.String(), r.code(a), true); !errors.Is(err, ErrNoRequest) {
			t.Errorf("confirm after refuse: %v", err)
		}
		noKeys(t, r, a)
		if kb := r.mustKeybox(a); kb.Grant.LinkRefused == nil || *kb.Grant.LinkRefused != wire.RefusedNotConfirmed {
			t.Errorf("keybox %+v", kb.Grant)
		}
	})
	t.Run("racing", func(t *testing.T) {
		for range 10 {
			r := newRig(t)
			code := r.issue()
			a := newPhone(t)
			r.handle(a, code.Nonce)
			shown := r.code(a)
			var wg sync.WaitGroup
			wg.Add(3)
			go func() { defer wg.Done(); _ = r.c.Confirm(a.id.String(), shown, true) }()
			go func() { defer wg.Done(); _ = r.c.Unlink(a.id.String()) }()
			go func() { defer wg.Done(); _ = r.c.Confirm(a.id.String(), "", false) }()
			wg.Wait()
			// Whichever order ran, an Unlink leaves the phone unlinked: its
			// keybox is revoked or refused, never keyed.
			noKeys(t, r, a)
		}
	})
}

func TestUnlinkWritesRevokedKeyboxAndRotates(t *testing.T) {
	r := newRig(t)
	a, b := newPhone(t), newPhone(t)
	r.confirmLinked(a)
	r.confirmLinked(b)
	before, err := r.kr.CurrentEpoch()
	if err != nil {
		t.Fatal(err)
	}
	if err := r.c.Allow(a.id.String(), GrantTyping, true); err != nil {
		t.Fatal(err)
	}
	if err := r.c.Unlink(strings.ToLower(a.id.String())); err != nil {
		t.Fatal(err)
	}
	after, _ := r.kr.CurrentEpoch()
	if after != before+1 {
		t.Errorf("epoch %d → %d", before, after)
	}
	if r.linked(a) {
		t.Error("still linked")
	}
	kb := r.mustKeybox(a)
	if kb.Grant.Revoked == nil || !*kb.Grant.Revoked || kb.Grant.Linked || kb.Keys != nil || kb.Grant.TypingAllowed {
		t.Errorf("revoked keybox %+v", kb)
	}
	// The remaining phone's keybox carries the new epoch.
	if kbB := r.mustKeybox(b); kbB.Keys == nil || kbB.Keys.Epoch != after || kbB.Keys.PreviousEpoch == nil {
		t.Errorf("remaining phone keys %+v", kbB.Keys)
	}
	// Unlinking a phone that is not linked rotates nothing.
	if err := r.c.Unlink(a.id.String()); !errors.Is(err, state.ErrNoDevice) {
		t.Errorf("second unlink: %v", err)
	}
	if again, _ := r.kr.CurrentEpoch(); again != after {
		t.Errorf("a no-op unlink rotated: %d", again)
	}
	// Seven days later the revoked keybox is gone, and the sweep forgets it.
	r.advance(RevokedLifetime + time.Second)
	if _, ok := r.keybox(a); ok {
		t.Error("revoked keybox after seven days")
	}
	if err := r.c.Sweep(); err != nil {
		t.Fatal(err)
	}
	if key, err := r.st.KeyboxRecipientKey(a.id.String()); err != nil || key != nil {
		t.Errorf("revoked row kept: %v", err)
	}
}

func TestARemovedPhoneIsNotLinkedAgainByItsOldCode(t *testing.T) {
	r := newRig(t)
	code := r.issue()
	a := newPhone(t)
	r.handle(a, code.Nonce)
	if err := r.c.Confirm(a.id.String(), r.code(a), true); err != nil {
		t.Fatal(err)
	}
	if err := r.c.Unlink(a.id.String()); err != nil {
		t.Fatal(err)
	}
	// The code is the phone's own used one: no link, no request; the only
	// answer stays the removal's revoked keybox (D9).
	if got := r.handle(a, code.Nonce); got.Code != "" || got.Refused != "" {
		t.Errorf("old code after removal: %+v", got)
	}
	if r.linked(a) || len(pendingIDs(t, r.c)) != 0 {
		t.Error("re-linked or waiting by the old code")
	}
	if kb := r.mustKeybox(a); kb.Grant.Revoked == nil || !*kb.Grant.Revoked || kb.Grant.Linked {
		t.Errorf("keybox %+v", kb.Grant)
	}
}

func TestTypingRequestIsStoredNotGranted(t *testing.T) {
	r := newRig(t)
	code := r.issue()
	a := newPhone(t)
	r.handle(a, code.Nonce, func(h *wire.DeviceHello) { h.Device.TypingRequested = true })
	if err := r.c.Confirm(a.id.String(), r.code(a), true); err != nil {
		t.Fatal(err)
	}
	d, _, err := r.st.Device(a.id.String())
	if err != nil || !d.TypingRequested || d.TypingAllowed {
		t.Errorf("device %+v %v", d, err)
	}
	if kb := r.mustKeybox(a); kb.Grant.TypingAllowed || kb.Grant.DecidedAt != nil {
		t.Errorf("grant %+v", kb.Grant)
	}
}

func TestPermissionsGrantIsSeparateFromTyping(t *testing.T) {
	r := newRig(t)
	a := newPhone(t)
	r.confirmLinked(a)
	id := a.id.String()
	if err := r.c.Allow(id, GrantPermissions, true); err != nil {
		t.Fatal(err)
	}
	g := r.mustKeybox(a).Grant
	if g.PermissionsAllowed == nil || !*g.PermissionsAllowed || g.TypingAllowed || g.DecidedAt == nil {
		t.Errorf("after permissions: %+v", g)
	}
	if err := r.c.Allow(id, GrantPermissions, false); err != nil {
		t.Fatal(err)
	}
	if err := r.c.Allow(id, GrantTyping, true); err != nil {
		t.Fatal(err)
	}
	g = r.mustKeybox(a).Grant
	if g.PermissionsAllowed != nil || !g.TypingAllowed {
		t.Errorf("after typing: %+v", g)
	}
	// Start sessions counts only with typing allowed and the phone's toggle on.
	if g.StartSessionsGranted == nil || *g.StartSessionsGranted {
		t.Errorf("start sessions before the grant: %+v", g.StartSessionsGranted)
	}
	if err := r.c.Allow(id, GrantStartSessions, true); err != nil {
		t.Fatal(err)
	}
	if g = r.mustKeybox(a).Grant; g.StartSessionsGranted == nil || !*g.StartSessionsGranted {
		t.Errorf("start sessions granted: %+v", g.StartSessionsGranted)
	}
	if err := r.c.Allow(id, Grant("everything"), true); !errors.Is(err, ErrUnknownGrant) {
		t.Errorf("unknown grant: %v", err)
	}
	if err := r.c.Allow(newPhone(t).id.String(), GrantTyping, true); !errors.Is(err, state.ErrNoDevice) {
		t.Errorf("unlinked device: %v", err)
	}
}

func TestEveryGrantAnnouncesOrderedActionsAndTransports(t *testing.T) {
	r := newRig(t)
	linked, revoked := newPhone(t), newPhone(t)
	r.confirmLinked(linked)
	r.confirmLinked(revoked)
	if err := r.c.Unlink(revoked.id.String()); err != nil {
		t.Fatal(err)
	}
	code := r.issue()
	r.handle(newPhone(t), code.Nonce) // pending
	r.advance(601 * time.Second)
	r.handle(newPhone(t), code.Nonce) // refused
	grants, err := r.c.Grants()
	if err != nil {
		t.Fatal(err)
	}
	if len(grants) != 4 {
		t.Fatalf("%d grants", len(grants))
	}
	for _, g := range grants {
		if g.OrderedActions == nil || *g.OrderedActions != 1 || !slices.Equal(g.Transports, []string{wire.TransportRelay}) ||
			g.RelayDeviceID != testRelayID || g.RelayAuthPub != testRelayPub || g.HubID != r.kr.HubID().String() {
			t.Errorf("grant %+v", g)
		}
	}
	if !grants[0].Linked {
		t.Errorf("linked phones first: %+v", grants[0])
	}
}

func TestGrantsKeepEveryLinkedPhoneAndCapTheRest(t *testing.T) {
	r := newRig(t)
	for range MaxGrantRecords + 2 {
		r.confirmLinked(newPhone(t))
		r.advance(time.Second)
	}
	code := r.issue()
	r.handle(newPhone(t), code.Nonce)
	grants, err := r.c.Grants()
	if err != nil {
		t.Fatal(err)
	}
	if len(grants) != MaxGrantRecords+2 {
		t.Fatalf("%d grants: every linked phone is published, the rest fill the room", len(grants))
	}
	for _, g := range grants {
		if !g.Linked {
			t.Errorf("unlinked row past the cap: %+v", g)
		}
	}
}

func TestFILES01_LinkLogsNoNamesOrKeys(t *testing.T) {
	sink := logcanary.Capture(t)
	r := newRig(t)
	name := logcanary.Text("device.name")
	code := r.issue()
	a, b := newPhone(t), newPhone(t)
	r.handle(a, code.Nonce, func(h *wire.DeviceHello) { h.Device.Name = name })
	r.handle(b, code.Nonce, func(h *wire.DeviceHello) { h.Device.Name = name })
	if err := r.c.Confirm(b.id.String(), "", false); err != nil {
		t.Fatal(err)
	}
	if err := r.c.Confirm(a.id.String(), r.code(a), true); err != nil {
		t.Fatal(err)
	}
	if err := r.c.Unlink(a.id.String()); err != nil {
		t.Fatal(err)
	}
	sink.AssertClean(t)
	if strings.Contains(sink.String(), code.Nonce) {
		t.Error("a link nonce reached the log")
	}
}

// A request replaced after the owner looked — here by a relay observer
// replaying the phone's older, still validly signed hello — is not linked
// by the owner's Link on the code they compared (Swift linkCodeChanged).
func TestConfirmOnAReplacedRequestIsCodeChanged(t *testing.T) {
	r := newRig(t)
	code := r.issue()
	_, sig, _ := ed25519.GenerateKey(rand.Reader)
	first, second := phoneWith(t, sig), phoneWith(t, sig)
	stale := r.hello(first, code.Nonce)
	if _, err := r.c.HandleHello("relay", first.name(), stale); err != nil {
		t.Fatal(err)
	}
	shown := r.handle(second, code.Nonce).Code // the phone re-rolled; the owner sees this code
	replayed, err := r.c.HandleHello("relay", first.name(), stale)
	if err != nil || replayed.Code == "" {
		t.Fatalf("replay: %+v %v", replayed, err)
	}
	if replayed.Code == shown {
		t.Skip("the replay's code collided with the shown one by chance (1 in 10 000)")
	}
	if err := r.c.Confirm(second.id.String(), shown, true); !errors.Is(err, ErrCodeChanged) {
		t.Fatalf("confirm on the replaced request: %v", err)
	}
	if r.linked(second) {
		t.Fatal("linked keys whose code the owner never compared")
	}
	if got := r.code(second); got != replayed.Code {
		t.Errorf("the request keeps waiting with its new code: %q", got)
	}
	// Confirming the code it shows now links it.
	if err := r.c.Confirm(second.id.String(), replayed.Code, true); err != nil {
		t.Fatal(err)
	}
	if !r.linked(second) {
		t.Error("not linked on the current code")
	}
}

// An Unlink while Keyboxes is between its device read and its key read
// waits for it: the unlinked phone never gets the epoch its unlink begins.
func TestKeyboxesNeverSealTheUnlinkEpochToTheUnlinkedPhone(t *testing.T) {
	r := newRig(t)
	a, b := newPhone(t), newPhone(t)
	r.confirmLinked(a)
	r.confirmLinked(b)
	before, _ := r.kr.CurrentEpoch()
	done := make(chan error, 1)
	r.c.beforeKeys = func() {
		r.c.beforeKeys = nil
		go func() { done <- r.c.Unlink(a.id.String()) }()
		time.Sleep(50 * time.Millisecond) // time enough for an unlocked Unlink to rotate
	}
	boxes, err := r.c.Keyboxes()
	if err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	for _, kb := range boxes {
		if kb.Keys != nil && kb.Keys.Epoch != before {
			t.Errorf("%s got epoch %d, the snapshot was under %d", kb.Grant.DeviceID, kb.Keys.Epoch, before)
		}
	}
	if after, _ := r.kr.CurrentEpoch(); after != before+1 {
		t.Errorf("the unlink did not rotate: %d", after)
	}
	if kb := r.mustKeybox(a); kb.Keys != nil || kb.Grant.Revoked == nil {
		t.Errorf("after the unlink: %+v", kb)
	}
}

// A linked phone that scans a new QR waits for the owner like any phone, but
// its keybox stays the linked one (the Swift DeviceGrantSlice: linked rows
// first, a phone appears once), with its keys and no confirm nonce.
func TestALinkedPhoneRescanningKeepsItsLinkedKeybox(t *testing.T) {
	r := newRig(t)
	a := newPhone(t)
	r.confirmLinked(a)
	code := r.issue()
	if got := r.handle(a, code.Nonce); got.Code == "" {
		t.Fatalf("re-scan: %+v", got)
	}
	if ids := pendingIDs(t, r.c); !slices.Equal(ids, sortedIDs(a)) {
		t.Fatalf("waiting %v", ids)
	}
	kb := r.mustKeybox(a)
	if !kb.Grant.Linked || kb.Keys == nil || kb.Grant.ConfirmNonce != nil || kb.Grant.AwaitingConfirmation != nil {
		t.Errorf("keybox %+v", kb)
	}
	grants, err := r.c.Grants()
	if err != nil || len(grants) != 1 {
		t.Errorf("one row per phone: %d %v", len(grants), err)
	}
}

// Publish runs after the center's lock is released: a callback that reads
// the keyboxes synchronously (as a publisher may) never deadlocks.
func TestPublishCallbackMayReadKeyboxes(t *testing.T) {
	r := newRig(t)
	var reads int
	r.c.publish = func(...string) {
		if _, err := r.c.Keyboxes(); err != nil {
			t.Error(err)
		}
		reads++
	}
	// The pairing runs here; a watchdog only waits. A deadlock never returns,
	// so the watchdog ends the run with a panic naming it.
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-done:
		case <-time.After(10 * time.Second):
			panic("TestPublishCallbackMayReadKeyboxes: a Publish callback reading Keyboxes deadlocked")
		}
	}()
	a, b := newPhone(t), newPhone(t)
	code := r.issue()
	r.handle(a, code.Nonce)
	r.handle(b, code.Nonce)
	if err := r.c.Confirm(b.id.String(), "", false); err != nil {
		t.Fatal(err)
	}
	if err := r.c.Confirm(a.id.String(), r.code(a), true); err != nil {
		t.Fatal(err)
	}
	if err := r.c.Allow(a.id.String(), GrantTyping, true); err != nil {
		t.Fatal(err)
	}
	if err := r.c.Unlink(a.id.String()); err != nil {
		t.Fatal(err)
	}
	r.advance(time.Hour)
	if err := r.c.Sweep(); err != nil {
		t.Fatal(err)
	}
	if reads < 6 {
		t.Errorf("published %d times", reads)
	}
}

// The revoke seam is told, after the commit and outside the lock, about a
// phone that lost its typing grant or was unlinked; granting, other grants
// and a no-op unlink tell it nothing.
func TestOnRevokeIsToldOfTypingRevokesAndUnlinks(t *testing.T) {
	r := newRig(t)
	a, b := newPhone(t), newPhone(t)
	r.confirmLinked(a)
	r.confirmLinked(b)
	var told []string
	r.c.OnRevoke(func(device string) {
		if _, err := r.c.Grants(); err != nil { // outside the lock: no deadlock
			t.Errorf("grants inside the seam: %v", err)
		}
		d, linked, _ := r.st.Device(device)
		if linked && d.TypingAllowed {
			t.Errorf("told before the revoke committed")
		}
		told = append(told, device)
	})
	steps := []func() error{
		func() error { return r.c.Allow(a.id.String(), GrantTyping, true) },
		func() error { return r.c.Allow(a.id.String(), GrantPermissions, false) },
		func() error { return r.c.Allow(a.id.String(), GrantTyping, false) },
		func() error { return r.c.Unlink(b.id.String()) },
	}
	for _, step := range steps {
		if err := step(); err != nil {
			t.Fatal(err)
		}
	}
	_ = r.c.Unlink(b.id.String()) // not linked any more: nothing to tell
	if want := []string{a.id.String(), b.id.String()}; !slices.Equal(told, want) {
		t.Fatalf("told %v, want %v", told, want)
	}
}

// TestLinkSecretsGoWhenTheRequestEnds: a request's four-digit code, confirm
// nonce and its copy of the link nonce live only in its pending_devices row,
// which goes when the link completes, is refused or its code expires. What
// stays is the code's own row (link_codes.nonce: a used or expired code is
// still told apart from an unknown one) and devices.link_nonce, an input of
// the phone's relay keys.
func TestLinkSecretsGoWhenTheRequestEnds(t *testing.T) {
	pendingRows := func(t *testing.T, r *rig) int {
		t.Helper()
		var n int
		if err := r.st.ReadTx(context.Background(), func(tx *sql.Tx) error {
			return tx.QueryRow(`SELECT COUNT(*) FROM pending_devices WHERE sas IS NOT NULL OR confirm_nonce IS NOT NULL OR link_nonce IS NOT NULL`).Scan(&n)
		}); err != nil {
			t.Fatal(err)
		}
		return n
	}
	for _, end := range []string{"linked", "refused", "expired"} {
		t.Run(end, func(t *testing.T) {
			r := newRig(t)
			code := r.issue()
			a := newPhone(t)
			r.handle(a, code.Nonce)
			if pendingRows(t, r) != 1 {
				t.Fatal("the request's row is not there while it waits")
			}
			switch end {
			case "linked":
				if err := r.c.Confirm(a.id.String(), r.code(a), true); err != nil {
					t.Fatal(err)
				}
			case "refused":
				if err := r.c.Confirm(a.id.String(), "", false); err != nil {
					t.Fatal(err)
				}
			case "expired":
				r.advance(601 * time.Second)
				if err := r.c.Sweep(); err != nil {
					t.Fatal(err)
				}
			}
			if n := pendingRows(t, r); n != 0 {
				t.Errorf("%d rows still hold a code or nonce after the request %s", n, end)
			}
		})
	}
}
