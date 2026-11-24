package hub

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"slices"
	"strings"
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

// startSASDesk is startPairDesk with an iCloud-routed phone linked before
// the start (icloudPhone) and the runtime handed back.
func startSASDesk(t *testing.T, active transport.Kind, icloudPhone bool) (*deskRig, *hubRuntime, *ControlClient) {
	t.Helper()
	policytest.Set(t, nil)
	r := newDeskRig(t, shortDir(t))
	ck := newAcctCK(transport.AccountAvailable)
	r.ck = ck.Fake
	fctx, fcancel := context.WithCancel(context.Background())
	t.Cleanup(fcancel)
	go ck.forward(fctx)
	setMeta(t, r.dir, state.MetaEnabled, "1", switcher.MetaTransport, string(active))
	if icloudPhone {
		linkSharedPhone(t, r.dir, sharedPhoneID, "_colleague-a")
	}
	var h *hubRuntime
	o := r.options()
	o.Desktop.newCloudKit = func(cloudkit.Config) transport.Transport { return ck }
	o.started = func(rt *hubRuntime) { h = rt }
	r.start(o)
	r.waitStatus("running on "+string(active), func(s Status) bool {
		return s.State == StateRunning && s.Transport == string(active) &&
			s.CloudKit.Account == string(transport.AccountAvailable)
	})
	c := r.dial()
	t.Cleanup(func() { _ = c.Close() })
	return r, h, c
}

