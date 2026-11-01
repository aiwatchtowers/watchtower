package link

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"reflect"
	"regexp"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
	"unicode"

	"watchtower/internal/hub/secure"
	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/cloudkit"
	"watchtower/internal/hub/transport/cloudkit/bridgefake"
	"watchtower/internal/hub/wire"
	"watchtower/internal/logcanary"
)

// The Go twins of the share behaviours of the Swift MobileLinkCenterTests
// (MobileLinkCenterTests.swift, +SharedLink, +LinkData): same scenarios,
// same assertions, over a fake transport.Shares (and the bridge fake where
// the wire matters).

const ownerUser = "_owner-acme"

// fakeShares is today's FakeShareService in Go: two zones of participants,
// the public link, a call log and failing ops.
type fakeShares struct {
	mu       sync.Mutex
	account  transport.Account
	owner    string
	open     bool
	created  int
	dataURL  string
	relayURL string
	parts    map[string][]transport.Participant
	failing  map[string]bool
	calls    []string
}

func newFakeShares() *fakeShares {
	return &fakeShares{
		account: transport.AccountAvailable, owner: ownerUser, parts: map[string][]transport.Participant{}, failing: map[string]bool{},
		dataURL: "https://share.example.com/d", relayURL: "https://share.example.com/r",
	}
}

func (f *fakeShares) call(op string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, op)
	if f.failing[op] {
		return transport.ErrUnavailable
	}
	return nil
}

