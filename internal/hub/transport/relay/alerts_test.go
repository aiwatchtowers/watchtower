package relay

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/cloudkit"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/transport/relay/client"
	"watchtower/internal/hub/transport/relay/relayv1"
)

// alertRig is a registered hub held by one paying phone that reads its hub,
// on the fake relay, with a sealed push in hand.
type alertRig struct {
	*harness
	phone   *client.Client
	phoneID string
	push    secure.Push
}

func newAlertRig(t *testing.T) *alertRig {
	t.Helper()
	h := newHarness(t)
	if _, err := h.tr.c.Register(t.Context()); err != nil {
		t.Fatal(err)
	}
	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	pc := client.New(h.relay.URL, key, relayv1.DeviceKind_DEVICE_KIND_PHONE)
	if _, err := pc.Register(t.Context()); err != nil {
		t.Fatal(err)
	}
	if err := pc.VouchHub(t.Context(), h.key.Public().(ed25519.PublicKey)); err != nil {
		t.Fatal(err)
	}
	if _, err := pc.Do(t.Context(), &relayv1.Request{Op: &relayv1.Request_AddSlot{AddSlot: &relayv1.AddMacSlot{
		MacDeviceId: h.tr.c.DeviceID(),
	}}}); err != nil {
		t.Fatal(err)
	}
	if err := h.tr.SetHubReaders(t.Context(), []string{pc.DeviceID()}); err != nil {
		t.Fatal(err)
	}
	push, err := h.sealer.AlertPush("ask-42", secure.WorkAlertFields{
		Event: "ask", Key: "ask-42", WorkbenchID: 1, WorkbenchName: "acme", Title: "Review the plan", Body: "Plan ready",
	})
	if err != nil {
		t.Fatal(err)
	}
	return &alertRig{harness: h, phone: pc, phoneID: pc.DeviceID(), push: push}
}

func (r *alertRig) registerPush(t *testing.T) {
	t.Helper()
	if _, err := r.phone.Do(t.Context(), &relayv1.Request{Op: &relayv1.Request_RegisterPush{RegisterPush: &relayv1.RegisterPushToken{
		Token: "ab12cd34", Env: relayv1.PushEnv_PUSH_ENV_SANDBOX,
	}}}); err != nil {
		t.Fatal(err)
	}
}

// The request carries the phone's relay device id and the Push's bytes and
// nothing else; the relay accepts it (Ok) for a phone with a token.
func TestSendAlertSendsTheEnvelopeOnly(t *testing.T) {
	r := newAlertRig(t)
	r.registerPush(t)
	if err := r.tr.SendAlert(t.Context(), r.phoneID, r.push); err != nil {
		t.Fatal(err)
	}
	reqs := r.relay.Requests("send_alert")
	if len(reqs) != 1 {
		t.Fatalf("send_alert requests: %d", len(reqs))
	}
	want := &relayv1.SendAlert{PhoneDeviceId: r.phoneID, Envelope: r.push.Envelope()}
	if got := reqs[0].GetSendAlert(); !proto.Equal(got, want) {
		t.Fatalf("send_alert = %v, want only phone id and envelope", got)
	}
	sent := r.relay.Alerts()
	if len(sent) != 1 || sent[0].Phone != r.phoneID || !bytes.Equal(sent[0].Envelope, r.push.Envelope()) {
		t.Fatalf("alerts the relay pushed: %+v", sent)
	}
}

// A Push the Sealer did not build is refused before any request.
func TestSendAlertRefusesAnUnsealedPush(t *testing.T) {
	r := newAlertRig(t)
	r.registerPush(t)
	hits := r.relay.Hits()
	if err := r.tr.SendAlert(t.Context(), r.phoneID, secure.Push{}); !errors.Is(err, secure.ErrUnsealed) {
		t.Fatalf("unsealed push: %v, want secure.ErrUnsealed", err)
	}
	if r.relay.Hits() != hits || len(r.relay.Requests("send_alert")) != 0 {
		t.Fatal("an unsealed push reached the relay")
	}
}

