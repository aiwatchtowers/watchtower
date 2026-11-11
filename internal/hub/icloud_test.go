package hub

import (
	"context"
	"database/sql"
	"strings"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	hubslices "watchtower/internal/hub/slices"
	"watchtower/internal/hub/state"
	"watchtower/internal/hub/switcher"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/cloudkit"
	"watchtower/internal/policy/policytest"
)

// Go twins of MobileHubServiceTests' iCloud tests (ask #969 Q3, "do it as
// Swift"): no usable account holds the CloudKit side until it returns; an
// account change or a zone deleted on the server wipes what was published.

// acctCK is a ckShares whose iCloud account the test sets, counting the
// reads of a mailbox on CloudKit.
type acctCK struct {
	*ckShares
	acct  atomic.Value // transport.Account
	reads atomic.Int64
}

func newAcctCK(a transport.Account) *acctCK {
	c := &acctCK{ckShares: newCKShares()}
	c.acct.Store(a)
	return c
}

func (c *acctCK) AccountStatus(ctx context.Context) (transport.Account, error) {
	return c.acct.Load().(transport.Account), c.call(ctx, "account_status")
}

func (c *acctCK) Changes(ctx context.Context, zone string, since uint64) (transport.Batch, error) {
	if strings.HasPrefix(zone, "relay/") { // a mailbox (transport.MailboxZone)
		c.reads.Add(1)
	}
	return c.ckShares.Changes(ctx, zone, since)
}

// urgentSource is an owner_ask slice (an urgent kind, which PullNow marks
// dirty) that counts its reads.
type urgentSource struct{ reads atomic.Int64 }

func (*urgentSource) Kind() hubslices.Kind { return "owner_ask" }
func (s *urgentSource) Items(context.Context) ([]hubslices.Item, error) {
	s.reads.Add(1)
	return []hubslices.Item{{ID: "1", Payload: []byte(`{"id":1}`)}}, nil
}

// startICloudDesk runs a desktop host over an acctCK reporting no iCloud
// account, with a linked phone, active the transport given, the source src,
// and waits until its status shows the account.
func startICloudDesk(t *testing.T, active transport.Kind, src hubslices.Source) (*deskRig, *acctCK) {
	t.Helper()
	policytest.Set(t, nil)
	r := newDeskRig(t, shortDir(t))
	ck := newAcctCK(transport.AccountNoAccount)
	r.ck = ck.Fake
	fctx, fcancel := context.WithCancel(context.Background())
	t.Cleanup(fcancel)
	go ck.forward(fctx)
	setMeta(t, r.dir, state.MetaEnabled, "1", switcher.MetaTransport, string(active))
	linkPhoneDirectly(t, r.dir)
	o := r.options()
	o.Desktop.newCloudKit = func(cloudkit.Config) transport.Transport {
		r.ckDial.Add(1)
		return ck
	}
	o.Sources = func(*state.Store) []hubslices.Source { return []hubslices.Source{src} }
	r.start(o)
	// Paused (no_icloud) only while CloudKit is the active transport; on the
	// relay nothing is paused.
	wantState, wantReason := StateRunning, ""
	if active == transport.KindCloudKit {
		wantState, wantReason = StatePaused, ReasonNoICloud
	}
	r.waitStatus("no iCloud account", func(s Status) bool {
		return s.Transport == string(active) && s.CloudKit.Account == string(transport.AccountNoAccount) &&
			s.State == wantState && s.Reason == wantReason
	})
	time.Sleep(300 * time.Millisecond) // a cycle or pass the hold waited for ends
	return r, ck
}

// twin of MobileHubServiceTests.testUnavailableICloudRunsNoLoopsAndRecoversWhenItReturns
// — a desktop host whose bridge reports no iCloud account reads no mailbox
// and publishes nothing on CloudKit (its active transport), however often
// it is woken; once the account is back (read at the next daemon cycle) it
// publishes and reads again by itself.
func TestNoICloudAccountHoldsCloudKitUntilItReturns(t *testing.T) {
	bubble(t, func(t *testing.T) {
		src := &urgentSource{}
		r, ck := startICloudDesk(t, transport.KindCloudKit, src)
		reads, mbox := src.reads.Load(), ck.reads.Load()
		ck.inject(transport.Event{PullNow: true}) // a pass now, the urgent kinds dirty
		time.Sleep(hubslices.CloudKitSpacing + 500*time.Millisecond)
		synctest.Wait()
		if n, m := src.reads.Load()-reads, ck.reads.Load()-mbox; n != 0 || m != 0 {
			t.Fatalf("with no iCloud account the hub read a slice source %d times and the mailbox %d times", n, m)
		}

		ck.acct.Store(transport.AccountAvailable)
		r.tick <- struct{}{} // the daemon cycle reads the account again
		eventually(t, "the full diff and the pass after the account came back", func() bool {
			return src.reads.Load() > reads && ck.reads.Load() > mbox
		})
		r.waitStatus("running again with the account", func(s Status) bool {
			return s.State == StateRunning && s.Reason == "" && s.CloudKit.Account == string(transport.AccountAvailable)
		})
	})
}

