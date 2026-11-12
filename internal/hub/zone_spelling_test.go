package hub

import (
	"context"
	"slices"
	"strings"
	"sync"
	"testing"
	"testing/synctest"
	"time"

	"watchtower/internal/hub/identity"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/cloudkit"
	"watchtower/internal/logcanary"
	"watchtower/internal/policy/policytest"
)

// adoptedHubID is a Swift hub's UUID().uuidString.lowercased(), kept by an
// adopted hub.
const adoptedHubID = "0a1b2c3d-4e5f-4a6b-8c7d-8e9fa0b1c2d3"

// retireCK is an acctCK that answers RetireZones (cloudkit.Client's),
// recording the hub ids it was asked for; failNext("retire_zones", n)
// fails the next n.
type retireCK struct {
	*acctCK
	mu      sync.Mutex
	retired []string
}

func (c *retireCK) RetireZones(ctx context.Context, hubID string) error {
	if err := c.call(ctx, "retire_zones"); err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.retired = append(c.retired, hubID)
	return nil
}

func (c *retireCK) asked() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return slices.Clone(c.retired)
}

// startRetireDesk runs a desktop host whose stored hub_id is stored over a
// retireCK with the iCloud account acct; prep runs on the CloudKit fake
// before the start.
func startRetireDesk(t *testing.T, stored string, acct transport.Account, prep func(*retireCK)) (*deskRig, *retireCK, Options) {
	t.Helper()
	policytest.Set(t, nil)
	r := newDeskRig(t, shortDir(t))
	ck := &retireCK{acctCK: newAcctCK(acct)}
	r.ck = ck.Fake
	fctx, fcancel := context.WithCancel(context.Background())
	t.Cleanup(fcancel)
	go ck.forward(fctx)
	if prep != nil {
		prep(ck)
	}
	setMeta(t, r.dir, state.MetaEnabled, "1", state.MetaHubID, stored)
	o := r.options()
	o.Desktop.newCloudKit = func(cloudkit.Config) transport.Transport { return ck }
	r.start(o)
	// Running, or paused (no_icloud) with an account that cannot be used.
	r.waitStatus("the iCloud account read", func(s Status) bool { return s.CloudKit.Account == string(acct) })
	return r, ck, o
}

// TestAdoptedHubRetiresTheUppercaseZonesOnce (#1750): a hub adopted from
// the Swift hub asks the bridge, once, to delete the zones and the
// subscription builds up to v0.28.0 named with the uppercase hub id —
// that spelling only, never the stored lowercase one its phones use — and
// records it; later cycles and the next start ask nothing.
func TestAdoptedHubRetiresTheUppercaseZonesOnce(t *testing.T) {
	bubble(t, func(t *testing.T) {
		r, ck, o := startRetireDesk(t, adoptedHubID, transport.AccountAvailable, nil)
		upper := strings.ToUpper(adoptedHubID)
		eventually(t, "the uppercase zones retired", func() bool { return len(ck.asked()) > 0 })
		r.cycles(3)
		if got := ck.asked(); !slices.Equal(got, []string{upper}) {
			t.Fatalf("retired %q, want only the uppercase spelling once", got)
		}
		if v, _ := readMetaRO(t, r.dir, metaCloudKitRetiredHubID); v != upper {
			t.Fatalf("retired mark %q, want %q", v, upper)
		}
		if err := r.stop(); err != nil {
			t.Fatal(err)
		}
		r.start(o)
		r.waitState(StateRunning, "")
		r.cycles(2)
		if n := len(ck.asked()); n != 1 {
			t.Fatalf("%d retire calls after a restart, want the first one only", n)
		}
	})
}

// TestGoMadeHubRetiresNothing: a hub the Go hub made stores the uppercase
// hub id, so both spellings are equal and its own zones are the only ones:
// it never asks the bridge to retire anything.
func TestGoMadeHubRetiresNothing(t *testing.T) {
	bubble(t, func(t *testing.T) {
		r, ck, _ := startRetireDesk(t, strings.ToUpper(adoptedHubID), transport.AccountAvailable, nil)
		r.cycles(3)
		if n := ck.count("retire_zones"); n != 0 {
			t.Fatalf("a Go-made hub asked to retire zones %d times", n)
		}
		if _, ok := readMetaRO(t, r.dir, metaCloudKitRetiredHubID); ok {
			t.Fatal("a Go-made hub recorded a retirement")
		}
	})
}