// slotSAS issues a code, sends a phone's hello through a Relay pairing
// slot and reads the sas line the pairing stream gets. Anything else on
// the stream fails the test at once; a sas that never comes fails it a
// minute later on the bubble's clock.
func slotSAS(t *testing.T, r *deskRig, c *ControlClient) (ControlAnswer, *hubtest.Phone) {
	t.Helper()
	phone, err := hubtest.FromLink(pairCode(t, c), r.fake, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := phone.Hello(transport.PairZone("slot1")); err != nil {
		t.Fatal(err)
	}
	r.fake.SendEvent(transport.Event{Control: &transport.Control{Kind: transport.PairingOpened, Detail: "slot1"}})
	_ = c.SetReadDeadline(time.Now().Add(time.Minute))
	defer func() { _ = c.SetReadDeadline(time.Time{}) }()
	a, err := c.Next()
	if err != nil || a.Error != "" || a.Event != link.EventSAS {
		t.Fatalf("waiting for the sas: %+v, %v", a, err)
	}
	return a, phone
}

// confirmAnswer sends the owner's confirm and reads its answer, skipping
// pairing events.
func confirmAnswer(t *testing.T, c *ControlClient, req ControlRequest) ControlAnswer {
	t.Helper()
	if err := c.Send(req); err != nil {
		t.Fatal(err)
	}
	_ = c.SetReadDeadline(time.Now().Add(time.Minute))
	defer func() { _ = c.SetReadDeadline(time.Time{}) }()
	for {
		a, err := c.Next()
		if err != nil {
			t.Fatalf("waiting for the confirm's answer: %v", err)
		}
		if a.Event == "" && a.Op == OpConfirm {
			return a
		}
	}
}

// #2191 review: a confirm names the code the owner was shown; a yes for a
// code the phone's request no longer has is refused code_changed and keeps
// the request; a confirm without a code takes the stream's latest, as
// before.
func TestAConfirmForAStaleCodeIsRefused(t *testing.T) {
	bubble(t, func(t *testing.T) {
		r, _, c := startSASDesk(t, transport.KindRelay, false)
		sas, phone := slotSAS(t, r, c)
		stale := "0000"
		if sas.Code == stale {
			stale = "1111"
		}
		a := confirmAnswer(t, c, ControlRequest{Op: OpConfirm, Device: phone.ID().String(), Confirm: true, Code: stale})
		if a.Error != ErrClassCodeChanged {
			t.Fatalf("a yes for a stale code: %+v", a)
		}
		// The code still holds but the line answered said another
		// moves_to_relay (a replacement that kept its code).
		flipped := !sas.MovesToRelay
		a = confirmAnswer(t, c, ControlRequest{Op: OpConfirm, Device: phone.ID().String(), Confirm: true, Code: sas.Code, MovesToRelay: &flipped})
		if a.Error != ErrClassCodeChanged {
			t.Fatalf("a yes for another moves_to_relay: %+v", a)
		}
		// The code holds but the request named is not the one waiting.
		a = confirmAnswer(t, c, ControlRequest{Op: OpConfirm, Device: phone.ID().String(), Confirm: true, Code: sas.Code,
			Request: "0000000000000000"})
		if sas.Request == "" || a.Error != ErrClassCodeChanged {
			t.Fatalf("a yes for another request (sas request %q): %+v", sas.Request, a)
		}
		shown := sas.MovesToRelay
		a = confirmAnswer(t, c, ControlRequest{Op: OpConfirm, Device: phone.ID().String(), Confirm: true, Code: sas.Code,
			MovesToRelay: &shown, Request: sas.Request})
		if !a.OK {
			t.Fatalf("a yes for the code shown: %+v", a)
		}
	})
}

// Without a code the confirm is today's: the stream's latest code.
func TestAConfirmWithoutACodeTakesTheStreamsCode(t *testing.T) {
	bubble(t, func(t *testing.T) {
		r, _, c := startSASDesk(t, transport.KindRelay, false)
		_, phone := slotSAS(t, r, c)
		if a := confirmAnswer(t, c, ControlRequest{Op: OpConfirm, Device: phone.ID().String(), Confirm: true}); !a.OK {
			t.Fatalf("a yes without a code: %+v", a)
		}
	})
}

// #2191 (Q6): the sas line says the Link moves the Mac to Relay exactly when
// the phone paired through a Relay pairing slot, the hub runs on iCloud and
// another linked phone has an iCloud route.
func TestTheSASLineSaysWhenTheLinkMovesTheMacToRelay(t *testing.T) {
	t.Run("a slot hello on iCloud with an iCloud phone", func(t *testing.T) {
		bubble(t, func(t *testing.T) {
			r, h, c := startSASDesk(t, transport.KindCloudKit, true)
			sas, phone := slotSAS(t, r, c)
			if !sas.MovesToRelay || !strings.EqualFold(sas.DeviceID, phone.ID().String()) {
				t.Fatalf("sas %+v: want moves_to_relay", sas)
			}
			// The OverRelay guard alone: the same event without it moves
			// nothing (that a CloudKit hello's sas never sets it is
			// TestASASOverAPairingSlotSaysOverRelay's, in internal/hub/link).
			if h.movesToRelay(link.PairEvent{Kind: link.EventSAS, DeviceID: sas.DeviceID}) {
				t.Fatal("a sas without OverRelay moves the Mac to Relay")
			}
			// The iCloud-routed phone relinking is not "another" phone.
			if h.movesToRelay(link.PairEvent{Kind: link.EventSAS, DeviceID: sharedPhoneID, OverRelay: true}) {
				t.Fatal("the iCloud phone itself counts as another iCloud phone")
			}
			// An unreadable route list warns rather than stays silent.
			broken, err := state.Open(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			_ = broken.Close()
			if !(&hubRuntime{sw: h.sw, st: broken}).movesToRelay(link.PairEvent{Kind: link.EventSAS, DeviceID: sas.DeviceID, OverRelay: true}) {
				t.Fatal("a failed route read answers false")
			}
		})
	})
	t.Run("no other iCloud phone", func(t *testing.T) {
		bubble(t, func(t *testing.T) {
			r, _, c := startSASDesk(t, transport.KindCloudKit, false)
			if sas, _ := slotSAS(t, r, c); sas.MovesToRelay {
				t.Fatalf("sas %+v: nobody is cut off", sas)
			}
		})
	})
	t.Run("the hub on Relay", func(t *testing.T) {
		bubble(t, func(t *testing.T) {
			r, _, c := startSASDesk(t, transport.KindRelay, true)
			if sas, _ := slotSAS(t, r, c); sas.MovesToRelay {
				t.Fatalf("sas %+v: the hub is on Relay already", sas)
			}
		})
	})
}

// A host without a switcher (one transport) never moves.
func TestMovesToRelayWithoutASwitcherIsFalse(t *testing.T) {
	h := &hubRuntime{}
	if h.movesToRelay(link.PairEvent{Kind: link.EventSAS, DeviceID: sharedPhoneID, OverRelay: true}) {
		t.Fatal("a host without a switcher moves to Relay")
	}
}
