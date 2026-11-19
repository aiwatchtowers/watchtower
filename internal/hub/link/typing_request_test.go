package link

import (
	"strings"
	"testing"

	"watchtower/internal/hub/wire"
)

// PROJ-16 (spec §10, OD-2): a phone asking to type asks the owner once per
// request; Desktop turns OnTypingRequest into its macOS notice.

// twin of MobileLinkCenterTests.testATypingRequestAsksTheOwnerOnce
func TestATypingRequestAsksTheOwnerOnce(t *testing.T) {
	r := newRig(t)
	a := newPhone(t)
	var asked []string
	r.c.OnTypingRequest(func(device, name string) { asked = append(asked, device+" "+name) })
	r.confirmLinked(a)
	if len(asked) != 0 {
		t.Fatalf("a phone linking with typing off asked %v", asked)
	}

	on := func(d *wire.DevicePayload) { d.Name, d.TypingRequested = "Colleague A's iPhone", true }
	r.rewriteRecord(a, on)
	r.rewriteRecord(a, on)
	want := strings.ToUpper(a.id.String()) + " Colleague A's iPhone"
	if len(asked) != 1 || asked[0] != want {
		t.Fatalf("asked %v, want once %q", asked, want)
	}

	// Allowed, the same request asks nothing; turned off and on again, it asks again.
	if err := r.c.Allow(a.id.String(), GrantTyping, true); err != nil {
		t.Fatal(err)
	}
	r.rewriteRecord(a, on)
	if len(asked) != 1 {
		t.Fatalf("an allowed phone asked again: %v", asked)
	}
	r.rewriteRecord(a, func(d *wire.DevicePayload) { d.TypingRequested = false })
	r.rewriteRecord(a, on)
	if len(asked) != 2 {
		t.Fatalf("turned off and on again: asked %v, want twice", asked)
	}
}

// twin of MobileLinkCenterTests.testAPhoneLinkingWithTypingOnAsks
func TestAPhoneLinkingWithTypingOnAsks(t *testing.T) {
	r := newRig(t)
	a := newPhone(t)
	var asked []string
	r.c.OnTypingRequest(func(device, _ string) { asked = append(asked, device) })
	code := r.issue()
	if got := r.handle(a, code.Nonce, func(h *wire.DeviceHello) { h.Device.TypingRequested = true }); got.Code == "" {
		t.Fatalf("hello not waiting: %+v", got)
	}
	if len(asked) != 0 {
		t.Fatalf("asked %v before the owner linked the phone", asked)
	}
	if err := r.c.Confirm(a.id.String(), r.code(a), true); err != nil {
		t.Fatal(err)
	}
	if len(asked) != 1 || asked[0] != strings.ToUpper(a.id.String()) {
		t.Fatalf("asked %v, want the linked phone once", asked)
	}
	if row := r.device(a); row.typing {
		t.Error("a request is never a grant")
	}
}
