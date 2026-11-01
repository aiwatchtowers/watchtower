// Package bridgefake is a CloudKit bridge for the hub's tests: it serves the
// bridge protocol on <dir>/bridge.sock over a CloudKit-kind memfake (opaque
// change tags, its own change cursors), keeps a copy of every frame it
// received (Frames) and sent (Answers) for canary checks, and plays the
// bridge's shares and pushes. It checks what the real bridge checks on its
// side: Hello first, zones of the hub only, assets under <dir>/assets and
// downloads under <dir>/downloads.
// Test-only: never imported by production code.
package bridgefake

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"watchtower/internal/hub/transport"
	"watchtower/internal/hub/transport/cloudkit"
	"watchtower/internal/hub/transport/cloudkit/bridgepb"
	"watchtower/internal/hub/transport/memfake"
)

// Option configures a Fake.
type Option func(*Fake)

// WithVersion makes the fake answer Hello with protocol version v.
func WithVersion(v uint32) Option { return func(f *Fake) { f.version = v } }

// WithClock stamps the records' server time (nil = time.Now).
func WithClock(clock func() time.Time) Option { return func(f *Fake) { f.clock = clock } }

// Fake is a bridge on a socket; safe for concurrent use.
type Fake struct {
	t       testing.TB
	dir     string
	version uint32
	clock   func() time.Time
	l       *net.UnixListener
	wg      sync.WaitGroup
	stop    chan struct{}

	mu           sync.Mutex
	store        *memfake.Fake
	gen          string
	reset        chan struct{}
	conns        map[*fakeConn]bool
	frames       [][]byte
	answers      [][]byte
	hubID        string
	account      transport.Account
	publicLink   bool
	participants map[string][]transport.Participant
	fail         map[string][]string
	accepted     int
}

type fakeConn struct {
	uc    *net.UnixConn
	wmu   sync.Mutex
	hello bool
}

// Dir is a fresh 0700 hub dir with a short path (a unix socket path is
// capped near 104 bytes, which a t.TempDir path can pass on macOS).
func Dir(t testing.TB) string {
	t.Helper()
	d, err := os.MkdirTemp("", "bfk")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(d) })
	return d
}

// Serve starts a bridge on <dir>/bridge.sock (0600); it stops at the test's
// end.
func Serve(t testing.TB, dir string, opts ...Option) *Fake {
	t.Helper()
	f := &Fake{
		t: t, dir: dir, version: cloudkit.ProtocolVersion, clock: time.Now, account: transport.AccountAvailable,
		conns: map[*fakeConn]bool{}, participants: map[string][]transport.Participant{}, fail: map[string][]string{},
		stop: make(chan struct{}), reset: make(chan struct{}, 1), gen: newGeneration(t),
	}
	for _, o := range opts {
		o(f)
	}
	f.store = memfake.New(transport.KindCloudKit, f.clock)
	path := filepath.Join(dir, cloudkit.SocketName)
	l, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatalf("bridgefake: listen: %v", err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatalf("bridgefake: chmod: %v", err)
	}
	f.l = l
	f.wg.Add(2)
	go f.accept()
	go f.forwardEvents()
	t.Cleanup(f.Close)
	return f
}

// Close stops the bridge: the listener, every connection, the event pump.
func (f *Fake) Close() {
	select {
	case <-f.stop:
		return
	default:
	}
	close(f.stop)
	_ = f.l.Close()
	f.DropConnections()
	f.wg.Wait()
	_ = os.Remove(filepath.Join(f.dir, cloudkit.SocketName))
}

// Store is the record store behind the bridge, by CloudKit zone names.
func (f *Fake) Store() *memfake.Fake {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.store
}

// Generation is the bridge's generation (the id its bridge.db was minted
// with).
func (f *Fake) Generation() string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.gen
}

// LoseState is the bridge's bridge.db lost: an empty store whose cursors
// and tags restart, a new generation, every connection dropped.
func (f *Fake) LoseState() {
	f.mu.Lock()
	f.store = memfake.New(transport.KindCloudKit, f.clock)
	f.gen = newGeneration(f.t)
	f.mu.Unlock()
	select {
	case f.reset <- struct{}{}:
	default:
	}
	f.DropConnections()
}