// With the relay active, no iCloud account holds only CloudKit's mailbox
// (the switch's standby poll of it); the relay side publishes on.
func TestNoICloudAccountOnTheRelayHoldsOnlyCloudKitsMailbox(t *testing.T) {
	bubble(t, func(t *testing.T) {
		src := &urgentSource{}
		r, ck := startICloudDesk(t, transport.KindRelay, src)
		mbox := ck.reads.Load()
		rid := r.rec.last().RelayDeviceID
		ck.inject(transport.Event{Zone: transport.SharedMailboxZone(rid)}) // a pass and the standby poll now
		time.Sleep(500 * time.Millisecond)
		synctest.Wait()
		if m := ck.reads.Load() - mbox; m != 0 {
			t.Fatalf("with no iCloud account the standby poll read CloudKit's mailbox %d times", m)
		}
		reads := src.reads.Load()
		ck.inject(transport.Event{PullNow: true})
		eventually(t, "the relay side publishing", func() bool { return src.reads.Load() > reads })

		ck.acct.Store(transport.AccountAvailable)
		r.tick <- struct{}{}
		eventually(t, "CloudKit's mailbox read after the account came back", func() bool {
			ck.inject(transport.Event{Zone: transport.SharedMailboxZone(rid)})
			return ck.reads.Load() > mbox
		})
	})
}

// ckResetRig is a CloudKit hub with no pass of its own (a never-firing pass
// ticker and the memfake's zone events dropped), so the zone token a test
// writes is read back as the reset left it.
// Its tick is the daemon cycle (housekeeping).
func ckResetRig(t *testing.T) (*ckHub, chan struct{}) {
	t.Helper()
	tick := make(chan struct{}, 1)
	h := startCloudKitHub(t, nil, func(o *Options) {
		o.passTicker = func(time.Duration) (<-chan time.Time, func()) { return nil, func() {} }
		o.CycleTick = tick
	})
	h.ck.quiet.Store(true)
	h.settle()
	return h, tick
}

// seedPublished writes, from a second handle, a published workbench record,
// CloudKit's mailbox token and a done ledger row.
func (h *ckHub) seedPublished() {
	h.t.Helper()
	st, err := state.Open(h.dir)
	if err != nil {
		h.t.Fatal(err)
	}
	defer func() { _ = st.Close() }()
	if err := st.WithTx(context.Background(), func(tx *sql.Tx) error {
		if err := state.SetSliceState(tx, "workbench-1", "w-1", "hash", time.Now()); err != nil {
			return err
		}
		if err := state.SetZoneTokenTx(tx, h.mailbox(), 7); err != nil {
			return err
		}
		return state.MarkDone(tx, "action-1", "applied", nil, nil, time.Now())
	}); err != nil {
		h.t.Fatal(err)
	}
}

func (h *ckHub) mailbox() string { return transport.SharedMailboxZone(h.status.RelayDeviceID) }

// published reads the workbench hashes, CloudKit's mailbox token, the
// ledger row's phase and hub_meta's hub_id and enabled_at.
func (h *ckHub) published() (workbench int, token uint64, phase, hubID, enabledAt string) {
	h.t.Helper()
	st, err := state.Open(h.dir)
	if err != nil {
		h.t.Fatal(err)
	}
	defer func() { _ = st.Close() }()
	hashes, err := st.SliceHashes("workbench")
	if err != nil {
		h.t.Fatal(err)
	}
	if token, err = st.ZoneToken(h.mailbox()); err != nil {
		h.t.Fatal(err)
	}
	if phase, _, _, err = st.Phase("action-1"); err != nil {
		h.t.Fatal(err)
	}
	hubID, _, _ = st.Meta(state.MetaHubID)
	enabledAt, _, _ = st.Meta(state.MetaEnabledAt)
	return len(hashes), token, phase, hubID, enabledAt
}

// generation reads the sync generation (bumped by each wipe).
func (h *ckHub) generation() int64 {
	h.t.Helper()
	st, err := state.Open(h.dir)
	if err != nil {
		h.t.Fatal(err)
	}
	defer func() { _ = st.Close() }()
	g, err := st.SyncGeneration()
	if err != nil {
		h.t.Fatal(err)
	}
	return g
}

// exec runs one statement on the sidecar from a second handle.
func (h *ckHub) exec(q string) {
	h.t.Helper()
	st, err := state.Open(h.dir)
	if err != nil {
		h.t.Fatal(err)
	}
	defer func() { _ = st.Close() }()
	if err := st.WithTx(context.Background(), func(tx *sql.Tx) error {
		_, err := tx.Exec(q)
		return err
	}); err != nil {
		h.t.Fatal(err)
	}
}