func (f *fakeShares) AccountStatus(context.Context) (transport.Account, error) {
	if err := f.call("account_status"); err != nil {
		return "", err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.account, nil
}

func (f *fakeShares) OwnerUser(context.Context) (string, error) {
	if err := f.call("owner_user"); err != nil {
		return "", err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.owner, nil
}

func (f *fakeShares) EnsureShares(context.Context) (string, string, error) {
	if err := f.call("ensure_shares"); err != nil {
		return "", "", err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.created++
	return f.dataURL, f.relayURL, nil
}

func (f *fakeShares) SetPublicLink(_ context.Context, open bool) error {
	if err := f.call("set_public_link"); err != nil {
		return err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.open = open
	return nil
}

func (f *fakeShares) Participants(_ context.Context, zone string) ([]transport.Participant, error) {
	if err := f.call("participants"); err != nil {
		return nil, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.parts[zone]), nil
}

func (f *fakeShares) RemoveParticipants(_ context.Context, zone string, names []string) error {
	if err := f.call("remove_participants"); err != nil {
		return err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.parts[zone] = slices.DeleteFunc(f.parts[zone], func(p transport.Participant) bool {
		return slices.Contains(names, p.UserRecordName)
	})
	return nil
}

var ckZones = []string{transport.DataZone(testRelayID), transport.SharedMailboxZone(testRelayID)}

// join makes user an accepted participant of zones (both when none given).
func (f *fakeShares) join(user string, zones ...string) {
	if len(zones) == 0 {
		zones = ckZones
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, z := range zones {
		f.parts[z] = append(f.parts[z], transport.Participant{UserRecordName: user, Accepted: true})
	}
}

func (f *fakeShares) names(zone string) []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []string
	for _, p := range f.parts[zone] {
		out = append(out, p.UserRecordName)
	}
	slices.Sort(out)
	return out
}

func (f *fakeShares) isOpen() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.open
}

func (f *fakeShares) setFailing(ops ...string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.failing = map[string]bool{}
	for _, op := range ops {
		f.failing[op] = true
	}
}

func (f *fakeShares) takeCalls() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := f.calls
	f.calls = nil
	return out
}

// ckRig is a rig whose center links over CloudKit: the Mac's user (the
// fake bridge's OwnerUser) is ownerUser, the grace is today's.
type ckRig struct {
	*rig
	s   *fakeShares
	ctx context.Context
}

func newCKRig(t *testing.T) *ckRig {
	t.Helper()
	r := newRig(t)
	r.c = r.ckCenter(DefaultSweep)
	return &ckRig{rig: r, s: newFakeShares(), ctx: context.Background()}
}

func (r *rig) ckCenter(sw Sweep) *Center {
	return NewCenter(Config{
		Store: r.st, Keys: r.kr, Opener: secure.NewOpener(r.kr, r.kr),
		Host: HostInfo{Name: "acme-host", RelayDeviceID: testRelayID, RelayAuthPub: testRelayPub,
			Transports: []string{wire.TransportCloudKit, wire.TransportRelay}},
		Clock:   r.clock,
		Publish: func(...string) {},
		Sweep:   sw,
	})
}

func (r *ckRig) issueCK() wire.LinkPayload {
	r.t.Helper()
	p, _, err := r.c.IssueCloudKit(r.ctx, r.s)
	if err != nil {
		r.t.Fatalf("IssueCloudKit: %v", err)
	}
	return p
}

// sharedHello edits a hello into a shared-scope one naming user.
func sharedHello(user string) func(*wire.DeviceHello) {
	return func(h *wire.DeviceHello) {
		h.Device.Scope = wire.ScopeShared
		h.Device.UserRecordName = user
	}
}

// ckHello hands p's hello to the center as the RelayZone record the bridge
// reads, created as a real phone's is: by the user it names (shared), by
// the Mac's own user (private).
func (r *ckRig) ckHello(p phone, nonce string, edit ...func(*wire.DeviceHello)) (Pending, error) {
	r.t.Helper()
	h := wire.DeviceHello{Device: wire.DevicePayload{Scope: wire.ScopePrivate}}
	for _, e := range edit {
		e(&h)
	}
	creator := transport.CurrentUserCreator
	if h.Device.Scope == wire.ScopeShared {
		creator = h.Device.UserRecordName
	}
	return r.ckHelloAs(creator, p, nonce, edit...)
}

// ckHelloAs is ckHello for a record created by creator.
func (r *ckRig) ckHelloAs(creator string, p phone, nonce string, edit ...func(*wire.DeviceHello)) (Pending, error) {
	r.t.Helper()
	rec := transport.Stored{Zone: transport.SharedMailboxZone(testRelayID), Name: p.name(), Envelope: r.hello(p, nonce, edit...),
		Creator: creator}
	return r.c.HandleCloudKitHello(r.ctx, r.s, rec)
}

// linkCK links p (issuing a code first unless nonce is given).
func (r *ckRig) linkCK(p phone, nonce string, edit ...func(*wire.DeviceHello)) {
	r.t.Helper()
	got, err := r.ckHello(p, nonce, edit...)
	if err != nil || got.Code == "" {
		r.t.Fatalf("hello not waiting: %+v %v", got, err)
	}
	if err := r.c.Confirm(p.id.String(), r.code(p), true); err != nil {
		r.t.Fatalf("Confirm: %v", err)
	}
}

func (r *ckRig) sweepMark() string {
	r.t.Helper()
	v, _, err := r.st.Meta(MetaShareSweepPending)
	if err != nil {
		r.t.Fatal(err)
	}
	return v
}

func (r *ckRig) userOf(p phone) string {
	r.t.Helper()
	var user string
	err := r.st.ReadTx(context.Background(), func(tx *sql.Tx) error {
		return tx.QueryRow(`SELECT user_record_name FROM devices WHERE device_id = ?`, p.id.String()).Scan(&user)
	})
	if err != nil {
		r.t.Fatal(err)
	}
	return user
}

func (r *ckRig) codeUsedBy(nonce string) string {
	r.t.Helper()
	var used sql.NullString
	err := r.st.ReadTx(context.Background(), func(tx *sql.Tx) error {
		return tx.QueryRow(`SELECT used_by_device FROM link_codes WHERE nonce = ?`, nonce).Scan(&used)
	})
	if err != nil {
		r.t.Fatal(err)
	}
	return used.String
}

func refusal(kb wire.Keybox) string {
	if kb.Grant.LinkRefused == nil {
		return ""
	}
	return *kb.Grant.LinkRefused
}

func TestIssueOnCloudKitOpensThePublicLinkAndCarriesShares(t *testing.T) {
	r := newRig(t)
	r.c = r.ckCenter(DefaultSweep)
	dir := bridgefake.Dir(t)
	bridge := bridgefake.Serve(t, dir)
	bridge.SetOwnerUser(ownerUser)
	hub := r.kr.HubID().String()
	client := cloudkit.New(cloudkit.Config{Dir: dir, HubID: hub, RelayID: testRelayID})
	t.Cleanup(func() { _ = client.Close() })

	p, url, err := r.c.IssueCloudKit(context.Background(), client)
	if err != nil {
		t.Fatalf("IssueCloudKit: %v", err)
	}
	if !bridge.PublicLink() {
		t.Error("the public link is open while the QR is on screen")
	}
	parsed, err := wire.ParseLinkURL(url)
	if err != nil {
		t.Fatalf("ParseLinkURL: %v", err)
	}
	for _, lp := range []wire.LinkPayload{p, parsed} {
		if lp.V != wire.LinkPayloadVersion || lp.Container != CloudKitContainer || lp.OwnerUser != ownerUser || lp.HubID != hub {
			t.Errorf("CloudKit fields %+v", lp)
		}
		if lp.DataShare == nil || *lp.DataShare != "https://www.icloud.com/share/data-"+hub ||
			lp.RelayShare == nil || *lp.RelayShare != "https://www.icloud.com/share/relay-"+hub {
			t.Errorf("share URLs %v %v", lp.DataShare, lp.RelayShare)
		}
		if lp.Transport != wire.TransportCloudKit || !slices.Equal(lp.Transports, []string{wire.TransportCloudKit, wire.TransportRelay}) ||
			lp.RelayDeviceID != testRelayID || lp.RelayAuthPub != testRelayPub {
			t.Errorf("transports %+v", lp)
		}
	}
	if lp := p; lp.Exp-lp.Iat != 600 {
		t.Errorf("lifetime %d", lp.Exp-lp.Iat)
	}
	if v, _, _ := r.st.Meta(MetaShareSweepPending); v != "1" {
		t.Errorf("sweep mark %q: marked before the link opened", v)
	}
	if !r.c.LinkUrgent() || r.c.Sharing() != SharingAvailable {
		t.Errorf("urgent %v sharing %q", r.c.LinkUrgent(), r.c.Sharing())
	}
	// Closed over the same bridge: the link shuts, the stranger is swept.
	bridge.SetParticipants(cloudkit.DataZoneName(hub), []transport.Participant{{UserRecordName: "_stranger", Accepted: true}})
	bridge.SetParticipants(cloudkit.RelayZoneName(hub), []transport.Participant{{UserRecordName: "_stranger", Accepted: true}})
	if err := r.c.CloseLink(context.Background(), client, CloseRestart); err != nil {
		t.Fatalf("CloseLink: %v", err)
	}
	if bridge.PublicLink() || len(bridge.ParticipantsOf(cloudkit.DataZoneName(hub))) != 0 ||
		len(bridge.ParticipantsOf(cloudkit.RelayZoneName(hub))) != 0 {
		t.Errorf("after the close: link %v participants %v %v", bridge.PublicLink(),
			bridge.ParticipantsOf(cloudkit.DataZoneName(hub)), bridge.ParticipantsOf(cloudkit.RelayZoneName(hub)))
	}
}

// testNoAccountOrRestrictedRefusesTheCodeAndCreatesNoShare.
func TestNoAccountRefusesToIssue(t *testing.T) {
	r := newCKRig(t)
	for _, account := range []transport.Account{transport.AccountNoAccount, transport.AccountRestricted,
		transport.AccountTemporarilyUnavailable, transport.AccountNoEntitlement} {
		r.s.account = account
		_, _, err := r.c.IssueCloudKit(r.ctx, r.s)
		var ae *AccountError
		if !errors.As(err, &ae) || ae.Account != account {
			t.Errorf("%s: err %v", account, err)
		}
	}
	if calls := r.s.takeCalls(); slices.ContainsFunc(calls, func(c string) bool { return c != "account_status" }) {
		t.Errorf("only the account was asked: %v", calls)
	}
	if r.s.created != 0 || r.s.isOpen() {
		t.Error("a share was made or opened")
	}
	if codes, err := r.c.keptCodes(); err != nil || len(codes) != 0 {
		t.Errorf("codes %v %v", codes, err)
	}
	// An unknown owner refuses too, before any share call.
	r.s.account = transport.AccountAvailable
	r.s.owner = ""
	if _, _, err := r.c.IssueCloudKit(r.ctx, r.s); !errors.Is(err, ErrOwnerUnknown) {
		t.Errorf("owner unknown: %v", err)
	}
	if calls := r.s.takeCalls(); !slices.Equal(calls, []string{"account_status", "owner_user"}) {
		t.Errorf("calls %v", calls)
	}
}

// testTheLinkClosesAtUseRemovingAnUnboundParticipantAndKeepingTheBoundOne.
func TestCloseSweepsUnboundParticipants(t *testing.T) {
	r := newCKRig(t)
	code := r.issueCK()
	r.s.join("_colleague-a")
	r.s.join("_stranger")
	a := newPhone(t)
	r.linkCK(a, code.Nonce, sharedHello("_colleague-a"))
	if err := r.c.CloseLink(r.ctx, r.s, CloseUsed); err != nil {
		t.Fatalf("CloseLink: %v", err)
	}
	r.advance(DefaultSweep.AnswerGrace)
	if err := r.c.SweepShares(r.ctx, r.s); err != nil {
		t.Fatalf("SweepShares: %v", err)
	}
	if r.s.isOpen() {
		t.Error("the link stays open")
	}
	for _, z := range ckZones {
		if got := r.s.names(z); !slices.Equal(got, []string{"_colleague-a"}) {
			t.Errorf("%s: %v", z, got)
		}
	}
	if r.sweepMark() != "0" || r.c.Sharing() != SharingAvailable {
		t.Errorf("mark %q sharing %q", r.sweepMark(), r.c.Sharing())
	}
}

// testClosingTheSheetRefusesPendingRequestsBeforeTheSweep, plus a due
// deferred sweep while the code is on screen.
func TestAWaitingPhonesParticipantIsNeverSweptBeforeTheOwnerDecides(t *testing.T) {
	r := newCKRig(t)
	code := r.issueCK()
	r.s.join("_colleague-a")
	a := newPhone(t)
	if got, err := r.ckHello(a, code.Nonce, sharedHello("_colleague-a")); err != nil || got.Code == "" {
		t.Fatalf("not waiting: %+v %v", got, err)
	}
	// A pass while the code is on screen sweeps nothing: the code's own close sweeps.
	r.advance(DefaultSweep.AnswerGrace)
	r.s.takeCalls()
	if err := r.c.SweepShares(r.ctx, r.s); err != nil {
		t.Fatal(err)
	}
	if calls := r.s.takeCalls(); len(calls) != 0 {
		t.Errorf("share calls while the owner decides: %v", calls)
	}
	// The sheet closes: the request is refused before the share calls.
	r.s.setFailing("set_public_link")
	_ = r.c.CloseLink(r.ctx, r.s, CloseSheetClosed)
	if kb := r.mustKeybox(a); refusal(kb) != wire.RefusedNotConfirmed || kb.Keys != nil {
		t.Errorf("refused before the share calls: %+v", kb.Grant)
	}
	if got := r.s.names(ckZones[1]); !slices.Equal(got, []string{"_colleague-a"}) {
		t.Errorf("not swept yet: %v", got)
	}
	r.s.setFailing()
	r.advance(DefaultSweep.AnswerGrace)
	if err := r.c.SweepShares(r.ctx, r.s); err != nil {
		t.Fatal(err)
	}
	if got := r.s.names(ckZones[1]); len(got) != 0 {
		t.Errorf("swept after the refusal: %v", got)
	}
	if ids := pendingIDs(t, r.c); len(ids) != 0 {
		t.Errorf("pending %v", ids)
	}
}

// testALatePhoneReadsUsedCodeBeforeTheSweepRemovesIt.
func TestAnsweringCloseKeepsParticipantsForAnswerGrace(t *testing.T) {
	r := newCKRig(t)
	code := r.issueCK()
	r.s.join("_colleague-a")
	r.s.join("_colleague-b")
	a, b := newPhone(t), newPhone(t)
	r.linkCK(a, code.Nonce, sharedHello("_colleague-a"))
	if err := r.c.CloseLink(r.ctx, r.s, CloseUsed); err != nil {
		t.Fatal(err)
	}
	if r.s.isOpen() {
		t.Error("no one new joins after the use")
	}
	if got := r.s.names(ckZones[0]); !slices.Equal(got, []string{"_colleague-a", "_colleague-b"}) {
		t.Errorf("the late phone can still read: %v", got)
	}
	if !r.c.LinkUrgent() {
		t.Error("the late hello is read at the active cadence")
	}
	if _, err := r.ckHello(b, code.Nonce, sharedHello("_colleague-b")); err != nil {
		t.Fatal(err)
	}
	if kb := r.mustKeybox(b); refusal(kb) != wire.RefusedUsedCode || kb.Keys != nil {
		t.Errorf("late phone %+v", kb.Grant)
	}
	r.advance(DefaultSweep.AnswerGrace - time.Second)
	if err := r.c.SweepShares(r.ctx, r.s); err != nil {
		t.Fatal(err)
	}
	if got := r.s.names(ckZones[0]); len(got) != 2 {
		t.Errorf("swept inside the grace: %v", got)
	}
	r.advance(time.Second)
	if err := r.c.SweepShares(r.ctx, r.s); err != nil {
		t.Fatal(err)
	}
	for _, z := range ckZones {
		if got := r.s.names(z); !slices.Equal(got, []string{"_colleague-a"}) {
			t.Errorf("%s: %v", z, got)
		}
	}
	if r.sweepMark() != "0" || r.c.LinkUrgent() {
		t.Errorf("mark %q urgent %v: the grace is over", r.sweepMark(), r.c.LinkUrgent())
	}
}

// testRemovingASharedPhoneRemovesItsParticipantFromBothShares,
// testLinkingAPrivatePhoneMakesNoParticipantCall.
func TestRemoveDropsTheParticipant(t *testing.T) {
	r := newCKRig(t)
	code := r.issueCK()
	r.s.join("_colleague-a")
	a := newPhone(t)
	r.linkCK(a, code.Nonce, sharedHello("_colleague-a"))
	if err := r.c.RemoveCloudKit(r.ctx, r.s, a.id.String()); err != nil {
		t.Fatalf("RemoveCloudKit: %v", err)
	}
	if r.linked(a) {
		t.Error("still linked")
	}
	for _, z := range ckZones {
		if got := r.s.names(z); len(got) != 0 {
			t.Errorf("%s: %v", z, got)
		}
	}
	// Two phones on one iCloud user: removing one keeps the user on the shares.
	code = r.issueCK()
	r.s.join("_colleague-b")
	b, c := newPhone(t), newPhone(t)
	r.linkCK(b, code.Nonce, sharedHello("_colleague-b"))
	code = r.issueCK()
	r.linkCK(c, code.Nonce, sharedHello("_colleague-b"))
	if err := r.c.RemoveCloudKit(r.ctx, r.s, b.id.String()); err != nil {
		t.Fatal(err)
	}
	if got := r.s.names(ckZones[1]); !slices.Equal(got, []string{"_colleague-b"}) {
		t.Errorf("the other phone's user left: %v", got)
	}
	// A private phone: no participant call at all.
	code = r.issueCK()
	d := newPhone(t)
	r.s.takeCalls()
	r.linkCK(d, code.Nonce)
	if err := r.c.RemoveCloudKit(r.ctx, r.s, d.id.String()); err != nil {
		t.Fatal(err)
	}
	if calls := r.s.takeCalls(); slices.ContainsFunc(calls, func(c string) bool { return c != "owner_user" }) {
		t.Errorf("a private phone made share calls: %v", calls)
	}
}

// testAFailedParticipantRemovalIsSweptByTheNextClose and the retry of a
// failed sweep.
func TestAFailedSweepIsRetried(t *testing.T) {
	r := newCKRig(t)
	code := r.issueCK()
	r.s.join("_colleague-a")
	a := newPhone(t)
	r.linkCK(a, code.Nonce, sharedHello("_colleague-a"))
	r.s.setFailing("remove_participants")
	if err := r.c.RemoveCloudKit(r.ctx, r.s, a.id.String()); err == nil {
		t.Error("the failed removal is reported")
	}
	if r.linked(a) || r.sweepMark() != "1" {
		t.Errorf("linked %v mark %q: the gate refuses the phone at once, the sweep stays pending", r.linked(a), r.sweepMark())
	}
	// A restart close whose sweep fails keeps the mark and retries after 60 s.
	if err := r.c.CloseLink(r.ctx, r.s, CloseRestart); err == nil {
		t.Error("the failed sweep is reported")
	}
	r.s.setFailing()
	r.advance(59 * time.Second)
	r.s.takeCalls()
	if err := r.c.SweepShares(r.ctx, r.s); err != nil {
		t.Fatal(err)
	}
	if calls := r.s.takeCalls(); len(calls) != 0 {
		t.Errorf("retried before its wait: %v", calls)
	}
	r.advance(time.Second)
	if err := r.c.SweepShares(r.ctx, r.s); err != nil {
		t.Fatal(err)
	}
	for _, z := range ckZones {
		if got := r.s.names(z); len(got) != 0 {
			t.Errorf("%s: %v", z, got)
		}
	}
	if r.sweepMark() != "0" {
		t.Errorf("mark %q", r.sweepMark())
	}
	// Retries are bounded: after the last wait the sweep is left to the next close.
	if err := r.st.SetMeta(MetaShareSweepPending, "1"); err != nil {
		t.Fatal(err)
	}
	r.s.setFailing("set_public_link")
	_ = r.c.CloseLink(r.ctx, r.s, CloseRestart)
	for _, wait := range sweepRetryDelays {
		r.advance(wait)
		_ = r.c.SweepShares(r.ctx, r.s)
	}
	r.s.takeCalls()
	r.advance(24 * time.Hour)
	_ = r.c.SweepShares(r.ctx, r.s)
	if calls := r.s.takeCalls(); len(calls) != 0 {
		t.Errorf("a retry past the last wait: %v", calls)
	}
}

// testASharedDeviceRecordFromAnotherCreatorIsRefusedWithNoGrant,
// testASharedPhoneThatDidNotAcceptBothSharesIsNotLinked: on the bridge the
// creator check is the participant check.
func TestWrongCreatorGetsNoKeys(t *testing.T) {
	r := newCKRig(t)
	code := r.issueCK()
	r.s.join("_colleague-a", ckZones[0]) // the data share only
	a, b := newPhone(t), newPhone(t)
	for _, tc := range []struct {
		p    phone
		user string
	}{{a, "_colleague-a"}, {b, "_not-a-participant"}, {b, ""}} {
		if _, err := r.ckHello(tc.p, code.Nonce, sharedHello(tc.user)); !errors.Is(err, ErrHelloDropped) {
			t.Errorf("user %q: err %v", tc.user, err)
		}
	}
	if ids := pendingIDs(t, r.c); len(ids) != 0 {
		t.Errorf("pending %v", ids)
	}
	if grants, err := r.c.Grants(); err != nil || len(grants) != 0 {
		t.Errorf("no grant, not even a refusal: %v %v", grants, err)
	}
	if r.codeUsedBy(code.Nonce) != "" {
		t.Error("the code stays usable for the owner's phone")
	}
	// A failed participant read leaves the phone unanswered too.
	r.s.join("_colleague-a", ckZones[1])
	r.s.setFailing("participants")
	if _, err := r.ckHello(a, code.Nonce, sharedHello("_colleague-a")); !errors.Is(err, ErrHelloDropped) {
		t.Errorf("unreadable participants: %v", err)
	}
	// testASharedPhoneThatAcceptedBothSharesIsLinked.
	r.s.setFailing()
	r.linkCK(a, code.Nonce, sharedHello("_colleague-a"))
	kb := r.mustKeybox(a)
	if !kb.Grant.Linked || kb.Keys == nil || kb.Grant.Scope != wire.ScopeShared || r.userOf(a) != "_colleague-a" {
		t.Errorf("linked %+v user %q", kb.Grant, r.userOf(a))
	}
}

// noAnswer asserts a dropped hello left nothing: no request, no grant (not
// even a refusal), the code unused.
func (r *ckRig) noAnswer(t *testing.T, err error, nonce string) {
	t.Helper()
	if !errors.Is(err, ErrHelloDropped) {
		t.Errorf("err %v", err)
	}
	if ids := pendingIDs(t, r.c); len(ids) != 0 {
		t.Errorf("pending %v", ids)
	}
	if grants, err := r.c.Grants(); err != nil || len(grants) != 0 {
		t.Errorf("no grant, not even a refusal: %v %v", grants, err)
	}
	if r.codeUsedBy(nonce) != "" {
		t.Error("the code stays usable for the owner's phone")
	}
}

// testAPrivateDeviceRecordWrittenByAStrangerIsNotLinked: a stranger who
// joined the public link cannot pass as a same-Apple-ID phone.
func TestAStrangersPrivateHelloNeverWaits(t *testing.T) {
	r := newCKRig(t)
	code := r.issueCK()
	r.s.join("_stranger")
	a := newPhone(t)
	_, err := r.ckHelloAs("_stranger", a, code.Nonce)
	r.noAnswer(t, err, code.Nonce)
	// Claiming the owner's name in the payload changes nothing: the creator decides.
	_, err = r.ckHelloAs("_stranger", a, code.Nonce, func(h *wire.DeviceHello) { h.Device.UserRecordName = ownerUser })
	r.noAnswer(t, err, code.Nonce)
	// With the owner unknown, a named creator cannot be checked: no answer either.
	r.s.setFailing("owner_user")
	_, err = r.ckHelloAs("_stranger", a, code.Nonce)
	r.noAnswer(t, err, code.Nonce)
}

// The private creator check: the current-user name, the owner's own record
// name or no creator pass, and the request is bound to the owner.
func TestAPrivateHelloMustBeCreatedByTheOwner(t *testing.T) {
	for _, creator := range []string{transport.CurrentUserCreator, ownerUser, ""} {
		r := newCKRig(t)
		code := r.issueCK()
		a := newPhone(t)
		got, err := r.ckHelloAs(creator, a, code.Nonce)
		if err != nil || got.Code == "" {
			t.Fatalf("creator %q: %+v %v", creator, got, err)
		}
		if err := r.c.Confirm(a.id.String(), r.code(a), true); err != nil {
			t.Fatal(err)
		}
		if r.userOf(a) != ownerUser {
			t.Errorf("creator %q: user %q", creator, r.userOf(a))
		}
	}
}

// testASharedDeviceRecordFromAnotherCreatorIsRefusedWithNoGrant: a shared
// hello must be created by the user it names, even when that user accepted
// both shares.
func TestASharedHelloFromAnotherCreatorGetsNoAnswer(t *testing.T) {
	r := newCKRig(t)
	code := r.issueCK()
	r.s.join("_colleague-a")
	r.s.join("_stranger")
	a := newPhone(t)
	for _, creator := range []string{"_stranger", transport.CurrentUserCreator, ""} {
		_, err := r.ckHelloAs(creator, a, code.Nonce, sharedHello("_colleague-a"))
		r.noAnswer(t, err, code.Nonce)
	}
	r.linkCK(a, code.Nonce, sharedHello("_colleague-a"))
	if !r.linked(a) {
		t.Error("the right creator links")
	}
}

// The creator travels the real wire: a stranger's private hello written into
// the bridge's RelayZone comes back from Changes with its creator and gets
// no answer, while the owner's own hello waits.
func TestTheBridgeCarriesTheCreatorToTheCheck(t *testing.T) {
	r := &ckRig{rig: newRig(t), ctx: context.Background()}
	r.c = r.ckCenter(DefaultSweep)
	dir := bridgefake.Dir(t)
	bridge := bridgefake.Serve(t, dir)
	bridge.SetOwnerUser(ownerUser)
	hub := r.kr.HubID().String()
	client := cloudkit.New(cloudkit.Config{Dir: dir, HubID: hub, RelayID: testRelayID})
	t.Cleanup(func() { _ = client.Close() })
	code, _, err := r.c.IssueCloudKit(r.ctx, client)
	if err != nil {
		t.Fatal(err)
	}
	phones := bridge.PhoneRecords(hub)
	mbox := transport.SharedMailboxZone(testRelayID)
	stranger, mine := newPhone(t), newPhone(t)
	if _, err := phones.WriteAs("_stranger", mbox, stranger.name(), r.hello(stranger, code.Nonce), transport.Expect{}); err != nil {
		t.Fatal(err)
	}
	if _, err := phones.WriteAs(transport.CurrentUserCreator, mbox, mine.name(), r.hello(mine, code.Nonce), transport.Expect{}); err != nil {
		t.Fatal(err)
	}
	b, err := client.Changes(r.ctx, mbox, 0)
	if err != nil || len(b.Changed) != 2 {
		t.Fatalf("changes %+v %v", b, err)
	}
	for _, rec := range b.Changed {
		got, err := r.c.HandleCloudKitHello(r.ctx, client, rec)
		switch rec.Name {
		case stranger.name():
			if rec.Creator != "_stranger" || !errors.Is(err, ErrHelloDropped) {
				t.Errorf("stranger: creator %q err %v", rec.Creator, err)
			}
		case mine.name():
			if rec.Creator != transport.CurrentUserCreator || err != nil || got.Code == "" {
				t.Errorf("owner's phone: creator %q %+v %v", rec.Creator, got, err)
			}
		}
	}
	if ids := pendingIDs(t, r.c); !slices.Equal(ids, []string{mine.id.String()}) {
		t.Errorf("pending %v", ids)
	}
}

// testAPrivatePhoneIsCheckedAgainstTheOwnerNotTheNameItSent.
func TestAPrivatePhoneIsBoundToTheOwnerNotTheNameItSent(t *testing.T) {
	r := newCKRig(t)
	code := r.issueCK()
	a := newPhone(t)
	r.s.takeCalls()
	r.linkCK(a, code.Nonce, func(h *wire.DeviceHello) { h.Device.UserRecordName = "_claimed-acme" })
	if r.userOf(a) != ownerUser {
		t.Errorf("user %q", r.userOf(a))
	}
	if calls := r.s.takeCalls(); slices.Contains(calls, "participants") {
		t.Errorf("a private phone's participants were read: %v", calls)
	}
}

func TestARestartCloseSweepsWithoutTheGrace(t *testing.T) {
	r := newCKRig(t)
	r.issueCK()
	r.s.join("_stranger")
	next := r.ckCenter(DefaultSweep) // the next run
	if err := next.CloseLink(r.ctx, r.s, CloseRestart); err != nil {
		t.Fatal(err)
	}
	if r.s.isOpen() || len(r.s.names(ckZones[1])) != 0 || next.LinkUrgent() {
		t.Errorf("open %v participants %v urgent %v", r.s.isOpen(), r.s.names(ckZones[1]), next.LinkUrgent())
	}
}

func TestALinkLeftOpenByAnEarlierRunIsClosedAtTheNextBuild(t *testing.T) {
	r := newCKRig(t)
	r.issueCK()
	next := r.ckCenter(DefaultSweep)
	if err := next.CloseLink(r.ctx, r.s, CloseRestart); err != nil {
		t.Fatal(err)
	}
	if r.s.isOpen() {
		t.Error("left open")
	}
	r.s.takeCalls()
	if err := next.CloseLink(r.ctx, r.s, CloseRestart); err != nil {
		t.Fatal(err)
	}
	if calls := r.s.takeCalls(); len(calls) != 0 {
		t.Errorf("a closed link needs no share call: %v", calls)
	}
}

func TestALateHelloAfterACloseReadsTheClosesRefusal(t *testing.T) {
	for _, tc := range []struct {
		reason CloseReason
		want   string
	}{{CloseSheetClosed, wire.RefusedNotConfirmed}, {CloseExpired, wire.RefusedExpiredCode}} {
		t.Run(string(tc.reason), func(t *testing.T) {
			r := newCKRig(t)
			code := r.issueCK()
			r.s.join("_colleague-b")
			if err := r.c.CloseLink(r.ctx, r.s, tc.reason); err != nil {
				t.Fatal(err)
			}
			b := newPhone(t)
			if _, err := r.ckHello(b, code.Nonce, sharedHello("_colleague-b")); err != nil {
				t.Fatal(err)
			}
			if ids := pendingIDs(t, r.c); len(ids) != 0 {
				t.Errorf("no request waits under a closed code: %v", ids)
			}
			if got := refusal(r.mustKeybox(b)); got != tc.want {
				t.Errorf("refusal %q", got)
			}
			if got := r.s.names(ckZones[0]); !slices.Equal(got, []string{"_colleague-b"}) {
				t.Errorf("the grace still runs: %v", got)
			}
		})
	}
}

func TestANewCodeCancelsAPendingGraceSweep(t *testing.T) {
	r := newCKRig(t)
	r.issueCK()
	if err := r.c.CloseLink(r.ctx, r.s, CloseSheetClosed); err != nil {
		t.Fatal(err)
	}
	r.issueCK()
	r.s.join("_colleague-c")
	r.advance(DefaultSweep.AnswerGrace)
	if err := r.c.SweepShares(r.ctx, r.s); err != nil {
		t.Fatal(err)
	}
	if !r.s.isOpen() || !slices.Equal(r.s.names(ckZones[1]), []string{"_colleague-c"}) {
		t.Errorf("open %v participants %v", r.s.isOpen(), r.s.names(ckZones[1]))
	}
}

func TestAPrivatePhoneLinksWithoutAnyShareWhenSharingFails(t *testing.T) {
	r := newCKRig(t)
	r.s.setFailing("ensure_shares")
	code := r.issueCK()
	a := newPhone(t)
	r.linkCK(a, code.Nonce)
	if code.DataShare != nil || code.RelayShare != nil || r.c.Sharing() != SharingUnavailable || !r.linked(a) {
		t.Errorf("code %+v sharing %q", code, r.c.Sharing())
	}
	if err := r.c.CloseLink(r.ctx, r.s, CloseUsed); err != nil {
		t.Fatal(err)
	}
	if calls := r.s.takeCalls(); !slices.Equal(calls, []string{"account_status", "owner_user", "ensure_shares", "owner_user"}) {
		t.Errorf("no link opened, so none to close: %v", calls)
	}
}

func TestTheLinkClosesAt600Seconds(t *testing.T) {
	r := newCKRig(t)
	r.issueCK()
	r.s.join("_stranger")
	r.advance(599 * time.Second)
	if err := r.c.SweepShares(r.ctx, r.s); err != nil || !r.s.isOpen() {
		t.Fatalf("closed early: %v", err)
	}
	r.advance(time.Second)
	if err := r.c.SweepShares(r.ctx, r.s); err != nil {
		t.Fatal(err)
	}
	if r.s.isOpen() {
		t.Error("open after 600 s")
	}
	r.advance(DefaultSweep.AnswerGrace)
	if err := r.c.SweepShares(r.ctx, r.s); err != nil {
		t.Fatal(err)
	}
	if got := r.s.names(ckZones[1]); len(got) != 0 {
		t.Errorf("stranger kept: %v", got)
	}
}

// testAFailedLinkCloseIsRetriedBeforeTheGraceEnds.
func TestAFailedLinkCloseIsRetriedBeforeTheGraceEnds(t *testing.T) {
	r := newCKRig(t)
	r.issueCK()
	r.s.setFailing("set_public_link")
	if err := r.c.CloseLink(r.ctx, r.s, CloseSheetClosed); err == nil {
		t.Error("the failed close is reported")
	}
	r.s.setFailing()
	r.advance(linkCloseRetryDelays[0])
	if err := r.c.SweepShares(r.ctx, r.s); err != nil {
		t.Fatal(err)
	}
	if r.s.isOpen() {
		t.Error("the link close was not retried inside the grace")
	}
}

// TestCloudKitLinkingMatchesTheSwiftHub pins the wire shapes and the share
// rules today's phone and Swift hub use (phone contract point 8): the QR's
// key set, the container, the share surface and the timing constants. The
// literals hold on their own; the Swift sources are read too while they
// exist (Task 24 deletes Services/MobileHub).
func TestCloudKitLinkingMatchesTheSwiftHub(t *testing.T) {
	r := newCKRig(t)
	p := r.issueCK()
	got := jsonKeys(t, p)

	// The fixture's v4 Desktop code (WatchtowerKit hub_contract_cases.json) has exactly these keys.
	raw, err := os.ReadFile("../../../WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		LinkPayload []struct {
			Name   string         `json:"name"`
			Expect map[string]any `json:"expect"`
		} `json:"link_payload"`
	}
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatal(err)
	}
	var want []string
	for _, c := range fixture.LinkPayload {
		if c.Name == "v4_desktop" {
			for k := range c.Expect {
				want = append(want, k)
			}
		}
	}
	slices.Sort(want)
	if len(want) == 0 || !slices.Equal(got, want) {
		t.Errorf("QR keys %v, the fixture's v4_desktop %v", got, want)
	}

	// Every key of today's Kit LinkPayload (v3) is there, and the container is the Kit's.
	kitKeys := []string{"container", "data_share", "exp", "hub_id", "hub_kx", "hub_sig", "iat", "mac_name", "nonce", "owner_user", "relay_share", "v"}
	for _, k := range kitKeys {
		if !slices.Contains(got, k) {
			t.Errorf("the Kit's key %q is missing", k)
		}
	}
	if CloudKitContainer != "iCloud.com.aiwatchtowers.watchtower" {
		t.Errorf("container %q", CloudKitContainer)
	}
	if src, err := os.ReadFile("../../../WatchtowerKit/Sources/WatchtowerSync/Link/LinkPayload.swift"); err == nil {
		var swiftKeys []string
		block := regexp.MustCompile(`(?s)enum CodingKeys: String, CodingKey \{(.*?)\}`).FindSubmatch(src)
		for _, m := range regexp.MustCompile(`case (\w+)(?: = "(\w+)")?`).FindAllSubmatch(block[1], -1) {
			key := string(m[1])
			if len(m[2]) > 0 {
				key = string(m[2])
			}
			swiftKeys = append(swiftKeys, key)
		}
		slices.Sort(swiftKeys)
		if !slices.Equal(swiftKeys, kitKeys) {
			t.Errorf("the Kit's LinkPayload keys are %v, pinned %v", swiftKeys, kitKeys)
		}
	}
	if src, err := os.ReadFile("../../../WatchtowerKit/Sources/WatchtowerSync/Relay/RelayRecordKind.swift"); err == nil &&
		!strings.Contains(string(src), `containerID = "`+CloudKitContainer+`"`) {
		t.Error("the Kit's WatchtowerCloud.containerID differs")
	}

	// The constants copied verbatim from today's MobileLinkCenter / MobileHubService.
	if MetaShareSweepPending != "share_sweep_pending" || DefaultSweep.AnswerGrace != 120*time.Second ||
		ShareTimeout != 30*time.Second ||
		!slices.Equal(sweepRetryDelays, []time.Duration{time.Minute, 5 * time.Minute, 15 * time.Minute, time.Hour}) ||
		!slices.Equal(linkCloseRetryDelays, []time.Duration{15 * time.Second, time.Minute}) {
		t.Error("a constant changed")
	}
	const swiftHub = "../../../WatchtowerDesktop/Sources/Services/MobileHub/"
	if src, err := os.ReadFile(swiftHub + "MobileLinkCenter.swift"); err == nil {
		for _, line := range []string{
			`sweepPendingKey = "share_sweep_pending"`,
			`answerGrace: Duration = .seconds(120)`,
			`sweepRetryDelays: [Duration] = [.seconds(60), .seconds(300), .seconds(900), .seconds(3600)]`,
			`linkCloseRetryDelays: [Duration] = [.seconds(15), .seconds(60)]`,
			`case sheetClosed = "sheet_closed"`, `case issueFailed = "issue_failed"`, `case accountChanged = "account_changed"`,
		} {
			if !strings.Contains(string(src), line) {
				t.Errorf("MobileLinkCenter.swift no longer has %q", line)
			}
		}
	}
	if src, err := os.ReadFile(swiftHub + "MobileHubService.swift"); err == nil &&
		!strings.Contains(string(src), "defaultCloudTimeout: Duration = .seconds(30)") {
		t.Error("the Swift share timeout changed")
	}

	// The share surface is today's ShareService, call for call.
	shareOps := []string{"accountStatus", "ensureShares", "participants", "removeParticipants", "setPublicLink"}
	var goOps []string
	st := reflect.TypeFor[transport.Shares]()
	for i := range st.NumMethod() {
		n := []rune(st.Method(i).Name)
		n[0] = unicode.ToLower(n[0])
		goOps = append(goOps, string(n))
	}
	slices.Sort(goOps)
	if !slices.Equal(goOps, shareOps) {
		t.Errorf("transport.Shares %v, ShareService %v", goOps, shareOps)
	}
	if src, err := os.ReadFile(swiftHub + "ShareService.swift"); err == nil {
		block := regexp.MustCompile(`(?s)protocol ShareService: Sendable \{(.*?)\n\}`).FindSubmatch(src)
		var swiftOps []string
		for _, m := range regexp.MustCompile(`func (\w+)\(`).FindAllSubmatch(block[1], -1) {
			swiftOps = append(swiftOps, string(m[1]))
		}
		slices.Sort(swiftOps)
		if !slices.Equal(swiftOps, shareOps) {
			t.Errorf("ShareService is %v, pinned %v", swiftOps, shareOps)
		}
	}
}

func jsonKeys(t *testing.T, v any) []string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	var keys []string
	for k := range m {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	return keys
}

func TestFILES01_CloudKitLinkLogsNoCodesURLsOrNames(t *testing.T) {
	sink := logcanary.Capture(t)
	r := newCKRig(t)
	r.s.dataURL = "https://share.example.com/" + logcanary.Text("share.url")
	r.s.relayURL = r.s.dataURL
	user := logcanary.Text("user_record_name")
	name := logcanary.Text("device.name")
	named := func(h *wire.DeviceHello) { h.Device.Name = name }

	code := r.issueCK()
	r.s.join(user)
	a, b := newPhone(t), newPhone(t)
	r.linkCK(a, code.Nonce, sharedHello(user), named)
	_, _ = r.ckHello(b, code.Nonce, sharedHello(logcanary.Text("other.user")), named)
	_ = r.c.CloseLink(r.ctx, r.s, CloseUsed)
	r.advance(DefaultSweep.AnswerGrace)
	_ = r.c.SweepShares(r.ctx, r.s)
	r.s.setFailing("remove_participants", "set_public_link")
	_ = r.c.RemoveCloudKit(r.ctx, r.s, a.id.String())
	_ = r.c.CloseLink(r.ctx, r.s, CloseRestart)
	r.s.setFailing("ensure_shares")
	code2 := r.issueCK()
	r.s.account = transport.AccountNoAccount
	_, _, _ = r.c.IssueCloudKit(r.ctx, r.s)

	sink.AssertClean(t)
	out := sink.String()
	if !strings.Contains(out, "hub link:") {
		t.Fatal("nothing was logged: the check proves nothing")
	}
	for _, secret := range []string{code.Nonce, code2.Nonce, "watchtower://", "share.example.com"} {
		if strings.Contains(out, secret) {
			t.Errorf("%q reached the log", secret)
		}
	}
}