func newGeneration(t testing.TB) string {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		t.Fatal(err)
	}
	return hex.EncodeToString(b[:])
}

// Frames is a copy of every frame's message bytes the bridge received, in
// order (the Go side's writes, Hello included).
func (f *Fake) Frames() [][]byte {
	f.mu.Lock()
	defer f.mu.Unlock()
	return cloneAll(f.frames)
}

// Answers is a copy of every frame's message bytes the bridge sent.
func (f *Fake) Answers() [][]byte {
	f.mu.Lock()
	defer f.mu.Unlock()
	return cloneAll(f.answers)
}

// Accepted is how many connections the bridge accepted.
func (f *Fake) Accepted() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.accepted
}

// HubID is the hub_id the last Hello named.
func (f *Fake) HubID() string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.hubID
}

// PullNow sends a pull_now event (a silent push reached the bridge).
func (f *Fake) PullNow() { f.broadcast(&bridgepb.Event{PullNow: true}) }

// SendError sends a transport-level error event of class.
func (f *Fake) SendError(class string) { f.broadcast(&bridgepb.Event{ErrorClass: class}) }

// FailNext makes the next request of op ("save", "delete", "changes",
// "download", "account_status", "ensure_shares", "set_public_link",
// "participants", "remove_participants") fail with class.
func (f *Fake) FailNext(op, class string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.fail[op] = append(f.fail[op], class)
}

// SetAccount sets what AccountStatus answers.
func (f *Fake) SetAccount(a transport.Account) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.account = a
}

// SetParticipants sets a zone's (CloudKit name) share participants.
func (f *Fake) SetParticipants(zone string, ps []transport.Participant) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.participants[zone] = append([]transport.Participant(nil), ps...)
}

// ParticipantsOf is a zone's participants now.
func (f *Fake) ParticipantsOf(zone string) []transport.Participant {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]transport.Participant(nil), f.participants[zone]...)
}

// PublicLink reports whether the shares' public link is open.
func (f *Fake) PublicLink() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.publicLink
}

// DropConnections closes every open connection (the bridge restarted).
func (f *Fake) DropConnections() {
	f.mu.Lock()
	defer f.mu.Unlock()
	for c := range f.conns {
		_ = c.uc.Close()
	}
}

// PhoneRecords is a phone's view of the store by hub zone names (data/<x>
// → DataZone-<hubID>, relay/<x>/<y> → RelayZone-<hubID>), for hubtest.Phone.
func (f *Fake) PhoneRecords(hubID string) *PhoneRecords {
	return &PhoneRecords{f: f, hub: hubID}
}

// PhoneRecords is a phone writing into and reading the fake's store.
type PhoneRecords struct {
	f   *Fake
	hub string
}

func (p *PhoneRecords) zone(z string) string {
	switch {
	case strings.HasPrefix(z, "data/"):
		return cloudkit.DataZoneName(p.hub)
	case strings.HasPrefix(z, "relay/"):
		return cloudkit.RelayZoneName(p.hub)
	}
	return z
}

// Write stores a phone's sealed record.
func (p *PhoneRecords) Write(zone, name string, env []byte, expect transport.Expect) (transport.Outcome, error) {
	return p.f.Store().Write(p.zone(zone), name, env, expect)
}

// WriteWithAsset stores a phone's sealed record with its sealed asset.
func (p *PhoneRecords) WriteWithAsset(zone, name string, env, asset []byte, expect transport.Expect) (transport.Outcome, error) {
	return p.f.Store().WriteWithAsset(p.zone(zone), name, env, asset, expect)
}

// Changes reads a zone's changes.
func (p *PhoneRecords) Changes(ctx context.Context, zone string, since uint64) (transport.Batch, error) {
	return p.f.Store().Changes(ctx, p.zone(zone), since)
}

// Delete deletes a phone's records.
func (p *PhoneRecords) Delete(ctx context.Context, zone string, items []transport.DeleteItem) ([]transport.Outcome, error) {
	return p.f.Store().Delete(ctx, p.zone(zone), items)
}

