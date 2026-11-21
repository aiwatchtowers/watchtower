package hub

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"slices"
	"testing"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/link"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/switcher"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/cloudkit"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/wire"
	"watchtower/internal/policy/policytest"
)

// startPairDesk runs a desktop host over an acctCK with an available iCloud
// account, active the transport given, no phone linked, and dials its
// control socket.
func startPairDesk(t *testing.T, active transport.Kind) (*deskRig, *acctCK, *ControlClient) {
	t.Helper()
	policytest.Set(t, nil)
	r := newDeskRig(t, shortDir(t))
	ck := newAcctCK(transport.AccountAvailable)
	r.ck = ck.Fake
	fctx, fcancel := context.WithCancel(context.Background())
	t.Cleanup(fcancel)
	go ck.forward(fctx)
	setMeta(t, r.dir, state.MetaEnabled, "1", switcher.MetaTransport, string(active))
	o := r.options()
	o.Desktop.newCloudKit = func(cloudkit.Config) transport.Transport {
		r.ckDial.Add(1)
		return ck
	}
	r.start(o)
	r.waitStatus("running on "+string(active), func(s Status) bool {
		return s.State == StateRunning && s.Transport == string(active) &&
			s.CloudKit.Account == string(transport.AccountAvailable)
	})
	c := r.dial()
	t.Cleanup(func() { _ = c.Close() })
	return r, ck, c
}

// pairCode asks for a code and parses the qr event's link.
func pairCode(t *testing.T, c *ControlClient) wire.LinkPayload {
	t.Helper()
	qr := pairStep(t, c, ControlRequest{Op: OpPair}, link.EventQR, link.EventWaiting)[link.EventQR]
	lp, err := wire.ParseLinkURL(qr.URL)
	if err != nil {
		t.Fatal(err)
	}
	return lp
}

// codesStored counts the sidecar's link codes, read through a second handle.
func codesStored(t *testing.T, dir string) int {
	t.Helper()
	st, err := state.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = st.Close() }()
	var n int
	if err := st.ReadTx(context.Background(), func(tx *sql.Tx) error {
		return tx.QueryRow(`SELECT COUNT(*) FROM link_codes`).Scan(&n)
	}); err != nil {
		t.Fatal(err)
	}
	return n
}

// #1127: a desktop host on CloudKit issues a CloudKit code (the shares'
// link, transport cloudkit), so the phone links on the transport the hub
// publishes on; a relay code there linked a paying phone over a pairing
// slot onto the relay, where the hub never wrote its heartbeat.
func TestPairOnACloudKitDesktopIssuesACloudKitCode(t *testing.T) {
	bubble(t, func(t *testing.T) {
		_, ck, c := startPairDesk(t, transport.KindCloudKit)
		lp := pairCode(t, c)
		if lp.Transport != wire.TransportCloudKit ||
			!slices.Equal(lp.Transports, []string{wire.TransportCloudKit, wire.TransportRelay}) {
			t.Fatalf("transport %q, transports %v: want a CloudKit code", lp.Transport, lp.Transports)
		}
		if lp.Container == "" || lp.OwnerUser != "_owner-acme" || lp.DataShare == nil || lp.RelayShare == nil {
			t.Fatalf("CloudKit fields missing: %+v", lp)
		}
		if lp.RelayDeviceID == "" || lp.RelayAuthPub == "" {
			t.Fatalf("the relay identity is kept: %+v", lp)
		}
		if n := ck.count("set_public_link:open"); n != 1 {
			t.Fatalf("the shares' public link opened %d times, want 1", n)
		}
	})
}

// On the relay the desktop host keeps the relay code and makes no share call.
func TestPairOnARelayDesktopIssuesARelayCode(t *testing.T) {
	bubble(t, func(t *testing.T) {
		_, ck, c := startPairDesk(t, transport.KindRelay)
		lp := pairCode(t, c)
		if lp.Transport != wire.TransportRelay || lp.Container != "" || lp.OwnerUser != "" || lp.DataShare != nil {
			t.Fatalf("want a relay code, got %+v", lp)
		}
		if n := ck.count("ensure_shares") + ck.count("set_public_link"); n != 0 {
			t.Fatalf("%d share calls for a relay code", n)
		}
	})
}

// With CloudKit active and the iCloud account gone, the pair is refused
// no_icloud and no code is issued.
func TestPairOnACloudKitDesktopWithoutICloudIsRefused(t *testing.T) {
	bubble(t, func(t *testing.T) {
		r, ck, c := startPairDesk(t, transport.KindCloudKit)
		ck.acct.Store(transport.AccountNoAccount)
		if err := c.Send(ControlRequest{Op: OpPair}); err != nil {
			t.Fatal(err)
		}
		for {
			a, err := c.Next()
			if err != nil {
				t.Fatal(err)
			}
			if a.Event == link.EventQR {
				t.Fatal("a qr event without an iCloud account")
			}
			if a.Event == "" && a.Op == OpPair {
				if a.Error != ErrClassNoICloud {
					t.Fatalf("answer %+v, want %s", a, ErrClassNoICloud)
				}
				break
			}
		}
		if n := codesStored(t, r.dir); n != 0 {
			t.Fatalf("%d codes stored", n)
		}
		if n := ck.count("set_public_link:open"); n != 0 {
			t.Fatalf("the public link opened %d times", n)
		}
	})
}

