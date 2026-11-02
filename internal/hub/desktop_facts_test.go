package hub

import (
	"context"
	"testing"
	"time"

	"watchtower/internal/hub/transport"
)

// acctShares is ckShares with a chosen iCloud account and rate limit.
type acctShares struct {
	*ckShares
	acct  transport.Account
	since time.Time
}

func (a *acctShares) AccountStatus(context.Context) (transport.Account, error) { return a.acct, nil }
func (a *acctShares) ThrottledSince() time.Time                                { return a.since }

// TestCloudKitStatusCarriesTheAccountAndTheThrottle: the "cloudkit" block
// of a desktop host's running hub holds the bridge's account (read at
// start, each cycle and on an account change) and since when CloudKit
// rate-limits it; Signed is false without a bridge or without the
// entitlement (Settings → Mobile's iCloud lines, plan 3 Task 23).
func TestCloudKitStatusCarriesTheAccountAndTheThrottle(t *testing.T) {
	f := &acctShares{ckShares: newCKShares(), acct: transport.AccountNoAccount}
	h := &hubRuntime{sup: &supervisor{o: Options{Desktop: &Desktop{}}}, tr: f, ck: f}
	if got := h.cloudKitStatus(); got != (CloudKitStatus{}) {
		t.Fatalf("before any read: %+v", got)
	}
	h.refreshCloudKitAccount(context.Background())
	since := time.Date(2026, 11, 2, 10, 0, 0, 0, time.UTC)
	f.since = since
	got := h.cloudKitStatus()
	if got.Account != string(transport.AccountNoAccount) || got.ThrottledSince != "2026-11-02T10:00:00Z" {
		t.Fatalf("block %+v", got)
	}
	f.acct, f.since = transport.AccountAvailable, time.Time{}
	h.refreshCloudKitAccount(context.Background()) // as on an AccountChanged event and each cycle
	if got := h.cloudKitStatus(); got.Account != string(transport.AccountAvailable) || got.ThrottledSince != "" {
		t.Fatalf("after an account change: %+v", got)
	}

	for _, c := range []struct {
		st   Status
		want bool
	}{
		{Status{Bridge: BridgeRunning, CloudKit: CloudKitStatus{Account: "available"}}, true},
		{Status{Bridge: BridgeRunning}, true},
		{Status{Bridge: BridgeUnavailable}, false},
		{Status{Bridge: BridgeRunning, CloudKit: CloudKitStatus{Account: string(transport.AccountNoEntitlement)}}, false},
	} {
		if got := signedBuild(c.st); got != c.want {
			t.Errorf("signedBuild(%+v) = %v", c.st, got)
		}
	}
	off := &hubRuntime{sup: &supervisor{o: Options{}}, tr: f, ck: f}
	f.acct = transport.AccountRestricted
	off.refreshCloudKitAccount(context.Background())
	if got := off.cloudKitStatus(); got.Account != "" {
		t.Fatalf("a headless host read the iCloud account: %+v", got)
	}
}

// TestHeartbeatCarriesTheLastPhoneContact: the desktop_heartbeat answer
// names when a phone was last in touch (the Desktop's keep-awake input),
// this run's or the one an earlier run stored; nothing before any contact,
// nothing while no hub runs.
func TestHeartbeatCarriesTheLastPhoneContact(t *testing.T) {
	r := newViewRig(t)
	s := r.s
	if a := s.handle(ControlRequest{Op: OpDesktopHeartbeat}, nil); !a.OK || a.PhoneContactAt != nil {
		t.Fatalf("no contact yet: %+v", a)
	}
	s.hub.st = s.st
	r.advance(time.Minute)
	s.hub.touch()
	a := s.handle(ControlRequest{Op: OpDesktopHeartbeat}, nil)
	if a.PhoneContactAt == nil || !a.PhoneContactAt.Equal(r.clock()) {
		t.Fatalf("contact %v, want %v", a.PhoneContactAt, r.clock())
	}
	touched := r.clock()
	s.hub.savePhoneContact()

	// A later run starts with the stored contact.
	next := &hubRuntime{sup: s, st: s.st}
	next.loadPhoneContact()
	if got := next.phoneContact(); !got.Equal(touched.Truncate(time.Second)) {
		t.Fatalf("stored contact %v, want %v", got, touched)
	}
	if v, ok, _ := s.st.Meta(metaPhoneContactAt); !ok || v == "" {
		t.Fatal("the contact was not stored")
	}

	s.hubMu.Lock()
	s.hub = nil
	s.hubMu.Unlock()
	if a := s.handle(ControlRequest{Op: OpDesktopHeartbeat}, nil); a.PhoneContactAt != nil {
		t.Fatalf("no hub, yet a contact: %+v", a)
	}
}