func (f *Fake) accept() {
	defer f.wg.Done()
	for {
		uc, err := f.l.AcceptUnix()
		if err != nil {
			return
		}
		c := &fakeConn{uc: uc}
		f.mu.Lock()
		f.conns[c] = true
		f.accepted++
		f.mu.Unlock()
		f.wg.Add(1)
		go f.serve(c)
	}
}

func (f *Fake) serve(c *fakeConn) {
	defer f.wg.Done()
	defer func() {
		_ = c.uc.Close()
		f.mu.Lock()
		delete(f.conns, c)
		f.mu.Unlock()
	}()
	for {
		var req bridgepb.Request
		raw, err := cloudkit.ReadFrame(c.uc, &req)
		if err != nil {
			return
		}
		f.mu.Lock()
		f.frames = append(f.frames, bytes.Clone(raw))
		f.mu.Unlock()
		resp := f.handle(c, &req)
		resp.Id = req.GetId()
		f.send(c, resp)
	}
}

func (f *Fake) send(c *fakeConn, resp *bridgepb.Response) {
	frame, err := cloudkit.EncodeFrame(resp)
	if err != nil {
		f.t.Errorf("bridgefake: encode: %v", err)
		return
	}
	c.wmu.Lock()
	defer c.wmu.Unlock()
	if _, err := c.uc.Write(frame); err != nil {
		return
	}
	f.mu.Lock()
	f.answers = append(f.answers, bytes.Clone(frame[4:]))
	f.mu.Unlock()
}

func (f *Fake) broadcast(ev *bridgepb.Event) {
	f.mu.Lock()
	var conns []*fakeConn
	for c := range f.conns {
		if c.hello {
			conns = append(conns, c)
		}
	}
	f.mu.Unlock()
	for _, c := range conns {
		f.send(c, &bridgepb.Response{Result: &bridgepb.Response_Event{Event: ev}})
	}
}

// forwardEvents turns the store's zone events into bridge events.
func (f *Fake) forwardEvents() {
	defer f.wg.Done()
	for {
		st := f.Store()
		select {
		case <-f.stop:
			return
		case <-f.reset:
		case ev := <-st.Events():
			if ev.Zone != "" {
				f.broadcast(&bridgepb.Event{Zone: ev.Zone})
			}
		}
	}
}

func failure(class string) *bridgepb.Response {
	return &bridgepb.Response{Result: &bridgepb.Response_Failure{Failure: &bridgepb.Failure{Class: class}}}
}

func done() *bridgepb.Response {
	return &bridgepb.Response{Result: &bridgepb.Response_Done{Done: &bridgepb.Done{}}}
}

func (f *Fake) failed(op string) (string, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if q := f.fail[op]; len(q) > 0 {
		f.fail[op] = q[1:]
		return q[0], true
	}
	return "", false
}

func (f *Fake) handle(c *fakeConn, req *bridgepb.Request) *bridgepb.Response {
	if h := req.GetHello(); h != nil {
		if h.GetHubId() == "" {
			return failure("bad_request")
		}
		f.mu.Lock()
		f.hubID, c.hello = h.GetHubId(), true
		f.mu.Unlock()
		return &bridgepb.Response{Result: &bridgepb.Response_Hello{Hello: &bridgepb.HelloOk{Version: f.version, Generation: f.Generation()}}}
	}
	f.mu.Lock()
	hello := c.hello
	f.mu.Unlock()
	if !hello {
		return failure("bad_request")
	}
	op := opName(req)
	if class, ok := f.failed(op); ok {
		return failure(class)
	}
	ctx := context.Background()
	switch {
	case req.GetSave() != nil:
		return f.save(req.GetSave())
	case req.GetDelete() != nil:
		return f.delete(ctx, req.GetDelete())
	case req.GetChanges() != nil:
		return f.changes(ctx, req.GetChanges())
	case req.GetDownload() != nil:
		return f.download(ctx, req.GetDownload())
	case req.GetAccountStatus() != nil:
		f.mu.Lock()
		defer f.mu.Unlock()
		return &bridgepb.Response{Result: &bridgepb.Response_Account{Account: &bridgepb.Account{Status: string(f.account)}}}
	case req.GetEnsureShares() != nil:
		hub := f.HubID()
		return &bridgepb.Response{Result: &bridgepb.Response_Shares{Shares: &bridgepb.SharesInfo{
			DataUrl: "https://www.icloud.com/share/data-" + hub, RelayUrl: "https://www.icloud.com/share/relay-" + hub,
		}}}
	case req.GetSetPublicLink() != nil:
		f.mu.Lock()
		f.publicLink = req.GetSetPublicLink().GetOpen()
		f.mu.Unlock()
		return done()
	case req.GetParticipants() != nil:
		z := req.GetParticipants().GetZone()
		if !f.ownZone(z) {
			return failure("unsupported_zone")
		}
		list := &bridgepb.ParticipantList{}
		for _, p := range f.ParticipantsOf(z) {
			list.Items = append(list.Items, &bridgepb.Participant{UserRecordName: p.UserRecordName, Accepted: p.Accepted})
		}
		return &bridgepb.Response{Result: &bridgepb.Response_Participants{Participants: list}}
	case req.GetRemoveParticipants() != nil:
		r := req.GetRemoveParticipants()
		if !f.ownZone(r.GetZone()) {
			return failure("unsupported_zone")
		}
		f.mu.Lock()
		var keep []transport.Participant
		for _, p := range f.participants[r.GetZone()] {
			gone := false
			for _, n := range r.GetUserRecordNames() {
				gone = gone || n == p.UserRecordName
			}
			if !gone {
				keep = append(keep, p)
			}
		}
		f.participants[r.GetZone()] = keep
		f.mu.Unlock()
		return done()
	}
	return failure("bad_request")
}