// A CloudKit code's refusals: a real account state (no account, restricted,
// no entitlement) is no_icloud; an account or owner that could not be read
// just now is icloud_unreachable (try again); an account change while the
// code was made is icloud_changed.
func TestLinkErrClassForCloudKitCodes(t *testing.T) {
	for _, tc := range []struct {
		err  error
		want string
	}{
		{&link.AccountError{Account: transport.AccountNoAccount}, ErrClassNoICloud},
		{&link.AccountError{Account: transport.AccountRestricted}, ErrClassNoICloud},
		{&link.AccountError{Account: transport.AccountNoEntitlement}, ErrClassNoICloud},
		{&link.AccountError{Account: transport.AccountTemporarilyUnavailable}, ErrClassICloudUnreachable},
		{&link.AccountError{Account: link.AccountUnreadable, Err: transport.ErrUnavailable}, ErrClassICloudUnreachable},
		{link.ErrOwnerUnknown, ErrClassICloudUnreachable},
		{fmt.Errorf("wrapped: %w", link.ErrAccountChanged), ErrClassICloudChanged},
		{errors.New("link: storing the code: disk full"), ErrClassFailed},
	} {
		if got := LinkErrClass(tc.err); got != tc.want {
			t.Errorf("%v: %s, want %s", tc.err, got, tc.want)
		}
	}
}

// An iCloud account the bridge reports only for now unavailable refuses the
// pair as retryable, with nothing issued.
func TestPairOnACloudKitDesktopWithICloudBriefyUnavailableIsRetryable(t *testing.T) {
	bubble(t, func(t *testing.T) {
		r, ck, c := startPairDesk(t, transport.KindCloudKit)
		ck.acct.Store(transport.AccountTemporarilyUnavailable)
		if a := pairRefusal(t, c); a != ErrClassICloudUnreachable {
			t.Fatalf("answer %s, want %s", a, ErrClassICloudUnreachable)
		}
		if n := codesStored(t, r.dir); n != 0 {
			t.Fatalf("%d codes stored", n)
		}
	})
}

// pairRefusal asks for a code and returns the answer's error class, failing
// on a qr event first.
func pairRefusal(t *testing.T, c *ControlClient) string {
	t.Helper()
	if err := c.Send(ControlRequest{Op: OpPair}); err != nil {
		t.Fatal(err)
	}
	for {
		a, err := c.Next()
		if err != nil {
			t.Fatal(err)
		}
		if a.Event == link.EventQR {
			t.Fatal("a qr event for a refused pair")
		}
		if a.Event == "" && a.Op == OpPair {
			return a.Error
		}
	}
}

// A hub on CloudKit without the shares seam never falls back to a relay code
// (the #1127 bug: the phone would link where the hub does not publish): the
// pair is refused failed and nothing is issued.
func TestPairOnCloudKitWithoutSharesIsRefused(t *testing.T) {
	bubble(t, func(t *testing.T) {
		h := startCloudKitHub(t, nil, func(o *Options) {
			plain := memfake.New(transport.KindCloudKit, nil)
			o.newTransport = func(context.Context, identity.Identity, *state.Store, []string) (transport.Transport, error) {
				return plain, nil
			}
		})
		if a := pairRefusal(t, h.c); a != ErrClassFailed {
			t.Fatalf("answer %s, want %s", a, ErrClassFailed)
		}
		if n := codesStored(t, h.dir); n != 0 {
			t.Fatalf("%d codes stored", n)
		}
	})
}

// A hub stopped with a CloudKit code on screen (Mobile turned off) closes
// the shares' public link before its bridge stops: the share URLs do not
// outlive the code until the next start.
func TestStoppingTheHubClosesAnOpenCloudKitLink(t *testing.T) {
	bubble(t, func(t *testing.T) {
		h := startCloudKitHub(t, nil, nil)
		pairCode(t, h.c)
		if n := h.ck.count("set_public_link:open"); n != 1 {
			t.Fatalf("public link opened %d times", n)
		}
		closes := h.ck.count("set_public_link:close")
		if a, err := h.c.Do(ControlRequest{Op: OpDisable}); err != nil || !a.OK {
			t.Fatalf("disable: %+v, %v", a, err)
		}
		h.waitState(StateOff, ReasonDisabled)
		eventually(t, "the public link closed at the stop", func() bool {
			return h.ck.count("set_public_link:close") > closes
		})
		if h.sweepMark() != "1" {
			t.Fatalf("sweep mark %q: the participants' sweep is the next start's", h.sweepMark())
		}
	})
}
