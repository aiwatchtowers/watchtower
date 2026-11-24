package hub

import (
	"bytes"
	"context"
	"fmt"
	"log"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"watchtower/internal/hub/state"
	"watchtower/internal/hub/switcher"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/cloudkit"
	"watchtower/internal/hub/transport/memfake"
	"watchtower/internal/hub/transport/relay"
	"watchtower/internal/policy/policytest"
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

// stateBridge is a bridge supervisor with no process, as the hub sees the
// real one: launch makes a new generation running at once, before any
// socket is served (cloudkit.Supervisor.runOnce); Run launches once and
// runs until its ctx ends.
type stateBridge struct {
	running  atomic.Bool
	launches atomic.Uint64
}

func (b *stateBridge) launch() { b.launches.Add(1); b.running.Store(true) }

func (b *stateBridge) Run(ctx context.Context) error {
	b.launch()
	<-ctx.Done()
	b.running.Store(false)
	return ctx.Err()
}
func (b *stateBridge) Running() bool    { return b.running.Load() }
func (b *stateBridge) Launches() uint64 { return b.launches.Load() }

var errBridgeDown = fmt.Errorf("cloudkit: bridge not running: %w", transport.ErrUnavailable)

// newAcctRuntime is a desktop host whose bridge was not launched yet and
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

// houseRead is housekeeping's account step: it notes the bridge's launch,
// then reads.
func houseRead(h *hubRuntime) {
	h.noteBridgeLaunch()
	h.refreshCloudKitAccount(context.Background())
}

const (
	acctUnavailable = "hub: reading the iCloud account failed (unavailable): retried next cycle\n"
	acctTimeout     = "hub: reading the iCloud account failed (timeout): retried next cycle\n"
	acctBack        = "hub: the iCloud account read again (available)\n"
)

// A start reads the account before the bridge serves its socket — the first
// pass, the housekeeping and the link upkeep's pass, all kicked at once —
// with the supervisor reporting the bridge running already: silent, and so
// is a socket still missing at a housekeeping right after a relaunch. The
// first housekeeping after a launch the one before it saw logs a socket
// still missing, once.
func TestAccountReadsLogAMissingSocketOnlyAfterAHousekeeping(t *testing.T) {
	logs := captureLog(t)
	h, _, b := newAcctRuntime()
	readAccount(h, 1) // the first pass, before the launch
	b.launch()
	houseRead(h)      // the kicked housekeeping: sees launch 1
	readAccount(h, 3) // the link upkeep's pass, the pass ticks
	b.launch()        // the bridge exited and was launched again
	houseRead(h)      // sees launch 2 first: still silent
	readAccount(h, 2)
	if out := logs(); out != "" {
		t.Fatalf("a bridge being launched was logged:\n%s", out)
	}
	houseRead(h) // the next housekeeping, launch 2 still without a socket
	houseRead(h)
	readAccount(h, 2)
	if out := logs(); out != acctUnavailable {
		t.Fatalf("log:\n%s\nwant:\n%s", out, acctUnavailable)
	}
}

// A healthy start: the socket is served before the next housekeeping, and
// nothing is logged, nor is the first answer; a relaunched hub (a fresh
// runtime) the same.
func TestAccountReadsWhileTheBridgeStartsAreNotLogged(t *testing.T) {
	logs := captureLog(t)
	for range 2 {
		h, f, b := newAcctRuntime()
		readAccount(h, 1)
		b.launch()
		houseRead(h)
		readAccount(h, 2)
		f.err = nil
		readAccount(h, 1)
		houseRead(h)
		if got := h.cloudKitStatus().Account; got != string(transport.AccountAvailable) {
			t.Fatalf("account after the bridge came up: %q", got)
		}
	}
	if out := logs(); out != "" {
		t.Fatalf("a starting bridge was logged:\n%s", out)
	}
}

// The real start order on a running desktop host, whose bridge supervisor
// reports the bridge running before its socket is served and whose socket
// never comes: the start logs nothing, and the daemon cycles' housekeepings
// log it once.
func TestAHubStartWithABridgeThatNeverServesLogsOnceAtAHousekeeping(t *testing.T) {
	bubble(t, func(t *testing.T) {
		policytest.Set(t, nil)
		logs := captureLog(t)
		r := newDeskRig(t, shortDir(t))
		ck := newAcctCK(transport.AccountAvailable)
		ck.failNext("account_status", 1<<30)
		r.ck = ck.Fake
		fctx, fcancel := context.WithCancel(context.Background())
		t.Cleanup(fcancel)
		go ck.forward(fctx)
		setMeta(t, r.dir, state.MetaEnabled, "1", switcher.MetaTransport, string(transport.KindCloudKit))
		o := r.options()
		o.Desktop.newCloudKit = func(cloudkit.Config) transport.Transport { return ck }
		o.Desktop.supervise = func(cloudkit.Config) bridgeRunner { return &stateBridge{} }
		r.start(o)
		r.waitStatus("running", func(s Status) bool { return s.State == StateRunning && s.Bridge == BridgeRunning })
		time.Sleep(10 * time.Second) // the start's passes
		synctest.Wait()
		before := ck.count("account_status")
		ck.inject(transport.Event{PullNow: true}) // a pass now, with the bridge running
		time.Sleep(time.Second)
		synctest.Wait()
		if ck.count("account_status") == before {
			t.Fatal("no account read while the bridge ran without a socket")
		}
		if strings.Contains(logs(), "iCloud account") {
			t.Fatalf("the start was logged:\n%s", logs())
		}
		r.cycles(4)
		if got := strings.Count(logs(), acctUnavailable); got != 1 {
			t.Fatalf("the missing socket logged %d times, want 1:\n%s", got, logs())
		}
	})
}

// Before the first answer, a failure that is not a missing bridge (a
// timeout, a socket refused) is logged even while the bridge is starting.
func TestOtherFailuresBeforeTheFirstAnswerAreLogged(t *testing.T) {
	logs := captureLog(t)
	h, f, b := newAcctRuntime()
	f.err = fmt.Errorf("cloudkit: account status: %w", context.DeadlineExceeded)
	readAccount(h, 2)
	f.err = errBridgeDown // the bridge restarting: silent
	b.launch()
	readAccount(h, 2)
	f.err = fmt.Errorf("cloudkit: account status: %w", context.DeadlineExceeded)
	readAccount(h, 1) // the class the log last named: no second line
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
	b.launch()
	f.err = nil
	readAccount(h, 1)

	b.launch()
	f.err = errBridgeDown // the bridge restarting
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