func opName(req *bridgepb.Request) string {
	switch {
	case req.GetSave() != nil:
		return "save"
	case req.GetDelete() != nil:
		return "delete"
	case req.GetChanges() != nil:
		return "changes"
	case req.GetDownload() != nil:
		return "download"
	case req.GetAccountStatus() != nil:
		return "account_status"
	case req.GetEnsureShares() != nil:
		return "ensure_shares"
	case req.GetSetPublicLink() != nil:
		return "set_public_link"
	case req.GetParticipants() != nil:
		return "participants"
	case req.GetRemoveParticipants() != nil:
		return "remove_participants"
	}
	return ""
}

// ownZone: zone is one of the hub's two CloudKit zones.
func (f *Fake) ownZone(zone string) bool {
	hub := f.HubID()
	return zone == cloudkit.DataZoneName(hub) || zone == cloudkit.RelayZoneName(hub)
}

// under: p is a clean absolute path inside <dir>/<sub> (no symlink checks:
// the client resolved it).
func (f *Fake) under(sub, p string) bool {
	root, err := filepath.EvalSymlinks(filepath.Join(f.dir, sub))
	if err != nil || !filepath.IsAbs(p) {
		return false
	}
	parent, err := filepath.EvalSymlinks(filepath.Dir(p))
	if err != nil {
		return false
	}
	rel, err := filepath.Rel(root, parent)
	return err == nil && !strings.HasPrefix(rel, "..")
}

// staleTag: a tag of another generation (the bridge never compares it).
func (f *Fake) staleTag(e *bridgepb.Expect) bool {
	return e.GetMode() == bridgepb.ExpectMode_EXPECT_SEQ && e.GetGeneration() != f.Generation()
}

func expectOf(e *bridgepb.Expect) transport.Expect {
	switch e.GetMode() {
	case bridgepb.ExpectMode_EXPECT_ABSENT:
		return transport.Expect{Mode: transport.ExpectAbsent}
	case bridgepb.ExpectMode_EXPECT_SEQ:
		return transport.Expect{Mode: transport.ExpectSeq, Seq: e.GetTagSeq()}
	case bridgepb.ExpectMode_EXPECT_NONE:
	}
	return transport.Expect{}
}

func outcomeOf(o transport.Outcome) *bridgepb.Outcome {
	out := &bridgepb.Outcome{Saved: o.Saved, TagSeq: o.RecordSeq}
	if o.Conflict != nil {
		out.Conflict = recordOf(*o.Conflict)
	}
	return out
}

func recordOf(s transport.Stored) *bridgepb.Record {
	r := &bridgepb.Record{Name: s.Name, Envelope: s.Envelope, TagSeq: s.RecordSeq, AssetId: s.AttachmentID}
	if !s.ServerAt.IsZero() {
		r.ServerAtMs = s.ServerAt.UnixMilli()
	}
	return r
}