// twin of MobileHubServiceTests.testAccountResetWipesHashesAndTokenButKeepsTheLedger
// — an iCloud account change wipes the published hashes and CloudKit's
// mailbox token; the ledger, the hub id and enabled_at stay.
func TestAnICloudAccountChangeWipesHashesAndTokenButKeepsTheLedger(t *testing.T) {
	bubble(t, func(t *testing.T) {
		h, _ := ckResetRig(t)
		_, _, _, hubID, enabledAt := h.published()
		h.seedPublished()
		gen := h.generation()
		h.ck.inject(transport.Event{AccountChanged: true})
		eventually(t, "the published state wiped", func() bool {
			n, token, _, _, _ := h.published()
			return n == 0 && token == 0 && h.generation() == gen+1
		})
		_, _, phase, gotHub, gotEnabled := h.published()
		if phase != state.PhaseDone {
			t.Fatalf("the ledger row is %q: phone UUIDs cannot collide across accounts", phase)
		}
		if hubID == "" || gotHub != hubID || gotEnabled != enabledAt {
			t.Fatalf("hub_id %q → %q, enabled_at %q → %q", hubID, gotHub, enabledAt, gotEnabled)
		}
	})
}

// twin of MobileHubServiceTests.testDataZoneResetWipesHashesButKeepsTheRelayTokenAndTheLedger
// and of RelayProcessorRecordingUploadTests.testADataZoneResetNeitherReingestsAFailedUploadNorReEchoesAReceivedOne
// — the bridge recreating a zone deleted on the server wipes the published
// hashes and the staged assets but keeps CloudKit's mailbox token (the
// relay buffer survived: rewinding it would re-read what was answered) and
// the ledger.
func TestRecreatedZonesWipeHashesButKeepTheMailboxTokenAndTheLedger(t *testing.T) {
	bubble(t, func(t *testing.T) {
		h, _ := ckResetRig(t)
		seedStagedAssets(t, h.dir)
		h.seedPublished()
		gen := h.generation()
		h.ck.inject(transport.Event{ZonesRecreated: true})
		eventually(t, "the published state and the staged assets wiped", func() bool {
			n, _, _, _, _ := h.published()
			file, row := stagedLeft(t, h.dir)
			return n == 0 && !file && !row && h.generation() == gen+1
		})
		if _, token, phase, _, _ := h.published(); token != 7 || phase != state.PhaseDone {
			t.Fatalf("mailbox token %d (want 7), ledger %q", token, phase)
		}
		if s := h.rec.last(); s.State != StateRunning {
			t.Fatalf("the hub stopped: %+v", s)
		}
	})
}

// A reset whose wipe fails keeps the published state as it was and is
// retried at the next daemon cycle, which wipes it: released unwiped, the
// full diff would match the old hashes and publish nothing into the new zone.
func TestAFailedCloudKitWipeIsRetriedAtTheNextCycle(t *testing.T) {
	bubble(t, func(t *testing.T) {
		h, tick := ckResetRig(t)
		h.seedPublished()
		gen := h.generation()
		h.exec(`ALTER TABLE work_alerts RENAME TO work_alerts_away`) // the wipe's first statement fails
		h.ck.inject(transport.Event{ZonesRecreated: true})
		time.Sleep(500 * time.Millisecond) // the event handled, its wipe failed
		synctest.Wait()
		if n, _, _, _, _ := h.published(); n != 1 || h.generation() != gen {
			t.Fatalf("after a failed wipe: %d published rows, generation %d (want 1, %d)", n, h.generation(), gen)
		}
		h.exec(`ALTER TABLE work_alerts_away RENAME TO work_alerts`)
		tick <- struct{}{}
		eventually(t, "the retried wipe", func() bool {
			n, _, _, _, _ := h.published()
			return n == 0 && h.generation() == gen+1
		})
	})
}

// With the relay active, an iCloud account change rewinds only CloudKit's
// mailbox: the relay's published state and the generation stay.
func TestAnICloudAccountChangeOnTheRelayRewindsOnlyCloudKitsMailbox(t *testing.T) {
	bubble(t, func(t *testing.T) {
		src := &urgentSource{}
		r, ck := startICloudDesk(t, transport.KindRelay, src)
		mailbox := transport.SharedMailboxZone(r.rec.last().RelayDeviceID)
		st, err := state.Open(r.dir)
		if err != nil {
			t.Fatal(err)
		}
		defer func() { _ = st.Close() }()
		eventually(t, "the relay side published", func() bool {
			hashes, err := st.SliceHashes("owner_ask")
			return err == nil && len(hashes) > 0
		})
		if err := st.SetZoneToken(mailbox, 7); err != nil {
			t.Fatal(err)
		}
		gen, err := st.SyncGeneration()
		if err != nil {
			t.Fatal(err)
		}
		ck.inject(transport.Event{AccountChanged: true})
		eventually(t, "CloudKit's mailbox rewound", func() bool {
			token, err := st.ZoneToken(mailbox)
			return err == nil && token == 0
		})
		hashes, err := st.SliceHashes("owner_ask")
		if g, gerr := st.SyncGeneration(); err != nil || gerr != nil || len(hashes) == 0 || g != gen {
			t.Fatalf("the relay's published state: %d rows, generation %d -> %d (%v, %v)", len(hashes), gen, g, err, gerr)
		}
	})
}
