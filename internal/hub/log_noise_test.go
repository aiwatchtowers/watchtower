package hub

import (
	"bytes"
	"context"
	"fmt"
	"log"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/cloudkit"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/transport/relay"
)

// #2192: a desktop host's log repeated "reading the iCloud account failed"
// at every hub start and "data zone not subscribed" whenever the relay
// refused an unvouched hub. Both are pinned here: the account read logs a
// run of failures once (and its end once), never the bridge still being
// started; the relay refusing a zone by design while no phone holds the hub
// in a slot is not logged, every other failure is, once per streak.

// captureLog collects the standard logger's lines until the test ends.
func captureLog(t *testing.T) func() string {
	t.Helper()
	var mu sync.Mutex
	var buf bytes.Buffer
	prev, flags := log.Writer(), log.Flags()
	log.SetOutput(writerFunc(func(p []byte) (int, error) {
		mu.Lock()
		defer mu.Unlock()
		return buf.Write(p)
	}))
	log.SetFlags(0)
	t.Cleanup(func() { log.SetOutput(prev); log.SetFlags(flags) })
	return func() string {
		mu.Lock()
		defer mu.Unlock()
		return buf.String()
	}
}

type writerFunc func([]byte) (int, error)

func (f writerFunc) Write(p []byte) (int, error) { return f(p) }

// failingAcct is ckShares whose account read fails with err while set.
type failingAcct struct {
	*ckShares
	acct transport.Account
	err  error
}

func (f *failingAcct) AccountStatus(context.Context) (transport.Account, error) {
	if f.err != nil {
		return "", f.err
	}
	return f.acct, nil
}

// stateBridge is the bridge supervisor's state as the status reads it.
type stateBridge struct{ running bool }

func (*stateBridge) Run(context.Context) error { return nil }
func (b *stateBridge) Running() bool           { return b.running }

var errBridgeDown = fmt.Errorf("cloudkit: bridge not running: %w", transport.ErrUnavailable)

// newAcctRuntime is a desktop host whose bridge is being (re)started and
// whose account reads find no bridge.
func newAcctRuntime() (*hubRuntime, *failingAcct, *stateBridge) {
	f := &failingAcct{ckShares: newCKShares(), acct: transport.AccountAvailable, err: errBridgeDown}
	b := &stateBridge{}
	return &hubRuntime{sup: &supervisor{o: Options{Desktop: &Desktop{}}}, tr: f, ck: f, bridge: b}, f, b
}

func readAccount(h *hubRuntime, n int) {
	for range n {
		h.refreshCloudKitAccount(context.Background())
	}
}

const (
	acctUnavailable = "hub: reading the iCloud account failed (unavailable): retried next cycle\n"
	acctTimeout     = "hub: reading the iCloud account failed (timeout): retried next cycle\n"
	acctBack        = "hub: the iCloud account read again (available)\n"
)

// A (re)start reads the account before the bridge serves its socket — the
// first pass, the housekeeping and the link upkeep's pass, all kicked at
// once — while the supervisor is still starting it: those reads log
// nothing, nor does the first answer.
func TestAccountReadsWhileTheBridgeStartsAreNotLogged(t *testing.T) {
	logs := captureLog(t)
	for range 2 { // a relaunch: a fresh runtime starts unread again
		h, f, b := newAcctRuntime()
		readAccount(h, 4)
		b.running, f.err = true, nil
		readAccount(h, 1)
		if got := h.cloudKitStatus().Account; got != string(transport.AccountAvailable) {
			t.Fatalf("account after the bridge came up: %q", got)
		}
	}
	if out := logs(); out != "" {
		t.Fatalf("a starting bridge was logged:\n%s", out)
	}
}

// A bridge the supervisor runs that never serves its socket is logged, once,
// whether or not its start was silent before.
func TestARunningBridgeWithoutASocketIsLogged(t *testing.T) {
	logs := captureLog(t)
	h, f, b := newAcctRuntime()
	readAccount(h, 2) // starting: silent, its class recorded
	b.running = true
	readAccount(h, 3)
	f.err = nil
	readAccount(h, 1)
	if out, want := logs(), acctUnavailable+acctBack; out != want {
		t.Fatalf("log:\n%s\nwant:\n%s", out, want)
	}
}

// Before the first answer, a failure that is not a missing bridge (a
// timeout, a socket refused) is logged even while the bridge is starting.
func TestOtherFailuresBeforeTheFirstAnswerAreLogged(t *testing.T) {
	logs := captureLog(t)
	h, f, _ := newAcctRuntime()
	f.err = fmt.Errorf("cloudkit: account status: %w", context.DeadlineExceeded)
	readAccount(h, 2)
	f.err = fmt.Errorf("%w: open to other users", cloudkit.ErrBridgeRefused)
	readAccount(h, 2)
	want := acctTimeout + "hub: reading the iCloud account failed (bridge_refused): retried next cycle\n"
	if out := logs(); out != want {
		t.Fatalf("log:\n%s\nwant:\n%s", out, want)
	}
}