func errorClass(err error) string {
	switch {
	case errors.Is(err, transport.ErrUnavailable):
		return "unavailable"
	case errors.Is(err, transport.ErrTokenExpired):
		return "token_expired"
	case errors.Is(err, transport.ErrForbidden):
		return "forbidden"
	}
	return "bad_request"
}

func (f *Fake) save(s *bridgepb.Save) *bridgepb.Response {
	for _, it := range s.GetItems() {
		if !f.ownZone(it.GetZone()) {
			return failure("unsupported_zone")
		}
		if p := it.GetAssetPath(); p != "" && !f.under(cloudkit.AssetsDirName, p) {
			return failure("forbidden")
		}
	}
	res := &bridgepb.Outcomes{}
	for _, it := range s.GetItems() {
		var (
			o   transport.Outcome
			err error
		)
		if f.staleTag(it.GetExpect()) {
			res.Items = append(res.Items, &bridgepb.Outcome{RefusedClass: "token_expired"})
			continue
		}
		if p := it.GetAssetPath(); p != "" {
			b, rerr := os.ReadFile(p)
			if rerr != nil {
				return failure("bad_request")
			}
			o, err = f.Store().WriteWithAsset(it.GetZone(), it.GetName(), it.GetEnvelope(), b, expectOf(it.GetExpect()))
		} else {
			o, err = f.Store().Write(it.GetZone(), it.GetName(), it.GetEnvelope(), expectOf(it.GetExpect()))
		}
		if err != nil {
			return failure(errorClass(err))
		}
		res.Items = append(res.Items, outcomeOf(o))
	}
	return &bridgepb.Response{Result: &bridgepb.Response_Outcomes{Outcomes: res}}
}

func (f *Fake) delete(ctx context.Context, d *bridgepb.Delete) *bridgepb.Response {
	if !f.ownZone(d.GetZone()) {
		return failure("unsupported_zone")
	}
	res := &bridgepb.Outcomes{}
	for _, it := range d.GetItems() {
		if f.staleTag(it.GetExpect()) {
			res.Items = append(res.Items, &bridgepb.Outcome{RefusedClass: "token_expired"})
			continue
		}
		out, err := f.Store().Delete(ctx, d.GetZone(), []transport.DeleteItem{{Name: it.GetName(), Expect: expectOf(it.GetExpect())}})
		if err != nil {
			return failure(errorClass(err))
		}
		res.Items = append(res.Items, outcomeOf(out[0]))
	}
	return &bridgepb.Response{Result: &bridgepb.Response_Outcomes{Outcomes: res}}
}

func (f *Fake) changes(ctx context.Context, c *bridgepb.Changes) *bridgepb.Response {
	if !f.ownZone(c.GetZone()) {
		return failure("unsupported_zone")
	}
	gen := f.Generation()
	if c.GetSince() != 0 && c.GetGeneration() != gen {
		return failure("token_expired")
	}
	b, err := f.Store().Changes(ctx, c.GetZone(), c.GetSince())
	if err != nil {
		return failure(errorClass(err))
	}
	out := &bridgepb.Batch{Deleted: b.Deleted, NewSeq: b.NewSeq, More: b.More, Generation: gen}
	for _, s := range b.Changed {
		out.Changed = append(out.Changed, recordOf(s))
	}
	return &bridgepb.Response{Result: &bridgepb.Response_Batch{Batch: out}}
}

func (f *Fake) download(ctx context.Context, d *bridgepb.Download) *bridgepb.Response {
	if !f.ownZone(d.GetZone()) {
		return failure("unsupported_zone")
	}
	if !f.under(cloudkit.DownloadsDirName, d.GetDst()) {
		return failure("forbidden")
	}
	if err := f.Store().Download(ctx, d.GetZone(), d.GetAssetId(), d.GetDst()); err != nil {
		return failure(errorClass(err))
	}
	return done()
}

func cloneAll(in [][]byte) [][]byte {
	out := make([][]byte, len(in))
	for i, b := range in {
		out[i] = bytes.Clone(b)
	}
	return out
}
