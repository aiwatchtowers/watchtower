package relay

import (
	"errors"
	"testing"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/relay/relayv1"
)

// TestRelayTransport_ObserveSavesReportsEachZone: the save observer hears nil
// per saved item and the call's error per zone of a save the relay refused
// whole; a failed precondition is not reported.
func TestRelayTransport_ObserveSavesReportsEachZone(t *testing.T) {
	h := newHarness(t)
	type seen struct {
		zone string
		err  error
	}
	var got []seen
	h.tr.ObserveSaves(func(zone string, err error) { got = append(got, seen{zone, err}) })
	box := transport.MailboxZone(h.tr.c.DeviceID(), "phone1")
	r2, err := h.sealer.Data(box, "target-2", "", []byte(`{}`), nil, "")
	if err != nil {
		t.Fatal(err)
	}
	h.relay.FailNext("save", relayv1.ErrorCode_ERROR_CODE_MAILBOX_QUOTA_EXCEEDED)
	if _, err := h.tr.Save(t.Context(), []transport.SaveItem{{Record: h.seal(t, "target-1", `{}`)}, {Record: r2}}); !errors.Is(err, transport.ErrMailboxQuota) {
		t.Fatalf("save: %v", err)
	}
	if len(got) != 2 || got[0].zone != h.data || got[1].zone != box ||
		!errors.Is(got[0].err, transport.ErrMailboxQuota) || !errors.Is(got[1].err, transport.ErrMailboxQuota) {
		t.Fatalf("observed %+v", got)
	}
	got = nil
	a := h.seal(t, "target-3", `{}`)
	if _, err := h.tr.Save(t.Context(), []transport.SaveItem{{Record: a}}); err != nil {
		t.Fatal(err)
	}
	// The second save of a conflicts (absent expected): not reported.
	if _, err := h.tr.Save(t.Context(), []transport.SaveItem{{Record: a, Expect: transport.Expect{Mode: transport.ExpectAbsent}}}); err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].zone != h.data || got[0].err != nil {
		t.Fatalf("observed %+v, want one success in the data zone", got)
	}
}

// TestRelayTransport_ConnectedFollowsTheConnection: not connected before
// Connect, connected after, not after Close.
func TestRelayTransport_ConnectedFollowsTheConnection(t *testing.T) {
	h := newHarness(t)
	if h.tr.Connected() {
		t.Fatal("connected before Connect")
	}
	if err := h.tr.Connect(t.Context(), nil); err != nil {
		t.Fatal(err)
	}
	if !h.tr.Connected() {
		t.Fatal("not connected after Connect")
	}
	_ = h.tr.Close()
	if h.tr.Connected() {
		t.Fatal("connected after Close")
	}
}
