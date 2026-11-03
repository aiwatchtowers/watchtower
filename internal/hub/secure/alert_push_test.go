package secure

import (
	"crypto/ed25519"
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"testing"
	"unicode/utf8"
)

func int64p(v int64) *int64 { return &v }

// pushFields is a work alert with every optional id set.
func pushFields(key, workbench, title, body string) WorkAlertFields {
	return WorkAlertFields{
		Event: "ask", Key: key, WorkbenchID: 7, WorkbenchName: workbench,
		SessionID: int64p(9), AskID: int64p(42), RequestID: int64p(11),
		Title: title, Body: body, Quick: true,
	}
}

// openPush is the NSE's AlertOpener in Go: class alert only, signed by
// hub_sig, sender = hub, under K_alert, with the AAD of wire in the data zone.
func openPush(t *testing.T, ks *InMemoryKeySource, wire string, env []byte) (Header, InnerFrame, error) {
	t.Helper()
	h, f, err := OpenSymmetric(env, []EnvelopeClass{ClassAlert}, Context{Zone: ZoneData, WireName: wire},
		ks.k.hubSig.Public().(ed25519.PublicKey), func(Header) ([]byte, error) { return alertKey, nil })
	if err == nil && h.Sender != h.Hub {
		return h, f, ErrWrongSender
	}
	return h, f, err
}

func decodePush(t *testing.T, f InnerFrame) WorkAlertFields {
	t.Helper()
	var got WorkAlertFields
	if err := json.Unmarshal(f.Payload, &got); err != nil {
		t.Fatalf("payload does not decode: %v", err)
	}
	return got
}

func TestAlertPushOpensUnderTheFixedWireName(t *testing.T) {
	ks := newKeySource(t)
	in := pushFields("ask-42", "Acme", "Acme · Build", "Which database?")
	p, err := NewSealer(ks).AlertPush("ask-42", in)
	if err != nil {
		t.Fatal(err)
	}
	if !p.Sealed() || p.Key() != "ask-42" {
		t.Fatalf("push sealed=%v key=%q", p.Sealed(), p.Key())
	}
	h, f, err := openPush(t, ks, AlertPushWireName, p.Envelope())
	if err != nil {
		t.Fatal(err)
	}
	if h.Class != ClassAlert || h.Sender != fixtureHubID || h.Hub != fixtureHubID || h.Epoch != ks.epoch {
		t.Errorf("header %+v", h)
	}
	if f.Kind != "ask_alert" || f.ID != "ask_alert-ask-42" || f.NotifyLevel != "" || f.Asset != nil {
		t.Errorf("frame %q %q %q", f.Kind, f.ID, f.NotifyLevel)
	}
	if got := decodePush(t, f); !pushEqual(got, in) {
		t.Errorf("payload %+v, want %+v", got, in)
	}
	// The envelope is a copy.
	env := p.Envelope()
	env[0] ^= 0xFF
	if _, _, err := openPush(t, ks, AlertPushWireName, p.Envelope()); err != nil {
		t.Errorf("Envelope() is not a copy: %v", err)
	}
}