// Once the account was read, a bridge restarting (or any failure) is a run
// of failed reads: one line at its start, one more only when the class
// changes, and one when an answer ends it; the last answer stays meanwhile.
func TestFailedAccountReadsAreLoggedOncePerRun(t *testing.T) {
	logs := captureLog(t)
	h, f, b := newAcctRuntime()
	b.running, f.err = true, nil
	readAccount(h, 1)

	b.running, f.err = false, errBridgeDown // the bridge restarting
	readAccount(h, 5)
	f.err = fmt.Errorf("cloudkit: account status: %w", context.DeadlineExceeded)
	readAccount(h, 2)
	if got := h.cloudKitStatus().Account; got != string(transport.AccountAvailable) {
		t.Fatalf("a failed read dropped the last answer: %q", got)
	}
	f.err = errBridgeDown // back to the first class: a change again
	readAccount(h, 2)
	f.err = nil
	readAccount(h, 2)
	f.err = errBridgeDown // a later run logs again
	readAccount(h, 1)

	want := acctUnavailable + acctTimeout + acctUnavailable + acctBack + acctUnavailable
	if out := logs(); out != want {
		t.Fatalf("log:\n%s\nwant:\n%s", out, want)
	}
}

// unvouchedRelay is slotRelay with no phone holding the hub in a slot.
type unvouchedRelay struct{ *slotRelay }

func (unvouchedRelay) Vouched() bool { return false }

func newUnvouchedRig(t *testing.T) (*zoneAdmissionRig, unvouchedRelay) {
	r := newZoneAdmissionRig(t)
	r.h.wasVouched = false
	u := unvouchedRelay{r.rel}
	r.h.tr = u
	return r, u
}

// The relay refusing the zones of an unvouched hub by design (FORBIDDEN on
// the zone, HUB_NOT_VOUCHED) — a desktop host on CloudKit whose phones never
// used the relay — is not logged, and the zones keep their backoff; once
// vouched, a refusal is news and is logged once.
func TestRefusalOfAnUnvouchedHubIsNotLogged(t *testing.T) {
	for _, refusal := range []error{transport.ErrZoneForbidden, transport.ErrNotVouched} {
		t.Run(errClass(refusal), func(t *testing.T) {
			logs := captureLog(t)
			r, u := newUnvouchedRig(t)
			r.rel.refuseWith(refusal)
			r.h.watchZones(context.Background(), u)
			r.h.watchZones(context.Background(), u)
			r.advance(time.Minute)
			r.h.watchZones(context.Background(), u)
			if n := r.rel.triesOf(r.h.data); n != 2 {
				t.Fatalf("data zone tried %d times, want 2 (backoff kept)", n)
			}
			if out := logs(); out != "" {
				t.Fatalf("an unvouched refusal was logged:\n%s", out)
			}

			r.h.tr = r.rel // vouched now, and still refused
			r.upkeep()
			r.advance(time.Minute)
			r.upkeep()
			line := fmt.Sprintf("hub: the data zone not subscribed (%s)", errClass(refusal))
			if got := strings.Count(logs(), line); got != 1 {
				t.Fatalf("a vouched refusal logged %d times, want 1:\n%s", got, logs())
			}
		})
	}
}

// While unvouched, a refusal that is not by design — the relay rejecting
// the hub's key (UNAUTHENTICATED: plain ErrForbidden), its attestation, or
// a rate limit — is logged, once per streak.
func TestUnvouchedRefusalsOfOtherKindsAreLogged(t *testing.T) {
	for _, refusal := range []error{transport.ErrForbidden, relay.ErrAttestationFailed, transport.ErrRateLimited} {
		t.Run(refusal.Error(), func(t *testing.T) {
			logs := captureLog(t)
			r, u := newUnvouchedRig(t)
			r.rel.refuseWith(refusal)
			r.h.watchZones(context.Background(), u)
			r.advance(time.Minute)
			r.h.watchZones(context.Background(), u)
			line := fmt.Sprintf("hub: the data zone not subscribed (%s)", errClass(refusal))
			if got := strings.Count(logs(), line); got != 1 {
				t.Fatalf("logged %d times, want 1:\n%s", got, logs())
			}
		})
	}
}

// A silent refusal by design, then another failure of the same zone while
// still unvouched (a timeout): that failure is logged, once.
func TestAFailureAfterASilentRefusalIsLoggedOnce(t *testing.T) {
	logs := captureLog(t)
	r, u := newUnvouchedRig(t)
	r.h.watchZones(context.Background(), u) // ErrZoneForbidden: silent
	r.rel.refuseWith(context.DeadlineExceeded)
	for range 3 {
		r.advance(10 * time.Minute)
		r.h.watchZones(context.Background(), u)
	}
	if got := strings.Count(logs(), "hub: the data zone not subscribed (timeout)"); got != 1 {
		t.Fatalf("logged %d times, want 1:\n%s", got, logs())
	}
	if strings.Contains(logs(), "(forbidden)") {
		t.Fatalf("the refusal by design was logged:\n%s", logs())
	}
}

// noVouchWatcher is a zone watcher without the vouch notion that refuses
// every zone.
type noVouchWatcher struct{ *memfake.Fake }

func (noVouchWatcher) WatchZone(context.Context, string) error { return transport.ErrZoneForbidden }

// A transport without the vouch notion counts as vouched: its refusals are
// news and logged.
func TestARefusalWithoutTheVouchNotionIsLogged(t *testing.T) {
	logs := captureLog(t)
	r := newZoneAdmissionRig(t)
	w := noVouchWatcher{r.rel.Fake}
	r.h.tr = w
	r.h.watchZones(context.Background(), w)
	if got := strings.Count(logs(), "hub: the data zone not subscribed (forbidden)"); got != 1 {
		t.Fatalf("logged %d times, want 1:\n%s", got, logs())
	}
}
