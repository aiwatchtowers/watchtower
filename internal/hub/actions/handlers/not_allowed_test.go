package handlers

import (
	"testing"

	"watchtower/internal/hub/wire"
)

// #1783 follow-up (ask #1322): a device_not_allowed refusal says how to allow
// it on this hub's kind — the Mac app's Settings → Mobile on a Mac hub, and
// `watchtower hub allow` with the requesting phone's id on a server hub.

func TestNotAllowedMessagesOnAMacHub(t *testing.T) {
	e := newEnv(t)
	if got := e.h.typingNotAllowed(e.device); got != "This phone is not allowed to type into sessions — Allow it in Settings → Mobile on the Mac" {
		t.Fatalf("typing: %q", got)
	}
	want := "This phone is not allowed to start sessions. On the Mac: Watchtower → Settings → Mobile → allow typing, then starting sessions."
	if got := e.h.startNotAllowed(startNotAllowedLead, e.device); got != want {
		t.Fatalf("start: %q", got)
	}
}

func TestNotAllowedMessagesOnAServerHubNameHubAllowWithThePhonesID(t *testing.T) {
	e := newEnv(t)
	e.h.d.ServerHost = true
	id := e.device.String()

	if got, want := e.h.typingNotAllowed(e.device),
		"This phone is not allowed to type into sessions. On your tower, run:\nwatchtower hub allow "+id+" typing"; got != want {
		t.Fatalf("typing: %q, want %q", got, want)
	}
	// A held line ended by a revoke reads the same.
	if o := e.h.lineFailure(inputReasonDeviceNotAllowed, e.device); o.Message != e.h.typingNotAllowed(e.device) {
		t.Fatalf("line failure: %+v", o)
	}

	e.linkDevice(true, false, false)
	wb := e.workbench()
	got := e.runAction(e.automation(wb, recipe{confirmedHash: "h1"}), wb, false)
	wantOutcome(t, got, wire.StatusFailed, reasonDeviceNotAllowed)
	want := "This phone is not allowed to run automations. On your tower, run:\n" +
		"watchtower hub allow " + id + " typing\nwatchtower hub allow " + id + " start_sessions"
	if got.Message != want {
		t.Fatalf("automation: %q, want %q", got.Message, want)
	}
}

func TestAServerHubsStartRefusalNamesHubAllow(t *testing.T) {
	le := startEnv(t)
	le.h.d.ServerHost = true
	le.setStartGrants(false, true)
	target := le.target(le.wb, 0, "Ship it")

	out := le.startOutcome(&target, startParams(le.wb, "new", false, nil))

	id := le.device.String()
	want := "This phone is not allowed to start sessions. On your tower, run:\n" +
		"watchtower hub allow " + id + " typing\nwatchtower hub allow " + id + " start_sessions"
	if out.Status != wire.StatusFailed || out.Reason != reasonDeviceNotAllowed || out.Message != want {
		t.Fatalf("%+v", out)
	}
}