// TestZoneRetirementRetriesAfterAFailure: a failed retirement records
// nothing, does not hold the hub, waits out its backoff (a daemon cycle
// before it asks nothing) and is retried after it.
func TestZoneRetirementRetriesAfterAFailure(t *testing.T) {
	bubble(t, func(t *testing.T) {
		r, ck, _ := startRetireDesk(t, adoptedHubID, transport.AccountAvailable, func(c *retireCK) {
			c.failNext("retire_zones", 1)
		})
		eventually(t, "the first try", func() bool { return ck.count("retire_zones") == 1 })
		r.cycles(2)
		if n := ck.count("retire_zones"); n != 1 {
			t.Fatalf("%d tries inside the backoff, want 1", n)
		}
		if _, ok := readMetaRO(t, r.dir, metaCloudKitRetiredHubID); ok {
			t.Fatal("a failed retirement was recorded")
		}
		r.waitState(StateRunning, "")
		time.Sleep(retireFirstDelay + time.Minute) // the housekeeping ticker runs after the backoff
		synctest.Wait()
		eventually(t, "the retry", func() bool { return len(ck.asked()) == 1 })
		if v, _ := readMetaRO(t, r.dir, metaCloudKitRetiredHubID); v != strings.ToUpper(adoptedHubID) {
			t.Fatalf("retired mark %q after the retry", v)
		}
	})
}

// TestZoneRetirementWaitsForTheICloudAccount: with no usable iCloud
// account nothing is asked; once the account is available it is.
func TestZoneRetirementWaitsForTheICloudAccount(t *testing.T) {
	bubble(t, func(t *testing.T) {
		r, ck, _ := startRetireDesk(t, adoptedHubID, transport.AccountTemporarilyUnavailable, nil)
		r.cycles(2)
		if n := ck.count("retire_zones"); n != 0 {
			t.Fatalf("%d retire calls without an iCloud account", n)
		}
		ck.acct.Store(transport.AccountAvailable)
		r.cycles(1)
		eventually(t, "the retirement once the account is back", func() bool { return len(ck.asked()) == 1 })
	})
}

// TestZoneRetirementGatesBackoffAndLogsOnce drives retireOldCloudKitZones
// on a bare runtime with a test clock: nothing is asked before the
// respelling mark names the stored spelling; a failure waits out a backoff
// that doubles (10 min, then 20 min); a failure class is logged once; the
// mark is written after the bridge answered done, and nothing runs after.
func TestZoneRetirementGatesBackoffAndLogsOnce(t *testing.T) {
	logs := logcanary.Capture(t)
	st, err := state.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	if err := st.SetMeta(state.MetaHubID, adoptedHubID); err != nil {
		t.Fatal(err)
	}
	id, err := identity.New()
	if err != nil {
		t.Fatal(err)
	}
	kr, err := identity.NewKeyring(id, st, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 11, 12, 9, 0, 0, 0, time.UTC)
	ck := &retireCK{acctCK: newAcctCK(transport.AccountAvailable)}
	h := &hubRuntime{sup: &supervisor{o: Options{Clock: func() time.Time { return now }}}, st: st, kr: kr, ck: ck,
		ckAccount: transport.AccountAvailable}
	ctx := context.Background()
	tries := func() int { return ck.count("retire_zones") }

	h.retireOldCloudKitZones(ctx) // no respelling mark yet
	if err := st.SetMeta(metaCloudKitZonesHubID, strings.ToUpper(adoptedHubID)); err != nil {
		t.Fatal(err)
	}
	h.retireOldCloudKitZones(ctx) // the mark names the old spelling
	if n := tries(); n != 0 {
		t.Fatalf("%d retire calls before the respelling was recorded", n)
	}

	if err := st.SetMeta(metaCloudKitZonesHubID, adoptedHubID); err != nil {
		t.Fatal(err)
	}
	ck.failNext("retire_zones", 2)
	steps := []struct {
		advance time.Duration
		tries   int
	}{
		{0, 1},                // fails: next try in 10 min
		{9 * time.Minute, 1},  // inside the backoff
		{time.Minute, 2},      // fails again: next try in 20 min
		{19 * time.Minute, 2}, // inside the doubled backoff
		{time.Minute, 3},      // done
		{24 * time.Hour, 3},   // never again
	}
	for i, s := range steps {
		now = now.Add(s.advance)
		h.retireOldCloudKitZones(ctx)
		if n := tries(); n != s.tries {
			t.Fatalf("step %d: %d tries, want %d", i, n, s.tries)
		}
	}
	if v, _, _ := st.Meta(metaCloudKitRetiredHubID); v != strings.ToUpper(adoptedHubID) {
		t.Fatalf("retired mark %q", v)
	}
	if n := strings.Count(logs.String(), "failed (bridge, unavailable)"); n != 1 {
		t.Fatalf("the failure class was logged %d times, want once:\n%s", n, logs.String())
	}
}
