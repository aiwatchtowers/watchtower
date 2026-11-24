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
)

// #2192: a day of a desktop host's log held ~40 "reading the iCloud account
// failed" and 11 "data zone not subscribed" lines. Both are pinned here:
// the account read logs a run of failures once (and its end once), never
// the bridge still starting; the relay refusing a zone while no phone holds
// the hub in a slot is by design and not logged.

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

var errBridgeDown = fmt.Errorf("cloudkit: bridge not running: %w", transport.ErrUnavailable)

func newAcctRuntime() (*hubRuntime, *failingAcct) {
	f := &failingAcct{ckShares: newCKShares(), acct: transport.AccountAvailable, err: errBridgeDown}
	return &hubRuntime{sup: &supervisor{o: Options{Desktop: &Desktop{}}}, tr: f, ck: f}, f
}

// A (re)start reads the account before the bridge serves its socket — the
// first pass, the housekeeping and the link upkeep's pass, all kicked at
// once: those reads say nothing and log nothing, nor does the first answer.
func TestAccountReadsBeforeTheBridgeIsUpAreNotLogged(t *testing.T) {
	logs := captureLog(t)
	for range 2 { // a relaunch: a fresh runtime starts unread again
		h, f := newAcctRuntime()
		for range 4 {
			h.refreshCloudKitAccount(context.Background())
		}
		f.err = nil
		h.refreshCloudKitAccount(context.Background())
		if got := h.cloudKitStatus().Account; got != string(transport.AccountAvailable) {
			t.Fatalf("account after the bridge came up: %q", got)
		}
	}
	if out := logs(); strings.Contains(out, "iCloud account") {
		t.Fatalf("a starting bridge was logged:\n%s", out)
	}
}

// Once the account was read, a bridge restarting (or any failure) is a run
// of failed reads: one line at its start, one more only when the class
// changes, and one when an answer ends it; the last answer stays meanwhile.
func TestFailedAccountReadsAreLoggedOncePerRun(t *testing.T) {
	logs := captureLog(t)
	h, f := newAcctRuntime()
	f.err = nil
	h.refreshCloudKitAccount(context.Background())

	f.err = errBridgeDown // the bridge restarting
	for range 5 {
		h.refreshCloudKitAccount(context.Background())
	}
	f.err = fmt.Errorf("cloudkit: account status: %w", context.DeadlineExceeded)
	h.refreshCloudKitAccount(context.Background())
	h.refreshCloudKitAccount(context.Background())
	if got := h.cloudKitStatus().Account; got != string(transport.AccountAvailable) {
		t.Fatalf("a failed read dropped the last answer: %q", got)
	}
	f.err = nil
	h.refreshCloudKitAccount(context.Background())
	h.refreshCloudKitAccount(context.Background())
	f.err = errBridgeDown // a later run logs again
	h.refreshCloudKitAccount(context.Background())

	want := "hub: reading the iCloud account failed (unavailable): retried next cycle\n" +
		"hub: reading the iCloud account failed (timeout): retried next cycle\n" +
		"hub: the iCloud account read again (available)\n" +
		"hub: reading the iCloud account failed (unavailable): retried next cycle\n"
	if out := logs(); out != want {
		t.Fatalf("log:\n%s\nwant:\n%s", out, want)
	}
}

// unvouchedRelay is slotRelay with no phone holding the hub in a slot.
type unvouchedRelay struct{ *slotRelay }

func (unvouchedRelay) Vouched() bool { return false }

// The relay refusing the zones of an unvouched hub (a desktop host on
// CloudKit whose phones never used the relay) is not logged, and the zones
// keep their backoff; once vouched, a refusal is news and is logged once.
func TestRefusalOfAnUnvouchedHubIsNotLogged(t *testing.T) {
	logs := captureLog(t)
	r := newZoneAdmissionRig(t)
	r.h.wasVouched = false
	u := unvouchedRelay{r.rel}
	r.h.tr = u
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
	if got := strings.Count(logs(), "hub: the data zone not subscribed (forbidden)"); got != 1 {
		t.Fatalf("a vouched refusal logged %d times, want 1:\n%s", got, logs())
	}
}
