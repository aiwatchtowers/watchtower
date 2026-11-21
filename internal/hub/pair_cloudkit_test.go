package hub

import (
	"context"
	"database/sql"
	"slices"
	"testing"

	"watchtower/internal/hub/link"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/switcher"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/cloudkit"
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
