package hub

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"watchtower/internal/hub/hubtest"
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
// control socket. edit changes the rig's options before the start (noRelay
// takes the relay away).
func startPairDesk(t *testing.T, active transport.Kind, edit ...func(*Options)) (*deskRig, *acctCK, *ControlClient) {
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
	for _, e := range edit {
		e(&o)
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

// noRelay is a desktop host without a relay origin: CloudKit only.
func noRelay(o *Options) { o.RelayOrigin = "" }

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
	// A Mac without a relay offers CloudKit alone: a paying phone is never
	// sent to a relay that is not there.
	bubble(t, func(t *testing.T) {
		_, _, c := startPairDesk(t, transport.KindCloudKit, noRelay)
		lp := pairCode(t, c)
		if lp.Transport != wire.TransportCloudKit || !slices.Equal(lp.Transports, []string{wire.TransportCloudKit}) {
			t.Fatalf("without a relay: transport %q, transports %v, want cloudkit only", lp.Transport, lp.Transports)
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

// With CloudKit active, no relay and the iCloud account gone, the pair is
// refused no_icloud and no code is issued.
func TestPairOnACloudKitDesktopWithoutICloudIsRefused(t *testing.T) {
	bubble(t, func(t *testing.T) {
		r, ck, c := startPairDesk(t, transport.KindCloudKit, noRelay)
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

// pairRelayCode asks for a code and wants a relay code (no CloudKit fields)
// answered OK, one code stored and the shares' public link never opened.
func pairRelayCode(t *testing.T, r *deskRig, ck *acctCK, c *ControlClient) {
	t.Helper()
	if err := c.Send(ControlRequest{Op: OpPair}); err != nil {
		t.Fatal(err)
	}
	var (
		qr     *ControlAnswer
		answer *ControlAnswer
	)
	for qr == nil || answer == nil {
		a, err := c.Next()
		if err != nil {
			t.Fatal(err)
		}
		switch {
		case a.Event == link.EventQR:
			qr = &a
		case a.Event == "" && a.Op == OpPair:
			if !a.OK || a.Error != "" {
				t.Fatalf("answer %+v, want OK", a)
			}
			answer = &a
		}
	}
	lp, err := wire.ParseLinkURL(qr.URL)
	if err != nil {
		t.Fatal(err)
	}
	if lp.Transport != wire.TransportRelay || lp.Container != "" || lp.OwnerUser != "" ||
		lp.DataShare != nil || lp.RelayShare != nil || lp.RelayDeviceID == "" {
		t.Fatalf("want a relay code, got %+v", lp)
	}
	if n := codesStored(t, r.dir); n != 1 {
		t.Fatalf("%d codes stored, want 1", n)
	}
	if n := ck.count("set_public_link:open"); n != 0 {
		t.Fatalf("the public link opened %d times", n)
	}
}

// F7: with CloudKit active and iCloud unusable (gone, or reported
// unavailable), a Mac with a relay answers like a relay hub: a relay code
// over a pairing slot, and the public link never opens.
func TestPairOnACloudKitDesktopWithoutICloudFallsBackToARelayCode(t *testing.T) {
	for _, tc := range []struct {
		name    string
		account transport.Account
	}{
		{ErrClassNoICloud, transport.AccountNoAccount},
		{ErrClassICloudUnreachable, transport.AccountTemporarilyUnavailable},
	} {
		t.Run(tc.name, func(t *testing.T) {
			bubble(t, func(t *testing.T) {
				r, ck, c := startPairDesk(t, transport.KindCloudKit)
				ck.acct.Store(tc.account)
				pairRelayCode(t, r, ck, c)
			})
		})
	}
}

// A relay code that replaces a CloudKit code refuses the phone waiting
// under it (expired_code) on the stream that showed its SAS only: the stream
// asking for the relay code has no phone bound and must not end.
func TestARelayCodeRefusesTheReplacedPhoneOnlyOnItsSASStream(t *testing.T) {
	bubble(t, func(t *testing.T) {
		r, ck, shown := startPairDesk(t, transport.KindCloudKit)
		lp := pairCode(t, shown)
		phone, err := hubtest.FromLink(lp, ck.Fake, nil)
		if err != nil {
			t.Fatal(err)
		}
		if err := phone.Hello(transport.SharedMailboxZone(lp.RelayDeviceID)); err != nil {
			t.Fatal(err)
		}
		for {
			a, err := shown.Next()
			if err != nil {
				t.Fatal(err)
			}
			if a.Event == link.EventSAS {
				break
			}
		}
		ck.acct.Store(transport.AccountNoAccount)
		fresh := r.dial()
		t.Cleanup(func() { _ = fresh.Close() })
		if err := fresh.Send(ControlRequest{Op: OpPair}); err != nil {
			t.Fatal(err)
		}
		for qr, answered := false, false; !qr || !answered; {
			a, err := fresh.Next()
			if err != nil {
				t.Fatal(err)
			}
			switch {
			case a.Event == link.EventRefused:
				t.Fatalf("the new code's stream got %+v", a)
			case a.Event == link.EventQR:
				qr = true
			case a.Event == "" && a.Op == OpPair:
				if !a.OK {
					t.Fatalf("answer %+v, want a relay code", a)
				}
				answered = true
			}
		}
		for {
			a, err := shown.Next()
			if err != nil {
				t.Fatal(err)
			}
			if a.Event != link.EventRefused {
				continue
			}
			if !strings.EqualFold(a.DeviceID, phone.ID().String()) || a.Reason != wire.RefusedExpiredCode {
				t.Fatalf("refusal %+v, want the waiting phone's expired_code", a)
			}
			break
		}
	})
}

// Two pairing streams at once: A asks for a code, then B. A is shown neither
// B's qr nor the SAS of B's phone; B is shown its phone's SAS.
func TestTwoPairStreamsSeeOnlyTheirOwnCodes(t *testing.T) {
	bubble(t, func(t *testing.T) {
		r, ck, a := startPairDesk(t, transport.KindCloudKit)
		pairCode(t, a)
		b := r.dial()
		t.Cleanup(func() { _ = b.Close() })
		lp := pairCode(t, b)
		phone, err := hubtest.FromLink(lp, ck.Fake, nil)
		if err != nil {
			t.Fatal(err)
		}
		if err := phone.Hello(transport.SharedMailboxZone(lp.RelayDeviceID)); err != nil {
			t.Fatal(err)
		}
		for {
			ev, err := b.Next()
			if err != nil {
				t.Fatal(err)
			}
			if ev.Event == link.EventSAS {
				if !strings.EqualFold(ev.DeviceID, phone.ID().String()) {
					t.Fatalf("B's SAS %+v, want its phone", ev)
				}
				break
			}
		}
		// A has read its own code's lines; anything more before the deadline
		// (on the bubble's clock) is another stream's.
		_ = a.c.SetReadDeadline(time.Now().Add(time.Minute))
		ev, err := a.Next()
		var ne net.Error
		if err == nil || !errors.As(err, &ne) || !ne.Timeout() {
			t.Fatalf("A was shown %+v (err %v): another stream's event", ev, err)
		}
	})
}

// idleBridge is a bridge that never launches (its launches keep failing):
// never running, no launch on record.
type idleBridge struct{}

func (idleBridge) Run(ctx context.Context) error { <-ctx.Done(); return ctx.Err() }
func (idleBridge) Running() bool                 { return false }
func (idleBridge) Launches() uint64              { return 0 }
func (idleBridge) LastLaunch() time.Time         { return time.Time{} }

// An unreadable iCloud account, or the Mac's iCloud user not read, past the
// bridge's startup grace is unusable: a Mac with a connected relay issues a
// relay code — whether its bridge runs (the rig's, launched long ago) or
// never launched at all.
func TestPairWithAnUnreadableAccountPastTheBridgeGraceFallsBackToARelayCode(t *testing.T) {
	for _, tc := range []struct {
		name string
		op   string
		edit []func(*Options)
	}{
		{"running", "account_status", nil},
		{"never launched", "account_status", []func(*Options){func(o *Options) {
			o.Desktop.supervise = func(cloudkit.Config) bridgeRunner { return idleBridge{} }
		}}},
		{"owner unread", "owner_user", nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			bubble(t, func(t *testing.T) {
				r, ck, c := startPairDesk(t, transport.KindCloudKit, tc.edit...)
				time.Sleep(bridgeStartGrace)
				ck.failNext(tc.op, 1000)
				pairRelayCode(t, r, ck, c)
			})
		})
	}
}

// An iCloud account the bridge reports only for now unavailable refuses the
// pair as retryable, with nothing issued, on a Mac without a relay.
func TestPairOnACloudKitDesktopWithICloudBriefyUnavailableIsRetryable(t *testing.T) {
	bubble(t, func(t *testing.T) {
		r, ck, c := startPairDesk(t, transport.KindCloudKit, noRelay)
		ck.acct.Store(transport.AccountTemporarilyUnavailable)
		if a := pairRefusal(t, c); a != ErrClassICloudUnreachable {
			t.Fatalf("answer %s, want %s", a, ErrClassICloudUnreachable)
		}
		if n := codesStored(t, r.dir); n != 0 {
			t.Fatalf("%d codes stored", n)
		}
	})
}

// iCloud that is only not read yet — the account unreadable inside the
// bridge's startup grace (just after the hub started), or the Mac's user not
// read — keeps the retryable refusal on a Mac with a relay: "try again in a
// moment", not a move to Relay.
func TestPairOnACloudKitDesktopWithICloudNotReadYetIsRetryable(t *testing.T) {
	for _, op := range []string{"account_status", "owner_user"} {
		t.Run(op, func(t *testing.T) {
			bubble(t, func(t *testing.T) {
				r, ck, c := startPairDesk(t, transport.KindCloudKit)
				ck.failNext(op, 1000)
				if a := pairRefusal(t, c); a != ErrClassICloudUnreachable {
					t.Fatalf("answer %s, want %s", a, ErrClassICloudUnreachable)
				}
				if n := codesStored(t, r.dir); n != 0 {
					t.Fatalf("%d codes stored", n)
				}
			})
		})
	}
}

// downRelay is a relay that never connects: the hub's relay stays down.
type downRelay struct{ transport.Transport }

func (downRelay) Connect(context.Context, []string) error { return transport.ErrUnavailable }

// liveRelay connects, then reports its live connection state from up (the
// hosted relay's connectedReporter).
type liveRelay struct {
	transport.Transport
	up *atomic.Bool
}

func (liveRelay) Connect(context.Context, []string) error { return nil }
func (l liveRelay) Connected() bool                       { return l.up.Load() }

// A Mac whose relay is not connected keeps the iCloud refusal — never
// connected, or connected once and dropped since: a relay code would send the
// phone to a pairing slot nobody serves, and the Mac must still say iCloud
// is the problem.
func TestPairOnACloudKitDesktopWithoutICloudAndTheRelayDownIsRefused(t *testing.T) {
	var up atomic.Bool
	for _, tc := range []struct {
		name string
		wrap func(transport.Transport) transport.Transport
	}{
		{"never connected", func(rel transport.Transport) transport.Transport { return downRelay{rel} }},
		{"dropped after a connect", func(rel transport.Transport) transport.Transport {
			up.Store(true)
			return liveRelay{rel, &up}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			bubble(t, func(t *testing.T) {
				r, ck, c := startPairDesk(t, transport.KindCloudKit, func(o *Options) {
					next := o.newTransport
					o.newTransport = func(ctx context.Context, id identity.Identity, st *state.Store, zones []string) (transport.Transport, error) {
						rel, err := next(ctx, id, st, zones)
						return tc.wrap(rel), err
					}
				})
				up.Store(false)
				ck.acct.Store(transport.AccountNoAccount)
				if a := pairRefusal(t, c); a != ErrClassNoICloud {
					t.Fatalf("answer %s, want %s", a, ErrClassNoICloud)
				}
				if n := codesStored(t, r.dir); n != 0 {
					t.Fatalf("%d codes stored", n)
				}
			})
		})
	}
}

// clockBridge is a bridge whose state the test sets.
type clockBridge struct {
	running bool
	last    time.Time
}

func (b clockBridge) Run(ctx context.Context) error { <-ctx.Done(); return ctx.Err() }
func (b clockBridge) Running() bool                 { return b.running }
func (clockBridge) Launches() uint64                { return 0 }
func (b clockBridge) LastLaunch() time.Time         { return b.last }

// Only an iCloud refusal that is not transient moves a pair to a relay code,
// and only with a relay that is connected now: icloud_changed, failed and
// the not-read-yet causes keep their refusal; an unreadable account counts
// as unusable once the bridge is past its startup grace.
func TestRelayCodeFallbackOnlyForUnusableICloud(t *testing.T) {
	start := time.Unix(1_800_000_000, 0)
	past := start.Add(time.Hour)
	relay := memfake.New(transport.KindRelay, nil)
	var connected, dropped atomic.Bool
	connected.Store(true)
	acct := func(a transport.Account) error { return &link.AccountError{Account: a} }
	unreadable := &link.AccountError{Account: link.AccountUnreadable, Err: transport.ErrUnavailable}
	for _, tc := range []struct {
		name    string
		rel     transport.Transport
		relDown bool
		bridge  bridgeRunner
		now     time.Time
		err     error
		want    bool
	}{
		{"no account", relay, false, nil, start, acct(transport.AccountNoAccount), true},
		{"restricted", relay, false, nil, start, acct(transport.AccountRestricted), true},
		{"no entitlement", relay, false, nil, start, acct(transport.AccountNoEntitlement), true},
		{"temporarily unavailable", relay, false, nil, start, acct(transport.AccountTemporarilyUnavailable), true},
		{"unreadable just after the start", relay, false, clockBridge{running: true}, start.Add(bridgeStartGrace - time.Second), unreadable, false},
		{"unreadable, a process launched just now", relay, false,
			clockBridge{running: true, last: past.Add(-time.Second)}, past, unreadable, false},
		{"unreadable, the process past its grace", relay, false,
			clockBridge{running: true, last: past.Add(-bridgeStartGrace)}, past, unreadable, true},
		{"unreadable, waiting to restart", relay, false,
			clockBridge{last: past.Add(-time.Second)}, past, unreadable, true},
		{"unreadable, never launched", relay, false, clockBridge{}, past, unreadable, true},
		{"unreadable, the clock stepped back behind the launch", relay, false,
			clockBridge{running: true, last: past.Add(10 * time.Minute)}, past, unreadable, true},
		{"unreadable, the clock stepped back behind the start", relay, false, nil,
			start.Add(-time.Hour), unreadable, true},
		{"unreadable, no bridge", relay, false, nil, past, unreadable, true},
		{"owner unknown just after the start", relay, false, nil, start.Add(bridgeStartGrace - time.Second),
			link.ErrOwnerUnknown, false},
		{"owner unknown past the grace", relay, false, nil, past, link.ErrOwnerUnknown, true},
		{"account changed", relay, false, nil, past, fmt.Errorf("w: %w", link.ErrAccountChanged), false},
		{"failed", relay, false, nil, past, errors.New("link: storing the code: disk full"), false},
		{"no relay", nil, false, nil, past, acct(transport.AccountNoAccount), false},
		{"relay never connected", relay, true, nil, past, acct(transport.AccountNoAccount), false},
		{"relay connected now", liveRelay{relay, &connected}, false, nil, past, acct(transport.AccountNoAccount), true},
		{"relay dropped after a connect", liveRelay{relay, &dropped}, false, nil, past, acct(transport.AccountNoAccount), false},
	} {
		now := tc.now
		h := &hubRuntime{rel: tc.rel, bridge: tc.bridge, startedAt: start,
			sup: &supervisor{o: Options{Clock: func() time.Time { return now }}}}
		h.relDown.Store(tc.relDown)
		if got := h.relayCodeFallback(tc.err); got != tc.want {
			t.Errorf("%s: %v, want %v", tc.name, got, tc.want)
		}
	}
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

// #1127 review: a pairing stream abandoned with its CloudKit code still on
// screen (the sheet closed, the CLI stopped) closes that code's link
// (CloseSheetClosed); an older stream going away never closes a newer
// stream's code.
func TestAnAbandonedPairStreamClosesItsCloudKitCode(t *testing.T) {
	bubble(t, func(t *testing.T) {
		h := startCloudKitHub(t, nil, nil)
		older, newer := h.rig.dial(), h.rig.dial()
		pairCode(t, older)
		pairCode(t, newer) // the newer code retires the older one
		closes := h.ck.count("set_public_link:close")
		if err := older.Close(); err != nil {
			t.Fatal(err)
		}
		time.Sleep(time.Second)
		synctest.Wait()
		if n := h.ck.count("set_public_link:close"); n != closes {
			t.Fatalf("the older stream's end closed the newer code's link (%d closes)", n-closes)
		}
		if err := newer.Close(); err != nil {
			t.Fatal(err)
		}
		time.Sleep(time.Second) // far within the code's 600 s: no expiry close
		synctest.Wait()
		if n := h.ck.count("set_public_link:close"); n <= closes {
			t.Fatal("the abandoned stream's code kept its link open")
		}
	})
}