func TestAlertPushDoesNotOpenUnderTheRecordWireName(t *testing.T) {
	ks := newKeySource(t)
	s := NewSealer(ks)
	p, err := s.AlertPush("ask-42", pushFields("ask-42", "Acme", "Acme", "Which database?"))
	if err != nil {
		t.Fatal(err)
	}
	record, err := s.WireName(ZoneData, "ask_alert-ask-42")
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := openPush(t, ks, record, p.Envelope()); !errors.Is(err, ErrSignatureInvalid) && !errors.Is(err, ErrAuthenticationFailed) {
		t.Errorf("push opened under the record's wire name: %v", err)
	}
	// And the record never opens as a push.
	r, err := s.Alert("DataZone", "ask_alert-ask-42", []byte(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := openPush(t, ks, AlertPushWireName, r.Envelope()); err == nil {
		t.Error("record opened under alert-push")
	}
}

func TestAlertPushFitsWorstCaseRunes(t *testing.T) {
	ks := newKeySource(t)
	emoji := func(n int) string { return strings.Repeat("😀", n) }
	in := pushFields("stop-12-1730000000123", emoji(60), emoji(123), emoji(120))
	p, err := NewSealer(ks).AlertPush(in.Key, in)
	if err != nil {
		t.Fatal(err)
	}
	if n := len(p.Envelope()); n > AlertPushMaxEnvelope || n != alertPushEnvelope {
		t.Fatalf("envelope %d bytes, want %d (max %d)", n, alertPushEnvelope, AlertPushMaxEnvelope)
	}
	_, f, err := openPush(t, ks, AlertPushWireName, p.Envelope())
	if err != nil {
		t.Fatal(err)
	}
	got := decodePush(t, f)
	if got.Key != in.Key || f.ID != "ask_alert-"+in.Key || p.Key() != in.Key {
		t.Errorf("key changed: %q / %q", got.Key, f.ID)
	}
	if !utf8.ValidString(got.Body) || !strings.HasSuffix(got.Body, "…") || !strings.HasPrefix(in.Body, strings.TrimSuffix(got.Body, "…")) {
		t.Errorf("body not clipped on a rune boundary with …: %q", got.Body)
	}
	if !utf8.ValidString(got.Title) || !strings.HasPrefix(in.Title, strings.TrimSuffix(got.Title, "…")) {
		t.Errorf("title not a rune-safe prefix: %q", got.Title)
	}
	// Everything but the texts stays as it was.
	got.Title, got.Body = in.Title, in.Body
	if !pushEqual(got, in) {
		t.Errorf("other fields changed: %+v", got)
	}
	// Body goes first: the title is clipped only when an empty body is not enough.
	if got := decodePush(t, f); got.Title != in.Title && got.Body != "" {
		t.Errorf("title clipped while the body still has text: %q / %q", got.Title, got.Body)
	}
}

func TestAlertPushClipsTheTitleOnceTheBodyIsGone(t *testing.T) {
	ks := newKeySource(t)
	in := pushFields("ask-42", strings.Repeat("😀", 60), strings.Repeat("😀", 250), strings.Repeat("😀", 120))
	p, err := NewSealer(ks).AlertPush("ask-42", in)
	if err != nil {
		t.Fatal(err)
	}
	_, f, err := openPush(t, ks, AlertPushWireName, p.Envelope())
	if err != nil {
		t.Fatal(err)
	}
	got := decodePush(t, f)
	if got.Body != "" || !strings.HasSuffix(got.Title, "…") || got.WorkbenchName != in.WorkbenchName {
		t.Errorf("title %q body %q", got.Title, got.Body)
	}
}

func TestAlertPushTooLargeEvenWithEmptyTexts(t *testing.T) {
	in := pushFields("ask-42", strings.Repeat("😀", 300), "a", "b")
	if _, err := NewSealer(newKeySource(t)).AlertPush("ask-42", in); !errors.Is(err, ErrAlertTooLarge) {
		t.Errorf("err %v, want ErrAlertTooLarge", err)
	}
}

func TestAlertPushKeepsShortTextAsIs(t *testing.T) {
	ks := newKeySource(t)
	in := pushFields("ask-42", strings.Repeat("w", 60), strings.Repeat("w", 60)+" · "+strings.Repeat("s", 60), strings.Repeat("b", 120))
	p, err := NewSealer(ks).AlertPush("ask-42", in)
	if err != nil {
		t.Fatal(err)
	}
	if n := len(p.Envelope()); n != 1172 {
		t.Errorf("envelope %d bytes, want 1172", n)
	}
	_, f, err := openPush(t, ks, AlertPushWireName, p.Envelope())
	if err != nil {
		t.Fatal(err)
	}
	if got := decodePush(t, f); !pushEqual(got, in) {
		t.Errorf("clipped: %+v", got)
	}
	// A tiny alert is padded to the same bucket: the push's length says nothing about its text.
	small, err := NewSealer(ks).AlertPush("ask-1", pushFields("ask-1", "A", "A", "B"))
	if err != nil {
		t.Fatal(err)
	}
	if n := len(small.Envelope()); n != 1172 {
		t.Errorf("small envelope %d bytes, want 1172", n)
	}
}

// TestAlertPushPayloadKeysMatchTheKit pins the JSON keys to the Kit's
// WorkAlertPayload.CodingKeys (AlertOpener.swift).
func TestAlertPushPayloadKeysMatchTheKit(t *testing.T) {
	ks := newKeySource(t)
	p, err := NewSealer(ks).AlertPush("ask-42", pushFields("ask-42", "Acme", "Acme", "Which database?"))
	if err != nil {
		t.Fatal(err)
	}
	_, f, err := openPush(t, ks, AlertPushWireName, p.Envelope())
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(f.Payload, &m); err != nil {
		t.Fatal(err)
	}
	var keys []string
	for k := range m {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	want := []string{"ask_id", "body", "event", "key", "quick", "request_id", "session_id", "title", "workbench_id", "workbench_name"}
	if !slices.Equal(keys, want) {
		t.Errorf("keys %v, want %v", keys, want)
	}
}

func TestAlertPushRefusesAKeyThePayloadDoesNotCarry(t *testing.T) {
	s := NewSealer(newKeySource(t))
	if _, err := s.AlertPush("ask-43", pushFields("ask-42", "Acme", "Acme", "x")); !errors.Is(err, ErrNameMismatch) {
		t.Errorf("mismatched key: %v", err)
	}
	if _, err := s.AlertPush("", pushFields("", "Acme", "Acme", "x")); !errors.Is(err, ErrNameMismatch) {
		t.Errorf("empty key: %v", err)
	}
}

func TestZeroPushIsNotSealed(t *testing.T) {
	var p Push
	if p.Sealed() || p.Envelope() != nil || p.Key() != "" {
		t.Errorf("zero push %+v", p)
	}
}

func pushEqual(a, b WorkAlertFields) bool {
	ptr := func(x, y *int64) bool { return (x == nil) == (y == nil) && (x == nil || *x == *y) }
	return a.Event == b.Event && a.Key == b.Key && a.WorkbenchID == b.WorkbenchID && a.WorkbenchName == b.WorkbenchName &&
		ptr(a.SessionID, b.SessionID) && ptr(a.AskID, b.AskID) && ptr(a.RequestID, b.RequestID) &&
		a.Title == b.Title && a.Body == b.Body && a.Quick == b.Quick
}