func TestSendAlertErrorMapping(t *testing.T) {
	retry := func(s uint32) *uint32 { return &s }
	cases := []struct {
		name string
		e    *relayv1.Error
		want error
		not  error
	}{
		{"no token", &relayv1.Error{Code: relayv1.ErrorCode_ERROR_CODE_NOT_FOUND, Message: "not found"}, transport.ErrNoPushToken, nil},
		{"push off", &relayv1.Error{Code: relayv1.ErrorCode_ERROR_CODE_UNSPECIFIED, Message: "not implemented"}, transport.ErrPushOff, nil},
		{"other unspecified", &relayv1.Error{Code: relayv1.ErrorCode_ERROR_CODE_UNSPECIFIED, Message: "invalid request"}, nil, transport.ErrPushOff},
		{"forbidden", &relayv1.Error{Code: relayv1.ErrorCode_ERROR_CODE_FORBIDDEN, Message: "forbidden"}, transport.ErrForbidden, nil},
		{"not vouched", &relayv1.Error{Code: relayv1.ErrorCode_ERROR_CODE_HUB_NOT_VOUCHED, Message: "hub not vouched"}, transport.ErrNotVouched, nil},
		{"not paying", &relayv1.Error{Code: relayv1.ErrorCode_ERROR_CODE_ENTITLEMENT_INACTIVE, Message: "entitlement inactive"}, transport.ErrEntitlementInactive, nil},
		{"too large", &relayv1.Error{Code: relayv1.ErrorCode_ERROR_CODE_RECORD_TOO_LARGE, Message: "record too large"}, transport.ErrRecordTooLarge, nil},
		{"rate limited", &relayv1.Error{Code: relayv1.ErrorCode_ERROR_CODE_RATE_LIMITED, Message: "rate limited", RetryAfterS: retry(7)}, transport.ErrRateLimited, nil},
		{"traffic", &relayv1.Error{Code: relayv1.ErrorCode_ERROR_CODE_TRAFFIC_LIMIT_EXCEEDED, Message: "traffic limit exceeded"}, transport.ErrRateLimited, nil},
		{"unavailable", &relayv1.Error{Code: relayv1.ErrorCode_ERROR_CODE_UNAVAILABLE, Message: "unavailable"}, transport.ErrUnavailable, nil},
	}
	for _, c := range cases {
		err := mapAlertError(&client.Error{E: c.e})
		if c.want != nil && !errors.Is(err, c.want) {
			t.Errorf("%s: %v, want %v", c.name, err, c.want)
		}
		if c.not != nil && errors.Is(err, c.not) {
			t.Errorf("%s: %v reads as %v", c.name, err, c.not)
		}
		if client.Code(err) != c.e.GetCode() {
			t.Errorf("%s: code not kept: %v", c.name, err)
		}
	}
	if got := RetryAfter(mapAlertError(&client.Error{E: cases[7].e})); got != 7*time.Second {
		t.Errorf("RetryAfter = %v, want 7s", got)
	}
	if got := RetryAfter(mapAlertError(&client.Error{E: cases[8].e})); got != 0 {
		t.Errorf("RetryAfter with no retry_after_s = %v, want 0", got)
	}
	if RetryAfter(nil) != 0 || RetryAfter(errors.New("x")) != 0 {
		t.Error("RetryAfter of a non-relay error is not 0")
	}
	// NOT_FOUND keeps its generic mapping on every other op.
	if errors.Is(MapError(&client.Error{E: cases[0].e}), transport.ErrNoPushToken) {
		t.Error("MapError maps NOT_FOUND to ErrNoPushToken outside send_alert")
	}

	// Through the transport and the fake's modelled answers.
	r := newAlertRig(t)
	if err := r.tr.SendAlert(t.Context(), r.phoneID, r.push); !errors.Is(err, transport.ErrNoPushToken) {
		t.Errorf("no token: %v", err)
	}
	r.registerPush(t)
	r.relay.SetPushOff(true)
	if err := r.tr.SendAlert(t.Context(), r.phoneID, r.push); !errors.Is(err, transport.ErrPushOff) {
		t.Errorf("push off: %v", err)
	}
	r.relay.SetPushOff(false)
	r.relay.FailNextWith("send_alert", cases[7].e)
	err := r.tr.SendAlert(t.Context(), r.phoneID, r.push)
	if !errors.Is(err, transport.ErrRateLimited) || RetryAfter(err) != 7*time.Second {
		t.Errorf("rate limited: %v, retry after %v", err, RetryAfter(err))
	}
	if err := r.tr.SetHubReaders(t.Context(), nil); err != nil {
		t.Fatal(err)
	}
	if err := r.tr.SendAlert(t.Context(), r.phoneID, r.push); !errors.Is(err, transport.ErrForbidden) {
		t.Errorf("not a hub reader: %v", err)
	}
	if err := r.tr.SetHubReaders(t.Context(), []string{r.phoneID}); err != nil {
		t.Fatal(err)
	}
	r.relay.SetPaying(r.phoneID, false)
	if err := r.tr.SendAlert(t.Context(), r.phoneID, r.push); !errors.Is(err, transport.ErrEntitlementInactive) {
		t.Errorf("not paying: %v", err)
	}
	r.relay.SetPaying(r.phoneID, true)
	if err := r.tr.SendAlert(t.Context(), "other-phone", r.push); !errors.Is(err, transport.ErrForbidden) {
		t.Errorf("phone not holding the hub: %v", err)
	}
	r.relay.RemoveSlot(r.phoneID, r.tr.c.DeviceID())
	if err := r.tr.SendAlert(t.Context(), r.phoneID, r.push); !errors.Is(err, transport.ErrNotVouched) {
		t.Errorf("unvouched hub: %v", err)
	}
	if len(r.relay.Alerts()) != 0 {
		t.Fatalf("a refused alert was pushed: %+v", r.relay.Alerts())
	}
}

// Only the hosted relay pushes alerts itself; a hub on CloudKit (or the
// in-memory fake) writes signals instead and has no send_alert.
func TestCloudKitTransportHasNoAlerts(t *testing.T) {
	for name, tr := range map[string]transport.Transport{
		"memfake":  memfake.New(transport.KindCloudKit, time.Now),
		"cloudkit": cloudkit.New(cloudkit.Config{Dir: t.TempDir(), HubID: "hub", RelayID: "relay"}),
	} {
		if _, ok := tr.(transport.Alerts); ok {
			t.Errorf("%s implements transport.Alerts", name)
		}
	}
	var tr transport.Transport = newHarness(t).tr
	if _, ok := tr.(transport.Alerts); !ok {
		t.Error("the relay transport does not implement transport.Alerts")
	}
}
